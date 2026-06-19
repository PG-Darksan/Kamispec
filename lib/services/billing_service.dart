// lib/services/billing_service.dart
//
// RevenueCat 連携の中核サービス。
//
// ┌─ プラットフォーム別の方針 ───────────────────────────────────────────┐
// │ Android / iOS / macOS : purchases_flutter (SDK) を使う              │
// │ Windows / Linux / Web : SDK 非対応 → Web Purchase Link (Stripe決済) │
// │                          をブラウザで開き、REST API で entitlement   │
// │                          を確認する                                  │
// └──────────────────────────────────────────────────────────────────┘
//
// 既存の `_isDesktop` ガードと同じ思想で、Windows では Purchases.* を
// 一切呼ばない (呼ぶと例外 or クラッシュするため)。
//
// このサービスは MindMapProvider に依存しない。結果は «プラン名の文字列»
// ('free' / 'pro' / 'max') で受け渡し、provider 側で SubscriptionPlan に
// 変換する (循環 import 回避)。

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' as http;
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// プラン名の文字列定数。provider の `SubscriptionPlan.name` と一致させること。
class BillingPlanName {
  static const String free = 'free';
  static const String pro = 'pro';
  static const String max = 'max';
}

/// ユーザーが購入をキャンセルしたことを表す例外。
/// UI 側はこれをキャッチして «静かに» 何もしなければよい。
class BillingCancelledException implements Exception {
  @override
  String toString() => 'BillingCancelledException: 購入がキャンセルされました';
}

/// UI に渡す購入パッケージの簡易データ。
/// RevenueCat の `Package` をそのまま UI に晒さず、必要な情報だけ抽出する。
class BillingPackage {
  /// RevenueCat の package identifier (例: 'pro_monthly', 'max_yearly')。
  final String id;

  /// 'pro' か 'max'。id の接頭辞から判定。
  final String planName;

  /// 月額 = false / 年額 = true。
  final bool isYearly;

  /// ローカライズ済みの価格文字列 (例: '￥1,500', '\$9.99')。
  final String priceString;

  /// 購入時に SDK へ渡す元の Package。
  final Package raw;

  BillingPackage({
    required this.id,
    required this.planName,
    required this.isYearly,
    required this.priceString,
    required this.raw,
  });
}

class BillingService {
  BillingService({
    required this.apiKeyMobile,
    required this.restApiKey,
    required this.webLinkPro,
    required this.webLinkMax,
    this.onPlanChanged,
  });

  /// Android / iOS / macOS 用 RevenueCat public API キー。
  /// 開発中は Test Store キー (test_xxx)、本番は goog_xxx 等に差し替える。
  final String apiKeyMobile;

  /// Windows の entitlement 確認用 (RevenueCat v1 REST の public key)。
  /// Stripe / Web Billing 連携後に設定する。
  final String restApiKey;

  /// Windows 用 Web Purchase Link (Pro / Max)。Stripe 連携後に設定。
  final String webLinkPro;
  final String webLinkMax;

  /// プラン状態が変化したときに呼ばれるコールバック (引数はプラン名)。
  /// provider 側で `applyBillingPlanByName` に繋ぐ。
  void Function(String planName)? onPlanChanged;

  bool _configured = false;
  bool get isConfigured => _configured;

  /// RevenueCat SDK がネイティブ対応するプラットフォームか。
  /// Android / iOS / macOS のみ true。Windows / Linux / Web は false。
  static bool get isNativeBilling {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  }

  /// Windows デスクトップか (Web Purchase Link 方式の対象)。
  static bool get isWindowsDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows;
  }

  // ─── 初期化 ─────────────────────────────────────────────────────────────

  /// RevenueCat を初期化。モバイルでのみ `Purchases.configure` を呼ぶ。
  /// Windows 等では何もしない (REST で確認するため SDK 不要)。
  Future<void> configure({required String appUserId}) async {
    if (!isNativeBilling) {
      // Windows / Linux / Web: SDK は使わない。
      return;
    }
    if (apiKeyMobile.isEmpty) {
      debugPrint(
          'BillingService: REVENUECAT_API_KEY_ANDROID 未設定 → 課金機能オフ');
      return;
    }
    // ★ release ビルドで Test Store キー (test_) を使うと、RevenueCat SDK は
    //   意図的にアラートを出してアプリをクラッシュさせる仕様。開発用キーが
    //   release ビルドに混入した場合は configure をスキップして起動を守る
    //   (課金は無効になる。本番リリースでは goog_ キーに差し替えること)。
    //   課金テストは debug ビルド (flutter run) で行うこと。
    if (kReleaseMode && apiKeyMobile.startsWith('test_')) {
      debugPrint(
          'BillingService: release ビルドに Test Store キー(test_)が混入。'
          '課金を無効化します。本番は goog_ キーに差し替えてください。');
      return;
    }
    try {
      await Purchases.setLogLevel(LogLevel.warn);
      final configuration = PurchasesConfiguration(apiKeyMobile)
        ..appUserID = appUserId;
      await Purchases.configure(configuration);
      _configured = true;

      // 状態変化リスナー: 更新・解約・期限切れ等を検知して provider に通知。
      Purchases.addCustomerInfoUpdateListener((CustomerInfo info) {
        onPlanChanged?.call(_planFromCustomerInfo(info));
      });

      // 起動時に現在の状態を 1 回反映 (前回購入の復元含む)。
      final info = await Purchases.getCustomerInfo();
      onPlanChanged?.call(_planFromCustomerInfo(info));
    } catch (e) {
      debugPrint('BillingService.configure 失敗: $e');
    }
  }

  /// CustomerInfo の有効な entitlement からプラン名を判定。
  /// max を優先 (max 保有者は pro entitlement も持つ構成にする場合に備える)。
  String _planFromCustomerInfo(CustomerInfo info) {
    final active = info.entitlements.active;
    if (active.containsKey(BillingPlanName.max)) return BillingPlanName.max;
    if (active.containsKey(BillingPlanName.pro)) return BillingPlanName.pro;
    return BillingPlanName.free;
  }

  // ─── モバイル (SDK) 用 ───────────────────────────────────────────────────

  /// 現在の Offering から購入可能なパッケージ一覧を取得 (モバイルのみ)。
  /// ペイウォール UI で月額/年額・Pro/Max を出し分けるのに使う。
  Future<List<BillingPackage>> fetchPackages() async {
    if (!isNativeBilling || !_configured) {
      debugPrint('BillingService.fetchPackages: スキップ '
          '(native=$isNativeBilling, configured=$_configured)');
      return const [];
    }
    try {
      final offerings = await Purchases.getOfferings();
      // Current Offering が未設定でも 'default' / 先頭から拾うフォールバック。
      var current = offerings.current;
      current ??= offerings.all['default'];
      if (current == null && offerings.all.isNotEmpty) {
        current = offerings.all.values.first;
      }
      // デバッグ: Offering / package がいくつ取れたか可視化
      debugPrint('BillingService.fetchPackages: '
          'current=${current?.identifier}, '
          'allOfferings=${offerings.all.keys.toList()}, '
          'packages=${current?.availablePackages.length ?? 0}');
      if (current == null) return const [];
      return current.availablePackages.map((p) {
        final id = p.identifier; // 'pro_monthly' 等 (ダッシュボードの Custom id)
        final isMax = id.toLowerCase().startsWith('max');
        final isYearly =
            id.toLowerCase().contains('year') || id.toLowerCase().contains('annual');
        return BillingPackage(
          id: id,
          planName: isMax ? BillingPlanName.max : BillingPlanName.pro,
          isYearly: isYearly,
          priceString: p.storeProduct.priceString,
          raw: p,
        );
      }).toList();
    } catch (e) {
      debugPrint('BillingService.fetchPackages 失敗: $e');
      return const [];
    }
  }

  /// パッケージを購入。成功したら解決したプラン名を返す。
  /// ユーザーがキャンセルした場合は [BillingCancelledException] を投げる。
  ///
  /// 注: purchasePackage の戻り値型は SDK バージョンで差があるため、
  ///     戻り値は使わず getCustomerInfo で最新状態を取り直す。
  Future<String> purchasePackage(BillingPackage pkg) async {
    if (!isNativeBilling) return BillingPlanName.free;
    try {
      await Purchases.purchasePackage(pkg.raw);
      final info = await Purchases.getCustomerInfo();
      final plan = _planFromCustomerInfo(info);
      onPlanChanged?.call(plan);
      return plan;
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        throw BillingCancelledException();
      }
      debugPrint('BillingService.purchasePackage 失敗: $e');
      rethrow;
    }
  }

  /// 購入の復元 (機種変更・再インストール時)。
  Future<String> restore() async {
    if (!isNativeBilling) return BillingPlanName.free;
    try {
      final info = await Purchases.restorePurchases();
      final plan = _planFromCustomerInfo(info);
      onPlanChanged?.call(plan);
      return plan;
    } catch (e) {
      debugPrint('BillingService.restore 失敗: $e');
      return BillingPlanName.free;
    }
  }

  // ─── Windows (デスクトップ) 用 ───────────────────────────────────────────
  // RevenueCat SDK が Windows 非対応のため、Web Purchase Link (Stripe Checkout)
  // をブラウザで開いて決済し、REST API で entitlement を確認する。
  // ↓ ここは Stripe / Web Billing 連携が済んでから有効になる。

  /// Web Purchase Link をブラウザで開く (Windows)。
  /// app_user_id を付与して購入を本人 (= Firebase UID) に紐付ける。
  Future<bool> openWebPurchase({
    required String planName,
    required String appUserId,
  }) async {
    final base = planName == BillingPlanName.max ? webLinkMax : webLinkPro;
    if (base.isEmpty) {
      debugPrint('Web Purchase Link 未設定 (Stripe連携後に env.json へ設定)');
      return false;
    }
    final sep = base.contains('?') ? '&' : '?';
    final uri = Uri.parse(
        '$base${sep}app_user_id=${Uri.encodeComponent(appUserId)}');
    if (await canLaunchUrl(uri)) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false;
  }

  /// REST API で現在の entitlement を確認 (Windows)。
  /// 決済後やアプリ復帰 (window focus) 時に呼んでプラン状態を最新化する。
  /// v1 `/subscribers/{id}` は public key で読める。
  Future<String> fetchPlanViaRest({required String appUserId}) async {
    if (restApiKey.isEmpty) return BillingPlanName.free;
    try {
      final res = await http.get(
        Uri.parse(
            'https://api.revenuecat.com/v1/subscribers/${Uri.encodeComponent(appUserId)}'),
        headers: {
          'Authorization': 'Bearer $restApiKey',
          'Content-Type': 'application/json',
        },
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final subscriber = data['subscriber'] as Map<String, dynamic>?;
        final entitlements =
            subscriber?['entitlements'] as Map<String, dynamic>? ?? const {};
        final now = DateTime.now().toUtc();

        bool isActive(String key) {
          final ent = entitlements[key] as Map<String, dynamic>?;
          if (ent == null) return false;
          final expires = ent['expires_date'] as String?;
          if (expires == null) return true; // 無期限
          final exp = DateTime.tryParse(expires);
          return exp != null && exp.isAfter(now);
        }

        if (isActive(BillingPlanName.max)) return BillingPlanName.max;
        if (isActive(BillingPlanName.pro)) return BillingPlanName.pro;
        return BillingPlanName.free;
      }
      debugPrint('fetchPlanViaRest: ${res.statusCode} ${res.body}');
    } catch (e) {
      debugPrint('BillingService.fetchPlanViaRest 失敗: $e');
    }
    return BillingPlanName.free;
  }

  /// Windows 用: Web で購入させた後、entitlement が反映されるまで
  /// 数回ポーリングして最新プランを取得する (決済→反映に時間差があるため)。
  Future<String> pollPlanAfterWebPurchase({
    required String appUserId,
    int attempts = 6,
    Duration interval = const Duration(seconds: 5),
  }) async {
    String last = BillingPlanName.free;
    for (var i = 0; i < attempts; i++) {
      await Future.delayed(interval);
      last = await fetchPlanViaRest(appUserId: appUserId);
      if (last != BillingPlanName.free) {
        onPlanChanged?.call(last);
        return last;
      }
    }
    return last;
  }

  /// デバッグ用: 課金まわりの状態を文字列で返す。
  /// 購入シートで商品が取れないとき、画面に原因を表示するのに使う
  /// (debug ビルド時のみ表示する想定)。
  Future<String> debugDiagnostics() async {
    final sb = StringBuffer();
    final keyPreview = apiKeyMobile.isEmpty
        ? '(未設定)'
        : (apiKeyMobile.length <= 12
            ? apiKeyMobile
            : '${apiKeyMobile.substring(0, 12)}...');
    sb.writeln('native=$isNativeBilling / configured=$_configured');
    sb.writeln('apiKey=$keyPreview');
    if (!isNativeBilling) {
      sb.writeln('→ このプラットフォームは SDK 非対応 (Windows等)');
      return sb.toString();
    }
    try {
      final offerings = await Purchases.getOfferings();
      sb.writeln('current=${offerings.current?.identifier ?? "(null)"}');
      sb.writeln('all offerings=${offerings.all.keys.toList()}');
      offerings.all.forEach((k, o) {
        sb.writeln('  [$k] ${o.availablePackages.length}個: '
            '${o.availablePackages.map((p) => p.identifier).toList()}');
      });
      final info = await Purchases.getCustomerInfo();
      sb.writeln('appUserId=${info.originalAppUserId}');
      sb.writeln('active entitlements='
          '${info.entitlements.active.keys.toList()}');
    } catch (e) {
      sb.writeln('ERROR: $e');
    }
    return sb.toString();
  }
}
