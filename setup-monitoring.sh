#!/bin/bash

# Monitoring and Email Alert Setup for CUPS Print Server
# Sets up email notifications for printer issues

set -e

echo "==============================================="
echo "Print Server Monitoring Setup"
echo "==============================================="

# Check if running as regular user
if [ "$EUID" -eq 0 ]; then
    echo "Error: Please run this script as a regular user (not root)"
    exit 1
fi

# Function to configure postfix
configure_postfix() {
    echo "Configuring Postfix for email alerts..."

    # Reconfigure postfix for local delivery
    sudo debconf-set-selections <<< "postfix postfix/mailname string $(hostname -f)"
    sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Local only'"
    sudo dpkg-reconfigure -f noninteractive postfix

    # Update postfix configuration
    sudo postconf -e "myhostname = $(hostname -f)"
    sudo postconf -e "mydestination = $(hostname -f), localhost.localdomain, localhost"
    sudo postconf -e "mynetworks = 127.0.0.0/8"
    sudo postconf -e "inet_interfaces = loopback-only"

    # Restart postfix
    sudo systemctl restart postfix
    sudo systemctl enable postfix

    echo "✓ Postfix configured for local email delivery"
}

# Function to get email configuration
get_email_config() {
    echo ""
    echo "Email Configuration:"
    echo "For monitoring alerts, you can:"
    echo "1. Use local email (messages stored on Pi)"
    echo "2. Configure external email (Gmail, etc.) - requires additional setup"
    echo ""

    read -p "Enter your email address for alerts (leave empty for local only): " EMAIL_ADDRESS

    if [ -n "$EMAIL_ADDRESS" ]; then
        echo "Note: External email requires additional SMTP configuration."
        echo "For now, setting up local delivery. You can configure external SMTP later."
    fi

    # Default to local user if no external email provided
    if [ -z "$EMAIL_ADDRESS" ]; then
        EMAIL_ADDRESS="$USER@localhost"
    fi

    echo "Using email address: $EMAIL_ADDRESS"
}

# Create monitoring script
create_monitoring_script() {
    echo "Creating printer monitoring script..."

    cat > ~/monitor_printer.sh << EOF
#!/bin/bash

# Printer Monitoring Script
# Checks printer status and sends alerts if issues detected

PRINTER_NAME="HP_LaserJet_Pro_MFP_M26a"
EMAIL_ADDRESS="$EMAIL_ADDRESS"
LOG_FILE="/tmp/printer_monitor.log"
STATUS_FILE="/tmp/printer_last_status"

# Function to log messages
log_message() {
    echo "\$(date): \$1" >> "\$LOG_FILE"
}

# Function to send email alert
send_alert() {
    local subject="\$1"
    local message="\$2"

    echo -e "\$message\n\nTime: \$(date)\nPrinter: \$PRINTER_NAME\nServer: \$(hostname)" | \\
        mail -s "\$subject" "\$EMAIL_ADDRESS" 2>/dev/null || \\
        logger "Failed to send email alert: \$subject"

    log_message "ALERT: \$subject"
}

# Check if CUPS is running
if ! systemctl is-active --quiet cups; then
    send_alert "CUPS Service Down" "The CUPS printing service has stopped running on \$(hostname)."
    exit 1
fi

# Check if printer exists in CUPS
if ! lpstat -p "\$PRINTER_NAME" >/dev/null 2>&1; then
    send_alert "Printer Not Found" "The printer \$PRINTER_NAME is not configured in CUPS."
    exit 1
fi

# Get printer status
PRINTER_STATUS=\$(lpstat -p "\$PRINTER_NAME" 2>/dev/null)
PRINTER_JOBS=\$(lpq -P "\$PRINTER_NAME" 2>/dev/null | wc -l)

# Check for printer errors
if echo "\$PRINTER_STATUS" | grep -q "disabled\|stopped\|not ready"; then
    if [ ! -f "\$STATUS_FILE" ] || ! grep -q "ERROR" "\$STATUS_FILE"; then
        send_alert "Printer Error Detected" "Printer status: \$PRINTER_STATUS"
        echo "ERROR" > "\$STATUS_FILE"
    fi
elif echo "\$PRINTER_STATUS" | grep -q "idle\|processing"; then
    if [ -f "\$STATUS_FILE" ] && grep -q "ERROR" "\$STATUS_FILE"; then
        send_alert "Printer Back Online" "Printer has recovered and is now: \$PRINTER_STATUS"
        echo "OK" > "\$STATUS_FILE"
    fi
    log_message "Status OK: \$PRINTER_STATUS"
fi

# Check for stuck jobs (more than 10 jobs queued)
if [ "\$PRINTER_JOBS" -gt 10 ]; then
    send_alert "Print Queue Warning" "Large number of jobs in queue: \$PRINTER_JOBS jobs pending"
fi

# Check USB connection
if ! lsusb | grep -q "03f0:932a"; then
    send_alert "USB Connection Lost" "HP LaserJet Pro MFP M26a is not detected on USB. Please check connections."
fi

# Cleanup old logs (keep last 100 lines)
if [ -f "\$LOG_FILE" ]; then
    tail -n 100 "\$LOG_FILE" > "\$LOG_FILE.tmp" && mv "\$LOG_FILE.tmp" "\$LOG_FILE"
fi
EOF

    chmod +x ~/monitor_printer.sh
    echo "✓ Monitoring script created: ~/monitor_printer.sh"
}

# Create detailed system monitoring script
create_system_monitor() {
    echo "Creating system monitoring script..."

    cat > ~/system_health_check.sh << 'EOF'
#!/bin/bash

# System Health Check for Print Server
# Comprehensive monitoring of system resources and print server health

EMAIL_ADDRESS="$EMAIL_ADDRESS"
HOSTNAME=$(hostname)
LOG_FILE="/tmp/system_health.log"

# Function to log and potentially alert
check_and_alert() {
    local check_name="$1"
    local threshold="$2"
    local current_value="$3"
    local comparison="$4"  # gt, lt, eq
    local alert_message="$5"

    case $comparison in
        "gt")
            if (( $(echo "$current_value > $threshold" | bc -l) )); then
                echo "WARNING: $check_name - $alert_message (Current: $current_value, Threshold: $threshold)"
                echo "$(date): WARNING $check_name: $current_value > $threshold" >> "$LOG_FILE"
                return 1
            fi
            ;;
        "lt")
            if (( $(echo "$current_value < $threshold" | bc -l) )); then
                echo "WARNING: $check_name - $alert_message (Current: $current_value, Threshold: $threshold)"
                echo "$(date): WARNING $check_name: $current_value < $threshold" >> "$LOG_FILE"
                return 1
            fi
            ;;
    esac

    echo "OK: $check_name ($current_value)"
    return 0
}

echo "System Health Check - $(date)"
echo "================================"

# Check CPU usage
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
check_and_alert "CPU Usage" "80" "$CPU_USAGE" "gt" "High CPU usage detected"

# Check memory usage
MEMORY_USAGE=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')
check_and_alert "Memory Usage" "90" "$MEMORY_USAGE" "gt" "High memory usage detected"

# Check disk usage
DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
check_and_alert "Disk Usage" "85" "$DISK_USAGE" "gt" "Low disk space detected"

# Check system temperature
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)
    TEMP_C=$((TEMP/1000))
    check_and_alert "CPU Temperature" "70" "$TEMP_C" "gt" "High CPU temperature detected"
fi

# Check network connectivity
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "OK: Network connectivity"
else
    echo "WARNING: Network connectivity issues"
    echo "$(date): WARNING Network: No internet connectivity" >> "$LOG_FILE"
fi

# Check CUPS service
if systemctl is-active --quiet cups; then
    echo "OK: CUPS service running"
else
    echo "CRITICAL: CUPS service not running"
    echo "$(date): CRITICAL CUPS service down" >> "$LOG_FILE"
fi

# Check available updates
UPDATES=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
if [ "$UPDATES" -gt 0 ]; then
    echo "INFO: $UPDATES package updates available"
fi

echo ""
echo "System health check completed."
EOF

    chmod +x ~/system_health_check.sh
    echo "✓ System health check script created: ~/system_health_check.sh"
}

# Setup cron jobs for monitoring
setup_cron_jobs() {
    echo "Setting up monitoring cron jobs..."

    # Create cron jobs
    (crontab -l 2>/dev/null || echo "") | grep -v "monitor_printer\|system_health_check" > /tmp/current_cron

    # Add monitoring jobs
    cat >> /tmp/current_cron << EOF

# Print server monitoring - every 5 minutes
*/5 * * * * $HOME/monitor_printer.sh >/dev/null 2>&1

# System health check - every hour
0 * * * * $HOME/system_health_check.sh >/dev/null 2>&1

# Daily summary report - at 8 AM
0 8 * * * echo "Daily Print Server Report - \$(date)" | mail -s "Print Server Daily Report" $EMAIL_ADDRESS
EOF

    crontab /tmp/current_cron
    rm /tmp/current_cron

    echo "✓ Cron jobs configured for automated monitoring"
}

# Create log rotation configuration
setup_log_rotation() {
    echo "Setting up log rotation..."

    sudo tee /etc/logrotate.d/printserver << EOF >/dev/null
/tmp/printer_monitor.log /tmp/system_health.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

    echo "✓ Log rotation configured"
}

# Main execution
echo "Starting monitoring setup..."

# Configure email system
configure_postfix

# Get email configuration
get_email_config

# Create monitoring scripts
create_monitoring_script
create_system_monitor

# Setup automated monitoring
setup_cron_jobs

# Setup log rotation
setup_log_rotation

# Test email functionality
echo ""
echo "Testing email functionality..."
if echo "Test email from Print Server setup - $(date)" | mail -s "Print Server Setup Complete" "$EMAIL_ADDRESS" 2>/dev/null; then
    echo "✓ Test email sent successfully"
else
    echo "⚠ Email test failed - check configuration"
fi

# Create management script for monitoring
cat > ~/monitoring_control.sh << 'EOF'
#!/bin/bash

case "$1" in
    status)
        echo "=== Print Server Monitoring Status ==="
        echo ""
        echo "CUPS Service:"
        systemctl status cups --no-pager -l
        echo ""
        echo "Postfix Service:"
        systemctl status postfix --no-pager -l
        echo ""
        echo "Recent Monitoring Logs:"
        if [ -f /tmp/printer_monitor.log ]; then
            echo "Printer Monitor:"
            tail -n 10 /tmp/printer_monitor.log
        fi
        echo ""
        if [ -f /tmp/system_health.log ]; then
            echo "System Health:"
            tail -n
