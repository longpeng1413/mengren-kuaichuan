$ErrorActionPreference = 'Stop'

$isAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdministrator) {
    Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')) `
        -Verb RunAs `
        -Wait
    exit
}

$program = Join-Path $PSScriptRoot 'lan_transfer.exe'
if (-not (Test-Path -LiteralPath $program -PathType Leaf)) {
    throw "Application executable not found: $program"
}

$rules = @(
    @{
        Name = 'Mengren Quick Transfer - LAN Discovery (UDP 53317)'
        Protocol = 'UDP'
        Port = 53317
    },
    @{
        Name = 'Mengren Quick Transfer - File Receive (TCP 53318)'
        Protocol = 'TCP'
        Port = 53318
    }
)

foreach ($definition in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $definition.Name -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        $existing | Remove-NetFirewallRule
    }
    New-NetFirewallRule `
        -DisplayName $definition.Name `
        -Group 'Mengren Quick Transfer' `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Profile Domain,Private,Public `
        -Program $program `
        -Protocol $definition.Protocol `
        -LocalPort $definition.Port `
        -RemoteAddress @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16') | Out-Null
}

Write-Host 'Mengren Quick Transfer LAN firewall rules are enabled.' -ForegroundColor Green
