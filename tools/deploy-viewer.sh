#!/bin/bash
# Deploys the cross-built viewer to the PC (ssh alias "gaming") without touching the firewall rule:
# same path, rename trick, then restarts the viewer in the user's interactive session.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="$ROOT/windows/target/x86_64-pc-windows-gnu/release/glide-client.exe"
[[ -f "$EXE" ]] || { echo "build first: cargo build --release --target x86_64-pc-windows-gnu"; exit 1; }
scp -q "$EXE" my-pc:C:/Users/me/glide/dev/glide-client.new.exe
ssh -o BatchMode=yes gaming 'Set-Location C:\Users\me\glide; Get-Process glide-client -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1; Remove-Item glide-client.old.exe -ErrorAction SilentlyContinue; if (Test-Path glide-client.exe) { Rename-Item glide-client.exe glide-client.old.exe }; Move-Item dev\glide-client.new.exe glide-client.exe; schtasks /create /tn GlideStart /tr "C:\Users\me\glide\glide-client.exe" /sc once /st 23:59 /it /f | Out-Null; schtasks /run /tn GlideStart | Out-Null; Start-Sleep 3; schtasks /delete /tn GlideStart /f | Out-Null; "viewer pid: " + (Get-Process glide-client).Id'
