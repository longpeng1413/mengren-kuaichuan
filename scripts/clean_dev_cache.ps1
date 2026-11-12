<#
.SYNOPSIS
    清理猛人快传开发文件夹里的编译缓存、日志和旧安装包。

.DESCRIPTION
    三种模式：
      Report        只统计各处占用空间，不删除任何东西。
      Routine       定量清理（默认）。只删除超过保留期限或大小上限的部分，随时可以运行。
                    scripts\flutter.ps1 每天第一次运行时会自动调用（带 -IfDue）。
      AfterRelease  发布完成后的彻底清理（一键清空）。删除所有能自动重新生成的编译产物，
                    下次编译会慢几分钟（需要重新生成），但不需要联网。

    永远不会删除：.tools 里的 Flutter / 安卓 SDK / JDK / 依赖包缓存 / 当前 Gradle 版本、
    dist\猛人快传（本机正在使用的程序）、private-signing（签名密钥）、源代码、.git。

    删除时遇到「链接文件夹」（junction / 符号链接）只删链接本身，绝不进入链接删除目标里的文件
    （Windows PowerShell 5.1 自带的递归删除会顺着链接删，app\windows\flutter\ephemeral 里就有
    指向依赖包缓存的链接）。

.EXAMPLE
    .\scripts\clean_dev_cache.ps1 -Mode Report
    .\scripts\clean_dev_cache.ps1                      # 定量清理
    .\scripts\clean_dev_cache.ps1 -Mode AfterRelease   # 发布完成后
    .\scripts\clean_dev_cache.ps1 -Mode AfterRelease -DryRun   # 只看会删什么
#>
param(
    [ValidateSet('Report', 'Routine', 'AfterRelease')]
    [string]$Mode = 'Routine',
    # 距离上次清理不到 20 小时就直接退出（给 flutter.ps1 每次运行时调用）。
    [switch]$IfDue,
    # 只列出会删除什么，不真正删除。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$toolsRoot = Join-Path $projectRoot '.tools'
$gradleHome = Join-Path $toolsRoot 'gradle-home'
$appRoot = Join-Path $projectRoot 'app'
$distRoot = Join-Path $projectRoot 'dist'
$stampFile = Join-Path $toolsRoot '.cache-cleanup-last-run'

# ---- 保留期限和大小上限（定量清理用；改动时同步 AGENTS.md「缓存清理规则」）----
$limits = @{
    GradleLogDays         = 7      # Gradle 后台进程日志保留 7 天
    GradleLogMaxMB        = 50     # 且总共不超过 50 MB
    GradleTmpDays         = 1      # Gradle 下载/临时残留 1 天
    GradleTransformsMaxMB = 4096   # Gradle 依赖加工缓存超过 4 GB 整个删掉重建
    AppBuildMaxMB         = 5120   # app\build 编译产物超过 5 GB 整个删掉重建
    TestCacheMaxMB        = 1024   # 测试编译缓存超过 1 GB 删掉
    FlutterCrashLogDays   = 7      # flutter_XX.log 崩溃日志保留 7 天
    GradleCreatedDays     = 7      # 写进 Gradle 自带清理：编译生成的缓存 7 天没用就删
    GradleDownloadedDays  = 30     # 下载的依赖 30 天没用才删（重新下载需要联网）
}

if ($IfDue -and (Test-Path -LiteralPath $stampFile)) {
    $last = (Get-Item -LiteralPath $stampFile).LastWriteTime
    if ($last -gt (Get-Date).AddHours(-20)) { return }
}

$script:freed = 0L
$script:failures = 0
$script:actions = New-Object System.Collections.Generic.List[object]
$script:notes = New-Object System.Collections.Generic.List[string]

# ---------------- 工具函数 ----------------

function Get-LongPath([string]$Path) {
    if ($Path.StartsWith('\\?\')) { return $Path }
    return '\\?\' + [IO.Path]::GetFullPath($Path)
}

function Get-Relative([string]$Path) {
    $full = $Path.TrimEnd('\')   # 不用 GetFullPath：合并行的名字里带 * 通配符
    if ($full.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($projectRoot.Length + 1)
    }
    return $full
}

function Test-PathExists([string]$Path) {
    $lp = Get-LongPath $Path
    return [IO.File]::Exists($lp) -or [IO.Directory]::Exists($lp)
}

function Test-IsLink([string]$LongPath) {
    return ([IO.File]::GetAttributes($LongPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

# 统计大小：不进入链接文件夹。
function Get-TreeBytes([string]$Path) {
    $lp = Get-LongPath $Path
    if ([IO.File]::Exists($lp)) { return (New-Object IO.FileInfo $lp).Length }
    if (-not [IO.Directory]::Exists($lp)) { return 0L }
    $total = 0L
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($lp)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            if (Test-IsLink $dir) { continue }
            $info = New-Object IO.DirectoryInfo $dir
            foreach ($f in $info.GetFiles()) { $total += $f.Length }
            foreach ($d in $info.GetDirectories()) { $stack.Push($d.FullName) }
        } catch { }
    }
    return $total
}

# 删除：遇到链接文件夹只删链接本身；删不掉的（正被占用）计数后跳过。
function Remove-Tree([string]$Path) {
    $lp = Get-LongPath $Path
    if ([IO.File]::Exists($lp)) {
        try { [IO.File]::SetAttributes($lp, 'Normal'); [IO.File]::Delete($lp) } catch { $script:failures++ }
        return
    }
    if (-not [IO.Directory]::Exists($lp)) { return }
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($lp)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            if (Test-IsLink $dir) {
                [IO.Directory]::Delete($dir, $false)   # 只删链接，不碰链接指向的文件
                continue
            }
            $dirs.Add($dir)
            foreach ($f in [IO.Directory]::GetFiles($dir)) {
                try { [IO.File]::SetAttributes($f, 'Normal'); [IO.File]::Delete($f) } catch { $script:failures++ }
            }
            foreach ($d in [IO.Directory]::GetDirectories($dir)) { $stack.Push($d) }
        } catch { $script:failures++ }
    }
    for ($i = $dirs.Count - 1; $i -ge 0; $i--) {
        try { [IO.Directory]::Delete($dirs[$i], $false) } catch { }
    }
}

# ---------------- 保护名单 ----------------

$gradleVersion = $null
$wrapperProps = Join-Path $appRoot 'android\gradle\wrapper\gradle-wrapper.properties'
if (Test-Path -LiteralPath $wrapperProps) {
    $m = Select-String -LiteralPath $wrapperProps -Pattern 'gradle-([0-9][0-9.]*[0-9])-(all|bin)\.zip'
    if ($m) { $gradleVersion = $m.Matches[0].Groups[1].Value }
}

$protected = @(
    '.git', 'private-signing', 'dist\猛人快传',
    'app\lib', 'app\test', 'app\assets', 'app\android\app\src', 'app\windows\runner',
    '.tools\flutter', '.tools\pub-cache', '.tools\jdk-17', '.tools\android-user-home',
    '.tools\android-sdk\ndk', '.tools\android-sdk\platforms', '.tools\android-sdk\build-tools',
    '.tools\android-sdk\cmdline-tools', '.tools\android-sdk\cmake', '.tools\android-sdk\platform-tools',
    '.tools\android-sdk\licenses',
    '.tools\gradle-home\caches\modules-2'
) | ForEach-Object { Join-Path $projectRoot $_ }
if ($gradleVersion) {
    $protected += Join-Path $gradleHome "wrapper\dists\gradle-$gradleVersion-all"
    $protected += Join-Path $gradleHome "wrapper\dists\gradle-$gradleVersion-bin"
}

function Assert-Deletable([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $full.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝删除项目文件夹以外的路径：$full"
    }
    foreach ($p in $protected) {
        $p = $p.TrimEnd('\')
        $same = $full.Equals($p, [StringComparison]::OrdinalIgnoreCase)
        $inside = $full.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
        $parent = $p.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)
        if ($same -or $inside -or $parent) { throw "拒绝删除受保护的路径：$full" }
    }
}

# $Group：同类的多个小文件合并成一行显示（例如「daemon\9.3.1\*.log」）。
function Invoke-Clean([string]$Path, [string]$Reason, [string]$Group) {
    if (-not (Test-PathExists $Path)) { return }
    Assert-Deletable $Path
    $before = Get-TreeBytes $Path
    $gone = $before
    if (-not $DryRun) {
        Remove-Tree $Path
        $gone = $before - (Get-TreeBytes $Path)
    }
    $script:freed += $gone
    $label = if ($Group) { $Group } else { Get-Relative $Path }
    $row = $script:actions | Where-Object { $_.'位置' -eq $label } | Select-Object -First 1
    if ($row) {
        $row.'数量' += 1
        $row.'释放MB' = [math]::Round($row.'释放MB' + $gone / 1MB, 1)
        return
    }
    $script:actions.Add([pscustomobject]@{
            '位置'   = $label
            '原因'   = $Reason
            '数量'   = 1
            '释放MB' = [math]::Round($gone / 1MB, 1)
        })
}

function Get-MB([string]$Path) { return [math]::Round((Get-TreeBytes $Path) / 1MB, 1) }

# ---------------- 正在编译时不动 ----------------

function Get-GradleDaemons {
    @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'GradleDaemon|KotlinCompileDaemon|gradle-launcher' })
}

function Test-FlutterBusy {
    $busy = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Name -eq 'flutter_tester.exe') -or
                ($_.Name -match '^dart' -and $_.CommandLine -match 'flutter_tools\.snapshot.*\s(build|test|run|assemble|pub)\b')
            })
    return $busy.Count -gt 0
}

$gradleDaemons = Get-GradleDaemons
if ($Mode -eq 'AfterRelease' -and $gradleDaemons.Count -gt 0 -and -not $DryRun) {
    # 发布完成后 Gradle 后台进程只是空闲待命，停掉才能删它占着的缓存。
    foreach ($p in $gradleDaemons) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Seconds 2
    $script:notes.Add("已停止 $($gradleDaemons.Count) 个空闲的 Gradle 后台编译进程。")
    $gradleDaemons = Get-GradleDaemons
}
$gradleBusy = $gradleDaemons.Count -gt 0
$flutterBusy = Test-FlutterBusy

# ---------------- Report 模式 ----------------

if ($Mode -eq 'Report') {
    $rows = @(
        @('.tools\flutter', 'Flutter SDK（编译必需，不清理）'),
        @('.tools\android-sdk', '安卓 SDK（编译必需，不清理）'),
        @('.tools\pub-cache', '依赖包缓存（编译必需，不清理）'),
        @('.tools\gradle-home\caches\modules-2', 'Gradle 下载的依赖（30 天没用由 Gradle 自动删）'),
        @('.tools\gradle-home\wrapper', 'Gradle 本体'),
        @(".tools\gradle-home\caches\$gradleVersion\transforms", 'Gradle 依赖加工缓存（可清理）'),
        @('.tools\gradle-home\daemon', 'Gradle 后台进程日志（可清理）'),
        @('.tools\gradle-home\.tmp', 'Gradle 临时残留（可清理）'),
        @('app\build', '编译产物（可清理）'),
        @('app\.dart_tool', 'Dart 工具缓存（flutter_build 部分可清理）'),
        @('app\windows\flutter\ephemeral', 'Windows 编译临时文件（可清理）'),
        @('dist', '安装包（只保留最新版和 dist\猛人快传）')
    )
    $total = 0.0
    $table = foreach ($r in $rows) {
        $mb = Get-MB (Join-Path $projectRoot $r[0])
        $total += $mb
        [pscustomobject]@{ '位置' = $r[0]; '说明' = $r[1]; '占用MB' = $mb }
    }
    $table | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host ("以上合计约 {0:N1} GB。一键清空可清理部分：.\scripts\clean_dev_cache.ps1 -Mode AfterRelease" -f ($total / 1024))
    return
}

# ---------------- 让 Gradle 自己也按期限清理 ----------------

$initDir = Join-Path $gradleHome 'init.d'
$initFile = Join-Path $initDir 'mengren-cache-retention.gradle'
$initContent = @"
// Managed by scripts/clean_dev_cache.ps1 - do not edit by hand.
// Shorter cache retention for this project's private GRADLE_USER_HOME.
beforeSettings { settings ->
    settings.caches {
        cleanup.set(org.gradle.api.cache.Cleanup.DEFAULT)
        releasedWrappers.setRemoveUnusedEntriesAfterDays(30)
        snapshotWrappers.setRemoveUnusedEntriesAfterDays(7)
        downloadedResources.setRemoveUnusedEntriesAfterDays($($limits.GradleDownloadedDays))
        createdResources.setRemoveUnusedEntriesAfterDays($($limits.GradleCreatedDays))
        buildCache.setRemoveUnusedEntriesAfterDays(7)
    }
}
"@
if (-not $DryRun -and (Test-Path -LiteralPath $gradleHome)) {
    $current = if (Test-Path -LiteralPath $initFile) { [IO.File]::ReadAllText($initFile) } else { '' }
    if ($current -ne $initContent) {
        New-Item -ItemType Directory -Path $initDir -Force | Out-Null
        [IO.File]::WriteAllText($initFile, $initContent, (New-Object Text.UTF8Encoding $false))
        $script:notes.Add('已写入 Gradle 自动清理设置（编译缓存 7 天、下载依赖 30 天没用就删）。')
    }
}

# ---------------- Gradle ----------------

$now = Get-Date
if ($gradleBusy) {
    $script:notes.Add('Gradle 正在运行，本次跳过 Gradle 缓存清理。')
} elseif (Test-Path -LiteralPath $gradleHome) {
    # 旧版本 Gradle 留下的缓存、日志和本体
    if ($gradleVersion) {
        foreach ($sub in @('caches', 'daemon')) {
            $dir = Join-Path $gradleHome $sub
            if (Test-Path -LiteralPath $dir) {
                Get-ChildItem -LiteralPath $dir -Directory -Force |
                    Where-Object { $_.Name -match '^\d+(\.\d+)+$' -and $_.Name -ne $gradleVersion } |
                    ForEach-Object { Invoke-Clean $_.FullName '旧版本 Gradle 的缓存' }
            }
        }
        $dists = Join-Path $gradleHome 'wrapper\dists'
        if (Test-Path -LiteralPath $dists) {
            Get-ChildItem -LiteralPath $dists -Directory -Force |
                Where-Object { $_.Name -match '^gradle-' -and $_.Name -notmatch "^gradle-$([regex]::Escape($gradleVersion))-(all|bin)$" } |
                ForEach-Object { Invoke-Clean $_.FullName '旧版本 Gradle 本体' }
        }
    }

    # 后台进程日志：AfterRelease 全删，平时按天数 + 总大小
    $logDir = if ($gradleVersion) { Join-Path $gradleHome "daemon\$gradleVersion" } else { $null }
    if ($logDir -and (Test-Path -LiteralPath $logDir)) {
        $logs = @(Get-ChildItem -LiteralPath $logDir -Filter '*.out.log' -File -Force | Sort-Object LastWriteTime -Descending)
        $keptBytes = 0L
        foreach ($log in $logs) {
            $old = $log.LastWriteTime -lt $now.AddDays(-$limits.GradleLogDays)
            $over = ($keptBytes + $log.Length) -gt ($limits.GradleLogMaxMB * 1MB)
            if ($Mode -eq 'AfterRelease' -or $old -or $over) {
                Invoke-Clean $log.FullName 'Gradle 后台进程日志' (Get-Relative (Join-Path $logDir '*.log'))
            } else {
                $keptBytes += $log.Length
            }
        }
    }

    # 下载 / 临时残留
    $tmp = Join-Path $gradleHome '.tmp'
    if (Test-Path -LiteralPath $tmp) {
        Get-ChildItem -LiteralPath $tmp -Force |
            Where-Object { $Mode -eq 'AfterRelease' -or $_.LastWriteTime -lt $now.AddDays(-$limits.GradleTmpDays) } |
            ForEach-Object { Invoke-Clean $_.FullName 'Gradle 临时残留' (Get-Relative (Join-Path $tmp '*')) }
    }

    # 依赖加工缓存（可在本机重新生成，不需要联网）
    if ($gradleVersion) {
        $transforms = Join-Path $gradleHome "caches\$gradleVersion\transforms"
        if (Test-Path -LiteralPath $transforms) {
            if ($Mode -eq 'AfterRelease') {
                Invoke-Clean $transforms 'Gradle 依赖加工缓存（发布后清理）'
            } elseif ((Get-TreeBytes $transforms) -gt ($limits.GradleTransformsMaxMB * 1MB)) {
                Invoke-Clean $transforms "Gradle 依赖加工缓存超过 $($limits.GradleTransformsMaxMB) MB"
            }
        }
    }
}

# 安卓 SDK 安装残留
$sdkTemp = Join-Path $toolsRoot 'android-sdk\.temp'
if (Test-Path -LiteralPath $sdkTemp) {
    Get-ChildItem -LiteralPath $sdkTemp -Force | ForEach-Object { Invoke-Clean $_.FullName '安卓 SDK 安装残留' (Get-Relative (Join-Path $sdkTemp '*')) }
}

# ---------------- app 编译产物 ----------------

if ($flutterBusy) {
    $script:notes.Add('Flutter 正在编译或测试，本次跳过 app 编译产物清理。')
} else {
    $appBuild = Join-Path $appRoot 'build'
    $ephemeral = Join-Path $appRoot 'windows\flutter\ephemeral'
    $flutterBuild = Join-Path $appRoot '.dart_tool\flutter_build'
    if ($Mode -eq 'AfterRelease') {
        Invoke-Clean $appBuild '编译产物（发布后清理）'
        Invoke-Clean $ephemeral 'Windows 编译临时文件（发布后清理）'
        Invoke-Clean $flutterBuild 'Flutter 编译缓存（发布后清理）'
    } elseif (Test-Path -LiteralPath $appBuild) {
        if ((Get-TreeBytes $appBuild) -gt ($limits.AppBuildMaxMB * 1MB)) {
            Invoke-Clean $appBuild "编译产物超过 $($limits.AppBuildMaxMB) MB"
        } else {
            $testCache = Join-Path $appBuild 'test_cache'
            if ((Get-TreeBytes $testCache) -gt ($limits.TestCacheMaxMB * 1MB)) {
                Invoke-Clean $testCache "测试编译缓存超过 $($limits.TestCacheMaxMB) MB"
            }
        }
    }
}

# Flutter 崩溃日志
foreach ($dir in @($projectRoot, $appRoot)) {
    Get-ChildItem -LiteralPath $dir -Filter 'flutter_*.log' -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $Mode -eq 'AfterRelease' -or $_.LastWriteTime -lt $now.AddDays(-$limits.FlutterCrashLogDays) } |
        ForEach-Object { Invoke-Clean $_.FullName 'Flutter 崩溃日志' }
}

# ---------------- dist：只留最新版 ----------------

if (Test-Path -LiteralPath $distRoot) {
    $pubspec = Select-String -LiteralPath (Join-Path $appRoot 'pubspec.yaml') -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)'
    $currentVersion = if ($pubspec) { [version]$pubspec.Matches[0].Groups[1].Value } else { $null }
    $items = @(Get-ChildItem -LiteralPath $distRoot -Force | Where-Object { $_.Name -ne '猛人快传' })
    $versioned = @(foreach ($i in $items) {
            $m = [regex]::Match($i.Name, 'v(\d+\.\d+\.\d+)')
            if ($m.Success) { [pscustomobject]@{ Item = $i; Version = [version]$m.Groups[1].Value } }
        })
    if ($versioned.Count -gt 0) {
        # 保留：pubspec 当前版本 + dist 里最新的版本（改了版本号还没打包时不删上一版）
        $newest = ($versioned | Sort-Object Version -Descending | Select-Object -First 1).Version
        foreach ($v in $versioned) {
            $keepVersion = ($v.Version -eq $newest) -or ($currentVersion -and $v.Version -eq $currentVersion)
            if (-not $keepVersion) {
                Invoke-Clean $v.Item.FullName "旧版本安装包（只保留 v$newest）"
            } elseif ($Mode -eq 'AfterRelease' -and $v.Item.PSIsContainer) {
                # 打包时生成的带版本号临时文件夹，ZIP 已经做好就不需要了
                Invoke-Clean $v.Item.FullName '打包临时文件夹'
            }
        }
    }
}

# ---------------- 结果 ----------------

if (-not $DryRun) {
    try {
        if (-not (Test-Path -LiteralPath $toolsRoot)) { New-Item -ItemType Directory -Path $toolsRoot | Out-Null }
        Set-Content -LiteralPath $stampFile -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding ASCII
    } catch { }
}

$title = switch ($Mode) { 'AfterRelease' { '发布后清理' } default { '定量清理' } }
if ($DryRun) { $title += '（试运行，没有真正删除）' }
foreach ($n in $script:notes) { Write-Host "  $n" }
if ($script:actions.Count -gt 0) {
    $script:actions | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}
$verb = if ($DryRun) { '可释放' } else { '共释放' }
Write-Host ("[缓存清理] {0}：{1} {2:N1} MB" -f $title, $verb, ($script:freed / 1MB))
if ($script:failures -gt 0) {
    Write-Host "[缓存清理] 有 $($script:failures) 个文件删不掉（可能正被占用），下次会再试。"
}
