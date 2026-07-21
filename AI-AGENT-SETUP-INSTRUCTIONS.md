# AI Agent Instructions: Add Database Migration to Service

This document provides step-by-step instructions for AI agents to implement database migration support in a service. Follow these instructions sequentially and validate each step.

**How the workflow runs (context):** During a `deploy --db`, the migration and validation commands run **on the server**, as the **service user**, with cwd `/srv/{serverFolder}` — against a `VACUUM INTO` snapshot of the live database, with the service stopped. The `DB_PATH` environment variable points at the snapshot. The live database is only replaced after migration and validation both succeed. The local `db_pull`/`db_migrate_test`/`db_validate_test` commands are a **rehearsal** of the same scripts against a downloaded copy — nothing local is ever uploaded.

## Prerequisites Check

Before starting, verify:

1. **You are in a service repository** (not sig-infra repository)
   - Check: Does `package.json` exist?
   - Check: Is there a `src/` directory?
   - If NO to both → STOP, this is not a service repository

2. **The service uses SQLite**
   - Search for: `Database`, `sqlite`, `.db`, `bun:sqlite`, `better-sqlite3`
   - If NOT FOUND → Ask user: "Does this service use a database? If yes, what type?"

3. **Locate the database file path**
   - Common locations: `data/db.sqlite`, `db/database.sqlite`, `src/db.sqlite`
   - Search codebase for: `.sqlite`, `Database(`, file paths
   - If NOT FOUND → Ask user: "Where is the database file located?"
   - STORE THIS PATH as `DB_FILE_PATH` for later use

4. **Identify the database library**
   - Check package.json dependencies for: `bun:sqlite` (built-in), `better-sqlite3`, `sqlite3`
   - STORE THIS as `DB_LIBRARY` for later use

## Implementation Steps

### Step 1: Create deploy.json

Create `deploy.json` in the repository root:

**File path:** `deploy.json`

**Content:**
```json
{
  "serviceName": "{{SERVICE_NAME}}",
  "serverFolder": "{{SERVER_FOLDER}}",
  "database": {
    "path": "{{DB_FILE_PATH}}",
    "migrate": "bun run db:migrate",
    "validate": "bun run db:health",
    "migrationsDir": "{{MIGRATIONS_DIR}}"
  }
}
```

**Replace placeholders:**
- `{{DB_FILE_PATH}}` → actual database path on server (relative to `/srv/{serverFolder}/`)
- `{{SERVICE_NAME}}` → the key in `services.json` and systemd unit name. **Omit this field** if it matches the local folder name.
- `{{SERVER_FOLDER}}` → the directory name under `/srv/` on the server. **Omit this field** if it matches the local folder name. Note: defaults to local folder name, NOT to `serviceName`.
- `{{MIGRATIONS_DIR}}` → path to the service's migration files (e.g., `"drizzle"`, `"migrations"`). **Omit this field** if the service has no dedicated migrations directory. When present, it enables `deploy_check` and `deploy --auto` to detect whether a deploy needs the database workflow.

**When to include name overrides:**
- If local folder is `sig-booking` but services.json key is `bookings` → set `"serviceName": "bookings"` (no `serverFolder` needed, it stays `sig-booking`)
- If server folder differs from local folder name → set `"serverFolder"` explicitly
- If everything matches (most common) → omit both fields

**Ask the user** if you're unsure whether the local folder name matches the services.json key or server directory.

**Note:** Do NOT include `healthCheck` field yet - we'll add it later if needed. Also do NOT include `install` — it is auto-detected from the lockfile.

**Validation:**
- File created at repository root
- JSON is valid (no syntax errors)
- `path` field matches the actual database location
- `serviceName`/`serverFolder` match actual server configuration (if included)

### Step 2: Update package.json

Add migration and validation scripts to `package.json`.

**Read existing package.json first** to understand the structure.

**Add to the `"scripts"` section:**
```json
"db:migrate": "bun ./scripts/migrate.ts",
"db:health": "bun ./scripts/health.ts"
```

**If no `"scripts"` section exists**, create it:
```json
{
  "name": "service-name",
  "scripts": {
    "db:migrate": "bun ./scripts/migrate.ts",
    "db:health": "bun ./scripts/health.ts"
  }
}
```

**Validation:**
- `package.json` is valid JSON
- Scripts section includes both new scripts
- Existing scripts are preserved

### Step 3: Create scripts directory

**If `scripts/` directory doesn't exist**, create it:

```bash
mkdir -p scripts
```

**Validation:**
- `scripts/` directory exists at repository root

### Step 4: Analyze existing database usage

Before creating migration scripts, understand how the service uses the database:

1. **Find database initialization code**
   - Search for: `new Database(`, `.prepare(`, `CREATE TABLE`, `.run(`
   - Identify: What tables exist? What's the schema?

2. **Document current schema**
   - List all tables in use
   - Note any indexes, constraints
   - STORE THIS for migration script

3. **Check for existing migrations**
   - Look for: `migrations/`, `db/migrations/`, migration files
   - If EXISTS → Ask user: "This service has existing migrations. Should I integrate with the existing system or create standalone scripts?"
   - If EXISTS → also set `database.migrationsDir` in deploy.json to that directory

### Step 5: Create migration script

**File path:** `scripts/migrate.ts`

**Template based on `DB_LIBRARY`:**

#### For bun:sqlite (built-in):
```typescript
import { Database } from "bun:sqlite";

// Read database path from environment variable.
// During deploys the server sets DB_PATH to a snapshot of the live DB;
// during local rehearsal (db_migrate_test) it points at deploy-tmp/db.sqlite.
// Falls back to the normal dev path if not set.
const dbPath = process.env.DB_PATH || "{{DB_FILE_PATH}}";
const db = new Database(dbPath);

console.log(`Running migrations on ${dbPath}...`);

try {
  // PLACEHOLDER: Add your migration logic here
  // Example: Add a new column (idempotent)
  const columns = db.query("PRAGMA table_info(your_table)").all();
  const hasNewColumn = columns.some((c: any) => c.name === "new_column");

  if (!hasNewColumn) {
    db.run("ALTER TABLE your_table ADD COLUMN new_column TEXT");
    console.log("✅ Added new_column to your_table");
  } else {
    console.log("ℹ️  new_column already exists, skipping");
  }

  console.log("✅ Migrations completed successfully");
  db.close();
  process.exit(0);
} catch (error) {
  console.error("❌ Migration failed:", error);
  db.close();
  process.exit(1);
}
```

#### For better-sqlite3:
```typescript
import Database from "better-sqlite3";

// DB_PATH: snapshot path during deploys, deploy-tmp/db.sqlite during rehearsal
const dbPath = process.env.DB_PATH || "{{DB_FILE_PATH}}";
const db = new Database(dbPath);

console.log(`Running migrations on ${dbPath}...`);

try {
  // PLACEHOLDER: Add your migration logic here
  const columns = db.prepare("PRAGMA table_info(your_table)").all();
  const hasNewColumn = columns.some((c: any) => c.name === "new_column");

  if (!hasNewColumn) {
    db.prepare("ALTER TABLE your_table ADD COLUMN new_column TEXT").run();
    console.log("✅ Added new_column to your_table");
  } else {
    console.log("ℹ️  new_column already exists, skipping");
  }

  console.log("✅ Migrations completed successfully");
  db.close();
  process.exit(0);
} catch (error) {
  console.error("❌ Migration failed:", error);
  db.close();
  process.exit(1);
}
```

**Replace placeholders:**
- `{{DB_FILE_PATH}}` → actual database path
- `your_table` → actual table name from schema analysis
- `new_column` → example, replace with actual migration logic

**IMPORTANT:**
- DO NOT write actual schema changes yet
- This is a TEMPLATE for the user to customize
- Add a comment: `// TODO: Add your actual migration logic here`
- The script MUST read `DB_PATH` — on the server, ignoring it means migrating the live file instead of the snapshot

**Validation:**
- File created at `scripts/migrate.ts`
- TypeScript syntax is valid
- Uses correct database library
- Reads `DB_PATH` from environment

### Step 6: Create validation script

**File path:** `scripts/health.ts`

**Template based on `DB_LIBRARY`:**

#### For bun:sqlite:
```typescript
import { Database } from "bun:sqlite";

// Read database path from environment variable
// (snapshot path during deploys, deploy-tmp/db.sqlite during rehearsal)
const dbPath = process.env.DB_PATH || "{{DB_FILE_PATH}}";
const db = new Database(dbPath);

console.log(`Validating database schema at ${dbPath}...`);

try {
  // Check that database is accessible
  db.query("SELECT 1").get();

  // PLACEHOLDER: Add your validation logic here
  // Example: Check that expected tables exist
  const tables = db.query(
    "SELECT name FROM sqlite_master WHERE type='table'"
  ).all() as { name: string }[];

  const tableNames = tables.map(t => t.name);
  const requiredTables = ["your_table"]; // TODO: Update with actual tables

  for (const table of requiredTables) {
    if (!tableNames.includes(table)) {
      throw new Error(`Missing required table: ${table}`);
    }
  }

  // Example: Check specific columns exist
  // const columns = db.query("PRAGMA table_info(your_table)").all();
  // const hasNewColumn = columns.some((c: any) => c.name === "new_column");
  // if (!hasNewColumn) {
  //   throw new Error("Missing new_column in your_table");
  // }

  console.log("✅ Database validation passed");
  db.close();
  process.exit(0);
} catch (error) {
  console.error("❌ Validation failed:", error);
  db.close();
  process.exit(1);
}
```

#### For better-sqlite3:
```typescript
import Database from "better-sqlite3";

const dbPath = process.env.DB_PATH || "{{DB_FILE_PATH}}";
const db = new Database(dbPath);

console.log(`Validating database schema at ${dbPath}...`);

try {
  // Check that database is accessible
  db.prepare("SELECT 1").get();

  // PLACEHOLDER: Add your validation logic here
  const tables = db.prepare(
    "SELECT name FROM sqlite_master WHERE type='table'"
  ).all() as { name: string }[];

  const tableNames = tables.map(t => t.name);
  const requiredTables = ["your_table"]; // TODO: Update with actual tables

  for (const table of requiredTables) {
    if (!tableNames.includes(table)) {
      throw new Error(`Missing required table: ${table}`);
    }
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

**Replace placeholders:**
- `{{DB_FILE_PATH}}` → actual database path
- `your_table` → actual table names from schema analysis
- Add TODO comments for user to customize

**Validation:**
- File created at `scripts/health.ts`
- TypeScript syntax is valid
- Uses correct database library
- Reads `DB_PATH` from environment

**Note:** On the server, this validation is the last gate before the migrated snapshot replaces the live database. Be thorough.

### Step 7: Update .gitignore

**Read existing `.gitignore`** first.

**Add these lines** if they don't already exist:
```gitignore
# Deployment artifacts
deploy-tmp/
*.local-backup
```

**Location:** Add at the end of the file, in a new section.

**If `.gitignore` doesn't exist**, create it with these lines.

(`deploy-tmp/` is only used by the local rehearsal commands — it is never deployed.)

**Validation:**
- `.gitignore` includes `deploy-tmp/`
- `.gitignore` includes `*.local-backup`
- No duplicate entries

### Step 8: Run preflight validation

**Before testing scripts**, run the preflight check to validate the full setup:

```bash
deploy_preflight
```

This checks:
- `deploy.json` is valid and has required fields
- Migration/validation scripts exist locally
- Scripts reference `DB_PATH` environment variable (critical — without this, the server-side migration runs against the wrong database)
- `package.json` has `db:migrate` and `db:health` scripts
- Remote database, service directory, and systemd unit exist
- Service is registered in `services.json`
- `.gitignore` includes `deploy-tmp/`

**All checks must pass before proceeding.** Fix any errors reported.

### Step 9: Rehearse migration against production data

**After preflight passes**, rehearse the migration locally. This runs the same scripts the server will run during deploy, but against a downloaded copy — nothing is uploaded.

```bash
# Snapshot prod DB on the server (VACUUM INTO), download to deploy-tmp/db.sqlite
db_pull

# Run migration on the downloaded DB (sets DB_PATH=deploy-tmp/db.sqlite)
db_migrate_test

# Validate the migrated DB
db_validate_test
```

**Expected behavior:**
- `db_pull` downloads the database successfully
- `db_migrate_test` runs migration and output shows path `deploy-tmp/db.sqlite` (NOT the fallback path)
- `db_validate_test` passes validation

**Critical check:** Verify the migration output shows the correct path. If it shows the fallback path (e.g., `data/status.db` instead of `deploy-tmp/db.sqlite`), your script is not reading the `DB_PATH` environment variable correctly. Fix this before deploying — on the server, the same bug would make the deploy migrate the live file instead of the snapshot.

**If errors occur:**
- Check TypeScript syntax
- Verify database path is correct
- Ensure database library is installed
- Confirm `process.env.DB_PATH` is used (not ignored or overridden)

### Step 10: Create summary document

Create a file: `DATABASE-MIGRATION-SETUP.md` in the repository root.

**Content:**
```markdown
# Database Migration Setup

This service has been configured to support database migrations during deployment.

## What was added:

1. **deploy.json** - Deployment configuration
   - Specifies database path: `{{DB_FILE_PATH}}`
   - Migration command: `bun run db:migrate`
   - Validation command: `bun run db:health`

2. **scripts/migrate.ts** - Migration script (TEMPLATE)
   - ⚠️ **ACTION REQUIRED:** Add your actual migration logic
   - Currently contains placeholder code
   - Reads DB path from `DB_PATH` environment variable

3. **scripts/health.ts** - Validation script (TEMPLATE)
   - ⚠️ **ACTION REQUIRED:** Add your actual validation checks
   - Currently performs basic table existence checks
   - Update `requiredTables` array with your actual tables

4. **.gitignore** - Updated to ignore deployment artifacts
   - `deploy-tmp/` - Local migration rehearsal directory
   - `*.local-backup` - Backup files

5. **package.json** - Added scripts
   - `db:migrate` - Run migration
   - `db:health` - Run validation

## Next Steps:

### 1. Customize Migration Script

Edit `scripts/migrate.ts` and replace the placeholder migration logic with your actual database changes.

**Example migrations:**
- Add a column: `ALTER TABLE users ADD COLUMN email TEXT`
- Create a table: `CREATE TABLE IF NOT EXISTS sessions (...)`
- Create an index: `CREATE INDEX IF NOT EXISTS idx_user_email ON users(email)`

**Important:** Make migrations idempotent (safe to run multiple times) — they run once in rehearsal and once for real on the server.

### 2. Customize Validation Script

Edit `scripts/health.ts` and add comprehensive validation:
- Check all required tables exist
- Verify critical columns exist
- Check indexes are present (if added)

### 3. Rehearse Locally

Before deploying:

\`\`\`bash
# Download a snapshot of the production database
db_pull

# Run migration on the downloaded DB
db_migrate_test

# Validate migration
db_validate_test

# Inspect if needed
sqlite3 deploy-tmp/db.sqlite ".schema"
\`\`\`

### 4. Deploy

Once migration and validation scripts are ready:

\`\`\`bash
deploy --db
\`\`\`

The deployment runs entirely on the server:
1. Maintenance mode on, git pull, install deps
2. Stop service (nothing may write to the DB)
3. Snapshot the live DB (`VACUUM INTO`)
4. Run migration on the snapshot (`DB_PATH` = snapshot)
5. Validate the snapshot
6. Rotate backups (backup.1 → backup.2, current → backup.1)
7. Swap snapshot into place (+ clear WAL/SHM sidecars), integrity check
8. Start service, health check, maintenance off
9. On failure: auto-recover to the previous commit (and restore backup.1 if the DB was already swapped)

For later deploys without schema changes, use `deploy --no-db` (or `deploy --auto` if `migrationsDir` is set).

## Current Database Schema

{{SCHEMA_SUMMARY}}

## Notes

- Migration runs **on the server** as the service user, against a snapshot — never against the live database file
- The live DB is only replaced after migration AND validation succeed
- Backups (backup.1, backup.2) are created automatically before the swap
- If deployment fails, code (and DB, if it was swapped) are auto-recovered
- See SERVICE-DATABASE-GUIDE.md in sig-infra repo for details
```

**Replace placeholders:**
- `{{DB_FILE_PATH}}` → actual database path
- `{{SCHEMA_SUMMARY}}` → brief description of current schema

**Validation:**
- File created at repository root
- Contains clear next steps
- References actual file paths

### Step 11: Final validation checklist

Verify all files are in place:

- [ ] `deploy.json` exists at repository root
- [ ] `scripts/migrate.ts` exists and is valid TypeScript
- [ ] `scripts/health.ts` exists and is valid TypeScript
- [ ] `package.json` includes `db:migrate` and `db:health` scripts
- [ ] `.gitignore` includes `deploy-tmp/` and `*.local-backup`
- [ ] `DATABASE-MIGRATION-SETUP.md` created with instructions
- [ ] All files use correct database path
- [ ] All files use correct database library

## Summary for User

After completing all steps, provide this summary to the user:

---

✅ **Database migration support has been added to this service!**

**Files created/modified:**
- `deploy.json` - Deployment configuration
- `scripts/migrate.ts` - Migration script (template)
- `scripts/health.ts` - Validation script (template)
- `package.json` - Added db:migrate and db:health scripts
- `.gitignore` - Added deployment artifact exclusions
- `DATABASE-MIGRATION-SETUP.md` - Setup summary and next steps

**⚠️ IMPORTANT - ACTION REQUIRED:**

The migration and validation scripts contain **placeholder code**. Before deploying:

1. **Edit `scripts/migrate.ts`** - Add your actual database migration logic
2. **Edit `scripts/health.ts`** - Add comprehensive validation checks
3. **Rehearse locally:**
   ```bash
   db_pull && db_migrate_test && db_validate_test
   ```
4. **Deploy with the database workflow:**
   ```bash
   deploy --db
   ```
   The migration runs on the server, against a snapshot, with automatic backup and recovery.
5. **Review `DATABASE-MIGRATION-SETUP.md`** for detailed instructions

**Need help?** See `SERVICE-DATABASE-GUIDE.md` in the sig-infra repository.

---

## Error Handling

### If user asks to add specific migrations:

1. Ask for details: "What database changes do you want to make?"
2. Get confirmation on schema changes
3. Update `scripts/migrate.ts` with actual logic
4. Update `scripts/health.ts` with corresponding validation
5. Test the scripts

### If service doesn't use SQLite:

Stop and inform user:
"This service appears to use [DATABASE_TYPE] instead of SQLite. The current deployment system only supports SQLite databases. Would you like to:
1. Convert to SQLite
2. Wait for multi-database support
3. Handle migrations manually"

### If service has no database:

Ask user:
"I don't see a database in this service. Are you sure you want to add database migration support? If yes, please provide:
1. Database file path (where should it be created?)
2. Initial schema (what tables/columns?)"

## Decision Tree

```
START
  |
  ├─ In service repo? ──NO──> STOP: Wrong repository
  |     YES
  |
  ├─ Uses SQLite? ──NO──> ERROR: Unsupported database
  |     YES
  |
  ├─ Found DB path? ──NO──> ASK USER: Where is database?
  |     YES
  |
  ├─ Existing migrations? ──YES──> ASK USER: Integrate or standalone?
  |     NO                          (and set database.migrationsDir)
  |
  ├─ Follow Steps 1-10
  |
  ├─ User wants specific migrations? ──YES──> Add to migrate.ts
  |     NO (just setup)
  |
  └─> DONE: Provide summary with templates
```

## Testing the Setup

After implementation, verify the setup works:

1. **Syntax check:**
   ```bash
   bun run db:migrate
   bun run db:health
   ```
   Both should run without syntax errors.

2. **Check package.json:**
   ```bash
   grep -A2 "scripts" package.json
   ```
   Should show db:migrate and db:health.

3. **Verify deploy.json:**
   ```bash
   cat deploy.json
   ```
   Should be valid JSON with database config.

4. **Test DB_PATH handling** (if database exists locally):
   ```bash
   DB_PATH=data/db.sqlite bun run db:migrate
   DB_PATH=data/db.sqlite bun run db:health
   ```
   Both should succeed and print the path from `DB_PATH` — this is how the server invokes them during deploys (with `DB_PATH` pointing at the snapshot).

## Common Issues

**Issue:** "Cannot find module 'bun:sqlite'"
- **Fix:** Service might use different library. Check package.json dependencies.

**Issue:** "ENOENT: no such file or directory"
- **Fix:** Database path in deploy.json is incorrect. Verify actual path.

**Issue:** "Package.json has no scripts section"
- **Fix:** Add scripts section: `{"scripts": {}}`

**Issue:** "Migration runs but validation fails"
- **Fix:** Validation logic doesn't match migration changes. Review both scripts.

**Issue:** "Migration output shows the fallback path, not DB_PATH"
- **Fix:** Script ignores `process.env.DB_PATH`. Critical — on the server this would migrate the live database instead of the snapshot. Fix before deploying.
