param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArguments
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$drive = 'L:'
$mappedHere = $false
$exitCode = 0

if (Test-Path -LiteralPath "$drive\") {
    throw "$drive is already in use. Free the drive letter before continuing."
}
try {
    & subst.exe $drive $projectRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to map the project root to $drive"
    }
    $mappedHere = $true

    $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:PUB_CACHE = "$drive\.tools\pub-cache"
    $env:ANDROID_SDK_ROOT = "$drive\.tools\android-sdk"
    $env:ANDROID_HOME = $env:ANDROID_SDK_ROOT
    $env:ANDROID_USER_HOME = "$drive\.tools\android-user-home"
    # Keep Gradle on the ASCII mapped path. Java cannot reliably decode this
    # machine's Chinese Windows user path when invoked through flutter.bat.
    $env:GRADLE_USER_HOME = "$drive\.tools\gradle-home"

    $jdkHome = Get-ChildItem -LiteralPath "$drive\.tools\jdk-17" -Directory `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $jdkHome) {
        throw 'JDK 17 was not found under .tools/jdk-17.'
    }
    $env:JAVA_HOME = $jdkHome.FullName
    $env:Path = "$($env:JAVA_HOME)\bin;$($env:ANDROID_SDK_ROOT)\platform-tools;$env:Path"

    Push-Location -LiteralPath "$drive\app"
    try {
        & "$drive\.tools\flutter\bin\flutter.bat" @FlutterArguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($mappedHere) {
        & subst.exe $drive /D
    }
}

exit $exitCode
