# MTP Guardian

### Reliable iPhone to Windows photo and video transfer over MTP

[English](README.md) | [简体中文使用说明](USAGE.zh-CN.md)

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![License](https://img.shields.io/badge/license-MIT-green)

A Windows PowerShell tool for copying large iPhone photo and video collections to a PC without letting one failed MTP operation stop the entire transfer.

Windows File Explorer can become stuck when copying iPhone media over MTP. Typical messages include:

- `The requested value cannot be determined.`
- `The data type supplied is incorrect.`
- `The requested resource is in use.`
- A transfer that reports several hours remaining and never progresses.

MTP Guardian works around these failures by copying one file at a time, recovering the MTP session, retrying failed files, and producing a final report.

## Features

| Feature | What it does |
|---|---|
| Copy-only workflow | Never deletes or moves source files from the iPhone |
| Monthly folder mapping | Copies `YYYYMM_*` folders into matching folders on the PC |
| One file at a time | Stops one bad file from blocking the whole batch |
| Automatic MTP recovery | Restarts the MTP device when the transfer becomes unresponsive |
| Error-dialog watchdog | Automatically closes blocking Windows copy error dialogs |
| Deferred retries | Retries failed files in automatic rounds after the main pass |
| Resume support | Skips files already present with the correct size |
| Final statistics | Reports copied, skipped, retried, and permanently failed files |
| Local logging | Writes logs and CSV reports locally; no telemetry or cloud upload |
| Single-instance lock | Prevents two copy processes from writing the same file |

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or later
- An iPhone connected with a data-capable USB cable
- Administrator permission for automatic MTP device recovery
- Free disk space for the selected media

## Download

Use the latest release on GitHub:

[Download the latest release](../../releases/latest)

Alternatively, open the repository and click:

```text
Code > Download ZIP
```

There is no installer. Extract the ZIP and run the launcher.

## Quick Start

1. Connect the iPhone and unlock it.
2. Keep the iPhone screen on during the transfer. Setting Auto-Lock to Never is recommended.
3. Extract the release ZIP.
4. Double-click `launcher-mtp-auto-copy.cmd`.
5. Approve the Windows administrator prompt.
6. Choose option `3` for a one-file test.
7. After the test succeeds, choose option `1` or `2` to copy media.

The default destination is:

```text
%USERPROFILE%\Pictures\iPhoneImport
```

Folder mapping example:

```text
iPhone: Apple iPhone\Internal Storage\202604_a
PC:     %USERPROFILE%\Pictures\iPhoneImport\202604_a
```

The destination can be changed from the main menu.

## How the Copy Process Works

```text
1. Read the selected iPhone month folder
2. Compare each source file with the destination
3. Copy missing files one at a time
4. Recover MTP automatically when a session becomes unhealthy
5. Retry failed files in deferred rounds
6. Write logs, statistics, and the final failure list
```

After the main pass, failed files are retried automatically in batches of three rounds. If failures remain, the tool asks:

```text
R = retry another batch
S = stop and keep the final failure list
```

This allows unattended recovery while still producing a finite result for permanently unreadable files.

## Output and Logs

Runtime files are stored in the tool directory:

```text
logs\mtp-copy-YYYYMMDD-HHMMSS.log
logs\results-YYYYMMDD-HHMMSS.csv
logs\summary-YYYYMMDD-HHMMSS.csv
logs\failed-files.csv
logs\dialog-watchdog.log
```

Incomplete destination files are moved into:

```text
_incomplete
```

Source files on the iPhone are never modified.

## Configuration

The tool creates `mtp-auto-copy.config.json` on first use. A sample is available in [config.example.json](config.example.json).

Important settings:

| Setting | Default | Purpose |
|---|---:|---|
| `DestinationRoot` | Pictures\iPhoneImport | Root directory for monthly folders |
| `ResetEveryFiles` | 100 | MTP reset interval during a long run |
| `LargeFileResetMB` | 1000 | Reset before unusually large files |
| `StallSeconds` | 75 | Detect a file with no write progress |
| `StartTimeoutSeconds` | 90 | Detect a file that never starts |
| `DeferredRetryRounds` | 3 | Automatic post-pass retry rounds |
| `DeferredRetryDelaySeconds` | 10 | Delay between retry rounds |

## Safety and Privacy

- The tool runs locally and does not upload data.
- It uses Windows MTP APIs and PowerShell; no cloud service is required.
- It copies files only. It does not delete phone media.
- Logs contain local file names. Review logs before attaching them to a public GitHub issue.
- Do not publish your `mtp-auto-copy.config.json` or `logs` folder.

## Troubleshooting

### The iPhone is not detected

- Use a data-capable USB cable.
- Unlock the iPhone and keep it on.
- Close other File Explorer copy tasks.
- Try a different USB port.
- If Windows requests it, unplug and reconnect the iPhone once.

### A copy error dialog appears

The watchdog should close it automatically. If it remains, close it manually once; the main program will continue with retry logic.

### A file still fails after retries

The file may be iCloud-only, corrupted, or unreadable by the iPhone-side app. It will appear in `logs\failed-files.csv` after the final retry batch.

## Development

PowerShell syntax check:

```powershell
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path '.\mtp-auto-copy.ps1'),
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count) { $errors }
```

Run a one-file test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\mtp-auto-copy.ps1" -Mode Test -Month "202604_a"
```

## Contributing

Issues and pull requests are welcome. Please remove personal paths, file names, and account information from logs before posting them.

## License

MIT. See [LICENSE](LICENSE).

This project is not affiliated with Apple Inc.
