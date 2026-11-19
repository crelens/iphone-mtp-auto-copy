[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$ParentPid,

    [int]$PollMilliseconds = 500
)

$ErrorActionPreference = 'SilentlyContinue'
$script:WatchdogRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:WatchdogLogDir = Join-Path $script:WatchdogRoot 'logs'
$script:WatchdogLog = Join-Path $script:WatchdogLogDir 'dialog-watchdog.log'

if (-not (Test-Path -LiteralPath $script:WatchdogLogDir)) {
    New-Item -ItemType Directory -Path $script:WatchdogLogDir | Out-Null
}

if (-not ('MtpCopyDialogWatcher' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class MtpCopyDialogWatcher
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDlgItem(IntPtr hDlg, int itemId);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    private const uint BM_CLICK = 0x00F5;
    private const uint WM_CLOSE = 0x0010;

    private static string GetText(IntPtr hWnd)
    {
        var buffer = new StringBuilder(512);
        GetWindowText(hWnd, buffer, buffer.Capacity);
        return buffer.ToString();
    }

    private static string GetClass(IntPtr hWnd)
    {
        var buffer = new StringBuilder(256);
        GetClassName(hWnd, buffer, buffer.Capacity);
        return buffer.ToString();
    }

    private static bool IsCopyError(string title)
    {
        return title.IndexOf("复制文件或文件夹时出错", StringComparison.OrdinalIgnoreCase) >= 0
            || title.IndexOf("Copy File or Folder Error", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static bool IsCopyProgress(string title)
    {
        return title.IndexOf("正在复制", StringComparison.OrdinalIgnoreCase) >= 0
            || title.IndexOf("Copying", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    public static int CloseDialogs()
    {
        var sawError = false;
        var closed = 0;

        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd))
            {
                return true;
            }

            var title = GetText(hWnd);
            var className = GetClass(hWnd);
            if (className == "#32770" && IsCopyError(title))
            {
                sawError = true;
                var okButton = GetDlgItem(hWnd, 1);
                if (okButton != IntPtr.Zero)
                {
                    SendMessage(okButton, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
                }
                else
                {
                    PostMessage(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                }
                closed++;
            }

            return true;
        }, IntPtr.Zero);

        if (sawError)
        {
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd))
                {
                    return true;
                }

                var title = GetText(hWnd);
                if (IsCopyProgress(title))
                {
                    PostMessage(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                    closed++;
                }

                return true;
            }, IntPtr.Zero);
        }

        return closed;
    }
}
'@
}

while ($true) {
    if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
        break
    }

    $closed = [MtpCopyDialogWatcher]::CloseDialogs()
    if ($closed -gt 0) {
        $line = '[{0}] Closed {1} copy dialog/progress window(s).' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $closed
        Add-Content -LiteralPath $script:WatchdogLog -Value $line -Encoding UTF8
    }

    Start-Sleep -Milliseconds $PollMilliseconds
}
