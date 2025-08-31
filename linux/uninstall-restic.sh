#!/bin/sh
# uninstall-restic.sh (POSIX /bin/sh)
# Completely uninstalls restic backup configuration, systemd units, and optionally the restic binary
#
# Usage:
#   sudo ./uninstall-restic.sh [--remove-binary]
#
# Options:
#   --remove-binary     Also remove the restic binary (if installed via apt)
#
# Note: This script only removes local configuration. Your backup data on the 
#       remote repository will remain intact and can be accessed later.
#
# Target: Debian / Ubuntu (POSIX shell compatible)

set -eu

# Parse command line arguments
REMOVE_BINARY=0

for arg in "$@"; do
  case "$arg" in
    --remove-binary)
      REMOVE_BINARY=1
      ;;
    --help|-h)
      echo "Usage: $0 [--remove-binary]"
      echo ""
      echo "Options:"
      echo "  --remove-binary     Also remove the restic binary (if installed via apt)"
      echo "  --help, -h          Show this help message"
      echo ""
      echo "Note: This script only removes local configuration. Your backup data"
      echo "      on the remote repository will remain intact and can be accessed later."
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "ERROR: must run as root (sudo)." >&2
  exit 2
fi

HOSTNAME_SHORT="$(hostname -s)"

printf "\n=== Restic backup uninstaller ===\n"
printf "Removing restic backup configuration for hostname: %s\n" "$HOSTNAME_SHORT"
if [ "$REMOVE_BINARY" = "1" ]; then
  printf "Will also remove restic binary\n"
fi
printf "\nNote: Your backup data on the remote repository will remain intact.\n"
printf "      Only local configuration files will be removed.\n\n"

# Define file paths
ETC_RESTIC_DIR="/etc/restic"
ENV_FILE="${ETC_RESTIC_DIR}/${HOSTNAME_SHORT}.env"
PASS_FILE="${ETC_RESTIC_DIR}/${HOSTNAME_SHORT}.pass"
EXCLUDE_FILE="${ETC_RESTIC_DIR}/${HOSTNAME_SHORT}.excludes"
WRAPPER_SCRIPT="/usr/local/bin/restic-backup-${HOSTNAME_SHORT}.sh"
SERVICE_NAME="restic-backup-${HOSTNAME_SHORT}.service"
TIMER_NAME="restic-backup-${HOSTNAME_SHORT}.timer"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"

# Stop and disable systemd units
printf "=== Stopping and disabling systemd units ===\n"
if systemctl is-active --quiet "${TIMER_NAME}" 2>/dev/null; then
  printf "Stopping timer: %s\n" "$TIMER_NAME"
  systemctl stop "${TIMER_NAME}"
fi

if systemctl is-enabled --quiet "${TIMER_NAME}" 2>/dev/null; then
  printf "Disabling timer: %s\n" "$TIMER_NAME"
  systemctl disable "${TIMER_NAME}"
fi

if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
  printf "Stopping service: %s\n" "$SERVICE_NAME"
  systemctl stop "${SERVICE_NAME}"
fi

if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
  printf "Disabling service: %s\n" "$SERVICE_NAME"
  systemctl disable "${SERVICE_NAME}"
fi

# Remove systemd unit files
printf "\n=== Removing systemd unit files ===\n"
if [ -f "$SERVICE_PATH" ]; then
  printf "Removing: %s\n" "$SERVICE_PATH"
  rm -f "$SERVICE_PATH"
fi

if [ -f "$TIMER_PATH" ]; then
  printf "Removing: %s\n" "$TIMER_PATH"
  rm -f "$TIMER_PATH"
fi

# Reload systemd to pick up changes
printf "Reloading systemd daemon...\n"
systemctl daemon-reload

# Remove wrapper script
printf "\n=== Removing wrapper script ===\n"
if [ -f "$WRAPPER_SCRIPT" ]; then
  printf "Removing: %s\n" "$WRAPPER_SCRIPT"
  rm -f "$WRAPPER_SCRIPT"
fi

# Remove configuration files
printf "\n=== Removing configuration files ===\n"
if [ -f "$ENV_FILE" ]; then
  printf "Removing: %s\n" "$ENV_FILE"
  rm -f "$ENV_FILE"
fi

if [ -f "$PASS_FILE" ]; then
  printf "Removing: %s\n" "$PASS_FILE"
  rm -f "$PASS_FILE"
fi

if [ -f "$EXCLUDE_FILE" ]; then
  printf "Removing: %s\n" "$EXCLUDE_FILE"
  rm -f "$EXCLUDE_FILE"
fi

# Remove backup files if they exist
if [ -f "${ENV_FILE}.bak" ]; then
  printf "Removing backup: %s\n" "${ENV_FILE}.bak"
  rm -f "${ENV_FILE}.bak"
fi

# Note about repository data preservation
printf "\n=== Repository Data ===\n"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  
  if [ -n "${RESTIC_REPOSITORY:-}" ]; then
    printf "Your backup repository: %s\n" "$RESTIC_REPOSITORY"
    printf "✓ Repository data will remain intact on the remote server\n"
    printf "✓ You can reinstall and access your existing backups later\n"
    printf "\nTo manually access your backups later:\n"
    printf "  RESTIC_REPOSITORY=%s restic snapshots\n" "$RESTIC_REPOSITORY"
  fi
else
  printf "No repository information found in configuration\n"
fi

# Handle restic binary removal if requested
if [ "$REMOVE_BINARY" = "1" ]; then
  printf "\n=== Restic Binary Removal ===\n"
  
  if command -v restic >/dev/null 2>&1; then
    RESTIC_PATH=$(command -v restic)
    printf "Found restic binary: %s\n" "$RESTIC_PATH"
    
    # Check if it was installed via package manager
    if command -v dpkg >/dev/null 2>&1 && dpkg -l restic >/dev/null 2>&1; then
      printf "Restic was installed via apt/dpkg, removing...\n"
      apt-get remove -y restic || {
        printf "⚠ Failed to remove restic via apt\n"
        printf "Manual removal: apt-get remove restic\n"
      }
    elif [ -f "/usr/bin/restic" ] || [ -f "/usr/local/bin/restic" ]; then
      printf "Do you want to remove the restic binary at %s? [y/N]: " "$RESTIC_PATH"
      read CONFIRM_BINARY
      
      case "$CONFIRM_BINARY" in
        [Yy]|[Yy][Ee][Ss])
          rm -f "$RESTIC_PATH" && printf "✓ Restic binary removed\n" || printf "⚠ Failed to remove restic binary\n"
          ;;
        *)
          printf "Restic binary removal skipped\n"
          ;;
      esac
    else
      printf "Restic binary location unknown, skipping removal\n"
    fi
  else
    printf "Restic binary not found\n"
  fi
fi

# Remove /etc/restic directory if it's empty
printf "\n=== Cleaning up directories ===\n"
if [ -d "$ETC_RESTIC_DIR" ]; then
  if [ -z "$(ls -A "$ETC_RESTIC_DIR" 2>/dev/null)" ]; then
    printf "Removing empty directory: %s\n" "$ETC_RESTIC_DIR"
    rmdir "$ETC_RESTIC_DIR"
  else
    printf "Directory not empty (contains other host configs): %s\n" "$ETC_RESTIC_DIR"
    printf "Remaining files:\n"
    ls -la "$ETC_RESTIC_DIR" | sed 's/^/  /'
  fi
fi

printf "\n=== Uninstall complete ===\n"
printf "All restic backup configuration for host '%s' has been removed.\n" "$HOSTNAME_SHORT"
if [ "$REMOVE_BINARY" = "1" ]; then
  printf "Restic binary removal attempted.\n"
fi
printf "\n✓ Your backup data remains safe on the remote repository\n"
printf "✓ You can reinstall and continue using your existing backups\n"
printf "\nTo reinstall: sudo ./install-restic.sh\n\n"

# Final verification
printf "=== Verification ===\n"
printf "Systemd timer status: "
if systemctl list-unit-files "${TIMER_NAME}" --no-legend 2>/dev/null | grep -q "${TIMER_NAME}"; then
  printf "still present (may need manual cleanup)\n"
else
  printf "✓ removed\n"
fi

printf "Systemd service status: "
if systemctl list-unit-files "${SERVICE_NAME}" --no-legend 2>/dev/null | grep -q "${SERVICE_NAME}"; then
  printf "still present (may need manual cleanup)\n"
else
  printf "✓ removed\n"
fi

printf "Configuration files: "
if [ -f "$ENV_FILE" ] || [ -f "$PASS_FILE" ] || [ -f "$EXCLUDE_FILE" ] || [ -f "$WRAPPER_SCRIPT" ]; then
  printf "some files still present\n"
else
  printf "✓ all removed\n"
fi

exit 0
