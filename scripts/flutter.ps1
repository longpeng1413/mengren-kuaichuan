param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArguments
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $projectRoot '.tools'
$exitCode = 0

if (-not (Test-Path -LiteralPath $toolsRoot)) {
    throw "Development tools were not found at $toolsRoot."
}
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:PUB_CACHE = Join-Path $toolsRoot 'pub-cache'
    $env:ANDROID_SDK_ROOT = Join-Path $toolsRoot 'android-sdk'
    $env:ANDROID_HOME = $env:ANDROID_SDK_ROOT
    $env:ANDROID_USER_HOME = Join-Path $toolsRoot 'android-user-home'
    $env:GRADLE_USER_HOME = Join-Path $toolsRoot 'gradle-home'

    $jdkHome = Get-ChildItem -LiteralPath (Join-Path $toolsRoot 'jdk-17') -Directory `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $jdkHome) {
        throw 'JDK 17 was not found under .tools/jdk-17.'
    }
    $env:JAVA_HOME = $jdkHome.FullName
    $env:Path = "$($env:JAVA_HOME)\bin;$($env:ANDROID_SDK_ROOT)\platform-tools;$env:Path"

    Push-Location -LiteralPath (Join-Path $projectRoot 'app')
    try {
        & (Join-Path $toolsRoot 'flutter\bin\flutter.bat') @FlutterArguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
exit $exitCode
