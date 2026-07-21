#!/usr/bin/env bun
/**
 * Server-side deployment script
 *
 * Two-file architecture:
 * - services.json: Service structure (port, stripPath) - tracked in git
 * - services-state.json: Operational state (live/maintenance) - server-only
 *
 * Database workflow (--db, requires a "database" block in the service's deploy.json)
 * runs entirely on this server:
 *   stop service → snapshot (VACUUM INTO) → migrate snapshot → validate snapshot
 *   → rotate backups → swap into place (+ remove WAL/SHM sidecars) → integrity check → start
 *
 * The live database is only ever replaced by a file that already migrated and
 * validated. On any failure the deploy auto-recovers: git reset to the previous
 * commit, reinstall deps, restore database backup.1 (only if it was already
 * swapped), restart. If recovery itself fails, the service stays in maintenance.
 *
 * Usage:
 *   bun deploy.ts <service-name>                     # Code-only deploy
 *   bun deploy.ts <service-name> --db                # Deploy with database migration
 *   bun deploy.ts <service-name> --folder <dir>      # /srv/ folder differs from service name
 *   bun deploy.ts <service-name> --status            # Check service status
 *   bun deploy.ts <service-name> --rollback [--db]   # Revert commit (--db: also restore DB backup.1)
 *   bun deploy.ts <service-name> --health-check '<command>' # Deploy with custom health check
 */

import { $ } from "bun";

const SCRIPT_DIR = import.meta.dir;
const SERVICES_STRUCTURE_FILE = `${SCRIPT_DIR}/services.json`;
const SERVICES_STATE_FILE = `${SCRIPT_DIR}/services-state.json`;
const CADDY_DIR = SCRIPT_DIR; // generate.ts is in same directory
const DB_TOOL = `${SCRIPT_DIR}/db-tool.ts`;

// Structure: port, stripPath (tracked in git)
interface ServiceStructure {
  port: number;
  stripPath?: boolean;
}

// State: live/maintenance (server-only)
interface ServiceState {
  live: boolean;
}

// Combined
interface ServiceConfig extends ServiceStructure {
  live: boolean;
}

interface DeployDbConfig {
  path: string;
  migrate: string;
  validate: string;
}

type ServicesStructure = Record<string, ServiceStructure>;
type ServicesState = Record<string, ServiceState>;
type Services = Record<string, ServiceConfig>;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

async function loadServicesStructure(): Promise<ServicesStructure> {
  const file = Bun.file(SERVICES_STRUCTURE_FILE);
  if (!(await file.exists())) {
    throw new Error(`${SERVICES_STRUCTURE_FILE} not found`);
  }
  return file.json();
}

async function loadServicesState(): Promise<ServicesState> {
  const file = Bun.file(SERVICES_STATE_FILE);
  if (!(await file.exists())) {
    return {}; // Default to empty if state file doesn't exist
  }
  return file.json();
}

async function loadServices(): Promise<Services> {
  const structure = await loadServicesStructure();
  const state = await loadServicesState();

  // Merge: structure + state, defaulting to live: true
  const merged: Services = {};
  for (const [name, config] of Object.entries(structure)) {
    merged[name] = {
      ...config,
      live: state[name]?.live ?? true,
    };
  }

  return merged;
}

async function saveServicesState(state: ServicesState): Promise<void> {
  const content = JSON.stringify(state, null, 2) + "\n";
  const tempFile = "/tmp/services-state.json.new";
  await Bun.write(tempFile, content);
  await $`cat ${tempFile} | sudo tee ${SERVICES_STATE_FILE} > /dev/null`;
  await $`rm ${tempFile}`;
}

async function setMaintenance(serviceName: string, enabled: boolean): Promise<void> {
  const services = await loadServices();

  if (!services[serviceName]) {
    throw new Error(`Service '${serviceName}' not found in services.json`);
  }

  // Update state file only
  const state = await loadServicesState();
  state[serviceName] = { live: !enabled };
  await saveServicesState(state);

  // Regenerate and reload Caddy
  await $`cd ${CADDY_DIR} && bun generate.ts`.quiet();
}

async function checkSystemdService(serviceName: string): Promise<boolean> {
  try {
    await $`systemctl is-active --quiet ${serviceName}`.quiet();
    return true;
  } catch {
    return false;
  }
}

// Default 60 attempts (1s apart): services that run their own migrations at
// boot start slowest right after a big migration set — a false timeout here
// doesn't just report failure, it triggers recovery over a healthy deploy.
// Bails immediately if the systemd unit enters "failed" state — no point
// polling the port for a process systemd already knows is dead.
async function waitForHealthy(
  serviceName: string,
  port: number,
  customHealthCheck?: string,
  maxAttempts = 60
): Promise<boolean> {
  console.log(`⏳ Waiting for service to be healthy (up to ${maxAttempts}s)...`);

  for (let i = 0; i < maxAttempts; i++) {
    try {
      if (customHealthCheck) {
        // Run custom health check command
        await $`sh -c ${customHealthCheck}`.quiet();
        return true;
      } else {
        // Simple TCP check - just see if port is listening
        await $`nc -z localhost ${port}`.quiet();
        return true;
      }
    } catch {
      // Fail fast: unit crashed and is not auto-restarting
      try {
        await $`systemctl is-failed --quiet ${serviceName}`.quiet();
        console.error(`❌ Unit '${serviceName}' entered failed state — giving up early`);
        console.error(`   sudo journalctl -u ${serviceName} -n 50`);
        return false;
      } catch {
        // Not in failed state — still starting (or auto-restarting), keep waiting
      }
      if (i > 0 && i % 10 === 0) {
        console.log(`   ...still waiting (${i}/${maxAttempts}s)`);
      }
      await Bun.sleep(1000);
    }
  }
  return false;
}

// Guard against Ctrl+C / hangup during the DB swap and recovery — aborting
// mid-way leaves the service stopped and in maintenance with no recovery run.
let criticalSection = "";
function installSignalGuard(): void {
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
    process.on(sig, () => {
      if (criticalSection) {
        console.error(`\n⚠️  ${sig} ignored — ${criticalSection} in progress, aborting now would strand the service`);
      } else {
        process.exit(130);
      }
    });
  }
}

// Run a shell command as the service user
async function asUser(folder: string, cmd: string): Promise<void> {
  await $`sudo -u ${folder} bash -c ${cmd}`;
}

// Run a project command (migrate/validate) as the service user with DB_PATH set
async function runDbCommand(
  folder: string,
  servicePath: string,
  dbPath: string,
  cmd: string
): Promise<void> {
  const full = `cd '${servicePath}' && DB_PATH='${dbPath}' ${cmd}`;
  await $`sudo -u ${folder} bash -c ${full}`;
}

// Auto-detect package manager from lockfile
async function detectInstallCmd(servicePath: string): Promise<string | undefined> {
  if (
    (await Bun.file(`${servicePath}/bun.lockb`).exists()) ||
    (await Bun.file(`${servicePath}/bun.lock`).exists())
  ) {
    return "bun install";
  }
  if (await Bun.file(`${servicePath}/pnpm-lock.yaml`).exists()) return "pnpm install";
  if (await Bun.file(`${servicePath}/yarn.lock`).exists()) return "yarn install";
  if (await Bun.file(`${servicePath}/package-lock.json`).exists()) return "npm install";
  return undefined; // No lockfile — no install step
}

async function runInstall(folder: string, servicePath: string, installCmd: string): Promise<void> {
  console.log(`📦 Installing dependencies: ${installCmd}`);
  // Use bash -c to ensure proper PATH and environment
  // Timeout after 30 seconds - bun install sometimes hangs at the end even when done
  try {
    await $`cd ${servicePath} && timeout 30 sudo -u ${folder} bash -c '${installCmd}'`;
  } catch (error: any) {
    // Exit code 124 means timeout - bun install likely finished but hung
    if (error.exitCode === 124) {
      console.log(`⚠️  Install command timed out (likely finished but hung)`);
    } else {
      console.error(`❌ Install command failed: ${error}`);
      throw new Error("Dependency installation failed");
    }
  }
}

// Read the service's deploy.json (after git pull — migrate commands ship with the new code)
async function readDeployConfig(servicePath: string): Promise<{
  installCmd?: string;
  healthCheck?: string;
  database?: DeployDbConfig;
}> {
  try {
    const cfg = await Bun.file(`${servicePath}/deploy.json`).json();
    const database =
      cfg.database?.path && cfg.database?.migrate && cfg.database?.validate
        ? (cfg.database as DeployDbConfig)
        : undefined;
    return { installCmd: cfg.install, healthCheck: cfg.healthCheck, database };
  } catch {
    return {}; // No deploy.json or invalid JSON - that's fine
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Recovery
// ─────────────────────────────────────────────────────────────────────────────

async function recover(
  serviceName: string,
  folder: string,
  servicePath: string,
  prevCommit: string,
  port: number,
  dbSwapped: boolean,
  dbFile?: string
): Promise<void> {
  console.log(`\n⏪ Auto-recovering to ${prevCommit.slice(0, 7)}...`);
  criticalSection = "auto-recovery";
  try {
    await $`cd ${servicePath} && sudo -u ${folder} git reset --hard ${prevCommit}`;

    // Reinstall deps for the reverted code (lockfile may have changed)
    const installCmd = await detectInstallCmd(servicePath);
    if (installCmd) {
      try {
        await runInstall(folder, servicePath, installCmd);
      } catch {
        console.error(`⚠️  Reinstall failed — continuing recovery`);
      }
    }

    // Only restore the DB if the deploy already swapped it. If the migration
    // failed before the swap, the live database was never touched.
    if (dbSwapped && dbFile) {
      console.log(`⏪ Restoring database from backup.1...`);
      await asUser(
        folder,
        `cp '${dbFile}.backup.1' '${dbFile}' && rm -f '${dbFile}-wal' '${dbFile}-shm'`
      );
      // Don't silently put back something broken
      await $`sudo -u ${folder} bun ${DB_TOOL} integrity ${dbFile}`;
    }

    console.log(`🔄 Restarting service on previous version...`);
    await $`sudo systemctl restart ${folder}`;

    // TCP check only — a custom health check may belong to the new (reverted) code
    const healthy = await waitForHealthy(folder, port);
    if (!healthy) {
      throw new Error(`Service not healthy after recovery`);
    }

    await setMaintenance(serviceName, false);
    criticalSection = "";
    console.log(
      `✅ Recovered on ${prevCommit.slice(0, 7)} — maintenance lifted. The deploy itself FAILED.`
    );
  } catch (error) {
    criticalSection = "";
    console.error(`\n❌ Recovery failed: ${error}`);
    console.error(`⚠️  Service left in MAINTENANCE mode. Manual intervention required:`);
    console.error(`   sudo systemctl status ${folder}`);
    console.error(`   sudo journalctl -u ${folder} -n 50`);
    console.error(`   bun deploy.ts ${serviceName} --rollback${dbSwapped ? " --db" : ""}\n`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Commands
// ─────────────────────────────────────────────────────────────────────────────

async function deploy(
  serviceName: string,
  healthCheckCmd?: string,
  serverFolder?: string,
  withDb = false
): Promise<void> {
  const folder = serverFolder || serviceName;
  const servicePath = `/srv/${folder}`;

  // Validate
  console.log(`\n🚀 Deploying ${serviceName}${withDb ? " (with database migration)" : ""}...\n`);

  const services = await loadServices();
  if (!services[serviceName]) {
    console.error(`❌ Service '${serviceName}' not found in Caddy config`);
    console.error(`   Run: caddy_add ${serviceName} <port>`);
    process.exit(1);
  }

  const port = services[serviceName].port;

  // Check service directory exists
  try {
    await $`test -d ${servicePath}`.quiet();
  } catch {
    console.error(`❌ Service directory not found: ${servicePath}`);
    process.exit(1);
  }

  // Capture the currently deployed commit — this is the recovery target.
  // A deploy can pull several commits, so HEAD~1 after the pull is not enough.
  const prevCommit = (
    await $`sudo -u ${folder} git -C ${servicePath} rev-parse HEAD`.text()
  ).trim();
  console.log(`📌 Deployed commit: ${prevCommit.slice(0, 7)} (recovery target)`);

  let dbSwapped = false;
  let db: { file: string; migrating: string } | null = null;

  // Step 1: Maintenance mode ON
  console.log(`🚧 Enabling maintenance mode...`);
  await setMaintenance(serviceName, true);

  try {
    // Step 2: Git pull
    console.log(`📥 Pulling latest changes...`);
    await $`cd ${servicePath} && sudo -u ${folder} git pull`;

    // Step 3: Read deploy.json AFTER pull — migration commands ship with the new code
    const cfg = await readDeployConfig(servicePath);
    if (!healthCheckCmd && cfg.healthCheck) {
      healthCheckCmd = cfg.healthCheck;
    }

    if (withDb && !cfg.database) {
      throw new Error(
        `--db requested but ${servicePath}/deploy.json has no complete "database" block (path/migrate/validate)`
      );
    }

    // Step 4: Install dependencies
    let installCmd = cfg.installCmd;
    if (!installCmd) {
      installCmd = await detectInstallCmd(servicePath);
      if (installCmd) console.log(`📦 Auto-detected: ${installCmd}`);
    }
    if (installCmd) {
      await runInstall(folder, servicePath, installCmd);
    }

    // Step 5: Database workflow (service must be stopped for the whole DB window)
    if (withDb && cfg.database) {
      const file = `${servicePath}/${cfg.database.path}`;
      const migrating = `${file}.migrating`;
      db = { file, migrating };

      console.log(`⏸  Stopping service for database window...`);
      criticalSection = "database window";
      await $`sudo systemctl stop ${folder}`;

      // VACUUM INTO folds the WAL into one consistent file — never copy a
      // WAL-mode database by copying app.sqlite alone.
      console.log(`📸 Snapshotting database...`);
      await $`sudo -u ${folder} bun ${DB_TOOL} snapshot ${file} ${migrating}`;

      // Fail fast if the LIVE database is already damaged — before migrating,
      // and critically before backup rotation snapshots the damage into backup.1.
      await $`sudo -u ${folder} bun ${DB_TOOL} integrity ${migrating}`;

      console.log(`🔄 Running migration on snapshot...`);
      console.log(`   DB_PATH=${migrating} ${cfg.database.migrate}`);
      await runDbCommand(folder, servicePath, migrating, cfg.database.migrate);

      console.log(`🔍 Validating migrated snapshot...`);
      console.log(`   DB_PATH=${migrating} ${cfg.database.validate}`);
      await runDbCommand(folder, servicePath, migrating, cfg.database.validate);

      // Fold the migration's own WAL into the snapshot before it goes live
      await $`sudo -u ${folder} bun ${DB_TOOL} checkpoint ${migrating}`;

      console.log(`💾 Rotating backups (backup.1 → backup.2, current → backup.1)...`);
      await asUser(
        folder,
        `if [ -f '${file}.backup.1' ]; then mv -f '${file}.backup.1' '${file}.backup.2'; fi`
      );
      await $`sudo -u ${folder} bun ${DB_TOOL} snapshot ${file} ${file}.backup.1`;

      // Swap: replace the database AND remove stale WAL/SHM sidecars in the
      // same step. Leaving old sidecars next to a new database file corrupts
      // it on boot (SQLite replays the stale WAL over the new file).
      console.log(`🔁 Swapping database into place...`);
      await asUser(
        folder,
        `mv -f '${migrating}' '${file}' && rm -f '${migrating}-wal' '${migrating}-shm' '${file}-wal' '${file}-shm'`
      );
      dbSwapped = true;

      // Verify the file that will actually boot, in its final location
      await $`sudo -u ${folder} bun ${DB_TOOL} integrity ${file}`;
    }

    // Step 6: Restart service
    console.log(`🔄 Starting service...`);
    await $`sudo systemctl restart ${folder}`;

    // Step 7: Health check
    const healthy = await waitForHealthy(folder, port, healthCheckCmd);
    if (!healthy) {
      throw new Error(`Service failed to become healthy on port ${port}`);
    }
    console.log(`✅ Service is healthy`);

    // Step 8: Maintenance mode OFF
    console.log(`🟢 Disabling maintenance mode...`);
    await setMaintenance(serviceName, false);
    criticalSection = "";

    console.log(`\n✅ Deployment successful!\n`);
  } catch (error) {
    console.error(`\n❌ Deployment failed: ${error}`);
    if (db && !dbSwapped) {
      console.error(`   Live database untouched. Failed snapshot kept for debugging:`);
      console.error(`   ${db.migrating}`);
    }
    await recover(serviceName, folder, servicePath, prevCommit, port, dbSwapped, db?.file);
    process.exit(1);
  }
}

async function status(serviceName: string, serverFolder?: string): Promise<void> {
  const services = await loadServices();

  if (!services[serviceName]) {
    console.log(`❌ ${serviceName}: not in Caddy config`);
    process.exit(1);
  }

  const config = services[serviceName];
  const systemdActive = await checkSystemdService(serviceName);

  console.log(`\nService: ${serviceName}`);
  console.log(`─`.repeat(40));
  console.log(`Port:        ${config.port}`);
  console.log(`Caddy:       ${config.live ? "🟢 live" : "🚧 maintenance"}`);
  console.log(`Systemd:     ${systemdActive ? "🟢 active" : "🔴 inactive"}`);

  // Get current commit
  try {
    const result = await $`cd /srv/${serviceName} && git log -1 --format="%h %s" 2>/dev/null`.text();
    console.log(`Last commit: ${result.trim()}`);
  } catch {
    console.log(`Last commit: unknown`);
  }

  console.log(``);
}

async function rollback(serviceName: string, serverFolder?: string, withDb = false): Promise<void> {
  const folder = serverFolder || serviceName;
  const servicePath = `/srv/${folder}`;

  console.log(`\n⏪ Rolling back ${serviceName}${withDb ? " (code + database)" : ""}...\n`);

  // Get current and previous commit for display
  const currentCommit = await $`cd ${servicePath} && git log -1 --format="%h %s"`.text();
  console.log(`Current: ${currentCommit.trim()}`);

  try {
    const prevCommit = await $`cd ${servicePath} && git log -2 --format="%h %s" | tail -1`.text();
    console.log(`Rolling back to: ${prevCommit.trim()}`);
  } catch {
    // ignore
  }

  // Maintenance mode ON
  console.log(`\n🚧 Enabling maintenance mode...`);
  await setMaintenance(serviceName, true);

  try {
    // Stop before touching code or database
    console.log(`⏸  Stopping service...`);
    criticalSection = "rollback";
    await $`sudo systemctl stop ${folder}`;

    // Reset to previous commit
    console.log(`📥 Reverting to previous commit...`);
    await $`cd ${servicePath} && sudo -u ${folder} git reset --hard HEAD~1`;

    // Reinstall deps for the reverted code
    const installCmd = await detectInstallCmd(servicePath);
    if (installCmd) {
      try {
        await runInstall(folder, servicePath, installCmd);
      } catch {
        console.error(`⚠️  Reinstall failed — continuing rollback`);
      }
    }

    // Restore database backup if requested
    if (withDb) {
      const cfg = await readDeployConfig(servicePath);
      if (!cfg.database) {
        throw new Error(`--db requested but deploy.json has no "database" block`);
      }
      const file = `${servicePath}/${cfg.database.path}`;
      console.log(`⏪ Restoring database from backup.1...`);
      await asUser(
        folder,
        `test -f '${file}.backup.1' && cp '${file}.backup.1' '${file}' && rm -f '${file}-wal' '${file}-shm'`
      );
      // Don't silently put back something broken
      await $`sudo -u ${folder} bun ${DB_TOOL} integrity ${file}`;
    }

    // Restart
    console.log(`🔄 Restarting service...`);
    await $`sudo systemctl restart ${folder}`;

    // Health check (note: rollback doesn't support custom health check)
    const services = await loadServices();
    const port = services[serviceName].port;
    const healthy = await waitForHealthy(folder, port);

    if (!healthy) {
      throw new Error(`Service failed to become healthy after rollback`);
    }

    // Maintenance mode OFF
    console.log(`🟢 Disabling maintenance mode...`);
    await setMaintenance(serviceName, false);
    criticalSection = "";

    console.log(`\n✅ Rollback successful!\n`);
  } catch (error) {
    console.error(`\n❌ Rollback failed: ${error}`);
    console.error(`⚠️  Service is still in maintenance mode. Manual intervention required.\n`);
    process.exit(1);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  installSignalGuard();
  const args = process.argv.slice(2);
  const serviceName = args.find(a => !a.startsWith("--"));
  const command = args.find(a => a === "--status" || a === "--rollback");
  const withDb = args.includes("--db");

  // Extract health check command if provided
  const healthCheckIndex = args.indexOf("--health-check");
  const healthCheckCmd = healthCheckIndex >= 0 && args[healthCheckIndex + 1]
    ? args[healthCheckIndex + 1]
    : undefined;

  // Extract folder override if provided (when server folder differs from service name)
  const folderIndex = args.indexOf("--folder");
  const serverFolder = folderIndex >= 0 && args[folderIndex + 1]
    ? args[folderIndex + 1]
    : undefined;

  if (!serviceName) {
    console.error(
      "Usage: bun deploy.ts <service-name> [--db] [--folder <dir>] [--status|--rollback|--health-check '<command>']"
    );
    process.exit(1);
  }

  switch (command) {
    case "--status":
      await status(serviceName, serverFolder);
      break;
    case "--rollback":
      await rollback(serviceName, serverFolder, withDb);
      break;
    default:
      await deploy(serviceName, healthCheckCmd, serverFolder, withDb);
  }
}

main();
