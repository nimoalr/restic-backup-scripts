# Restic Backup Scripts

Automated system-wide backup solution using [restic](https://restic.net/) with REST server backend and systemd scheduling.

## Overview

This project provides POSIX shell scripts to automatically set up weekly restic backups on Debian/Ubuntu systems. The backups use a REST server backend and run via systemd timers without requiring user intervention.

### Key Features

- **Automatic Installation**: Sets up complete backup system with one command
- **No Authentication Required**: Simplified setup for internal/Tailscale networks
- **Smart Connectivity**: Automatic hostname resolution with IP fallback
- **Repository Auto-initialization**: Creates repositories automatically if they don't exist
- **Systemd Integration**: Weekly automatic backups with proper service management
- **POSIX Compatible**: Works on all POSIX-compliant shells (dash, bash, etc.)
- **Clean Uninstall**: Complete removal of configuration while preserving backup data

## Components

### `linux/install-restic.sh`
Main installation script that:
- Installs restic if missing (via apt)
- Tests connectivity to REST server with hostname/IP fallback
- Creates configuration files and systemd units
- Automatically initializes repositories
- Sets up weekly backup schedule

### `linux/uninstall-restic.sh`
Complete uninstall script that:
- Stops and disables systemd timers/services
- Removes all configuration files
- Optionally removes restic binary
- Preserves backup data on remote repository

## Prerequisites

### REST Server Setup
You need a restic REST server running and accessible. Example Docker setup:

```bash
# Docker setup
docker run -d \
  --name restic-rest-server \
  -p 9999:8000 \
  -v /path/to/data:/data \
  restic/rest-server:latest \
  --path /data
```

### Network Requirements
- REST server accessible via HTTP (port 8000 by default)
- Hostname resolution or direct IP access
- No authentication required (suitable for internal networks only)

## Installation

### 1. Clone Repository
```bash
git clone https://github.com/nimoalr/restic-backup-scripts.git
cd restic-backup-scripts/linux
```

### 2. Run Installation
```bash
sudo ./install-restic.sh
```

The script will prompt for:
- **REST server endpoint** (e.g., `http://my-server:9999/`)
- **Repository encryption password** (store this safely!)
- **Backup paths** (default: `/home`)
- **Exclude file creation** (recommended)
- **Retention settings** (daily/weekly/monthly keep counts)

### 3. Verification
After installation, verify the setup:
```bash
# Check timer status
systemctl status restic-backup-$(hostname -s).timer

# View recent logs
journalctl -u restic-backup-$(hostname -s).service --no-pager

# Manual backup test
sudo /usr/local/bin/restic-backup-$(hostname -s).sh
```

## Configuration Files

All configuration is stored in `/etc/restic/$(hostname -s).*`:

- **`.env`** - Environment variables (repository URL, paths, retention)
- **`.pass`** - Repository encryption password (mode 600)
- **`.excludes`** - Backup exclusion patterns

## Systemd Integration

Creates two systemd units:
- **`restic-backup-HOSTNAME.service`** - Backup execution
- **`restic-backup-HOSTNAME.timer`** - Weekly schedule (OnCalendar=weekly)

## Backup Process

Each backup run:
1. **Connectivity Check** - Tests repository access with hostname/IP fallback
2. **Auto-initialization** - Creates repository if it doesn't exist
3. **Backup Execution** - Creates snapshot with exclusions and tags
4. **Cleanup** - Runs forget/prune with configured retention
5. **Logging** - Results available via journalctl

## Repository Management

### List Snapshots
```bash
# Using environment file
source /etc/restic/$(hostname -s).env
restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" snapshots

# Direct command
RESTIC_PASSWORD_FILE=/etc/restic/$(hostname -s).pass \
RESTIC_REPOSITORY=rest:http://your-server:8000/$(hostname -s) \
restic snapshots
```

### Restore Files
```bash
# Mount repository for browsing
mkdir /tmp/restic-mount
RESTIC_PASSWORD_FILE=/etc/restic/$(hostname -s).pass \
RESTIC_REPOSITORY=rest:http://your-server:8000/$(hostname -s) \
restic mount /tmp/restic-mount

# Restore specific snapshot
RESTIC_PASSWORD_FILE=/etc/restic/$(hostname -s).pass \
RESTIC_REPOSITORY=rest:http://your-server:8000/$(hostname -s) \
restic restore SNAPSHOT_ID --target /tmp/restore
```

## Troubleshooting

### Common Issues

**Hostname Resolution Problems**
- Script automatically detects and uses IP fallback
- Check `/etc/hosts` or DNS configuration
- Verify REST server accessibility: `curl http://your-server:8000`

**Repository Initialization Failures**
- Check REST server permissions (container user ID)
- Verify data directory ownership on host filesystem
- Test manual initialization: `restic init`

**Permission Errors**
- Ensure REST server data directory is writable
- For Docker: check user ID mapping and host permissions
- Example: `chown -R 568:568 /path/to/data` (match container user ID)

### Log Analysis
```bash
# View service logs
journalctl -u restic-backup-$(hostname -s).service -f

# Check timer schedule
systemctl list-timers restic-backup-$(hostname -s).timer

# Test connectivity manually
curl -I http://your-server:8000/$(hostname -s)
```

## Uninstallation

### Complete Removal
```bash
sudo ./uninstall-restic.sh
```

### Remove Binary Too
```bash
sudo ./uninstall-restic.sh --remove-binary
```

**Important**: Uninstallation only removes local configuration. Your backup data on the remote repository remains intact and can be accessed later.

## Security Considerations

### No Authentication Mode
This setup runs without REST server authentication, suitable for:
- Internal networks (LAN/Tailscale)
- Trusted environments
- Development/testing setups

**Not recommended** for internet-exposed servers.

### Encryption
- Repository data is encrypted with your chosen password
- Password stored locally in `/etc/restic/$(hostname -s).pass` (mode 600)
- **Critical**: Store your password safely - losing it means losing access to backups

### Network Security
- Use VPN (Tailscale) or private networks
- Consider firewall rules to restrict REST server access
- Monitor server logs for unexpected access

## Advanced Configuration

### Custom Schedules
Edit the timer file to change backup frequency:
```bash
sudo systemctl edit restic-backup-$(hostname -s).timer
```

### Multiple Backup Sets
Run the installer multiple times with different configurations:
- Use different REST server endpoints
- Backup different path sets
- Configure different retention policies

### REST Server with Authentication
To add authentication to your REST server:
```bash
# Generate password file
htpasswd -c /path/to/htpasswd username

# Run REST server with auth
docker run -d \
  --name restic-rest-server \
  -p 9999:8000 \
  -v /path/to/data:/data \
  -v /path/to/htpasswd:/etc/restic/htpasswd \
  restic/rest-server:latest \
  --path /data --htpasswd-file /etc/restic/htpasswd
```

## License

MIT License

## Links

- [Restic Documentation](https://restic.readthedocs.io/)
- [Restic REST Server Repository](https://github.com/restic/rest-server)
- [Restic Setup REST Server](https://restic.readthedocs.io/en/latest/030_preparing_a_new_repo.html#rest-server) 
