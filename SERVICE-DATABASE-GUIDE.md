# Database Migration Guide for Services

This guide is for developers of individual services (e.g., `golf-serie`, `bookings`, etc.) who want to enable safe database migrations during deployment.

## Overview

The deployment system supports **optional** database migration with:
- Local migration execution (migrations run on your dev machine, not on the server)
- Automatic backup and rollback on failure
- Local development testing with production data
- Custom health checks after deployment

**This is completely optional** - services without database configuration deploy normally.

## Quick Start

To enable database migration support for your service:

1. Create `deploy.json` in your repository root
2. Add migration and validation scripts
3. Test locally with `db_pull` and `db_migrate_test`
4. Deploy normally - migrations happen automatically

## Configuration File (deploy.json)

Create `deploy.json` in your service repository root:

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

### Configuration Fields

#### `database.path` (required if using database)
- Relative path from `/srv/{your-service}/` on the server
- Example: `"data/db.sqlite"` → `/srv/golf-serie/data/db.sqlite`
- This is where your production database lives on the server

#### `database.migrate` (required if using database)
- Shell command to run migration
- Executed in your **project root** on your **local machine**
- Example: `"bun run db:migrate"` or `"npm run migrate"`
- Environment variable `DB_PATH` points to the database file

#### `database.validate` (required if using database)
- Shell command to validate migration succeeded
- Executed in your **project root** on your **local machine**
- Must exit with code 0 for success, non-zero for failure
- Example: `"bun run db:health"` or `"npm run db:validate"`
- Environment variable `DB_PATH` points to the database file

#### `healthCheck` (optional)
- Custom health check command to run on the server after deployment
- Executed on the **server** after service restart
- Must exit with code 0 for success, non-zero for failure
- Example: `"curl -f http://localhost:3000/health"`
- If omitted, uses TCP port check (existing behavior)

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

// Read database path from environment variable
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
- Read `DB_PATH` from environment (deployment sets this to `deploy-tmp/db.sqlite`)
- Fall back to your normal dev DB path if not set
- Exit with code 0 on success, non-zero on failure
- Use idempotent operations (`IF NOT EXISTS`, etc.) when possible

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
- Be thorough - this prevents deploying broken migrations

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

## Deployment Workflow

When you run `deploy` from your service directory:

### With Database Configuration:

1. **Pre-deployment (local):**
   - Detects `deploy.json` with database config
   - Enables maintenance mode on server
   - Downloads production database to `deploy-tmp/db.sqlite`
   - Runs `DB_PATH=deploy-tmp/db.sqlite bun run db:migrate`
   - Runs `DB_PATH=deploy-tmp/db.sqlite bun run db:health`
   - If validation fails → aborts, disables maintenance mode

2. **Database Upload:**
   - Server rotates backups: `.backup.1` → `.backup.2`, `current` → `.backup.1`
   - Uploads migrated DB to server
   - Swaps new DB into place

3. **Code Deployment:**
   - Runs local build (if `.build` exists)
   - Git commit and push
   - Server pulls latest code
   - Server restarts service

4. **Health Check:**
   - Runs custom health check (if specified) or TCP port check
   - If check fails → rollbacks both database and code

5. **Finalization:**
   - Disables maintenance mode
   - Tails logs

### Without Database Configuration:

Works exactly as before:
1. Local build (if `.build` exists)
2. Git commit and push
3. Server deployment
4. Health check (TCP port)
5. Tail logs

## Local Development Testing

Before deploying, test your migration locally:

```bash
cd ~/projects/your-service

# Download production database
db_pull

# Run migration on the downloaded DB
db_migrate_test

# Validate migration
db_validate_test

# Inspect the migrated database if needed
sqlite3 deploy-tmp/db.sqlite
```

This lets you:
- Test migrations against real production data structure
- Verify schema changes work correctly
- Catch issues before deploying

## Backup and Rollback

### Automatic Backups

Each deployment creates numbered backups on the server:
- `db.sqlite.backup.1` - Latest backup (from current deployment)
- `db.sqlite.backup.2` - Previous backup (from prior deployment)

Rotation happens automatically before upload.

### Automatic Rollback

If deployment fails (migration, validation, or health check):
- Database is restored from `.backup.1`
- Code is reverted via `git reset --hard HEAD~1`
- Service stays in maintenance mode
- You're notified of the failure

### Manual Rollback

If you need to rollback manually:

```bash
deploy_rollback your-service
```

This:
- Reverts code to previous commit
- Restarts service
- Runs health check
- Removes maintenance mode

**Note:** Manual rollback does NOT restore the database. If you need to restore the database manually:

```bash
ssh marcus@app.swedenindoorgolf.se
cd /srv/your-service
sudo -u your-service cp data/db.sqlite.backup.1 data/db.sqlite
sudo systemctl restart your-service
```

## Troubleshooting

### Migration fails locally

Check:
- Is `DB_PATH` being read correctly in your script?
- Does the migration work with your dev database?
- Are you using idempotent operations?
- Run `DB_PATH=deploy-tmp/db.sqlite bun run db:migrate` manually

### Validation fails

Check:
- Does your validation script correctly check the schema?
- Did the migration actually apply?
- Inspect with: `sqlite3 deploy-tmp/db.sqlite ".schema"`

### Health check fails after deployment

Check:
- Is your service actually starting? `ssh server 'sudo journalctl -u your-service -n 50'`
- Is the health check command correct?
- Can you curl the endpoint manually?
- Try deploying without custom health check first (remove from deploy.json)

### Database not found

Check:
- Is `database.path` in deploy.json correct?
- Does the file exist on the server? `ssh server 'ls -la /srv/your-service/data/'`

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

### 2. Test Against Production Data

Always use `db_pull` and test locally before deploying:

```bash
db_pull && db_migrate_test && db_validate_test
```

### 3. Keep Validation Comprehensive

Don't just check that migration didn't crash - verify the schema is correct:

```typescript
// Not enough
db.query("SELECT 1").get();

// Better
const tables = db.query("SELECT name FROM sqlite_master WHERE type='table'").all();
const hasNewTable = tables.some(t => t.name === "sessions");
if (!hasNewTable) throw new Error("sessions table missing");
```

### 4. Deployment Strategy for Schema Changes

For complex migrations:
1. Deploy backward-compatible code first (works with old schema)
2. Deploy database migration (updates schema)
3. Deploy new code that uses new schema

For simple additions (new columns, tables), you can deploy together.

### 5. Monitor Deployments

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
- [ ] Tested locally: `db_pull && db_migrate_test && db_validate_test`
- [ ] Migration is idempotent (safe to run multiple times)
- [ ] Validation is comprehensive (checks actual schema, not just "doesn't crash")
- [ ] Added `deploy-tmp/` to `.gitignore`
- [ ] Documented migration in commit message
- [ ] Optional: Added custom health check endpoint

## Need Help?

- Check deployment logs: `deploy_status your-service`
- View service logs: `ssh server 'sudo journalctl -u your-service -n 100'`
- Test locally first: `db_pull && db_migrate_test`
- Rollback if needed: `deploy_rollback your-service`
