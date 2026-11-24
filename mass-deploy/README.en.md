🇧🇷 [Português](README.md) | 🇺🇸 **English**

# solid-mass-deploy.ps1

PowerShell GUI tool for mass deployment of commands via SSH to multiple servers at once, with parallel execution via Runspaces and a native Windows interface.

## What it does

- Runs a command or script on N servers at the same time via SSH (Posh-SSH)
- GUI with progress bar, counter and an output console colored by result
- Parallel execution with Runspaces — the UI doesn't freeze during the deploy
- Cancel button with a thread-safe token (cancels without abruptly killing running processes)
- Statistical summary at the end: SUCCESS / FAILED / SKIPPED / DISPATCHED / CANCELLED
- Console line limit (keeps the last 1000 when it goes over 1500) to avoid excessive memory use
- Offers to open the log file when it finishes

## Requirements

- PowerShell 5.1+
- `Posh-SSH` module installed:
  ```powershell
  Install-Module Posh-SSH -Force
  ```

## Usage

Run the script directly from PowerShell:

```powershell
.\solid-mass-deploy.ps1
```

The interface opens automatically. Provide:
1. The list of target hosts (one per line or from a file)
2. The command to run or the script to send
3. Click **Deploy** to start

## Console colors

| Color | Status |
|---|---|
| Green | `[SUCCESS]` |
| Red | `[FAILED]` |
| Yellow | `[SKIPPED]` |
| Orange | `[DISPATCHED]` |
| Gray | `[CANCELLED]` |

## Technical notes

- Uses `List<T>` instead of `array +=` to avoid O(n²) complexity when building the target list
- Separately configurable timeouts for normal and disruptive commands
- Guard against an empty target list before starting the deploy

## License

MIT — see [LICENSE](LICENSE).
