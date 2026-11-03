/// Written into the update cache and run by Windows PowerShell 5.1.
///
/// `extract` runs while the app is still open. `apply` is started detached:
/// it waits for the app to exit, backs up every file it is about to replace,
/// copies the new files over the install folder (other files are kept), rolls
/// back on failure, records the outcome and restarts the app. Keep this
/// script ASCII-only so PowerShell 5.1 reads it correctly without a BOM.
const windowsUpdateScript = r'''
param(
  [Parameter(Mandatory = $true)][ValidateSet('extract', 'apply')][string]$Mode,
  [string]$Zip,
  [string]$Staging,
  [string]$Target,
  [string]$ExeName,
  [string]$Backup,
  [string]$ResultFile,
  [string]$Version,
  [int]$ProcessId = 0,
  [int]$Retries = 10,
  [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

if ($Mode -eq 'extract') {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if (Test-Path -LiteralPath $Staging) {
    Remove-Item -LiteralPath $Staging -Recurse -Force
  }
  [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Staging)
  exit 0
}

function Write-UpdateResult([bool]$Ok, [string]$Message) {
  $payload = @{
    ok = $Ok
    version = $Version
    message = $Message
    time = (Get-Date).ToString('o')
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText(
    $ResultFile,
    $payload,
    (New-Object System.Text.UTF8Encoding($false))
  )
}

function Copy-WithRetry([string]$Source, [string]$Destination) {
  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    try {
      Copy-Item -LiteralPath $Source -Destination $Destination -Force
      return
    } catch {
      if ($attempt -ge $Retries) { throw }
      Start-Sleep -Milliseconds 500
    }
  }
}

try {
  if ($ProcessId -gt 0) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -ne $process) {
      if (-not $process.WaitForExit(60000)) {
        throw 'The running app did not exit within 60 seconds.'
      }
    }
    Start-Sleep -Milliseconds 500
  }

  if (Test-Path -LiteralPath $Backup) {
    Remove-Item -LiteralPath $Backup -Recurse -Force
  }
  New-Item -ItemType Directory -Path $Backup -Force | Out-Null

  $stagingRoot = (Resolve-Path -LiteralPath $Staging).ProviderPath.TrimEnd('\')
  $files = @(Get-ChildItem -LiteralPath $stagingRoot -Recurse -File)
  if ($files.Count -eq 0) { throw 'The extracted update is empty.' }
  $replaced = New-Object System.Collections.Generic.List[string]
  $created = New-Object System.Collections.Generic.List[string]

  try {
    foreach ($file in $files) {
      $relative = $file.FullName.Substring($stagingRoot.Length + 1)
      $destination = Join-Path $Target $relative
      $destinationFolder = Split-Path -Parent $destination
      if (-not (Test-Path -LiteralPath $destinationFolder)) {
        New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
      }
      if (Test-Path -LiteralPath $destination) {
        $backupPath = Join-Path $Backup $relative
        $backupFolder = Split-Path -Parent $backupPath
        if (-not (Test-Path -LiteralPath $backupFolder)) {
          New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        }
        Copy-Item -LiteralPath $destination -Destination $backupPath -Force
        $replaced.Add($relative)
      } else {
        $created.Add($relative)
      }
      Copy-WithRetry $file.FullName $destination
    }
  } catch {
    $failure = $_.Exception.Message
    foreach ($relative in $replaced) {
      try {
        Copy-Item -LiteralPath (Join-Path $Backup $relative) `
          -Destination (Join-Path $Target $relative) -Force
      } catch {}
    }
    foreach ($relative in $created) {
      try {
        Remove-Item -LiteralPath (Join-Path $Target $relative) -Force
      } catch {}
    }
    throw "Copy failed and the previous version was restored: $failure"
  }

  Write-UpdateResult $true ''
} catch {
  try { Write-UpdateResult $false $_.Exception.Message } catch {}
}

if (-not $NoRestart) {
  $launcher = Join-Path $Target $ExeName
  if (Test-Path -LiteralPath $launcher) {
    Start-Process -FilePath $launcher -WorkingDirectory $Target
  }
}
''';
