# Redis

Native Redis instance shared across services (currently Infisical).
Binds to `0.0.0.0` so Docker containers can reach it, but protected by `requirepass`.

---

## Operations

```bash
ssh <user>@<siem-host>

# Status
sudo systemctl status redis-server

# Health check
redis-cli ping   # should return PONG
```

| Item | Path |
|---|---|
| Data directory | `/opt/siem/data/redis/` |
| Logs | `/var/log/redis/redis-server.log` |

---

## Configuration

Password is set via `REDIS_PASSWORD` in `.env`. See [configuration.md](configuration.md).
