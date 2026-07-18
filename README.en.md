🇧🇷 [Português](README.md) | 🇺🇸 **English**

# automation-scripts

Automation scripts for Linux maintenance, PostgreSQL recovery, Windows optimization and SSH setup — Bash & PowerShell.

## Scripts

| Script | What it does | Docs |
|---|---|---|
| [`orl-linux-maintenance.sh`](linux-maintenance/orl-linux-maintenance.sh) | Maintenance and optimization of Linux systems (kernel tuning, I/O, cache) | [README](linux-maintenance/README.md) |
| [`psql-emergency-recovery.sh`](postgresql-recovery/psql-emergency-recovery.sh) | Emergency recovery for PostgreSQL with zero tolerance for downtime | [README](postgresql-recovery/README.md) |
| [`windows-maintenance.ps1`](windows-maintenance/windows-maintenance.ps1) | Deep Windows maintenance with 28 automated steps | [README](windows-maintenance/README.md) |
| [`solid-mass-deploy.ps1`](mass-deploy/solid-mass-deploy.ps1) | Mass SSH deploy with a GUI and parallel execution via Runspaces | [README](mass-deploy/README.md) |
| [`ssh-setup.ps1`](ssh-setup/ssh-setup.ps1) | Automated SSH environment setup on Windows with ProxyJump | [README](ssh-setup/README.md) |

## Stack

- **Bash** — Linux scripts with `set -euo pipefail`, readonly globals and full reversibility
- **PowerShell** — Windows automation with native GUI, Runspaces and registry manipulation

## Tests

These scripts act on system state (kernel, services, database, registry) and aren't unit-testable in the traditional sense. The automated check here is **syntax/parse validation**: it guarantees no script has a syntax error before being distributed.

```powershell
pwsh ./tests/test_syntax.ps1
```

## Structure

```
automation-scripts/
├── linux-maintenance/
│   ├── orl-linux-maintenance.sh
│   └── README.md
├── postgresql-recovery/
│   ├── psql-emergency-recovery.sh
│   └── README.md
├── windows-maintenance/
│   ├── windows-maintenance.ps1
│   └── README.md
├── mass-deploy/
│   ├── solid-mass-deploy.ps1
│   └── README.md
├── ssh-setup/
│   ├── ssh-setup.ps1
│   └── README.md
├── tests/
│   └── test_syntax.ps1
├── LICENSE
└── README.md
```

Each folder is self-contained: script + usage docs, requirements and technical notes.

## License

MIT — use, adapt and share freely.
