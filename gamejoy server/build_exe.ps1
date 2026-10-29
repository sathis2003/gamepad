# Builds dist\PocketPadServer.exe. Run from this folder: .\build_exe.ps1
# No $ErrorActionPreference = "Stop": PyInstaller logs to stderr, which PowerShell 5.1 would treat as a failure.
Set-Location $PSScriptRoot

# App icon from the Android launcher icon
python -c "from PIL import Image; Image.open(r'..\android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png').save('icon.ico', sizes=[(256,256),(64,64),(32,32),(16,16)])"

python -m PyInstaller --noconfirm --clean --onefile --console --uac-admin `
  --name PocketPadServer `
  --icon icon.ico `
  --collect-all vgamepad `
  launcher.py

Write-Host "Built: $PSScriptRoot\dist\PocketPadServer.exe"
