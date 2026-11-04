param(
    [string]$OutputDirectory,
    [string]$PackageSuffix,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot 'dist'
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'flutter.ps1') build windows --release
    if ($LASTEXITCODE -ne 0) {
        throw "Windows build failed with exit code $LASTEXITCODE."
    }
}

$source = Join-Path $projectRoot 'app\build\windows\x64\runner\Release'
if (-not (Test-Path -LiteralPath (Join-Path $source 'lan_transfer.exe') -PathType Leaf)) {
    throw "Windows Release output was not found: $source"
}

$versionMatch = Select-String `
    -LiteralPath (Join-Path $projectRoot 'app\pubspec.yaml') `
    -Pattern '^version:\s*([^+\s]+)'
if ($null -eq $versionMatch) {
    throw 'Unable to read the application version from app/pubspec.yaml.'
}
$versionName = $versionMatch.Matches[0].Groups[1].Value
$suffix = if ([string]::IsNullOrWhiteSpace($PackageSuffix)) {
    ''
} else {
    '-' + $PackageSuffix.Trim().TrimStart('-')
}
$packageName = "猛人快传-windows-x64-v$versionName$suffix"
$staging = Join-Path $OutputDirectory $packageName
$archive = Join-Path $OutputDirectory "$packageName.zip"

if ((Test-Path -LiteralPath $staging) -or (Test-Path -LiteralPath $archive)) {
    throw "Package already exists; use a new PackageSuffix to preserve it: $packageName"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $staging | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $staging -Recurse -Force
# Keep Flutter's internal build target ASCII; expose the product name in the
# portable package. Runtime startup uses Platform.resolvedExecutable.
Rename-Item -LiteralPath (Join-Path $staging 'lan_transfer.exe') -NewName '猛人快传.exe'
# Ship the VC++ runtime next to the EXE (app-local deployment). Binaries built
# with a newer MSVC can crash on a PC whose installed runtime is older, so the
# package must not depend on what each computer happens to have.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot = if (Test-Path -LiteralPath $vswhere) {
    & $vswhere -latest -products * -property installationPath
}
$crt = if ($vsRoot) {
    Get-ChildItem -Path (Join-Path $vsRoot 'VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT') `
        -Directory -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
}
if ($null -eq $crt) {
    throw 'VC++ runtime (VC\Redist\MSVC\...\x64\Microsoft.VC*.CRT) was not found.'
}
foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    Copy-Item -LiteralPath (Join-Path $crt.FullName $dll) -Destination $staging -Force
}
Copy-Item `
    -Path (Join-Path $projectRoot 'packaging\windows\enable_lan_access.*') `
    -Destination $staging `
    -Force
# Double-click helper that puts a desktop shortcut to this folder's EXE.
Copy-Item `
    -Path (Join-Path $projectRoot 'packaging\windows\*.cmd'), `
        (Join-Path $projectRoot 'packaging\windows\create_desktop_shortcut.ps1') `
    -Destination $staging `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $projectRoot 'docs\猛人快传-安装测试说明.txt') `
    -Destination $staging `
    -Force
$versionGuide = Join-Path $projectRoot "docs\猛人快传-v$versionName-安装与测试说明.md"
if (Test-Path -LiteralPath $versionGuide -PathType Leaf) {
    Copy-Item -LiteralPath $versionGuide -Destination $staging
}

Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $archive -CompressionLevel Optimal

Get-FileHash -Algorithm SHA256 -LiteralPath $archive
