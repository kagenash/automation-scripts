🇧🇷 [Português](README.md) | 🇺🇸 **English**

# windows-maintenance.ps1

Deep maintenance and optimization script for Windows systems, with 28 automated steps covering everything from cache cleanup to network and registry tuning.

## What it does

| Step | Action |
|---|---|
| Diagnostics | TOP 10 processes by CPU and memory, disk space, startup programs |
| Power plan | Enables High Performance, disables hibernation and Fast Startup |
| System integrity | DISM (CheckHealth → ScanHealth → RestoreHealth) + SFC /scannow |
| Disk health | SMART check via CIM |
| Performance | Process priority, visual effects, WaitToKillServiceTimeout |
| Temp cleanup | `%TEMP%`, `%windir%\Temp`, Prefetch |
| DISM components | `startcomponentcleanup /resetbase` |
| Disk | TRIM (SSD) or Defrag (HDD) via `Optimize-Volume` |
| Caches | Thumbnails, icons, fonts, legacy IE/Edge, Chrome, Edge Chromium (all profiles) |
| Recycle Bin | Empties it + sets immediate deletion |
| Event logs | Clears all channels via `wevtutil` |
| CleanMgr | Automated run via StateFlags |
| Downloads | Removes files older than 30 days |
| Critical services | Checks and restarts Winmgmt, RpcSs, EventLog, W32Time |
| Startup | Removes Explorer delay, disables hybrid Fast Startup |
| Telemetry | Disables DiagTrack, dmwappushservice, WerSvc, PcaSvc and the data collection policy |
| Background apps | Disables GlobalUserDisabled + BackgroundAppGlobalToggle |
| SysMain | Disabled on HDD, kept on SSD (automatic detection) |
| Windows Update | Clears download cache and Delivery Optimization |
| DNS and network | Flush DNS, TCP auto-tuning, disables EEE and wake-on-LAN on active adapters |
| .NET NGEN | Triggers assembly optimization via scheduled tasks |
| Windows Search | Rebuilds the search index |
| Pagefile | Ensures automatic management by the system |
| Audit | Lists active third-party scheduled tasks |
| CHKDSK + reboot | Schedules a disk check and reboots in 15 seconds |

## Requirements

- Windows 10 / 11
- PowerShell 5.1+
- Run as **Administrator**

## Usage

```powershell
# Open PowerShell as Administrator
.\windows-maintenance.ps1
```

The system reboots automatically at the end. Save all your work before running.

## Notes

- The script deletes itself after running via an external `cmd` process
- Every action is logged to the terminal with a `[N/28]` step indicator
- SysMain is only disabled on HDD — on SSD it stays enabled, as Microsoft recommends

## License

MIT — see [LICENSE](LICENSE).
