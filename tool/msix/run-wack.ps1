# Windows App Certification Kit (WACK) を走らせる。
#
# ★ 管理者として実行してください。
#   スタートメニューで「PowerShell」 を右クリック →「管理者として実行」 →
#   下の 1 行を貼り付けて Enter。
#
#     & "C:\Users\Study\mindmap_app_out\wack\run-wack.ps1"
#
# 何をするか:
#   ① 検査用の自己署名証明書を「信頼された人」 に入れる
#      (WACK はパッケージを実際にインストールして調べるため、 署名が信頼
#       されている必要がある。 Store 提出用の未署名パッケージとは別物)
#   ② WACK を走らせる (10〜20 分ほど。 途中でアプリが自動で起動・終了する)
#   ③ 結果を wack\wack_report.xml と .html に書き出し、 合否を表示する
#
# 終わったら、 入れた検査用証明書は下の「後片付け」 で消せます。

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
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
  $overall = $x.REPORT.OVERALL_RESULT
  if ($overall -eq 'PASS') {
    Write-Host "結果: $overall" -ForegroundColor Green
  } else {
    Write-Host "結果: $overall" -ForegroundColor Yellow
  }
  # 落ちた項目だけを並べる
  $failed = $x.SelectNodes('//*[@RESULT="FAIL"]')
  if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host '落ちた項目:' -ForegroundColor Yellow
    foreach ($f in $failed) {
      $name = $f.GetAttribute('NAME')
      if ($name) { Write-Host "  - $name" }
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
