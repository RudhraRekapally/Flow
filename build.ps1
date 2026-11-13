# Builds dist\FlowSetup.exe.
#   1. a private build environment (.build-venv) with PySide6-Essentials + PyInstaller
#   2. PyInstaller freezes src\ into dist\Flow\
#   3. Inno Setup wraps that folder into the installer
# Needs Python 3.12+ and Inno Setup 6 (https://jrsoftware.org/isinfo.php) installed.

# No $ErrorActionPreference = 'Stop': PyInstaller logs to stderr, which Windows PowerShell would
# then treat as a failure. Each step checks its exit code instead.
$root = $PSScriptRoot
$venvPy = Join-Path $root '.build-venv\Scripts\python.exe'

if (-not (Test-Path $venvPy)) {
    python -m venv (Join-Path $root '.build-venv')
    if ($LASTEXITCODE -ne 0) { throw 'could not create the build environment' }
    & $venvPy -m pip install --disable-pip-version-check PySide6-Essentials pyinstaller
    if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }
}

& $venvPy (Join-Path $root 'tools\make_icon.py') (Join-Path $root 'assets\icon.ico')

Push-Location $root
try {
    & $venvPy -m PyInstaller --noconfirm --clean Flow.spec
    if ($LASTEXITCODE -ne 0) { throw 'PyInstaller failed' }
} finally {
    Pop-Location
}

$iscc = @(
    (Get-Command iscc -ErrorAction SilentlyContinue).Source,
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) not found' }

& $iscc (Join-Path $root 'installer\Flow.iss')
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }

Get-Item (Join-Path $root 'dist\FlowSetup.exe') | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
