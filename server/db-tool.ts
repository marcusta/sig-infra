#!/usr/bin/env bun
/**
 * Small helper for safe SQLite operations. Run as the service user (via sudo -u)
 * so file ownership stays correct.
 *
 * Usage:
 *   bun db-tool.ts snapshot <src> <dest>   # VACUUM INTO — one consistent file, WAL folded in
 *   bun db-tool.ts checkpoint <db>         # PRAGMA wal_checkpoint(TRUNCATE)
 *   bun db-tool.ts integrity <db>          # PRAGMA integrity_check (exit 1 on failure)
 */

import { Database } from "bun:sqlite";
import { existsSync, rmSync } from "node:fs";

const [cmd, a, b] = process.argv.slice(2);

function fail(msg: string): never {
  console.error(msg);
  process.exit(1);
}

// Escape a path for embedding in a SQL string literal
function sqlQuote(path: string): string {
  return path.replaceAll("'", "''");
}

switch (cmd) {
  case "snapshot": {
    if (!a || !b) fail("Usage: db-tool.ts snapshot <src> <dest>");
    if (!existsSync(a)) fail(`Source not found: ${a}`);
    // VACUUM INTO refuses to overwrite — clear any previous snapshot and its sidecars
    for (const f of [b, `${b}-wal`, `${b}-shm`]) rmSync(f, { force: true });
    const db = new Database(a);
    db.run(`VACUUM INTO '${sqlQuote(b)}'`);
    db.close();
    console.log(`📸 Snapshot: ${a} → ${b}`);
    break;
  }

  case "checkpoint": {
    if (!a) fail("Usage: db-tool.ts checkpoint <db>");
    if (!existsSync(a)) fail(`Database not found: ${a}`);
    const db = new Database(a);
    db.run("PRAGMA wal_checkpoint(TRUNCATE)");
    db.close();
    console.log(`✅ Checkpointed: ${a}`);
    break;
  }

  case "integrity": {
    if (!a) fail("Usage: db-tool.ts integrity <db>");
    if (!existsSync(a)) fail(`Database not found: ${a}`);
    const db = new Database(a, { readonly: true });
    const row = db.query("PRAGMA integrity_check").get() as { integrity_check: string };
    db.close();
    if (row.integrity_check !== "ok") fail(`❌ Integrity check failed: ${row.integrity_check}`);
    console.log(`✅ Integrity: ok`);
    break;
  }

  default:
    fail("Usage: db-tool.ts <snapshot|checkpoint|integrity> <args>");
}
