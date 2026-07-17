<#
  Update-SocialPreview.ps1
  Expertise Tecnologia - ferramenta interna do repositorio (nao faz parte
  da serie de scripts de TI/NOC, por isso nao segue o template de cabecalho
  com links/licenca).

  O que faz:
  - Le $ScriptVersion em WindowsOptimizerCleanup.ps1.
  - Atualiza os dois lugares que mostram a versao em
    assets/social-preview-source.html (badge "vX.Y.Z" e a linha
    "Versao: X.Y.Z" do mockup de terminal).
  - Renderiza o HTML via Chrome/Edge headless em 2x e reduz para
    1280x640 (tamanho recomendado pelo GitHub para Social Preview),
    sobrescrevendo assets/social-preview.png.

  Uso:
    powershell -ExecutionPolicy Bypass -File .\scripts\Update-SocialPreview.ps1

  Depois de rodar, o upload em Settings > General > Social preview no
  GitHub continua manual - a API do GitHub nao expoe esse campo.
#>

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ScriptPath = Join-Path $RepoRoot 'WindowsOptimizerCleanup.ps1'
$HtmlPath   = Join-Path $RepoRoot 'assets\social-preview-source.html'
$PngPath    = Join-Path $RepoRoot 'assets\social-preview.png'

if (-not (Test-Path $ScriptPath)) { throw "Nao encontrado: $ScriptPath" }
if (-not (Test-Path $HtmlPath))   { throw "Nao encontrado: $HtmlPath" }

# --- 1. Descobrir a versao atual -------------------------------------------
$versionMatch = Select-String -Path $ScriptPath -Pattern "\`$ScriptVersion\s*=\s*'([\d.]+)'" | Select-Object -First 1
if (-not $versionMatch) { throw "Nao consegui extrair `$ScriptVersion de $ScriptPath" }
$Version = $versionMatch.Matches[0].Groups[1].Value
Write-Host "Versao detectada: $Version"

# --- 2. Atualizar o HTML-fonte com a nova versao ----------------------------
$html = Get-Content -Path $HtmlPath -Raw
$html = $html -replace '(<span class="badge">v)\d+\.\d+\.\d+(</span>)', "`${1}$Version`${2}"
$html = $html -replace '(Versao:\s*)\d+\.\d+\.\d+', "`${1}$Version"
Set-Content -Path $HtmlPath -Value $html -NoNewline
Write-Host "HTML-fonte atualizado: $HtmlPath"

# --- 3. Localizar um navegador para o headless screenshot -------------------
$browserCandidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
)
$browser = $browserCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $browser) { throw "Nenhum navegador (Chrome/Edge) encontrado para renderizar o preview." }
Write-Host "Usando navegador: $browser"

# --- 4. Renderizar em 2x e reduzir para 1280x640 ----------------------------
$tmpPng = Join-Path ([System.IO.Path]::GetTempPath()) ("social-preview-{0}.png" -f ([guid]::NewGuid()))
$fileUri = "file:///" + ($HtmlPath -replace '\\', '/')

$chromeArgs = @(
    '--headless', '--disable-gpu', '--hide-scrollbars',
    '--force-device-scale-factor=2', '--window-size=1280,640',
    "--screenshot=$tmpPng", $fileUri
)
Start-Process -FilePath $browser -ArgumentList $chromeArgs -Wait -NoNewWindow

# O processo "lancador" do Chrome as vezes retorna antes do processo filho
# terminar de gravar o PNG em disco; aguarda um pouco antes de desistir.
$attempts = 0
while (-not (Test-Path $tmpPng) -and $attempts -lt 10) {
    Start-Sleep -Milliseconds 500
    $attempts++
}
if (-not (Test-Path $tmpPng)) { throw "Falha ao gerar o screenshot (navegador nao produziu o arquivo)." }

Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile($tmpPng)
$dst = New-Object System.Drawing.Bitmap(1280, 640)
$dst.SetResolution(96, 96)
$g = [System.Drawing.Graphics]::FromImage($dst)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.DrawImage($src, 0, 0, 1280, 640)
$g.Dispose()
$dst.Save($PngPath, [System.Drawing.Imaging.ImageFormat]::Png)
$dst.Dispose()
$src.Dispose()
Remove-Item -Path $tmpPng -Force -ErrorAction SilentlyContinue

$sizeKB = [math]::Round((Get-Item $PngPath).Length / 1KB, 1)
Write-Host "Preview atualizado: $PngPath ($sizeKB KB, v$Version)"
Write-Host "Falta so: git add/commit/push, e reenviar o PNG em Settings > General > Social preview no GitHub."
