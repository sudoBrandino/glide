<#
Builds Glide-<version>-windows-x64.msi (packaging/windows/wix/Glide.wxs) with WiX Toolset v5.
Runs on Windows (the release workflow's windows job); WiX does not build MSIs elsewhere.

  pwsh packaging/windows/build-msi.ps1 [-OutDir DIR] [-ExeDir DIR]

  -OutDir   where the MSI goes (default: $env:GLIDE_RELEASE_OUT, else dist\release\<version>,
            like tools/release.sh)
  -ExeDir   folder with glide-client.exe and glide-host.exe (default: <OutDir>\windows, where
            tools/release.sh viewer-build puts them). Sign them first: the MSI embeds them.

The wix .NET tool is installed at the pinned version into a temporary folder (the .NET SDK must
be present, as on GitHub's Windows runners), with the pinned firewall extension. The MSI itself is
signed afterwards (release workflow: Azure Artifact Signing).
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

# The wix tool, pinned.
if (-not $env:DOTNET_ROLL_FORWARD) { $env:DOTNET_ROLL_FORWARD = 'Major' }   # runs on a newer .NET too
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$ToolDir = Join-Path ([IO.Path]::GetTempPath()) "glide-wix-$WixVersion"
$Wix = Join-Path $ToolDir 'wix.exe'
if (-not (Test-Path $Wix)) {
    & dotnet tool install wix --version $WixVersion --tool-path $ToolDir
    if ($LASTEXITCODE -ne 0) { throw "dotnet tool install wix $WixVersion failed" }
}
$got = (& $Wix --version) -replace '\+.*$', ''
if ($got -ne $WixVersion) { throw "wix --version says $got, expected $WixVersion" }
& $Wix extension add -g "WixToolset.Firewall.wixext/$WixVersion"
if ($LASTEXITCODE -ne 0) { throw 'wix extension add failed' }

$Msi = Join-Path $OutDir "Glide-$Version-windows-x64.msi"
Remove-Item -Force -ErrorAction SilentlyContinue $Msi
Write-Host "==> MSI $MsiVersion from $ExeDir"
& $Wix build -arch x64 -pdbtype none `
    -ext WixToolset.Firewall.wixext `
    -d "Version=$MsiVersion" -d "ExeDir=$ExeDir" `
    -o $Msi $Wxs
if ($LASTEXITCODE -ne 0) { throw 'wix build failed' }

# ICE validation, for the log only: it needs the Windows Installer service and its findings are
# advice (the package installs either way).
& $Wix msi validate $Msi
if ($LASTEXITCODE -ne 0) { Write-Warning "ICE validation reported problems (see above); the MSI was built anyway" }
$global:LASTEXITCODE = 0

Get-Item $Msi | Format-Table Name, Length -AutoSize
Write-Host "wrote $Msi"
