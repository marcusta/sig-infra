#!/usr/bin/env zsh
# =============================================================================
# sig-infra shell functions
# Source this from ~/.zshrc:
#   source ~/projects/sig-infra/shell/functions.zsh
# =============================================================================

# Configuration
SIG_SERVER="marcus@app.swedenindoorgolf.se"
SIG_INFRA_LOCAL="${0:A:h:h}"  # Parent of shell/ directory (where this file lives)
SIG_INFRA_REMOTE="/srv/infra"

# =============================================================================
# Infrastructure Management
# =============================================================================

infra_push() {
  local msg="${1:-update}"
  
  echo "📤 Pushing infrastructure changes..."
  cd "$SIG_INFRA_LOCAL" || { echo "❌ Can't find $SIG_INFRA_LOCAL"; return 1; }
  
  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    git add -A
    git commit -m "$msg"
  fi
  
  git push origin main || { echo "❌ Push failed"; return 1; }
  
  echo "🔄 Updating server..."
  ssh $SIG_SERVER "cd $SIG_INFRA_REMOTE && git pull"
  
  echo "✅ Infrastructure updated"
}

infra_pull() {
  echo "📥 Pulling infrastructure changes..."
  cd "$SIG_INFRA_LOCAL" || { echo "❌ Can't find $SIG_INFRA_LOCAL"; return 1; }
  git pull origin main
  echo "✅ Local infrastructure updated"
}

infra_pull_remote() {
  echo "📥 Pulling infrastructure changes on server..."
  ssh $SIG_SERVER "cd $SIG_INFRA_REMOTE && git pull"
  echo "✅ Server infrastructure updated"
}

infra_status() {
  echo "Local ($SIG_INFRA_LOCAL):"
  cd "$SIG_INFRA_LOCAL" && git status -s
  echo ""
  echo "Server ($SIG_INFRA_REMOTE):"
  ssh $SIG_SERVER "cd $SIG_INFRA_REMOTE && git log -1 --format='  %h %s (%cr)'"
}

# =============================================================================
# Service Setup
# =============================================================================

service_create() {
  local service_name repo_name nice_service_name start_command port

  echo "🔧 Service Setup Wizard"
  echo "─────────────────────────────────────────"
  echo ""

  # Gather inputs locally
  read -r "service_name?Service name (default: current directory): "
  service_name=${service_name:-$(basename "$PWD")}

  read -r "repo_name?GitHub repo name (default: ${service_name}): "
  repo_name=${repo_name:-$service_name}

  read -r "nice_service_name?Service description (default: ${service_name} Service): "
  nice_service_name=${nice_service_name:-"${service_name} Service"}

  read -r "start_command?Start command (default: /usr/local/bin/bun ./src/server.ts): "
  start_command=${start_command:-"/usr/local/bin/bun ./src/server.ts"}

  read -r "port?Port number: "
  if [[ -z "$port" ]]; then
    echo "❌ Port number is required"
    return 1
  fi

  # Confirm
  echo ""
  echo "Creating service with the following configuration:"
  echo "─────────────────────────────────────────"
  echo "  Service name:  $service_name"
  echo "  Repository:    marcusta/$repo_name"
  echo "  Description:   $nice_service_name"
  echo "  Start command: $start_command"
  echo "  Port:          $port"
  echo "  Working dir:   /srv/${service_name}"
  echo "─────────────────────────────────────────"
  echo ""
  read -r "confirm?Proceed? (y/n): "
  [[ "$confirm" != "y" ]] && { echo "Cancelled."; return 0; }

  echo ""
  echo "🚀 Creating service on server..."
  echo ""

  # Execute on server - using a temporary script approach to avoid heredoc nesting
  local setup_script="/tmp/setup-${service_name}.sh"

  # Create the setup script content locally
  cat > /tmp/local-setup.sh <<'OUTER_EOF'
#!/bin/bash
set -e

SERVICE_NAME="$1"
REPO_NAME="$2"
NICE_NAME="$3"
START_CMD="$4"

echo "📦 Creating system user..."
sudo adduser --system --no-create-home --group "$SERVICE_NAME"

echo "📥 Cloning repository..."
sudo git clone "https://github.com/marcusta/${REPO_NAME}.git" "/srv/${SERVICE_NAME}"

echo "🔑 Setting ownership..."
sudo chown -R "${SERVICE_NAME}:${SERVICE_NAME}" "/srv/${SERVICE_NAME}"

echo "⚙️  Creating systemd service..."
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOL
[Unit]
Description=${NICE_NAME}
After=network.target

[Service]
ExecStart=${START_CMD}
WorkingDirectory=/srv/${SERVICE_NAME}
Restart=always
User=${SERVICE_NAME}
Group=${SERVICE_NAME}
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOL

echo "✅ Enabling systemd service..."
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.service"

echo ""
echo "✅ Service ${SERVICE_NAME} created successfully!"
echo ""
echo "Management commands:"
echo "  Start:   sudo systemctl start ${SERVICE_NAME}"
echo "  Stop:    sudo systemctl stop ${SERVICE_NAME}"
echo "  Restart: sudo systemctl restart ${SERVICE_NAME}"
echo "  Logs:    sudo journalctl -u ${SERVICE_NAME} -f"
OUTER_EOF

  # Copy script to server and execute
  scp -q /tmp/local-setup.sh $SIG_SERVER:/tmp/setup-service.sh
  ssh -t $SIG_SERVER "bash /tmp/setup-service.sh '$service_name' '$repo_name' '$nice_service_name' '$start_command' && rm /tmp/setup-service.sh"

  local ssh_exit=$?
  rm /tmp/local-setup.sh

  if [[ $ssh_exit -ne 0 ]]; then
    echo "❌ Service creation failed"
    return 1
  fi

  echo ""
  echo "🌐 Adding to Caddy..."
  caddy_add "$service_name" "$port"

  echo ""
  echo "✅ Complete! Service is ready."
  echo ""
  echo "Next steps:"
  echo "  1. Start the service: ssh $SIG_SERVER 'sudo systemctl start $service_name'"
  echo "  2. Deploy updates:    cd ~/projects/$service_name && deploy"
}

# =============================================================================
# Caddy Management
# =============================================================================

caddy_list() {
  ssh $SIG_SERVER "cd $SIG_INFRA_REMOTE/server && bun status.ts"
}

caddy_status() {
  local service_name=$1

  if [[ -z "$service_name" ]]; then
    # No service specified, show all
    caddy_list
  else
    # Show specific service
    ssh $SIG_SERVER "cd $SIG_INFRA_REMOTE/server && bun status.ts $service_name"
  fi
}

caddy_view() {
  ssh $SIG_SERVER "cat /srv/caddy/config/Caddyfile"
}

caddy_add() {
  local path_segment=$1
  local port=$2

  if [[ -z "$path_segment" || -z "$port" ]]; then
    echo "Usage: caddy_add <service-name> <port>"
    echo "Example: caddy_add my-api 3005"
    return 1
  fi

  # Strip leading slash if present
  path_segment="${path_segment#/}"

  echo "🔧 Adding $path_segment to Caddy routing (GitOps mode)..."

  # Navigate to infra repo
  cd "$SIG_INFRA_LOCAL" || { echo "❌ Can't find $SIG_INFRA_LOCAL"; return 1; }

  # Check if service already exists
  if jq -e ".[\"$path_segment\"]" server/services.json > /dev/null 2>&1; then
    echo "❌ Service '$path_segment' already exists"
    return 1
  fi

  # Check if port is already in use
  if jq -e ".[] | select(.port == $port)" server/services.json > /dev/null 2>&1; then
    echo "❌ Port $port already in use"
    return 1
  fi

  # Add service to services.json using jq
  jq ". + {\"$path_segment\": {\"port\": $port}}" server/services.json > server/services.json.tmp
  mv server/services.json.tmp server/services.json

  # Commit and push
  git add server/services.json
  git commit -m "Add $path_segment to Caddy (port $port)"
  git push origin main || { echo "❌ Push failed"; return 1; }

  # Pull on server and regenerate
  echo "🔄 Updating server..."
  ssh -t $SIG_SERVER "cd $SIG_INFRA_REMOTE && git pull && cd server && bun generate.ts"

  echo "✅ $path_segment added successfully"
}

caddy_remove() {
  local service_name=$1

  if [[ -z "$service_name" ]]; then
    echo "Usage: caddy_remove <service-name>"
    return 1
  fi

  service_name="${service_name#/}"

  read -r "confirm?Remove $service_name from Caddy? (y/n): "
  [[ "$confirm" != "y" ]] && { echo "Cancelled."; return 0; }

  echo "🔧 Removing $service_name from Caddy routing (GitOps mode)..."

  # Navigate to infra repo
  cd "$SIG_INFRA_LOCAL" || { echo "❌ Can't find $SIG_INFRA_LOCAL"; return 1; }

  # Check if service exists
  if ! jq -e ".[\"$service_name\"]" server/services.json > /dev/null 2>&1; then
    echo "❌ Service '$service_name' not found"
    return 1
  fi

  # Remove service from services.json using jq
  jq "del(.[\"$service_name\"])" server/services.json > server/services.json.tmp
  mv server/services.json.tmp server/services.json

  # Commit and push
  git add server/services.json
  git commit -m "Remove $service_name from Caddy"
  git push origin main || { echo "❌ Push failed"; return 1; }

  # Pull on server and regenerate (also cleans up state file)
  echo "🔄 Updating server..."
  ssh -t $SIG_SERVER "cd $SIG_INFRA_REMOTE && git pull && cd server && bun generate.ts"

  echo "✅ $service_name removed successfully"
}

caddy_regen() {
  local dry_run=""
  [[ "$1" == "--dry-run" ]] && dry_run="--dry-run"
  
  ssh -t $SIG_SERVER "cd $SIG_INFRA_REMOTE/server && bun generate.ts $dry_run"
}

# =============================================================================
# Maintenance Mode
# =============================================================================

app_maint() {
  local service_name=$1
  local dry_run=""

  if [[ "$1" == "--dry-run" ]]; then
    dry_run="--dry-run"
    service_name=$2
  fi

  # Interactive mode if no service specified
  if [[ -z "$service_name" ]]; then
    echo "🔍 Fetching services..."
    # Use a temporary script on server to merge structure + state
    local selection=$(ssh $SIG_SERVER "cd $SIG_INFRA_REMOTE/server && bun -e '
      const structure = await Bun.file(\"services.json\").json();
      const state = await Bun.file(\"services-state.json\").exists()
        ? await Bun.file(\"services-state.json\").json()
        : {};

      for (const [name, config] of Object.entries(structure).sort()) {
        const live = state[name]?.live ?? true;
        const status = live ? \"🟢 LIVE \" : \"🚧 MAINT\";
        console.log(\`\${status}  \${name}\`);
      }
    '" | fzf --header "Select service to toggle" --reverse)

    [[ -z "$selection" ]] && { echo "Cancelled."; return 0; }
    service_name=$(echo "$selection" | awk '{print $NF}')
  fi

  # Strip leading slash if present
  service_name="${service_name#/}"

  ssh -t $SIG_SERVER "cd $SIG_INFRA_REMOTE/server && bun generate.ts $dry_run maint $service_name"
}

# =============================================================================
# Deployment
# =============================================================================

# NOTE: The database migration workflow runs server-side in server/deploy.ts
# (snapshot → migrate → validate → backup → swap). Nothing DB-related happens
# on the local machine during a deploy anymore.

deploy_preflight() {
  local service_name=$(basename "$PWD")
  local server_folder="$service_name"
  local errors=0
  local warnings=0

  # Override service name and server folder from deploy.json if present
  # serviceName overrides only the services.json key / systemd unit
  # serverFolder overrides only the /srv/ directory (defaults to local folder name)
  if [[ -f "deploy.json" ]]; then
    local name_override=$(jq -r '.serviceName // empty' deploy.json 2>/dev/null)
    if [[ -n "$name_override" ]]; then
      service_name="$name_override"
    fi
    local folder_override=$(jq -r '.serverFolder // empty' deploy.json 2>/dev/null)
    if [[ -n "$folder_override" ]]; then
      server_folder="$folder_override"
    fi
  fi

  echo "🔍 Preflight check: $service_name (folder: $server_folder)"
  echo "────────────────────────────────────────"

  # 1. deploy.json exists and is valid JSON
  if [[ ! -f "deploy.json" ]]; then
    echo "❌ deploy.json not found"
    ((errors++))
    echo "────────────────────────────────────────"
    echo "❌ $errors error(s) — fix before deploying"
    return 1
  fi

  if ! jq empty deploy.json 2>/dev/null; then
    echo "❌ deploy.json is not valid JSON"
    ((errors++))
    echo "────────────────────────────────────────"
    echo "❌ $errors error(s) — fix before deploying"
    return 1
  fi
  echo "✅ deploy.json valid"

  # 2. Database section checks (if present)
  local db_path=$(jq -r '.database.path // empty' deploy.json)
  if [[ -n "$db_path" ]]; then
    echo "✅ database.path: $db_path"

    local db_migrate=$(jq -r '.database.migrate // empty' deploy.json)
    local db_validate=$(jq -r '.database.validate // empty' deploy.json)

    if [[ -z "$db_migrate" ]]; then
      echo "❌ database.migrate not defined"
      ((errors++))
    fi
    if [[ -z "$db_validate" ]]; then
      echo "❌ database.validate not defined"
      ((errors++))
    fi

    # 3. Migration/validation scripts exist locally
    # Skip file check for "bun run X" / "npm run X" style commands (validated via package.json in check 4)
    if [[ -n "$db_migrate" ]]; then
      if echo "$db_migrate" | grep -qE '^(bun|npm|npx|pnpm|yarn) run '; then
        echo "✅ migrate command: $db_migrate (package.json script)"
      else
        local migrate_script=$(echo "$db_migrate" | sed -E 's/^[^ ]+ +//' | sed 's/ .*//')
        migrate_script=${migrate_script#./}
        if [[ -f "$migrate_script" ]]; then
          echo "✅ $migrate_script exists"
        else
          echo "❌ $migrate_script not found"
          ((errors++))
        fi
      fi
    fi

    if [[ -n "$db_validate" ]]; then
      if echo "$db_validate" | grep -qE '^(bun|npm|npx|pnpm|yarn) run '; then
        echo "✅ validate command: $db_validate (package.json script)"
      else
        local validate_script=$(echo "$db_validate" | sed -E 's/^[^ ]+ +//' | sed 's/ .*//')
        validate_script=${validate_script#./}
        if [[ -f "$validate_script" ]]; then
          echo "✅ $validate_script exists"
        else
          echo "❌ $validate_script not found"
          ((errors++))
        fi
      fi
    fi

    # 3b. Verify scripts reference DB_PATH env var
    # Resolve actual script files to check for DB_PATH usage
    local migrate_file=""
    local validate_file=""

    if [[ -n "$db_migrate" ]]; then
      if echo "$db_migrate" | grep -qE '^(bun|npm|npx|pnpm|yarn) run '; then
        # Resolve from package.json: "bun run db:migrate" → look up scripts.db:migrate
        local script_name=$(echo "$db_migrate" | sed -E 's/^[^ ]+ run //')
        local resolved=$(jq -r ".scripts[\"$script_name\"] // empty" package.json 2>/dev/null)
        if [[ -n "$resolved" ]]; then
          migrate_file=$(echo "$resolved" | sed -E 's/^[^ ]+ +//' | sed 's/ .*//')
          migrate_file=${migrate_file#./}
        fi
      else
        migrate_file=$(echo "$db_migrate" | sed -E 's/^[^ ]+ +//' | sed 's/ .*//')
        migrate_file=${migrate_file#./}
      fi
    fi

    if [[ -n "$db_validate" ]]; then
      if echo "$db_validate" | grep -qE '^(bun|npm|npx|pnpm|yarn) run '; then
        local script_name=$(echo "$db_validate" | sed -E 's/^[^ ]+ run //')
        local resolved=$(jq -r ".scripts[\"$script_name\"] // empty" package.json 2>/dev/null)
        if [[ -n "$resolved" ]]; then
          validate_file=$(echo "$resolved" | sed -E 's/^[^ ]+ +//' | sed 's/ .*//')
          validate_file=${validate_file#./}
        fi
      else
        validate_file=$(echo "$db_validate" | sed -E 's/^[^ ]+ +//' | sed 's/ .*//')
        validate_file=${validate_file#./}
      fi
    fi

    if [[ -n "$migrate_file" && -f "$migrate_file" ]]; then
      if grep -q "DB_PATH" "$migrate_file"; then
        echo "✅ $migrate_file reads DB_PATH env var"
      else
        echo "❌ $migrate_file does not reference DB_PATH — migration will use wrong database"
        ((errors++))
      fi
    fi

    if [[ -n "$validate_file" && -f "$validate_file" ]]; then
      if grep -q "DB_PATH" "$validate_file"; then
        echo "✅ $validate_file reads DB_PATH env var"
      else
        echo "❌ $validate_file does not reference DB_PATH — validation will use wrong database"
        ((errors++))
      fi
    fi

    # 4. package.json scripts defined
    if [[ -f "package.json" ]]; then
      if jq -e '.scripts["db:migrate"]' package.json >/dev/null 2>&1; then
        echo "✅ package.json has db:migrate script"
      else
        echo "❌ package.json missing db:migrate script"
        ((errors++))
      fi
      if jq -e '.scripts["db:health"]' package.json >/dev/null 2>&1; then
        echo "✅ package.json has db:health script"
      else
        echo "❌ package.json missing db:health script"
        ((errors++))
      fi
    else
      echo "❌ package.json not found"
      ((errors++))
    fi

    # 5. Remote database file exists
    if ssh $SIG_SERVER "test -f /srv/$server_folder/$db_path" 2>/dev/null; then
      echo "✅ Remote DB exists: /srv/$server_folder/$db_path"
    else
      echo "❌ Remote DB not found at /srv/$server_folder/$db_path"
      ((errors++))
    fi
  fi

  # 6. Remote service directory exists
  if ssh $SIG_SERVER "test -d /srv/$server_folder" 2>/dev/null; then
    echo "✅ Remote service directory exists"
  else
    echo "❌ Remote service directory /srv/$server_folder not found"
    ((errors++))
  fi

  # 7. Remote systemd unit exists
  local systemd_status=$(ssh $SIG_SERVER "systemctl is-active $service_name 2>/dev/null" 2>/dev/null)
  if [[ -n "$systemd_status" && "$systemd_status" != "unknown" ]]; then
    echo "✅ Systemd unit: $systemd_status"
  else
    echo "❌ Systemd unit not found for $service_name"
    ((errors++))
  fi

  # 8. Service exists in services.json
  if ssh $SIG_SERVER "jq -e '.[\"$service_name\"]' $SIG_INFRA_REMOTE/server/services.json" >/dev/null 2>&1; then
    echo "✅ Service registered in services.json"
  else
    echo "❌ Service not found in services.json"
    ((errors++))
  fi

  # 9. .gitignore includes deploy-tmp/
  if [[ -f ".gitignore" ]] && grep -q "deploy-tmp" .gitignore 2>/dev/null; then
    echo "✅ .gitignore includes deploy-tmp/"
  else
    echo "⚠️  .gitignore missing deploy-tmp/"
    ((warnings++))
  fi

  # 10. healthCheck syntax (if present)
  local health_check=$(jq -r '.healthCheck // empty' deploy.json)
  if [[ -n "$health_check" ]]; then
    if echo "$health_check" | grep -qE '^curl\s'; then
      echo "✅ healthCheck: $health_check"
    else
      echo "⚠️  healthCheck doesn't start with curl — may not work as expected"
      ((warnings++))
    fi
  fi

  echo "────────────────────────────────────────"
  if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
    echo "✅ All checks passed — ready to deploy"
  elif [[ $errors -eq 0 ]]; then
    echo "✅ All checks passed ($warnings warning(s)) — ready to deploy"
  else
    echo "❌ $errors error(s), $warnings warning(s) — fix before deploying"
    return 1
  fi
}

# Print deploy usage / help
_deploy_usage() {
  cat <<'EOF'
Usage: deploy <mode>

A mode is required — bare `deploy` does nothing but print this help.

Modes:
  --no-db    Code-only deploy. Skips the database workflow entirely.
             Use when no schema change.
  --db       Full deploy WITH database migration. Runs ON THE SERVER:
             stop service → snapshot (VACUUM INTO) → migrate → validate
             → backup → swap (+ clear WAL/SHM sidecars) → start.
             Use when this deploy adds or changes migrations.
  --auto     Detect: if migration files changed since the deployed commit,
             run --db; otherwise --no-db. Needs "database.migrationsDir" in deploy.json.
  --help     Show this help.

Tip: run `deploy_check` first to see whether the next deploy needs --db or --no-db.
EOF
}

# Determine whether migration files changed vs the commit currently deployed on the server.
# Args: <server_folder> <migrations_dir>
# Return: 0 = changed, 1 = unchanged, 2 = unknown (no dir / server unreachable / commit missing)
_deploy_migrations_changed() {
  local server_folder=$1 migrations_dir=$2
  [[ -z "$migrations_dir" ]] && return 2

  local remote_commit
  remote_commit=$(ssh -o ConnectTimeout=5 $SIG_SERVER \
    "sudo -u $server_folder git -C /srv/$server_folder rev-parse HEAD" 2>/dev/null)
  [[ -z "$remote_commit" ]] && return 2

  # Ensure the deployed commit exists locally (fetch once if not)
  git cat-file -e "${remote_commit}^{commit}" 2>/dev/null || git fetch -q origin 2>/dev/null
  git cat-file -e "${remote_commit}^{commit}" 2>/dev/null || return 2

  # Committed-but-not-yet-deployed migration changes...
  local committed worktree
  committed=$(git diff --name-only "$remote_commit" HEAD -- "$migrations_dir" 2>/dev/null)
  # ...plus uncommitted/untracked migration files (deploy will commit these).
  worktree=$(git status --porcelain -- "$migrations_dir" 2>/dev/null)

  [[ -n "$committed" || -n "$worktree" ]] && return 0
  return 1
}

# Report whether the next deploy from this folder needs a DB migration.
deploy_check() {
  local service_name=$(basename "$PWD")
  local server_folder="$service_name"

  [[ ! -f "deploy.json" ]] && { echo "❌ No deploy.json in $PWD"; return 1; }

  local name_override=$(jq -r '.serviceName // empty' deploy.json 2>/dev/null)
  [[ -n "$name_override" ]] && service_name="$name_override"
  local folder_override=$(jq -r '.serverFolder // empty' deploy.json 2>/dev/null)
  [[ -n "$folder_override" ]] && server_folder="$folder_override"

  local db_path=$(jq -r '.database.path // empty' deploy.json)
  if [[ -z "$db_path" ]]; then
    echo "ℹ️  No database configured → use: deploy --no-db"
    return 1
  fi

  local migrations_dir=$(jq -r '.database.migrationsDir // empty' deploy.json)
  if [[ -z "$migrations_dir" ]]; then
    echo "⚠️  No \"database.migrationsDir\" in deploy.json — cannot auto-detect."
    echo "   Add e.g. \"migrationsDir\": \"drizzle\" to the database block,"
    echo "   or choose explicitly: deploy --db | deploy --no-db"
    return 2
  fi

  echo "🔎 Comparing '$migrations_dir' against deployed commit on server..."
  _deploy_migrations_changed "$server_folder" "$migrations_dir"
  case $? in
    0) echo "✅ Migrations changed since last deploy → use: deploy --db"; return 0 ;;
    1) echo "✅ No migration changes → use: deploy --no-db (fast, no DB transfer)"; return 1 ;;
    *) echo "⚠️  Could not determine (server unreachable or deployed commit not found locally)."
       echo "   Choose explicitly: deploy --db | deploy --no-db"; return 2 ;;
  esac
}

deploy() {
  local service_name=$(basename "$PWD")
  local server_folder="$service_name"
  local build_config=".build"
  local has_database=false
  local skip_db=false
  local deploy_mode=""
  local db_path=""
  local migrations_dir=""
  local health_check_cmd=""

  # An explicit mode is required
  case "$1" in
    --db)    deploy_mode="db";    shift ;;
    --no-db) deploy_mode="no-db"; shift ;;
    --auto)  deploy_mode="auto";  shift ;;
    -h|--help|"") _deploy_usage; return 0 ;;
    *) echo "❌ Unknown option: $1"; echo ""; _deploy_usage; return 1 ;;
  esac

  # Override names and read DB config from deploy.json if present
  # serviceName overrides only the services.json key / systemd unit
  # serverFolder overrides only the /srv/ directory (defaults to local folder name)
  if [[ -f "deploy.json" ]]; then
    local name_override=$(jq -r '.serviceName // empty' deploy.json 2>/dev/null)
    if [[ -n "$name_override" ]]; then
      service_name="$name_override"
    fi
    local folder_override=$(jq -r '.serverFolder // empty' deploy.json 2>/dev/null)
    if [[ -n "$folder_override" ]]; then
      server_folder="$folder_override"
    fi
    db_path=$(jq -r '.database.path // empty' deploy.json)
    migrations_dir=$(jq -r '.database.migrationsDir // empty' deploy.json)
    health_check_cmd=$(jq -r '.healthCheck // empty' deploy.json)
  fi

  # Resolve --auto into db / no-db
  if [[ "$deploy_mode" == "auto" ]]; then
    if [[ -z "$db_path" ]]; then
      deploy_mode="no-db"
      echo "🔎 --auto: no database configured → code-only deploy"
    elif [[ -z "$migrations_dir" ]]; then
      echo "❌ --auto needs \"database.migrationsDir\" in deploy.json to detect migrations."
      echo "   Add it, or run: deploy --db | deploy --no-db"
      return 1
    else
      echo "🔎 --auto: comparing '$migrations_dir' against deployed commit..."
      _deploy_migrations_changed "$server_folder" "$migrations_dir"
      case $? in
        0) deploy_mode="db";    echo "   → migrations changed: deploying WITH migration" ;;
        1) deploy_mode="no-db"; echo "   → no migration changes: code-only deploy" ;;
        *) echo "❌ --auto could not determine migration state (server unreachable or commit missing locally)."
           echo "   Run explicitly: deploy --db | deploy --no-db"; return 1 ;;
      esac
    fi
    echo ""
  fi

  [[ "$deploy_mode" == "no-db" ]] && skip_db=true

  echo "🚀 Deploying $service_name (folder: $server_folder)..."
  echo ""

  # Resolve database workflow based on mode
  if [[ -n "$db_path" ]]; then
    if [[ "$skip_db" == "true" ]]; then
      echo "📊 Database configured but skipped (--no-db)"
    else
      has_database=true
      echo "📊 Database migration will run on the server: $db_path"
    fi
  elif [[ "$deploy_mode" == "db" ]]; then
    echo "⚠️  --db requested but no database configured in deploy.json — continuing code-only"
  fi

  # Step 1: Local build (optional)
  if [ -f "$build_config" ]; then
    local cmd=$(head -n 1 "$build_config")
    read -r "run_build?🏗️  Found $build_config. Run '$cmd'? (y/n): "
    if [[ "$run_build" == "y" ]]; then
      echo "Running: $cmd"
      eval "$cmd" || { echo "❌ Build failed. Aborting."; return 1; }
      echo ""
    fi
  fi

  # Step 2: Git commit & push
  echo "📦 Handling Git workflow..."

  # `git commit -am` only picks up TRACKED modifications, but _deploy_migrations_changed
  # counts untracked files too. A brand-new migration file therefore used to make --auto
  # announce "deploying WITH migration", commit nothing, push nothing, and deploy a
  # version that has no migration in it — a green deploy that did nothing.
  # Untracked files must be surfaced here, never silently dropped.
  local tracked_dirty="" untracked=""
  git diff-index --quiet HEAD -- 2>/dev/null || tracked_dirty=1
  untracked=$(git ls-files --others --exclude-standard)

  local add_all=false
  if [[ -n "$untracked" ]]; then
    echo ""
    echo "⚠️  Untracked files (a normal deploy commit does NOT include these):"
    echo "$untracked" | sed 's/^/     /'
    echo ""
    read -r "include_untracked?Include them in the deploy commit? (y/n): "
    if [[ "$include_untracked" == "y" ]]; then
      add_all=true
    elif [[ -n "$migrations_dir" ]] && echo "$untracked" | grep -qE "^${migrations_dir}(/|$)"; then
      echo ""
      echo "❌ Untracked files inside '$migrations_dir' were excluded."
      echo "   The server would migrate without them. Aborting rather than deploying a no-op."
      return 1
    fi
  fi

  if [[ -n "$tracked_dirty" || "$add_all" == "true" ]]; then
    read -r "msg?Commit message (default: 'deploy'): "
    msg=${msg:-"deploy"}
    if [[ "$add_all" == "true" ]]; then
      git add -A || { echo "❌ git add failed."; return 1; }
      git commit -m "$msg" || { echo "❌ Commit failed."; return 1; }
    else
      git commit -am "$msg" || { echo "❌ Commit failed."; return 1; }
    fi
  else
    echo "   No local changes to commit."
  fi

  git push origin $(git rev-parse --abbrev-ref HEAD) || { echo "❌ Push failed."; return 1; }
  echo ""

  # Step 3: Remote deployment (server handles maintenance, DB workflow, health check, recovery)
  echo "🌐 Running remote deployment..."
  echo "────────────────────────────────────────"

  local deploy_cmd="bun $SIG_INFRA_REMOTE/server/deploy.ts $service_name"
  if [[ "$server_folder" != "$service_name" ]]; then
    deploy_cmd="$deploy_cmd --folder $server_folder"
  fi
  if [[ "$has_database" == "true" ]]; then
    deploy_cmd="$deploy_cmd --db"
  fi
  if [[ -n "$health_check_cmd" ]]; then
    deploy_cmd="$deploy_cmd --health-check '$health_check_cmd'"
  fi

  if ! ssh -t $SIG_SERVER "$deploy_cmd"; then
    echo "────────────────────────────────────────"
    echo "❌ Deployment failed! (server attempted auto-recovery to the previous version)"
    echo ""
    echo "Useful commands:"
    echo "  deploy_status $service_name"
    echo "  ssh $SIG_SERVER 'sudo journalctl -u $server_folder -n 50'"
    return 1
  fi

  echo "────────────────────────────────────────"
  echo ""

  # Step 4: Tail logs
  echo "📋 Tailing logs (Ctrl+C to exit)..."
  echo "────────────────────────────────────────"
  ssh -t $SIG_SERVER "sudo journalctl -u $server_folder -f -n 20"
}

deploy_status() {
  local service_name=${1:-$(basename "$PWD")}
  ssh -t $SIG_SERVER "bun $SIG_INFRA_REMOTE/server/deploy.ts $service_name --status"
}

# Usage: deploy_rollback [service] [--db]
#   --db also restores the database from backup.1 (use after a failed --db deploy)
deploy_rollback() {
  local service_name=""
  local db_flag=""

  for arg in "$@"; do
    case "$arg" in
      --db) db_flag="--db" ;;
      *) service_name="$arg" ;;
    esac
  done
  [[ -z "$service_name" ]] && service_name=$(basename "$PWD")
  local server_folder="$service_name"

  # Resolve overrides when run from a project directory
  if [[ -f "deploy.json" ]]; then
    local name_override=$(jq -r '.serviceName // empty' deploy.json 2>/dev/null)
    [[ -n "$name_override" ]] && service_name="$name_override"
    local folder_override=$(jq -r '.serverFolder // empty' deploy.json 2>/dev/null)
    [[ -n "$folder_override" ]] && server_folder="$folder_override"
  fi

  echo "⚠️  This will rollback $service_name to the previous commit."
  [[ -n "$db_flag" ]] && echo "⚠️  It will ALSO restore the database from backup.1."
  read -r "confirm?Are you sure? (y/n): "
  [[ "$confirm" != "y" ]] && { echo "Cancelled."; return 0; }

  local rollback_cmd="bun $SIG_INFRA_REMOTE/server/deploy.ts $service_name --rollback"
  if [[ "$server_folder" != "$service_name" ]]; then
    rollback_cmd="$rollback_cmd --folder $server_folder"
  fi
  [[ -n "$db_flag" ]] && rollback_cmd="$rollback_cmd --db"

  ssh -t $SIG_SERVER "$rollback_cmd"
}

# =============================================================================
# Database Development Tools
# =============================================================================

db_pull() {
  local service_name=${1:-$(basename "$PWD")}
  local server_folder="$service_name"

  # Check for deploy.json
  if [[ ! -f "deploy.json" ]]; then
    echo "❌ No deploy.json found in current directory"
    return 1
  fi

  # Override service name and server folder from deploy.json if present
  # serviceName overrides only the services.json key / systemd unit
  # serverFolder overrides only the /srv/ directory (defaults to local folder name)
  local name_override=$(jq -r '.serviceName // empty' deploy.json 2>/dev/null)
  if [[ -n "$name_override" ]]; then
    service_name="$name_override"
  fi
  local folder_override=$(jq -r '.serverFolder // empty' deploy.json 2>/dev/null)
  if [[ -n "$folder_override" ]]; then
    server_folder="$folder_override"
  fi

  # Parse database path
  local db_path=$(jq -r '.database.path // empty' deploy.json)
  if [[ -z "$db_path" ]]; then
    echo "❌ No database configuration found in deploy.json"
    return 1
  fi

  echo "📥 Downloading production database for $service_name..."
  mkdir -p deploy-tmp

  # Snapshot with VACUUM INTO first — a raw scp of a WAL-mode database misses
  # anything still in the -wal sidecar. The snapshot is one consistent file.
  local snapshot="/tmp/$service_name-db.snapshot"
  ssh -t $SIG_SERVER "sudo -u $server_folder bun $SIG_INFRA_REMOTE/server/db-tool.ts snapshot /srv/$server_folder/$db_path $snapshot && sudo chmod 644 $snapshot" || {
    echo "❌ Failed to snapshot database on server"
    return 1
  }

  scp "$SIG_SERVER:$snapshot" "deploy-tmp/db.sqlite" || {
    echo "❌ Failed to download database"
    ssh -t $SIG_SERVER "sudo rm -f $snapshot" 2>/dev/null
    return 1
  }

  ssh -t $SIG_SERVER "sudo rm -f $snapshot" 2>/dev/null

  echo "✅ Database downloaded to: deploy-tmp/db.sqlite"
  echo ""
  echo "Next steps:"
  echo "  db_migrate_test   # Run migration on downloaded DB"
  echo "  db_validate_test  # Validate migration"
}

db_migrate_test() {
  if [[ ! -f "deploy.json" ]]; then
    echo "❌ No deploy.json found"
    return 1
  fi

  if [[ ! -f "deploy-tmp/db.sqlite" ]]; then
    echo "❌ No database found in deploy-tmp/. Run db_pull first."
    return 1
  fi

  local migrate_cmd=$(jq -r '.database.migrate // empty' deploy.json)
  if [[ -z "$migrate_cmd" ]]; then
    echo "❌ No migration command in deploy.json"
    return 1
  fi

  echo "🔄 Running migration: $migrate_cmd"
  echo "   DB_PATH=deploy-tmp/db.sqlite"
  echo ""

  ( export DB_PATH="deploy-tmp/db.sqlite" && eval "$migrate_cmd" ) || {
    echo "❌ Migration failed"
    return 1
  }

  echo "✅ Migration completed"
}

db_validate_test() {
  if [[ ! -f "deploy.json" ]]; then
    echo "❌ No deploy.json found"
    return 1
  fi

  if [[ ! -f "deploy-tmp/db.sqlite" ]]; then
    echo "❌ No database found in deploy-tmp/. Run db_pull and db_migrate_test first."
    return 1
  fi

  local validate_cmd=$(jq -r '.database.validate // empty' deploy.json)
  if [[ -z "$validate_cmd" ]]; then
    echo "❌ No validation command in deploy.json"
    return 1
  fi

  echo "🔍 Running validation: $validate_cmd"
  echo "   DB_PATH=deploy-tmp/db.sqlite"
  echo ""

  ( export DB_PATH="deploy-tmp/db.sqlite" && eval "$validate_cmd" ) || {
    echo "❌ Validation failed"
    return 1
  }

  echo "✅ Validation passed"
}

# =============================================================================
# Help
# =============================================================================

helpme_sig_infra() {
  echo ""
  echo "--- DEPLOYMENT ---"
  echo "deploy         : Deploy current folder (mode required: --db | --no-db | --auto)"
  echo "deploy_check   : Report whether next deploy needs --db or --no-db"
  echo "deploy_status  : Check service status (deploy_status [service])"
  echo "deploy_rollback: Rollback to previous commit (--db: also restore DB backup.1)"
  echo "deploy_preflight: Pre-deploy checks"
  echo ""
  echo "--- DATABASE ---"
  echo "db_pull        : Download production database for local testing"
  echo "db_migrate_test: Run migration on downloaded database"
  echo "db_validate_test: Run validation on migrated database"
  echo ""
  echo "--- SERVICE SETUP ---"
  echo "service_create : Interactive wizard to create new service"
  echo ""
  echo "--- CADDY ---"
  echo "caddy_list     : List all services with status"
  echo "caddy_status   : Check specific service (caddy_status <service>)"
  echo "caddy_add      : Add a service (caddy_add <name> <port>)"
  echo "caddy_remove   : Remove a service from Caddy"
  echo "caddy_view     : View the generated Caddyfile"
  echo "caddy_regen    : Regenerate Caddyfile (--dry-run to preview)"
  echo "app_maint      : Toggle maintenance mode"
  echo ""
  echo "--- INFRASTRUCTURE ---"
  echo "infra_push     : Push infra changes to server"
  echo "infra_pull     : Pull latest infra locally"
  echo "infra_status   : Show local/server infra sync status"
}

# =============================================================================
# Completions
# =============================================================================

# Cache for service names (refreshed on first use per shell session)
_caddy_services_cache=""
_caddy_services_cache_time=0

_get_caddy_services() {
  local now=$(date +%s)
  # Cache for 60 seconds
  if [[ -z "$_caddy_services_cache" ]] || (( now - _caddy_services_cache_time > 60 )); then
    _caddy_services_cache=$(ssh -o ConnectTimeout=2 $SIG_SERVER \
      "cat $SIG_INFRA_REMOTE/server/services.json 2>/dev/null" | jq -r 'keys[]' 2>/dev/null)
    _caddy_services_cache_time=$now
  fi
  echo "$_caddy_services_cache"
}

_app_maint_completion() {
  local -a services
  if [[ $CURRENT -eq 2 ]]; then
    services=(${(f)"$(_get_caddy_services)"})
    _alternative \
      'options:options:(--dry-run)' \
      "services:service:(${services[*]})"
  elif [[ $CURRENT -eq 3 && "${words[2]}" == "--dry-run" ]]; then
    services=(${(f)"$(_get_caddy_services)"})
    _describe 'service' services
  fi
}

_caddy_add_completion() {
  if [[ $CURRENT -eq 2 ]]; then
    _message "service name (e.g., my-api)"
  elif [[ $CURRENT -eq 3 ]]; then
    local used_ports=$(ssh -o ConnectTimeout=2 $SIG_SERVER \
      "cat $SIG_INFRA_REMOTE/server/services.json 2>/dev/null" | jq -r '.[].port' 2>/dev/null | tr '\n' ' ')
    _message "port number (in use: ${used_ports:-none})"
  fi
}

_caddy_remove_completion() {
  local -a services
  services=(${(f)"$(_get_caddy_services)"})
  _describe 'service' services
}

_caddy_status_completion() {
  local -a services
  services=(${(f)"$(_get_caddy_services)"})
  _describe 'service' services
}

_caddy_regen_completion() {
  _arguments '1:option:(--dry-run)'
}

_infra_push_completion() {
  _message "commit message (optional)"
}

# Register completions
compdef _app_maint_completion app_maint
compdef _caddy_add_completion caddy_add
compdef _caddy_remove_completion caddy_remove
compdef _caddy_status_completion caddy_status
compdef _caddy_regen_completion caddy_regen
compdef _infra_push_completion infra_push
compdef '_arguments "1:mode:(--db --no-db --auto --help)"' deploy
compdef '_arguments "1:service:($(_get_caddy_services))"' deploy_status
compdef '_arguments "1:service:($(_get_caddy_services))"' deploy_rollback

# =============================================================================
# Startup message
# =============================================================================
echo "sig-infra loaded. Type 'helpme' for commands."
