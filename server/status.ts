#!/usr/bin/env bun
/**
 * Service Status Checker
 *
 * Provides comprehensive status for all services:
 * - Configuration (port, routing)
 * - Systemd status (running/stopped)
 * - Port availability (listening)
 * - HTTP health (responding)
 *
 * Usage:
 *   bun status.ts              # Show all services
 *   bun status.ts my-service   # Show specific service
 *   bun status.ts --json       # JSON output
 */

import { $ } from "bun";

const SCRIPT_DIR = import.meta.dir;
const SERVICES_STRUCTURE_FILE = `${SCRIPT_DIR}/services.json`;
const SERVICES_STATE_FILE = `${SCRIPT_DIR}/services-state.json`;
const DOMAIN = "app.swedenindoorgolf.se";

// Structure: port, stripPath (tracked in git)
interface ServiceStructure {
  port: number;
  stripPath?: boolean;
  description?: string;
  healthCheckPath?: string; // optional path for HTTP health check (e.g., "/health" or "/status.html")
}

// State: live/maintenance (server-only)
interface ServiceState {
  live: boolean;
}

// Combined
interface ServiceConfig extends ServiceStructure {
  live: boolean;
}

interface ServiceStatus {
  name: string;
  port: number;
  stripPath: boolean;
  config: "live" | "maintenance";
  systemd: "active" | "inactive" | "failed" | "unknown";
  systemdUnit?: string; // The actual systemd unit name found
  portOpen: boolean;
  httpOk: boolean;
  httpStatus?: number;
  url: string;
}

type ServicesStructure = Record<string, ServiceStructure>;
type ServicesState = Record<string, ServiceState>;
type Services = Record<string, ServiceConfig>;

// ─────────────────────────────────────────────────────────────────────────────
// Service Loading (same as generate.ts and deploy.ts)
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
    return {};
  }
  return file.json();
}

async function loadServices(): Promise<Services> {
  const structure = await loadServicesStructure();
  const state = await loadServicesState();

  const merged: Services = {};
  for (const [name, config] of Object.entries(structure)) {
    merged[name] = {
      ...config,
      live: state[name]?.live ?? true,
    };
  }

  return merged;
}

// ─────────────────────────────────────────────────────────────────────────────
// Status Checks
// ─────────────────────────────────────────────────────────────────────────────

async function checkSystemdStatus(
  serviceName: string
): Promise<{ status: string; unit?: string }> {
  // Try multiple naming patterns to find the actual systemd unit.
  // The first pattern whose unit FILE exists wins, regardless of its active
  // state — a failed/inactive exact-match unit must not fall through to an
  // unrelated pattern.
  const patterns = [
    serviceName, // exact match (e.g., "golf-serie")
    `sig-${serviceName}`, // sig- prefix (e.g., "sig-gsp")
    `${serviceName}-server`, // -server suffix (e.g., "golf-improver-server")
    `${serviceName.replace(/s$/, "")}-calculator`, // singular + calculator (e.g., "booking-calculator" from "bookings")
    `sig-${serviceName.replace(/s$/, "")}`, // sig- prefix with singular (e.g., "sig-booking" from "bookings")
    ...(serviceName === "mycal" ? ["gsp-calculator"] : []), // mycal → gsp-calculator mapping
  ];

  for (const pattern of patterns) {
    // Does the unit file exist? (LoadState is "loaded" for real units,
    // "not-found" otherwise; systemctl show exits 0 either way on most
    // systemd versions, so also treat a thrown error as not-found.)
    let loadState: string;
    try {
      loadState = (
        await $`systemctl show -p LoadState --value ${pattern}`.quiet()
      )
        .text()
        .trim();
    } catch {
      loadState = "not-found";
    }
    if (loadState !== "loaded") continue;

    // Unit exists — report its actual state. is-active exits non-zero for
    // anything but "active", so never let that throw skip the unit.
    let state: string;
    try {
      state = (await $`systemctl is-active ${pattern}`.quiet()).text().trim();
    } catch (err: any) {
      state = (err?.stdout?.toString?.() ?? "").trim() || "unknown";
    }
    if (state === "active" || state === "inactive" || state === "failed") {
      return { status: state, unit: pattern };
    }
    // activating/deactivating/etc.
    return { status: "unknown", unit: pattern };
  }

  return { status: "unknown" };
}

async function checkPortOpen(port: number): Promise<boolean> {
  try {
    await $`nc -z -w1 localhost ${port}`.quiet();
    return true;
  } catch {
    return false;
  }
}

async function checkHttpHealth(
  serviceName: string,
  healthCheckPath?: string
): Promise<{ ok: boolean; status?: number }> {
  const path = healthCheckPath || "/";
  const url = `https://${DOMAIN}/${serviceName}${path}`;
  try {
    // Use curl with short timeout, follow redirects
    const result = await $`curl -f -s -o /dev/null -w '%{http_code}' --max-time 3 ${url}`.text();
    const status = parseInt(result.trim(), 10);
    return { ok: status >= 200 && status < 400, status };
  } catch {
    return { ok: false };
  }
}

async function getServiceStatus(
  name: string,
  config: ServiceConfig
): Promise<ServiceStatus> {
  const [systemdResult, portOpen, httpHealth] = await Promise.all([
    checkSystemdStatus(name),
    checkPortOpen(config.port),
    checkHttpHealth(name, config.healthCheckPath),
  ]);

  return {
    name,
    port: config.port,
    stripPath: config.stripPath !== false, // default true
    config: config.live ? "live" : "maintenance",
    systemd: systemdResult.status as ServiceStatus["systemd"],
    systemdUnit: systemdResult.unit,
    portOpen,
    httpOk: httpHealth.ok,
    httpStatus: httpHealth.status,
    url: `https://${DOMAIN}/${name}/`,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Output Formatting
// ─────────────────────────────────────────────────────────────────────────────

function getStatusIcon(status: ServiceStatus): string {
  // All checks must pass for green
  if (
    status.config === "live" &&
    status.systemd === "active" &&
    status.portOpen &&
    status.httpOk
  ) {
    return "🟢";
  }

  // Maintenance mode is expected state
  if (status.config === "maintenance") {
    return "🚧";
  }

  // Something is wrong
  return "🔴";
}

function formatStatus(status: ServiceStatus, showPort: boolean = false): string {
  const icon = getStatusIcon(status);
  const config = status.config === "live" ? "LIVE" : "MAINT";
  const systemd = status.systemd.toUpperCase().padEnd(8);
  const port = status.portOpen ? "✓" : "✗";
  const http = status.httpOk ? "✓" : "✗";
  const httpDetail = status.httpStatus ? ` (${status.httpStatus})` : "";

  if (showPort) {
    // Format: 🟢 service-name      3001  LIVE    ACTIVE   ✓     ✓ (200)
    return `${icon} ${status.name.padEnd(18)} ${String(status.port).padStart(4)}  ${config.padEnd(6)} ${systemd} ${port.padEnd(5)} ${http}${httpDetail}`;
  }

  return `${icon} ${status.name.padEnd(20)} ${config.padEnd(6)} ${systemd} Port:${port} HTTP:${http}${httpDetail}`;
}

function printStatusTable(statuses: ServiceStatus[]): void {
  console.log("\n╔══════════════════════════════════════════════════════════════════════════╗");
  console.log("║                          SERVICE STATUS                                  ║");
  console.log("╠══════════════════════════════════════════════════════════════════════════╣");
  console.log("║   SERVICE            PORT  CONFIG  SYSTEMD  PORT  HTTP                   ║");
  console.log("╟──────────────────────────────────────────────────────────────────────────╢");

  for (const status of statuses.sort((a, b) => a.name.localeCompare(b.name))) {
    console.log(`║ ${formatStatus(status, true).padEnd(72)} ║`);
  }

  console.log("╚══════════════════════════════════════════════════════════════════════════╝");

  // Summary
  const healthy = statuses.filter(
    (s) =>
      s.config === "live" &&
      s.systemd === "active" &&
      s.portOpen &&
      s.httpOk
  ).length;
  const maintenance = statuses.filter((s) => s.config === "maintenance").length;
  const issues = statuses.filter(
    (s) =>
      s.config === "live" &&
      (s.systemd !== "active" || !s.portOpen || !s.httpOk)
  ).length;

  console.log("");
  console.log(
    `Summary: ${healthy} healthy, ${maintenance} maintenance, ${issues} issues`
  );
  console.log("");

  // Show URLs for services with issues
  if (issues > 0) {
    console.log("Services with issues:");
    for (const status of statuses) {
      if (
        status.config === "live" &&
        (status.systemd !== "active" || !status.portOpen || !status.httpOk)
      ) {
        const problems = [];
        if (status.systemd !== "active")
          problems.push(`systemd: ${status.systemd}`);
        if (!status.portOpen) problems.push("port closed");
        if (!status.httpOk)
          problems.push(
            `http failed${status.httpStatus ? ` (${status.httpStatus})` : ""}`
          );
        const unitName = status.systemdUnit || status.name;
        console.log(`  - ${status.name}: ${problems.join(", ")}`);
        console.log(`    URL: ${status.url}`);
        console.log(`    Logs: sudo journalctl -u ${unitName} -n 20`);
      }
    }
    console.log("");
  }
}

function printDetailedStatus(status: ServiceStatus): void {
  console.log(`\nService: ${status.name}`);
  console.log("─".repeat(60));
  console.log(`URL:        ${status.url}`);
  console.log(`Port:       ${status.port}`);
  console.log(`Path Mode:  ${status.stripPath ? "handle_path (strips /${status.name}/)" : "handle (preserves path)"}`);
  console.log(`Config:     ${status.config === "live" ? "🟢 Live" : "🚧 Maintenance"}`);
  console.log(
    `Systemd:    ${status.systemd === "active" ? "🟢" : "🔴"} ${status.systemd}${status.systemdUnit && status.systemdUnit !== status.name ? ` (${status.systemdUnit})` : ""}`
  );
  console.log(
    `Port Open:  ${status.portOpen ? "🟢 Yes" : "🔴 No"} (nc -z localhost ${status.port})`
  );
  console.log(
    `HTTP OK:    ${status.httpOk ? "🟢 Yes" : "🔴 No"}${status.httpStatus ? ` (${status.httpStatus})` : ""}`
  );
  console.log("");

  // Suggest commands (use actual systemd unit name if different)
  const unitName = status.systemdUnit || status.name;
  if (status.systemd !== "active") {
    console.log("Commands:");
    console.log(`  sudo systemctl status ${unitName}`);
    console.log(`  sudo journalctl -u ${unitName} -n 50`);
    console.log(`  sudo systemctl restart ${unitName}`);
  } else if (!status.httpOk) {
    console.log("Debug:");
    console.log(`  curl -v ${status.url}`);
    console.log(`  curl -v http://localhost:${status.port}/`);
    console.log(`  sudo journalctl -u ${unitName} -n 20`);
  }
  console.log("");
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const jsonOutput = args.includes("--json");
  const serviceName = args.find((a) => !a.startsWith("--"));

  const services = await loadServices();

  if (serviceName) {
    // Show specific service
    if (!services[serviceName]) {
      console.error(`❌ Service '${serviceName}' not found`);
      process.exit(1);
    }

    const status = await getServiceStatus(serviceName, services[serviceName]);

    if (jsonOutput) {
      console.log(JSON.stringify(status, null, 2));
    } else {
      printDetailedStatus(status);
    }
  } else {
    // Show all services
    const statuses = await Promise.all(
      Object.entries(services).map(([name, config]) =>
        getServiceStatus(name, config)
      )
    );

    if (jsonOutput) {
      console.log(JSON.stringify(statuses, null, 2));
    } else {
      printStatusTable(statuses);
    }
  }
}

main();
