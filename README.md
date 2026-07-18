# automation-scripts

Automation scripts for Linux maintenance, PostgreSQL recovery, Windows optimization and SSH setup — Bash & PowerShell.

## Scripts

| Script | Descrição | Docs |
|---|---|---|
| [`orl-linux-maintenance.sh`](linux-maintenance/orl-linux-maintenance.sh) | Manutenção e otimização de sistemas Linux (kernel tuning, I/O, cache) | [README](linux-maintenance/README.md) |
| [`psql-emergency-recovery.sh`](postgresql-recovery/psql-emergency-recovery.sh) | Recuperação de emergência para PostgreSQL com zero tolerância a downtime | [README](postgresql-recovery/README.md) |
| [`windows-maintenance.ps1`](windows-maintenance/windows-maintenance.ps1) | Manutenção profunda de sistemas Windows com 28 etapas automatizadas | [README](windows-maintenance/README.md) |
| [`solid-mass-deploy.ps1`](mass-deploy/solid-mass-deploy.ps1) | Deploy em massa via SSH com interface gráfica e execução paralela via Runspaces | [README](mass-deploy/README.md) |
| [`ssh-setup.ps1`](ssh-setup/ssh-setup.ps1) | Configuração automatizada de ambiente SSH no Windows com ProxyJump | [README](ssh-setup/README.md) |

## Stack

- **Bash** — scripts Linux com `set -euo pipefail`, readonly globals e reversibilidade total
- **PowerShell** — automação Windows com GUI nativa, Runspaces e manipulação de registro

## Estrutura

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
├── LICENSE
└── README.md
```

Cada pasta é autocontida: script + documentação de uso, requisitos e notas técnicas.

## Licença

MIT — use, adapte e compartilhe à vontade.
