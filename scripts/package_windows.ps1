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
Copy-Item `
    -Path (Join-Path $projectRoot 'packaging\windows\enable_lan_access.*') `
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
