🇧🇷 [Português](README.md) | 🇺🇸 **English**

# orl-linux-maintenance.sh

Automated maintenance and optimization script for Linux systems, focused on performance, security and full reversibility.

## What it does

- **Kernel tuning** via `sysctl.d/` — adjusts memory, CPU scheduler and TCP buffer parameters without modifying `/etc/sysctl.conf`
- **I/O scheduler tuning** via `udev` rules — optimizes disk throughput per device type
- **Cache cleanup** — page cache, dentries and inodes
- **Defragmentation / TRIM** — according to the detected storage type
- **Automatic reboot** with safe self-deletion of the script after it runs

## Requirements

- Bash 4.3+
- Run as `root`
- Linux kernel 3.x+

## Usage

```bash
sudo bash orl-linux-maintenance.sh
```

## Full rollback

All changes are isolated in dedicated files that can be removed individually:

```bash
# Revert kernel tuning
rm -f /etc/sysctl.d/90-orl-optimization.conf && sysctl --system

# Revert I/O scheduler tuning
rm -f /etc/udev/rules.d/60-io-schedulers.rules
```

## Log

```
/var/log/orl-manutencao.log
```

## Security

- Explicit PATH set at the start of the script to prevent PATH hijacking in compromised environments
- `set -euo pipefail` for immediate failure on errors
- Constants declared as `readonly` to prevent accidental changes
- Self-deletion resolves the absolute path at startup so it works even if the working directory changes

## License

MIT — see [LICENSE](LICENSE).
