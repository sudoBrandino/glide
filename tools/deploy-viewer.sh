#!/bin/bash
# Deploys the cross-built viewer to a Windows PC over SSH and restarts it in the user's
# interactive session. The exe keeps the same path (rename trick), so a Windows Firewall rule
# bound to that path keeps applying.
#   GLIDE_VIEWER_SSH   ssh host or alias of the PC (required); its default shell must be PowerShell
#   GLIDE_VIEWER_DIR   install folder on the PC, relative to the SSH home folder (default: glide)
# Both can live in .dev/build.env (see tools/build-env.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/build-env.sh
source "$ROOT/tools/build-env.sh"
PC="${GLIDE_VIEWER_SSH:?set GLIDE_VIEWER_SSH to the ssh host of the Windows PC}"
DIR="${GLIDE_VIEWER_DIR:-glide}"
EXE="$ROOT/windows/target/x86_64-pc-windows-gnu/release/glide-client.exe"
[[ -f "$EXE" ]] || { echo "build first: cargo build --release --target x86_64-pc-windows-gnu"; exit 1; }
scp -q "$EXE" "$PC:$DIR/dev/glide-client.new.exe"
ssh -o BatchMode=yes "$PC" "Set-Location (Join-Path \$HOME '$DIR'); \$exe = Join-Path (Get-Location) 'glide-client.exe'; Get-Process glide-client -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1; Remove-Item glide-client.old.exe -ErrorAction SilentlyContinue; if (Test-Path glide-client.exe) { Rename-Item glide-client.exe glide-client.old.exe }; Move-Item dev\\glide-client.new.exe glide-client.exe; schtasks /create /tn GlideStart /tr \"\$exe\" /sc once /st 23:59 /it /f | Out-Null; schtasks /run /tn GlideStart | Out-Null; Start-Sleep 3; schtasks /delete /tn GlideStart /f | Out-Null; 'viewer pid: ' + (Get-Process glide-client).Id"
