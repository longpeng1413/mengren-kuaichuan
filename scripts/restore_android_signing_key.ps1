$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $projectRoot 'private-signing\debug.keystore'
$destinationDirectory = Join-Path $projectRoot '.tools\android-user-home'
$destination = Join-Path $destinationDirectory 'debug.keystore'

if (-not (Test-Path -LiteralPath $source)) {
    throw "没有找到开发资料包中的签名密钥：$source"
}

New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null

if (Test-Path -LiteralPath $destination) {
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) {
        throw "目标位置已有不同的签名密钥，为防止误覆盖已停止。请先人工核对：$destination"
    }
    Write-Host 'Android 签名密钥已经是正确版本，无需重复复制。'
    exit 0
}

Copy-Item -LiteralPath $source -Destination $destination
Write-Host "Android 签名密钥已恢复到：$destination"
