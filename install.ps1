<#
Glide viewer installer and setup assistant for Windows 10/11 (x64).

  irm https://raw.githubusercontent.com/sudoBrandino/glide/main/install.ps1 | iex

It downloads the latest release, checks it against SHA256SUMS, installs glide-client.exe (in
the folder an existing viewer already uses, so firewall rules keep applying), asks which side
connects, offers a Windows Firewall rule, adds Start menu (and optionally sign-in) shortcuts and
starts the viewer for pairing. Run it again to update. No administrator rights are needed except
for the optional firewall rule, which asks for them separately.

Options, with the script saved to a file (.\install.ps1 -Mac 192.168.1.50) or in one line:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/sudoBrandino/glide/main/install.ps1))) -Listen
  -Version X.Y.Z   install that release instead of the latest one
  -Zip PATH        install from a downloaded Glide-Viewer zip instead of downloading
  -Dir PATH        install folder (default: the current viewer's folder, else %LOCALAPPDATA%\Glide)
  -Mac ADDRESS     this PC connects to the Mac at ADDRESS
  -Listen          the Mac connects to this PC (glide-client.exe --listen)
  -Yes             unattended: no questions, no firewall rule, don't start the viewer
  -NoLaunch        don't start the viewer at the end
  -Uninstall       remove the viewer and its shortcuts (-Purge also removes the settings, this
                   PC's key and the pairing in %APPDATA%\Glide)
#>

# Everything runs in a child scope, parameters included: with `irm | iex` this script runs inside
# the caller's session, so it must not change their variables or preferences or leave functions
# behind, and must never call `exit` (that would close their PowerShell window). The options
# reach the block through @args, both when the script runs as a file and as a scriptblock.
& {
    param(
        [string]$Version,
        [string]$Zip,
        [string]$Dir,
        [string]$Mac,
        [switch]$Listen,
        [switch]$Yes,
        [switch]$NoLaunch,
        [switch]$Uninstall,
        [switch]$Purge
    )
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        Write-Host 'error: the Glide viewer runs on Windows. On the Mac, use install.sh (see docs/INSTALL.md).' -ForegroundColor Red
        return
    }
    $Repo = if ($env:GLIDE_REPO) { $env:GLIDE_REPO } else { 'sudoBrandino/glide' }
    $Port = 7420
    $ExeName = 'glide-client.exe'
    $ShortcutName = 'Glide Viewer.lnk'
    $StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) $ShortcutName
    $Startup = Join-Path ([Environment]::GetFolderPath('Startup')) $ShortcutName
    $ConfigDir = Join-Path $env:APPDATA 'Glide'
    $state = @{ Step = 0 }
    $Interactive = -not $Yes

    function Step([string]$Text) {
        $state.Step++
        Write-Host ''
        Write-Host ("[{0}] {1}" -f $state.Step, $Text) -ForegroundColor Cyan
    }
    function Info([string]$Text) { Write-Host "    $Text" }
    function Ok([string]$Text) { Write-Host '    ' -NoNewline; Write-Host 'OK' -ForegroundColor Green -NoNewline; Write-Host " $Text" }
    function Warn([string]$Text) { Write-Host '    ' -NoNewline; Write-Host '!' -ForegroundColor Yellow -NoNewline; Write-Host " $Text" }

    function Ask([string]$Question, [string]$Default = '') {
        if (-not $Interactive) { return $Default }
        $hint = if ($Default) { " [$Default]" } else { '' }
        $answer = Read-Host "    $Question$hint"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        return $answer.Trim()
    }

    function Confirm([string]$Question, [bool]$Default) {
        if (-not $Interactive) { return $Default }
        $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
        while ($true) {
            $answer = Read-Host "    $Question $hint"
            if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
            switch -Regex ($answer.Trim()) {
                '^(y|yes)$' { return $true }
                '^(n|no)$' { return $false }
            }
        }
    }

    function Get-Download([string]$Url, [string]$OutFile) {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -UserAgent 'glide-installer'
    }

    function Test-Port([string]$HostName, [int]$PortNumber) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect($HostName, $PortNumber, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne(3000)) { return $false }
            $client.EndConnect($async)
            return $true
        } catch { return $false } finally { $client.Close() }
    }

    function Split-HostPort([string]$Address) {
        if ($Address -match '^(.+):(\d+)$') { return @($Matches[1], [int]$Matches[2]) }
        return @($Address, $Port)
    }

    # Single-quoted PowerShell literal, for the elevated firewall command.
    function Quote([string]$Text) { "'" + $Text.Replace("'", "''") + "'" }

    function Get-ShortcutInfo([string]$Path) {
        if (-not (Test-Path $Path)) { return $null }
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        return @{ Target = $lnk.TargetPath; Arguments = $lnk.Arguments }
    }

    function Set-Shortcut([string]$Path, [string]$Target, [string]$Arguments) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        $lnk.TargetPath = $Target
        $lnk.Arguments = $Arguments
        $lnk.WorkingDirectory = Split-Path $Target
        $lnk.Description = 'Glide viewer: control your Mac'
        $lnk.Save()
    }

    # Program paths of firewall rules for glide-client.exe (reading them needs no elevation).
    function Get-FirewallPrograms {
        try {
            Get-NetFirewallApplicationFilter -ErrorAction Stop |
                Where-Object { $_.Program -like "*\$ExeName" } |
                ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Program) } |
                Select-Object -Unique
        } catch { @() }
    }

    # Enabled inbound rules for this exe (reading them needs no elevation).
    function Get-ViewerRules([string]$Exe) {
        try {
            @(Get-NetFirewallApplicationFilter -Program $Exe -ErrorAction Stop |
                Get-NetFirewallRule -ErrorAction Stop |
                Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' })
        } catch { @() }
    }

    # Where an existing viewer lives: the running one, a firewall rule, a shortcut, or the default.
    # Downloads and temp folders don't count: the viewer shouldn't live there (docs/INSTALL.md).
    function Find-InstallDir {
        $candidates = @()
        $running = Get-Process -Name 'glide-client' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($running -and $running.Path) { $candidates += $running.Path }
        $candidates += @(Get-FirewallPrograms)
        foreach ($s in @($StartMenu, $Startup)) {
            $info = Get-ShortcutInfo $s
            if ($info -and $info.Target) { $candidates += $info.Target }
        }
        $avoid = @((Join-Path $env:USERPROFILE 'Downloads'), [IO.Path]::GetTempPath().TrimEnd('\'))
        foreach ($c in $candidates) {
            if (-not $c -or -not (Test-Path $c)) { continue }
            $folder = Split-Path $c
            if (@($avoid | Where-Object { $folder -like "$_*" }).Count -gt 0) { continue }
            return $folder
        }
        return (Join-Path $env:LOCALAPPDATA 'Glide')
    }

    function Stop-Viewer {
        $procs = @(Get-Process -Name 'glide-client' -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { return $true }
        Info 'The viewer is running. It has to close to be replaced.'
        if (-not (Confirm 'Close it now?' $true)) { return $false }
        $procs | Stop-Process -Force
        $procs | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
        Ok 'closed the viewer'
        return $true
    }

    function Get-LocalAddress {
        try {
            Get-NetIPConfiguration -ErrorAction Stop |
                Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
                ForEach-Object { $_.IPv4Address.IPAddress } | Select-Object -First 1
        } catch { $null }
    }

    function Install-Viewer {
        Write-Host 'Glide viewer setup' -NoNewline; Write-Host " ($Repo)" -ForegroundColor DarkGray

        if (-not [Environment]::Is64BitOperatingSystem) { throw 'the Glide viewer needs 64-bit Windows 10 or 11.' }
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
            Warn 'This PC has an ARM processor: the x64 viewer runs under emulation and is untested there.'
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("glide-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            # 1. Get the zip.
            if ($Zip) {
                Step "Using $Zip"
                if (-not (Test-Path $Zip)) { throw "$Zip not found" }
                $zipPath = (Resolve-Path $Zip).Path
                $source = "$Zip"
            } else {
                Step 'Downloading the Glide viewer'
                $ver = $Version
                if (-not $ver) {
                    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UserAgent 'glide-installer'
                    $ver = $release.tag_name
                }
                $ver = $ver.TrimStart('v')
                $name = "Glide-Viewer-$ver-windows-x64.zip"
                $base = "https://github.com/$Repo/releases/download/v$ver"
                Get-Download "$base/SHA256SUMS" (Join-Path $tmp 'SHA256SUMS')
                $want = Get-Content (Join-Path $tmp 'SHA256SUMS') | ForEach-Object {
                    $parts = $_ -split '\s+', 2
                    if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $name) { $parts[0] }
                } | Select-Object -First 1
                if (-not $want) { throw "release v$ver has no $name" }
                Info "release v${ver}: $name"
                $zipPath = Join-Path $tmp $name
                Get-Download "$base/$name" $zipPath
                $got = (Get-FileHash $zipPath -Algorithm SHA256).Hash
                if ($got -ne $want.ToUpperInvariant()) { throw "checksum mismatch for $name (expected $want, got $got). Not installing." }
                Ok 'checksum matches SHA256SUMS'
                $source = "release v$ver"
            }
            Expand-Archive -Path $zipPath -DestinationPath (Join-Path $tmp 'unzip') -Force
            $newExe = Get-ChildItem -Path (Join-Path $tmp 'unzip') -Recurse -Filter $ExeName | Select-Object -First 1
            if (-not $newExe) { throw "the zip holds no $ExeName" }

            # 2. Where to put it.
            Step 'Installing'
            $target = if ($Dir) { $Dir } else { Find-InstallDir }
            if (-not $Dir) {
                Info 'Keep the viewer in one folder: Windows Firewall rules are tied to the path of the exe.'
                $target = Ask 'Install folder:' $target
            }
            $exe = Join-Path $target $ExeName
            $old = $null
            if (Test-Path $exe) {
                $old = (& $exe --version 2>$null | Select-Object -First 1)
            }
            if (-not (Stop-Viewer)) { throw 'the viewer is still running; close it and run this again' }
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            $files = @(Get-ChildItem -Path $newExe.DirectoryName -File)
            $files | Copy-Item -Destination $target -Force
            # Only the files just copied: no "Windows protected your PC" prompt for them.
            $files | ForEach-Object { Unblock-File -Path (Join-Path $target $_.Name) }
            $new = (& $exe --version 2>$null | Select-Object -First 1)
            if ($old) { Ok "updated $old -> $new" } else { Ok "installed $new ($source)" }
            Info $exe

            # 3. Which side connects.
            $existing = Get-ShortcutInfo $StartMenu
            $viewerArgs = $null
            if ($Mac) {
                $viewerArgs = $Mac
            } elseif ($Listen) {
                $viewerArgs = '--listen'
            } elseif ($Interactive) {
                Step 'How should the PC and the Mac connect?'
                Info "1) This PC connects to the Mac (the Mac listens on port $Port)"
                Info '2) The Mac connects to this PC (the viewer listens; use this when the Mac can'
                Info '   reach the PC but not the other way round)'
                $default = '1'
                if ($existing -and $existing.Arguments -match '--listen') { $default = '2' }
                $choice = Ask 'Choose 1 or 2:' $default
                if ($choice -eq '2') {
                    $viewerArgs = '--listen'
                } else {
                    $prev = if ($existing -and $existing.Arguments -and $existing.Arguments -notmatch '^--') { $existing.Arguments } else { '' }
                    $addr = Ask "The Mac's address (name or IP, optionally :port):" $prev
                    if (-not $addr) { throw 'no address given' }
                    $viewerArgs = $addr
                }
            } elseif ($existing) {
                $viewerArgs = $existing.Arguments
            } else {
                $viewerArgs = ''
            }

            if ($viewerArgs -eq '--listen') {
                Ok "the viewer waits for the Mac on port $Port"
                $ip = Get-LocalAddress
                Info ("On the Mac, choose 'This Mac connects to the PC' in the setup, with this PC's address" + $(if ($ip) { ": $ip" } else { '.' }))
                $rules = Get-ViewerRules $exe
                $blocking = @($rules | Where-Object { $_.Action -eq 'Block' })
                $allowing = @($rules | Where-Object { $_.Action -eq 'Allow' -and "$($_.Profile)" -match 'Any|Private' })
                if ($blocking.Count -gt 0) {
                    # Windows adds these when its first-run prompt is cancelled; Block beats Allow.
                    Warn "Windows Firewall blocks the viewer: $(($blocking | ForEach-Object { $_.DisplayName }) -join ', ')"
                }
                if ($allowing.Count -gt 0 -and $blocking.Count -eq 0) {
                    Ok 'a Windows Firewall rule already admits the viewer on Private networks'
                } elseif ($Interactive) {
                    Info 'Windows Firewall has to let the Mac in. Changing it needs administrator rights (Windows asks).'
                    $question = if ($blocking.Count -gt 0) { 'Remove the blocking rules and allow the viewer (Private networks only)?' } else { 'Add a firewall rule for the viewer (Private networks only)?' }
                    if (Confirm $question $true) {
                        $remote = Ask "Only allow the Mac's IP address? (Enter for any address on Private networks)" ''
                        $cmd = ''
                        if ($blocking.Count -gt 0) {
                            $cmd = "Get-NetFirewallApplicationFilter -Program $(Quote $exe) | Get-NetFirewallRule | Where-Object { `$_.Direction -eq 'Inbound' -and `$_.Action -eq 'Block' } | Remove-NetFirewallRule; "
                        }
                        $cmd += "New-NetFirewallRule -DisplayName 'Glide viewer' -Direction Inbound -Program $(Quote $exe) -Protocol TCP -LocalPort $Port -Action Allow -Profile Private"
                        if ($remote) { $cmd += " -RemoteAddress $(Quote $remote)" }
                        try {
                            $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
                                -ArgumentList @('-NoProfile', '-Command', $cmd)
                            if ($p.ExitCode -eq 0) { Ok 'added the firewall rule' } else { Warn "the firewall command failed (exit $($p.ExitCode))" }
                        } catch {
                            Warn 'no firewall rule (administrator rights declined). Windows asks on the first connection instead.'
                        }
                    }
                }
            } elseif ($viewerArgs) {
                Ok "the viewer connects to $viewerArgs"
                $hp = Split-HostPort $viewerArgs
                if (Test-Port $hp[0] $hp[1]) {
                    Ok "the Mac answers on port $($hp[1])"
                } else {
                    Warn "nothing answers at $($hp[0]):$($hp[1]) yet. Is Glide Host running on the Mac (menu bar icon)?"
                    Warn 'The viewer keeps retrying, so it connects once the host is reachable.'
                }
            }

            # 4. Shortcuts.
            Set-Shortcut $StartMenu $exe $viewerArgs
            Ok "Start menu: Glide Viewer$(if ($viewerArgs) { " ($viewerArgs)" })"
            $startupDefault = ($viewerArgs -eq '--listen') -or (Test-Path $Startup)
            if (Confirm 'Start the viewer when you sign in to Windows?' $startupDefault) {
                Set-Shortcut $Startup $exe $viewerArgs
                Ok 'starts at sign-in'
            } elseif (Test-Path $Startup) {
                Remove-Item $Startup -Force
                Ok 'no longer starts at sign-in'
            }

            # 5. Start it; pairing happens in the viewer.
            if (-not $NoLaunch -and $Interactive -and (Confirm 'Start the viewer now?' $true)) {
                if ($viewerArgs) { Start-Process -FilePath $exe -ArgumentList $viewerArgs -WorkingDirectory $target }
                else { Start-Process -FilePath $exe -WorkingDirectory $target }
                Ok 'started'
                Info 'First connection: the PC and the Mac both show a 6-digit code. If they match,'
                Info 'confirm on both. On the Mac: menu bar -> Glide -> Pair New Viewer... (or glide-setup).'
            }

            Write-Host ''
            Write-Host "Glide viewer is set up." -ForegroundColor Green
            Info "Viewer:   $exe"
            Info "Settings: $ConfigDir\config.json (tray icon -> Open config file)"
            Info 'Run this installer again to update or change the connection.'
        } finally {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }
    }

    function Uninstall-Viewer {
        Step 'Uninstalling the Glide viewer'
        $target = if ($Dir) { $Dir } else { Find-InstallDir }
        if (-not (Stop-Viewer)) { throw 'the viewer is still running' }
        $exe = Join-Path $target $ExeName
        if (Test-Path $exe) {
            Remove-Item $exe -Force
            # The zip's text files, but only if they are ours (the folder may hold other files).
            $readme = Join-Path $target 'README.txt'
            if ((Test-Path $readme) -and ((Get-Content $readme -TotalCount 1) -like 'Glide viewer*')) {
                Remove-Item $readme -Force
                Remove-Item (Join-Path $target 'LICENSE.txt') -Force -ErrorAction SilentlyContinue
            }
            if (-not (Get-ChildItem $target -Force)) { Remove-Item $target -Force }
            Ok "removed $exe"
        }
        foreach ($s in @($StartMenu, $Startup)) { if (Test-Path $s) { Remove-Item $s -Force; Ok "removed $s" } }
        if ((Get-ViewerRules $exe).Count -gt 0) {
            Info "A firewall rule still names $exe. Remove it in an administrator PowerShell with:"
            Info "  Get-NetFirewallApplicationFilter -Program $(Quote $exe) | Get-NetFirewallRule | Remove-NetFirewallRule"
        }
        if ($Purge) {
            Remove-Item -Recurse -Force $ConfigDir -ErrorAction SilentlyContinue
            Ok "removed $ConfigDir (settings, this PC's key, the pairing)"
        } else {
            Info "kept $ConfigDir (-Purge removes it)"
        }
    }

    try {
        if ($Mac -and $Listen) { throw '-Mac and -Listen exclude each other' }
        if ($Uninstall) { Uninstall-Viewer } else { Install-Viewer }
    } catch {
        Write-Host ''
        Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    }
} @args
