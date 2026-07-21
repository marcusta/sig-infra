# Database Migration Guide for Services

This guide is for developers of individual services (e.g., `golf-serie`, `bookings`, etc.) who want to enable safe database migrations during deployment.

## Overview

The deployment system supports **optional** database migration with:
- **Server-side migration execution** — migrations run on the server, as the service user, against a snapshot of the live database (never against the live file directly)
- Automatic backup rotation and auto-recovery on failure
- WAL-safe snapshot/swap/restore operations (via `server/db-tool.ts`)
- Local rehearsal against production data (`db_pull` / `db_migrate_test` / `db_validate_test`)
- Custom health checks after deployment

**This is completely optional** — services without database configuration deploy normally.

**Why server-side?** SQLite in WAL mode is *three* files (`db.sqlite`, `-wal`, `-shm`). Downloading/uploading only the main file while sidecars exist corrupts the database — SQLite replays the stale WAL over the new file on boot. The server-side workflow stops the service first, snapshots with `VACUUM INTO` (which folds the WAL into one consistent file), migrates the snapshot, and always removes sidecars when swapping files. The live database is only ever replaced by a file that has already migrated and validated.

## Quick Start

To enable database migration support for your service:

1. Create `deploy.json` in your repository root
2. Add migration and validation scripts
3. Validate the setup with `deploy_preflight`
4. Rehearse locally with `db_pull` and `db_migrate_test`
5. Deploy with `deploy --db` — the migration runs on the server automatically

## Configuration File (deploy.json)

Create `deploy.json` in your service repository root:

```json
{
  "serviceName": "bookings",
  "serverFolder": "sig-booking",
  "database": {
    "path": "data/db.sqlite",
    "migrate": "bun run db:migrate",
    "validate": "bun run db:health",
    "migrationsDir": "drizzle"
  },
  "install": "bun install",
  "healthCheck": "curl -f http://localhost:3000/health"
}
```

**Note:** The server reads `deploy.json` *after* `git pull` — so your migration commands always ship together with the code that needs them.

### Configuration Fields

#### `serviceName` (optional)
- Overrides the service name used for `services.json` lookup and systemd unit
- Defaults to the local folder name (e.g., `basename $PWD`)
- Does **not** affect `serverFolder` — they are independent
- Only needed when the local folder name doesn't match the services.json key

#### `serverFolder` (optional)
- Overrides the directory name under `/srv/` on the server
- Defaults to the local folder name (NOT `serviceName`)
- Only needed when the server folder differs from the local folder name
- Example: local folder `sig-booking`, services.json key `bookings` → only need `"serviceName": "bookings"`, no `serverFolder` needed

#### `database.path` (required if using database)
- Relative path from `/srv/{serverFolder}/` on the server
- Example: `"data/db.sqlite"` → `/srv/sig-booking/data/db.sqlite`
- This is where your production database lives on the server

#### `database.migrate` (required if using database)
- Shell command to run migration
- Executed **on the server**, as the **service user**, with cwd `/srv/{serverFolder}`
- Runs against a snapshot — the `DB_PATH` environment variable points at the snapshot file, never the live database
- Example: `"bun run db:migrate"` or `"npm run migrate"`

#### `database.validate` (required if using database)
- Shell command to validate migration succeeded
- Executed **on the server**, as the **service user**, with cwd `/srv/{serverFolder}`
- Runs against the migrated snapshot (`DB_PATH` points at it)
- Must exit with code 0 for success, non-zero for failure
- Example: `"bun run db:health"` or `"npm run db:validate"`

#### `database.migrationsDir` (optional)
- Path to your migration files (e.g., `"drizzle"`, `"migrations"`)
- Enables `deploy_check` and `deploy --auto` to detect whether the next deploy needs a migration (by diffing this directory against the commit currently deployed on the server)
- Without it, you must choose `deploy --db` / `deploy --no-db` yourself

#### `install` (optional)
- Command to install dependencies on the server after `git pull`
- Auto-detected from lockfile if omitted (`bun.lockb`/`bun.lock` → `bun install`, `package-lock.json` → `npm install`, etc.)
- Only specify to override auto-detection (e.g., `"pnpm install --frozen-lockfile"`)

#### `healthCheck` (optional)
- Custom health check command to run on the server after deployment
- Executed on the **server** after service restart
- Must exit with code 0 for success, non-zero for failure
- Example: `"curl -f http://localhost:3000/health"`
- If omitted, uses TCP port check (`nc -z localhost {port}`)

## Implementation Steps

### Step 1: Add Scripts to package.json

```json
{
  "scripts": {
    "db:migrate": "bun ./scripts/migrate.ts",
    "db:health": "bun ./scripts/health.ts"
  }
}
```

### Step 2: Create Migration Script

Create `scripts/migrate.ts` (or `.js`):

```typescript
import { Database } from "bun:sqlite";

// Read database path from environment variable.
// During deploys the server sets DB_PATH to the snapshot file;
// during local rehearsal (db_migrate_test) it points at deploy-tmp/db.sqlite.
const dbPath = process.env.DB_PATH || "data/db.sqlite";
const db = new Database(dbPath);

console.log(`Running migrations on ${dbPath}...`);

try {
  // Example: Add a column
  db.run(`
    ALTER TABLE users
    ADD COLUMN email TEXT
  `);

  // Example: Create a table
  db.run(`
    CREATE TABLE IF NOT EXISTS sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      token TEXT NOT NULL,
      created_at INTEGER DEFAULT (unixepoch())
    )
  `);

  console.log("✅ Migrations completed successfully");
  db.close();
  process.exit(0);
} catch (error) {
  console.error("❌ Migration failed:", error);
  db.close();
  process.exit(1);
}
```

**Key points:**
- Read `DB_PATH` from environment — the deploy sets it to the snapshot on the server; `db_migrate_test` sets it to `deploy-tmp/db.sqlite` locally
- Fall back to your normal dev DB path if not set
- Exit with code 0 on success, non-zero on failure
- Use idempotent operations (`IF NOT EXISTS`, etc.) when possible — the same migration runs once in rehearsal and once for real on the server

### Step 3: Create Validation Script

Create `scripts/health.ts` (or `.js`):

```typescript
import { Database } from "bun:sqlite";

// Read database path from environment variable
const dbPath = process.env.DB_PATH || "data/db.sqlite";
const db = new Database(dbPath);

console.log(`Validating database schema at ${dbPath}...`);

try {
  // Check that expected tables exist
  const tables = db.query(
    "SELECT name FROM sqlite_master WHERE type='table'"
  ).all();

  const tableNames = tables.map(t => t.name);
  const requiredTables = ["users", "sessions"];

  for (const table of requiredTables) {
    if (!tableNames.includes(table)) {
      throw new Error(`Missing required table: ${table}`);
    }
  }

  // Check specific columns exist
  const userColumns = db.query("PRAGMA table_info(users)").all();
  const hasEmail = userColumns.some(col => col.name === "email");

  if (!hasEmail) {
    throw new Error("Missing email column in users table");
  }

  console.log("✅ Database validation passed");
  db.close();
  process.exit(0);
} catch (error) {
  console.error("❌ Validation failed:", error);
  db.close();
  process.exit(1);
}
```

**Key points:**
- Verify your schema is in the expected state
- Check tables, columns, indexes exist
- Exit with code 0 on success, non-zero on failure
- Be thorough — on the server, this is the last gate before the migrated snapshot replaces the live database

### Step 4: Add Health Check Endpoint (Optional)

If you want a custom health check, add an endpoint to your service:

```typescript
// In your server setup
app.get("/health", (req, res) => {
  try {
    // Check database connectivity
    const result = db.query("SELECT 1").get();

    // Check any other critical services
    // ...

    res.status(200).json({ status: "healthy" });
  } catch (error) {
    res.status(500).json({ status: "unhealthy", error: error.message });
  }
});
```

Update your `deploy.json`:
```json
{
  "healthCheck": "curl -f http://localhost:3000/health"
}
```

### Step 5: Update .gitignore

Add to your service's `.gitignore`:

```gitignore
# Deployment artifacts
deploy-tmp/
*.local-backup
```

(`deploy-tmp/` is only used for local rehearsal — it never gets deployed.)

## Deployment Workflow

Deploy requires an explicit mode:

```bash
deploy --db      # Full deploy WITH server-side database migration
deploy --no-db   # Code-only deploy, skips the database workflow
deploy --auto    # Detect: --db if migration files changed, else --no-db
                 # (needs "database.migrationsDir" in deploy.json)
```

Run `deploy_check` first if you're unsure whether the next deploy needs `--db`.

### With `--db` (database migration):

1. **Local:**
   - Optional build (if `.build` exists)
   - Git commit and push

2. **Server** (`deploy.ts <service> --db`):
   - Records the currently deployed commit (recovery target)
   - Enables maintenance mode
   - `git pull` (as service user)
   - Reads `deploy.json` (from the freshly pulled code)
   - Installs dependencies (from `install` or lockfile auto-detection)
   - **Stops the service** — nothing may write to the DB during the window
   - Snapshots the database: `VACUUM INTO {db}.migrating` (folds WAL into one consistent file)
   - Runs your migrate command with `DB_PATH={db}.migrating`
   - Runs your validate command with `DB_PATH={db}.migrating`
   - Rotates backups: `backup.1` → `backup.2`, `VACUUM INTO` current → `backup.1`
   - Swaps: `mv {db}.migrating` → `{db}` **and removes `-wal`/`-shm` sidecars in the same step**
   - Runs an integrity check on the file in its final location
   - Starts the service
   - Health check (custom command or TCP port)
   - Disables maintenance mode

3. **On failure — auto-recovery:**
   - Git reset to the recorded commit, reinstall dependencies
   - Database restored from `backup.1` **only if it was already swapped** (if migration/validation failed, the live DB was never touched)
   - Service restarted, maintenance lifted if healthy
   - If recovery itself fails, the service stays in maintenance mode

4. **Local:** Tails logs via journalctl

### With `--no-db` (code only):

1. Optional local build, git commit and push
2. Server: maintenance on → git pull → install deps → restart → health check → maintenance off (with the same auto-recovery on failure)
3. Tail logs

## Preflight Validation

Before deploying or testing migrations, validate your setup:

```bash
cd ~/projects/your-service

deploy_preflight
```

This verifies:
- `deploy.json` is valid with required fields
- Migration/validation scripts exist and reference the `DB_PATH` env var
- `package.json` has the required scripts
- Remote service, database, and systemd unit exist
- `.gitignore` includes `deploy-tmp/`

**Run this first** when setting up migration support for a new service. It catches common issues like missing scripts, wrong paths, or scripts that ignore the `DB_PATH` environment variable.

## Local Rehearsal

After preflight passes, rehearse your migration against production data. **This is a rehearsal only** — the deploy re-runs the same migration on the server; nothing from `deploy-tmp/` is ever uploaded.

```bash
cd ~/projects/your-service

# Snapshot prod DB on the server (VACUUM INTO), download to deploy-tmp/db.sqlite
db_pull

# Run migration on the downloaded DB (sets DB_PATH=deploy-tmp/db.sqlite)
db_migrate_test

# Validate migration
db_validate_test

# Inspect the migrated database if needed
sqlite3 deploy-tmp/db.sqlite
```

**Important:** Check the migration output path. It should show `deploy-tmp/db.sqlite`, not your fallback path. If it shows the fallback (e.g., `data/db.sqlite`), your script is not reading `DB_PATH` correctly — and on the server the deploy would migrate the wrong file.

This lets you:
- Test migrations against real production data structure
- Verify schema changes work correctly
- Confirm `DB_PATH` is being read correctly
- Catch issues before deploying

## Backup and Recovery

### Automatic Backups

Each `--db` deployment creates numbered backups on the server:
- `db.sqlite.backup.1` — Latest backup (from current deployment)
- `db.sqlite.backup.2` — Previous backup (from prior deployment)

Rotation happens automatically **with the service stopped**, using `VACUUM INTO` — so each backup is a single consistent file with the WAL folded in.

### Automatic Recovery

If a `--db` deployment fails, the server auto-recovers:

- **Migration or validation failed** → the live DB was never touched. Code is reset to the pre-deploy commit and the service restarts on the old version. The failed snapshot is kept at `{db}.migrating` for debugging.
- **Health check failed after the swap** → code is reset AND the database is restored from `backup.1` (with `-wal`/`-shm` sidecars cleared).
- **Recovery itself failed** → the service stays in maintenance mode; fix manually or run `deploy_rollback`.

### Manual Rollback

If auto-recovery failed, or you need to revert a successful deploy:

```bash
deploy_rollback your-service          # code only (git reset HEAD~1, restart)
deploy_rollback your-service --db     # code + restore database from backup.1
```

The `--db` variant restores `backup.1` and clears the `-wal`/`-shm` sidecars in the same step.

Fully manual (on the server):

```bash
ssh marcus@app.swedenindoorgolf.se
sudo systemctl stop your-service                    # stop BEFORE touching code or DB
cd /srv/your-service
sudo -u your-service git reset --hard HEAD~1
# If the DB needs restoring (never restore next to stale sidecars):
sudo -u your-service cp data/db.sqlite.backup.1 data/db.sqlite
sudo -u your-service rm -f data/db.sqlite-wal data/db.sqlite-shm
sudo systemctl restart your-service
cd /srv/infra/server && bun generate.ts maint your-service  # toggle off maintenance
```

## Troubleshooting

### Migration fails in local rehearsal

Check:
- Is `DB_PATH` being read correctly in your script?
- Does the migration work with your dev database?
- Are you using idempotent operations?
- Run `DB_PATH=deploy-tmp/db.sqlite bun run db:migrate` manually

### Migration or validation fails during deploy

The live database was **not** touched — the failure happened on the snapshot. The service is back on the previous code version (auto-recovery).

Check:
- The deploy output shows the exact command and `DB_PATH` used
- Inspect the failed snapshot on the server: `ssh server 'sudo -u your-service sqlite3 /srv/your-service/data/db.sqlite.migrating ".schema"'`
- Did the rehearsal (`db_pull && db_migrate_test`) pass? If prod data changed since, pull again

### Health check fails after deployment

Check:
- Is your service actually starting? `ssh server 'sudo journalctl -u your-service -n 50'`
- Is the health check command correct?
- Can you curl the endpoint manually?
- Try deploying without custom health check first (remove from deploy.json)

Note: if this happens on a `--db` deploy, auto-recovery already restored `backup.1` — the data written between swap and failed health check (there shouldn't be any, the service just started) is gone with the snapshot.

### Database not found

Check:
- Is `database.path` in deploy.json correct?
- Does the file exist on the server? `ssh server 'ls -la /srv/your-service/data/'`

### Service stuck in maintenance mode

Auto-recovery failed. Diagnose on the server:

```bash
ssh server 'sudo systemctl status your-service'
ssh server 'sudo journalctl -u your-service -n 50'
deploy_rollback your-service --db
```

## Best Practices

### 1. Make Migrations Idempotent

Use `IF NOT EXISTS`, `IF NOT NULL`, etc.:

```typescript
// Good
db.run("CREATE TABLE IF NOT EXISTS sessions (...)");
db.run("ALTER TABLE users ADD COLUMN email TEXT"); // fails if exists

// Better - check first
const columns = db.query("PRAGMA table_info(users)").all();
if (!columns.some(c => c.name === "email")) {
  db.run("ALTER TABLE users ADD COLUMN email TEXT");
}
```

This matters doubly here: the migration runs once in rehearsal and once for real on the server.

### 2. Rehearse Against Production Data

Always use `db_pull` and test locally before deploying:

```bash
db_pull && db_migrate_test && db_validate_test
```

### 3. Keep Validation Comprehensive

Don't just check that migration didn't crash — verify the schema is correct. On the server, validation is the last gate before the snapshot replaces the live database:

```typescript
// Not enough
db.query("SELECT 1").get();

// Better
const tables = db.query("SELECT name FROM sqlite_master WHERE type='table'").all();
const hasNewTable = tables.some(t => t.name === "sessions");
if (!hasNewTable) throw new Error("sessions table missing");
```

### 4. Set `migrationsDir` and Use `deploy --auto`

With `"migrationsDir"` in your database block, `deploy_check` and `deploy --auto` can tell whether the next deploy actually needs the database workflow — avoiding both unnecessary DB windows and forgotten migrations.

### 5. Deployment Strategy for Schema Changes

For complex migrations:
1. Deploy backward-compatible code first (works with old schema)
2. Deploy database migration (updates schema)
3. Deploy new code that uses new schema

For simple additions (new columns, tables), you can deploy together.

### 6. Monitor Deployments

After deploying, watch the logs:
- Service starts correctly
- Database connections work
- No migration-related errors

## Examples

### Example 1: Simple Column Addition

**deploy.json:**
```json
{
  "database": {
    "path": "data/db.sqlite",
    "migrate": "bun run db:migrate",
    "validate": "bun run db:health"
  }
}
```

**scripts/migrate.ts:**
```typescript
import { Database } from "bun:sqlite";

const dbPath = process.env.DB_PATH || "data/db.sqlite";
const db = new Database(dbPath);

const columns = db.query("PRAGMA table_info(users)").all();
if (!columns.some(c => c.name === "last_login")) {
  db.run("ALTER TABLE users ADD COLUMN last_login INTEGER");
  console.log("✅ Added last_login column");
} else {
  console.log("ℹ️  last_login column already exists");
}

db.close();
```

**scripts/health.ts:**
```typescript
import { Database } from "bun:sqlite";

const dbPath = process.env.DB_PATH || "data/db.sqlite";
const db = new Database(dbPath);

const columns = db.query("PRAGMA table_info(users)").all();
if (!columns.some(c => c.name === "last_login")) {
  throw new Error("last_login column missing");
}

console.log("✅ Validation passed");
db.close();
```

### Example 2: Complex Migration with Data Transform

**scripts/migrate.ts:**
```typescript
import { Database } from "bun:sqlite";

const dbPath = process.env.DB_PATH || "data/db.sqlite";
const db = new Database(dbPath);

// Add new table
db.run(`
  CREATE TABLE IF NOT EXISTS user_preferences (
    user_id INTEGER PRIMARY KEY,
    theme TEXT DEFAULT 'light',
    notifications INTEGER DEFAULT 1
  )
`);

// Migrate existing data
const users = db.query("SELECT id FROM users").all();
for (const user of users) {
  db.run(
    "INSERT OR IGNORE INTO user_preferences (user_id) VALUES (?)",
    [user.id]
  );
}

console.log(`✅ Migrated ${users.length} users`);
db.close();
```

## Migration Checklist

Before deploying a service with database changes:

- [ ] Created `deploy.json` with correct paths
- [ ] Migration script reads `DB_PATH` environment variable
- [ ] Validation script verifies schema changes
- [ ] `deploy_preflight` passes all checks
- [ ] Rehearsed locally: `db_pull && db_migrate_test && db_validate_test`
- [ ] Migration output shows `deploy-tmp/db.sqlite` path (not the fallback)
- [ ] Migration is idempotent (safe to run multiple times)
- [ ] Validation is comprehensive (checks actual schema, not just "doesn't crash")
- [ ] Added `deploy-tmp/` to `.gitignore`
- [ ] Documented migration in commit message
- [ ] Deploy with `deploy --db` (or `deploy --auto` with `migrationsDir` set)
- [ ] Optional: Added custom health check endpoint

## Need Help?

- Check deployment status: `deploy_status your-service`
- View service logs: `ssh server 'sudo journalctl -u your-service -n 100'`
- Rehearse locally first: `db_pull && db_migrate_test`
- Rollback if needed: `deploy_rollback your-service [--db]`
