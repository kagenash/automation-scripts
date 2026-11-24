🇧🇷 [Português](README.md) | 🇺🇸 **English**

# ssh-setup.ps1

Automated SSH environment setup script for Windows, with ProxyJump support to reach internal servers through an intermediate host.

## What it does

1. Creates the `~/.ssh` folder if it doesn't exist
2. Enables the `ssh-agent` service and sets it to start automatically
3. Generates an RSA 4096-bit key pair (only if one doesn't exist)
4. Creates the `~/.ssh/config` file with a ProxyJump hop configuration
5. Creates a `.bat` shortcut on the Desktop for one-click connection

## Requirements

- Windows 10 / 11 with OpenSSH installed
- PowerShell running as **Administrator** (needed to configure `ssh-agent`)

## Usage

```powershell
# Open PowerShell as Administrator
.\ssh-setup.ps1
```

When it finishes, a `CONECTAR_SERVIDOR.bat` icon is created on the Desktop.

## Configured topology

```
[Local machine] → [jslxuser01 (jump host)] → [target: 10.1.50.50]
```

Edit the variables in the script to match the hosts and IPs of your environment before running.

## Notes

- The RSA key isn't overwritten if it already exists
- `ForwardAgent yes` on the jump host lets you use the local key on the target server without copying it

## License

MIT — see [LICENSE](LICENSE).
