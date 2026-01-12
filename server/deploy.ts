#!/usr/bin/env bun
/**
 * Server-side deployment script
 *
 * Two-file architecture:
 * - services.json: Service structure (port, stripPath) - tracked in git
 * - services-state.json: Operational state (live/maintenance) - server-only
 *
 * Usage:
 *   bun deploy.ts <service-name>           # Full deploy
 *   bun deploy.ts <service-name> --status  # Check service status
 *   bun deploy.ts <service-name> --rollback # Rollback to previous commit
 *   bun deploy.ts <service-name> --health-check '<command>' # Deploy with custom health check
 */

import { $ } from "bun";

const SCRIPT_DIR = import.meta.dir;
const SERVICES_STRUCTURE_FILE = `${SCRIPT_DIR}/services.json`;
const SERVICES_STATE_FILE = `${SCRIPT_DIR}/services-state.json`;
const CADDY_DIR = SCRIPT_DIR; // generate.ts is in same directory

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

async function serviceExists(serviceName: string): Promise<boolean> {
  const services = await loadServices();
  return serviceName in services;
}

async function checkSystemdService(serviceName: string): Promise<boolean> {
  try {
    await $`systemctl is-active --quiet ${serviceName}`.quiet();
    return true;
  } catch {
    return false;
  }
}

async function waitForHealthy(
  serviceName: string,
  port: number,
  customHealthCheck?: string,
  maxAttempts = 10
): Promise<boolean> {
  console.log(`⏳ Waiting for service to be healthy...`);

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
      await Bun.sleep(1000);
    }
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Commands
// ─────────────────────────────────────────────────────────────────────────────

async function deploy(serviceName: string, healthCheckCmd?: string): Promise<void> {
  const servicePath = `/srv/${serviceName}`;

  // Validate
  console.log(`\n🚀 Deploying ${serviceName}...\n`);

  const services = await loadServices();
  if (!services[serviceName]) {
    console.error(`❌ Service '${serviceName}' not found in Caddy config`);
    console.error(`   Run: caddy_add ${serviceName} <port>`);
    process.exit(1);
  }

  const port = services[serviceName].port;

  // Load deploy.json if it exists
  let installCmd: string | undefined;
  const deployConfigPath = `${servicePath}/deploy.json`;
  try {
    const deployConfig = await Bun.file(deployConfigPath).json();
    installCmd = deployConfig.install;
    if (!healthCheckCmd && deployConfig.healthCheck) {
      healthCheckCmd = deployConfig.healthCheck;
    }
  } catch {
    // No deploy.json or invalid JSON - that's fine
  }

  // Auto-detect package manager if not explicitly set
  if (!installCmd) {
    if (await Bun.file(`${servicePath}/bun.lockb`).exists()) {
      installCmd = "bun install";
      console.log("📦 Auto-detected: bun (bun.lockb found)");
    } else if (await Bun.file(`${servicePath}/pnpm-lock.yaml`).exists()) {
      installCmd = "pnpm install";
      console.log("📦 Auto-detected: pnpm (pnpm-lock.yaml found)");
    } else if (await Bun.file(`${servicePath}/yarn.lock`).exists()) {
      installCmd = "yarn install";
      console.log("📦 Auto-detected: yarn (yarn.lock found)");
    } else if (await Bun.file(`${servicePath}/package-lock.json`).exists()) {
      installCmd = "npm install";
      console.log("📦 Auto-detected: npm (package-lock.json found)");
    }
    // If no lockfile found, installCmd remains undefined (no install step)
  }

  // Check service directory exists
  const dirExists = await Bun.file(servicePath).exists().catch(() => false);
  if (!dirExists) {
    try {
      await $`test -d ${servicePath}`.quiet();
    } catch {
      console.error(`❌ Service directory not found: ${servicePath}`);
      process.exit(1);
    }
  }
  
  // Step 1: Maintenance mode ON
  console.log(`🚧 Enabling maintenance mode...`);
  await setMaintenance(serviceName, true);
  
  try {
    // Step 2: Git pull
    console.log(`📥 Pulling latest changes...`);
    await $`cd ${servicePath} && sudo -u ${serviceName} git pull`;

    // Step 3: Install dependencies (if configured)
    if (installCmd) {
      console.log(`📦 Installing dependencies: ${installCmd}`);
      // Use bash -c to ensure proper PATH and environment
      // Timeout after 30 seconds - bun install sometimes hangs at the end even when done
      try {
        await $`cd ${servicePath} && timeout 30 sudo -u ${serviceName} bash -c '${installCmd}'`;
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

    // Step 4: Restart service
    console.log(`🔄 Restarting service...`);
    await $`sudo systemctl restart ${serviceName}`;

    // Step 5: Health check
    const healthy = await waitForHealthy(serviceName, port, healthCheckCmd);
    if (!healthy) {
      throw new Error(`Service failed to become healthy on port ${port}`);
    }
    console.log(`✅ Service is healthy`);

    // Step 6: Maintenance mode OFF
    console.log(`🟢 Disabling maintenance mode...`);
    await setMaintenance(serviceName, false);

    console.log(`\n✅ Deployment successful!\n`);
    
  } catch (error) {
    console.error(`\n❌ Deployment failed: ${error}`);
    console.error(`\n⚠️  Service is still in maintenance mode!`);
    console.error(`   Fix the issue and run: bun deploy.ts ${serviceName}`);
    console.error(`   Or restore with: bun deploy.ts ${serviceName} --rollback`);
    console.error(`   Or manually: app_maint ${serviceName}\n`);
    process.exit(1);
  }
}

async function status(serviceName: string): Promise<void> {
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

async function rollback(serviceName: string): Promise<void> {
  const servicePath = `/srv/${serviceName}`;
  
  console.log(`\n⏪ Rolling back ${serviceName}...\n`);
  
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
    // Reset to previous commit
    console.log(`📥 Reverting to previous commit...`);
    await $`cd ${servicePath} && sudo -u ${serviceName} git reset --hard HEAD~1`;
    
    // Restart
    console.log(`🔄 Restarting service...`);
    await $`sudo systemctl restart ${serviceName}`;
    
    // Health check (note: rollback doesn't support custom health check)
    const services = await loadServices();
    const port = services[serviceName].port;
    const healthy = await waitForHealthy(serviceName, port);

    if (!healthy) {
      throw new Error(`Service failed to become healthy after rollback`);
    }
    
    // Maintenance mode OFF
    console.log(`🟢 Disabling maintenance mode...`);
    await setMaintenance(serviceName, false);
    
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
  const args = process.argv.slice(2);
  const serviceName = args.find(a => !a.startsWith("--"));
  const command = args.find(a => a.startsWith("--") && !a.includes("--health-check"));

  // Extract health check command if provided
  const healthCheckIndex = args.indexOf("--health-check");
  const healthCheckCmd = healthCheckIndex >= 0 && args[healthCheckIndex + 1]
    ? args[healthCheckIndex + 1]
    : undefined;

  if (!serviceName) {
    console.error("Usage: bun deploy.ts <service-name> [--status|--rollback|--health-check '<command>']");
    process.exit(1);
  }

  switch (command) {
    case "--status":
      await status(serviceName);
      break;
    case "--rollback":
      await rollback(serviceName);
      break;
    default:
      await deploy(serviceName, healthCheckCmd);
  }
}

main();
