# Security

## Data handling

MTP Guardian runs locally on Windows. It does not include telemetry, analytics, or cloud upload functionality.

The tool reads media from the connected iPhone and writes copies to the selected destination directory. It does not delete source files.

## Logs

Log files can contain:

- Local folder paths
- Media file names
- Error messages from Windows and MTP

Review and redact logs before posting them in a public issue.

Do not publish:

- `mtp-auto-copy.config.json`
- The `logs` folder
- Personal screenshots containing private media names

## Reporting a security issue

Please use GitHub private vulnerability reporting if it is enabled for the repository, or contact the maintainer without posting sensitive details publicly.
