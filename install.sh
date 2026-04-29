#!/bin/bash
# ================================================
# Pi 4G LTE Hotspot Installer - Fixed for Bookworm
# Quectel EC25 + Soracom on Raspberry Pi Zero W
# ================================================

set -e

echo "=================================================="
echo "   Pi 4G LTE Hotspot Installer (Fixed Version)"
echo "=================================================="

# 1. Update system and install packages
echo "→ Updating system and installing packages..."
sudo apt update
sudo apt install -y hostapd dnsmasq iptables minicom usbutils rfkill

# 2. Stop and disable interfering services
echo "→ Stopping NetworkManager and wpa_supplicant interference..."
sudo systemctl stop wpa_supplicant || true
sudo systemctl stop NetworkManager || true
sudo rfkill unblock wifi
sudo rfkill unblock all

# 3. Set Quectel EC25 to ECM mode
echo "→ Setting Quectel EC25 to ECM mode..."
AT_PORT=$(ls /dev/ttyUSB* 2>/dev/null | head -n1 || echo "")
if [ -n "$AT_PORT" ]; then
    echo "Found AT port: $AT_PORT"
    echo -e "AT+QCFG=\"usbnet\",1\r\nAT+CFUN=1,1\r\n" | sudo minicom -D "$AT_PORT" -b 115200 -t -q || true
    echo "Waiting 15 seconds for modem to reboot..."
    sleep 15
fi

# 4. Interactive SSID and Password
CONFIG_FILE="/etc/pi4g-hotspot.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

read -p "Enter Hotspot SSID [${SSID:-Pi4G-Hotspot}]: " input_ssid
SSID=${input_ssid:-${SSID:-Pi4G-Hotspot}}

while true; do
    read -p "Enter Hotspot Password (min 8 chars) [${PASSWORD:-Passwd123}]: " input_pass
    PASSWORD=${input_pass:-${PASSWORD:-Passwd123}}
    if [ ${#PASSWORD} -ge 8 ]; then break; fi
    echo "Password too short. Try again."
done

sudo tee "$CONFIG_FILE" > /dev/null << EOF
SSID="$SSID"
PASSWORD="$PASSWORD"
EOF

echo "→ Saved SSID: $SSID"

# 5. Create start-hotspot.sh
echo "→ Creating start-hotspot.sh ..."
sudo tee /usr/local/bin/start-hotspot.sh > /dev/null << 'EOF'
#!/bin/bash
CONFIG="/etc/pi4g-hotspot.conf"
[ -f "$CONFIG" ] && source "$CONFIG"

SSID="${SSID:-Pi4G-Hotspot}"
PASSWORD="${PASSWORD:-Passwd123}"

echo "=== Starting Pi 4G Hotspot ==="

sudo rfkill unblock wifi

# Static IP
sudo ip addr flush dev wlan0 2>/dev/null || true
sudo ip addr add 192.168.4.1/24 dev wlan0
sudo ip link set wlan0 up

# IP Forwarding + NAT
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -F
sudo iptables -t nat -A POSTROUTING -o usb0 -j MASQUERADE
sudo iptables -A FORWARD -i wlan0 -o usb0 -j ACCEPT
sudo iptables -A FORWARD -i usb0 -o wlan0 -j ACCEPT

# Restart services
sudo systemctl restart dnsmasq
sudo systemctl restart hostapd

echo "Hotspot '$SSID' is active. Password: $PASSWORD"
EOF

sudo chmod +x /usr/local/bin/start-hotspot.sh

# 6. hostapd config
sudo tee /etc/hostapd/hostapd.conf > /dev/null << EOF
interface=wlan0
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
country_code=US
ieee80211n=1
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${PASSWORD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

# 7. dnsmasq config
sudo tee /etc/dnsmasq.conf > /dev/null << 'EOF'
interface=wlan0
dhcp-range=192.168.4.50,192.168.4.150,12h
dhcp-option=option:router,192.168.4.1
dhcp-option=option:dns-server,8.8.8.8,1.1.1.1
EOF

# 8. dhcpcd static IP
if ! grep -q "interface wlan0" /etc/dhcpcd.conf; then
    echo -e "\ninterface wlan0\nstatic ip_address=192.168.4.1/24\nnohook wpa_supplicant" | sudo tee -a /etc/dhcpcd.conf > /dev/null
fi

# 9. Systemd service
sudo tee /etc/systemd/system/pi4g-hotspot.service > /dev/null << 'EOF'
[Unit]
Description=Pi 4G LTE Hotspot
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/start-hotspot.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable pi4g-hotspot.service

echo ""
echo "=================================================="
echo "Installation finished!"
echo "SSID: $SSID"
echo "Password: $PASSWORD"
echo ""
echo "Reboot now to test:"
echo "sudo reboot"
echo ""
echo "After reboot, look for the hotspot on your phone."
echo "If it still fails, run: sudo /usr/local/bin/start-hotspot.sh  and check status with:"
echo "sudo systemctl status hostapd"
echo "=================================================="