# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure scripts for Sweden Indoor Golf services running on `app.swedenindoorgolf.se`. A template-based approach to managing multiple Bun/TypeScript services behind Caddy reverse proxy on a single VPS.

**Core Philosophy:**
- Convention over configuration — folder name = service name = systemd unit = Caddy path
- Single source of truth — `server/services.json` defines all routing
- No manual Caddyfile editing — everything is generated
- No secrets in repo — safe to keep public

## Architecture

### Two-Tier System

1. **Server Side** (`/srv/infra` on production)
   - `server/generate.ts` — Caddyfile generator and service manager
   - `server/deploy.ts` — Deployment orchestration with maintenance mode
   - `server/services.json` — Service registry (source of truth for all routing)

2. **Local Side** (macOS development machine)
   - `shell/functions.zsh` — Thin shell wrappers that SSH to server and invoke server scripts
   - User sources this in `~/.zshrc` to get deployment commands

### Critical Design Decisions

**Caddyfile Generation Pattern:**
- Never edit `/srv/caddy/config/Caddyfile` directly
- All changes go through `services.json` → `generate.ts` → Caddyfile
- Uses `cat | sudo tee` to preserve Docker bind mount inodes
- Automatically formats and reloads Caddy after generation

**Maintenance Mode:**
- Swaps Caddy block from `reverse_proxy` to static file server
- Port number preserved in JSON comment during maintenance (e.g., `# live_port:3010`)
- Enables zero-downtime deploys with automatic rollback on failure

**Path Handling:**
- `stripPath: true` (default) → uses `handle_path` (strips `/service` before proxying)
- `stripPath: false` → uses `handle` (preserves full path)
- Example: `sig-web3` needs full path for routing, so `stripPath: false`

### Deployment Flow

```
Local                           Server
─────                           ──────
1. Optional build (if .build exists)
2. Git commit + push  ────────→
                                3. Maintenance mode ON
                                4. Git pull (as service user)
                                5. Systemctl restart
                                6. Health check (nc -z on port)
                                7. Maintenance mode OFF
                                ←────────────────── Success/Fail
8. Tail logs via journalctl
```

If deployment fails, service stays in maintenance mode until manually fixed.

## Common Commands

### Development & Testing

```bash
# Test Caddyfile generation locally (server-side)
bun server/generate.ts --dry-run
bun server/generate.ts list

# Test maintenance mode toggle
bun server/generate.ts maint my-service --dry-run
```

### Local Shell Functions (via `shell/functions.zsh`)

**Service Setup:**
```bash
service_create              # Interactive wizard to create new service
                            # - Creates system user
                            # - Clones GitHub repo
                            # - Sets up systemd service
                            # - Adds to Caddy routing
```

**Service Management:**
```bash
caddy_list                  # List all services and status
caddy_add my-api 3007       # Add new service to routing
caddy_remove my-api         # Remove service from Caddy
caddy_view                  # View generated Caddyfile
caddy_regen --dry-run       # Preview regeneration
```

**Deployment:**
```bash
deploy                      # Full deploy from current directory
deploy_status [service]     # Check service status
deploy_rollback [service]   # Revert to previous commit
```

**Maintenance:**
```bash
app_maint                   # Interactive service picker (uses fzf)
app_maint golf-serie        # Toggle specific service
app_maint --dry-run my-api  # Preview toggle
```

**Infrastructure:**
```bash
infra_push "message"        # Commit, push, and update server
infra_pull                  # Update local from remote
infra_status                # Compare local vs server
```

### On Server (manual operations)

```bash
cd /srv/infra/server

# Service management
bun generate.ts list
bun generate.ts add my-service 3008
bun generate.ts maint my-service

# Deployment (usually triggered from local)
bun deploy.ts my-service
bun deploy.ts my-service --status
bun deploy.ts my-service --rollback
```

**Server-side convenience functions** (in `server/.bashrc` for reference):
```bash
rfu <command>               # Run command as folder user (e.g., cd /srv/golf-serie && rfu git status)
rbu <script>                # Run bun command as folder user (e.g., cd /srv/golf-serie && rbu dev)
```
These are useful for manual debugging/operations on the server.

## File Structure

```
sig-infra/
├── server/
│   ├── generate.ts       # Caddyfile generator (add/remove/maint/list)
│   ├── deploy.ts         # Server-side deployment orchestrator
│   ├── services.json     # Source of truth for all routing
│   └── .bashrc           # Reference copy of server bashrc (rfu/rbu helpers)
└── shell/
    └── functions.zsh     # Local shell wrappers (SSH to server)
```

### Server Environment

```
/srv/
├── infra/                # This repo
├── caddy/config/
│   └── Caddyfile         # Generated, never edit directly
└── {service-name}/       # Individual service repos (e.g., golf-serie/, gsp/)
    ├── .git/
    └── src/
```

Each service runs as:
- Systemd unit: `{service-name}.service`
- User: `{service-name}`
- Directory: `/srv/{service-name}`
- Accessible at: `https://app.swedenindoorgolf.se/{service-name}/*`

## Key Implementation Details

### services.json Schema

```typescript
interface ServiceConfig {
  port: number;          // Port service listens on
  live: boolean;         // false = maintenance mode
  description?: string;  // Optional description
  stripPath?: boolean;   // default true (use handle_path), false = handle
}
```

### generate.ts Modes

1. **generate** (default) — Generate Caddyfile and reload
2. **list** — Show all services with status
3. **add** — Add new service (validates port conflicts)
4. **remove** — Remove service from config
5. **maint** — Toggle maintenance mode

### deploy.ts Modes

1. **deploy** (default) — Full deployment with health checks
2. **--status** — Check service status (systemd + Caddy)
3. **--rollback** — Git reset to HEAD~1 and redeploy

### Health Checks

- Uses `nc -z localhost {port}` for TCP check
- Retries 10 times with 1s delay
- If unhealthy, deployment fails and service stays in maintenance

## Adding a New Service

### Automated (Recommended)

Use the interactive setup wizard:

```bash
service_create
```

This will prompt for:
- Service name (defaults to current directory)
- GitHub repository name (defaults to service name)
- Service description (for systemd)
- Start command (defaults to `/usr/local/bin/bun ./src/server.ts`)
- Port number (required)

It then automatically:
1. Creates system user on server
2. Clones the GitHub repository to `/srv/{service-name}`
3. Sets up systemd service file and enables it
4. Adds the service to Caddy routing

### Manual

If you need more control or already have parts set up:

1. Create service directory and systemd unit on server
2. Add to Caddy: `caddy_add my-service 3008`
3. From local service directory: `deploy`

## Rollback Procedure

If a deployment fails:

```bash
# Automatic (recommended)
deploy_rollback my-service

# Manual
ssh marcus@app.swedenindoorgolf.se
cd /srv/my-service
sudo -u my-service git reset --hard HEAD~1
sudo systemctl restart my-service
cd /srv/infra/server && bun generate.ts maint my-service  # toggle off maintenance
```

## Requirements

- **Server:** Ubuntu, Bun, Docker (Caddy container), systemd
- **Local:** macOS, zsh, Bun (optional), jq, fzf

## Important Notes

- All server scripts run via `bun` (not `node`)
- Shell functions use SSH with `$SIG_SERVER` variable
- Maintenance mode preserves port configuration for easy restoration
- Service names must match: directory name = systemd unit = JSON key = Caddy path
