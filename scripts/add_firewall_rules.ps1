param([string]$ProgramPath)

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ProgramPath)) {
    $ProgramPath = Join-Path $projectRoot 'app\build\windows\x64\runner\Release\lan_transfer.exe'
}

& (Join-Path $projectRoot 'packaging\windows\enable_lan_access.ps1') `
    -ProgramPath $ProgramPath
