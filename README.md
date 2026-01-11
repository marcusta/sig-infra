# sig-infra

Infrastructure scripts for Sweden Indoor Golf services running on `app.swedenindoorgolf.se`.

A simple, template-based approach to managing multiple Bun/TypeScript services behind Caddy on a single VPS.

## Documentation

### For Infrastructure Operators
- **[CLAUDE.md](./CLAUDE.md)** - Complete infrastructure documentation with architecture details and command reference

### For Service Developers
- **[SERVICE-DATABASE-GUIDE.md](./SERVICE-DATABASE-GUIDE.md)** - Guide for adding database migration support to your service (optional)

### For AI Agents
- **[AI-AGENT-SETUP-INSTRUCTIONS.md](./AI-AGENT-SETUP-INSTRUCTIONS.md)** - Step-by-step procedural instructions for setting up migrations

### Templates
- **[deploy.json.example](./deploy.json.example)** - Service deployment configuration template

## Philosophy

- **Convention over configuration** — folder name = service name = systemd unit = Caddy path
- **Single source of truth** — `services.json` defines all routing, no manual Caddyfile editing
- **Simple tooling** — Bun scripts on server, thin shell wrappers locally
- **No secrets in repo** — safe to keep public

## Setup

### Server (`app.swedenindoorgolf.se`)

```bash
cd /srv
sudo git clone https://github.com/marcusta/sig-infra.git infra
sudo chown -R marcus:marcus infra
```

### Local (Mac)

```bash
cd ~/dev/github
git clone https://github.com/marcusta/sig-infra.git
```

Add to `~/.zshrc`:

```bash
# Sweden Indoor Golf infrastructure
source ~/dev/github/sig-infra/shell/functions.zsh
```

## Usage

### Service Management

```bash
caddy_list                  # List all services and status
caddy_add my-api 3007       # Add new service
caddy_remove my-api         # Remove service
caddy_view                  # View generated Caddyfile
caddy_regen --dry-run       # Preview Caddyfile regeneration
```

### Maintenance Mode

```bash
app_maint                   # Interactive - pick from list
app_maint golf-serie        # Toggle specific service
app_maint --dry-run golf-serie  # Preview
```

### Deployment

From a service directory locally:

```bash
deploy                      # Build → push → deploy → tail logs
deploy_status               # Check service status
deploy_rollback             # Revert to previous commit
```

### Database Development (Optional)

Services can optionally enable database migrations:

```bash
db_pull                     # Download production database
db_migrate_test             # Test migration locally
db_validate_test            # Validate migration
```

See [SERVICE-DATABASE-GUIDE.md](./SERVICE-DATABASE-GUIDE.md) for setup instructions.

### Updating Infrastructure Scripts

```bash
infra_push "added rollback feature"  # Push changes and update server
infra_pull                           # Update local from remote
```

## File Structure

```
sig-infra/
├── README.md
├── CLAUDE.md                          # Infrastructure documentation
├── SERVICE-DATABASE-GUIDE.md          # Guide for service developers
├── AI-AGENT-SETUP-INSTRUCTIONS.md     # Instructions for AI agents
├── deploy.json.example                # Service config template
├── .gitignore
├── server/
│   ├── generate.ts                    # Caddyfile generator
│   ├── deploy.ts                      # Deployment orchestration
│   └── services.json                  # Service registry (source of truth)
└── shell/
    └── functions.zsh                  # Local shell functions (sourced by .zshrc)
```

### On Server

```
/srv/
├── infra/                  # This repo
│   ├── server/
│   │   ├── generate.ts
│   │   ├── deploy.ts
│   │   └── services.json
│   └── ...
├── caddy/
│   └── config/
│       └── Caddyfile       # Generated output (don't edit)
├── golf-serie/             # Service repos
├── gsp/
└── ...
```

## Adding a New Service

1. Create the service on the server:

   ```bash
   cd /srv
   sudo create_and_clone_repo  # Interactive setup
   ```

2. Add to Caddy:

   ```bash
   caddy_add my-service 3008
   ```

3. Deploy:
   ```bash
   cd ~/projects/my-service
   deploy
   ```

## How It Works

### Caddyfile Generation

Instead of editing Caddyfile directly (error-prone), we:

1. Define services in `services.json`:

   ```json
   {
     "golf-serie": { "port": 3010, "live": true },
     "gsp": { "port": 3000, "live": true }
   }
   ```

2. Run `generate.ts` which outputs a valid Caddyfile

3. Caddy reloads automatically

### Maintenance Mode

Toggling maintenance swaps the Caddy block from `reverse_proxy` to serving a static maintenance page. The port is preserved in the config so restoration is automatic.

### Deployment Flow

**Standard deployment:**
```
Local                           Server
─────                           ──────
1. Build (optional)
2. Git commit
3. Git push ──────────────────→
                                4. Maintenance ON
                                5. Git pull
                                6. Systemctl restart
                                7. Health check (wait for port)
                                8. Maintenance OFF
                                ←────────────────── Success/Fail
9. Tail logs
```

**With database migration** (optional):
```
Local                           Server
─────                           ──────
1. Download DB
2. Migrate locally
3. Validate
4. Upload DB ─────────────────→ Backup & activate
5. Build (optional)
6. Git push ──────────────────→
                                7. Maintenance ON
                                8. Git pull
                                9. Systemctl restart
                                10. Health check
                                11. Rollback if failed
                                12. Maintenance OFF
13. Tail logs
```

## Requirements

- **Server**: Ubuntu with Bun, Docker (for Caddy), systemd
- **Local**: macOS with zsh, Bun (optional, for local dev), jq, fzf

## License

MIT — use it, fork it, adapt it for your own VPS setup.
