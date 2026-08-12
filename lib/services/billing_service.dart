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

  /// 決済を通さずに AI を呼べる開発 / 検証用の枠。 購入では手に入らず、
  /// 引き換えコードでサーバー (Worker) が付与した時だけ返ってくる。
  static const String dev = 'dev';
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
    this.stripeLinkProMonthly = '',
    this.stripeLinkProYearly = '',
    this.stripeLinkMaxMonthly = '',
    this.stripeLinkMaxYearly = '',
    this.stripeTestMode = false,
    this.entitlementApiBase = '',
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

  // ── Stripe 決済リンク (デスクトップ用の直接経路) ──
  // RevenueCat Web Billing を使わず、 Stripe の Payment Link をそのまま開く。
  // 購入者の紐付けは client_reference_id に Firebase UID を渡して行う。
  final String stripeLinkProMonthly;
  final String stripeLinkProYearly;
  final String stripeLinkMaxMonthly;
  final String stripeLinkMaxYearly;

  /// テスト環境のリンクを使っているか (UI に注意書きを出すため)。
  final bool stripeTestMode;

  // ── 表示用の価格 (= ユーザー要望: 課金画面に金額と割引率を出す) ──
  //
  // ★ Stripe の Payment Link は金額を返さないので、 画面に出す数字はここに
  //   持っている。 **Stripe 側で価格を変えたらここも直すこと**。 直し忘れると
  //   「画面の金額」 と「決済ページの金額」 が食い違う。
  //   年額は「1 か月あたり」 の額。 年間の請求額は 12 倍して出す。
  static const double proMonthlyUsd = 9.99;
  static const double proYearlyPerMonthUsd = 7.99;
  static const double maxMonthlyUsd = 19.99;
  static const double maxYearlyPerMonthUsd = 15.99;

  /// プランと課金周期から「1 か月あたりの額 (USD)」 を引く。
  static double priceUsdFor({required String planName, required bool yearly}) {
    if (planName == BillingPlanName.max) {
      return yearly ? maxYearlyPerMonthUsd : maxMonthlyUsd;
    }
    return yearly ? proYearlyPerMonthUsd : proMonthlyUsd;
  }

  /// 年額にすると何 % 安くなるか (四捨五入した整数)。
  /// 月額が 0 以下なら 0 を返す。
  static int yearlyDiscountPercent(String planName) {
    final m = priceUsdFor(planName: planName, yearly: false);
    final y = priceUsdFor(planName: planName, yearly: true);
    if (m <= 0) return 0;
    return (((m - y) / m) * 100).round();
  }

  /// 年額を選んだ時に実際に請求される 1 年分の額 (USD)。
  static double yearlyTotalUsd(String planName) =>
      priceUsdFor(planName: planName, yearly: true) * 12;

  /// 権利照会 API のベース URL (Cloudflare Worker)。
  /// 例: https://api.hisator-notebook.com
  final String entitlementApiBase;

  /// Stripe 決済リンクが 1 本でも設定されているか。
  bool get hasStripeLinks =>
      stripeLinkProMonthly.isNotEmpty ||
      stripeLinkProYearly.isNotEmpty ||
      stripeLinkMaxMonthly.isNotEmpty ||
      stripeLinkMaxYearly.isNotEmpty;

  /// プランと課金周期から決済リンクを引く。
  String stripeLinkFor({required String planName, required bool yearly}) {
    if (planName == BillingPlanName.max) {
      return yearly ? stripeLinkMaxYearly : stripeLinkMaxMonthly;
    }
    return yearly ? stripeLinkProYearly : stripeLinkProMonthly;
  }

  /// Stripe の決済ページをブラウザで開く (デスクトップ)。
  ///
  /// `client_reference_id` に Firebase UID を渡すので、 Stripe 側の
  /// Checkout Session からどのユーザーの購入か特定できる。 決済完了後の
  /// 権利付与は Webhook を受けるサーバー側で行う (未構築の間は、 購入後に
  /// 手動でプランを反映する運用になる)。
  Future<bool> openStripeCheckout({
    required String planName,
    required bool yearly,
    required String appUserId,
  }) async {
    final base = stripeLinkFor(planName: planName, yearly: yearly);
    if (base.isEmpty) {
      debugPrint('BillingService: Stripe link 未設定 ($planName/$yearly)');
      return false;
    }
    final sep = base.contains('?') ? '&' : '?';
    final uri = Uri.parse('$base${sep}client_reference_id='
        '${Uri.encodeComponent(appUserId)}');
    try {
      if (await canLaunchUrl(uri)) {
        return launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('BillingService.openStripeCheckout 失敗: $e');
    }
    return false;
  }

  /// Stripe のカスタマーポータル (no-code ログインリンク)。
  /// ユーザーが購入時のメールアドレスでログインして、 解約・支払い方法の
  /// 変更・請求履歴の確認を自分で行える (= ユーザー要望: 定期購入を解約
  /// できるように)。 Stripe ダッシュボード → 設定 → Billing →
  /// カスタマーポータル で有効化して、 発行されたログインリンクを
  /// env.json の STRIPE_CUSTOMER_PORTAL_LINK に入れる。
  static const String stripeCustomerPortalUrl = String.fromEnvironment(
      'STRIPE_CUSTOMER_PORTAL_LINK',
      defaultValue: '');

  /// 定期購入の管理ページ (解約・支払い方法変更) を開く。
  ///
  /// - Android: RevenueCat の managementURL (購入した Google アカウントの
  ///   Play ストア定期購入管理画面へ直行)。 取れなければ Play の定期購入
  ///   一覧へフォールバック。 Play の購入は端末の Google アカウントに必ず
  ///   紐づくので、 そのアカウントでログインしていれば解約できる。
  /// - Windows: Stripe のカスタマーポータル。 リンク未設定なら false を
  ///   返し、 呼び出し側で案内を出す。
  Future<bool> openManagementPage() async {
    try {
      if (isNativeBilling) {
        String? url;
        try {
          final info = await Purchases.getCustomerInfo();
          url = info.managementURL;
        } catch (_) {}
        url ??= 'https://play.google.com/store/account/subscriptions'
            '?package=com.kamispec.app';
        return await launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication);
      }
      if (stripeCustomerPortalUrl.isNotEmpty) {
        return await launchUrl(Uri.parse(stripeCustomerPortalUrl),
            mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('BillingService.openManagementPage 失敗: $e');
    }
    return false;
  }

  /// プラン状態が変化したときに呼ばれるコールバック (引数はプラン名)。
  /// provider 側で `applyBillingPlanByName` に繋ぐ。
  void Function(String planName)? onPlanChanged;

  bool _configured = false;
  bool get isConfigured => _configured;

  void Function(CustomerInfo)? _customerInfoListener;
  bool _disposed = false;

  /// RevenueCat SDK がネイティブ対応するプラットフォームか。
  /// Android / iOS / macOS のみ true。Windows / Linux / Web は false。
  static bool get isNativeBilling {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  }

  /// RevenueCat SDK 非対応のデスクトップか (Web Purchase Link / Stripe 方式の
  /// 対象)。 Windows に加え Linux も該当 (どちらも purchases_flutter 非対応)。
  /// ※ 名前は歴史的経緯で isWindowsDesktop のままだが Linux も含む。
  static bool get isWindowsDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux;
  }

  // ─── 初期化 ─────────────────────────────────────────────────────────────

  /// RevenueCat を初期化。モバイルでのみ `Purchases.configure` を呼ぶ。
  /// Windows 等では何もしない (REST で確認するため SDK 不要)。
  Future<void> configure({required String appUserId}) async {
    if (_disposed || _configured) return;
    if (!isNativeBilling) {
      // Windows / Linux / Web: SDK は使わない。
      return;
    }
    if (apiKeyMobile.isEmpty) {
      debugPrint('BillingService: REVENUECAT_API_KEY_ANDROID 未設定 → 課金機能オフ');
      return;
    }
    // RevenueCat の Test Store キー (test_) は release ビルドでは使えない。
    // SDK が Wrong API Key ダイアログを出して終了するため、ここで初期化を止める。
    // Test Store 検証は debug APK、本番ストア公開は goog_ キーで行うこと。
    if (kReleaseMode && apiKeyMobile.startsWith('test_')) {
      debugPrint(
          'BillingService: release build is using RevenueCat Test Store key. '
          'Skip SDK configure to avoid RevenueCat Wrong API Key shutdown. '
          'Use a debug build for Test Store, or goog_ key for production.');
      return;
    }
    try {
      await Purchases.setLogLevel(LogLevel.warn);
      final configuration = PurchasesConfiguration(apiKeyMobile)
        ..appUserID = appUserId;
      await Purchases.configure(configuration);
      _configured = true;

      // 状態変化リスナー: 更新・解約・期限切れ等を検知して provider に通知。
      _customerInfoListener = (CustomerInfo info) {
        if (_disposed) return;
        onPlanChanged?.call(_planFromCustomerInfo(info));
      };
      Purchases.addCustomerInfoUpdateListener(_customerInfoListener!);

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
        final isYearly = id.toLowerCase().contains('year') ||
            id.toLowerCase().contains('annual');
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
      final oldProductIdentifier = await _googleOldProductIdentifierFor(pkg);
      if (oldProductIdentifier == null) {
        await Purchases.purchasePackage(pkg.raw);
      } else {
        await Purchases.purchasePackage(
          pkg.raw,
          googleProductChangeInfo: GoogleProductChangeInfo(
            oldProductIdentifier,
            prorationMode: GoogleProrationMode.immediateWithTimeProration,
          ),
        );
      }
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

  /// Android / Google Play のサブスク切替用に、現在有効な旧 product id を返す。
  /// これを渡さないと Pro 月額 → Max 月額などが「別サブスク購入」扱いになり、
  /// 切替ダイアログに進めないことがある。
  Future<String?> _googleOldProductIdentifierFor(BillingPackage pkg) async {
    if (!Platform.isAndroid || !_configured) return null;

    try {
      final info = await Purchases.getCustomerInfo();
      final active = info.entitlements.active;
      final targetProductIdentifier = pkg.raw.storeProduct.identifier;

      final current = pkg.planName == BillingPlanName.max
          ? (active[BillingPlanName.max] ?? active[BillingPlanName.pro])
          : active[pkg.planName];
      final oldProductIdentifier = current?.productIdentifier;
      if (oldProductIdentifier == null ||
          oldProductIdentifier == targetProductIdentifier) {
        return null;
      }
      return oldProductIdentifier;
    } catch (e) {
      debugPrint('BillingService: Google product change info skipped: $e');
      return null;
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
    final uri =
        Uri.parse('$base${sep}app_user_id=${Uri.encodeComponent(appUserId)}');
    if (await canLaunchUrl(uri)) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false;
  }

  /// Cloudflare Worker の権利 API で現在のプランを取得する。
  ///
  /// Stripe の Webhook を受けた Worker が KV に書いた結果を読むだけなので、
  /// クライアントが勝手にプランを詐称することはできない (アプリは判定を
  /// 持たず、 サーバーの答えをそのまま使う)。
  ///
  /// 戻り値が **null は「判定できなかった」** (未設定・圏外・サーバー障害)。
  /// free と区別できないと、 通信に失敗しただけで有料ユーザーを解約扱いに
  /// してしまうため、 呼び出し側は null の時は今の状態を変えないこと。
  Future<String?> fetchPlanViaEntitlementApi({required String appUserId}) async {
    if (entitlementApiBase.isEmpty || appUserId.isEmpty) return null;
    try {
      final uri = Uri.parse('$entitlementApiBase/entitlement'
          '?uid=${Uri.encodeComponent(appUserId)}');
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        debugPrint('entitlement API: ${res.statusCode} ${res.body}');
        return null;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final plan = (data['plan'] as String? ?? '').toLowerCase();
      // Dev はサーバーだけが付与できる (アプリからは要求できない)。
      if (plan == BillingPlanName.dev) return BillingPlanName.dev;
      if (plan == BillingPlanName.max) return BillingPlanName.max;
      if (plan == BillingPlanName.pro) return BillingPlanName.pro;
      return BillingPlanName.free;
    } catch (e) {
      debugPrint('BillingService.fetchPlanViaEntitlementApi 失敗: $e');
      return null;
    }
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

  /// RevenueCat のグローバルリスナーからこのサービスを切り離す。
  /// Provider の破棄後に古いコールバックが状態を書き換えることを防ぐ。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final listener = _customerInfoListener;
    _customerInfoListener = null;
    onPlanChanged = null;
    if (listener != null && isNativeBilling) {
      Purchases.removeCustomerInfoUpdateListener(listener);
    }
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
