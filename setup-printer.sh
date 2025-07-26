#!/bin/bash

# HP LaserJet Pro MFP M26a Setup Script for Raspberry Pi
# This script automatically detects and configures the printer

set -e

PRINTER_NAME="HP_LaserJet_Pro_MFP_M26a"
PRINTER_DESCRIPTION="HP LaserJet Pro MFP M26a"
PRINTER_LOCATION="Raspberry Pi Print Server"
PRINTER_MODEL="HP LaserJet Pro MFP M26a"

echo "==============================================="
echo "HP LaserJet Pro MFP M26a Setup Script"
echo "==============================================="

# Check if running as regular user
if [ "$EUID" -eq 0 ]; then
    echo "Error: Please run this script as a regular user (not root)"
    exit 1
fi

# Check if printer is connected
echo "Checking for connected printer..."
if ! lsusb | grep -q "03f0:932a"; then
    echo "Error: HP LaserJet Pro MFP M26a not found!"
    echo "Please ensure the printer is connected via USB and powered on."
    exit 1
fi

echo "✓ Printer detected: HP LaserJet Pro MFP M26a"

# Check if CUPS is running
echo "Checking CUPS service..."
if ! systemctl is-active --quiet cups; then
    echo "Starting CUPS service..."
    sudo systemctl start cups
fi

# Wait for CUPS to be ready
sleep 3

# Remove existing printer if it exists
echo "Removing any existing printer configuration..."
if lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
    echo "Removing existing printer: $PRINTER_NAME"
    lpadmin -x "$PRINTER_NAME" || true
fi

# Find the correct USB device path
echo "Detecting USB device path..."
USB_DEVICE=$(sudo hp-makeuri -c usb | grep "03f0:932a" | head -1 | cut -d' ' -f1)

if [ -z "$USB_DEVICE" ]; then
    echo "Warning: hp-makeuri failed, using standard USB path"
    USB_DEVICE="usb://HP/LaserJet%20Pro%20MFP%20M26a?serial=000000000000"
fi

echo "Using device URI: $USB_DEVICE"

# Download and install HP driver if needed
echo "Checking HP driver installation..."
if ! hp-check -t 2>/dev/null | grep -q "M26a"; then
    echo "Installing HP drivers..."
    sudo hp-setup -i -a -x -q
fi

# Add the printer
echo "Adding printer to CUPS..."
lpadmin -p "$PRINTER_NAME" \
    -E \
    -v "$USB_DEVICE" \
    -m "drv:///hp/hpcups.drv/hp-laserjet_pro_mfp_m26a-pcl3.ppd" \
    -D "$PRINTER_DESCRIPTION" \
    -L "$PRINTER_LOCATION"

# Set as default printer
echo "Setting as default printer..."
lpadmin -d "$PRINTER_NAME"

# Enable the printer
echo "Enabling printer..."
cupsenable "$PRINTER_NAME"
cupsaccept "$PRINTER_NAME"

# Configure printer options for office use
echo "Configuring printer options..."
lpadmin -p "$PRINTER_NAME" -o media=A4
lpadmin -p "$PRINTER_NAME" -o sides=one-sided
lpadmin -p "$PRINTER_NAME" -o print-quality=normal
lpadmin -p "$PRINTER_NAME" -o printer-resolution=600dpi

# Create printer-specific script for easy management
cat > ~/manage_printer.sh << 'EOF'
#!/bin/bash

case "$1" in
    status)
        echo "Printer Status:"
        lpstat -p HP_LaserJet_Pro_MFP_M26a -l
        echo ""
        echo "Print Queue:"
        lpq -P HP_LaserJet_Pro_MFP_M26a
        ;;
    test)
        echo "Printing test page..."
        echo "This is a test page from Raspberry Pi Print Server" | lp -d HP_LaserJet_Pro_MFP_M26a
        echo "Test page sent to printer"
        ;;
    clear)
        echo "Clearing print queue..."
        cancel -a HP_LaserJet_Pro_MFP_M26a
        echo "Print queue cleared"
        ;;
    restart)
        echo "Restarting printer..."
        cupsdisable HP_LaserJet_Pro_MFP_M26a
        sleep 2
        cupsenable HP_LaserJet_Pro_MFP_M26a
        cupsaccept HP_LaserJet_Pro_MFP_M26a
        echo "Printer restarted"
        ;;
    *)
        echo "Usage: $0 {status|test|clear|restart}"
        echo ""
        echo "  status  - Show printer and queue status"
        echo "  test    - Print a test page"
        echo "  clear   - Clear print queue"
        echo "  restart - Restart printer"
        ;;
esac
EOF

chmod +x ~/manage_printer.sh

# Test the printer
echo "Testing printer connectivity..."
if lpstat -p "$PRINTER_NAME" | grep -q "idle"; then
    echo "✓ Printer is ready and idle"
else
    echo "⚠ Printer may not be ready. Check status with: lpstat -p $PRINTER_NAME"
fi

# Print test page
echo "Printing test page..."
echo "Test page from Raspberry Pi Print Server - $(date)" | lp -d "$PRINTER_NAME" -o media=A4

echo ""
echo "==============================================="
echo "Setup Complete!"
echo "==============================================="
echo "Printer Name: $PRINTER_NAME"
echo "Description: $PRINTER_DESCRIPTION"
echo "Location: $PRINTER_LOCATION"
echo ""
echo "The printer should now be discoverable on your network."
echo "Test it by printing from any device on your 192.168.1.x network."
echo ""
echo "Useful commands:"
echo "  lpstat -p                    # Check printer status"
echo "  lpq                          # Check print queue"
echo "  ~/manage_printer.sh status   # Detailed printer status"
echo "  ~/manage_printer.sh test     # Print test page"
echo ""
echo "Web interface: http://$(hostname -I | awk '{print $1}'):631"
echo ""

# Show current status
echo "Current Status:"
lpstat -p "$PRINTER_NAME"
echo ""
echo "Recent jobs:"
lpstat -o 2>/dev/null || echo "No current print jobs"
