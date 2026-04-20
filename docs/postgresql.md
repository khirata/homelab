# PostgreSQL

Native PostgreSQL 16 instance shared across services (currently Infisical).
Binds to `localhost` only — not accessible externally.

---

## Operations

```bash
ssh <user>@<siem-host>

# Status
sudo systemctl status postgresql@16-main

# Connect
sudo -u postgres psql -c '\l'       # list databases
sudo -u postgres psql infisical     # connect to infisical DB
```

| Item | Path |
|---|---|
| Data directory | `/var/lib/postgresql/16/main/` |
| Backups | `/opt/siem/backups/postgresql/` |
| Logs | `journalctl -u postgresql@16-main` |

---

## Backup

Automated backups run via a systemd timer. To trigger manually:

```bash
# On siem-host
sudo systemctl start pg-backup.service
sudo journalctl -u pg-backup -n 50 --no-pager

# Or from local machine
make backup
```

---

## Restore

```bash
# List available backups
ls /opt/siem/backups/postgresql/

# Restore (run on siem-host as root)
sudo -u postgres pg_restore -d infisical -c \
  /opt/siem/backups/postgresql/<timestamp>_infisical.pgdump
```
