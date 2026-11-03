param(
    # Only for testing: write the shortcut somewhere other than the desktop.
    [string]$DesktopPath
)

$ErrorActionPreference = 'Stop'

try {
    $program = Join-Path $PSScriptRoot '猛人快传.exe'
    if (-not (Test-Path -LiteralPath $program -PathType Leaf)) {
        throw '这个文件夹里没有找到“猛人快传.exe”。请把本文件和猛人快传程序放在同一个文件夹里再运行。'
    }
    $program = (Resolve-Path -LiteralPath $program).Path

    $desktop = if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
        [Environment]::GetFolderPath('Desktop')
    } else {
        $DesktopPath
    }
    $link = Join-Path $desktop '猛人快传.lnk'

    $shell = New-Object -ComObject WScript.Shell
    $previousTarget = $null
    if (Test-Path -LiteralPath $link -PathType Leaf) {
        $previousTarget = $shell.CreateShortcut($link).TargetPath
    }

    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $program
    $shortcut.WorkingDirectory = Split-Path -Parent $program
    $shortcut.IconLocation = "$program,0"
    $shortcut.Description = '猛人快传：局域网互传文字、图片和文件'
    $shortcut.Save()

    Write-Host ''
    Write-Host '已在桌面创建快捷方式“猛人快传”。' -ForegroundColor Green
    Write-Host "指向：$program"
    if ($previousTarget -and ($previousTarget -ne $program)) {
        Write-Host "（已替换桌面上原来的快捷方式，它原来指向：$previousTarget）"
    }
    Write-Host ''
    Write-Host '以后在软件里一键更新时，程序文件夹不变，这个快捷方式会一直有效。'
} catch {
    Write-Host ''
    Write-Host "创建快捷方式失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
