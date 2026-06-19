# Kamispec / MokuMoku — Flutter マインドマップアプリ

> 開発者・利用者の両方に向けた README です。コードの内部構成を素早く把握できるよう、主要なクラス・機能を `ファイル:行番号` で対応付けたナビゲーション表を多数掲載しています。将来のコード調査（推論）を短縮することを最優先に作成しています。
>
> 注意: 行番号は本 README 作成時点のスナップショットです。2 つの巨大ファイル（`lib/providers/mind_map_provider.dart` ≒ 30,635 行、`lib/screens/mind_map_screen.dart` ≒ 101,510 行）は頻繁に変更されるため、編集前に必ず Grep（`^class ` / `^enum ` / メソッド名 / `t('` キー）で再確認してください。

---

## 概要

Kamispec（内部コード名 MokuMoku）は **Android と Windows デスクトップ** を主要ターゲットとする Flutter 製マインドマップアプリです（iOS / macOS / Linux / Web は部分的な設定のみ）。単なるマインドマップを大きく超え、以下を 1 つのアプリに統合しています。

- ノードツリーの作成・編集・接続
- YouTube 埋め込み・検索・ダウンロード、ローカル動画再生（最大 16 倍速）、PiP / バックグラウンド再生
- アプリ内 PDF ビューア（ページ紐付けメモ・ハイライト付き）
- ドキュメントビューア／エディタ（docx / xlsx / pptx / csv / tsv / txt / Markdown / 画像）
- Gemini をはじめとするマルチプロバイダ AI によるノード生成・要約・解説
- 音声入力（speech-to-text）
- OS 通知 / リマインダー、フォーカスロック（集中モード）
- グループ共有カレンダー
- RevenueCat / Stripe によるサブスクリプション（free / pro / max）

UI 文字列とコードコメントは主に **日本語** です。状態は単一の巨大プロバイダ（`MindMapProvider`）に集約され、ローカルは `SharedPreferences`、クラウドは Firestore REST API へ同期します。

---

## 主な機能

| 機能 | 概要 | 主な実装場所 |
|---|---|---|
| ノード操作（作成・移動・編集） | ノードの追加・タイトル/メモ/色/サイズ編集、長押しドラッグ移動、範囲選択（複数選択）、グループ化、コネクション（接続）、図形デコレーション、裁断（カット）モード | キャンバス操作: `lib/screens/mind_map_screen.dart:365` (`_MindMapScreenState`)。ノード CRUD: `lib/providers/mind_map_provider.dart:25500` (`addNodeAtCenterReturning`)、`:26797` (`connectNodes`)、`:30089` (`deleteNode`)、`:30128` (`moveNodes`) |
| メモ | ノード本文メモ、ノードごと/全体のフォントサイズ、折りたたみ | `updateNodeMemo` `lib/providers/mind_map_provider.dart:28621`、レンダリングは `lib/widgets/node_widget.dart:32` |
| YouTube 埋め込み・検索・DL | URL からの埋め込み、`m.youtube.com` を隠し WebView でスクレイピングした検索/プレイリスト抽出、チャンネル自動取り込み、`youtube_explode_dart` による動画ダウンロード（YouTube DL は Pro 以上） | 検索: `_YoutubeSearchSheet` `lib/screens/mind_map_screen.dart:54934` / Windows版 `:56720`。DL: `_downloadCurrentVideo` `:52220` / Windows版 `:48451` |
| ローカル動画再生 | mp4/webm/mov を `video_player` で再生（WebView の 2 倍速制限を回避し 1.0–16x 対応）、フォーカスモード、再生位置自動保存、WebView フォールバック | `_FullscreenVideoPage` `lib/screens/mind_map_screen.dart:50599`、launcher `_openFullscreenVideo` `:12051` |
| アプリ内 PDF ビューア + ページ紐付けメモ | `syncfusion_flutter_pdfviewer` による描画（`onPageChanged`/`jumpToPage` 利用）、ページ/URL アンカー付きメモ、テキストハイライト、ページ非表示、AI クイズ生成 | ビューア `_InAppViewerDialog` `:73584` / `_InAppViewerPage` `:77168`、メモパネル `_PdfMemoPanel` `:79184`、モデル `PdfMemo` `lib/models/mind_map_node.dart:28` |
| ドキュメントビューア（docx/xlsx/pptx/csv） | 全てアプリ内でパース/編集。xlsx は `excel`、csv/tsv は `csv`、docx/pptx は `archive` で unzip して XML パース | スプレッドシート `_SpreadsheetEditorDialog` `:84333`、DOCX `_DocxViewerDialog` `:95928`、PPTX `_PptxViewerDialog` `:87047`、テキスト/Markdown `_TextEditorDialog` `:93275` |
| AI ノード生成（Gemini） | 子/孫ノード生成、概念解説、ファイル要約、構造化マップ生成、ノード単位の解説/カスタムプロンプト。マルチプロバイダ（gemini/openai/anthropic/grok/deepseek） | ディスパッチ `askAi` `lib/providers/mind_map_provider.dart:19688`、`askGemini` `:22057`、子生成 `aiGenerateChildren` `:22367` |
| 音声入力 | `speech_to_text` による音声→テキスト。言語に応じた BCP-47 ロケール | `_VoiceInputDialog` `lib/screens/mind_map_screen.dart:67549`、ロケール解決 `speechLocaleId` `lib/providers/mind_map_provider.dart:4211` |
| OS 通知 / リマインダー | Android は `flutter_local_notifications`（`zonedSchedule`、アプリ終了後も発火）、Windows は `local_notifier` トースト、加えてアプリ内オーバーレイ。予定登録の「通知する」トグルから予約 | `main()` `lib/main.dart:24`、コア関数 `_scheduleAbsoluteNotification` `lib/screens/mind_map_screen.dart:15484` |
| 共有カレンダー | 日付別イベント、グループ共有（Pro 以上で他人のカレンダー閲覧）、祝日表示、タイムゾーン、フォーカスロックスケジュール | モデル `CalendarEvent` `lib/providers/mind_map_provider.dart:19`、アップロード `uploadCalendarEventsToCloud` `:1706`、ダウンロード `downloadCalendarEventsFromCloud` `:1825` |
| サブスクリプション | free/pro/max。Android/iOS/macOS は RevenueCat SDK、Windows/Web は Stripe Web Purchase Link + REST 確認。クーポン・開発者モードあり | プラン解決 `currentPlan` `lib/providers/mind_map_provider.dart:18132`、`lib/services/billing_service.dart:69` (`BillingService`) |

補足機能: フローティングツール（電卓・関数電卓・ストップウォッチ・ポモドーロ・天気・Google 検索）、メニュー時計、画像エディタ、付箋（名前付きグループ）、プレゼンターモード、問い合わせ/開発者インボックス、ブックマークボタン、カスタマイズ可能なヘッダー/フッターボタン。

---

## 対応プラットフォーム

| プラットフォーム | 状況 | 備考 |
|---|---|---|
| Android | 主要ターゲット | `flutter_inappwebview`、`flutter_local_notifications`、RevenueCat、`audio_service` 等を使用 |
| Windows デスクトップ | 主要ターゲット | `webview_windows`、`local_notifier`、Stripe + REST 課金、`syncfusion_pdfviewer_windows` を使用 |
| iOS / macOS | 部分対応 | 課金は RevenueCat（macOS）。Firebase 設定枠あり |
| Linux / Web | 部分対応 | Web/Linux はビルド設定のみ。Web 課金は Stripe |

Android と Windows は WebView 実装・通知・課金・動画再生・音声認識が大きく異なるため、コード全体に `if (Platform.isWindows)` / `if (Platform.isAndroid)` 分岐とプラットフォーム別プラグインが多数あります（詳細は「プラットフォーム別の注意点」参照）。

---

## 必要環境

- Flutter SDK（`flutter_lints ^3` を使用する Dart/Flutter バージョン）
- Android ビルド: Android SDK（`targetSdk 34`、`minSdk = flutter.minSdkVersion`＝23 相当）、Java 11、core library desugaring（`desugar_jdk_libs:2.1.4`）
- Windows ビルド: Visual Studio（C++ デスクトップ開発）、CMake、WebView2 ランタイム
- `env.json`（API キー類。git 管理外。後述）
- 任意: 署名用 `android/key.properties`（無い場合は debug 署名にフォールバック）、ネイティブ Firebase 初期化用 `google-services.json`（REST のみ運用なら省略可）

> `flutter test` / `test/widget_test.dart` は標準のカウンタテンプレートのままで、このアプリには対応していません。実質的にテストスイートは空と考えてください。

---

## セットアップ

```bash
flutter pub get          # 依存パッケージのインストール
flutter analyze          # 静的解析（flutter_lints）
```

日本語 PDF を正しく出力したい場合は、別途 Noto Sans JP フォントを配置します（「既知の注意点」参照）。

---

## env.json の設定

`env.json` は **すべての API キーを保持するファイルで、git 管理外（`.gitignore` 対象）です。絶対にコミットしないでください。** キーはコンパイル時に `String.fromEnvironment(...)` で読み込まれます（ランタイムの `.env` 読み込みは存在しません）。**Firebase / Gemini / 課金に触れるビルド・実行では `--dart-define-from-file=env.json` が必須**です。未指定でもアプリは起動しますが、Firebase / AI / 同期機能は無効化（graceful degrade）されます。

主なキー:

| カテゴリ | キー | 用途 |
|---|---|---|
| Firebase | `FIREBASE_PROJECT_ID` | Firestore REST のプロジェクト ID |
| Firebase | `FIREBASE_MESSAGING_SENDER_ID` / `FIREBASE_STORAGE_BUCKET` / `FIREBASE_AUTH_DOMAIN` / `FIREBASE_IOS_BUNDLE_ID` | 共通設定 |
| Firebase | `FIREBASE_API_KEY_ANDROID` / `_WINDOWS` / `_IOS` / `_WEB` / `_MACOS` | プラットフォーム別 API キー |
| Firebase | `FIREBASE_API_KEY_REST` | Firestore REST 用キー（優先解決。後述） |
| Firebase | `FIREBASE_APP_ID_*` / `FIREBASE_MEASUREMENT_ID`（Windows のみ） | アプリ ID / 計測 ID |
| RevenueCat | `REVENUECAT_API_KEY_ANDROID` | RevenueCat SDK 公開キー（dev は `test_…`、本番は `goog_…`） |
| RevenueCat | `REVENUECAT_API_KEY_REST` | Windows 用 RevenueCat REST 公開キー |
| RevenueCat | `REVENUECAT_WEB_PURCHASE_LINK_PRO` / `_MAX` | Windows/Web 用 Stripe Web Purchase Link |
| Gemini | `GEMINI_API_KEY` | Gemini API キー（未設定時はユーザー入力キーやアプリ共有キーへフォールバック） |

消費場所:
- Firebase 設定: `lib/firebase_options.dart`（全フィールドが `String.fromEnvironment(..., defaultValue: '')`）
- Firestore REST キーの優先解決: `lib/providers/mind_map_provider.dart:2499`（`FIREBASE_API_KEY_REST → _WINDOWS → _ANDROID → _IOS → _WEB → _MACOS` の順に最初の非空を採用）
- Gemini キー注入: `lib/providers/mind_map_provider.dart:15459`
- RevenueCat/Stripe キー注入: `lib/providers/mind_map_provider.dart:17843`

> **重要(セキュリティ)**: RevenueCat に入れてよいのは公開キーのみです。Stripe/RevenueCat のシークレットを env.json に入れてはいけません。`lib/firebase_options.dart` は手動メンテされており（先頭コメント参照）、`flutterfire configure` で再生成すると env-var 配線が上書きされます。再生成した場合は手動で再修正してください。

---

## 実行 / ビルドコマンド

```bash
# デバッグ実行
flutter run --dart-define-from-file=env.json

# Android リリースビルド（APK）
flutter build apk --release --dart-define-from-file=env.json

# Windows リリースビルド
flutter build windows --release --dart-define-from-file=env.json
```

---

## アーキテクチャ概要

### 1. 単一の巨大プロバイダ（状態）

アプリ全体の状態は **`lib/providers/mind_map_provider.dart`**（`MindMapProvider extends ChangeNotifier`、約 30,635 行）に集約されています。`lib/main.dart` のルートで `ChangeNotifierProvider` により 1 度だけ生成され、ドキュメントツリー / AI 設定・使用量 / i18n / クラウド同期 / カレンダー / 課金プラン / 機能トグルの単一の真実の源になります。新しい横断的状態はほぼここに追加します。

- 永続化（2 系統）:
  - **ドキュメントツリー**は `_saveToStorage` `:24815` が `mindmap_pages_v3`（ページ群、定数 `_storageKey` `:1102`）と `mindmap_folders_v1`（フォルダ群、定数 `_foldersStorageKey` `:1103`）へ保存。読み込みは `_loadFromStorage` `:24695`（v3 を読み、無ければ旧 `mindmap_pages_v2` を `:24716` でフォールバック読み／フォルダは `:24739`）。
  - **機能別設定**は `_saveToStorageLocal` `:24841`（呼び出し多数: `:16216` ほか、フォーカスロック/各種トグル系）と、無数の個別 `_save*` / `prefs.set*`（コード全体に 460 箇所以上）が分担。ドキュメント本体とは別ルートなので混同しないこと。
  - クラウド同期は上記とは独立に、選択データを Firestore REST へミラー（後述「5. Firestore REST 同期」）。
- コンストラクタ `:22727` が起動時に約 25 個の `_load*` を発火（ほとんどが fire-and-forget）。`_loadFromStorage` `:24695` のみ `.then` で連鎖し、最後に開いたページ復元（`last_opened_page_id` `:24890`/`:24900`）とサムネ生成を行う。

#### 主要 SharedPreferences キー早見表

> プロバイダには 100 以上の永続化キーがあります（全列挙は不可能なため代表のみ）。命名規則: スキーマ版は末尾 `_v1`/`_v2`、一部は `$pageId` 等を埋め込む**動的キー**（例 `page_uploaded_$pageId`）。「どこにデータが保存されるか」を調べる際の起点として使ってください。

| カテゴリ | 代表キー | 用途 / 参照行 |
|---|---|---|
| ドキュメントツリー（最重要） | `mindmap_pages_v3`（正規・定数 `_storageKey` `:1102`）/ `mindmap_pages_v2`（旧・移行用） / `mindmap_folders_v1` | 全ページ・全フォルダ。書き `_saveToStorage` `:24815`（v3 へ保存）、読み `:24716`（v2 フォールバック）/ `:24739`（フォルダ）。フォルダ定数 `_foldersStorageKey` `:1103` |
| 起動復元 | `last_opened_page_id` | 最後に開いたページ。`:24890`（書き）/`:24900`（読み） |
| ページ管理 | `favorite_page_ids` (`:28531`) / `hidden_page_ids` / `page_uploaded_$pageId` | お気に入り/非表示/アップロード済みフラグ（動的キー） |
| AI 設定 | `aiProvider` (`:3789`/`:15471`) / `aiModelTier` / `aiChildMin`/`aiChildMax`/`aiGrandchildMin`/`aiGrandchildMax`/`aiDepth` | 生成プロバイダと子/孫ノード数・深さ |
| AI キー | `gemini_api_key`/`openai_api_key`/`anthropic_api_key`/`grok_api_key`/`deepseek_api_key` と各 `*_model`、`global_gemini_api_key` (`:18988`/`:18995`)、`cached_*_models`+`models_fetch_*_ts` | プロバイダ別キー・モデル・モデル一覧キャッシュ |
| 課金 | `purchased_plan` (`:17895`/`:18198`) / `dev_impersonate_plan` / `developer_mode` / `applied_coupon_code`/`coupon_plan`/`coupon_expiry_ms`/`coupon_discount_percent` / `billingMonthYm`/`monthlyUploadBytes`/`monthlyDownloadBytes` | プラン・開発者偽装・クーポン・月次転送量 |
| 同期/グループ | `firebase_uid` (`:19237`/`:19240`) / `firebase_refresh_token` / `joinedGroupIds` (`:2589`/`:2614`) / `autoSyncPageIds` / `displayName` | 認証 UID・参加グループ・自動同期対象 |
| カレンダー | `calendarGroupSharingEnabled` / `calendarViewingUid` / `calendarTzLabel`/`calendarTzOffset` | グループ共有・閲覧対象 UID・タイムゾーン |
| 表示/設定 | `appLanguage` (`:4074`/`:15494`) / `isDarkMode` / `colorMode` / `defaultTitleFontSize`/`defaultMemoFontSize` / `customHeaderButtons`/`customBottomButtons` | 言語・テーマ・フォント・カスタムボタン |
| フォーカスロック | `focusLockScheduleEnabled` / `focusLockScheduleStartMin`/`focusLockScheduleEndMin` / `focusLockSchedules` / `focusLockHideSeconds` | 集中モードのスケジュール |
| 動画/YouTube | `lastWatchedVideoId` / `lastVideoPlaybackRate` / `generatedVideoIds` / `autoDeleteWatched` / `channelQueues`/`channelMode` / `chFilterInclude`/`chFilterExclude` / `includeShorts`/`minViewCount` | 視聴履歴・再生速度・チャンネル取り込み設定 |
| PDF | `hidden_pdf_pages` / `lastPdfPages_v1` / `pdfHighlights` / `pdfMemoPinnedFolders_v1` / `pastQuizQuestions` | 非表示ページ・最終ページ・ハイライト・クイズ履歴 |

### 2. データモデル階層（Folder > Page > Node）

- **`MindMapFolder`** `lib/providers/mind_map_provider.dart:143` → **`MindMapPage`** `:176` → **`MindMapNode`** `lib/models/mind_map_node.dart:581`。
- フォルダはページをまとめ（ネスト不可・フラット）、ページはノードとコネクションを保持します。
- `MindMapNode` は `NodeContentType`（`none`/`memo`/`youtube`/`link`/`attachment`/`table`）で内容種別を持ち、`PdfMemo` / `TableData` / `NodeConnection` を内包します。
- **JSON シリアライズはすべて手書き**（各クラスに `toJson`/`fromJson`）。`json_serializable` / `build_runner` は dev 依存にあるが **`.g.dart` もコード生成ステップも無い**。フィールド追加時は手書きの `toJson`/`fromJson` を後方互換で更新すること（既存フィールドは防御的に読む）。

### 3. 単一の巨大スクリーン

**`lib/screens/mind_map_screen.dart`**（約 101,510 行）が `MindMapScreen` + `_MindMapScreenState` ＋多数の private ウィジェット/ペインタ/シート/ビューアを含みます。`_MindMapScreenState` は約 365–45736 行を占める「神状態」で、キャンバス・ドロワー・分割ビュー・オーバーレイ・ほぼ全インタラクションを保持します。45737 行以降は機能別の支援クラス群（ファイル全体で約 200 のトップレベル宣言）。切り出されたウィジェットは `lib/widgets/` にあります。

### 4. 独自 i18n（`t()`）

ARB/`gen_l10n` ではなく独自実装。`static const Map<String, Map<String,String>> _translations`（`lib/providers/mind_map_provider.dart:4317`、約 11,000 行、~1,149 キー）を `String t(String key)` `:15360` で引きます。フォールバックは **`_appLanguage` → `'en'` → `'ja'` → キー文字列**（`:15363`）。対応 30 言語（`supportedLanguages` `:3827`）のうち完全翻訳は 9 言語（`_fullyTranslatedLanguages` `:3901`）、残りは英語フォールバック（BETA）。UI 文字列は `_translations` にキー追加して使う（既定言語は `'en'`）。

### 5. Firestore REST 同期

`cloud_firestore` プラグインは **使わず**、`package:http` で Firestore REST API（`https://firestore.googleapis.com/v1/...`）を直接叩きます。認証は Identity Toolkit の匿名サインイン（`_signInAnonymously` `:22841`）で得た UID をユーザーキーに使用。同期は **8 文字のグループコード**（`_syncGroupId` / `createGroup` `:22914`, `joinGroup` `:22933`）を軸に、ページ・カレンダー・メッセージング・メンバーを共有します。REST フィールドエンコードは `_firestoreStr`（読み `:23372`）、`_normalizeFields`（書き `:2829`）、`_firestoreBaseUrl` `:2534` でラップ。

Firestore ドキュメントツリー（概略）:
```
(default)/documents/
├── groups/{gid}/                gid = 8文字コード
│   ├── pages/{pageId}           json, namedGroupsJson, expiresAt(TTL), uploadRestricted, restrictedByUid
│   ├── members/{uid}            uid, displayName, lastSeen, allowCalendarSharing, plan
│   └── calendar/{uid}           json(イベント), ownerUid, ownerName, updatedAt
├── users/{uid}                  displayName, plan, lastSeen, couponCode
├── messages/{msgId}             fromUid, fromName, text, timestamp, read, toUid|toGroupId
├── inquiries/{msgId}            uid, message, reply, status, senderPlan, ...
├── admin/settings               globalGeminiApiKey, inquiryEmail
├── coupons/{code} / licenses/{code}
└── (Storage) groups/{gid}/attachments/{fileName}
```
- **TTL / 自動失効**: グループページの `expiresAt` フィールドが TTL を担い、期限切れドキュメントは定期プルーニングで掃除されます（最終実行時刻は SharedPreferences の `lastPruneAtMs` で間引き）。グループ共有データが「いつの間にか消える」挙動の入口はこの TTL/prune 処理です。
- **メッセージング backend は生存・UI のみ削除**: `messages/{msgId}` コレクションは REST 経由で今も読み書きされます（`markMessageRead` / `deleteMessage` などが `/messages/` を叩く）。一方で `MessagingDialog` の**画面 UI は削除済み**（後述 dead code）。「メッセージング削除」という記述と矛盾して見えますが、消えたのは UI で、データ層は残存しています。
> セキュリティ: チェックはクライアント側のみ。本番では Firestore Security Rules で `uploadRestricted` 等を再実装する必要がある（コメント `lib/providers/mind_map_provider.dart:193`）。Rules ファイルはリポジトリに含まれていません。

### 6. 課金のプラットフォーム分岐

`lib/services/billing_service.dart` がサブスクを抽象化。**Android/iOS/macOS は `purchases_flutter`（RevenueCat SDK）**、**Windows/Web は Stripe Web Purchase Link + RevenueCat v1 REST `/subscribers/{id}` で権限確認**。プロバイダには依存せず、`'free'`/`'pro'`/`'max'` の文字列を `onPlanChanged` コールバックで返す（循環 import 回避）。プロバイダ側は `applyBillingPlanByName` `:17876` で `SubscriptionPlan` enum に橋渡しし、`currentPlan` `:18132` が唯一のプラン解決点（開発者モード > 購入プラン > 有効クーポン > free）。

### 7. AI（Gemini ほか）

Gemini（`gemini-2.5-flash` / `gemini-2.5-pro`）を `generativelanguage.googleapis.com` REST で利用。モデル一覧は `generateContent` 対応モデルのみ抽出してキャッシュ（`refreshGeminiModels` `:17608`）。リクエスト/累積のトークン使用量を追跡し USD/JPY コストを算出（`calcCostUsd` `:15397`、`usdToJpy` `:15405`＝固定 170 円/USD）。**プラン別の AI 利用上限は無く**、AI は API キーの有無のみでゲートされます（唯一の例外は Max 限定の PDF/ファイル→マインドマップ要約 `lib/screens/mind_map_screen.dart:37147`）。

---

## プロジェクト構成

```
lib/
├── main.dart                          # エントリポイント。起動シーケンス、通知/タイムゾーン/ウィンドウ初期化、ルートProvider、MaterialApp
├── firebase_options.dart              # 手動メンテのFirebase設定（全フィールドがString.fromEnvironment）
├── models/
│   └── mind_map_node.dart             # 正規のデータモデル（MindMapNode / PdfMemo / TableData / NodeConnection / enums）
├── providers/
│   └── mind_map_provider.dart         # 巨大プロバイダ。状態の単一真実源（ツリー/AI/i18n/同期/カレンダー/課金/設定）。MindMapFolder・MindMapPageもここ
├── screens/
│   ├── mind_map_screen.dart           # 巨大スクリーン。MindMapScreen + _MindMapScreenState + 約200の支援クラス
│   ├── mind_map_node.dart             # ★孤立した重複モデル（dead code。後述）
│   └── messaging_dialog.dart          # ★UI DEAD（メッセージング画面は削除済み。データ層は残存／後述）
├── widgets/
│   ├── node_widget.dart               # LIVE。ノード描画+インタラクション（コールバック束）。URLユーティリティのstatic群
│   ├── connection_painter.dart        # LIVE。コネクション線(ベジェ)描画 + findConnectionヒットテスト
│   ├── google_search_dialog.dart      # LIVE。統合Google検索+メモUI（モーダル/フローティング）
│   └── node_detail_sheet.dart         # ★DEAD/orphan（ノード編集は画面内インラインに移行済み。未使用）
└── services/
    └── billing_service.dart           # LIVE。サブスク抽象化（RevenueCat SDK vs Stripe+REST のプラットフォーム分岐）
```

ネイティブ設定:
```
android/app/src/main/AndroidManifest.xml  # 権限(通知/exact-alarm/録音/前景サービス等)、MainActivity、各種Receiver
android/app/build.gradle                  # applicationId=com.kamispec.app、namespace=com.example.mindmap_app、targetSdk34、desugaring、google-services、署名/R8
windows/runner/main.cpp                   # Windowsランナー（1280x720）
windows/CMakeLists.txt                    # BINARY_NAME=mindmap_app
windows/flutter/generated_plugin_registrant.cc  # local_notifier/syncfusion/webview_windows 等を登録
pubspec.yaml                              # 依存とバージョンピンの根拠コメント（変更前に必読）
assets/fonts/                             # ★存在しない（NotoSansJP未配置。配置前にディレクトリ作成が必要。PDF日本語が豆腐になる。後述）
env.json                                  # ★API キー（git管理外）
```

### `mind_map_node.dart`（モデル）主要クラス

| 宣言 | 場所 | 役割 |
|---|---|---|
| `enum NodeContentType` | `lib/models/mind_map_node.dart:7` | ノード内容種別 `{none,memo,youtube,link,attachment,table}`。`.index` でシリアライズ（末尾追加のみ安全） |
| `class PdfMemo` | `:28` | PDF ページ（`pageNumber`+`xRatio/yRatio`）または訪問 URL（`url`+`scrollY`）へのアノテーション。色/フォルダ/ピン留め |
| `class TableData` | `:144` | テーブルノードのグリッド（`cells[row][col]`）。高さキャッシュは非シリアライズ。`fromJson` は不揃い行を補正 |
| `enum NodeAnchorMode` | `:465` | 接続方向数 `{twoWay,fourWay,eightWay}` |
| `enum AnchorDirection` | `:472` | 8 方向アンカー |
| `class NodeConnection` | `:493` | 有向エッジ（不変）。`==`/`hashCode` は `fromId`+`toId` のみで判定 |
| `class MindMapNode` | `:581` | コアノード。`visualHeight` `:738` が描画高の鍵（`node_widget.dart` の描画と同期必須） |

### プロバイダの主要リージョン（ナビゲーション）

| リージョン | 代表メソッド/getter | 場所 |
|---|---|---|
| ドキュメントツリー / ノード CRUD | `addPage` `:24864`, `addNodeAtCenterReturning` `:25500`, `connectNodes` `:26797`, `deleteNode` `:30089`, `moveNodes` `:30128`, `_loadFromStorage` `:24695`, `_saveToStorage` `:24815`, `_saveToStorageLocal` `:24841` | provider |
| AI / Gemini | `askAi` `:19688`, `askGemini` `:22057`, `aiGenerateChildren` `:22367`, `refreshGeminiModels` `:17608`, コスト `calcCostUsd` `:15397` | provider |
| i18n | `_translations` `:4317`, `t()` `:15360`, `setAppLanguage` `:4067` | provider |
| クラウド同期 | `_initFirebase` `:22785`, `_signInAnonymously` `:22841`, `_savePageToFirestore` `:23379`, `uploadToCloud` `:24325`, `_triggerAutoSync` `:3028` | provider |
| カレンダー | `addCalendarEvent` `:2116`, `uploadCalendarEventsToCloud` `:1706`, `downloadCalendarEventsFromCloud` `:1825`, `holidaysFor` `:1337` | provider |
| 課金 / プラン | `currentPlan` `:18132`, `applyBillingPlan` `:17888`, `applyCoupon` `:18267`, 上限 `monthlyUploadLimit` `:17945` | provider |
| 通知（状態のみ） | フォーカスロックスケジュール `:16350`（OS 通知配線は screen 側） | provider |

### スクリーンの主要クラス（抜粋）

| 分類 | クラス | 場所 |
|---|---|---|
| ルート/状態 | `MindMapScreen` / `_MindMapScreenState` | `lib/screens/mind_map_screen.dart:145` / `:365` |
| キャンバス描画 | `_GridPainter` `:56612`, `_RangeSelectionPainter` `:56667`, `_DecorationPainter` `:59822`, `_CutPreviewPainter` `:59747`, `_GroupBackgroundPainter` `:56357` | screen |
| ノードオーバーレイ | `_ActionOverlay` `:46783`, `_ConnectionActionOverlay` `:46365`, `_MultiNodeActionOverlay` `:59179` | screen |
| 動画/PiP | `_FullscreenVideoPage` `:50599`, `_PiPManager` `:65441`, `_WindowsPiPManager` `:65589`, `_BgPlaybackController` `:71809` | screen |
| YouTube | `_YoutubeSearchSheet` `:54934`, `_PlaylistExtractSheet` `:55203`, `_ChannelSettingsDialog` `:55543` | screen |
| PDF | `_InAppViewerDialog` `:73584`, `_InAppViewerPage` `:77168`, `_PdfMemoPanel` `:79184`, `_PdfExporter` `:95002` | screen |
| ドキュメント | `_SpreadsheetEditorDialog` `:84333`, `_DocxViewerDialog` `:95928`, `_PptxViewerDialog` `:87047`, `_TextEditorDialog` `:93275`, `_ImageEditorDialog` `:98933` | screen |
| ドロワー | `_DrawerTile` `:56157`, `_ReorderDropZone` `:56038`, enum `_FolderAction` `:55976` / `_PageAction` `:55990` / `_AddMenuAction` `:56011` | screen |
| フローティング | `_FloatingCalculator` `:60274`, `_FloatingStopwatch` `:60760`, `_FloatingPomodoro` `:68758`, `_FloatingWeather` `:69646` | screen |

### `lib/widgets/` と `lib/services/`

| ファイル | 状態 | 主要クラス / 補足 |
|---|---|---|
| `lib/widgets/node_widget.dart` | LIVE | `NodeWidget` `:32`（screen `:32707` から生成）。static URL ヘルパ `extractVideoId` `:142` / `parseTimestamp` `:162` / `isMp4Url` `:180` / `isImageUrl` `:209` / `thumbnailUrl` `:227`、`SnapTarget` `:17` |
| `lib/widgets/connection_painter.dart` | LIVE | `ConnectionPainter` `:4`、ヒットテスト `findConnection` `:37`（~14px 以内） |
| `lib/widgets/google_search_dialog.dart` | LIVE | `GoogleSearchDialog.show` `:56` / `showFloating` `:239`、ブックマーク永続化キー `mokumoku_gs_bookmarks_v1` `:3678`。**このウィジェットは独自に SharedPreferences を持つ**（ブックマーク・検索メモ等の `mokumoku_gs_*` 系キー）ので、検索 UI 周りの設定はプロバイダ側ではなくここを見ること |
| `lib/services/billing_service.dart` | LIVE | `BillingService` `:69`、`BillingPlanName` `:29`、`fetchPlanViaRest` `:272`（Windows） |
| `lib/widgets/node_detail_sheet.dart` | DEAD/orphan | `NodeDetailSheet` `:11`。どこからも import されない。編集は screen 内インライン |
| `lib/screens/messaging_dialog.dart` | UI DEAD | `MessagingDialog` `:9`。画面 UI は削除済み（`mind_map_screen.dart:17` にコメント）。データ層（`messages/` への REST 読み書き）は provider 側に残存 |

---

## プラットフォーム別の注意点

### WebView
- **モバイル**: `flutter_inappwebview`（import 別名 `iaw`）。**Windows/デスクトップ**: `webview_windows`（別名 `wv_win`）。`_isDesktop` でどちらを生成するか分岐。
- `webview_flutter` から `flutter_inappwebview` へ移行した理由は、MIUI/HyperOS の Pigeon チャネルエラーで `loadRequest` が壊れたため（コメント `lib/screens/mind_map_screen.dart:21`）。
- メディア/ビューア機能はほぼ全てモバイル版と Windows 版が二重実装。挙動変更時は **両方** を更新しないとプラットフォーム間で挙動が乖離します。

### 通知
- Android: `flutter_local_notifications ^17.2.4`（`zonedSchedule` で正確時刻通知。アプリ終了後も発火）。チャネルは 1 つ（`kNodeReminderChannelId = 'mokumoku_node_reminders'`、`lib/main.dart:20`）。
- Windows/デスクトップ: 17.x は Windows 非対応のため `local_notifier ^0.1.6`（WinToast）。`setup(shortcutPolicy: requireCreate)` でスタートメニューショートカット（AUMID）を作り、非 MSIX でもトースト可能。
- タイムゾーンは `Asia/Tokyo` 固定で初期化（`zonedSchedule` が `TZDateTime` を要求するため）。
- スケジューリングロジックは **すべて screen + main.dart** にあり、プロバイダには通知プラグインコードは無い。リマインダーの再アーム機構は無く、永続性は Android OS の保持とカレンダーイベントに依存。Android の通知タップハンドラ（`lib/main.dart:48`）はペイロードを `debugPrint` するのみでノードへ遷移しない。

### 課金
- Android/iOS/macOS: RevenueCat `purchases_flutter ^9.9.0`。リリースで `test_` キーが混入すると SDK が意図的にクラッシュするため、`configure` `lib/services/billing_service.dart:114` で `test_` キーを検出してスキップ。
- Windows/Web: SDK 非対応のため Stripe Web Purchase Link + REST 確認（`openWebPurchase` `:251`, `fetchPlanViaRest` `:272`, `pollPlanAfterWebPurchase` `:312`）。

### 動画 / バックグラウンド再生
- ローカル mp4/webm は `video_player ^2.9.1`（WebView の速度上限を回避し最大 16x）。
- 画面オフ継続再生は `audio_service ^0.18.16` + `just_audio ^0.9.40`（ダミー無音ハンドラで前景サービスを起動）。
- `wakelock_plus`、`permission_handler`（バッテリー最適化除外）、`android_intent_plus`（OEM 自動起動）でバックグラウンド再生を補強。

### 主要依存のバージョンピン根拠（`pubspec.yaml` コメント。**変更前に必読**）

| 依存 | ピン | 根拠 |
|---|---|---|
| `flutter_inappwebview` | `6.0.0`（厳密固定） | 6.1.x が Windows webview 実装に干渉するため固定 |
| `webview_windows` | `^0.2.2` | Windows 専用 WebView 実装（モバイルは inappwebview） |
| `syncfusion_flutter_pdfviewer` | `^28.1.37` | 全プラットフォームでネイティブ PDF 描画。`onPageChanged`/`jumpToPage` が必要（ページ紐付けメモの土台）。Windows で空白だった `pdfx` を置き換え |
| `device_info_plus` | `^11.0.0` | syncfusion pdfviewer + flutter_localizations(intl) が ^11 を要求 |
| `super_clipboard` | `^0.9.1` | device_info_plus ^11 整合のため 0.8.x から引き上げ |
| `local_notifier` | `^0.1.6` | FLN 17.x の Windows 非対応を補う OS トースト |
| `flutter_local_notifications` | `^17.2.4` | Android リマインダー。`zonedSchedule` が成熟 |
| `timezone` | `^0.9.4` | `TZDateTime` 用に明示ピン |
| `video_player` | `^2.9.1` | ローカル動画を最大 16x 再生（WebView の制限回避） |
| `wakelock_plus` | `^1.2.5` | 動画/タイマー中に画面・CPU を維持し Android の onStop を回避 |
| `permission_handler` | `^11.3.1` | バッテリー最適化除外画面を開く（Doze 下の安定再生） |
| `android_intent_plus` | `^5.1.0` | OEM 別の自動起動インテント（Xiaomi/Samsung/Huawei/Oppo） |
| `audio_service` / `just_audio` | `^0.18.16` / `^0.9.40` | 画面オフ継続再生 + ロック画面コントロール |
| `purchases_flutter` | `^9.9.0` | RevenueCat（モバイル）。Windows/Web は Stripe+REST に分岐 |
| `speech_to_text` | `^7.0.0` | 音声入力。Windows はビルドはできるが認識は不可フォールバック |
| `pdf` | `^3.11.1` | docx/pptx → PDF 書き出し（日本語は NotoSansJP 必須） |
| `csv` / `excel` / `archive` | `^6.0.0 / ^4.0.6 / ^3.6.1` | CSV/TSV、xlsx 読み書き、pptx/docx の zip+xml 解析 |
| `youtube_explode_dart` | `^2.4.2` | YouTube ダウンロード（マニフェスト + muxed ストリーム保存） |

---

## 既知の注意点

- **重複モデルファイル**: `lib/screens/mind_map_node.dart` は `lib/models/mind_map_node.dart` のほぼ同一の孤立コピーで、**どのファイルからも import されていません**（grep で参照 0 件、しかも内容は古くわずかに乖離）。実モデルは `lib/models/` 版。編集は `models/` 版のみ行い、`screens/` 版は dead code として扱うこと。
- **build_runner 未使用**: `json_serializable` / `build_runner` は dev 依存にあるが `.g.dart` もコード生成も無い。`build_runner` で配線が生成されると期待しないこと。`toJson`/`fromJson` は手書きで後方互換に追加する。
- **NotoSansJP 未配置で PDF の日本語が豆腐（□）になる**: `assets/fonts/` ディレクトリは**存在せず**、`pubspec.yaml`（200–201 行付近）の `assets:` 宣言はコメントアウト済み。`_loadJapaneseFont()` `lib/screens/mind_map_screen.dart:95010` はフォント読み込みに失敗すると一度だけ警告して null を返し、PDF 内日本語が □ で描画される（クラッシュはしない）。修正するには `assets/fonts/` ディレクトリを作成して OFL の `NotoSansJP-Regular.ttf` を置き、かつ該当 `assets:` 行のコメントを外す。**ファイルを置かずに宣言だけ有効化すると `flutter build` が失敗する** ので注意。
- **巨大ファイルは丸読み禁止**: `mind_map_provider.dart`（特に `_translations` の 4317–15347 行と AI 生成の 19626–22655 行）と `mind_map_screen.dart` は大きすぎるため、`^class `/`^enum `・メソッド名・`t('` キーを Grep して目的箇所へジャンプすること。
- **dead code**: `lib/widgets/node_detail_sheet.dart`（実際のノード編集は screen 内インライン実装に移行済み）と `lib/screens/messaging_dialog.dart`（メッセージング**画面**は削除済み。ただし `messages/` のデータ層は provider に残存）は未使用。`lib/screens/mind_map_screen.dart:17` に削除コメントあり。
- **Google カレンダー連携は削除済み**: `gcal*` 系の getter/メソッドは後方互換の no-op スタブ（`gcalIsAuthenticated` 常に false）。`if (gcalIsAuthenticated)` 分岐はすべて dead。`CalendarEvent.googleId` は旧データ読み込み用に残存。
- **env.json は機密**: 作業ツリーに実キーが含まれることがある。コミット/プッシュ前に `.gitignore` で除外されていることを必ず確認すること。
- **`com.example.*` の名残**: `applicationId` は `com.kamispec.app` だが、Android namespace（`android/app/build.gradle`）は `com.example.mindmap_app`、`FIREBASE_IOS_BUNDLE_ID` の既定値も `com.example.mindmapApp`。`com.example.*` は Play ストア公開のブロッカーなので、公開前に整理が必要。
- **AI コスト計上の不整合**: `askGemini` `:22178` は `_pricing`/`calcCostUsd` を使う正規パスだが、別の AI プロバイダのパス（OpenAI `askOpenAi:21803`＝$0.15/$0.60、Claude `askClaude:22031`＝$1.0/$5.0）はトークン単価をハードコードしており、正規パスと算出方式が不一致。`usdToJpy` `:15405` は固定 170 円/USD（為替レートではない）。
- **テストスイートは実質空**: `test/widget_test.dart` は標準カウンタテンプレートのままで、このアプリと一致せず、そのまま実行すると失敗する。
