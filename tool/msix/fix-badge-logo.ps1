# MSIX のバッジロゴを規則どおりに直す。
#
# なぜ要るか:
#   バッジロゴ (24x24) は Windows が好きな色に塗り直して使うため、
#   画素は「白」 か「透明」 でなければならない。 ところが msix の道具は
#   色つきのアプリロゴをそのまま縮小してバッジ用にも使うので、 必ず
#   この規則に反する (WACK の「アプリ リソース」 が FAIL になる)。
#   道具側に差し替えの設定が無いので、 出来上がった .msix を開いて
#   バッジロゴだけ白のシルエットに置き換え、 包み直す。
#
# 使い方:
#   1. dart run msix:create  (いつもどおり作る)
#   2. & "wack\fix-badge-logo.ps1" -Msix "build\windows\x64\runner\Release\HisatorNotebook.msix"
#
#   署名済みのパッケージを直した時は、 包み直すと署名が外れるので
#   -Pfx と -Password を渡して署名し直すこと (提出用の未署名パッケージは不要)。

param(
  [Parameter(Mandatory = $true)][string]$Msix,
  [string]$Pfx = '',
  [string]$Password = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$msixPath = (Resolve-Path $Msix).Path
$makeappx = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse `
  -Filter 'makeappx.exe' -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match '\\x64\\' } |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $makeappx) { throw 'makeappx.exe が見つかりません (Windows SDK が要ります)' }

$work = Join-Path $env:TEMP ('msixfix_' + [Guid]::NewGuid().ToString('N'))
Write-Host '① 中身を取り出しています...' -ForegroundColor Cyan
& $makeappx unpack /p $msixPath /d $work /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'unpack に失敗しました' }

Write-Host '② バッジロゴを白のシルエットにします...' -ForegroundColor Cyan
$badges = Get-ChildItem (Join-Path $work 'Images') -Filter 'BadgeLogo*.png'
foreach ($b in $badges) {
  $src = New-Object System.Drawing.Bitmap($b.FullName)
  $dst = New-Object System.Drawing.Bitmap($src.Width, $src.Height,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  for ($y = 0; $y -lt $src.Height; $y++) {
    for ($x = 0; $x -lt $src.Width; $x++) {
      $p = $src.GetPixel($x, $y)
      # 透け具合はそのままに、 色だけ白へ。 これで
      #   「白 (##FFFFFF) か 透明 (00######)」 の規則を満たす。
      $dst.SetPixel($x, $y,
        [System.Drawing.Color]::FromArgb($p.A, 255, 255, 255))
    }
  }
  $src.Dispose()
  $tmp = $b.FullName + '.tmp'
  $dst.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
  $dst.Dispose()
  Move-Item $tmp $b.FullName -Force
  Write-Host "   $($b.Name)"
}

Write-Host '③ 包み直しています...' -ForegroundColor Cyan
# 署名は包み直すと外れるので、 先に消しておく (未署名で出すのが提出用)。
$sig = Join-Path $work 'AppxSignature.p7x'
if (Test-Path $sig) { Remove-Item $sig -Force }
$blockmap = Join-Path $work 'AppxBlockMap.xml'
if (Test-Path $blockmap) { Remove-Item $blockmap -Force }
& $makeappx pack /d $work /p $msixPath /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'pack に失敗しました' }

if ($Pfx) {
  Write-Host '④ 署名し直しています...' -ForegroundColor Cyan
  $signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse `
    -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $signtool) { throw 'signtool.exe が見つかりません' }
  & $signtool sign /fd SHA256 /a /f $Pfx /p $Password $msixPath | Out-Null
  if ($LASTEXITCODE -ne 0) { throw '署名に失敗しました' }
}

Remove-Item $work -Recurse -Force
Write-Host ''
Write-Host "できました: $msixPath" -ForegroundColor Green
