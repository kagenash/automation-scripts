# automation-scripts

Automation scripts for Linux maintenance, PostgreSQL recovery, Windows optimization and SSH setup — Bash & PowerShell.

## Scripts

| Script | Descrição | Docs |
|---|---|---|
| `psql-emergency-recovery.sh` | Recuperação de emergência para PostgreSQL com zero tolerância a downtime | [README](README-psql-emergency-recovery.md) |
| `orl-linux-maintenance.sh` | Manutenção e otimização de sistemas Linux (kernel tuning, I/O, cache) | [README](README-orl-linux-maintenance.md) |
| `solid-mass-deploy.ps1` | Deploy em massa via SSH com interface gráfica e execução paralela via Runspaces | [README](README-solid-mass-deploy.md) |
| `windows-maintenance.ps1` | Manutenção profunda de sistemas Windows com 28 etapas automatizadas | [README](README-windows-maintenance.md) |
| `ssh-setup.ps1` | Configuração automatizada de ambiente SSH no Windows com ProxyJump | [README](README-ssh-setup.md) |

## Stack

- **Bash** — scripts Linux com `set -euo pipefail`, readonly globals e reversibilidade total
- **PowerShell** — automação Windows com GUI nativa, Runspaces e manipulação de registro
