[CmdletBinding()]
param(
    [ValidateSet('Menu', 'All', 'Month', 'Test', 'Failures')]
    [string]$Mode = 'Menu',

    [string]$Month = '',

    [switch]$SkipElevation,

    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:ScriptRoot 'mtp-auto-copy.config.json'
$script:LogDir = Join-Path $script:ScriptRoot 'logs'
$script:FailuresCsv = Join-Path $script:LogDir 'failed-files.csv'
$script:CurrentLog = $null
$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:AwakeEnabled = $false
$script:CurrentResults = New-Object System.Collections.Generic.List[object]
$script:SingleInstanceMutex = $null
$script:SingleInstanceAcquired = $false
$script:DialogWatcherProcess = $null
$script:MonthlySummaries = New-Object System.Collections.Generic.List[object]

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $SkipElevation -and -not (Test-IsAdministrator)) {
    Write-Host '需要管理员权限来自动重置 MTP 连接，正在请求提升权限...' -ForegroundColor Yellow
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments | Out-Null
    exit
}

$mutexName = 'Local\MtpAutoCopy_SingleInstance_01A1EE90'
$createdNew = $false
try {
    $script:SingleInstanceMutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
    $script:SingleInstanceAcquired = $createdNew
}
catch {
    Write-Host ("无法创建单实例锁：{0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

if (-not $createdNew) {
    Write-Host ''
    Write-Host 'MTP 自动复制器已经有一个实例在运行。' -ForegroundColor Yellow
    Write-Host '请不要重复打开工具，否则两个进程会同时写入同一个文件并产生“资源正在使用”错误。' -ForegroundColor Yellow
    Read-Host '按 Enter 关闭这个重复窗口'
    exit 1
}

if (-not ('MtpCopySleepControl' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MtpCopySleepControl
{
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
'@
}

function Enable-KeepAwake {
    if ($script:AwakeEnabled) { return }
    [void][MtpCopySleepControl]::SetThreadExecutionState([uint32]2147483649)
    $script:AwakeEnabled = $true
}

function Disable-KeepAwake {
    if (-not $script:AwakeEnabled) { return }
    [void][MtpCopySleepControl]::SetThreadExecutionState([uint32]2147483648)
    $script:AwakeEnabled = $false
}

function Get-DefaultConfig {
    $picturesFolder = [Environment]::GetFolderPath('Pictures')
    if ([string]::IsNullOrWhiteSpace($picturesFolder)) {
        $picturesFolder = Join-Path $env:USERPROFILE 'Pictures'
    }
    return [ordered]@{
        DestinationRoot       = (Join-Path $picturesFolder 'iPhoneImport')
        ResetEveryFiles       = 100
        LargeFileResetMB      = 1000
        StallSeconds          = 75
        StartTimeoutSeconds   = 90
        MaxFileMinutes        = 180
        StableSeconds         = 5
        PauseBetweenFiles     = 1
        MaxAttemptsPerFile    = 2
        ReconnectTimeoutSec   = 60
        DeferredRetryRounds   = 3
        DeferredRetryDelaySeconds = 10
    }
}

function Normalize-DestinationRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    try {
        $full = [System.IO.Path]::GetFullPath($Path.Trim().Trim('"'))
        if ($full.Length -gt 3) {
            $full = $full.TrimEnd('\')
        }
        $leaf = [System.IO.Path]::GetFileName($full)
        if ($leaf -match '^\d{6}_[A-Za-z0-9_]*$') {
            return [System.IO.Path]::GetDirectoryName($full)
        }
        return $full
    }
    catch {
        return $Path.Trim().Trim('"')
    }
}

function Load-Config {
    $config = Get-DefaultConfig
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $configText = [System.IO.File]::ReadAllText($script:ConfigPath, [System.Text.Encoding]::UTF8)
            $saved = $configText | ConvertFrom-Json
            $configKeys = @($config.Keys)
            foreach ($name in $configKeys) {
                $property = $saved.PSObject.Properties[$name]
                if ($null -ne $property) {
                    $config[$name] = $property.Value
                }
            }
        }
        catch {
            Write-Host '配置文件损坏，已恢复默认设置。' -ForegroundColor Yellow
        }
    }
    $normalizedRoot = Normalize-DestinationRoot -Path ([string]$config.DestinationRoot)
    if ($normalizedRoot -ne [string]$config.DestinationRoot) {
        Write-Host ("目标目录原为 {0}，已自动改为上级目录 {1}，避免月份目录嵌套。" -f $config.DestinationRoot, $normalizedRoot) -ForegroundColor Yellow
        $config.DestinationRoot = $normalizedRoot
    }
    Save-Config $config
    return $config
}

function Save-Config {
    param($Config)
    $json = $Config | ConvertTo-Json -Depth 5
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $true
    [System.IO.File]::WriteAllText($script:ConfigPath, $json, $encoding)
}

function Initialize-Log {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir | Out-Null
    }
    $script:CurrentLog = Join-Path $script:LogDir ("mtp-copy-{0}.log" -f $script:RunId)
    Add-Content -LiteralPath $script:CurrentLog -Value ("MTP 自动复制器启动 {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:CurrentLog) {
        Add-Content -LiteralPath $script:CurrentLog -Value $line -Encoding UTF8
    }

    $color = 'Gray'
    switch ($Level) {
        'OK'    { $color = 'Green' }
        'WARN'  { $color = 'Yellow' }
        'ERROR' { $color = 'Red' }
        'DEBUG' { $color = 'DarkGray' }
    }

    if ($Level -ne 'DEBUG') {
        Write-Host $line -ForegroundColor $color
    }
}

function Start-DialogWatcher {
    $watchdogScript = Join-Path $script:ScriptRoot 'mtp-dialog-watchdog.ps1'
    if (-not (Test-Path -LiteralPath $watchdogScript)) {
        Write-Log '未找到复制错误窗口自动处理组件。' WARN
        return
    }

    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ParentPid {1}' -f $watchdogScript, $PID
        $script:DialogWatcherProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
        Write-Log '已启动复制错误窗口自动处理组件。' INFO
    }
    catch {
        Write-Log ("启动复制错误窗口处理组件失败：{0}" -f $_.Exception.Message) WARN
    }
}

function Stop-DialogWatcher {
    if ($null -eq $script:DialogWatcherProcess) { return }
    try {
        if (-not $script:DialogWatcherProcess.HasExited) {
            Stop-Process -Id $script:DialogWatcherProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
    $script:DialogWatcherProcess = $null
}

function Convert-SizeTextToBytes {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $match = [regex]::Match($Text, '([0-9]+(?:[.,][0-9]+)?)\s*(TB|GB|MB|KB|B)', 'IgnoreCase')
    if (-not $match.Success) { return $null }

    $numberText = $match.Groups[1].Value.Replace(',', '.')
    $number = 0.0
    if (-not [double]::TryParse($numberText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $null
    }

    $unit = $match.Groups[2].Value.ToUpperInvariant()
    $power = 0
    switch ($unit) {
        'KB' { $power = 1 }
        'MB' { $power = 2 }
        'GB' { $power = 3 }
        'TB' { $power = 4 }
    }

    return [int64]($number * [math]::Pow(1024, $power))
}

function Get-ItemSizeInfo {
    param(
        $Item,
        $FolderView
    )

    $exact = $null
    try {
        $value = $Item.ExtendedProperty('System.Size')
        if ($null -ne $value -and $value -ne '') {
            $exact = [int64]$value
        }
    }
    catch {
        $exact = $null
    }

    $text = ''
    try {
        $text = [string]$FolderView.GetDetailsOf($Item, 2)
    }
    catch {
        $text = ''
    }

    $approx = Convert-SizeTextToBytes -Text $text

    return [pscustomobject]@{
        ExactBytes = $exact
        ApproxBytes = $approx
        DisplayText = $text
    }
}

function Format-Bytes {
    param($Bytes)
    if ($null -eq $Bytes) { return '未知大小' }
    $value = [double]$Bytes
    if ($value -ge 1TB) { return '{0:N2} TB' -f ($value / 1TB) }
    if ($value -ge 1GB) { return '{0:N2} GB' -f ($value / 1GB) }
    if ($value -ge 1MB) { return '{0:N1} MB' -f ($value / 1MB) }
    if ($value -ge 1KB) { return '{0:N1} KB' -f ($value / 1KB) }
    return '{0} B' -f $Bytes
}

function Release-ComObject {
    param($Object)
    if ($null -eq $Object) { return }
    try {
        if ([Runtime.InteropServices.Marshal]::IsComObject($Object)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Object)
        }
    }
    catch {
    }
}

function Get-MtpContext {
    param([int]$TimeoutSeconds = 15)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $shell = $null
        try {
            $shell = New-Object -ComObject Shell.Application
            $computer = $shell.Namespace(17)
            if ($null -eq $computer) {
                throw '无法读取“此电脑”'
            }

            foreach ($candidate in @($computer.Items())) {
                $path = ''
                try { $path = [string]$candidate.Path } catch { }
                $isIphone = ($path -match 'vid_05ac&pid_12a8') -or ($candidate.Name -match 'Apple iPhone')
                if (-not $isIphone) { continue }

                try {
                    $deviceFolder = $candidate.GetFolder
                    if ($null -eq $deviceFolder) { continue }
                    $storage = @($deviceFolder.Items()) | Where-Object {
                        $_.IsFolder -and $_.Name -eq 'Internal Storage'
                    } | Select-Object -First 1

                    if ($null -ne $storage) {
                        return [pscustomobject]@{
                            Shell = $shell
                            Device = $candidate
                            Storage = $storage
                        }
                    }
                }
                catch {
                }
            }
        }
        catch {
        }

        if ($null -ne $shell) {
            Release-ComObject $shell
        }

        if ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Wait-ForMtpContext {
    param([int]$TimeoutSeconds = 60)
    Write-Host '等待 iPhone MTP 连接恢复...' -ForegroundColor Yellow
    return Get-MtpContext -TimeoutSeconds $TimeoutSeconds
}

function Get-MonthFolders {
    param($Context)
    $result = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($item in @($Context.Storage.GetFolder.Items())) {
            if (-not $item.IsFolder) { continue }
            if ($item.Name -match '^\d{6}_[A-Za-z0-9_]*$') {
                $result.Add([string]$item.Name)
            }
        }
    }
    catch {
        throw "读取月份文件夹失败：$($_.Exception.Message)"
    }
    return @($result | Sort-Object)
}

function Get-MonthFolderItem {
    param(
        $Context,
        [string]$FolderName
    )

    try {
        foreach ($item in @($Context.Storage.GetFolder.Items())) {
            if ($item.IsFolder -and $item.Name -eq $FolderName) {
                return $item
            }
        }
    }
    catch {
    }
    return $null
}

function Get-MonthFolderWithRetry {
    param(
        $Context,
        [string]$FolderName,
        [int]$TimeoutSeconds = 45
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $folder = $null
        try {
            $folder = Get-MonthFolderItem -Context $Context -FolderName $FolderName
        }
        catch {
            $folder = $null
        }

        if ($null -ne $folder) {
            return [pscustomobject]@{
                Folder = $folder
                Context = $Context
            }
        }

        if ((Get-Date) -ge $deadline) {
            break
        }

        Start-Sleep -Seconds 2
        $freshContext = Get-MtpContext -TimeoutSeconds 5
        if ($null -ne $freshContext) {
            $Context = $freshContext
        }
    } while ($true)

    throw "MTP 已恢复，但在 $TimeoutSeconds 秒内仍无法打开月份文件夹：$FolderName"
}

function Get-FileRecords {
    param($FolderItem)

    Write-Host '正在读取手机文件列表，文件较多时可能需要一到两分钟...' -ForegroundColor Yellow
    $collection = $FolderItem.GetFolder.Items()
    $total = 0
    try { $total = [int]$collection.Count } catch { $total = 0 }

    $records = New-Object System.Collections.Generic.List[object]
    $seen = 0
    foreach ($item in $collection) {
        $seen++
        try {
            if (-not $item.IsFolder) {
                $records.Add([pscustomobject]@{
                    Name = [string]$item.Name
                    Item = $item
                })
            }
        }
        catch {
        }

        if ($seen % 250 -eq 0) {
            if ($total -gt 0) {
                Write-Host ("  已读取 {0}/{1}" -f $seen, $total) -ForegroundColor DarkGray
            }
            else {
                Write-Host ("  已读取 {0}" -f $seen) -ForegroundColor DarkGray
            }
        }
    }

    if ($records.Count -eq 0) {
        throw '没有读取到可复制的文件，MTP 会话可能已失效。'
    }

    return @($records | Sort-Object Name)
}

function Get-FileRecordsWithRecovery {
    param(
        $Config,
        [string]$MonthName,
        $Context,
        $FolderItem
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $records = @(Get-FileRecords -FolderItem $FolderItem)
            if ($records.Count -gt 0) {
                return [pscustomobject]@{
                    Records = $records
                    Context = $Context
                    FolderItem = $FolderItem
                }
            }
            $lastError = '文件列表为空'
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Write-Log ("读取 {0} 文件列表失败：{1}，准备重置 MTP 后重试。" -f $MonthName, $lastError) WARN
        $Context = Reset-MtpConnection -Config $Config
        try {
            $lookup = Get-MonthFolderWithRetry -Context $Context -FolderName $MonthName -TimeoutSeconds 45
            $Context = $lookup.Context
            $FolderItem = $lookup.Folder
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    throw ("连续多次无法读取 {0} 的文件列表：{1}" -f $MonthName, $lastError)
}

function Resolve-FileItem {
    param(
        $FolderItem,
        $Record
    )

    if ($null -ne $Record.Item) {
        try {
            if ($Record.Item.Name -eq $Record.Name) {
                return $Record.Item
            }
        }
        catch {
            $Record.Item = $null
        }
    }

    try {
        $item = $FolderItem.GetFolder.ParseName($Record.Name)
        if ($null -ne $item -and -not $item.IsFolder) {
            $Record.Item = $item
            return $item
        }
    }
    catch {
    }

    return $null
}

function Rebuild-FileItemMap {
    param(
        $FolderItem,
        $Records
    )

    Write-Host '正在重建 MTP 文件索引...' -ForegroundColor Yellow
    $map = @{}
    foreach ($item in @($FolderItem.GetFolder.Items())) {
        try {
            if (-not $item.IsFolder) {
                $map[[string]$item.Name] = $item
            }
        }
        catch {
        }
    }

    foreach ($record in $Records) {
        $record.Item = $map[$record.Name]
    }
}

function Refresh-FolderLookup {
    param(
        $FolderItem,
        $Records,
        $PreferredRecord
    )

    foreach ($record in $Records) {
        $record.Item = $null
    }

    if ($null -ne $PreferredRecord) {
        try {
            $probe = $FolderItem.GetFolder.ParseName($PreferredRecord.Name)
            if ($null -ne $probe -and -not $probe.IsFolder) {
                $PreferredRecord.Item = $probe
                return
            }
        }
        catch {
        }
    }

    Rebuild-FileItemMap -FolderItem $FolderItem -Records $Records
}

function Move-PartialFile {
    param(
        [string]$TargetPath,
        [string]$DestinationFolder,
        [string]$Reason
    )

    if (-not (Test-Path -LiteralPath $TargetPath)) { return }

    try {
        $incompleteDir = Join-Path $DestinationFolder '_incomplete'
        if (-not (Test-Path -LiteralPath $incompleteDir)) {
            New-Item -ItemType Directory -Path $incompleteDir | Out-Null
        }

        $name = [System.IO.Path]::GetFileName($TargetPath)
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $newName = '{0}.partial_{1}' -f $name, $stamp
        $newPath = Join-Path $incompleteDir $newName
        Move-Item -LiteralPath $TargetPath -Destination $newPath -Force
        Write-Log "已将未完成文件移至 $newPath（$Reason）" WARN
    }
    catch {
        Write-Log "无法移动未完成文件：$TargetPath；$($_.Exception.Message)" WARN
    }
}

function Copy-SingleFile {
    param(
        $Item,
        $FolderView,
        [string]$DestinationFolder,
        [string]$FileName,
        $Config,
        $LocalShell
    )

    $targetPath = Join-Path $DestinationFolder $FileName
    $sizeInfo = Get-ItemSizeInfo -Item $Item -FolderView $FolderView
    $expected = $sizeInfo.ExactBytes
    $approx = $sizeInfo.ApproxBytes

    if (Test-Path -LiteralPath $targetPath) {
        $existing = Get-Item -LiteralPath $targetPath -ErrorAction SilentlyContinue
        $matches = $false
        if ($null -ne $existing) {
            if ($null -ne $expected -and $existing.Length -eq $expected) {
                $matches = $true
            }
            elseif ($null -ne $approx) {
                $tolerance = [math]::Max(2MB, $approx * 0.02)
                if ([math]::Abs([double]$existing.Length - [double]$approx) -le $tolerance) {
                    $matches = $true
                }
            }
            else {
                $matches = $true
            }

            if ($matches) {
                return [pscustomobject]@{
                    Status = 'Skipped'
                    Seconds = 0
                    SizeBytes = $existing.Length
                    Reason = '目标文件已存在'
                }
            }

            Move-PartialFile -TargetPath $targetPath -DestinationFolder $DestinationFolder -Reason '大小与手机源文件不一致'
        }
    }

    $destinationNamespace = $LocalShell.Namespace($DestinationFolder)
    if ($null -eq $destinationNamespace) {
        throw "无法打开目标目录：$DestinationFolder"
    }

    $started = Get-Date
    $lastLength = -1
    $lastChange = $started
    $lastDisplay = $started
    $seenAt = $null
    $stableSince = $null

    # FOF_NO_UI: silent, no confirmation, no error dialog, no mkdir prompt.
    $destinationNamespace.CopyHere($Item, 0x614)

    while ($true) {
        Start-Sleep -Seconds 2
        $now = Get-Date
        $elapsed = ($now - $started).TotalMinutes

        if ($elapsed -gt [double]$Config.MaxFileMinutes) {
            return [pscustomobject]@{
                Status = 'Failed'
                Seconds = ((Get-Date) - $started).TotalSeconds
                SizeBytes = $expected
                Reason = '超过单文件最大等待时间'
            }
        }

        $file = Get-Item -LiteralPath $targetPath -ErrorAction SilentlyContinue
        if ($null -eq $file) {
            if (($now - $started).TotalSeconds -gt [int]$Config.StartTimeoutSeconds) {
                return [pscustomobject]@{
                    Status = 'Failed'
                    Seconds = ($now - $started).TotalSeconds
                    SizeBytes = $expected
                    Reason = '目标文件未出现'
                }
            }
        }
        else {
            if ($null -eq $seenAt) {
                $seenAt = $now
                $lastChange = $now
            }

            if ($file.Length -ne $lastLength) {
                $lastLength = $file.Length
                $lastChange = $now
                $stableSince = $null
            }
            else {
                if ($null -eq $stableSince) {
                    $stableSince = $now
                }
            }

            if (($now - $lastDisplay).TotalSeconds -ge 5) {
                Write-Host ("    已写入 {0}" -f (Format-Bytes $file.Length)) -ForegroundColor DarkGray
                $lastDisplay = $now
            }

            $sizeMatches = $false
            if ($null -ne $expected -and $file.Length -eq $expected) {
                $sizeMatches = $true
            }
            elseif ($null -ne $approx) {
                $tolerance = [math]::Max(2MB, $approx * 0.02)
                if ([math]::Abs([double]$file.Length - [double]$approx) -le $tolerance) {
                    $sizeMatches = $true
                }
            }

            if ($sizeMatches -and $file.Length -gt 0) {
                Start-Sleep -Seconds 2
                $check = Get-Item -LiteralPath $targetPath -ErrorAction SilentlyContinue
                if ($null -ne $check -and $check.Length -eq $file.Length) {
                    return [pscustomobject]@{
                        Status = 'Copied'
                        Seconds = ((Get-Date) - $started).TotalSeconds
                        SizeBytes = $check.Length
                        Reason = ''
                    }
                }
            }

            if ($null -eq $expected -and $null -eq $approx -and $file.Length -gt 0) {
                if ($null -ne $stableSince -and ($now - $stableSince).TotalSeconds -ge [int]$Config.StableSeconds) {
                    return [pscustomobject]@{
                        Status = 'Copied'
                        Seconds = ((Get-Date) - $started).TotalSeconds
                        SizeBytes = $file.Length
                        Reason = '文件大小已稳定'
                    }
                }
            }

            if (($now - $lastChange).TotalSeconds -ge [int]$Config.StallSeconds) {
                return [pscustomobject]@{
                    Status = 'Failed'
                    Seconds = ($now - $started).TotalSeconds
                    SizeBytes = $file.Length
                    Reason = '长时间没有任何写入进度'
                }
            }
        }
    }
}

function Find-MtpDeviceNode {
    $nodes = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match '^USB\\VID_05AC&PID_12A8'
    })

    $parent = $nodes | Where-Object { $_.InstanceId -notmatch '&MI_' } | Select-Object -First 1
    if ($null -ne $parent) { return $parent }

    $wpd = $nodes | Where-Object { $_.Class -eq 'WPD' } | Select-Object -First 1
    if ($null -ne $wpd) { return $wpd }

    return $null
}

function Reset-MtpConnection {
    param($Config)

    Write-Log '正在自动重置 MTP 连接...' WARN
    $wpdNode = Get-PnpDevice -PresentOnly -Class WPD -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match '^USB\\VID_05AC&PID_12A8'
    } | Select-Object -First 1

    $problemCode = $null
    if ($null -ne $wpdNode) {
        try {
            $problemProperty = Get-PnpDeviceProperty -InstanceId $wpdNode.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction Stop
            if ($null -ne $problemProperty) {
                $problemCode = $problemProperty.Data
            }
        }
        catch {
        }
    }

    if ($null -ne $wpdNode -and ($wpdNode.Status -ne 'OK' -or ($null -ne $problemCode -and [int]$problemCode -ne 0))) {
        Write-Log ("当前 MTP 设备状态异常：{0}，需要物理重新插拔。" -f $wpdNode.Status) WARN
    }
    else {
        $node = Find-MtpDeviceNode

        if ($null -ne $node) {
            try {
                & pnputil.exe /restart-device $node.InstanceId | Out-Null
            }
            catch {
                Write-Log "设备重启命令失败：$($_.Exception.Message)" WARN
            }
        }
        else {
            Write-Log '没有找到 iPhone MTP 设备节点。' WARN
        }
    }

    try {
        Restart-Service WPDBusEnum -Force -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
    }

    try {
        Restart-Service 'Apple Mobile Device Service' -Force -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
    }

    Start-Sleep -Seconds 2
    $context = Wait-ForMtpContext -TimeoutSeconds ([math]::Min(20, [int]$Config.ReconnectTimeoutSec))
    if ($null -ne $context) {
        Write-Log 'MTP 连接已恢复。' OK
        return $context
    }

    Write-Host ''
    Write-Host '自动重置后仍未恢复。请执行以下操作：' -ForegroundColor Yellow
    Write-Host '  1. 拔下 iPhone 数据线，等待 3 秒后重新插入。' -ForegroundColor Yellow
    Write-Host '  2. 解锁 iPhone，保持亮屏。' -ForegroundColor Yellow
    Write-Host '  3. 插好后回到这里按 Enter。' -ForegroundColor Yellow
    Read-Host '完成后按 Enter 继续'

    $context = Wait-ForMtpContext -TimeoutSeconds 120
    if ($null -eq $context) {
        throw 'MTP 连接未恢复，请检查数据线、USB 端口和手机解锁状态。'
    }

    Write-Log '重新插拔后 MTP 连接已恢复。' OK
    return $context
}

function Select-MonthsInteractive {
    param([string[]]$Months)

    Write-Host ''
    Write-Host '可用的月份文件夹：' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Months.Count; $i++) {
        Write-Host ('  {0,2}. {1}' -f ($i + 1), $Months[$i])
    }

    Write-Host ''
    Write-Host '输入编号（例如 1,3,5），或输入 A 复制全部：' -ForegroundColor Yellow
    $answer = [string](Read-Host '选择')

    if ($answer.Trim().ToUpperInvariant() -eq 'A') {
        return $Months
    }

    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($part in $answer.Split(',')) {
        $number = 0
        if ([int]::TryParse($part.Trim(), [ref]$number)) {
            if ($number -ge 1 -and $number -le $Months.Count) {
                $selected.Add($Months[$number - 1])
            }
        }
    }

    if ($selected.Count -eq 0) {
        throw '没有选择有效月份。'
    }

    return @($selected)
}

function Add-ResultRecord {
    param(
        [string]$MonthName,
        [string]$FileName,
        [string]$Status,
        [string]$SizeText,
        [double]$Seconds,
        [string]$Reason
    )

    $script:CurrentResults.Add([pscustomobject]@{
        Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Month = $MonthName
        File = $FileName
        Status = $Status
        Size = $SizeText
        Seconds = [math]::Round($Seconds, 1)
        Reason = $Reason
    })
}

function Add-FailureRecord {
    param(
        [string]$MonthName,
        [string]$FileName,
        [string]$SizeText,
        [string]$Reason
    )

    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir | Out-Null
    }

    [pscustomobject]@{
        Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Month = $MonthName
        File = $FileName
        Size = $SizeText
        Reason = $Reason
    } | Export-Csv -LiteralPath $script:FailuresCsv -Append -NoTypeInformation -Encoding UTF8
}

function Invoke-DeferredRetry {
    param(
        $Config,
        [string]$MonthName,
        [string]$DestinationFolder,
        $FailedQueue,
        $Records,
        $Context,
        $FolderItem,
        $LocalShell
    )

    $queue = $FailedQueue
    $retryCopied = 0
    $retrySkipped = 0
    $batchSize = [int]$Config.DeferredRetryRounds
    if ($batchSize -lt 1) { $batchSize = 3 }
    $roundInBatch = 0
    $roundNumber = 0

    while ($queue.Count -gt 0) {
        if ($roundInBatch -gt 0 -and [double]$Config.DeferredRetryDelaySeconds -gt 0) {
            Start-Sleep -Seconds ([int]$Config.DeferredRetryDelaySeconds)
        }

        $roundNumber++
        $roundInBatch++
        Write-Section ("{0} 延迟重试第 {1} 轮，剩余 {2} 个文件" -f $MonthName, $roundNumber, $queue.Count)

        $Context = Reset-MtpConnection -Config $Config
        $lookup = Get-MonthFolderWithRetry -Context $Context -FolderName $MonthName -TimeoutSeconds 60
        $Context = $lookup.Context
        $FolderItem = $lookup.Folder
        Refresh-FolderLookup -FolderItem $FolderItem -Records $Records -PreferredRecord $queue[0].Record

        $nextQueue = New-Object System.Collections.Generic.List[object]
        $itemNumber = 0
        foreach ($failure in $queue) {
            $itemNumber++
            $record = $failure.Record
            $targetPath = Join-Path $DestinationFolder $record.Name
            $sourceItem = Resolve-FileItem -FolderItem $FolderItem -Record $record

            if ($null -eq $sourceItem) {
                $failure.Reason = '延迟重试时无法取得源文件'
                $nextQueue.Add($failure)
                Write-Log ("重试 {0}/{1} 失败：无法取得源文件" -f $itemNumber, $queue.Count) WARN
                continue
            }

            $sizeInfo = Get-ItemSizeInfo -Item $sourceItem -FolderView $FolderItem.GetFolder
            $sizeBytes = if ($null -ne $sizeInfo.ExactBytes) { $sizeInfo.ExactBytes } else { $sizeInfo.ApproxBytes }
            $failure.SizeText = if ($sizeInfo.DisplayText) { $sizeInfo.DisplayText } else { Format-Bytes $sizeBytes }

            Write-Host ''
            Write-Host ("[重试 {0}/{1}] {2}  {3}" -f $itemNumber, $queue.Count, $record.Name, $failure.SizeText) -ForegroundColor Cyan

            try {
                $copyResult = Copy-SingleFile -Item $sourceItem -FolderView $FolderItem.GetFolder -DestinationFolder $DestinationFolder -FileName $record.Name -Config $Config -LocalShell $LocalShell
            }
            catch {
                $copyResult = [pscustomobject]@{
                    Status = 'Failed'
                    Seconds = 0
                    SizeBytes = $sizeBytes
                    Reason = $_.Exception.Message
                }
            }

            if ($copyResult.Status -eq 'Copied') {
                $retryCopied++
                Write-Log ("延迟重试成功 {0}，{1}，耗时 {2:N1} 秒" -f $record.Name, (Format-Bytes $copyResult.SizeBytes), $copyResult.Seconds) OK
                Add-ResultRecord -MonthName $MonthName -FileName $record.Name -Status '延迟重试成功' -SizeText (Format-Bytes $copyResult.SizeBytes) -Seconds $copyResult.Seconds -Reason ''
            }
            elseif ($copyResult.Status -eq 'Skipped') {
                $retrySkipped++
                Write-Log ("延迟重试后发现目标已存在：{0}" -f $record.Name) OK
                Add-ResultRecord -MonthName $MonthName -FileName $record.Name -Status '重试后已存在' -SizeText (Format-Bytes $copyResult.SizeBytes) -Seconds 0 -Reason $copyResult.Reason
            }
            else {
                $failure.Reason = [string]$copyResult.Reason
                Move-PartialFile -TargetPath $targetPath -DestinationFolder $DestinationFolder -Reason $failure.Reason
                $nextQueue.Add($failure)
                Write-Log ("延迟重试失败 {0}：{1}" -f $record.Name, $failure.Reason) WARN
            }
        }

        $queue = $nextQueue
        if ($queue.Count -eq 0) {
            break
        }

        if ($roundInBatch -ge $batchSize) {
            Write-Host ''
            Write-Host ("自动重试已连续 {0} 轮，仍有 {1} 个文件失败。" -f $batchSize, $queue.Count) -ForegroundColor Yellow
            Write-Host '输入 R 再自动重试一批，输入 S 结束并保留最终失败清单。' -ForegroundColor Yellow
            if ($NoPause) {
                break
            }
            $answer = [string](Read-Host '继续重试? (R/S)')
            if ($answer.Trim().ToUpperInvariant() -ne 'R') {
                break
            }
            $roundInBatch = 0
        }
    }

    return [pscustomobject]@{
        FailedQueue = $queue
        RetryCopied = $retryCopied
        RetrySkipped = $retrySkipped
        Context = $Context
        FolderItem = $FolderItem
    }
}

function Invoke-MonthCopy {
    param(
        $Config,
        [string]$MonthName,
        $Context
    )

    Write-Section ("开始处理 {0}" -f $MonthName)
    $destinationFolder = Join-Path $Config.DestinationRoot $MonthName
    if (-not (Test-Path -LiteralPath $destinationFolder)) {
        New-Item -ItemType Directory -Path $destinationFolder | Out-Null
        Write-Log "已创建目标目录：$destinationFolder" INFO
    }

    $initialLookup = Get-MonthFolderWithRetry -Context $Context -FolderName $MonthName -TimeoutSeconds 30
    $Context = $initialLookup.Context
    $folderItem = $initialLookup.Folder

    $listing = Get-FileRecordsWithRecovery -Config $Config -MonthName $MonthName -Context $Context -FolderItem $folderItem
    $Context = $listing.Context
    $folderItem = $listing.FolderItem
    $records = @($listing.Records)
    Write-Log "文件列表读取完成，共 $($records.Count) 个文件。" INFO

    $localShell = New-Object -ComObject Shell.Application
    $stats = [pscustomobject]@{
        TotalFiles = $records.Count
        Copied = 0
        Skipped = 0
        InitialFailed = 0
        RetryCopied = 0
        RetrySkipped = 0
        FinalFailed = 0
    }

    $copiedSinceReset = 0
    $currentFolder = $folderItem
    $currentContext = $Context
    $failedQueue = New-Object System.Collections.Generic.List[object]

    for ($index = 0; $index -lt $records.Count; $index++) {
        $record = $records[$index]
        $displayNumber = $index + 1
        $targetPath = Join-Path $destinationFolder $record.Name

        if (Test-Path -LiteralPath $targetPath) {
            $sourceItem = Resolve-FileItem -FolderItem $currentFolder -Record $record
            if ($null -ne $sourceItem) {
                $sizeInfo = Get-ItemSizeInfo -Item $sourceItem -FolderView $currentFolder.GetFolder
                $existing = Get-Item -LiteralPath $targetPath -ErrorAction SilentlyContinue
                $matches = $false
                if ($null -ne $existing) {
                    if ($null -ne $sizeInfo.ExactBytes -and $existing.Length -eq $sizeInfo.ExactBytes) {
                        $matches = $true
                    }
                    elseif ($null -ne $sizeInfo.ApproxBytes) {
                        $tolerance = [math]::Max(2MB, $sizeInfo.ApproxBytes * 0.02)
                        if ([math]::Abs([double]$existing.Length - [double]$sizeInfo.ApproxBytes) -le $tolerance) {
                            $matches = $true
                        }
                    }
                    else {
                        $matches = $true
                    }
                }

                if ($matches) {
                    $stats.Skipped++
                    Write-Host ("[{0}/{1}] 跳过已存在：{2}" -f $displayNumber, $records.Count, $record.Name) -ForegroundColor DarkGray
                    Add-ResultRecord -MonthName $MonthName -FileName $record.Name -Status '跳过' -SizeText (Format-Bytes $existing.Length) -Seconds 0 -Reason '目标文件已存在'
                    continue
                }
            }
        }

        $attempt = 0
        $success = $false
        $lastReason = ''
        $lastSizeText = '未知大小'

        while ($attempt -lt [int]$Config.MaxAttemptsPerFile -and -not $success) {
            $attempt++
            $sourceItem = Resolve-FileItem -FolderItem $currentFolder -Record $record
            if ($null -eq $sourceItem) {
                $lastReason = '无法取得 MTP 文件对象'
                Write-Log ("[{0}/{1}] {2}：{3}" -f $displayNumber, $records.Count, $record.Name, $lastReason) WARN
                $currentContext = Reset-MtpConnection -Config $Config
                $lookup = Get-MonthFolderWithRetry -Context $currentContext -FolderName $MonthName -TimeoutSeconds 60
                $currentContext = $lookup.Context
                $currentFolder = $lookup.Folder
                Refresh-FolderLookup -FolderItem $currentFolder -Records $records -PreferredRecord $record
                $copiedSinceReset = 0
                continue
            }

            $sizeInfo = Get-ItemSizeInfo -Item $sourceItem -FolderView $currentFolder.GetFolder
            $sizeBytes = if ($null -ne $sizeInfo.ExactBytes) { $sizeInfo.ExactBytes } else { $sizeInfo.ApproxBytes }
            $lastSizeText = if ($sizeInfo.DisplayText) { $sizeInfo.DisplayText } else { Format-Bytes $sizeBytes }
            $sizeMB = if ($null -ne $sizeBytes) { [double]$sizeBytes / 1MB } else { 0 }

            if ([double]$Config.LargeFileResetMB -gt 0 -and $sizeMB -ge [double]$Config.LargeFileResetMB -and $copiedSinceReset -gt 0) {
                Write-Log ("大文件前主动重置 MTP：{0} ({1})" -f $record.Name, $lastSizeText) INFO
                $currentContext = Reset-MtpConnection -Config $Config
                $lookup = Get-MonthFolderWithRetry -Context $currentContext -FolderName $MonthName -TimeoutSeconds 60
                $currentContext = $lookup.Context
                $currentFolder = $lookup.Folder
                Refresh-FolderLookup -FolderItem $currentFolder -Records $records -PreferredRecord $record
                $copiedSinceReset = 0
                $sourceItem = Resolve-FileItem -FolderItem $currentFolder -Record $record
                if ($null -eq $sourceItem) {
                    $lastReason = '重置后无法取得文件对象'
                    continue
                }
            }

            Write-Host ''
            Write-Host ("[{0}/{1}] 复制 {2}  {3}  (第 {4} 次尝试)" -f $displayNumber, $records.Count, $record.Name, $lastSizeText, $attempt) -ForegroundColor Cyan
            Write-Progress -Activity ("复制 {0}" -f $MonthName) -Status ("{0}/{1}  {2}" -f $displayNumber, $records.Count, $record.Name) -PercentComplete ([math]::Floor(($displayNumber - 1) * 100 / $records.Count))

            try {
                $copyResult = Copy-SingleFile -Item $sourceItem -FolderView $currentFolder.GetFolder -DestinationFolder $destinationFolder -FileName $record.Name -Config $Config -LocalShell $localShell
            }
            catch {
                $copyResult = [pscustomobject]@{
                    Status = 'Failed'
                    Seconds = 0
                    SizeBytes = $sizeBytes
                    Reason = $_.Exception.Message
                }
            }

            if ($copyResult.Status -eq 'Skipped') {
                $stats.Skipped++
                $success = $true
                Add-ResultRecord -MonthName $MonthName -FileName $record.Name -Status '跳过' -SizeText (Format-Bytes $copyResult.SizeBytes) -Seconds 0 -Reason $copyResult.Reason
                break
            }

            if ($copyResult.Status -eq 'Copied') {
                $stats.Copied++
                $copiedSinceReset++
                $success = $true
                Write-Log ("完成 {0}，{1}，耗时 {2:N1} 秒" -f $record.Name, (Format-Bytes $copyResult.SizeBytes), $copyResult.Seconds) OK
                Add-ResultRecord -MonthName $MonthName -FileName $record.Name -Status '成功' -SizeText (Format-Bytes $copyResult.SizeBytes) -Seconds $copyResult.Seconds -Reason ''
            }
            else {
                $lastReason = [string]$copyResult.Reason
                Write-Log ("失败 {0}：{1}" -f $record.Name, $lastReason) ERROR
                Move-PartialFile -TargetPath $targetPath -DestinationFolder $destinationFolder -Reason $lastReason

                if ($attempt -lt [int]$Config.MaxAttemptsPerFile) {
                    $currentContext = Reset-MtpConnection -Config $Config
                    $lookup = Get-MonthFolderWithRetry -Context $currentContext -FolderName $MonthName -TimeoutSeconds 60
                    $currentContext = $lookup.Context
                    $currentFolder = $lookup.Folder
                    Refresh-FolderLookup -FolderItem $currentFolder -Records $records -PreferredRecord $record
                    $copiedSinceReset = 0
                }
            }
        }

        if (-not $success) {
            $stats.InitialFailed++
            $failedQueue.Add([pscustomobject]@{
                Record = $record
                SizeText = $lastSizeText
                Reason = $lastReason
            })
            Add-ResultRecord -MonthName $MonthName -FileName $record.Name -Status '初次失败，等待延迟重试' -SizeText $lastSizeText -Seconds 0 -Reason $lastReason
            Write-Log ("初次失败，加入延迟重试队列：{0}" -f $record.Name) WARN
        }

        if ($success -and [int]$Config.ResetEveryFiles -gt 0 -and $copiedSinceReset -ge [int]$Config.ResetEveryFiles) {
            $currentContext = Reset-MtpConnection -Config $Config
            $lookup = Get-MonthFolderWithRetry -Context $currentContext -FolderName $MonthName -TimeoutSeconds 60
            $currentContext = $lookup.Context
            $currentFolder = $lookup.Folder
            Refresh-FolderLookup -FolderItem $currentFolder -Records $records -PreferredRecord $record
            $copiedSinceReset = 0
        }

        if ($success -and [double]$Config.PauseBetweenFiles -gt 0) {
            Start-Sleep -Milliseconds ([int]([double]$Config.PauseBetweenFiles * 1000))
        }
    }

    if ($failedQueue.Count -gt 0 -and [int]$Config.DeferredRetryRounds -gt 0) {
        $retryResult = Invoke-DeferredRetry -Config $Config -MonthName $MonthName -DestinationFolder $destinationFolder -FailedQueue $failedQueue -Records $records -Context $currentContext -FolderItem $currentFolder -LocalShell $localShell
        $currentContext = $retryResult.Context
        $currentFolder = $retryResult.FolderItem
        $failedQueue = $retryResult.FailedQueue
        $stats.RetryCopied = $retryResult.RetryCopied
        $stats.RetrySkipped = $retryResult.RetrySkipped
    }

    $stats.FinalFailed = $failedQueue.Count
    foreach ($failure in $failedQueue) {
        Add-FailureRecord -MonthName $MonthName -FileName $failure.Record.Name -SizeText $failure.SizeText -Reason $failure.Reason
        Add-ResultRecord -MonthName $MonthName -FileName $failure.Record.Name -Status '最终失败' -SizeText $failure.SizeText -Seconds 0 -Reason $failure.Reason
    }

    Write-Progress -Activity ("复制 {0}" -f $MonthName) -Completed
    Release-ComObject $localShell
    $summary = [pscustomobject]@{
        Month = $MonthName
        TotalFiles = $stats.TotalFiles
        InitialCopied = $stats.Copied
        SkippedExisting = $stats.Skipped
        InitialFailed = $stats.InitialFailed
        RetryCopied = $stats.RetryCopied
        RetrySkipped = $stats.RetrySkipped
        FinalFailed = $stats.FinalFailed
        CompletedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    $script:MonthlySummaries.Add($summary)
    Write-Log ("{0} 完成：总文件 {1}，初始复制 {2}，已存在跳过 {3}，初次失败 {4}，延迟重试复制 {5}，重试后已存在 {6}，最终失败 {7}" -f $MonthName, $stats.TotalFiles, $stats.Copied, $stats.Skipped, $stats.InitialFailed, $stats.RetryCopied, $stats.RetrySkipped, $stats.FinalFailed) OK
    return [pscustomobject]@{
        Stats = $stats
        Context = $currentContext
    }
}

function Invoke-TestCopy {
    param(
        $Config,
        $Context,
        [string[]]$Months,
        [string]$PreferredMonth = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredMonth) -and $Months -contains $PreferredMonth) {
        $month = $PreferredMonth
    }
    else {
        $month = Select-MonthsInteractive -Months $Months | Select-Object -First 1
    }
    $initialLookup = Get-MonthFolderWithRetry -Context $Context -FolderName $month -TimeoutSeconds 30
    $Context = $initialLookup.Context
    $folderItem = $initialLookup.Folder
    $listing = Get-FileRecordsWithRecovery -Config $Config -MonthName $month -Context $Context -FolderItem $folderItem
    $Context = $listing.Context
    $folderItem = $listing.FolderItem
    $records = @($listing.Records)
    $folderView = $folderItem.GetFolder

    $chosen = $null
    foreach ($record in $records) {
        $item = Resolve-FileItem -FolderItem $folderItem -Record $record
        if ($null -eq $item) { continue }
        $sizeInfo = Get-ItemSizeInfo -Item $item -FolderView $folderView
        $sizeBytes = if ($null -ne $sizeInfo.ExactBytes) { $sizeInfo.ExactBytes } else { $sizeInfo.ApproxBytes }

        if ($record.Name -match '\.(JPG|JPEG|PNG)$' -and ($null -eq $sizeBytes -or $sizeBytes -le 50MB)) {
            $chosen = [pscustomobject]@{ Record = $record; Item = $item; Size = $sizeInfo }
            break
        }
        if ($null -eq $chosen -and ($null -eq $sizeBytes -or $sizeBytes -le 100MB)) {
            $chosen = [pscustomobject]@{ Record = $record; Item = $item; Size = $sizeInfo }
        }
    }

    if ($null -eq $chosen) {
        $chosen = [pscustomobject]@{ Record = $records[0]; Item = (Resolve-FileItem -FolderItem $folderItem -Record $records[0]); Size = $null }
    }

    $testRoot = Join-Path $Config.DestinationRoot ('_MTP自动复制测试_{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    Write-Section '执行单文件测试'
    Write-Host ("测试文件：{0}" -f $chosen.Record.Name) -ForegroundColor Yellow
    Write-Host ("目标目录：{0}" -f $testRoot) -ForegroundColor Yellow

    $localShell = New-Object -ComObject Shell.Application
    $result = Copy-SingleFile -Item $chosen.Item -FolderView $folderView -DestinationFolder $testRoot -FileName $chosen.Record.Name -Config $Config -LocalShell $localShell
    Release-ComObject $localShell

    if ($result.Status -eq 'Copied') {
        Write-Host ''
        Write-Host '测试复制成功。' -ForegroundColor Green
        Write-Host ("文件：{0}" -f (Join-Path $testRoot $chosen.Record.Name)) -ForegroundColor Green
        Write-Host ("大小：{0}，耗时：{1:N1} 秒" -f (Format-Bytes $result.SizeBytes), $result.Seconds) -ForegroundColor Green
    }
    else {
        Write-Host ''
        Write-Host ("测试未成功：{0}" -f $result.Reason) -ForegroundColor Red
    }
}

function Show-Failures {
    if (-not (Test-Path -LiteralPath $script:FailuresCsv)) {
        Write-Host '还没有失败记录。' -ForegroundColor Green
        return
    }

    Write-Section '最近的失败记录'
    try {
        $rows = Import-Csv -LiteralPath $script:FailuresCsv -Encoding UTF8 | Select-Object -Last 50
        $rows | Format-Table Time, Month, File, Size, Reason -AutoSize
        Write-Host ("完整记录：{0}" -f $script:FailuresCsv) -ForegroundColor Yellow
    }
    catch {
        Write-Host ("读取失败记录出错：{0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Set-DestinationRootInteractive {
    param($Config)

    Write-Host ''
    Write-Host ("当前目标目录：{0}" -f $Config.DestinationRoot) -ForegroundColor Cyan
    $newPath = [string](Read-Host '输入新的目标根目录，直接回车取消')
    if ([string]::IsNullOrWhiteSpace($newPath)) { return }

    $newPath = $newPath.Trim().Trim('"')
    $normalizedPath = Normalize-DestinationRoot -Path $newPath
    if ($normalizedPath -ne $newPath) {
        Write-Host ("检测到你输入的是月份目录，已改为它的上级根目录：{0}" -f $normalizedPath) -ForegroundColor Yellow
        $newPath = $normalizedPath
    }
    $root = [System.IO.Path]::GetPathRoot($newPath)
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
        Write-Host '目标盘不存在。' -ForegroundColor Red
        return
    }

    if (-not (Test-Path -LiteralPath $newPath)) {
        New-Item -ItemType Directory -Path $newPath -Force | Out-Null
    }

    $Config.DestinationRoot = $newPath
    Save-Config $Config
    Write-Host '目标目录已保存。' -ForegroundColor Green
}

function Invoke-SelectedMonths {
    param(
        $Config,
        $Context,
        [string[]]$SelectedMonths
    )

    if (-not (Test-Path -LiteralPath $Config.DestinationRoot)) {
        New-Item -ItemType Directory -Path $Config.DestinationRoot -Force | Out-Null
    }

    $totals = [pscustomobject]@{
        TotalFiles = 0
        InitialCopied = 0
        Skipped = 0
        InitialFailed = 0
        RetryCopied = 0
        RetrySkipped = 0
        FinalFailed = 0
    }

    $currentContext = $Context
    foreach ($month in $SelectedMonths) {
        $monthCompleted = $false
        for ($monthAttempt = 1; $monthAttempt -le 3; $monthAttempt++) {
            try {
                if ($monthAttempt -gt 1) {
                    Write-Host ("重新处理同一月份 {0}（第 {1} 次恢复尝试）..." -f $month, $monthAttempt) -ForegroundColor Yellow
                }
                $monthResult = Invoke-MonthCopy -Config $Config -MonthName $month -Context $currentContext
                $currentContext = $monthResult.Context
                $stats = $monthResult.Stats
                $totals.TotalFiles += $stats.TotalFiles
                $totals.InitialCopied += $stats.Copied
                $totals.Skipped += $stats.Skipped
                $totals.InitialFailed += $stats.InitialFailed
                $totals.RetryCopied += $stats.RetryCopied
                $totals.RetrySkipped += $stats.RetrySkipped
                $totals.FinalFailed += $stats.FinalFailed
                $monthCompleted = $true
                break
            }
            catch {
                Write-Log ("处理 {0} 出错（第 {1}/3 次）：{2}" -f $month, $monthAttempt, $_.Exception.Message) ERROR
                if ($monthAttempt -lt 3) {
                    Write-Host '正在重新连接 MTP，随后重试同一月份...' -ForegroundColor Yellow
                    $currentContext = Reset-MtpConnection -Config $Config
                    Start-Sleep -Seconds 5
                }
            }
        }
        if (-not $monthCompleted) {
            $errorMessage = "月份 $month 连续三次未能恢复，已停止该月份任务。"
            Write-Log $errorMessage ERROR
            if ($SelectedMonths.Count -eq 1) {
                throw $errorMessage
            }
        }
    }

    return $totals
}

function Show-MainMenu {
    param(
        $Config,
        [string[]]$Months,
        $Context
    )

    while ($true) {
        Write-Section 'MTP 自动复制器'
        Write-Host ("手机：{0}" -f $Context.Device.Name) -ForegroundColor Gray
        Write-Host ("目标：{0}" -f $Config.DestinationRoot) -ForegroundColor Gray
        Write-Host ("检测到 {0} 个月份文件夹" -f $Months.Count) -ForegroundColor Gray
        Write-Host ''
        Write-Host '  1. 自动复制全部月份' -ForegroundColor White
        Write-Host '  2. 选择指定月份复制' -ForegroundColor White
        Write-Host '  3. 单文件测试复制' -ForegroundColor White
        Write-Host '  4. 修改目标根目录' -ForegroundColor White
        Write-Host '  5. 查看失败记录' -ForegroundColor White
        Write-Host '  6. 退出' -ForegroundColor White
        Write-Host ''

        $choice = [string](Read-Host '请选择')
        switch ($choice.Trim()) {
            '1' {
                Write-Host ''
                Write-Host ("即将处理全部 {0} 个月份文件夹。大任务可随时按 Ctrl+C 停止，下次运行会跳过已完成文件。" -f $Months.Count) -ForegroundColor Yellow
                $confirm = [string](Read-Host '输入 Y 开始')
                if ($confirm.Trim().ToUpperInvariant() -ne 'Y') { continue }
                $totals = Invoke-SelectedMonths -Config $Config -Context $Context -SelectedMonths $Months
                Write-Section '全部任务完成'
                Write-Host ("总文件 {0}，初始复制 {1}，已存在跳过 {2}，初次失败 {3}，延迟重试复制 {4}，重试后已存在 {5}，最终失败 {6}" -f $totals.TotalFiles, $totals.InitialCopied, $totals.Skipped, $totals.InitialFailed, $totals.RetryCopied, $totals.RetrySkipped, $totals.FinalFailed) -ForegroundColor Cyan
                return
            }
            '2' {
                $selected = @(Select-MonthsInteractive -Months $Months)
                $totals = Invoke-SelectedMonths -Config $Config -Context $Context -SelectedMonths $selected
                Write-Section '指定任务完成'
                Write-Host ("总文件 {0}，初始复制 {1}，已存在跳过 {2}，初次失败 {3}，延迟重试复制 {4}，重试后已存在 {5}，最终失败 {6}" -f $totals.TotalFiles, $totals.InitialCopied, $totals.Skipped, $totals.InitialFailed, $totals.RetryCopied, $totals.RetrySkipped, $totals.FinalFailed) -ForegroundColor Cyan
                return
            }
            '3' {
                Invoke-TestCopy -Config $Config -Context $Context -Months $Months
            }
            '4' {
                Set-DestinationRootInteractive -Config $Config
            }
            '5' {
                Show-Failures
            }
            '6' {
                return
            }
            default {
                Write-Host '无效选项。' -ForegroundColor Red
            }
        }
    }
}

function Export-RunResults {
    if ($script:MonthlySummaries.Count -gt 0) {
        $summaryPath = Join-Path $script:LogDir ("summary-{0}.csv" -f $script:RunId)
        $script:MonthlySummaries | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8
        Write-Host ("本次统计汇总：{0}" -f $summaryPath) -ForegroundColor Yellow
    }
    if ($script:CurrentResults.Count -eq 0) { return }
    $path = Join-Path $script:LogDir ("results-{0}.csv" -f $script:RunId)
    $script:CurrentResults | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    Write-Host ("本次结果明细：{0}" -f $path) -ForegroundColor Yellow
}

try {
    Initialize-Log
    Enable-KeepAwake
    Start-DialogWatcher
    $config = Load-Config

    if (-not (Test-IsAdministrator)) {
        Write-Log '当前未以管理员身份运行，自动重置 MTP 可能会失败。' WARN
    }

    if ($Mode -eq 'Failures') {
        Show-Failures
        if (-not $NoPause) {
            Read-Host '按 Enter 关闭'
        }
        exit 0
    }

    $context = Get-MtpContext -TimeoutSeconds 15
    if ($null -eq $context) {
        Write-Host '没有找到 iPhone 文件通道。请连接数据线、解锁手机并保持亮屏。' -ForegroundColor Yellow
        Read-Host '连接好后按 Enter'
        $context = Get-MtpContext -TimeoutSeconds 60
    }
    if ($null -eq $context) {
        throw 'iPhone MTP 设备不可用。'
    }

    $months = @(Get-MonthFolders -Context $context)
    if ($months.Count -eq 0) {
        throw '手机 Internal Storage 中没有找到 YYYYMM_a 形式的月份文件夹。'
    }

    switch ($Mode) {
        'All' {
            $totals = Invoke-SelectedMonths -Config $config -Context $context -SelectedMonths $months
            Write-Section '任务完成'
            Write-Host ("总文件 {0}，初始复制 {1}，已存在跳过 {2}，初次失败 {3}，延迟重试复制 {4}，重试后已存在 {5}，最终失败 {6}" -f $totals.TotalFiles, $totals.InitialCopied, $totals.Skipped, $totals.InitialFailed, $totals.RetryCopied, $totals.RetrySkipped, $totals.FinalFailed) -ForegroundColor Cyan
        }
        'Month' {
            if ([string]::IsNullOrWhiteSpace($Month) -or $months -notcontains $Month) {
                throw "找不到指定月份文件夹：$Month"
            }
            $totals = Invoke-SelectedMonths -Config $config -Context $context -SelectedMonths @($Month)
            Write-Section '任务完成'
            Write-Host ("总文件 {0}，初始复制 {1}，已存在跳过 {2}，初次失败 {3}，延迟重试复制 {4}，重试后已存在 {5}，最终失败 {6}" -f $totals.TotalFiles, $totals.InitialCopied, $totals.Skipped, $totals.InitialFailed, $totals.RetryCopied, $totals.RetrySkipped, $totals.FinalFailed) -ForegroundColor Cyan
        }
        'Test' {
            Invoke-TestCopy -Config $config -Context $context -Months $months -PreferredMonth $Month
        }
        default {
            Show-MainMenu -Config $config -Months $months -Context $context
        }
    }

    Export-RunResults
    Write-Host ''
    Write-Host ("运行日志：{0}" -f $script:CurrentLog) -ForegroundColor Yellow
    Write-Host ("失败记录：{0}" -f $script:FailuresCsv) -ForegroundColor Yellow
}
catch {
    if ($script:CurrentLog) {
        Write-Log $_.Exception.Message ERROR
    }
    else {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    if (-not $NoPause) {
        Write-Host ''
        Read-Host '按 Enter 关闭'
    }
    exit 1
}
finally {
    Disable-KeepAwake
    Stop-DialogWatcher
    if ($script:SingleInstanceAcquired -and $null -ne $script:SingleInstanceMutex) {
        try {
            $script:SingleInstanceMutex.ReleaseMutex()
        }
        catch {
        }
        $script:SingleInstanceMutex.Dispose()
        $script:SingleInstanceMutex = $null
        $script:SingleInstanceAcquired = $false
    }
}

if (-not $NoPause) {
    Write-Host ''
    Read-Host '按 Enter 关闭'
}
