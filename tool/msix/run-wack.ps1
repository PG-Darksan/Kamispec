# Windows App Certification Kit (WACK) を走らせる。
#
# ★ 管理者として実行してください。
#   スタートメニューで「PowerShell」 を右クリック →「管理者として実行」 →
#   下の 1 行を貼り付けて Enter。
#
#     & "C:\Users\Study\mindmap_app_out\tool\msix\run-wack.ps1"
#
# 何をするか:
#   ① 検査用の自己署名証明書を「信頼された人」 に入れる
#      (WACK はパッケージを実際にインストールして調べるため、 署名が信頼
#       されている必要がある。 Store 提出用の未署名パッケージとは別物)
#   ② WACK を走らせる (10〜20 分ほど。 途中でアプリが自動で起動・終了する)
#   ③ 結果を tool\msix\wack_report.xml に書き出し、 合否を表示する
#
# 終わったら、 入れた検査用証明書は下の「後片付け」 で消せます。

$ErrorActionPreference = 'Stop'

# ★ $MyInvocation.MyCommand.Path は呼び方 (-File か & か) によっては空になり、
#   置き場を見失って appcert に変な道を渡してしまう。 $PSScriptRoot は
#   スクリプト実行時に必ず入るので、 こちらを使う。
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$pfx = Join-Path $here 'wacktest.pfx'
$msix = Join-Path $here 'HisatorNotebookWack.msix'
$reportXml = Join-Path $here 'wack_report.xml'
$appcert = 'C:\Program Files (x86)\Windows Kits\10\App Certification Kit\appcert.exe'

# 管理者かどうか確かめる
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host '管理者として実行してください。' -ForegroundColor Red
  Write-Host 'PowerShell を右クリック →「管理者として実行」 から開き直してください。'
  exit 1
}

foreach ($f in @($pfx, $msix, $appcert)) {
  if (-not (Test-Path $f)) {
    Write-Host "見つかりません: $f" -ForegroundColor Red
    exit 1
  }
}

# ── 検査に掛ける .msix が「今の版」 か確かめる ───────────────────────
#   ★ このスクリプトは前まで版を見ていなかったので、 何か月も前に作った
#     HisatorNotebookWack.msix をそのまま検査して PASS と出していた。
#     提出する版で走らせないと意味が無いので、 pubspec と突き合わせる。
$pubspec = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'pubspec.yaml'
$want = $null
if (Test-Path $pubspec) {
  $m = Select-String -Path $pubspec -Pattern '^\s*msix_version:\s*([0-9.]+)' |
    Select-Object -First 1
  if ($m) { $want = $m.Matches[0].Groups[1].Value }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($msix)
try {
  $entry = $zip.GetEntry('AppxManifest.xml')
  $reader = New-Object System.IO.StreamReader($entry.Open())
  [xml]$mf = $reader.ReadToEnd()
  $reader.Dispose()
} finally { $zip.Dispose() }
$got = $mf.Package.Identity.Version
Write-Host "検査するパッケージ: $got  (pubspec: $want)"
if ($want -and $got -ne $want) {
  Write-Host ''
  Write-Host "版が合っていません。 古いパッケージを検査しようとしています。" `
    -ForegroundColor Red
  Write-Host "  $msix = $got"
  Write-Host "  pubspec.yaml     = $want"
  Write-Host ''
  Write-Host '提出する版で作り直してください (docs/store-release.md の WACK の節):'
  Write-Host '  1. pubspec の msix_config を store: false /'
  Write-Host '     publisher: CN=HisatorNotebookWackTest /'
  Write-Host '     certificate_path: tool/msix/wacktest.pfx (password: wacktest) にする'
  Write-Host '  2. dart run msix:create --build-windows false'
  Write-Host '  3. tool\msix\fix-badge-logo.ps1 -Msix <出来た msix>' `
    '-Pfx tool\msix\wacktest.pfx -Password wacktest'
  Write-Host '  4. tool\msix\HisatorNotebookWack.msix へ置く'
  Write-Host '  5. pubspec を提出用 (store: true) へ必ず戻す'
  exit 1
}

# 前の結果を退けておく (= 古いレポートを読んで PASS と出さないため)
if (Test-Path $reportXml) {
  $stamp = (Get-Item $reportXml).LastWriteTime.ToString('yyyyMMdd-HHmmss')
  Move-Item $reportXml "$reportXml.$stamp.bak" -Force
  Write-Host "前の結果を退けました: $reportXml.$stamp.bak"
}

Write-Host '① 検査用の証明書を信頼済みに入れます...' -ForegroundColor Cyan
$pw = ConvertTo-SecureString -String 'wacktest' -Force -AsPlainText
Import-PfxCertificate -FilePath $pfx `
  -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' -Password $pw | Out-Null
Import-PfxCertificate -FilePath $pfx `
  -CertStoreLocation 'Cert:\LocalMachine\Root' -Password $pw | Out-Null

Write-Host '② WACK を走らせます (10〜20 分ほど掛かります)...' -ForegroundColor Cyan
& $appcert reset | Out-Null
& $appcert test -appxpackagepath $msix -reportoutputpath $reportXml

Write-Host ''
if (Test-Path $reportXml) {
  [xml]$x = Get-Content $reportXml
  # ★ 念のため、 レポートの中の版も突き合わせる。
  $repVer = $x.REPORT.APP_VERSION
  if ($want -and $repVer -and $repVer -ne $want) {
    Write-Host "レポートが古い版の物です ($repVer)。 検査は走っていません。" `
      -ForegroundColor Red
    exit 1
  }
  $overall = $x.REPORT.OVERALL_RESULT
  if ($overall -eq 'PASS') {
    Write-Host "結果: $overall" -ForegroundColor Green
  } else {
    Write-Host "結果: $overall" -ForegroundColor Yellow
  }
  # 落ちた項目だけを並べる。
  # ★ RESULT は**属性ではなく子の要素**である (<TEST NAME=...><RESULT>PASS</RESULT>)。
  #   前は //*[@RESULT="FAIL"] で探していて 1 件も当たらず、 FAIL があっても
  #   「落ちた項目」 が空のまま PASS とだけ出ていた。
  $failed = @()
  foreach ($t in $x.SelectNodes('//TEST')) {
    $res = $t.SelectSingleNode('RESULT')
    if ($res -and $res.InnerText.Trim().ToUpper() -eq 'FAIL') { $failed += $t }
  }
  $total = @($x.SelectNodes('//TEST')).Count
  Write-Host "検査項目: $total 件中 $($failed.Count) 件が FAIL"
  if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host '落ちた項目:' -ForegroundColor Yellow
    foreach ($f in $failed) {
      $opt = $f.GetAttribute('OPTIONAL')
      $mark = if ($opt -eq 'TRUE') { '(OPTIONAL＝全体の合否には響かない)' } else { '(必須)' }
      Write-Host "  - $($f.GetAttribute('NAME'))  $mark"
      foreach ($m in $f.SelectNodes('.//MESSAGE')) {
        $txt = $m.GetAttribute('TEXT')
        if ($txt) { Write-Host "      $txt" -ForegroundColor DarkGray }
      }
    }
  }
  Write-Host ''
  Write-Host "詳しい結果: $reportXml"
} else {
  Write-Host 'レポートが作られませんでした。 上の出力を確認してください。' -ForegroundColor Red
}

Write-Host ''
Write-Host '── 後片付け (検査用の証明書を消す) ──' -ForegroundColor DarkGray
Write-Host 'Get-ChildItem Cert:\LocalMachine\TrustedPeople, Cert:\LocalMachine\Root |'
Write-Host '  Where-Object { $_.Subject -eq "CN=HisatorNotebookWackTest" } | Remove-Item'
