# CUPS Print Server Setup Guide for Raspberry Pi

## Overview
This guide will set up your Raspberry Pi as a network print server for the HP LaserJet Pro MFP M26a, making it accessible to all devices on your 192.168.1.x network.

*Solution developed with assistance from Claude (Anthropic) - AI-powered coding assistant specializing in Raspberry Pi and system administration.*

## Prerequisites
- Raspberry Pi 4 with Raspberry Pi OS
- HP LaserJet Pro MFP M26a connected via USB
- Ethernet connection to your network
- Internet access for downloading packages

## Step-by-Step Setup

### Step 1: System Update and Package Installation
```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install CUPS and related packages
sudo apt install -y cups cups-bsd cups-client cups-filters ghostscript hplip

# Install additional tools for monitoring and email
sudo apt install -y avahi-utils samba-common-bin mailutils postfix
```

### Step 2: Configure CUPS
```bash
# Add your user to the lpadmin group
sudo usermod -aG lpadmin $USER

# Backup original CUPS configuration
sudo cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.backup

# Apply our CUPS configuration
sudo cp cupsd.conf /etc/cups/cupsd.conf

# Set proper permissions
sudo chown root:lp /etc/cups/cupsd.conf
sudo chmod 640 /etc/cups/cupsd.conf
```

### Step 3: Configure Printer
```bash
# Run the printer setup script
chmod +x setup_printer.sh
./setup_printer.sh
```

### Step 4: Set Up Monitoring (Choose One Approach)

### Option A: Basic Email Monitoring
```bash
# Configure email alerts for basic monitoring
chmod +x setup_monitoring.sh
./setup_monitoring.sh
```

### Option B: Advanced Grafana Monitoring (Recommended)
```bash
# Set up comprehensive Grafana monitoring dashboard
chmod +x setup_grafana_monitoring.sh
./setup_grafana_monitoring.sh
```

### Step 5: Enable and Start Services
```bash
# Enable CUPS to start on boot
sudo systemctl enable cups

# Start CUPS service
sudo systemctl start cups

# Enable Avahi for printer discovery
sudo systemctl enable avahi-daemon
sudo systemctl start avahi-daemon

# Restart CUPS to apply all changes
sudo systemctl restart cups
```

### Step 6: Verify Installation
```bash
# Check CUPS status
sudo systemctl status cups

# List available printers
lpstat -p -d

# Check if printer is discoverable on network
avahi-browse -t _ipp._tcp
```

## Testing the Setup

### From the Raspberry Pi:
```bash
# Print a test page
lp -d HP_LaserJet_Pro_MFP_M26a /usr/share/cups/data/testprint

# Check print queue
lpq -P HP_LaserJet_Pro_MFP_M26a
```

### From Windows:
1. Open Settings → Devices → Printers & scanners
2. Click "Add a printer or scanner"
3. Select "HP LaserJet Pro MFP M26a" when it appears
4. Follow the installation wizard

### From macOS:
1. Open System Preferences → Printers & Scanners
2. Click the "+" button
3. Select "HP LaserJet Pro MFP M26a" from the list
4. Click "Add"

### From Mobile:
- iOS: The printer should appear automatically in print dialogs
- Android: Install "HP Smart" app or use built-in printing

## Monitoring and Maintenance

### Option A: Basic Email Monitoring

**Features:**
- Email alerts for printer issues
- System health checks
- Local email delivery with optional external SMTP
- Automated cron job monitoring every 5 minutes

**Management:**
```bash
# Check monitoring status
~/monitoring_control.sh status

# View monitoring logs
tail -f /tmp/printer_monitor.log

# Test monitoring script manually
~/monitor_printer.sh
```

### Option B: Grafana Monitoring Dashboard (Recommended)

**Features:**
- Professional web-based dashboard
- Real-time metrics visualization
- Historical data and trends
- Visual alerts and status indicators
- Mobile-friendly interface
- Multiple exporters for comprehensive monitoring

**Components:**
- **Grafana** (Port 3000): Main dashboard interface
- **Prometheus** (Port 9090): Metrics collection and storage
- **Node Exporter** (Port 9100): System metrics
- **CUPS Exporter** (Port 9628): Printer-specific metrics
- **Custom Exporter** (Port 9629): Raspberry Pi metrics

**Access:**
- Dashboard: `http://192.168.1.XXX:3000` (Username: admin, Password: admin)
- **Important:** Change default password after first login!

**Management:**
```bash
# Check all monitoring services status
~/grafana_control.sh status

# Show monitoring URLs and credentials
~/grafana_control.sh urls

# Restart all monitoring services
~/grafana_control.sh restart

# View service logs
~/grafana_control.sh logs
```

**Dashboard Metrics:**
- CUPS service status and printer status
- Print queue size and job history
- CPU usage, memory, disk space, temperature
- Network traffic monitoring
- Service health indicators
- System information table

## Web Interfaces

### CUPS Web Interface
- **URL:** `http://192.168.1.XXX:631` (replace XXX with your Pi's IP)
- **Purpose:** Manage print jobs and printer settings
- **Access:** Available from any device on your network

### Grafana Dashboard (If Option B chosen)
- **URL:** `http://192.168.1.XXX:3000`
- **Username:** admin
- **Password:** admin (change immediately!)
- **Purpose:** Comprehensive monitoring and visualization
```bash
# Check printer status
lpstat -p HP_LaserJet_Pro_MFP_M26a

# Clear print queue
cancel -a HP_LaserJet_Pro_MFP_M26a

# Restart CUPS service
sudo systemctl restart cups

# View CUPS logs
sudo tail -f /var/log/cups/error_log
```

## Troubleshooting

### Printer Not Found:
```bash
# Check USB connection
lsusb | grep HP

# Restart CUPS
sudo systemctl restart cups
```

### Network Discovery Issues:
```bash
# Check Avahi status
sudo systemctl status avahi-daemon

# Restart network discovery
sudo systemctl restart avahi-daemon
```

### Print Jobs Stuck:
```bash
# Clear all jobs
sudo cancel -a

# Restart printer
sudo cupsdisable HP_LaserJet_Pro_MFP_M26a
sudo cupsenable HP_LaserJet_Pro_MFP_M26a
```

## Files Created by This Setup

### Core Print Server Files
- `cupsd.conf` - CUPS daemon configuration
- `setup_printer.sh` - Printer installation script
- `manage_printer.sh` - Basic printer management commands

### Basic Monitoring Files (Option A)
- `setup_monitoring.sh` - Email monitoring setup script
- `monitor_printer.sh` - Printer monitoring script (runs via cron)
- `system_health_check.sh` - System health monitoring
- `monitoring_control.sh` - Monitoring management script

### Grafana Monitoring Files (Option B)
- `setup_grafana_monitoring.sh` - Complete Grafana stack setup
- `cups_exporter.py` - CUPS metrics exporter
- `printserver_exporter.py` - Custom system metrics exporter
- `print-server-dashboard.json` - Grafana dashboard configuration
- `grafana_control.sh` - Monitoring stack management script

### System Service Files (Created automatically)
- `/etc/systemd/system/cups-exporter.service` - CUPS exporter service
- `/etc/systemd/system/printserver-exporter.service` - Custom exporter service

## Security Notes
- CUPS is configured to allow access from your local network (192.168.1.x)
- No authentication required for local network printing access
- CUPS web interface accessible but requires admin privileges for configuration changes
- Grafana dashboard (if installed) uses default credentials - **change immediately after setup**
- All monitoring services are configured to run with minimal privileges
