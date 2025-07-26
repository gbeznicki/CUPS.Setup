#!/bin/bash

# Grafana + Prometheus + Node Exporter Setup for Print Server Monitoring
# This script sets up a complete monitoring stack on Raspberry Pi

set -e

GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
NODE_EXPORTER_PORT=9100
CUPS_EXPORTER_PORT=9628

echo "==============================================="
echo "Grafana Print Server Monitoring Setup"
echo "==============================================="

# Check if running as regular user
if [ "$EUID" -eq 0 ]; then
    echo "Error: Please run this script as a regular user (not root)"
    exit 1
fi

# Function to check if port is available
check_port() {
    local port=$1
    if netstat -tuln | grep -q ":$port "; then
        echo "Warning: Port $port is already in use"
        return 1
    fi
    return 0
}

# Update system and install dependencies
install_dependencies() {
    echo "Installing dependencies..."
    sudo apt update
    sudo apt install -y curl wget apt-transport-https software-properties-common gnupg2 \
        prometheus prometheus-node-exporter python3-pip python3-venv bc jq

    echo "✓ Dependencies installed"
}

# Install Grafana
install_grafana() {
    echo "Installing Grafana..."

    # Add Grafana GPG key and repository
    wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
    echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list

    sudo apt update
    sudo apt install -y grafana

    # Enable and start Grafana
    sudo systemctl enable grafana-server
    sudo systemctl start grafana-server

    echo "✓ Grafana installed and started on port $GRAFANA_PORT"
}

# Configure Prometheus
configure_prometheus() {
    echo "Configuring Prometheus..."

    # Backup original config
    sudo cp /etc/prometheus/prometheus.yml /etc/prometheus/prometheus.yml.backup

    # Create new Prometheus configuration
    sudo tee /etc/prometheus/prometheus.yml > /dev/null << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "/etc/prometheus/rules/*.yml"

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['localhost:9100']
    scrape_interval: 5s

  - job_name: 'cups-exporter'
    static_configs:
      - targets: ['localhost:9628']
    scrape_interval: 10s

  - job_name: 'print-server-custom'
    static_configs:
      - targets: ['localhost:9629']
    scrape_interval: 30s

alerting:
  alertmanagers:
    - static_configs:
        - targets: []
EOF

    # Create rules directory
    sudo mkdir -p /etc/prometheus/rules

    # Create alerting rules for print server
    sudo tee /etc/prometheus/rules/printserver.yml > /dev/null << 'EOF'
groups:
  - name: printserver
    rules:
      - alert: PrinterOffline
        expr: up{job="cups-exporter"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "CUPS exporter is down"
          description: "The CUPS exporter has been down for more than 2 minutes."

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage detected"
          description: "CPU usage is above 80% for more than 5 minutes."

      - alert: HighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage detected"
          description: "Memory usage is above 85% for more than 5 minutes."

      - alert: LowDiskSpace
        expr: (1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})) * 100 > 85
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Low disk space"
          description: "Disk usage is above 85% for more than 5 minutes."

      - alert: PrintQueueStuck
        expr: cups_printer_jobs_total > 10
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Print queue has many pending jobs"
          description: "More than 10 jobs have been in the print queue for over 10 minutes."
EOF

    # Restart Prometheus
    sudo systemctl restart prometheus
    sudo systemctl enable prometheus

    echo "✓ Prometheus configured with print server monitoring"
}

# Create CUPS exporter
create_cups_exporter() {
    echo "Creating CUPS exporter..."

    # Create Python virtual environment
    python3 -m venv ~/cups_exporter_env
    source ~/cups_exporter_env/bin/activate

    # Install required Python packages
    pip install prometheus_client requests subprocess32 2>/dev/null || pip install prometheus_client requests

    # Create CUPS exporter script
    cat > ~/cups_exporter.py << 'EOF'
#!/usr/bin/env python3

import time
import subprocess
import re
import json
from prometheus_client import start_http_server, Gauge, Counter, Info
from prometheus_client.core import CollectorRegistry
import logging

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Prometheus metrics
registry = CollectorRegistry()

# System metrics
cups_up = Gauge('cups_up', 'CUPS service status (1=up, 0=down)', registry=registry)
printer_status = Gauge('cups_printer_status', 'Printer status (1=idle, 0=error)', ['printer'], registry=registry)
printer_jobs_total = Gauge('cups_printer_jobs_total', 'Total number of jobs in queue', ['printer'], registry=registry)
printer_jobs_completed = Counter('cups_printer_jobs_completed_total', 'Total completed print jobs', ['printer'], registry=registry)
printer_pages_printed = Counter('cups_printer_pages_printed_total', 'Total pages printed', ['printer'], registry=registry)

# System info
system_info = Info('printserver_info', 'Print server information', registry=registry)

class CUPSExporter:
    def __init__(self):
        self.printer_name = "HP_LaserJet_Pro_MFP_M26a"

    def get_cups_status(self):
        """Check if CUPS service is running"""
        try:
            result = subprocess.run(['systemctl', 'is-active', 'cups'],
                                  capture_output=True, text=True, timeout=5)
            return result.returncode == 0
        except Exception as e:
            logger.error(f"Error checking CUPS status: {e}")
            return False

    def get_printer_status(self):
        """Get printer status from CUPS"""
        try:
            result = subprocess.run(['lpstat', '-p', self.printer_name],
                                  capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                status_text = result.stdout.lower()
                if 'idle' in status_text:
                    return 1
                elif 'disabled' in status_text or 'stopped' in status_text:
                    return 0
                else:
                    return 0.5  # Unknown state
            return 0
        except Exception as e:
            logger.error(f"Error getting printer status: {e}")
            return 0

    def get_print_queue_info(self):
        """Get print queue information"""
        try:
            result = subprocess.run(['lpq', '-P', self.printer_name],
                                  capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                lines = result.stdout.strip().split('\n')
                # Count actual job lines (skip header and empty lines)
                job_count = 0
                for line in lines:
                    if line.strip() and not line.startswith('Rank') and 'no entries' not in line.lower():
                        job_count += 1
                return max(0, job_count)
            return 0
        except Exception as e:
            logger.error(f"Error getting queue info: {e}")
            return 0

    def get_usb_printer_connection(self):
        """Check if printer is connected via USB"""
        try:
            result = subprocess.run(['lsusb'], capture_output=True, text=True, timeout=5)
            return '03f0:932a' in result.stdout
        except Exception as e:
            logger.error(f"Error checking USB connection: {e}")
            return False

    def update_metrics(self):
        """Update all metrics"""
        try:
            # CUPS status
            cups_status = self.get_cups_status()
            cups_up.set(1 if cups_status else 0)

            if cups_status:
                # Printer status
                printer_stat = self.get_printer_status()
                printer_status.labels(printer=self.printer_name).set(printer_stat)

                # Queue information
                queue_size = self.get_print_queue_info()
                printer_jobs_total.labels(printer=self.printer_name).set(queue_size)

                # USB connection check
                usb_connected = self.get_usb_printer_connection()
                if not usb_connected:
                    logger.warning("USB printer connection lost!")

            # System information
            try:
                with open('/proc/version', 'r') as f:
                    kernel_version = f.read().strip()

                system_info.info({
                    'hostname': subprocess.run(['hostname'], capture_output=True, text=True).stdout.strip(),
                    'kernel': kernel_version.split()[2],
                    'printer_model': 'HP LaserJet Pro MFP M26a'
                })
            except Exception as e:
                logger.error(f"Error updating system info: {e}")

        except Exception as e:
            logger.error(f"Error updating metrics: {e}")

def main():
    exporter = CUPSExporter()

    # Start Prometheus metrics server
    start_http_server(9628, registry=registry)
    logger.info("CUPS Exporter started on port 9628")

    # Main collection loop
    while True:
        try:
            exporter.update_metrics()
            time.sleep(30)  # Update every 30 seconds
        except KeyboardInterrupt:
            logger.info("Shutting down CUPS exporter")
            break
        except Exception as e:
            logger.error(f"Error in main loop: {e}")
            time.sleep(10)  # Wait before retrying

if __name__ == '__main__':
    main()
EOF

    chmod +x ~/cups_exporter.py
    deactivate

    echo "✓ CUPS exporter created"
}

# Create custom print server metrics exporter
create_custom_exporter() {
    echo "Creating custom print server metrics exporter..."

    cat > ~/printserver_exporter.py << 'EOF'
#!/usr/bin/env python3

import time
import subprocess
import psutil
import os
from prometheus_client import start_http_server, Gauge
from prometheus_client.core import CollectorRegistry
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

registry = CollectorRegistry()

# Custom metrics
cpu_temperature = Gauge('rpi_cpu_temperature_celsius', 'CPU temperature in Celsius', registry=registry)
disk_usage_percent = Gauge('rpi_disk_usage_percent', 'Disk usage percentage', ['mountpoint'], registry=registry)
memory_usage_percent = Gauge('rpi_memory_usage_percent', 'Memory usage percentage', registry=registry)
cpu_usage_percent = Gauge('rpi_cpu_usage_percent', 'CPU usage percentage', registry=registry)
network_bytes_sent = Gauge('rpi_network_bytes_sent_total', 'Network bytes sent', ['interface'], registry=registry)
network_bytes_recv = Gauge('rpi_network_bytes_recv_total', 'Network bytes received', ['interface'], registry=registry)

class CustomExporter:
    def __init__(self):
        pass

    def get_cpu_temperature(self):
        """Get CPU temperature"""
        try:
            with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
                temp = float(f.read()) / 1000.0
                return temp
        except Exception as e:
            logger.error(f"Error reading CPU temperature: {e}")
            return 0

    def update_metrics(self):
        """Update all custom metrics"""
        try:
            # CPU temperature
            temp = self.get_cpu_temperature()
            cpu_temperature.set(temp)

            # CPU usage
            cpu_percent = psutil.cpu_percent(interval=1)
            cpu_usage_percent.set(cpu_percent)

            # Memory usage
            memory = psutil.virtual_memory()
            memory_usage_percent.set(memory.percent)

            # Disk usage
            disk = psutil.disk_usage('/')
            disk_usage_percent.labels(mountpoint='/').set(disk.percent)

            # Network statistics
            net_io = psutil.net_io_counters(pernic=True)
            for interface, stats in net_io.items():
                if interface.startswith(('eth', 'wlan')):
                    network_bytes_sent.labels(interface=interface).set(stats.bytes_sent)
                    network_bytes_recv.labels(interface=interface).set(stats.bytes_recv)

        except Exception as e:
            logger.error(f"Error updating metrics: {e}")

def main():
    exporter = CustomExporter()

    start_http_server(9629, registry=registry)
    logger.info("Custom Print Server Exporter started on port 9629")

    while True:
        try:
            exporter.update_metrics()
            time.sleep(15)  # Update every 15 seconds
        except KeyboardInterrupt:
            logger.info("Shutting down custom exporter")
            break
        except Exception as e:
            logger.error(f"Error in main loop: {e}")
            time.sleep(5)

if __name__ == '__main__':
    main()
EOF

    chmod +x ~/printserver_exporter.py

    echo "✓ Custom exporter created"
}

# Create systemd services for exporters
create_systemd_services() {
    echo "Creating systemd services for exporters..."

    # CUPS exporter service
    sudo tee /etc/systemd/system/cups-exporter.service > /dev/null << EOF
[Unit]
Description=CUPS Prometheus Exporter
After=network.target cups.service
Requires=cups.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME
Environment=PATH=$HOME/cups_exporter_env/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$HOME/cups_exporter_env/bin/python $HOME/cups_exporter.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Custom exporter service
    sudo tee /etc/systemd/system/printserver-exporter.service > /dev/null << EOF
[Unit]
Description=Print Server Custom Prometheus Exporter
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME
ExecStart=/usr/bin/python3 $HOME/printserver_exporter.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Install psutil for custom exporter
    sudo apt install -y python3-psutil

    # Reload systemd and start services
    sudo systemctl daemon-reload
    sudo systemctl enable cups-exporter.service
    sudo systemctl enable printserver-exporter.service
    sudo systemctl start cups-exporter.service
    sudo systemctl start printserver-exporter.service

    echo "✓ Systemd services created and started"
}

# Configure Grafana datasources and dashboards
configure_grafana() {
    echo "Configuring Grafana..."

    # Wait for Grafana to start
    echo "Waiting for Grafana to start..."
    sleep 30

    # Create datasource configuration
    cat > /tmp/prometheus-datasource.json << EOF
{
  "name": "Prometheus",
  "type": "prometheus",
  "url": "http://localhost:9090",
  "access": "proxy",
  "isDefault": true
}
EOF

    # Add Prometheus datasource (using default admin:admin credentials)
    curl -X POST \
        -H "Content-Type: application/json" \
        -d @/tmp/prometheus-datasource.json \
        http://admin:admin@localhost:3000/api/datasources \
        2>/dev/null || echo "Datasource may already exist"

    rm /tmp/prometheus-datasource.json

    echo "✓ Grafana datasource configured"
}

# Create Grafana dashboard
create_dashboard() {
    echo "Creating Grafana dashboard..."

    cat > /tmp/printserver-dashboard.json << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "Print Server Monitoring",
    "tags": ["print-server", "raspberry-pi"],
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "title": "CUPS Service Status",
        "type": "stat",
        "targets": [
          {
            "expr": "cups_up",
            "legendFormat": "CUPS Status"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "mappings": [
              {
                "options": {
                  "0": {
                    "text": "DOWN",
                    "color": "red"
                  },
                  "1": {
                    "text": "UP",
                    "color": "green"
                  }
                },
                "type": "value"
              }
            ],
            "thresholds": {
              "steps": [
                {
                  "color": "red",
                  "value": null
                },
                {
                  "color": "green",
                  "value": 1
                }
              ]
            }
          }
        },
        "gridPos": {
          "h": 4,
          "w": 6,
          "x": 0,
          "y": 0
        }
      },
      {
        "id": 2,
        "title": "Printer Status",
        "type": "stat",
        "targets": [
          {
            "expr": "cups_printer_status",
            "legendFormat": "{{printer}}"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "mappings": [
              {
                "options": {
                  "0": {
                    "text": "ERROR",
                    "color": "red"
                  },
                  "1": {
                    "text": "IDLE",
                    "color": "green"
                  }
                },
                "type": "value"
              }
            ]
          }
        },
        "gridPos": {
          "h": 4,
          "w": 6,
          "x": 6,
          "y": 0
        }
      },
      {
        "id": 3,
        "title": "Print Queue Size",
        "type": "stat",
        "targets": [
          {
            "expr": "cups_printer_jobs_total",
            "legendFormat": "Jobs in Queue"
          }
        ],
        "gridPos": {
          "h": 4,
          "w": 6,
          "x": 12,
          "y": 0
        }
      },
      {
        "id": 4,
        "title": "CPU Usage",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rpi_cpu_usage_percent",
            "legendFormat": "CPU Usage %"
          }
        ],
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 4
        }
      },
      {
        "id": 5,
        "title": "Memory Usage",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rpi_memory_usage_percent",
            "legendFormat": "Memory Usage %"
          }
        ],
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 4
        }
      },
      {
        "id": 6,
        "title": "CPU Temperature",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rpi_cpu_temperature_celsius",
            "legendFormat": "CPU Temperature °C"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "thresholds": {
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "yellow",
                  "value": 60
                },
                {
                  "color": "red",
                  "value": 70
                }
              ]
            }
          }
        },
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 12
        }
      },
      {
        "id": 7,
        "title": "Disk Usage",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rpi_disk_usage_percent",
            "legendFormat": "Disk Usage % ({{mountpoint}})"
          }
        ],
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 12
        }
      }
    ],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "30s"
  }
}
EOF

    # Import dashboard
    curl -X POST \
        -H "Content-Type: application/json" \
        -d @/tmp/printserver-dashboard.json \
        http://admin:admin@localhost:3000/api/dashboards/db \
        2>/dev/null || echo "Dashboard import may have failed"

    rm /tmp/printserver-dashboard.json

    echo "✓ Dashboard created"
}

# Create monitoring management script
create_management_script() {
    echo "Creating monitoring management script..."

    cat > ~/grafana_control.sh << 'EOF'
#!/bin/bash

case "$1" in
    status)
        echo "=== Grafana Monitoring Stack Status ==="
        echo ""
        echo "Grafana:"
        systemctl status grafana-server --no-pager -l
        echo ""
        echo "Prometheus:"
        systemctl status prometheus --no-pager -l
        echo ""
        echo "Node Exporter:"
        systemctl status prometheus-node-exporter --no-pager -l
        echo ""
        echo "CUPS Exporter:"
        systemctl status cups-exporter --no-pager -l
        echo ""
        echo "Custom Exporter:"
        systemctl status printserver-exporter --no-pager -l
        ;;
    restart)
        echo "Restarting all monitoring services..."
        sudo systemctl restart grafana-server
        sudo systemctl restart prometheus
        sudo systemctl restart prometheus-node-exporter
        sudo systemctl restart cups-exporter
        sudo systemctl restart printserver-exporter
        echo "All services restarted"
        ;;
    logs)
        echo "Recent logs from monitoring services:"
        echo ""
        echo "=== Grafana Logs ==="
        sudo journalctl -u grafana-server --no-pager -n 20
        echo ""
        echo "=== Prometheus Logs ==="
        sudo journalctl -u prometheus --no-pager -n 20
        echo ""
        echo "=== CUPS Exporter Logs ==="
        sudo journalctl -u cups-exporter --no-pager -n 20
        ;;
    urls)
        PI_IP=$(hostname -I | awk '{print $1}')
        echo "Monitoring URLs:"
        echo "Grafana Dashboard: http://$PI_IP:3000"
        echo "  Username: admin"
        echo "  Password: admin (change this!)"
        echo ""
        echo "Prometheus: http://$PI_IP:9090"
        echo "Node Exporter: http://$PI_IP:9100"
        echo "CUPS Exporter: http://$PI_IP:9628"
        echo "Custom Exporter: http://$PI_IP:9629"
        ;;
    *)
        echo "Usage: $0 {status|restart|logs|urls}"
        echo ""
        echo "  status  - Show status of all monitoring services"
        echo "  restart - Restart all monitoring services"
        echo "  logs    - Show recent logs from services"
        echo "  urls    - Show monitoring URLs and credentials"
        ;;
esac
EOF

    chmod +x ~/grafana_control.sh
    echo "✓ Management script created: ~/grafana_control.sh"
}

# Main execution
main() {
    echo "Starting Grafana monitoring stack installation..."

    # Check ports
    echo "Checking port availability..."
    check_port $GRAFANA_PORT || echo "Port $GRAFANA_PORT may conflict"
    check_port $PROMETHEUS_PORT || echo "Port $PROMETHEUS_PORT may conflict"

    # Install components
    install_dependencies
    install_grafana
    configure_prometheus
    create_cups_exporter
    create_custom_exporter
    create_systemd_services

    # Wait for services to stabilize
    echo "Waiting for services to start..."
    sleep 45

    # Configure Grafana
    configure_grafana
    create_dashboard
    create_management_script

    # Final status check
    echo ""
    echo "==============================================="
    echo "Grafana Monitoring Setup Complete!"
    echo "==============================================="

    PI_IP=$(hostname -I | awk '{print $1}')
    echo "Access your monitoring at:"
    echo "  Grafana: http://$PI_IP:3000"
    echo "  Username: admin"
    echo "  Password: admin"
    echo ""
    echo "IMPORTANT: Change the default Grafana password!"
    echo ""
    echo "Other endpoints:"
    echo "  Prometheus: http://$PI_IP:9090"
    echo "  Node Exporter: http://$PI_IP:9100"
    echo "  CUPS Exporter: http://$PI_IP:9628"
    echo ""
    echo "Management commands:"
    echo "  ~/grafana_control.sh status  - Check all services"
    echo "  ~/grafana_control.sh urls    - Show access URLs"
    echo "  ~/grafana_control.sh restart - Restart services"
    echo ""

    # Show service status
    echo "Current service status:"
    systemctl is-active grafana-server && echo "✓ Grafana: Running" || echo "✗ Grafana: Not running"
    systemctl is-active prometheus && echo "✓ Prometheus: Running" || echo "✗ Prometheus: Not running"
    systemctl is-active cups-exporter && echo "✓ CUPS Exporter: Running" || echo "✗ CUPS Exporter: Not running"
    systemctl is-active printserver-exporter && echo "✓ Custom Exporter: Running" || echo "✗ Custom Exporter: Not running"
}

# Run main function
main
