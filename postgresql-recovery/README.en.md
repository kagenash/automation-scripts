🇧🇷 [Português](README.md) | 🇺🇸 **English**

# psql-emergency-recovery.sh

Emergency recovery script for PostgreSQL in point-of-sale (POS) environments, designed to restore availability of port 5432 within seconds with zero tolerance for downtime.

## Context

In POS environments with continuous replication to a central server, the real risk isn't data loss — it's a stopped POS. This script is explicitly allowed to be destructive with the local state of processes and locks, prioritizing immediate release of the database.

## What it does

- Terminates hung PostgreSQL processes with a configurable timeout (default: 2s before `kill -9`)
- Kills pending connections and locks blocking port 5432
- Runs automated diagnostics of the database state before and after the intervention
- Escalates recovery aggressiveness progressively (graceful → forced → `pg_resetwal`)
- Logs every action to `/var/log/pg_emergency_recovery.log` with timestamp and severity level
- Shows colored terminal output to make it easier to read under pressure

## Requirements

- Ubuntu
- PostgreSQL installed via `apt`
- Run as `root`
- No external dependencies beyond standard PostgreSQL

## Usage

```bash
sudo bash psql-emergency-recovery.sh
```

## Log

```
/var/log/pg_emergency_recovery.log
```

## Rollback

This script doesn't change persistent PostgreSQL settings. Every intervention is on in-memory state (processes, locks). No rollback is needed.

## Warning

Using `pg_resetwal` discards transactions not committed locally. In environments with second-by-second replication this is safe. In other contexts, evaluate before running.

## License

MIT — see [LICENSE](LICENSE).
