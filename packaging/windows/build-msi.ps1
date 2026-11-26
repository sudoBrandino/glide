<#
Builds Glide-<version>-windows-x64.msi (packaging/windows/wix/Glide.wxs) with WiX Toolset v5.
Runs on Windows (the release workflow's windows job); WiX does not build MSIs elsewhere.

  pwsh packaging/windows/build-msi.ps1 [-OutDir DIR] [-ExeDir DIR]

  -OutDir   where the MSI goes (default: $env:GLIDE_RELEASE_OUT, else dist\release\<version>,
            like tools/release.sh)
  -ExeDir   folder with glide-client.exe and glide-host.exe (default: <OutDir>\windows, where
            tools/release.sh viewer-build puts them). Sign them first: the MSI embeds them.

Supply chain: the wix .NET tool and the firewall extension are downloaded from nuget.org at pinned
versions and checked against the SHA-512 hashes in packaging/windows/wix/packages.sha512 (the
same hashes nuget.org's catalog lists) before anything runs. The tool is installed from that
local folder only (a nuget.config with no other source, an empty package cache), and the
extension is loaded straight from its verified package. Needs the .NET SDK, as on GitHub's
Windows runners. The MSI itself is signed afterwards (release workflow: Azure Artifact Signing).

To move to another WiX version: change $WixVersion, download both .nupkg files, compare their
SHA-512 with nuget.org's catalog entry (packageHash, base64), and update packages.sha512.
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$ExeDir
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$WixVersion = '5.0.2'   # WiX Toolset v5; the extension version must match
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Wxs = Join-Path $PSScriptRoot 'wix\Glide.wxs'

$Version = (Get-Content (Join-Path $Root 'VERSION') -Raw).Trim()
if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$') { throw "VERSION '$Version' is not X.Y.Z[-pre]" }
# MSI versions are numeric (major.minor.build, each part limited): drop a pre-release suffix.
$MsiVersion = '{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3]
if ([int]$Matches[1] -gt 255 -or [int]$Matches[2] -gt 255 -or [int]$Matches[3] -gt 65535) { throw "VERSION $Version does not fit an MSI version" }

if (-not $OutDir) {
    $OutDir = if ($env:GLIDE_RELEASE_OUT) { $env:GLIDE_RELEASE_OUT } else { Join-Path $Root "dist\release\$Version" }
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
if (-not $ExeDir) { $ExeDir = Join-Path $OutDir 'windows' }
foreach ($exe in 'glide-client.exe', 'glide-host.exe') {
    if (-not (Test-Path (Join-Path $ExeDir $exe))) { throw "no $exe in $ExeDir (run: tools/release.sh viewer-build)" }
}
$ExeDir = (Resolve-Path $ExeDir).Path

# The wix tool and the firewall extension, pinned by version and content hash.
$Hashes = @{}
foreach ($line in Get-Content (Join-Path $PSScriptRoot 'wix\packages.sha512')) {
    if ($line -match '^([0-9a-f]{128})\s+(\S+)$') { $Hashes[$Matches[2]] = $Matches[1] }
}
$Work = Join-Path ([IO.Path]::GetTempPath()) ("glide-wix-" + [Guid]::NewGuid().ToString('N'))
$Feed = Join-Path $Work 'feed'
New-Item -ItemType Directory -Force -Path $Feed | Out-Null
function Get-VerifiedPackage([string]$Id) {
    $file = "$Id.$WixVersion.nupkg".ToLowerInvariant()
    $want = $Hashes[$file]
    if (-not $want) { throw "packages.sha512 has no hash for $file" }
    $path = Join-Path $Feed $file
    $url = "https://api.nuget.org/v3-flatcontainer/$($Id.ToLowerInvariant())/$WixVersion/$file"
    Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
    $got = (Get-FileHash -Algorithm SHA512 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($got -ne $want) { throw "$file has SHA-512 $got, expected $want (packages.sha512)" }
    Write-Host "verified $file"
    return $path
}
$ProgressPreference = 'SilentlyContinue'
[void](Get-VerifiedPackage 'wix')
$FirewallPkg = Get-VerifiedPackage 'WixToolset.Firewall.wixext'

if (-not $env:DOTNET_ROLL_FORWARD) { $env:DOTNET_ROLL_FORWARD = 'Major' }   # runs on a newer .NET too
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:NUGET_PACKAGES = Join-Path $Work 'packages'   # no package cached earlier can stand in
$NugetConfig = Join-Path $Work 'nuget.config'
@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="verified" value="$Feed" />
  </packageSources>
</configuration>
"@ | Set-Content -LiteralPath $NugetConfig -Encoding utf8
$ToolDir = Join-Path $Work 'tool'
& dotnet tool install wix --version $WixVersion --tool-path $ToolDir --configfile $NugetConfig
if ($LASTEXITCODE -ne 0) { throw "dotnet tool install wix $WixVersion failed" }
$Wix = Join-Path $ToolDir 'wix.exe'
$got = (& $Wix --version) -replace '\+.*$', ''
if ($got -ne $WixVersion) { throw "wix --version says $got, expected $WixVersion" }

# The extension: a .nupkg is a zip; wix loads the extension DLL from a path.
$ExtDir = Join-Path $Work 'firewall'
Copy-Item -LiteralPath $FirewallPkg -Destination "$ExtDir.zip"
Expand-Archive -LiteralPath "$ExtDir.zip" -DestinationPath $ExtDir
$FirewallExt = Join-Path $ExtDir 'wixext5\WixToolset.Firewall.wixext.dll'
if (-not (Test-Path -LiteralPath $FirewallExt)) { throw "no wixext5\WixToolset.Firewall.wixext.dll in $FirewallPkg" }

$Msi = Join-Path $OutDir "Glide-$Version-windows-x64.msi"
Remove-Item -Force -ErrorAction SilentlyContinue $Msi
Write-Host "==> MSI $MsiVersion from $ExeDir"
& $Wix build -arch x64 -pdbtype none `
    -ext $FirewallExt `
    -d "Version=$MsiVersion" -d "ExeDir=$ExeDir" `
    -o $Msi $Wxs
if ($LASTEXITCODE -ne 0) { throw 'wix build failed' }

# ICE validation, for the log only: it needs the Windows Installer service and its findings are
# advice (the package installs either way).
& $Wix msi validate $Msi
if ($LASTEXITCODE -ne 0) { Write-Warning "ICE validation reported problems (see above); the MSI was built anyway" }
$global:LASTEXITCODE = 0

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Work
Get-Item $Msi | Format-Table Name, Length -AutoSize
Write-Host "wrote $Msi"
