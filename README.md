# Ninstall

Public install scripts for NodeNook home lab management.

## Scripts

### bootstrap.sh

Sets up the **first node** of a NodeNook Docker Swarm cluster.

```bash
curl -sSL https://raw.githubusercontent.com/dcherrera/Ninstall/main/bootstrap.sh | bash
```

**What it does:**
- Installs Docker
- Sets hostname
- Initializes Docker Swarm
- Deploys Traefik (reverse proxy)
- Deploys Prometheus + Node Exporter (monitoring)
- Generates SSH keys for dashboard access
- Saves config to `/opt/nodenook/config/`

### setup.sh (coming soon)

Joins additional nodes to an existing swarm using secure pairing codes.

## License

[MIT Transparency License](LICENSE)
