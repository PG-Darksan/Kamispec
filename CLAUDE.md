# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Flutter mind-map application ("Kamispec" / "MokuMoku") targeting **Android and Windows desktop** (iOS/macOS/Linux/Web have partial config). Far beyond a basic mind map: it embeds YouTube and local video playback, an in-app PDF viewer with page-anchored memos, document viewers/editors (docx/xlsx/pptx/csv/txt), Gemini-powered AI node/map generation, speech-to-text, OS notifications/reminders, a shared cloud calendar, group sync/messaging, and RevenueCat/Stripe subscriptions. Code comments and UI strings are primarily in **Japanese**.

The codebase is dominated by **two enormous files** — `lib/providers/mind_map_provider.dart` (~30.6k lines, all state) and `lib/screens/mind_map_screen.dart` (~101.5k lines, all UI). Almost everything you need is in one of these. NEVER read either whole; use the navigation maps below and Grep by class/method name. Every *other* file under `lib/` is small and single-purpose; the layout exceptions to that rule are the two big files plus three dead files (see Gotchas).

## Commands

```bash
flutter pub get                                                  # install deps
flutter run --dart-define-from-file=env.json                     # debug run
flutter analyze                                                  # lint (flutter_lints ^3)
flutter test                                                     # run all tests (effectively empty — see note)
flutter test test/widget_test.dart                               # run a single test file
flutter build apk --release --dart-define-from-file=env.json     # Android release
flutter build windows --release --dart-define-from-file=env.json # Windows release
```

**`--dart-define-from-file=env.json` is required for any build/run that touches Firebase, Gemini, or billing.** `env.json` holds all API keys and is git-ignored (never commit it). Keys are read at **compile time** via `String.fromEnvironment(...)` — there is no runtime `.env` loading. Without it, Firebase/AI/sync features degrade gracefully (the app still launches).

> Note: `test/widget_test.dart` is the stock Flutter counter-test template and does **not** match this app — it will fail if run as-is. Treat the test suite as effectively empty.

## Architecture

### State: one giant provider
The entire app state lives in **`lib/providers/mind_map_provider.dart`** (`MindMapProvider extends ChangeNotifier`, ~30.6k lines). It is installed once at the root in `lib/main.dart` via `ChangeNotifierProvider` and is the single source of truth for: the document tree, AI settings/usage tracking, i18n, cloud sync, calendar, billing plan, focus-lock schedules, and feature toggles. New cross-cutting state almost always belongs here. It persists to **`SharedPreferences`** (local, eager per-setting writes) and mirrors selected data to **Firestore via the REST API** (see Cloud sync below).

### Data model hierarchy (Folder → Page → Node)
The tree is split across two files:
- **`MindMapFolder`** (`mind_map_provider.dart:143`) → **`MindMapPage`** (`mind_map_provider.dart:176`) → **`MindMapNode`** (`mind_map_node.dart:581`). Folders are flat (no nesting) and group pages; pages hold a `Map<String,MindMapNode> nodes` + `List<NodeConnection> connections` + `List<MapDecoration> decorations`.
- `MindMapNode` carries content via `NodeContentType` (`none`/`memo`/`youtube`/`link`/`attachment`/`table`) plus `PdfMemo`s, `TableData`, and `NodeConnection`s. Additional persisted fields worth knowing (all hand-serialized): `isContainer` (`:610`) + `containedNodeIds` + `hiddenInContainer` (storage/格納 node, Ctrl+G — see Container nodes), `linkedPageId` (`:630`, makes the node a tappable link to another page — see Submap navigation), `pdfMemoFolders` (`:640`, named PDF-memo folders), `attachmentAspectRatio` (`:655`, original image aspect ratio used by `node_widget` draw math).
- Its `visualHeight` getter (`mind_map_node.dart:738`) is THE derived draw height and **must be kept in sync with `node_widget.dart` draw logic**.
- **All JSON serialization is hand-written** (`toJson`/`fromJson` on each class) and **defensive** (reads via `as num?`, `?? default`, index bounds-checks). Although `json_serializable`/`build_runner` are dev dependencies, there are **no `.g.dart` files and no codegen step** — do not run build_runner expecting it to wire things up; add `toJson`/`fromJson` by hand and keep them backward-compatible.

### UI: one giant screen
**`lib/screens/mind_map_screen.dart`** (~101.5k lines) is `MindMapScreen` + a ~45k-line `_MindMapScreenState` (lines 365–45736, `with WidgetsBindingObserver` — lifecycle handlers like `didChangeAppLifecycleState` `:3418` live here, used for app-pause/resume + focus-lock checks) plus **~190 private widgets/painters/data classes** (everything from 45737 → EOF). Most interactive features are implemented as private classes within this single file. Supporting widgets that *are* split out live in `lib/widgets/` (`node_widget.dart`, `connection_painter.dart`, `google_search_dialog.dart`) and `lib/services/billing_service.dart`.

### i18n
Custom, not ARB/`gen_l10n`. Translations are a `static const Map<String, Map<String,String>>` (`_translations`, `mind_map_provider.dart:4317`, ~11k lines, ~1149 keys) keyed `dottedKey → {langCode → string}`. Look up strings with **`provider.t('some.key')`** (`mind_map_provider.dart:15360`), whose fallback chain is **`_appLanguage → 'en' → 'ja' → key`** (note: en before ja; unknown keys pass through verbatim). 30 supported languages (`supportedLanguages`, `:3827`); only 9 are fully translated (`_fullyTranslatedLanguages`, `:3901`) — the other 21 are BETA and surface English (never raw keys). Add UI strings by adding keys to `_translations`, not `.arb` files.

### Firebase / Cloud sync
Uses the **Firestore REST API directly over `package:http`** (`https://firestore.googleapis.com/v1/...`) — the `cloud_firestore` plugin is **not** used. Anonymous auth via Identity Toolkit; Storage via the Storage REST API. Helpers `_firestoreStr` (read, `:23372`), `_normalizeFields` (write, `:2829`), and `_firestoreBaseUrl` (`:2534`) wrap the REST field-encoding. `lib/firebase_options.dart` is hand-maintained to read keys from `--dart-define` (do **not** blindly regenerate with `flutterfire configure` — it overwrites the env-var wiring). Sync is organized around a `_syncGroupId` (an 8-char shared "group" code for pages/calendar/messaging across users). All access control is **client-side only**; the code repeatedly warns that production must enforce the same rules in Firestore Security Rules (no `.rules` file is in-repo).

### Billing
`lib/services/billing_service.dart` abstracts subscriptions and deliberately does **not** import the provider — results flow back as plain plan strings (`'free'`/`'pro'`/`'max'`) via an `onPlanChanged` callback (the provider hooks it to `applyBillingPlanByName`). **`purchases_flutter` (RevenueCat SDK) on Android/iOS/macOS**; a **Stripe Web Purchase Link + RevenueCat REST entitlement check on Windows/Web** (the SDK is unsupported there). This split mirrors the pervasive desktop guards.

### AI
Gemini (`gemini-2.5-flash` / `gemini-2.5-pro` and dynamically-listed variants) via `generativelanguage.googleapis.com` REST. **BYOK: the Gemini key is user-entered only** (prefs `gemini_api_key`, set in-app); the build-time `GEMINI_API_KEY` dart-define fallback and the developer "global key" auto-injection were **removed** (anti-extraction — each user supplies their own key). `_effectiveGeminiKey` returns the user key only. Multi-provider capable (`gemini`/`openai`/`anthropic`/`grok`/`deepseek`) but Gemini is the default and canonical path. The provider tracks per-request and cumulative token usage and computes USD/JPY cost (`calcCostUsd` `:15397`, `usdToJpy` `:15405`, fixed 170 JPY/USD). There is **no per-plan AI quota** — AI is gated only by API-key presence (`hasActiveAiKey` `:3794`); the one plan-gated AI feature (Max-only PDF/file→mindmap) is enforced in the screen.

### Calendar
A shared cloud calendar lives entirely in the provider (no separate service): `CalendarEvent` model + per-user Firestore docs at `groups/{gid}/calendar/{uid}`. Google Calendar integration was fully **removed** — all `gcal*` methods are no-op stubs (`gcalIsAuthenticated` always false). Calendar UI is private widgets in the screen.

### Notifications / reminders
**No notification-plugin code exists in the provider.** All scheduling/cancellation is in `lib/main.dart` (plugin init) + `lib/screens/mind_map_screen.dart`. Android uses `flutter_local_notifications` (`zonedSchedule`, exact alarms, single channel `mokumoku_node_reminders`); Windows/desktop uses `local_notifier` toasts fired by in-memory `Timer`s. The provider only owns the calendar events reminders are derived from. There is no reminder re-arming on launch (durability comes from the Android OS alarm + the calendar entry).

### Container nodes (格納ノード, Ctrl+G)
Multiple selected nodes can be collapsed into a single representative "container" node. `createContainerFromNodes` (`mind_map_provider.dart:27350`) sets `hiddenInContainer = <containerId>` on each member (hiding it and suppressing its connections) and leaves a node with `isContainer = true` + `containedNodeIds`. `unpackContainer` (`:27394`) dissolves it (clears `hiddenInContainer`, deletes the container). The keyboard command id is `containerize` (default Ctrl+G).

### Submap embedding / linked-page navigation
A node with `linkedPageId` set (model field `mind_map_node.dart:630`) acts as a tappable link to another page (an embedded submap). The screen keeps a browser-style history stack `_navHistory` (`mind_map_screen.dart:434`) + `_navIndex` (`:435`); `_navigateToPage(pageId, {suppressPush})` (`:10240`) pushes/navigates, and Alt+Left / Alt+Right go back/forward. Embed/open handlers are around `:10232`–`:10380` and `:29081`.

### Keyboard-shortcut subsystem (customizable + per-command on/off)
A sizable region of the screen. `_commandDefs` (`mind_map_screen.dart:44849`) is a `static const` list of ~60 commands (`{id, labelKey, defaultKey, fixedSuffix?}`); `_fixedCommands` (`:44965`) marks the non-rebindable ones. `_customKeyBindings` (`:44974`) holds user overrides but is **session-only — NOT persisted**. `_disabledShortcuts` (`:1752`, a `Set<String>`) is the per-command on/off set and IS persisted (prefs `disabled_shortcuts`, via `_loadDisabledShortcuts` `:1929` / `_persistDisabledShortcuts` `:1945`). Resolution: `_commandForKeyCombo` (`:41077`) maps a combo to an id, honoring aliases (`ctrl+shift+z → redo`, `:41088`) and skipping disabled ids; global arrows go through `_handleMainGlobalArrowKey` (HardwareKeyboard handler, `:2274`, added `:2187` / removed `:3376`). Reserved/fixed combos include Ctrl+K=lockH, Ctrl+L=lockV (`:44949`/`:44950`), Ctrl+1〜9=switchMap, and Ctrl+Shift+Z as a redo alias. The shortcut-editor dialog is ~`:45010`–`:45680`.

### Platform-specific code is everywhere
Because Android and Windows differ substantially (WebView impl, notifications, billing, video, speech), the code is full of `if (Platform.isWindows)` / `if (Platform.isAndroid)` / `_isDesktop` branches and platform-specific plugins (e.g. `flutter_inappwebview` for mobile vs `webview_windows`; `flutter_local_notifications` on Android vs `local_notifier` on desktop). Nearly every media/viewer feature exists **twice** (a mobile class and a `_Windows…` twin) — when changing behavior, update both or platforms diverge. The `pubspec.yaml` dependency comments document many version pins and their reasons. **Read those comments before changing dependency versions.**

---

## NAVIGATION MAP — `lib/providers/mind_map_provider.dart` (~30,635 lines)

One `MindMapProvider extends ChangeNotifier` (line 1072 → EOF) plus ~21 small top-level model/enum/helper classes (lines 19–1070). Constructor at **22727** fires ~25 fire-and-forget `_load*` calls. Two huge gaps are effectively dividerless: **4317–15359** (the `_translations` map, zero `// ───` dividers) and **19626–22655** (AI generation — its only `// ───` divider is the section header at its start, `:19626`; the body has none). Navigate by grepping `^class `/`^enum `, method signatures, or the `// ───`/`// ═══` section dividers.

### Top-level model/helper classes (before the provider)
| Symbol | Line | Purpose |
|---|---|---|
| `CalendarEvent` | 19 | Calendar entry; group-share via `ownerUid`/`ownerName`, legacy `googleId`. `isOthersEvent()` at 50. |
| `FocusLockSchedule` | 80 | Recurring auto-lock window: `startMin`/`endMin` (min-of-day, start>end=overnight), `days` set (1=Mon..7=Sun, empty=daily). |
| `CalendarMemberInfo` | 121 | Cached group member (uid/displayName/plan/allowSharing); `isProOrAbove` at 135. |
| `MindMapFolder` | 143 | Flat page-grouping folder: id, name, expanded, `linkedDirPath` (disk auto-export). |
| `MindMapPage` | 176 | One page: nodes map, connections, decorations, background image, folderId, uploadRestricted; legacy `parentId`→connection migration in fromJson (312). |
| `MapDecorationKind` (enum) | 336 | line/arrow/rectangle/ellipse/wavyLine/filledRectangle/circle/hollowCircle. |
| `MapDecoration` | 356 | Shape: kind, start/end Offsets, colorRgb, strokeWidth, text, text anchor. |
| `ChannelVideoQueue` | 452 | YouTube channel auto-refill queue. |
| `_PageSnapshot` (private) | 458 | Undo/redo snapshot; deep-copies nodes via `copyWith()`. |
| `AiMapResult` | 506 | AI map-gen result: pageIndex, rootId, rootPosition, addedToCurrentPage. |
| `PausedExplainSession` | 543 | Paused comprehensive-explain state for resume. |
| `_UrlSlot` (private) | 608 | Helper for `_validateUrlsInStructure`. |
| `_AttachmentKind` (enum) | 619 | image/video. |
| `_AttachmentToUpload` (private) | 621 | One upload job for `_uploadPageAttachments`. |
| `AiPageContext` | 643 | Per-page AI source context for follow-up Q&A. |
| `AiQAEntry` | 670 | One AI Q&A turn. |
| `SubscriptionPlan` (enum) | 690 | `free`/`pro`/`max` (no `developer`/`coupon` — those are flags/labels). |
| `_DisplayNameRequiredException` / `_UploadRestrictedException` | 694 / 713 | Detect via top-level `isDisplayNameRequiredError` (702) / `isUploadRestrictedError` (721). |
| `PdfHighlightLine` / `PdfHighlight` | 946 / 984 | PDF marker persistence (per-line rects + color); prefs key `pdfHighlights`. |
| `GoogleSearchMemo` | 1035 | Memo from Google-search dialog. |

Also top-level (not classes): `nextSequenceTitle` (824) + sequence tables `_kanjiDigit`/`_romanNumerals`/`_hiraganaTable`/`_katakanaTable` (739/776/784/798).

### `MindMapProvider` feature regions
| Region | Lines / key methods |
|---|---|
| **Constructor / startup load** | ctor **22727** (fires ~25 `_load*`; only `_loadFromStorage` chains `.then` → `_restoreLastOpenedPage` + thumbnails) |
| **Document tree — getters** | `pages` 22639, `currentPage` 22641, `nodes` 22642, `selectedNode` 22652 |
| **Pages** | `addPage` 24864, `switchPage` 24876, `renamePage` 24910, `deletePage` 24917, `reorderPages` 24984 |
| **Folders** | `addFolder` 25007, `setFolderLinkedDir` 25020, `syncFolderToLinkedDir` 25110, `deleteFolder` 25192, `movePageToFolder` 25272 |
| **JSON export/import** | 25337–25638 |
| **Node CRUD** | `addNodeAtCenterReturning` 25500, `connectNodes` 26797, `addChildrenWithCount` 26881, `addParentToNodes` 27016, `createContainerFromNodes` 27350, `unpackContainer` 27394, `updateNodeTitle` 27929, `updateNodePosition` 28236, `updateNodeMemo` 28621, `updateNodeYoutube` 28744, `updateNodeLink` 28809, `updateNodeColor` 28937, table nodes 28955–29137, `deleteNode` 30089, `deleteNodes` 30114, `moveNodes` 30128, `copyNodesToPage` 30165, `pasteNodes` 30264 |
| **Persistence (local)** | `_loadFromStorage` 24695 (folders 24737, fallback v2→v3), `_saveToStorage` 24814 (writes `mindmap_pages_v3` + triggers autosync), `_saveToStorageLocal` 24841 (no-cloud, used on receive) |
| **Auto-layout / alignment** | 25837–26875 (`autoLayoutTree` 25850) |
| **Named groups (付箋)** | `arrangeGroup` 27243, `setNamedGroup` 27290, `splitNamedGroup` 27461 (27145–27878) |
| **AI settings / providers** | keys 3662–3804 (Gemini 3692, OpenAI/Claude 3709, Grok/DeepSeek 3737, `aiProvider` 3780, `hasActiveAiKey` 3794) |
| **AI model lists** | `initializeAvailableModels` 17518, `refreshGeminiModels` 17608, fallback lists 17421, `_geminiModels` 17444, `_effectiveGeminiKey` 17762 |
| **AI generation (dividerless body, 19626–22655)** | `_beginAi/_endAi/cancelAi` 19647–19668, `askAi` 19688, `askAiForJson` 19714, `_buildAiStructurePrompt` 19902, `_buildPageFromAiStructure` 20010, `summarizeFileToNewPage` 20206, `explainConceptToNewPage` 20352, `_explainConceptComprehensive` 20435, `resumeExplainConcept` 20649, `askAiFollowUpForPage` 21020, per-provider `askOpenAi` 21709/`askGrok` 21927/`askDeepseek` 21941/`askClaude` 21956/`askGemini` 22057, `_askAiAboutNode` 22249, `aiExplainNode` 22320, `aiGenerateChildren` 22367, `aiCustomPrompt` 22532; AI quiz 29152–29950 |
| **AI usage / cost** | fields 15366–15394 (`aiDepth`/`aiChildMin..`), `_loadAiSettings` 15416, `calcCostUsd` 15397, `usdToJpy` 15405, `formatCost` 15408, `_saveUsageTotals` 15441, `resetUsageTotals` 15449 |
| **i18n** | `_translations` map **4317** (→15359, never read whole), `t()` **15360**, `appLanguage`/`setAppLanguage` 4066/4067, `supportedLanguages` 3827, `isFullyTranslated` 3904, `languageInstructionForAi` 4310, locale URL/STT helpers 3944–4253 |
| **Cloud sync (Firestore REST)** | env 2495–2561, `_initFirebase` 22785, `_signInAnonymously` 22841, `_ensureFreshToken` 22897, `createGroup` 22914, `joinGroup` 22933, `setActiveGroup` 22958, `_registerMember` 23011, `_cleanupGroupIfEmpty` 23059, `_writeGroupMeta` 23280, `_savePageToFirestore` 23379, `uploadToCloud` 24325, `fetchCloudPageList` 24448, `downloadFromCloud` 24524, `_triggerAutoSync` 3028, `pruneExpiredCloudData` 23175 |
| **Cloud storage (attachments)** | `uploadAttachmentToStorage` 23663, `_uploadPageAttachments` 23910, `_downloadPageAttachments` 24109 |
| **Calendar** | model+state 19–137 / 1106–2493, `eventsOn` 1175, `holidaysFor` 1337, `_pushCalendarUndo` 1627, `uploadCalendarEventsToCloud` 1706, `downloadCalendarEventsFromCloud` 1825, `addCalendarEvent` 2116, `removeCalendarEvent` 2167, `updateCalendarEvent` 2196, `_saveCalendarEvents`/`loadCalendarEvents` 2326/2337, gcal stubs 2357–2490, sharing toggle 2703 |
| **Messaging / inquiries** | `sendMessage` 2785, `fetchMyMessages` 2843, `markMessageRead` 2936, `deleteMessage` 2958, `sendInquiry` 19217 (daily limit `kInquiryDailyLimit`=5), admin settings 18999/19047 |
| **Billing / plan** | `SubscriptionPlan` 690, `proSubscribed` 17832, `purchasedPlan` 17838, `_billing` ctor 17843, `applyBillingPlanByName` 17876, `applyBillingPlan` 17888, **`currentPlan` 18132** (THE resolution point), `isProUnlocked`/`hasUnlimitedPages` 18144, `canCreateNewPage` 18154, `canUseSplitView` 18173, `_loadProState` 18194, coupons `applyCoupon` 18267 / `hasActiveCoupon` 18093, `setDevImpersonatePlan` 18115, `currentPlanLabel` 18849, `_syncPlanToUserDoc` 18859, license restore 18613/18689, dev mode 18955 |
| **Usage quotas (cloud)** | limits `monthlyUploadLimit` 17945, `monthlyDownloadLimit` 17957, `totalStorageLimit` 17973; checks `canUseStorageBytes` **17991**, `canUseUploadBytes` **18009**, `canUseDownloadBytes` **18013**, recorder `recordUploadBytes` **18042** (cloud-path call sites at ~23682/23692/23766/23835) |
| **Focus-lock schedules** | settings 16278–16391, `focusLockSchedules` 16350, `addFocusLockSchedule` 16363, `_persistFocusLockSchedules` 16354 (OS wiring is in the screen) |
| **PDF highlights / memos** | `getPdfHighlights` 16020, `_savePdfHighlights` 16048, `addPdfMemoAsNode` 17067, folder ops 16780+ |
| **Settings / toggles** | video/channel 3174–3572, speech 4106, theme/PDF/UI 15918–16278 (`splitMode` 15918, `isDarkMode` 15937, `openLinksInApp` 16228, `pasteImageScalePercent` 16250), custom toolbars 15761–15935 & 17175–17452, page visibility/favorites/shuffle 28468–28621 |

---

## NAVIGATION MAP — `lib/screens/mind_map_screen.dart` (~101,510 lines)

`MindMapScreen` (145) + `_MindMapScreenState` (**365 → 45736**, `with WidgetsBindingObserver`, the ~45k-line god-state) + ~190 private classes (45737 → EOF). To find a method/builder *inside* `_MindMapScreenState`, Grep its name within 365–45736 — its hundreds of `Widget _buildX(...)` methods and handlers are NOT separate top-level classes. Classes are grouped by feature below.

### Top-level (file-scope) functions
| Symbol | Line | Notes |
|---|---|---|
| `computeCanvasSize` | 127 | Fixed square canvas size from node bounds |
| `_splitBtnTooltip` | 162 | Split-button tooltip text |
| `_expandRoutineDates` | 62561 | Expand a routine pattern into concrete dates |
| `_showRoutineCopyDialog` | 62609 | Calendar routine-copy dialog |

### Core state & canvas interaction (inside `_MindMapScreenState`)
| Symbol / concern | Line | Notes |
|---|---|---|
| `_MindMapScreenState` | 365 | God-state (`with WidgetsBindingObserver`; lifecycle hook `didChangeAppLifecycleState` 3418) |
| `_kAnchorSnapDist` | 143 | 28.0 anchor snap threshold |
| `_controllers` / `_ctrlFor` | 367 / 3462 | Per-page `TransformationController` cache |
| `_canvasKey` | 376 | GlobalKey; basis for `_globalToCanvas`/`_canvasToGlobal` (3979/3989) |
| `_navHistory` / `_navIndex` | 434 / 435 | Submap browser-history stack (Alt+Left/Right) |
| `_lockH` / `_lockV` | 589 / 590 | Axis locks (Ctrl+K / Ctrl+L) |
| `_pauseViewer` getter | 681 | Disables pan/zoom during node/range/decoration drag or split-panel hover |
| `_baseScale` / `_kDefaultScale` | 3453 | 0.9375 desktop / 0.50 mobile |
| `_onTransformChanged` | 3473 | Enforces axis/scale locks; syncs `_scalePercent` |
| `_navigateToPage` | 10240 | Push/navigate submap pages (`suppressPush` for history nav) |
| `_handleCutClick` | 3714 | Two-click cut: severs crossed connections + splits groups |
| node move handlers | `_onLongPressNodeStart` 4000 / `Move` 4020 / `End` 4379; `_detectAnchorSnap` 4671 |
| `_showActionButtons` | 10464 | Builds the per-node `_ActionOverlay` |
| `_onConnectionTap` | 14097 | Hit-test/select connections (uses `ConnectionPainter.findConnection`) |
| `_showCanvasContextMenu` / `_showNodeContextMenu` | 14150 / 14701 | Desktop right-click menus (custom OverlayEntry, not `showMenu`) |
| `_startInlineTitleEdit` | 16041 | Double-tap title editor |
| decoration hit-test / handles | `_decorationHitTest` 20413, `_buildDecorationHandles` 20486 |
| `_buildCanvas` / `_buildCanvasInner` | 32019 / 32145 | `InteractiveViewer.builder` at 32153 (minScale 0.15, maxScale 3.0, boundaryMargin 0) |
| Stack painter z-order | 32468 | grid→group bg→connections→decorations→cut→nodes→group fg→range rect |
| raw `Listener` (range/cut/move) | 27946 | Shift+drag range, cut clicks, group-drag (commit at 28090) |
| `NodeWidget` wiring | 32707 | onTap/doubleTap/longPress*/rightClick/sizeChanged per node |
| `_showBulkEditSheet` / `_showBulkAISheet` | 42146 / 42161 | Over `_rangeSelectedIds` |

> Connections are created **implicitly by anchor-snapping on drop** (`provider.connectNodes`), not by a draw-wire gesture. Node creation uses `provider.addNodeAtCenter[Returning]` (~20 call sites); there is no `_addNode` method.

### Split view / WebView / resize chrome
| Symbol | Line |
|---|---|
| `_SplitPosition` (enum) | 156 |
| `_ResizeHandle` / State | 175 / 188 |
| split methods (`_setSplitOpen` 728, `_splitLoadUrl` 1988, `_splitLoadLeftPdf` 991, `_splitOpenLocalPdf` 2104, `_openOfficeInSplitPanel` 1477, `_swapSplitPanels` 1095, split PDF page-change 24897/24932) | inside state |
| `_SplitPdfHorizontalScrollBar` / State | 45737 / 45753 |
| `_SplitWindowsWebView` / State | 84077 / 84099 |
| `_GroupResizeHandle` / State | 59708 / 59716 |

### Header / bookmarks / toolbar / context-menu primitives
| Symbol | Line |
|---|---|
| `_BookmarkButton` (data model, not widget) | 281 |
| `_HeaderCustomButtonsBar` | 47158 |
| `_ReorderableHeaderIcon` / State | 47233 / 47249 |
| `_GroupMenuBtn` / `_Btn` / `_ToolBarBtn` | 47478 / 47512 / 47569 |
| `_CtxMenuItem`/State, `_CtxMenuToggle`/State, `_CtxFontSizeRow`/State | 47632/47647, 47687/47704, 47754/47771 |
| `_ChannelModeBtn` / `_PomodoroBtn` / `_HourlyScrollBtn` / `_RadioRow` | 55917 / 69602 / 71561 / 62940 |

### Overlays & dialogs (node/connection/group/AI/inquiry)
| Symbol | Line |
|---|---|
| `_InlineTitleDialog` / State | 45856 / 45881 |
| `_GroupNameInputField` / State | 46330 / 46343 |
| `_ConnectionActionOverlay` / State | 46365 / 46397 |
| `_ActionOverlay` / State (per-node action bar) | 46783 / 46827 |
| `_MultiNodeActionOverlay` | 59179 |
| `_AiOptionTile`, `_AiCountSelector` / State | 47320, 47358 / 47371 |
| `_BulkEditSheet` / State, `_BulkAISheet` / State | 58354 / 58367, 58764 / 58779 |
| `_InquiryDialog` / State, `_DevInboxDialog` / State, `_DevHistoryInlineView` / State | 57368 / 57375, 58046 / 58053, 59327 / 59334 |

### Drawer (folder/page tree)
The drawer is built by `_MindMapScreenState` methods (`_buildDrawer` 30161, wired at Scaffold `drawer:` 27852), not a class. Support classes:
| Symbol | Line |
|---|---|
| `_DrawerPageDragData` | 55964 |
| `_FolderAction` / `_PageAction` / `_AddMenuAction` (enums) | 55976 / 55990 / 56011 |
| `_DrawerFlatItemKind` (enum) / `_DrawerFlatItem` | 56022 / 56026 |
| `_ReorderDropZone` / State | 56038 / 56053 |
| `_DrawerTile` | 56157 |
| menus: `_showDrawerAddMenu` 31087, `_showFolderContextMenu` 31259, `_showPageContextMenu` 31639 | inside state |

### Canvas painters
| Symbol | Line |
|---|---|
| `_GroupBackgroundPainter` / `_GroupBounds` / `_GroupForegroundPainter` | 56357 / 56549 / 56567 |
| `_GridPainter` | 56612 |
| `_RangeSelectionPainter` | 56667 |
| `_CutPreviewPainter` | 59747 |
| `_DecorationPainter` | 59822 |
| `_TimezoneMapPainter` | 60064 |
| `_CreateTableGridPainter` | 84012 |
| `_AnnotationPainter` / `_DiagonalSlashPainter` (image editor) | 99908 / 99947 |

### Video playback / download / PiP / background audio
| Symbol | Line |
|---|---|
| `_openFullscreenVideo` (dispatcher) | 12051 |
| `_DownloadedVideosStore` (prefs `downloaded_videos_v1`) | 50386 |
| `_VideoMemoEntry` / `_VideoMemoHistoryStore` (prefs `video_memo_history_<id>`) | 50492 / 50553 |
| `_FullscreenVideoPage` / State (mobile; local mp4 via `video_player`, YT via iaw WebView) | 50599 / 50635 |
| `_downloadCurrentVideo` (mobile) / `_downloadCurrentVideoWin` | 52220 / 48451 |
| `_PiPManager` / `_WindowsPiPManager` | 65441 / 65589 |
| `_PiPMiniPlayer` / State, `_WindowsPiPMiniPlayer` / State | 66386 / 66418, 65747 / 65784 |
| `_BackgroundAudioHandler` / `_BgPlaybackController` (audio_service + just_audio) | 71623 / 71809 |

### YouTube search / playlist / channels (HTML scrape of m.youtube.com)
| Symbol | Line |
|---|---|
| `_YoutubeSearchSheet` / State, `_WindowsYoutubeSearchSheet` / State | 54934 / 54953, 56720 / 56740 |
| `_PlaylistExtractSheet` / State, `_WindowsPlaylistExtractSheet` / State | 55203 / 55218, 56971 / 56988 |
| `_ChannelSettingsDialog` / State | 55543 / 55550 |
| `_YoutubeNavHistory` (prefs `mokumoku_youtube_nav_history_v1`, max 3) | 95664 |
| `_WindowsWebViewSheet` / State (desktop fullscreen video/browse) | 47884 / 47923 |

### PDF viewer (syncfusion) + page-anchored memos & highlights
| Symbol | Line |
|---|---|
| `_InAppViewerDialog` / State (desktop), `_InAppViewerPage` / State (mobile) | 73584 / 73609, 77168 / 77191 |
| `_addHighlightForSelection` (HighlightAnnotation, version-drift via `dynamic`) | 75160 |
| `_PdfMemoPanel` / State | 79184 / 79221 |
| `_PdfMemoTile`, `_PdfMemoEditDialog` / State | 82470, 83103 / 83126 |
| `_MapPdfMemoListPanel` / `_MapMemoListTile` | 83486 / 83614 |
| `_PdfFolderDragData`, `_SubmitMemoIntent` | 72078, 83473 |
| `_PdfExporter` (static; caches NotoSansJP — tofu gotcha) | 95002 |

### Document editors/viewers (docx / xlsx / pptx / csv / txt / image)
| Symbol | Line |
|---|---|
| Spreadsheet: `_SpreadsheetKind` 84319, `_SheetSnapshot` 84323, `_SpreadsheetEditorDialog` / State 84333 / 84363, cells `_SsDataCell`/`_SsColumnHeaderCell`/`_SsRowHeaderCell` 86303/86414/86487 | |
| Formula engine: `_FormulaEvaluator` 99970, `_TokKind` 100553, `_Tok` 100555, `_AstNode`+subclasses 100561–100604, `_Parser` 100611 | |
| PPTX: model `_Pptx*` 86575–86968, `_PptxViewerDialog` / State 87047 / 87075, `_PresenterModeDialog` / State 101064 / 101086 | |
| Text/Markdown/LaTeX: `_TextSnapshot` 93270, `_TextEditorDialog` / State 93275 / 93294, `_MathRenderer` 94519, `_LatexFormatter` 94571 | |
| DOCX: enums `_DocxBlockKind`/`_DocxAlign`/`_DocxParaStyle` 95712/95715/95749, models `_DocxRun`/`_DocxBlock`/`_DocxSnapshot` 95804/95816/95922, `_DocxViewerDialog` / State 95928 / 95955 | |
| `_OfficeFileTemplate` (static; blank txt/csv/xlsx/docx/pptx) | 95362 |
| Image editor: `_ImageEditorDialog` / State 98933 / 98946, `_ImgTextItem` 99894 | |
| `_CreateTableResult`, `_CreateTableDialog` / State | 83728, 83734 / 83746 |

### Floating tools, clock/weather, voice, focus-lock, Google search
| Symbol | Line |
|---|---|
| `_FloatingCalculator` / State, `_FloatingScientificCalculator` / State, `_SciCalcEval` | 60274 / 60292, 62052 / 62068, 61866 |
| `_FloatingStopwatch` / State, `_FloatingPomodoro` / State, `_FloatingWeather` / State | 60760 / 60775, 68758 / 68773, 69646 / 69661 |
| `_MenuClockWeather` / State, `_WeatherMenuSummary`, `_MapPickerDialog` / State | 64900 / 64907, 65056, 71231 / 71248 |
| `_AudioAlarm` (static alarm sounds + prefs) | 64661 |
| `_AlarmSoundPickerDialog` | 65187 |
| `_VoiceInputDialog` / State (speech-to-text) | 67549 / 67560 |
| `_FocusLockOverlay` / State; `_checkFocusLockSchedule` (Android-only, 30s timer) / `_focusLockActiveScheduleRemain` / `_buildFocusLockScheduleEditor` | 68207 / 68220; 22854 / 22878 / 22342 |
| Google search (canvas-docked): `_DockedGoogleSearchState` (data, **not** a Flutter State), `_FloatingGoogleSearch` / State, `_WinGoogleSearchView` / State, `_DockedGoogleSearchPane` / State, `_FullWidthDigitToHalfFormatter` | 72010, 72269 / 72280, 72710 / 72720, 72789 / 72798, 72060 |
| `_CalendarDragPayload`, `_RoutinePatternMode` (enum), `_DayTimelinePage` / State | 60244, 62553, 62984 / 63000 |
| `_AlwaysDraggableScrollBehavior`, `_AppLockChoice` (last class, EOF) | 71591, 101506 |

### Reminder/notification scheduling (inside `_MindMapScreenState`)
| Symbol | Line | Notes |
|---|---|---|
| `_scheduleAbsoluteNotification` | 15484 | Core funnel: `zonedSchedule` OS notif + per-key in-app/Windows-toast Timer; skips past times |
| `_scheduleNodeNotification` | 15430 | Node "remind later"; also writes a calendar event |
| `_showWindowsOsNotification` / `_showNodeNotificationOverlay` | 15553 / 15587 | Windows toast / in-app overlay fallbacks |
| `_pendingNotificationTimers` | 15703 | `Map<String,Timer>` (in-memory, cleared in dispose 3369) |
| `_eventNotifyTimer` / `_checkEventNotifications` / `_showEventNotification` | 2164 / 2815 / 2848 | Foreground-only 30s calendar SnackBar poller |
| calendar 予定登録 → schedule | 35542 | `notify && startTime` → fireAt = start − leadMinutes |
| focus-lock: `_kFocusLockNotifId` 99310 / `_scheduleCompletionNotification` / `_cancelCompletionNotification` | 68235 / 68303 / 68333 | Android-only, reuses node channel |

---

## SharedPreferences keys

All local persistence funnels through `MindMapProvider` via ad-hoc `_load*`/`_save*` methods (each opens its own `SharedPreferences` instance; load order is non-deterministic except `_loadFromStorage`). A handful of keys are `static const` near `:1100` (e.g. `_kShortcutFolderId` 1100, `_storageKey` 1101, `_foldersStorageKey` 1102, `_calendarStorageKey` 1108; ~7 such declarations exist across the whole file); the rest are inline literals. **`_loadGeminiApiKey` (`:15461`) and `_loadFontSettings` (`:24767`) are grab-bag loaders** — most UI/settings bools/ints are loaded (and `.clamp()`-ed) there, so look there if you can't find where a setting loads. The dynamic key `page_uploaded_<pageId>` is the only interpolated one.

| Key | Type | Meaning |
|---|---|---|
| `mindmap_pages_v3` | String(JSON) | The whole document tree (canonical) |
| `mindmap_pages_v2` | String(JSON) | Legacy tree; read-only, migrated to v3 |
| `mindmap_folders_v1` | String(JSON) | Folder list |
| `last_opened_page_id` | String | Page to reopen on launch |
| `shortcut_folder_id` | String | Ctrl+1..9 shortcut base folder |
| `defaultTitleFontSize` / `defaultMemoFontSize` | double | Default node fonts |
| `gemini_api_key` / `openai_api_key` / `anthropic_api_key` / `grok_api_key` / `deepseek_api_key` | String | Per-provider AI keys |
| `grok_model` / `deepseek_model` / `openaiModel` / `anthropicModel` / `aiProvider` | String | AI provider/model selection |
| `global_gemini_api_key` | String | App-wide/dev Gemini key |
| `aiDepth` / `aiChildMin` / `aiChildMax` / `aiGrandchildMin` / `aiGrandchildMax` / `aiModelTier` | int/String | AI generation params |
| `totalInputTokens` / `totalOutputTokens` / `totalCostUsd` | int/double | Cumulative AI usage |
| `cached_flash_models` / `cached_pro_models` / `cached_openai_models` / `cached_claude_models` | String(JSON) | Cached model lists |
| `models_fetch_gemini_ts` / `models_fetch_openai_ts` / `models_fetch_claude_ts` | int | Last model-fetch epoch ms (24h) |
| `appLanguage` | String | UI language (default `en`) |
| `langPickerShown` | bool | First-launch flag (NOT `appLanguage`) |
| `isDarkMode` | bool | Dark theme |
| `voiceDelimiter` / `voicePauseSeconds` | String/int | Speech-to-text segmentation |
| `clockOffsetMinutes` / `clockOffsetUserSet` | int/bool | Menu clock tz offset |
| `pdfArrowStepDivisor` / `pdfPageJumpCount` / `pdfAiPanelDefault` | int/String | PDF reader settings |
| `pdfHighlights` / `pdfMemoPinnedFolders_v1` / `pdfMemoFolderTopIndex_v1` / `lastPdfPages_v1` / `hidden_pdf_pages` | String(JSON) | PDF highlights/memos/state |
| `decoTextAnchorX` / `decoTextAnchorY` | double | Decoration text anchor |
| `openLinksInApp` / `pasteImageScalePercent` / `pasteImageOriginalSize`(legacy) / `promptForTitleOnNodeCreate` | bool/int | UI behavior |
| `focusLockHideSeconds` / `focusLockHideUnlockBtn` / `hideEmbedRelated` | bool | Focus-lock / embed |
| `focusLockScheduleEnabled` / `focusLockScheduleStartMin` / `focusLockScheduleEndMin` / `focusLockSchedules` | bool/int/String(JSON) | Focus-lock schedules (last is multi) |
| `customHeaderButtons` / `customBottomButtons` / `customBottomTopButtons` / `customBottomTopButtonsSplit` / `lockScaleBottomSlot` | String(JSON)/int | Custom toolbar layouts |
| `headerIconColors` / `headerIconColorsOff` | String(JSON) | Per-command icon color overrides |
| `snapEnabled` / `memoCollapsedGlobal` / `allowDuplicateVideoNodes` / `autofillSequenceEnabled` | bool | Canvas/node toggles |
| `channelMode` / `includeShorts`(legacy) / `autoDeleteWatched` / `unwatchedLimit` / `quickAddChildrenCount` | String/bool/int | YouTube channel behavior |
| `minViewCount` / `chFilterInclude` / `chFilterExclude` | int/String | Channel filters |
| `videoMaxRate` / `lastVideoPlaybackRate` / `backgroundPlaybackEnabled` / `pipScale` | double/bool | Video playback |
| `channelQueues` / `generatedVideoIds` / `videoPositions` / `lastWatchedVideoId` / `lastYoutubeBrowseUrl` | String(JSON)/StringList/String | Video/channel state |
| `pastQuizQuestions` / `quizAvoidDuplicates` | StringList/bool | AI quiz history |
| `web_page_memos` / `qiita_blocked_authors` | String(JSON)/StringList | Web-page memos / Qiita blocks |
| `googleSearchMemoDraft` / `googleSearchMemos` | String | Google-search memos |
| `hidden_page_ids` / `favorite_page_ids` / `autoSyncPageIds` | StringList | Page visibility / auto-sync set |
| `page_uploaded_<pageId>` | String(ISO8601) | Per-page last upload timestamp (dynamic key) |
| `namedGroups` / `groupColors` / `groupFontSizes` / `groupFontFamilies` / `groupLayoutRows` / `groupLayoutModes` / `groupPadding` | String(JSON) | Named-group styling |
| `colorMode` / `fixedColorIndex` / `colorCycleCounter` | String/int | Node coloring |
| `pro_subscribed` / `purchased_plan` / `subscription_ended_at_ms` / `splitViewUseCount` / `dev_impersonate_plan` | bool/String/int | Billing/plan state |
| `applied_coupon_code` / `coupon_discount_percent` / `coupon_expiry_ms` / `coupon_plan` | String/int | Coupons |
| `billingMonthYm` / `monthlyUploadBytes` / `monthlyDownloadBytes` / `totalStorageBytes` | String/int | Usage quota counters |
| `developer_mode` | bool | Developer mode unlocked |
| `inquiry_email` / `inquiry_send_log` / `my_inquiries` | String(JSON) | Inquiries |
| `firebase_uid` / `firebase_refresh_token` | String | Cached anon auth |
| `syncGroupId`(legacy) / `joinedGroupIds` / `pageGroupBindings` / `lastPruneAtMs` | String/StringList/JSON/int | Sync group membership |
| `displayName` / `displayNameSkipped` / `userAvatar` / `userAvatarImage` | String/bool | User profile |
| `calendarGroupSharingEnabled` / `calendarViewingUid` / `calendar_events_v1` / `calendar_sync_destination` / `calendar_pull_source` / `calendarTzOffset` / `calendarTzLabel` | bool/String(JSON)/int | Calendar |
| **Keys owned outside the provider:** `disabled_shortcuts` (StringList — per-command shortcut on/off; screen `:1929`/`:1945`), `downloaded_videos_v1` / `video_memo_history_<id>` / `mokumoku_youtube_nav_history_v1` (screen), `mokumoku_gs_bookmarks_v1` (google_search_dialog) | String(JSON)/StringList | Not loaded via `MindMapProvider`. (`_customKeyBindings` is in-memory only and has NO prefs key.) |

---

## Firestore document structure (REST API)

Project id from `FIREBASE_PROJECT_ID` (example `mindmap-b6115`); base URL `_firestoreBaseUrl` (`:2534`). Storage bucket hard-coded `mindmap-b6115.firebasestorage.app` (`:2560`). `gid` = 8-char uppercase group code (UUIDv4-derived). Auth is anonymous (Identity Toolkit); `_uid` = the anon localId, used as the per-user doc key.

```
(default)/documents/
├── groups/{gid}/                       fields: createdAt, host(uid)
│   ├── pages/{pageId}                   json (full MindMapPage), namedGroupsJson,
│   │                                     expiresAt (TTL: free=+7d, paid=null), uploadRestricted, restrictedByUid
│   ├── members/{uid}                    uid, displayName, lastSeen, allowCalendarSharing, plan
│   ├── calendar/{uid}                   json (that owner's events blob), ownerUid, ownerName, updatedAt
│   └── calendar/events                  LEGACY single doc (read-only 404 fallback)
├── users/{uid}                          displayName, plan, lastSeen, couponCode
├── messages/{msgId}                     fromUid, fromName, text, timestamp, read, toUid | toGroupId  (OR-filtered client-side)
├── inquiries/{msgId}                    uid, message, timestamp, reply, replyTimestamp, status, senderPlan, senderName, forwardEmail  (rule: allow write: if true)
├── admin/settings                       globalGeminiApiKey, inquiryEmail
├── coupons/{code}                       discountPercent, expiresAt, plan, currentUses, note
└── licenses/{code}                      plan, expiresAt, consumedByUid

Firebase Storage (bucket mindmap-b6115.firebasestorage.app):
└── groups/{gid}/attachments/{fileName}
```

Writes are HTTP `PATCH` with `updateMask.fieldPaths=...`; creates with a fixed id use `POST .../{collection}?documentId=...`. `expiresAt` drives a Firestore TTL policy for free-plan page deletion; `pruneExpiredCloudData` (`:23175`) deletes Storage objects (free 7d, paid 30d after cancel). Per-plan upload/download/storage caps are enforced **only** inside the provider's cloud paths — a new upload path elsewhere would bypass them unless it also calls `canUse*Bytes`/`recordUploadBytes`.

---

## `lib/widgets/` and `lib/services/` index

| File | Lines | Status | What it is |
|---|---|---|---|
| `lib/widgets/node_widget.dart` | 2247 | **LIVE** | `NodeWidget` (32) — THE per-node renderer (rendered at `mind_map_screen.dart:32707`); large callback prop-bag. Static URL helpers `extractVideoId` 142 / `parseTimestamp` 162 / `isMp4Url` 180 / `isImageUrl` 209 / `thumbnailUrl` 227 (callers reuse these — must match `MindMapNode._isMp4Url`). `SnapTarget` 17 (drag-snap value class). Inline table `_NodeTableInlineWidget`/State 1564/1618. |
| `lib/widgets/connection_painter.dart` | 317 | **LIVE** | `ConnectionPainter` (4) — cubic-bezier connection lines (built at `mind_map_screen.dart:14100`, `32507`). `findConnection(Offset)` 37 (≤14px hit-test). `_effectiveLineColor` 25 rewrites pale-yellow lines → `0xFF263238` (yellow retired). |
| `lib/widgets/google_search_dialog.dart` | 3747 | **LIVE** | `GoogleSearchDialog` (55) — integrated search + note-taking. `show(...)` 56 (modal; `compactMode`/`minimalMode`), `showFloating(...)` 239 (draggable overlay). Shared body `_GoogleSearchPage` 454 (iaw mobile / webview_windows desktop). Memo draft persists via `provider.googleSearchMemoDraft`; bookmarks via `_GoogleSearchBookmarks` 3677 (prefs `mokumoku_gs_bookmarks_v1`, max 50). Launched at `mind_map_screen.dart:6958`/`6971`. |
| `lib/services/billing_service.dart` | 362 | **LIVE** | `BillingService` (69) — subscription abstraction; does NOT import provider (communicates via `onPlanChanged` string callback). `BillingPlanName` consts 29. Platform split: `isNativeBilling` 99 (RevenueCat SDK), `isWindowsDesktop` 105 (Stripe link 251 + REST `/subscribers/{id}` 272 + poll 312). `configure` 114 skips `test_` keys in release (129–134). `fetchPackages` 168 / `purchasePackage` 212 / `restore` 231. `_planFromCustomerInfo` 157 (max>pro). |
| `lib/widgets/node_detail_sheet.dart` | 817 | **DEAD/orphan** | `NodeDetailSheet` (11) 3-tab node editor. Imported by no file — the live node editor is inline in `mind_map_screen.dart`. Do not edit expecting effect. |
| `lib/screens/messaging_dialog.dart` | 785 | **DEAD** | `MessagingDialog` (9) — messaging UI; feature removed (see comment `mind_map_screen.dart:17`). Not instantiated anywhere. |

---

## Build & platform setup

- **Startup** (`lib/main.dart:24`): orientation → timezone init (`Asia/Tokyo`, UTC fallback, required for `zonedSchedule`) → `flutter_local_notifications` init (Android channel `mokumoku_node_reminders`, plugin singleton at `main.dart:16`) → Android 13+ permission requests (notifications + exact alarms) → desktop `windowManager` + `localNotifier.setup(shortcutPolicy: requireCreate)` → `runApp`. `MyApp` (102) installs the single root `ChangeNotifierProvider(create: (_) => MindMapProvider())`; theme via `provider.isDarkMode`, seed `0xFF6C63FF`.
- **`lib/firebase_options.dart`**: hand-maintained; every field is `String.fromEnvironment(..., defaultValue: '')`. **Do NOT regenerate with `flutterfire configure`** (overwrites env wiring). The Firestore REST key is resolved separately in the provider via a priority chain `FIREBASE_API_KEY_REST → _WINDOWS → _ANDROID → _IOS/_WEB/_MACOS` (`:2499`), and `env.json` carries an extra `FIREBASE_API_KEY_REST`.
- **`env.json` keys**: `FIREBASE_*` (project/sender/bucket/auth-domain/bundle-id; per-platform API_KEY/APP_ID; MEASUREMENT_ID Windows; plus `FIREBASE_API_KEY_REST`), `REVENUECAT_*` (`API_KEY_ANDROID`, `API_KEY_REST`, `WEB_PURCHASE_LINK_PRO/_MAX`). RevenueCat holds **public keys only**. (`GEMINI_API_KEY` is **no longer used** — BYOK; the app reads the user-entered key from prefs. It can be dropped from env.json.)
- **Android** (`AndroidManifest.xml` + `build.gradle`): permissions include POST_NOTIFICATIONS, SCHEDULE/USE_EXACT_ALARM, RECEIVE_BOOT_COMPLETED, FOREGROUND_SERVICE_MEDIA_PLAYBACK, REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, RECORD_AUDIO; `MainActivity` is `singleTop` + `showWhenLocked`/`turnScreenOn`; registers `audio_service` + the three FLN receivers; `<queries>` declares `android.speech.RecognitionService` (required on Android 11+). `applicationId com.kamispec.app` (namespace still `com.example.mindmap_app` — a Play publish-blocker noted in comments); `targetSdk 34`; core library desugaring enabled for FLN 17.x.
- **Windows** (`windows/runner/` + CMake): `BINARY_NAME mindmap_app`; registered plugins include `local_notifier`, `syncfusion_pdfviewer_windows`, `webview_windows` (and NOT FLN or purchases_flutter — Windows uses local_notifier + Stripe/REST).

### Dependency pin rationale (read pubspec comments before changing)
`flutter_inappwebview` is pinned **exactly `6.0.0`** (6.1.x disturbs the Windows webview); `webview_windows ^0.2.2` is the separate desktop WebView; `syncfusion_flutter_pdfviewer ^28.1.37` replaced `pdfx` (blank on Windows) and is required for `onPageChanged`/`jumpToPage` (PDF memos); `device_info_plus ^11` is forced by syncfusion + flutter_localizations; `local_notifier ^0.1.6` provides desktop toasts (FLN 17.x has no Windows support); `flutter_local_notifications ^17.2.4` + `timezone ^0.9.4` drive Android exact reminders; `video_player ^2.9.1` plays local mp4 at up to ~16x (WebView caps ~2x); `audio_service`/`just_audio`/`wakelock_plus`/`permission_handler`/`android_intent_plus` keep background audio alive under Doze; `purchases_flutter ^9.9.0` is mobile-only billing; `youtube_explode_dart ^2.4.2` for downloads; `csv`/`excel`/`archive` for in-app document editors.

## Gotchas

- **Two files too big to read whole** — `mind_map_provider.dart` (~30.6k) and `mind_map_screen.dart` (~101.5k). Always navigate via the maps above and Grep (`^class `/`^enum `, method names, `t('` keys, `// ───` dividers). The 4317–15359 (translations) and 19626–22655 (AI) regions are dividerless bodies — grep method signatures there.
- **Duplicate orphan model file:** `lib/screens/mind_map_node.dart` is a stale, slightly-older near-copy of `lib/models/mind_map_node.dart` (1139 vs 1113 lines; `diff` DIFFERS), imported by **zero** source files. The real model is `lib/models/mind_map_node.dart` (imported by the provider `:12`, screen `:14`, and the `lib/widgets/` painters/widgets). Edit only the `models/` version.
- **Two more dead files:** `lib/widgets/node_detail_sheet.dart` (`NodeDetailSheet`) and `lib/screens/messaging_dialog.dart` (`MessagingDialog`) are imported/instantiated by nothing — the live node editor is inline in the screen and messaging was removed (see comment `mind_map_screen.dart:17`). Don't edit them expecting effect.
- **No codegen:** `json_serializable`/`build_runner` are declared but produce no `.g.dart` files. Serialization is hand-written and defensive; keep it backward-compatible (existing fields read with null/bounds guards).
- **NotoSansJP font tofu:** there is **no `assets/` directory at all** (`assets/fonts/NotoSansJP-Regular.ttf` is absent) and the `assets:` lines in `pubspec.yaml` (~200–201) are commented out, so PDF export renders Japanese as □ (tofu). `_PdfExporter._loadJapaneseFont` (`mind_map_screen.dart:95010`) warns once and returns null (no crash). To fix: place `assets/fonts/NotoSansJP-Regular.ttf` **and** uncomment the two `assets:` lines (uncommenting without the file breaks `flutter build`).
- **`visualHeight` ↔ `node_widget.dart` coupling:** `MindMapNode.visualHeight` (`mind_map_node.dart:738`) and the static `_isMp4Url`/`NodeWidget.isMp4Url` helpers must stay in sync with the widget's draw logic, or node hit-boxes/connection anchors drift from what's drawn. `attachmentAspectRatio` also feeds that draw math.
- **`copyWith` sentinels are not uniform:** `PdfMemo` (`_sentinel` at `mind_map_node.dart:99`) and `MindMapNode` (`_sentinel` at `:1020`) use a `static const Object _sentinel` so nullable fields can be explicitly cleared vs left unchanged. `NodeConnection` has **no** sentinel — it clears its nullable `label` via a `bool clearLabel = false` parameter (`:530`, `label: clearLabel ? null : (label ?? this.label)`); grepping NodeConnection for `_sentinel` finds nothing. Plain nullable string fields on the node (`memoText`, `attachmentPath`) use `?? this.x` and thus **cannot** be cleared to null via copyWith.
- **fromJson ≠ ctor defaults:** `MindMapNode.fromJson` defaults `width`/`height` to `140/42`, but the constructor defaults `160/40`. `NodeConnection.fromJson` defaults missing `arrowHeadScale` to `1.0` while the ctor default is `0.5`. Don't assume they match.
- **t() fallback is en-before-ja:** the chain is `_appLanguage → 'en' → 'ja' → key` (default language is `en`, not `ja`); 21 of 30 languages are BETA and surface English, never raw keys.
- **Custom key bindings are not persisted:** `_customKeyBindings` lives only in memory (no prefs key); only the per-command on/off set `_disabledShortcuts` (prefs `disabled_shortcuts`) survives restart.
- **Client-side security only:** all Firestore access control (upload-restriction lock, sharing gates, coupon/inquiry rate limits) is enforced in Dart and is bypassable; production must replicate it in Firestore Security Rules (none are in-repo).
- **Cost accounting is inconsistent across Gemini paths:** `askGemini` (`:22178`) uses `_pricing`/`calcCostUsd` (canonical); two other generateContent paths hardcode different per-token rates. `usdToJpy` uses a fixed 170 rate.
- **env.json may contain real secrets in the working tree** despite being meant as git-ignored — verify `.gitignore` actually excludes it before any commit/push, and never commit it.
