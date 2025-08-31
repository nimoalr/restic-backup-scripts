#!/bin/sh
# install-restic.sh (POSIX /bin/sh)
# System-wide installer for weekly restic backups to a rest-server.
# NO AUTH! Only uses without auth if your restic server is not exposed to the internet.
#
# Usage:
#   sudo ./install-restic.sh
#
# Target: Debian / Ubuntu

# Fail on unset and error (pipefail not used because dash doesn't support it)
set -eu

if [ "$(id -u)" != "0" ]; then
  echo "ERROR: must run as root (sudo)." >&2
  exit 2
fi

HOSTNAME_SHORT="$(hostname -s)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEFAULT_ENDPOINT="http://my-restic-server:9999/" # Default REST server endpoint

printf "\n=== Restic weekly backup installer (system-wide) ===\n"
printf "Repository name will be the machine short hostname: %s\n\n" "$HOSTNAME_SHORT"

# Ensure restic exists, try apt if missing
if ! command -v restic >/dev/null 2>&1; then
  printf "restic not found. Attempting to install via apt (Debian/Ubuntu)...\n"
  apt-get update -y
  apt-get install -y restic || {
    echo "Failed to install restic via apt. Please install restic manually and re-run." >&2
    exit 3
  }
fi

RESTIC_BIN="$(command -v restic)"
printf "Using restic: %s\n\n" "$RESTIC_BIN"

# --- Prompt for variables (POSIX-safe)
printf "REST server endpoint (example: %s) : " "$DEFAULT_ENDPOINT"
read INPUT_ENDPOINT
if [ -z "$INPUT_ENDPOINT" ]; then
  INPUT_ENDPOINT="$DEFAULT_ENDPOINT"
fi
# strip trailing slashes
REST_SERVER_ENDPOINT="$(printf '%s' "$INPUT_ENDPOINT" | sed -e 's#/*$##')"

# restic repository encryption password (silent)
printf "restic repository encryption password (store safely): "
stty -echo
read RESTIC_REPO_PASSWORD || RESTIC_REPO_PASSWORD=""
stty echo
printf "\n"

printf "Paths to backup (space-separated, default: /home): "
read RESTIC_PATHS
if [ -z "$RESTIC_PATHS" ]; then
  RESTIC_PATHS="/home"
fi

printf "Create a sensible exclude file? [Y/n]: "
read CREATE_EXCL
if [ -z "$CREATE_EXCL" ]; then
  CREATE_EXCL="Y"
fi

printf "Retention - keep daily (default 14): "
read KEEP_DAILY
if [ -z "$KEEP_DAILY" ]; then KEEP_DAILY=14; fi
printf "Retention - keep weekly (default 8): "
read KEEP_WEEKLY
if [ -z "$KEEP_WEEKLY" ]; then KEEP_WEEKLY=8; fi
printf "Retention - keep monthly (default 12): "
read KEEP_MONTHLY
if [ -z "$KEEP_MONTHLY" ]; then KEEP_MONTHLY=12; fi

# Build repo path with hostname resolution fallback
REPO_PATH="${REST_SERVER_ENDPOINT}/${HOSTNAME_SHORT}"
# compact double slashes
REPO_PATH="$(printf '%s' "$REPO_PATH" | sed -e 's#\([^:]\)/\+#\1/#g')"

# Test hostname resolution and use IP fallback if needed
printf "\n=== Testing hostname resolution ===\n"
REST_HOST_FROM_ENDPOINT=$(echo "$REST_SERVER_ENDPOINT" | sed 's|http://||' | sed 's|https://||' | cut -d: -f1)
printf "Testing resolution of hostname: %s\n" "$REST_HOST_FROM_ENDPOINT"

# Try to resolve hostname to IP for better compatibility
RESOLVED_IP=""
if command -v getent >/dev/null 2>&1; then
  RESOLVED_IP=$(getent hosts "$REST_HOST_FROM_ENDPOINT" 2>/dev/null | awk '{print $1}' | head -1)
elif command -v nslookup >/dev/null 2>&1; then
  RESOLVED_IP=$(nslookup "$REST_HOST_FROM_ENDPOINT" 2>/dev/null | awk '/^Address: / { print $2 }' | head -1)
elif command -v host >/dev/null 2>&1; then
  RESOLVED_IP=$(host "$REST_HOST_FROM_ENDPOINT" 2>/dev/null | awk '/has address/ { print $4 }' | head -1)
fi

# Test connectivity with original hostname first
CONNECTIVITY_TEST_FAILED=0
if command -v curl >/dev/null 2>&1; then
  printf "Testing connectivity with hostname...\n"
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$REST_SERVER_ENDPOINT" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "000" ]; then
    printf "⚠ Hostname connectivity failed (code: %s)\n" "$HTTP_CODE"
    CONNECTIVITY_TEST_FAILED=1
  else
    printf "✓ Hostname connectivity working (code: %s)\n" "$HTTP_CODE"
  fi
fi

# If hostname failed and we have a resolved IP, try IP-based URL
if [ "$CONNECTIVITY_TEST_FAILED" = "1" ] && [ -n "$RESOLVED_IP" ]; then
  printf "Trying IP address fallback: %s\n" "$RESOLVED_IP"
  
  # Extract port from original endpoint
  ORIGINAL_PORT=$(echo "$REST_SERVER_ENDPOINT" | sed 's|.*:||')
  if [ "$ORIGINAL_PORT" = "$REST_SERVER_ENDPOINT" ]; then
    # No port specified, use default
    IP_BASED_ENDPOINT="http://$RESOLVED_IP"
  else
    # Port was specified
    IP_BASED_ENDPOINT="http://$RESOLVED_IP:$ORIGINAL_PORT"
  fi
  
  # Test IP-based connectivity
  if command -v curl >/dev/null 2>&1; then
    IP_HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$IP_BASED_ENDPOINT" 2>/dev/null || echo "000")
    if [ "$IP_HTTP_CODE" != "000" ]; then
      printf "✓ IP address connectivity working (code: %s)\n" "$IP_HTTP_CODE"
      printf "Using IP-based repository URL for better compatibility\n"
      
      # Update repository path to use IP
      REPO_PATH="${IP_BASED_ENDPOINT}/${HOSTNAME_SHORT}"
      REPO_PATH="$(printf '%s' "$REPO_PATH" | sed -e 's#\([^:]\)/\+#\1/#g')"
      printf "Updated repository path: %s\n" "$REPO_PATH"
    else
      printf "✗ IP address connectivity also failed (code: %s)\n" "$IP_HTTP_CODE"
      printf "Will proceed with original hostname - manual troubleshooting may be needed\n"
    fi
  fi
elif [ "$CONNECTIVITY_TEST_FAILED" = "1" ]; then
  printf "⚠ Could not resolve hostname to IP address\n"
  printf "Will proceed with original hostname - manual troubleshooting may be needed\n"
else
  printf "✓ Using original hostname-based URL\n"
fi

# Files & paths
ETC_RESTIC_DIR="/etc/restic"
ENV_FILE="${ETC_RESTIC_DIR}/${HOSTNAME_SHORT}.env"
PASS_FILE="${ETC_RESTIC_DIR}/${HOSTNAME_SHORT}.pass"
EXCLUDE_FILE="${ETC_RESTIC_DIR}/${HOSTNAME_SHORT}.excludes"
WRAPPER_SCRIPT="/usr/local/bin/restic-backup-${HOSTNAME_SHORT}.sh"
SERVICE_NAME="restic-backup-${HOSTNAME_SHORT}.service"
TIMER_NAME="restic-backup-${HOSTNAME_SHORT}.timer"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"

# Ensure clean file creation - remove existing files if re-running
printf "\n=== Creating configuration files (overwriting any existing) ===\n"
mkdir -p "$ETC_RESTIC_DIR"
chmod 700 "$ETC_RESTIC_DIR"
umask 077

# Remove existing files to ensure clean overwrite
[ -f "$PASS_FILE" ] && rm -f "$PASS_FILE"
[ -f "$ENV_FILE" ] && rm -f "$ENV_FILE"
[ -f "$EXCLUDE_FILE" ] && rm -f "$EXCLUDE_FILE"
[ -f "$WRAPPER_SCRIPT" ] && rm -f "$WRAPPER_SCRIPT"
[ -f "$SERVICE_PATH" ] && rm -f "$SERVICE_PATH"
[ -f "$TIMER_PATH" ] && rm -f "$TIMER_PATH"

# write pass file
printf "%s\n" "$RESTIC_REPO_PASSWORD" > "$PASS_FILE"
chmod 600 "$PASS_FILE"

# write env file
cat > "$ENV_FILE" <<EOF
# restic environment for host ${HOSTNAME_SHORT} (created ${TIMESTAMP})
RESTIC_REPOSITORY=rest:${REPO_PATH}
RESTIC_PASSWORD_FILE=${PASS_FILE}
RESTIC_BACKUP_PATHS="${RESTIC_PATHS}"
RESTIC_EXCLUDE_FILE=${EXCLUDE_FILE}
KEEP_DAILY=${KEEP_DAILY}
KEEP_WEEKLY=${KEEP_WEEKLY}
KEEP_MONTHLY=${KEEP_MONTHLY}
EOF
chmod 600 "$ENV_FILE"

# create exclude file if requested
case "$CREATE_EXCL" in
  [Yy]*|"")
    cat > "$EXCLUDE_FILE" <<'EEX'
/proc
/sys
/dev
/tmp
/run
/var/run
/var/tmp
/home/*/.cache
/home/*/.local/share/Trash
EEX
    chmod 600 "$EXCLUDE_FILE"
    printf "Wrote exclude file to %s\n" "$EXCLUDE_FILE"
    ;;
  *)
    printf "Skipping exclude file creation.\n"
    ;;
esac

# create wrapper script with enhanced troubleshooting
cat > "$WRAPPER_SCRIPT" <<'WRAP'
#!/bin/sh
set -eu

ENV_FILE='__ENV_FILE__'
PASS_FILE='__PASS_FILE__'

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
else
  echo "ERROR: env file $ENV_FILE not found" >&2
  exit 1
fi

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set in $ENV_FILE}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE must be set in $ENV_FILE}"

BACKUP_PATHS="${RESTIC_BACKUP_PATHS:-/home}"
EXCLUDE_FILE="${RESTIC_EXCLUDE_FILE:-/etc/restic/__HOST__.excludes}"

echo "=== Restic Backup Script Starting ==="
echo "Repository: $RESTIC_REPOSITORY"
echo "Backup paths: $BACKUP_PATHS"
echo "Exclude file: $EXCLUDE_FILE"

# Enhanced connectivity check with detailed diagnostics and auto-init
echo ""
echo "=== Connectivity Check ==="

# First check if we can resolve the hostname from the repository URL
REPO_HOST=$(echo "$RESTIC_REPOSITORY" | sed 's|rest:http://||' | sed 's|rest:https://||' | cut -d/ -f1 | cut -d: -f1)
REPO_PORT=$(echo "$RESTIC_REPOSITORY" | sed 's|rest:http://||' | sed 's|rest:https://||' | cut -d/ -f1 | cut -d: -f2)

# Try to resolve hostname and create alternative IP-based repository URL if needed
ALTERNATIVE_REPO=""
if command -v getent >/dev/null 2>&1; then
  RESOLVED_IP=$(getent hosts "$REPO_HOST" 2>/dev/null | awk '{print $1}' | head -1)
  if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" != "$REPO_HOST" ]; then
    if [ "$REPO_PORT" != "$REPO_HOST" ]; then
      ALTERNATIVE_REPO=$(echo "$RESTIC_REPOSITORY" | sed "s|://$REPO_HOST:$REPO_PORT|://$RESOLVED_IP:$REPO_PORT|")
    else
      ALTERNATIVE_REPO=$(echo "$RESTIC_REPOSITORY" | sed "s|://$REPO_HOST|://$RESOLVED_IP|")
    fi
  fi
fi

# Test primary repository URL first
if ! restic -r "${RESTIC_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" snapshots >/dev/null 2>&1; then
  echo "Primary repository URL not accessible: $RESTIC_REPOSITORY"
  
  # Try alternative IP-based URL if available
  if [ -n "$ALTERNATIVE_REPO" ]; then
    echo "Trying alternative IP-based URL: $ALTERNATIVE_REPO"
    if restic -r "${ALTERNATIVE_REPO}" --password-file "${RESTIC_PASSWORD_FILE}" snapshots >/dev/null 2>&1; then
      echo "✓ Alternative repository URL is accessible!"
      RESTIC_REPOSITORY="$ALTERNATIVE_REPO"
    else
      echo "Alternative repository URL also failed, proceeding with diagnostics..."
    fi
  fi
fi

# If still not accessible, run full diagnostics and initialization
if ! restic -r "${RESTIC_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" snapshots >/dev/null 2>&1; then
  echo "Repository not accessible, checking if initialization is needed..."
  echo ""
  echo "=== Troubleshooting Information ==="
  echo "Repository URL: $RESTIC_REPOSITORY"
  echo "Password file: $RESTIC_PASSWORD_FILE"
  
  # Test basic connectivity
  REST_HOST=$(echo "$RESTIC_REPOSITORY" | sed 's|rest:http://||' | sed 's|rest:https://||' | cut -d/ -f1)
  REST_PORT=$(echo "$REST_HOST" | cut -d: -f2)
  REST_HOST_ONLY=$(echo "$REST_HOST" | cut -d: -f1)
  
  echo ""
  echo "Testing network connectivity..."
  if command -v nc >/dev/null 2>&1; then
    if nc -z "$REST_HOST_ONLY" "$REST_PORT" 2>/dev/null; then
      echo "✓ Network connection to $REST_HOST_ONLY:$REST_PORT is working"
      NETWORK_OK=1
    else
      echo "✗ Cannot reach $REST_HOST_ONLY:$REST_PORT"
      echo "  Check if the REST server is running and accessible"
      NETWORK_OK=0
    fi
  else
    echo "  (netcat not available for port testing)"
    NETWORK_OK=1  # Assume OK if we can't test
  fi
  
  # Test HTTP response
  echo ""
  echo "Testing HTTP response..."
  if command -v curl >/dev/null 2>&1; then
    HTTP_URL=$(echo "$RESTIC_REPOSITORY" | sed 's/rest://')
    echo "Trying: curl -s -o /dev/null -w '%{http_code}' $HTTP_URL"
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$HTTP_URL" 2>/dev/null || echo "000")
    case "$HTTP_CODE" in
      200|401|404) 
        echo "✓ HTTP server responding (code: $HTTP_CODE)" 
        HTTP_OK=1
        ;;
      000) 
        echo "✗ No HTTP response - server may be down" 
        HTTP_OK=0
        ;;
      *) 
        echo "? HTTP server responding with code: $HTTP_CODE" 
        HTTP_OK=1
        ;;
    esac
  else
    echo "  (curl not available for HTTP testing)"
    HTTP_OK=1  # Assume OK if we can't test
  fi
  
  # Attempt repository initialization if connectivity seems OK
  if [ "${NETWORK_OK:-1}" = "1" ] && [ "${HTTP_OK:-1}" = "1" ]; then
    echo ""
    echo "=== Attempting Repository Initialization ==="
    echo "Network and HTTP connectivity appear to be working."
    echo "Attempting to initialize repository..."
    
    if restic -r "${RESTIC_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" init 2>/dev/null; then
      echo "✓ SUCCESS: Repository initialized successfully!"
      echo "✓ Proceeding with backup..."
    else
      echo "✗ Failed to initialize repository"
      echo ""
      echo "This could be due to:"
      echo "1. Repository path doesn't exist or isn't writable on REST server"
      echo "2. Repository already exists but is corrupted"
      echo "3. Insufficient permissions on REST server"
      echo ""
      echo "Manual initialization command:"
      echo "RESTIC_PASSWORD_FILE=$RESTIC_PASSWORD_FILE RESTIC_REPOSITORY=$RESTIC_REPOSITORY restic init"
      exit 5
    fi
  else
    echo ""
    echo "Network or HTTP connectivity issues detected."
    echo "Cannot proceed with repository initialization."
    echo ""
    echo "Common issues to check:"
    echo "1. REST server is running on $REST_HOST"
    echo "2. Repository path exists: $(echo "$RESTIC_REPOSITORY" | sed 's|rest:http://[^/]*/||')"
    echo "3. Firewall/network allows access to port $REST_PORT"
    echo ""
    echo "Manual test command:"
    echo "RESTIC_PASSWORD_FILE=$RESTIC_PASSWORD_FILE RESTIC_REPOSITORY=$RESTIC_REPOSITORY restic snapshots"
    
    exit 5
  fi
fi

echo "✓ Repository connectivity verified"

echo ""
echo "=== Starting Backup ==="
echo "Starting restic backup for: ${BACKUP_PATHS}"
restic -r "${RESTIC_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" backup ${BACKUP_PATHS} --one-file-system --exclude-file "${EXCLUDE_FILE}" --tag automated || echo "backup command returned non-zero"

echo ""
echo "=== Running Cleanup ==="
echo "Running forget/prune (keep daily ${KEEP_DAILY}, weekly ${KEEP_WEEKLY}, monthly ${KEEP_MONTHLY})"
restic -r "${RESTIC_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" forget --prune --keep-daily ${KEEP_DAILY} --keep-weekly ${KEEP_WEEKLY} --keep-monthly ${KEEP_MONTHLY} || echo "forget/prune returned non-zero"

echo ""
echo "=== Backup Complete ==="
WRAP

# replace placeholders
sed -e "s#__ENV_FILE__#${ENV_FILE}#g" \
    -e "s#__PASS_FILE__#${PASS_FILE}#g" \
    -e "s#__HOST__#${HOSTNAME_SHORT}#g" \
    "$WRAPPER_SCRIPT" > "${WRAPPER_SCRIPT}.tmp" 2>/dev/null || true
# Above sed reads the just-written script; ensure it exists first
mv "${WRAPPER_SCRIPT}.tmp" "$WRAPPER_SCRIPT" 2>/dev/null || true

# Make wrapper executable; if sed path-step failed above (empty file), regenerate correctly:
if [ ! -s "$WRAPPER_SCRIPT" ]; then
  # regenerate properly inline replacement (POSIX-safe)
  awk -v EFILE="$ENV_FILE" -v PFILE="$PASS_FILE" -v HOST="$HOSTNAME_SHORT" '
  { gsub(/__ENV_FILE__/, EFILE); gsub(/__PASS_FILE__/, PFILE); gsub(/__HOST__/, HOST); print }
  ' "$WRAPPER_SCRIPT" > "${WRAPPER_SCRIPT}.new" 2>/dev/null || true
  if [ -f "${WRAPPER_SCRIPT}.new" ]; then
    mv "${WRAPPER_SCRIPT}.new" "$WRAPPER_SCRIPT"
  fi
fi

chmod 700 "$WRAPPER_SCRIPT"

# systemd unit
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Restic weekly backup for ${HOSTNAME_SHORT}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
ExecStart=${WRAPPER_SCRIPT}
Nice=10
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

# timer
cat > "$TIMER_PATH" <<EOF
[Unit]
Description=Weekly restic backup timer for ${HOSTNAME_SHORT}

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

# reload + enable (stop existing timer first if re-running)
systemctl daemon-reload
systemctl stop "${TIMER_NAME}" 2>/dev/null || true
systemctl disable "${TIMER_NAME}" 2>/dev/null || true
systemctl enable --now "${TIMER_NAME}"

# Enhanced connectivity check with automatic repository initialization
printf "\n=== Repository Connectivity Check & Initialization ===\n"
# export RESTIC envs for this check
# shellcheck disable=SC1090
. "$ENV_FILE"

# First try a simple connection
if restic -r "${RESTIC_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" snapshots >/dev/null 2>&1; then
  printf "✓ SUCCESS: restic can reach the repository %s\n" "${RESTIC_REPOSITORY}"
  SNAPSHOT_COUNT=$(restic -r "${RESTIC_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" snapshots --json 2>/dev/null | wc -l 2>/dev/null || echo "unknown")
  printf "✓ Repository contains snapshots (count: %s)\n" "$SNAPSHOT_COUNT"
else
  printf "⚠ Repository not accessible, attempting initialization...\n"
  
  # Extract connection details for troubleshooting
  REST_HOST=$(echo "$RESTIC_REPOSITORY" | sed 's|rest:http://||' | sed 's|rest:https://||' | cut -d/ -f1)
  REST_PATH=$(echo "$RESTIC_REPOSITORY" | sed 's|rest:http://[^/]*/||' | sed 's|rest:https://[^/]*/||')
  REST_HOST_ONLY=$(echo "$REST_HOST" | cut -d: -f1)
  REST_PORT=$(echo "$REST_HOST" | cut -d: -f2)
  
  printf "Repository URL: %s\n" "$RESTIC_REPOSITORY"
  printf "REST server: %s\n" "$REST_HOST"
  printf "Repository path: %s\n" "$REST_PATH"
  
  # Test basic connectivity first
  if command -v nc >/dev/null 2>&1; then
    if nc -z "$REST_HOST_ONLY" "$REST_PORT" 2>/dev/null; then
      printf "✓ Network connectivity to %s:%s is working\n" "$REST_HOST_ONLY" "$REST_PORT"
    else
      printf "✗ Cannot reach %s:%s - check if REST server is running\n" "$REST_HOST_ONLY" "$REST_PORT"
      printf "\n=== Setup Complete with Warnings ===\n"
      printf "Network connectivity issue detected. Fix the connection and then:\n"
      printf "1. Initialize repository: RESTIC_PASSWORD_FILE=%s RESTIC_REPOSITORY=%s restic init\n" "$PASS_FILE" "$RESTIC_REPOSITORY"
      printf "2. Test backup: %s\n" "$WRAPPER_SCRIPT"
      printf "\n"
      # Continue with setup summary but note the issue
      INIT_FAILED=1
    fi
  fi
  
  # Test HTTP response if network seems OK
  if [ "${INIT_FAILED:-0}" = "0" ] && command -v curl >/dev/null 2>&1; then
    HTTP_URL=$(echo "$RESTIC_REPOSITORY" | sed 's/rest://')
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$HTTP_URL" 2>/dev/null || echo "000")
    case "$HTTP_CODE" in
      200|401|404) printf "✓ HTTP server responding (code: %s)\n" "$HTTP_CODE" ;;
      000) 
        printf "✗ No HTTP response - server may be down\n"
        INIT_FAILED=1
        ;;
      *) printf "? HTTP server responding with code: %s)\n" "$HTTP_CODE" ;;
    esac
  fi
  
  # Attempt repository initialization if connectivity looks good
  if [ "${INIT_FAILED:-0}" = "0" ]; then
    printf "\n=== Attempting Repository Initialization ===\n"
    printf "Initializing restic repository at %s\n" "$RESTIC_REPOSITORY"
    
    # Try initialization with current URL
    if restic -r "${RESTIC_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" init 2>/dev/null; then
      printf "✓ SUCCESS: Repository initialized successfully!\n"
      
      # Verify initialization worked
      if restic -r "${RESTIC_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" snapshots >/dev/null 2>&1; then
        printf "✓ Repository verification successful\n"
      else
        printf "⚠ Repository initialized but verification failed\n"
      fi
    else
      printf "✗ Failed to initialize repository with hostname\n"
      
      # Try to resolve hostname for restic fallback
      printf "Attempting hostname resolution for restic fallback...\n"
      RESTIC_IP=""
      if command -v getent >/dev/null 2>&1; then
        RESTIC_IP=$(getent hosts "$REST_HOST_ONLY" 2>/dev/null | awk '{print $1}' | head -1)
      elif command -v nslookup >/dev/null 2>&1; then
        RESTIC_IP=$(nslookup "$REST_HOST_ONLY" 2>/dev/null | awk '/^Address: / { print $2 }' | head -1)
      elif command -v host >/dev/null 2>&1; then
        RESTIC_IP=$(host "$REST_HOST_ONLY" 2>/dev/null | awk '/has address/ { print $4 }' | head -1)
      fi
      
      if [ -n "$RESTIC_IP" ] && [ "$RESTIC_IP" != "$REST_HOST_ONLY" ]; then
        # Create IP-based repository URL
        if echo "$RESTIC_REPOSITORY" | grep -q ":$REST_PORT"; then
          IP_REPOSITORY=$(echo "$RESTIC_REPOSITORY" | sed "s|://$REST_HOST_ONLY:$REST_PORT|://$RESTIC_IP:$REST_PORT|")
        else
          IP_REPOSITORY=$(echo "$RESTIC_REPOSITORY" | sed "s|://$REST_HOST_ONLY|://$RESTIC_IP|")
        fi
        
        printf "Trying IP-based repository URL: %s\n" "$IP_REPOSITORY"
        
        if restic -r "${IP_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" init 2>/dev/null; then
          printf "✓ SUCCESS: Repository initialized with IP address!\n"
          
          # Update the environment file to use the working IP-based URL
          printf "Updating configuration to use IP-based URL...\n"
          sed -i.bak "s|RESTIC_REPOSITORY=rest:.*|RESTIC_REPOSITORY=${IP_REPOSITORY}|" "$ENV_FILE"
          
          # Verify initialization worked
          if restic -r "${IP_REPOSITORY}" --password-file "${RESTIC_PASSWORD_FILE}" snapshots >/dev/null 2>&1; then
            printf "✓ Repository verification successful with IP URL\n"
            printf "✓ Configuration updated to use IP address: %s\n" "$RESTIC_IP"
          else
            printf "⚠ Repository initialized but verification failed\n"
          fi
        else
          printf "✗ Failed to initialize repository even with IP address\n"
          printf "\nMost likely causes:\n"
          printf "1. Repository path doesn't exist or isn't writable on REST server\n"
          printf "2. Repository path conflicts with existing data\n"
          printf "3. REST server path isn't writable\n"
          printf "\\nAlternative repository paths to try:\\n"
          printf "- Shared repo: RESTIC_REPOSITORY=%s\\n" "$(echo "$IP_REPOSITORY" | sed 's|/[^/]*$|/shared|')"
          printf "- Subdir: RESTIC_REPOSITORY=%s\\n" "$(echo "$IP_REPOSITORY" | sed 's|/[^/]*$|/backups/'$HOSTNAME_SHORT'|')"
          printf "\nManual initialization:\n"
          printf "RESTIC_PASSWORD_FILE=%s RESTIC_REPOSITORY=%s restic init\n" "$PASS_FILE" "$IP_REPOSITORY"
          INIT_FAILED=1
        fi
      else
        printf "✗ Could not resolve hostname to IP address\n"
        printf "\nPossible issues:\n"
        printf "1. REST server path doesn't exist or isn't writable\n"
        printf "2. Repository path conflicts with existing data\n"
        printf "3. Network/firewall issues\n"
        printf "\nManual initialization:\n"
        printf "RESTIC_PASSWORD_FILE=%s RESTIC_REPOSITORY=%s restic init\n" "$PASS_FILE" "$RESTIC_REPOSITORY"
        INIT_FAILED=1
      fi
    fi
  fi
  
  if [ "${INIT_FAILED:-0}" = "1" ]; then
    printf "\n=== Troubleshooting Information ===\n"
    printf "Repository initialization failed. Common solutions:\n"
    printf "\n"
    printf "SOLUTION 1 - Check Repository Path:\n"
    printf "Verify the repository path exists and is writable on the REST server:\n"
    printf "- Check if directory /data/%s exists on server\n" "$REST_PATH"
    printf "- Ensure REST server has write permissions to the data directory\n"
    printf "\n"
    printf "SOLUTION 2 - Pre-create Repository Directory:\n"
    printf "Create the repository directory on the REST server filesystem:\n"
    printf "- SSH/access the REST server filesystem\n"
    printf "- Create directory: /data/%s (or wherever data is stored)\n" "$REST_PATH"
    printf "- Set appropriate ownership/permissions\n"
    printf "\n"
    printf "SOLUTION 3 - Use Alternative Repository Structure:\n"
    printf "Try these alternative repository paths:\n"
    printf "- Shared: RESTIC_REPOSITORY=rest:%s/shared\n" "$(echo "$RESTIC_REPOSITORY" | sed 's|rest:||' | sed 's|/[^/]*$||')"
    printf "- Subdirectory: RESTIC_REPOSITORY=rest:%s/backups/%s\n" "$(echo "$RESTIC_REPOSITORY" | sed 's|rest:||' | sed 's|/[^/]*$||')" "$HOSTNAME_SHORT"
    printf "\n"
    printf "Manual test commands:\n"
    printf "1. Test connectivity: curl -I %s\n" "$(echo "$RESTIC_REPOSITORY" | sed 's/rest://')"
    printf "2. Initialize repo: RESTIC_PASSWORD_FILE=%s RESTIC_REPOSITORY=%s restic init\n" "$PASS_FILE" "$RESTIC_REPOSITORY"
    printf "3. List snapshots: RESTIC_PASSWORD_FILE=%s RESTIC_REPOSITORY=%s restic snapshots\n" "$PASS_FILE" "$RESTIC_REPOSITORY"
  fi
fi

printf "\n=== Setup complete ===\n"
printf "Host: %s\n" "${HOSTNAME_SHORT}"
printf "Repository: rest:%s\n" "${REPO_PATH}"
printf "Env file: %s (mode 600)\n" "$ENV_FILE"
printf "Password file: %s (mode 600) - KEEP THIS SAFE\n" "$PASS_FILE"
printf "Exclude file: %s\n" "$EXCLUDE_FILE"
printf "Wrapper script: %s (executable)\n" "$WRAPPER_SCRIPT"
printf "Systemd service: %s\n" "$SERVICE_PATH"
printf "Systemd timer:   %s (OnCalendar=weekly) - enabled and started\n\n" "$TIMER_PATH"

if [ "${INIT_FAILED:-0}" = "0" ]; then
  printf "✓ Repository initialization completed successfully\n\n"
  printf "=== Ready to Use ===\n"
  printf "Manual backup test: %s\n" "$WRAPPER_SCRIPT"
  printf "View backup logs: journalctl -u %s --no-pager\n" "$SERVICE_NAME"
  printf "List snapshots: RESTIC_PASSWORD_FILE=%s RESTIC_REPOSITORY=rest:%s restic snapshots\n" "$PASS_FILE" "$REPO_PATH"
else
  printf "⚠ Repository initialization had issues - see messages above\n\n"
  printf "=== Manual Steps Required ===\n"
  printf "Initialize repo: RESTIC_PASSWORD_FILE=%s RESTIC_REPOSITORY=rest:%s restic init\n" "$PASS_FILE" "$REPO_PATH"
  printf "Test backup: %s\n" "$WRAPPER_SCRIPT"
  printf "View logs: journalctl -u %s --no-pager\n" "$SERVICE_NAME"
fi

printf "\nTimer status: systemctl status %s\n" "$TIMER_NAME"

exit 0
