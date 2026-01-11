#!/usr/bin/env bun
/**
 * Server-side deployment script
 * 
 * Usage:
 *   bun deploy.ts <service-name>           # Full deploy
 *   bun deploy.ts <service-name> --status  # Check service status
 *   bun deploy.ts <service-name> --rollback # Rollback to previous commit
 */

import { $ } from "bun";

const SCRIPT_DIR = import.meta.dir;
const SERVICES_FILE = `${SCRIPT_DIR}/services.json`;
const CADDY_DIR = SCRIPT_DIR; // generate.ts is in same directory

interface ServiceConfig {
  port: number;
  live: boolean;
  stripPath?: boolean;
}

type Services = Record<string, ServiceConfig>;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

async function loadServices(): Promise<Services> {
  const file = Bun.file(SERVICES_FILE);
  if (!(await file.exists())) {
    throw new Error(`${SERVICES_FILE} not found`);
  }
  return file.json();
}

async function saveServices(services: Services): Promise<void> {
  const content = JSON.stringify(services, null, 2) + "\n";
  const tempFile = "/tmp/services.json.new";
  await Bun.write(tempFile, content);
  await $`cat ${tempFile} | sudo tee ${SERVICES_FILE} > /dev/null`;
  await $`rm ${tempFile}`;
}

async function setMaintenance(serviceName: string, enabled: boolean): Promise<void> {
  const services = await loadServices();
  
  if (!services[serviceName]) {
    throw new Error(`Service '${serviceName}' not found in services.json`);
  }
  
  services[serviceName].live = !enabled;
  await saveServices(services);
  
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

async function waitForHealthy(serviceName: string, port: number, maxAttempts = 10): Promise<boolean> {
  console.log(`⏳ Waiting for service to be healthy...`);
  
  for (let i = 0; i < maxAttempts; i++) {
    try {
      // Simple TCP check - just see if port is listening
      await $`nc -z localhost ${port}`.quiet();
      return true;
    } catch {
      await Bun.sleep(1000);
    }
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Commands
// ─────────────────────────────────────────────────────────────────────────────

async function deploy(serviceName: string): Promise<void> {
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
    
    // Step 3: Restart service
    console.log(`🔄 Restarting service...`);
    await $`sudo systemctl restart ${serviceName}`;
    
    // Step 4: Health check
    const healthy = await waitForHealthy(serviceName, port);
    if (!healthy) {
      throw new Error(`Service failed to become healthy on port ${port}`);
    }
    console.log(`✅ Service is healthy`);
    
    // Step 5: Maintenance mode OFF
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
    
    // Health check
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
  const command = args.find(a => a.startsWith("--"));
  
  if (!serviceName) {
    console.error("Usage: bun deploy.ts <service-name> [--status|--rollback]");
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
      await deploy(serviceName);
  }
}

main();
