🇧🇷 [Português](README.md) | 🇺🇸 **English**

# automation-scripts

Automation scripts for Linux maintenance, PostgreSQL recovery, Windows optimization, SSH setup and ITSM (Cherwell) — Bash & PowerShell.

## Scripts

| Script | What it does | Docs |
|---|---|---|
| [`orl-linux-maintenance.sh`](linux-maintenance/orl-linux-maintenance.sh) | Maintenance and optimization of Linux systems (kernel tuning, I/O, cache) | [README](linux-maintenance/README.md) |
| [`psql-emergency-recovery.sh`](postgresql-recovery/psql-emergency-recovery.sh) | Emergency recovery for PostgreSQL with zero tolerance for downtime | [README](postgresql-recovery/README.md) |
| [`windows-maintenance.ps1`](windows-maintenance/windows-maintenance.ps1) | Deep Windows maintenance with 28 automated steps | [README](windows-maintenance/README.md) |
| [`solid-mass-deploy.ps1`](mass-deploy/solid-mass-deploy.ps1) | Mass SSH deploy with a GUI and parallel execution via Runspaces | [README](mass-deploy/README.md) |
| [`ssh-setup.ps1`](ssh-setup/ssh-setup.ps1) | Automated SSH environment setup on Windows with ProxyJump | [README](ssh-setup/README.md) |
| [`cherwell-automation/`](cherwell-automation/) | **Testing and study only.** Cherwell Service Management kit: weekly report with e-mail, reply templates, host check and REST API | [README](cherwell-automation/README.md) |

## Stack

- **Bash** — Linux scripts with `set -euo pipefail`, readonly globals and full reversibility
- **PowerShell** — Windows automation with native GUI, Runspaces, registry manipulation, REST API and Outlook via COM

## Tests

These scripts act on system state (kernel, services, database, registry) and aren't unit-testable in the traditional sense. The automated check here is **syntax/parse validation**: it guarantees no script has a syntax error before being distributed.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_syntax.ps1   # Windows PowerShell 5.1
pwsh -File ./tests/test_syntax.ps1                                          # or PowerShell 7+
```

## Structure

```
automation-scripts/
├── linux-maintenance/
│   ├── orl-linux-maintenance.sh
│   ├── LICENSE
│   ├── README.en.md
│   └── README.md
├── postgresql-recovery/
│   ├── psql-emergency-recovery.sh
│   ├── LICENSE
│   ├── README.en.md
│   └── README.md
├── windows-maintenance/
│   ├── windows-maintenance.ps1
│   ├── LICENSE
│   ├── README.en.md
│   └── README.md
├── mass-deploy/
│   ├── solid-mass-deploy.ps1
│   ├── LICENSE
│   ├── README.en.md
│   └── README.md
├── ssh-setup/
│   ├── ssh-setup.ps1
│   ├── LICENSE
│   ├── README.en.md
│   └── README.md
├── cherwell-automation/
│   ├── exemplos/
│   │   └── incidentes_exemplo.csv
│   ├── cherwell-api-export.ps1
│   ├── cherwell-bridge-test.ps1
│   ├── cherwell-host-check.ps1
│   ├── cherwell-reply-template.ps1
│   ├── cherwell-weekly-report.ps1
│   ├── LICENSE
│   ├── README.en.md
│   └── README.md
├── tests/
│   └── test_syntax.ps1
├── LICENSE
├── README.en.md
└── README.md
```

Each folder is self-contained: script, docs in Portuguese and English (usage, requirements and technical notes) and LICENSE. The scripts in `cherwell-automation/` are for testing and study only.

## License

MIT — use, adapt and share freely.
