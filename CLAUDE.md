# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure scripts for Sweden Indoor Golf services running on `app.swedenindoorgolf.se`. A template-based approach to managing multiple Bun/TypeScript services behind Caddy reverse proxy on a single VPS.

**Core Philosophy:**
- Convention over configuration — folder name = service name = systemd unit = Caddy path
- Separation of structure and state — GitOps for infrastructure, direct manipulation for operations
- No manual Caddyfile editing — everything is generated
- No secrets in repo — safe to keep public

## Architecture

### Two-Tier System

1. **Server Side** (`/srv/infra` on production)
   - `server/generate.ts` — Caddyfile generator and service manager
   - `server/deploy.ts` — Deployment orchestration with maintenance mode
   - `server/services.json` — Service structure (port, stripPath) - **tracked in git**
   - `server/services-state.json` — Operational state (live/maintenance) - **server-only**

2. **Local Side** (macOS development machine)
   - `shell/functions.zsh` — Thin shell wrappers that SSH to server and invoke server scripts
   - User sources this in `~/.zshrc` to get deployment commands

### Critical Design Decisions

**Two-File Architecture:**
- `services.json` (tracked in git): Service structure (port, stripPath, description)
  - Modified via GitOps: local edit → commit → push → pull on server
  - Commands: `caddy_add`, `caddy_remove`, `service_create`
- `services-state.json` (server-only, gitignored): Operational state (live/maintenance)
  - Modified directly on server for fast operations
  - Commands: `app_maint`, `deploy.ts` (during deployments)
- `generate.ts` merges both files at runtime, defaulting to `live: true` if no state exists

**Caddyfile Generation Pattern:**
- Never edit `/srv/caddy/config/Caddyfile` directly
- All changes go through services files → `generate.ts` → Caddyfile
- Uses `cat | sudo tee` to preserve Docker bind mount inodes
- Automatically formats and reloads Caddy after generation

**Maintenance Mode:**
- Swaps Caddy block from `reverse_proxy` to static file server
- State stored in `services-state.json` only (doesn't pollute git history)
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

## Service Status Monitoring

The infrastructure includes comprehensive status checking for all services, going beyond just configuration to verify actual service health.

### Status Checks Performed

For each service, the system checks:

1. **Configuration Status** (from `services.json` + `services-state.json`)
   - Live or Maintenance mode
   - Configured port

2. **Systemd Status** (`systemctl is-active`)
   - active, inactive, failed, or unknown
   - Indicates if the service process is running
   - **Smart detection**: Tries multiple naming patterns:
     - Exact match (e.g., `golf-serie`)
     - `sig-` prefix (e.g., `sig-gsp` for service `gsp`)
     - `-server` suffix (e.g., `golf-improver-server` for service `golf-improver`)
   - Shows detected unit name in detailed view if different from service name

3. **Port Availability** (`nc -z localhost {port}`)
   - Checks if something is listening on the configured port
   - Indicates if the service started successfully

4. **HTTP Health** (`curl https://app.swedenindoorgolf.se/{service}/`)
   - Tests full request path through Caddy
   - Verifies service is responding to actual requests
   - Reports HTTP status code
   - Optional: Specify `healthCheckPath` in services.json to check a specific endpoint (e.g., "/health" or "/status")

### Status Display

**All services overview:**
```bash
caddy_list  # or: ssh server 'cd /srv/infra/server && bun status.ts'
```

Shows formatted table:
```
╔════════════════════════════════════════════════════════════════════════╗
║                          SERVICE STATUS                                ║
╠════════════════════════════════════════════════════════════════════════╣
║ SERVICE              CONFIG  SYSTEMD  PORT  HTTP                       ║
╟────────────────────────────────────────────────────────────────────────╢
║ 🟢 bookings           LIVE    ACTIVE    Port:✓ HTTP:✓ (200)            ║
║ 🟢 golf-serie         LIVE    ACTIVE    Port:✓ HTTP:✓ (200)            ║
║ 🚧 gsp                MAINT   ACTIVE    Port:✓ HTTP:✓ (503)            ║
║ 🔴 mycal              LIVE    INACTIVE  Port:✗ HTTP:✗                  ║
╚════════════════════════════════════════════════════════════════════════╝

Summary: 2 healthy, 1 maintenance, 1 issues
```

**Specific service details:**
```bash
caddy_status mycal  # or: ssh server 'cd /srv/infra/server && bun status.ts mycal'
```

Shows detailed information with diagnostic commands:
```
Service: mycal
────────────────────────────────────────────────────────────
URL:        https://app.swedenindoorgolf.se/mycal/
Port:       3005
Config:     🟢 Live
Systemd:    🔴 inactive
Port Open:  🔴 No (nc -z localhost 3005)
HTTP OK:    🔴 No

Commands:
  sudo systemctl status mycal
  sudo journalctl -u mycal -n 50
  sudo systemctl restart mycal
```

### Status Icons

- 🟢 **Green** - Service is fully healthy (live, active, port open, HTTP responding)
- 🚧 **Orange** - Service is in maintenance mode (expected state)
- 🔴 **Red** - Service has issues (live but systemd inactive, port closed, or HTTP failing)

### JSON Output

For scripting and automation:
```bash
ssh server 'cd /srv/infra/server && bun status.ts --json' | jq '.'
```

Returns structured JSON with all status information for each service.

## Database Migration Support

Services can optionally include database migration and validation in their deployment workflow. Migrations run **locally** before deployment, with automatic backup and rollback on failure.

**For service developers:** See [SERVICE-DATABASE-GUIDE.md](./SERVICE-DATABASE-GUIDE.md) for complete implementation instructions.

**For AI agents:** See [AI-AGENT-SETUP-INSTRUCTIONS.md](./AI-AGENT-SETUP-INSTRUCTIONS.md) for step-by-step procedural instructions to add migration support to a service.

### Configuration (deploy.json)

Each service can include a `deploy.json` at the repository root:

```json
{
  "database": {
    "path": "data/db.sqlite",           // Path on server (relative to /srv/{service}/)
    "migrate": "bun run db:migrate",    // Migration command (runs locally)
    "validate": "bun run db:health"     // Validation command (runs locally)
  },
  "install": "bun install",             // Optional: Auto-detected from lockfile, or manually override
  "healthCheck": "curl -f http://localhost:3000/health"  // Optional custom health check
}
```

**Key principles:**
- Migration/validation commands run in **project root** working directory on **local machine**
- Database path provided via **DB_PATH environment variable**: `DB_PATH=deploy-tmp/db.sqlite`
- Install command runs on **server** after git pull
  - **Auto-detected** from lockfile if not specified (bun.lockb → bun install, package-lock.json → npm install, etc.)
  - Can be manually overridden in deploy.json (e.g., `"install": "pnpm install --frozen-lockfile"`)
- Commands are project-specific (each service defines its own)
- Health check is optional (falls back to TCP port check if not specified)

### Enhanced Deployment Flow (with database)

```
Local                           Server
─────                           ──────
1. Check for deploy.json
2. If database config exists:
   a. Download DB to deploy-tmp/
   b. Run migration locally
   c. Run validation locally
   d. If valid:                 → Backup DB (rotate: .1→.2, current→.1)
   e. Upload migrated DB        → Receive and activate new DB
3. Optional build (if .build exists)
4. Git commit + push  ────────→
                                5. Maintenance mode ON
                                6. Git pull (as service user)
                                7. Install dependencies (if configured)
                                8. Systemctl restart
                                9. Health check (TCP or custom)
                                10. Maintenance mode OFF
                                ←────────────────── Success/Fail
                                11. If fail: rollback DB + code
12. Tail logs via journalctl
```

### Database Backup Strategy

Each deployment creates numbered backups on the server:
- `db.sqlite.backup.1` - Latest backup (from current deployment)
- `db.sqlite.backup.2` - Previous backup (from prior deployment)

Rotation happens automatically:
1. `backup.1` → `backup.2` (if exists)
2. `current` → `backup.1`
3. `uploaded` → `current`

### Local Development Workflow

Test migrations against production data locally:

```bash
cd ~/projects/my-service

db_pull                    # Download prod DB to deploy-tmp/db.sqlite
db_migrate_test            # Run migration on downloaded DB (sets DB_PATH)
db_validate_test           # Validate migration

# Manually copy deploy-tmp/db.sqlite to your dev DB location if desired
# Or point your dev server configuration at deploy-tmp/
```

### Example Service Setup

**1. Create deploy.json:**
```json
{
  "database": {
    "path": "data/db.sqlite",
    "migrate": "bun run db:migrate",
    "validate": "bun run db:health"
  },
  "healthCheck": "curl -f http://localhost:3000/health"
}
```

**2. Add migration script to package.json:**
```json
{
  "scripts": {
    "db:migrate": "bun ./scripts/migrate.ts",
    "db:health": "bun ./scripts/health.ts"
  }
}
```

**3. Create migration script (scripts/migrate.ts):**
```typescript
// Reads DB_PATH environment variable
const dbPath = process.env.DB_PATH || "data/db.sqlite";
const db = new Database(dbPath);

// Run your migrations
db.run("ALTER TABLE users ADD COLUMN email TEXT");
console.log("Migration completed");
```

**4. Create validation script (scripts/health.ts):**
```typescript
const dbPath = process.env.DB_PATH || "data/db.sqlite";
const db = new Database(dbPath);

// Verify schema
const result = db.query("PRAGMA table_info(users)").all();
const hasEmail = result.some(col => col.name === "email");

if (!hasEmail) {
  console.error("Validation failed: email column missing");
  process.exit(1);
}

console.log("Validation passed");
```

**5. Update .gitignore:**
```
deploy-tmp/
*.local-backup
```

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

**Service Status:**
```bash
caddy_list                  # Comprehensive status of all services
                            # Shows: config, systemd, port, HTTP health
caddy_status my-service     # Detailed status of specific service
                            # Includes diagnostic commands
```

**Service Management (GitOps - modifies local, commits, pushes):**
```bash
caddy_add my-api 3007       # Add new service to routing (GitOps)
caddy_remove my-api         # Remove service from Caddy (GitOps)
caddy_view                  # View generated Caddyfile
caddy_regen --dry-run       # Preview regeneration
```

**Advanced Service Configuration:**
To customize HTTP health checks, edit `server/services.json` directly:
```json
{
  "my-service": {
    "port": 3007,
    "stripPath": false,
    "description": "My Service Description",
    "healthCheckPath": "/health"
  }
}
```
Then commit and push changes (GitOps workflow).

**Deployment:**
```bash
deploy                      # Full deploy from current directory
deploy_status [service]     # Check service status
deploy_rollback [service]   # Revert to previous commit
```

**Database Development (requires deploy.json):**
```bash
db_pull [service]           # Download production database for local testing
db_migrate_test             # Run migration on downloaded DB (sets DB_PATH env)
db_validate_test            # Run validation on migrated DB (sets DB_PATH env)
```

**Maintenance (Direct server manipulation):**
```bash
app_maint                   # Interactive service picker (uses fzf)
app_maint golf-serie        # Toggle specific service (fast, no git commit)
app_maint --dry-run my-api  # Preview toggle
```

**Infrastructure:**
```bash
infra_push "message"        # Commit, push, and update server
infra_pull                  # Update local from remote
infra_pull_remote           # Update server from remote (useful after manual push)
infra_status                # Compare local vs server
```

### On Server (manual operations)

```bash
cd /srv/infra/server

# Service status
bun status.ts                # Comprehensive status of all services
bun status.ts my-service     # Detailed status of specific service
bun status.ts --json         # JSON output for scripting

# Service management
bun generate.ts list         # Simple config list (legacy)
bun generate.ts add my-service 3008
bun generate.ts maint my-service

# Deployment (usually triggered from local)
bun deploy.ts my-service
bun deploy.ts my-service --status
bun deploy.ts my-service --rollback
bun deploy.ts my-service --health-check 'curl -f http://localhost:3000/health'
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
│   ├── status.ts                   # Service status checker (systemd, port, HTTP)
│   ├── generate.ts                 # Caddyfile generator (add/remove/maint/list)
│   ├── deploy.ts                   # Server-side deployment orchestrator
│   ├── services.json               # Service structure (tracked in git)
│   ├── services-state.json.example # Template for operational state
│   └── .bashrc                     # Reference copy of server bashrc (rfu/rbu helpers)
├── shell/
│   └── functions.zsh               # Local shell wrappers (SSH to server)
├── deploy.json.example             # Template for service deployment config
├── CLAUDE.md                       # Infrastructure documentation (this file)
├── SERVICE-DATABASE-GUIDE.md       # Guide for service developers
└── AI-AGENT-SETUP-INSTRUCTIONS.md  # Step-by-step instructions for AI agents
```

### Server Environment

```
/srv/
├── infra/                          # This repo
│   └── server/
│       ├── services.json           # Service structure (pulled from git)
│       └── services-state.json     # Operational state (server-only, gitignored)
├── caddy/config/
│   └── Caddyfile                   # Generated, never edit directly
└── {service-name}/                 # Individual service repos (e.g., golf-serie/, gsp/)
    ├── .git/
    └── src/
```

Each service runs as:
- Systemd unit: `{service-name}.service`
- User: `{service-name}`
- Directory: `/srv/{service-name}`
- Accessible at: `https://app.swedenindoorgolf.se/{service-name}/*`

## Key Implementation Details

### Two-File Schema

**services.json** (structure - tracked in git):
```typescript
interface ServiceStructure {
  port: number;            // Port service listens on
  stripPath?: boolean;     // default true (use handle_path), false = handle
  description?: string;    // Optional description for systemd
  healthCheckPath?: string;// Optional path for HTTP health checks (e.g., "/health")
}
```

**services-state.json** (operational state - server-only):
```typescript
interface ServiceState {
  live: boolean;         // false = maintenance mode
}
```

**Merged at runtime** (by generate.ts and deploy.ts):
```typescript
interface ServiceConfig extends ServiceStructure {
  live: boolean;         // Defaults to true if not in state file
}
```

### Merge Logic

Both scripts load and merge the files:
```typescript
const structure = await loadServicesStructure();  // from services.json
const state = await loadServicesState();           // from services-state.json (or {} if missing)
const merged = { ...structure[name], live: state[name]?.live ?? true };
```

### generate.ts Modes

1. **generate** (default) — Merge files, generate Caddyfile, reload
2. **list** — Show all services with merged status
3. **add** — Add to services.json only (GitOps when called from shell)
4. **remove** — Remove from services.json and clean up state
5. **maint** — Toggle in services-state.json only (fast)

### deploy.ts Modes

1. **deploy** (default) — Full deployment with health checks, toggles state file
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
- Service names must match: directory name = systemd unit = JSON key = Caddy path
- **Bootstrapping state file:** On a new server, `services-state.json` doesn't exist initially. Scripts default all services to `live: true`. Create it from the example: `cp server/services-state.json.example server/services-state.json`
- **GitOps workflow:** `caddy_add`/`caddy_remove` modify local files and commit. Maintenance toggles (`app_maint`, `deploy.ts`) modify server state directly for speed.
