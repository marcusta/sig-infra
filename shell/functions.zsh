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

# Internal helper: Backup database on server and upload migrated version
_deploy_db_backup_and_upload() {
  local service_name=$1
  local db_path=$2
  local server_folder=${3:-$service_name}

  echo "💾 Backing up database on server..."
  # Use single quotes for bash -c to avoid quoting issues, expand variables before sending
  ssh -t $SIG_SERVER "sudo -u $server_folder bash -c 'cd /srv/$server_folder && if [ -f $db_path.backup.1 ]; then mv $db_path.backup.1 $db_path.backup.2; fi && if [ -f $db_path ]; then cp $db_path $db_path.backup.1; fi'" || {
    echo "❌ Failed to backup database"
    return 1
  }

  echo "📤 Uploading deploy-tmp/db.sqlite → /srv/$server_folder/$db_path"
  # Upload to tmp first (marcus can write there), then move with sudo
  scp "deploy-tmp/db.sqlite" "$SIG_SERVER:/tmp/$service_name-db.new" || {
    echo "❌ Failed to upload database"
    return 1
  }

  ssh -t $SIG_SERVER "sudo mv /tmp/$service_name-db.new /srv/$server_folder/$db_path.new && \
    sudo chown $server_folder:$server_folder /srv/$server_folder/$db_path.new && \
    sudo -u $server_folder mv /srv/$server_folder/$db_path.new /srv/$server_folder/$db_path" || {
    echo "❌ Failed to move database into place"
    return 1
  }

  echo "✅ Database uploaded and activated"
}

# Internal helper: Rollback database from backup
_deploy_db_rollback() {
  local service_name=$1
  local db_path=$2
  local server_folder=${3:-$service_name}

  echo "⏪ Rolling back database..."
  ssh -t $SIG_SERVER "cd /srv/$server_folder && \
    if [ -f $db_path.backup.1 ]; then \
      sudo -u $server_folder cp $db_path.backup.1 $db_path; \
      echo '✅ Database rolled back to backup.1'; \
    else \
      echo '⚠️  No backup found to restore'; \
    fi"
}

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

deploy() {
  local service_name=$(basename "$PWD")
  local server_folder="$service_name"
  local build_config=".build"
  local has_database=false
  local skip_db=false
  local db_path=""
  local db_migrate_cmd=""
  local db_validate_cmd=""
  local health_check_cmd=""

  # Parse flags
  if [[ "$1" == "--no-db" ]]; then
    skip_db=true
    shift
  fi

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

  echo "🚀 Deploying $service_name (folder: $server_folder)..."
  echo ""

  # Check for deploy.json
  if [[ -f "deploy.json" ]]; then
    db_path=$(jq -r '.database.path // empty' deploy.json)
    if [[ -n "$db_path" ]]; then
      if [[ "$skip_db" == "true" ]]; then
        echo "📊 Database configured but skipped (--no-db)"
      else
        has_database=true
        db_migrate_cmd=$(jq -r '.database.migrate' deploy.json)
        db_validate_cmd=$(jq -r '.database.validate' deploy.json)
        echo "📊 Database detected: $db_path"
      fi
    fi
    health_check_cmd=$(jq -r '.healthCheck // empty' deploy.json)
  fi

  # Database migration workflow
  if [[ "$has_database" == "true" ]]; then
    echo ""
    echo "🔄 Database Migration Workflow"
    echo "────────────────────────────────────────"

    # 1. Enable maintenance mode
    echo "🚧 Enabling maintenance mode..."
    ssh -t $SIG_SERVER "cd $SIG_INFRA_REMOTE/server && bun generate.ts maint $service_name" 2>/dev/null

    # 2. Download DB
    echo "📥 Downloading /srv/$server_folder/$db_path → deploy-tmp/db.sqlite"
    mkdir -p deploy-tmp
    scp "$SIG_SERVER:/srv/$server_folder/$db_path" "deploy-tmp/db.sqlite" || {
      echo "❌ Failed to download database. Aborting."
      ssh -t $SIG_SERVER "cd $SIG_INFRA_REMOTE/server && bun generate.ts maint $service_name" 2>/dev/null
      return 1
    }

    # 3. Run migration
    echo "🔄 Running migration on deploy-tmp/db.sqlite"
    echo "   DB_PATH=deploy-tmp/db.sqlite $db_migrate_cmd"
    ( export DB_PATH="deploy-tmp/db.sqlite" && eval "$db_migrate_cmd" ) || {
      echo "❌ Migration failed. Aborting."
      ssh -t $SIG_SERVER "cd $SIG_INFRA_REMOTE/server && bun generate.ts maint $service_name" 2>/dev/null
      return 1
    }

    # 4. Run validation
    echo "🔍 Running validation on deploy-tmp/db.sqlite"
    echo "   DB_PATH=deploy-tmp/db.sqlite $db_validate_cmd"
    ( export DB_PATH="deploy-tmp/db.sqlite" && eval "$db_validate_cmd" ) || {
      echo "❌ Validation failed. Aborting."
      ssh -t $SIG_SERVER "cd $SIG_INFRA_REMOTE/server && bun generate.ts maint $service_name" 2>/dev/null
      return 1
    }

    echo "✅ Migration and validation successful"
    echo ""
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

  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    read -r "msg?Commit message (default: 'deploy'): "
    msg=${msg:-"deploy"}
    git commit -am "$msg" || { echo "❌ Commit failed."; return 1; }
  else
    echo "   No local changes to commit."
  fi

  git push origin $(git rev-parse --abbrev-ref HEAD) || { echo "❌ Push failed."; return 1; }
  echo ""

  # Step 3: Upload database if migrated
  if [[ "$has_database" == "true" ]]; then
    _deploy_db_backup_and_upload "$service_name" "$db_path" "$server_folder" || {
      echo "❌ Database upload failed. Aborting."
      ssh -t $SIG_SERVER "cd $SIG_INFRA_REMOTE/server && bun generate.ts maint $service_name" 2>/dev/null
      return 1
    }
    echo ""
  fi

  # Step 4: Remote deployment
  echo "🌐 Running remote deployment..."
  echo "────────────────────────────────────────"

  local deploy_cmd="bun $SIG_INFRA_REMOTE/server/deploy.ts $service_name"
  if [[ "$server_folder" != "$service_name" ]]; then
    deploy_cmd="$deploy_cmd --folder $server_folder"
  fi
  if [[ -n "$health_check_cmd" ]]; then
    deploy_cmd="$deploy_cmd --health-check '$health_check_cmd'"
  fi

  if ! ssh -t $SIG_SERVER "$deploy_cmd"; then
    echo "────────────────────────────────────────"
    echo "❌ Deployment failed!"

    # Rollback database if it was involved
    if [[ "$has_database" == "true" ]]; then
      echo ""
      _deploy_db_rollback "$service_name" "$db_path" "$server_folder"
    fi

    echo ""
    echo "Useful commands:"
    echo "  deploy_status $service_name"
    echo "  deploy_rollback $service_name"
    echo "  ssh $SIG_SERVER 'sudo journalctl -u $service_name -n 50'"
    return 1
  fi

  echo "────────────────────────────────────────"
  echo ""

  # Step 5: Tail logs
  echo "📋 Tailing logs (Ctrl+C to exit)..."
  echo "────────────────────────────────────────"
  ssh -t $SIG_SERVER "sudo journalctl -u $server_folder -f -n 20"
}

deploy_status() {
  local service_name=${1:-$(basename "$PWD")}
  ssh -t $SIG_SERVER "bun $SIG_INFRA_REMOTE/server/deploy.ts $service_name --status"
}

deploy_rollback() {
  local service_name=${1:-$(basename "$PWD")}

  echo "⚠️  This will rollback $service_name to the previous commit."
  read -r "confirm?Are you sure? (y/n): "
  [[ "$confirm" != "y" ]] && { echo "Cancelled."; return 0; }

  ssh -t $SIG_SERVER "bun $SIG_INFRA_REMOTE/server/deploy.ts $service_name --rollback"
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

  scp "$SIG_SERVER:/srv/$server_folder/$db_path" "deploy-tmp/db.sqlite" || {
    echo "❌ Failed to download database"
    return 1
  }

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
  echo "deploy         : Deploy current folder to server (--no-db to skip database)"
  echo "deploy_status  : Check service status (deploy_status [service])"
  echo "deploy_rollback: Rollback to previous commit"
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
compdef '_arguments "1:option:(--no-db)"' deploy
compdef '_arguments "1:service:($(_get_caddy_services))"' deploy_status
compdef '_arguments "1:service:($(_get_caddy_services))"' deploy_rollback

# =============================================================================
# Startup message
# =============================================================================
echo "sig-infra loaded. Type 'helpme' for commands."
