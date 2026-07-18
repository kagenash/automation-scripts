# orl-linux-maintenance.sh

Script de manutenção e otimização automatizada para sistemas Linux, com foco em performance, segurança e reversibilidade total.

## O que faz

- **Tuning de kernel** via `sysctl.d/` — ajusta parâmetros de memória, CPU scheduler e buffers TCP sem modificar `/etc/sysctl.conf`
- **Ajuste de I/O scheduler** via regras `udev` — otimiza throughput de disco por tipo de dispositivo
- **Limpeza de cache** — page cache, dentries e inodes
- **Desfragmentação / TRIM** — de acordo com o tipo de armazenamento detectado
- **Reinicialização automática** com auto-deleção segura do script após a execução

## Requisitos

- Bash 4.3+
- Execução como `root`
- Kernel Linux 3.x+

## Uso

```bash
sudo bash orl-linux-maintenance.sh
```

## Reversão completa

Todas as alterações são isoladas em arquivos dedicados, removíveis individualmente:

```bash
# Reverte tuning de kernel
rm -f /etc/sysctl.d/90-orl-optimization.conf && sysctl --system

# Reverte ajuste de I/O scheduler
rm -f /etc/udev/rules.d/60-io-schedulers.rules
```

## Log

```
/var/log/orl-manutencao.log
```

## Segurança

- PATH explícito definido no início do script para prevenir PATH-hijacking em ambientes comprometidos
- Uso de `set -euo pipefail` para falha imediata em erros
- Constantes declaradas como `readonly` para evitar mutações acidentais
- Auto-deleção resolve o path absoluto no início da execução para garantir funcionamento mesmo com mudança de diretório
