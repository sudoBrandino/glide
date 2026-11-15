<#
Glide viewer installer and setup assistant for Windows 10/11 (x64).

  irm https://raw.githubusercontent.com/sudoBrandino/glide/main/install.ps1 | iex

It downloads the latest release, checks it against SHA256SUMS, installs glide-client.exe (in
the folder an existing viewer already uses, so firewall rules keep applying), asks for the Mac's
address and whether the Mac may connect to this PC, saves both in the viewer's settings
(%APPDATA%\Glide\config.json, like the viewer's own setup window), offers a Windows Firewall rule,
adds a Start menu shortcut, optionally starts the viewer at sign-in, and starts it for pairing.
Run it again to update. No administrator rights are needed except for the optional firewall rule,
which asks for them separately.

The viewer dials the Mac when it knows the Mac's address, and also listens on TCP port 7420 so
the Mac can connect to it (unless that is turned off). Whichever direction the network allows
connects.

Options, with the script saved to a file (.\install.ps1 -Mac 192.168.1.50) or in one line:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/sudoBrandino/glide/main/install.ps1))) -Mac 192.168.1.50
  -Version X.Y.Z   install that release instead of the latest one
  -Zip PATH        install from a downloaded Glide-Viewer zip instead of downloading
  -Dir PATH        install folder (default: the current viewer's folder, else %LOCALAPPDATA%\Glide)
  -Mac ADDRESS     the Mac's address: the viewer dials it, and also lets the Mac connect
  -NoListen        with -Mac: dial only, the viewer doesn't listen (config "accept_incoming": false)
  -Listen          forget the Mac's address: the viewer only waits for the Mac to connect
  -Yes             unattended: no questions, keep the connection settings unless -Mac or -Listen
                   says otherwise, no firewall rule, don't start the viewer
  -NoLaunch        don't start the viewer at the end
  -Uninstall       remove the viewer, its shortcut and its sign-in entry (-Purge also removes the
                   settings, this PC's key and the pairing in %APPDATA%\Glide)
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
        [switch]$NoListen,
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
    $FirewallRule = 'Glide Viewer'          # the same name the viewer's setup window uses
    $StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) $ShortcutName
    # Older versions of this script started the viewer at sign-in with a Startup folder shortcut;
    # now it is the same HKCU Run value the viewer's setup window writes.
    $Startup = Join-Path ([Environment]::GetFolderPath('Startup')) $ShortcutName
    $RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $RunValue = 'Glide Viewer'
    $ConfigDir = Join-Path $env:APPDATA 'Glide'
    $ConfigFile = Join-Path $ConfigDir 'config.json'
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

    # Single-quoted PowerShell literal. PowerShell also ends a literal at the typographic quotes
    # U+2018..U+201B, so those are doubled too (doubling keeps the character), like ps_quote in
    # windows/src/setup.rs: a folder such as C:\Users\O<U+2019>Brien stays data.
    function Quote([string]$Text) { "'" + ($Text -replace '([''\u2018-\u201B])', '$1$1') + "'" }

    # Run a script elevated (Windows asks for administrator rights). The full path, so no
    # powershell.exe from the current folder or PATH is picked up, and -EncodedCommand (base64 of
    # UTF-16LE), so nothing in the script is re-parsed or has its spaces collapsed on the way.
    # Returns the exit code; throws when the user declines.
    function Invoke-Elevated([string]$Script) {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ErrorActionPreference = 'Stop'; $Script"))
        $p = Start-Process -FilePath $powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
        return $p.ExitCode
    }

    function Get-ShortcutInfo([string]$Path) {
        if (-not (Test-Path $Path)) { return $null }
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        return @{ Target = $lnk.TargetPath; Arguments = $lnk.Arguments }
    }

    # No arguments: the viewer's settings say where to connect.
    function Set-Shortcut([string]$Path, [string]$Target) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        $lnk.TargetPath = $Target
        $lnk.Arguments = ''
        $lnk.WorkingDirectory = Split-Path $Target
        $lnk.Description = 'Glide viewer: control your Mac'
        $lnk.Save()
    }

    # The exe the sign-in entry starts (the Run value holds it in double quotes), or $null.
    function Get-RunExe {
        try { $v = (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction Stop).$RunValue } catch { return $null }
        if ($v -match '^"([^"]+)"') { return $Matches[1] }
        return $v
    }

    function Get-Autostart { return [bool](Get-RunExe) -or (Test-Path $Startup) }

    function Set-Autostart([bool]$On, [string]$Exe) {
        # An older Startup shortcut may carry old arguments, and two entries would start it twice.
        if (Test-Path $Startup) { Remove-Item $Startup -Force }
        if ($On) {
            New-ItemProperty -Path $RunKey -Name $RunValue -Value ('"' + $Exe + '"') -PropertyType String -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue
        }
    }

    # The viewer's settings. Unknown keys are kept as they are; a file that isn't a JSON object is
    # moved to config.json.bad, as the viewer itself does.
    function Read-ViewerConfig {
        if (-not (Test-Path -LiteralPath $ConfigFile)) { return [pscustomobject]@{ version = 1 } }
        $obj = $null
        try { $obj = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json } catch { $obj = $null }
        if ($obj -is [Management.Automation.PSCustomObject]) { return $obj }
        Move-Item -LiteralPath $ConfigFile -Destination "$ConfigFile.bad" -Force
        Warn "$ConfigFile was not valid; moved it to config.json.bad"
        return [pscustomobject]@{ version = 1 }
    }

    function Get-ConfigValue($Config, [string]$Name) {
        if ($Config.PSObject.Properties[$Name]) { return $Config.$Name }
        return $null
    }

    # $null removes the key (the viewer then uses its default).
    function Set-ConfigValue($Config, [string]$Name, $Value) {
        if ($null -eq $Value) { $Config.PSObject.Properties.Remove($Name); return }
        if ($Config.PSObject.Properties[$Name]) { $Config.$Name = $Value }
        else { $Config | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    }

    # UTF-8 without a byte order mark (the viewer's JSON parser rejects one), written to a temp
    # file and renamed over the old one.
    function Save-ViewerConfig($Config) {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        $json = ConvertTo-Json -InputObject $Config -Depth 32
        $tmpFile = "$ConfigFile.tmp"
        [IO.File]::WriteAllText($tmpFile, $json + "`n", (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmpFile -Destination $ConfigFile -Force
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

    # Where an existing viewer lives: the running one, a firewall rule, a shortcut, the sign-in
    # entry, or the default. Downloads and temp folders don't count: the viewer shouldn't live
    # there (docs/INSTALL.md).
    function Find-InstallDir {
        $candidates = @()
        $running = Get-Process -Name 'glide-client' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($running -and $running.Path) { $candidates += $running.Path }
        $candidates += @(Get-FirewallPrograms)
        foreach ($s in @($StartMenu, $Startup)) {
            $info = Get-ShortcutInfo $s
            if ($info -and $info.Target) { $candidates += $info.Target }
        }
        $runExe = Get-RunExe
        if ($runExe) { $candidates += $runExe }
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

    # Let the Mac in through Windows Firewall: check the rules for the exe, and offer one
    # elevated step that removes Block rules (Windows adds them when its own prompt is
    # cancelled; Block beats Allow) and adds an Allow rule for Private networks.
    function Set-FirewallRule([string]$Exe, [int]$ListenPort) {
        $rules = Get-ViewerRules $Exe
        $blocking = @($rules | Where-Object { $_.Action -eq 'Block' })
        $allowing = @($rules | Where-Object { $_.Action -eq 'Allow' -and "$($_.Profile)" -match 'Any|Private' })
        try {
            if (@(Get-NetConnectionProfile -ErrorAction Stop | Where-Object { $_.NetworkCategory -eq 'Public' }).Count -gt 0) {
                Warn 'This network is set to Public in Windows. Rules for Private networks do not apply there:'
                Warn 'set it to Private (Settings -> Network) if the Mac should connect to this PC.'
            }
        } catch { }
        if ($blocking.Count -gt 0) {
            Warn "Windows Firewall blocks the viewer: $(($blocking | ForEach-Object { $_.DisplayName }) -join ', ')"
        }
        if ($allowing.Count -gt 0 -and $blocking.Count -eq 0) {
            Ok 'a Windows Firewall rule already lets the Mac connect on Private networks'
            return
        }
        if (-not $Interactive) {
            Info 'No firewall rule added (-Yes). Windows asks on the first connection from the Mac.'
            return
        }
        Info 'Windows Firewall has to let the Mac in. Changing it needs administrator rights (Windows asks).'
        $question = if ($blocking.Count -gt 0) { 'Remove the blocking rules and allow the viewer (Private networks only)?' } else { 'Add a firewall rule for the viewer (Private networks only)?' }
        if (-not (Confirm $question $true)) {
            Info 'No firewall rule. Windows asks on the first connection from the Mac instead.'
            return
        }
        $remote = Ask "Only allow the Mac's IP address? (Enter for any address on Private networks)" ''
        $cmd = "`$p = $(Quote $Exe); " +
            "Get-NetFirewallApplicationFilter -Program `$p -ErrorAction SilentlyContinue | Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { `$_.Direction -eq 'Inbound' -and `$_.Action -eq 'Block' } | Remove-NetFirewallRule; " +
            "Get-NetFirewallRule -DisplayName $(Quote $FirewallRule) -ErrorAction SilentlyContinue | Remove-NetFirewallRule; " +
            "New-NetFirewallRule -DisplayName $(Quote $FirewallRule) -Direction Inbound -Program `$p -Protocol TCP -LocalPort $ListenPort -Action Allow -Profile Private"
        if ($remote) { $cmd += " -RemoteAddress $(Quote $remote)" }
        $cmd += ' | Out-Null'
        try {
            $code = Invoke-Elevated $cmd
            if ($code -eq 0) { Ok 'added the firewall rule' } else { Warn "the firewall command failed (exit $code)" }
        } catch {
            Warn 'no firewall rule (administrator rights declined). Windows asks on the first connection instead.'
        }
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

            # 3. The connection, saved in the viewer's settings (the viewer's setup window edits
            # the same two values: "host" and "accept_incoming").
            $config = Read-ViewerConfig
            # Older versions of this script put the Mac's address (or --listen) on the shortcut.
            $legacy = ''
            $existing = Get-ShortcutInfo $StartMenu
            if ($existing -and $existing.Arguments -and $existing.Arguments.Trim() -notmatch '^-') { $legacy = ($existing.Arguments.Trim() -split '\s+')[0] }
            $savedHost = [string](Get-ConfigValue $config 'host')
            $currentHost = if ($savedHost.Trim()) { $savedHost.Trim() } else { $legacy }
            $savedAccept = Get-ConfigValue $config 'accept_incoming'
            $currentAccept = if ($savedAccept -is [bool]) { $savedAccept } else { $true }
            $listenPort = $Port
            $savedPort = (Get-ConfigValue $config 'listen_port') -as [int]
            if ($savedPort -gt 0 -and $savedPort -le 65535) { $listenPort = $savedPort }

            $macAddress = $currentHost
            $accept = $currentAccept
            if ($Mac) {
                $macAddress = $Mac.Trim()
                $accept = -not $NoListen
            } elseif ($Listen) {
                $macAddress = ''
            } elseif ($NoListen) {
                if (-not $currentHost) { throw "-NoListen needs the Mac's address (-Mac)" }
                $accept = $false
            } elseif ($Interactive) {
                Step 'Connecting to the Mac'
                Info "The viewer dials the Mac when it knows the Mac's address, and can also let the Mac"
                Info 'connect to this PC. One direction that your network allows is enough.'
                $question = if ($currentHost) { "The Mac's address (name or IP, optionally :port; - for none):" } else { "The Mac's address (optional; name or IP, optionally :port):" }
                while ($true) {
                    $answer = Ask $question $currentHost
                    $macAddress = if ($answer -eq '-') { '' } else { $answer }
                    if ($macAddress -notmatch '[\s/\\]') { break }
                    Warn "'$macAddress' is not an address: use the Mac's IP address or name, for example 192.168.1.50"
                }
                if ($macAddress) {
                    $accept = Confirm 'Also let the Mac connect to this PC (needs a Windows Firewall rule)?' $currentAccept
                }
            }
            if ($macAddress -match '[\s/\\]') { throw "'$macAddress' is not an address: use the Mac's IP address or name, for example 192.168.1.50" }
            if (-not $macAddress) { $accept = $true }   # without the address the viewer can only wait for the Mac

            Set-ConfigValue $config 'host' $(if ($macAddress) { $macAddress } else { $null })
            Set-ConfigValue $config 'accept_incoming' ([bool]$accept)
            Save-ViewerConfig $config
            Ok "saved in $ConfigFile"

            if ($macAddress) {
                Ok "the viewer dials the Mac at $macAddress"
                $hp = Split-HostPort $macAddress
                if (Test-Port $hp[0] $hp[1]) {
                    Ok "the Mac answers on port $($hp[1])"
                } elseif ($accept) {
                    Info "Nothing answers at $($hp[0]):$($hp[1]) yet. The viewer keeps trying, and the Mac can connect to this PC."
                } else {
                    Warn "nothing answers at $($hp[0]):$($hp[1]) yet. Is Glide Host running on the Mac (menu bar icon)?"
                    Warn 'The viewer keeps retrying, so it connects once the host is reachable.'
                }
            }
            if ($accept) {
                if ($macAddress) { Ok "the viewer also listens on port $listenPort, so the Mac can connect to this PC" }
                else { Ok "the viewer waits for the Mac to connect on port $listenPort" }
                $ip = Get-LocalAddress
                Info ("If only the Mac can reach this PC, enter this PC's address in Glide Host's setup window on the Mac" + $(if ($ip) { ": $ip" } else { '.' }))
                Set-FirewallRule $exe $listenPort
            } else {
                Ok 'the viewer only dials; it does not listen'
            }

            # 4. Shortcut and sign-in entry, both without arguments.
            Set-Shortcut $StartMenu $exe
            Ok 'Start menu: Glide Viewer'
            $autostartNow = Get-Autostart
            if (Confirm 'Start the viewer when you sign in to Windows?' ($autostartNow -or $accept)) {
                Set-Autostart $true $exe
                Ok 'starts at sign-in'
            } elseif ($autostartNow) {
                Set-Autostart $false $exe
                Ok 'no longer starts at sign-in'
            }

            # 5. Start it; pairing happens in the viewer.
            if (-not $NoLaunch -and $Interactive -and (Confirm 'Start the viewer now?' $true)) {
                # Without the Mac's address, --listen says what the settings say; started without
                # arguments, a viewer that isn't paired yet would open its setup window first.
                if ($macAddress) { Start-Process -FilePath $exe -WorkingDirectory $target }
                else { Start-Process -FilePath $exe -ArgumentList @('--listen', "$listenPort") -WorkingDirectory $target }
                Ok 'started'
                Info 'First connection: the PC and the Mac both show a 6-digit code. If they match,'
                Info 'confirm on both. On the Mac: menu bar -> Glide -> Pair New Viewer... (or glide-setup).'
            }

            Write-Host ''
            Write-Host "Glide viewer is set up." -ForegroundColor Green
            Info "Viewer:   $exe"
            Info "Settings: $ConfigFile (Glide menu or tray icon -> Set up...)"
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
        if (Get-RunExe) { Set-Autostart $false $exe; Ok 'removed the sign-in entry' }
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
        if ($NoListen -and $Listen) { throw '-NoListen and -Listen exclude each other' }
        if ($Uninstall) { Uninstall-Viewer } else { Install-Viewer }
    } catch {
        Write-Host ''
        Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    }
} @args
