# AI Agent Instructions: Add Database Migration to Service

This document provides step-by-step instructions for AI agents to implement database migration support in a service. Follow these instructions sequentially and validate each step.

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
  "database": {
    "path": "{{DB_FILE_PATH}}",
    "migrate": "bun run db:migrate",
    "validate": "bun run db:health"
  }
}
```

**Replace `{{DB_FILE_PATH}}`** with the actual path you found in prerequisites.

**Note:** Do NOT include `healthCheck` field yet - we'll add it later if needed.

**Validation:**
- File created at repository root
- JSON is valid (no syntax errors)
- `path` field matches the actual database location

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

### Step 5: Create migration script

**File path:** `scripts/migrate.ts`

**Template based on `DB_LIBRARY`:**

#### For bun:sqlite (built-in):
```typescript
import { Database } from "bun:sqlite";

// Read database path from environment variable
// Falls back to production path if not set
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

**Validation:**
- `.gitignore` includes `deploy-tmp/`
- `.gitignore` includes `*.local-backup`
- No duplicate entries

### Step 8: Test the scripts locally

**Before finalizing**, test that the scripts run:

```bash
# Test migration script
bun run db:migrate

# Test validation script
bun run db:health
```

**Expected behavior:**
- Scripts should run without syntax errors
- Migration should log success (even if no changes)
- Validation should pass

**If errors occur:**
- Check TypeScript syntax
- Verify database path is correct
- Ensure database library is installed

### Step 9: Create summary document

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
   - `deploy-tmp/` - Local migration testing directory
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

**Important:** Make migrations idempotent (safe to run multiple times).

### 2. Customize Validation Script

Edit `scripts/health.ts` and add comprehensive validation:
- Check all required tables exist
- Verify critical columns exist
- Check indexes are present (if added)

### 3. Test Locally

Before deploying:

\`\`\`bash
# Download production database
db_pull

# Run migration on downloaded DB
db_migrate_test

# Validate migration
db_validate_test

# Inspect if needed
sqlite3 deploy-tmp/db.sqlite ".schema"
\`\`\`

### 4. Deploy

Once migration and validation scripts are ready:

\`\`\`bash
deploy
\`\`\`

The deployment will:
1. Download prod DB
2. Run migration locally
3. Validate migration
4. Upload if valid
5. Deploy code
6. Health check
7. Rollback if anything fails

## Current Database Schema

{{SCHEMA_SUMMARY}}

## Notes

- Migration runs **locally** on your machine, not on the server
- Database is backed up automatically before migration
- If deployment fails, both DB and code are rolled back
- See SERVICE-DATABASE-GUIDE.md in sig-infra repo for details
```

**Replace placeholders:**
- `{{DB_FILE_PATH}}` → actual database path
- `{{SCHEMA_SUMMARY}}` → brief description of current schema

**Validation:**
- File created at repository root
- Contains clear next steps
- References actual file paths

### Step 10: Final validation checklist

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
3. **Test locally:**
   ```bash
   db_pull && db_migrate_test && db_validate_test
   ```
4. **Review `DATABASE-MIGRATION-SETUP.md`** for detailed instructions

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
  |     NO
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

4. **Test with deploy commands** (if database exists locally):
   ```bash
   DB_PATH=data/db.sqlite bun run db:migrate
   DB_PATH=data/db.sqlite bun run db:health
   ```
   Both should succeed.

## Common Issues

**Issue:** "Cannot find module 'bun:sqlite'"
- **Fix:** Service might use different library. Check package.json dependencies.

**Issue:** "ENOENT: no such file or directory"
- **Fix:** Database path in deploy.json is incorrect. Verify actual path.

**Issue:** "Package.json has no scripts section"
- **Fix:** Add scripts section: `{"scripts": {}}`

**Issue:** "Migration runs but validation fails"
- **Fix:** Validation logic doesn't match migration changes. Review both scripts.
