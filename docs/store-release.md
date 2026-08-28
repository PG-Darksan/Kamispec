# Microsoft Store 提出手順 (Windows / MSIX)

このファイルが唯一の正本です。ここに書いていない手順で作った .msix は提出しないでください。

---

## いちばん大事なこと

`dart run msix:create` を素で叩いてはいけません。

内部で `flutter build windows` が **`--dart-define-from-file` 無し** で再実行され、
`build/windows/x64/runner/Release` が **鍵の入っていないバイナリで上書き**されます。
その .msix は起動しますが、Stripe 決済・エンタイトルメント照会・Firebase 同期が
すべて黙って死にます（「このプラットフォームの課金は準備中です」と出る事故がこれ）。

必ず `--build-windows false` を付けてください。

---

## 手順

### 1. バージョンを上げる

`pubspec.yaml` の 2 か所を同じ番号に揃えます。Partner Center は
**同一以下のバージョンを取り込み時に拒否**します。

```yaml
version: 1.0.0+206          # ← ビルド番号 (b206)
msix_config:
  msix_version: 1.0.206.0   # ← 4 桁・末尾は必ず 0
```

### 2. 鍵入りで Windows をビルドする

```powershell
flutter build windows --release --dart-define-from-file=env.json --dart-define=STORE_BUILD=true
```

`STORE_BUILD=true` が落とすもの（ストア規約対応）:

- ffmpeg の**自動ダウンロード**ボタン（ストア外から実行ファイルを取得して動かすのは禁止）
- 自動操作の**コマンド実行**機能一式（任意コマンド実行は「コード実行」とみなされる）
- **ビデオエディター（動画編集ページ）一式** — 書き出しに ffmpeg.exe が要るのに
  ストア版では取りに行けないため。 作成の入口（ドロワーの＋ / 種類選び /
  Ctrl+Shift+K / ノード右クリック）、 MCP の `add_video_editor_item` と
  `create_page` / `set_page_type` の `videoEditor`、
  AI に渡す説明書（AGENTS.md ほか）の記述まで落ちる。
  既に作ってあるページは消さず、 開くと案内を出す（中身は prefs に残る）。
  ※ 画面録画と AI 面接のコマ送りも ffmpeg を使うが、 こちらは残す。
  ストア版では exe の隣 / PATH / `C:\ffmpeg\bin` のいずれかから見つける。

zip 配布版では付けないでください。付けないのが既定の動作です。

### 3. MSIX に固める

```powershell
dart run msix:create --build-windows false
```

`--build-windows false` が肝です。手順 2 の成果物をそのまま包みます。

### 4. BadgeLogo を直す

```powershell
tool\msix\fix-badge-logo.ps1 -Msix "build\windows\x64\runner\Release\HisatorNotebook.msix"
```

`-Pfx` は付けません。**提出用は未署名のまま**です（`store: true` のため。
Microsoft 側が取り込み時に署名します。ダブルクリックでのサイドロードはできません）。

---

## 検証（毎回やること）

`build/` の中身ではなく、**完成した .msix の中の `app.so`** を見てください。
手順 2 と 3 の間で上書きされていないことを、ここで初めて確認できます。

```powershell
# .msix を展開して app.so を取り出す
$msix = "build\windows\x64\runner\Release\HisatorNotebook.msix"
$tmp  = "$env:TEMP\msixcheck"
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Copy-Item $msix "$tmp.zip" -Force
Expand-Archive "$tmp.zip" $tmp -Force

$so = Get-ChildItem "$tmp\data\app.so" -ErrorAction Stop
$bytes = [System.IO.File]::ReadAllBytes($so.FullName)
$text  = [System.Text.Encoding]::ASCII.GetString($bytes)

# 鍵が入っているか (0 だったら手順 2 からやり直し)
"buy.stripe.com        : " + ([regex]::Matches($text,'buy\.stripe\.com')).Count
"api.hisator-notebook  : " + ([regex]::Matches($text,'api\.hisator-notebook\.com')).Count
"AIza (Firebase)       : " + ([regex]::Matches($text,'AIza')).Count

# ストアで落とすものが本当に消えているか (どちらも 0 であること)
"FFmpeg-Builds (要 0)  : " + ([regex]::Matches($text,'FFmpeg-Builds')).Count

# AOT ビルドか (kernel_blob.bin が無いこと = デバッグ成果物の混入なし)
Test-Path "$tmp\data\flutter_assets\kernel_blob.bin"   # False であること
```

マニフェストも見ます。

```powershell
[xml]$m = Get-Content "$tmp\AppxManifest.xml"
$m.Package.Identity                       # Name / Publisher / Version
$m.Package.Capabilities.DeviceCapability  # microphone と webcam があること
$m.Package.Resources.Resource             # ja-jp と en-us があること
```

---

## WACK

提出する版でリビルドしてから実行してください。
過去の PASS 報告は別バージョン・別署名の別物です。

WACK には署名済みパッケージが要るので、**検証用だけ** `store: false` +
`publisher` 行を外した自己署名パッケージを別途作ります（提出物ではありません）。

```powershell
# 管理者 PowerShell で
tool\msix\run-wack.ps1
```

既知の FAIL（いずれも OPTIONAL=TRUE なので全体は PASS）:

- `data\flutter_assets\NOTICES.Z` — Flutter が必ず出す成果物。削除不可
  （アプリ内のライセンス表示が読んでいる）
- `app.so` の中の `cmd` / `PowerShell` 等の文字列 — `STORE_BUILD=true` で
  自分の分は消えます。残るのは依存パッケージ由来

---

## 提出時に Partner Center で申告すること

コードだけ直しても、ここを忘れると落ちます。

1. **第三者決済 API の使用**（Stripe）。非ゲームの PC アプリは外部決済を
   使ってよいことになっていますが、**提出時の申告が条件**です。
   審査ノートに「サブスクリプションと AI クレジットは Stripe で販売。
   決済はインストール後に外部ブラウザで開く」と書きます。
2. **生成 AI の使用**。申告欄にチェックし、通報手段（アプリ内の問い合わせ）を
   案内します。
3. **プライバシーポリシー URL**。Desktop Bridge (`Windows.FullTrustApplication`) は
   収集の有無に関係なく必須です。
4. **年齢レーティング (IARC)**。アプリ内ブラウザで任意サイトを開けること、
   ユーザー同士が共有・共同編集できることは **yes** と答えます。

---

## やってはいけないこと

- `dart run msix:create` を `--build-windows false` 無しで実行する
- `-Pfx` を付けて提出用パッケージに署名する
- `build/` の中身だけ見て「鍵が入っている」と判断する
- 前回と同じ `msix_version` で提出する
