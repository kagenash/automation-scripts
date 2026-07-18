# psql-emergency-recovery.sh

Script de recuperação de emergência para PostgreSQL em ambientes de ponto de venda (PDV), projetado para restaurar a disponibilidade da porta 5432 em segundos com zero tolerância a downtime.

## Contexto

Em ambientes de PDV com replicação contínua para um servidor central, o risco real não é a perda de dados — é o PDV parado. Este script tem autorização explícita para ser destrutivo com o estado local de processos e locks, priorizando a liberação imediata do banco.

## O que faz

- Encerra processos travados no PostgreSQL com timeout configurável (padrão: 2s antes de `kill -9`)
- Mata conexões e locks pendentes que bloqueiam a porta 5432
- Executa diagnóstico automatizado do estado do banco antes e após a intervenção
- Escala a agressividade da recuperação progressivamente (graceful → forçado → `pg_resetwal`)
- Registra todas as ações em `/var/log/pg_emergency_recovery.log` com timestamp e nível de severidade
- Exibe saída colorida no terminal para facilitar leitura em situações de pressão

## Requisitos

- Ubuntu
- PostgreSQL instalado via `apt`
- Execução como `root`
- Sem dependências externas além do PostgreSQL padrão

## Uso

```bash
sudo bash psql-emergency-recovery.sh
```

## Log

```
/var/log/pg_emergency_recovery.log
```

## Reversão

Este script não altera configurações persistentes do PostgreSQL. Toda intervenção é sobre estado em memória (processos, locks). Não há rollback necessário.

## Aviso

O uso do `pg_resetwal` descarta transações não commitadas localmente. Em ambientes com replicação segundo a segundo, isso é seguro. Em outros contextos, avalie antes de executar.
