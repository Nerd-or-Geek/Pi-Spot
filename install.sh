#!/bin/bash
# ================================================
# pi4g-hotspot/install.sh
# Full installer for Quectel EC25 + Soracom on Raspberry Pi Zero W
# Run with: sudo ./install.sh
# ================================================

set -e

echo "=================================================="
echo "   Pi 4G LTE Hotspot Installer (Quectel EC25)"
echo "   For Soracom SIM (AT&T / T-Mobile / Verizon)"
echo "=================================================="

# 1. Update and install ALL required packages
echo "→ Installing dependencies..."
sudo apt update
sudo apt install -y hostapd dnsmasq iptables minicom usbutils rfkill git curl

# 2. Unblock WiFi (critical on Bookworm)
echo "→ Unblocking WiFi..."
sudo rfkill unblock wifi
sudo rfkill unblock all

# 3. Force EC25 into ECM mode (creates usb0)
echo "→ Setting Quectel EC25 to ECM mode..."
AT_PORT=""
for p in /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB1; do
    if [ -c "$p" ]; then
        AT_PORT="$p"
        break
    fi
done

if [ -n "$AT_PORT" ]; then
    echo "Using AT port: $AT_PORT"
    echo -e "AT+QCFG=\"usbnet\",1\r\nAT+CFUN=1,1\r\n" | sudo minicom -D "$AT_PORT" -b 115200 -t -q || true
    echo "EC25 reboot command sent. Waiting 15 seconds..."
    sleep 15
else
    echo "Warning: Could not find AT port. Skipping ECM mode switch (usb0 may already exist)."
fi

# 4. Load or create configuration (preserves SSID/Password on updates)
CONFIG_FILE="/etc/pi4g-hotspot.conf"

if [ -f "$CONFIG_FILE" ]; then
    echo "→ Existing configuration found. Loading previous SSID and password..."
    source "$CONFIG_FILE"
fi

# Interactive setup
echo "→ Hotspot setup"
read -p "Enter Hotspot SSID [${SSID:-Pi4G-Hotspot}]: " input_ssid
SSID=${input_ssid:-${SSID:-Pi4G-Hotspot}}

while true; do
    read -s -p "Enter Hotspot Password (at least 8 characters) [${PASSWORD:-Passwd123}]: " input_pass
    echo
    PASSWORD=${input_pass:-${PASSWORD:-Passwd123}}
    if [ ${#PASSWORD} -ge 8 ]; then
        break
    fi
    echo "Password must be at least 8 characters."
done

# Save config
sudo mkdir -p /etc
cat << EOF | sudo tee "$CONFIG_FILE" >/dev/null
SSID="$SSID"
PASSWORD="$PASSWORD"
EOF

echo "→ Configuration saved (SSID: $SSID)"

# 5. Create the start-hotspot script
echo "→ Creating start-hotspot.sh ..."
sudo tee /usr/local/bin/start-hotspot.sh > /dev/null << 'EOF'
#!/bin/bash
# Auto-generated start script - do not edit directly

CONFIG="/etc/pi4g-hotspot.conf"
if [ -f "$CONFIG" ]; then source "$CONFIG"; fi

SSID="${SSID:-Pi4G-Hotspot}"
PASSWORD="${PASSWORD:-Passwd123}"

echo "=== Pi 4G Hotspot Starting ==="
echo "SSID: $SSID"

sudo rfkill unblock wifi

# Static IP
sudo ip addr flush dev wlan0 2>/dev/null || true
sudo ip addr add 192.168.4.1/24 dev wlan0
sudo ip link set wlan0 up

# Forwarding + NAT (usb0 -> wlan0)
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -F
sudo iptables -t nat -A POSTROUTING -o usb0 -j MASQUERADE
sudo iptables -A FORWARD -i wlan0 -o usb0 -j ACCEPT
sudo iptables -A FORWARD -i usb0 -o wlan0 -j ACCEPT

# Services
sudo systemctl restart dnsmasq
sudo systemctl restart hostapd

echo "Hotspot is now active!"
echo "Clients can connect to '$SSID' with password '$PASSWORD'"
EOF

sudo chmod +x /usr/local/bin/start-hotspot.sh

# 6. hostapd configuration
echo "→ Creating hostapd configuration..."
sudo tee /etc/hostapd/hostapd.conf > /dev/null << EOF
interface=wlan0
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
country_code=US
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${PASSWORD}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# 7. dnsmasq configuration
echo "→ Creating dnsmasq configuration..."
sudo tee /etc/dnsmasq.conf > /dev/null << 'EOF'
interface=wlan0
dhcp-range=192.168.4.50,192.168.4.150,12h
dhcp-option=option:router,192.168.4.1
dhcp-option=option:dns-server,8.8.8.8,1.1.1.1
EOF

# 8. dhcpcd static IP for wlan0
echo "→ Configuring static IP for wlan0..."
if ! grep -q "interface wlan0" /etc/dhcpcd.conf; then
    echo -e "\ninterface wlan0\nstatic ip_address=192.168.4.1/24\nnohook wpa_supplicant" | sudo tee -a /etc/dhcpcd.conf >/dev/null
fi

# 9. Create systemd service for automatic start on boot
echo "→ Creating systemd service (auto-start on boot)..."
sudo tee /etc/systemd/system/pi4g-hotspot.service > /dev/null << 'EOF'
[Unit]
Description=Pi 4G LTE Hotspot (Quectel EC25 + Soracom)
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/start-hotspot.sh
ExecStop=/usr/bin/systemctl stop hostapd dnsmasq
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable pi4g-hotspot.service
sudo systemctl unmask hostapd dnsmasq

echo ""
echo "=================================================="
echo "✅ Installation Completed Successfully!"
echo ""
echo "SSID     : $SSID"
echo "Password : $PASSWORD"
echo ""
echo "Next steps:"
echo "1. Reboot the Pi:   sudo reboot"
echo "2. After reboot, the hotspot should start automatically."
echo "3. Connect your phone to '$SSID' and test internet."
echo ""
echo "To manually start:   sudo /usr/local/bin/start-hotspot.sh"
echo "To check status:     sudo systemctl status pi4g-hotspot"
echo "To update later:     cd ~/pi4g-hotspot && git pull && sudo ./install.sh"
echo "=================================================="