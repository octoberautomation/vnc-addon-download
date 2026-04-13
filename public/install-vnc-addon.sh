#!/bin/bash

###############################################################################
# VNC + Tailscale + Auto-Registration Add-On Script
# For machines that already have Matlab Runtime, Basler SDK, and PLC Gateway
# Version: 1.0.0
###############################################################################

set -e  # Exit on any error

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║   🔧 VNC + Tailscale + Registration Add-On                    ║"
echo "║                                                                ║"
echo "║   For machines with existing PLC Gateway installations        ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root"
    echo "   Please run: sudo bash $0"
    exit 1
fi

# Configuration
VNC_PASSWORD="october2024"
TAILSCALE_AUTH_KEY="tskey-auth-knfL1vHwXa11CNTRL-rwwsNBbmgNJX8RcDKq3iNJ81WTxrL4iN"
SUPABASE_URL="https://gtqvwbuzrntgqikwjtru.supabase.co"
SUPABASE_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imd0cXZ3YnV6cm50Z3Fpa3dqdHJ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzQ1NTU5OTAsImV4cCI6MjA1MDEzMTk5MH0.Zra9y3uh5b5mVHkcMHcL8-MfL3E1f8cYMJ3F9D4Fq3o"

echo "📋 This script will install and configure:"
echo "   • Tailscale VPN"
echo "   • x11vnc VNC Server (port 5900)"
echo "   • VNC Dashboard Registration"
echo "   • Machine Registration with Remote UI"
echo "   • Tailscale Funnel (public HTTPS access)"
echo ""
echo "⚠️  Prerequisites:"
echo "   • Ubuntu 22.04 LTS with GUI"
echo ""

# If running interactively, ask for confirmation; if piped (curl | bash), auto-proceed
if [ -t 0 ]; then
    read -p "Continue with installation? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "❌ Installation cancelled"
        exit 0
    fi
else
    echo "🔄 Non-interactive mode detected, proceeding automatically..."
fi

echo ""
echo "Starting installation..."
echo ""

###############################################################################
# STEP 1: Install Required Packages
###############################################################################
echo "========================================="
echo "Step 1: Installing Required Packages"
echo "========================================="
echo ""

# Update package lists
echo "Updating package lists..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 || {
    echo "⚠️  Warning: apt-get update had issues (continuing anyway)"
}

# Install VNC and dependencies
echo "Installing x11vnc and dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    x11vnc \
    tigervnc-common \
    jq \
    curl \
    net-tools 2>&1

echo "✓ Required packages installed"
echo ""

###############################################################################
# STEP 2: Install and Configure Tailscale
###############################################################################
echo "========================================="
echo "Step 2: Tailscale Installation & Setup"
echo "========================================="
echo ""

# Check if Tailscale is already installed
if command -v tailscale &> /dev/null; then
    echo "✓ Tailscale already installed"
    TAILSCALE_VERSION=$(tailscale version | head -1)
    echo "  Version: $TAILSCALE_VERSION"
else
    echo "Installing Tailscale..."
    
    # Add Tailscale repository
    if [ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]; then
        echo "Adding Tailscale repository..."
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list
        echo "✓ Tailscale repository added"
    fi
    
    # Install Tailscale
    echo "Updating package lists for Tailscale..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 || {
        echo "⚠️  Warning: apt-get update had issues (continuing anyway)"
    }
    
    echo "Installing Tailscale package..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale 2>&1 || {
        echo "❌ Failed to install Tailscale"
        exit 1
    }
    echo "✓ Tailscale installed"
fi

# Start Tailscale service
systemctl enable --now tailscaled
sleep 2
echo "✓ Tailscale service started"

# Authenticate with Tailscale
echo ""
echo "Connecting to Tailscale network..."
tailscale up --reset --auth-key="$TAILSCALE_AUTH_KEY" --accept-routes --accept-dns=false

# Wait for connection
sleep 3

# Verify Tailscale is connected
TAILSCALE_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.Self.Online' 2>/dev/null || echo "false")

if [ "$TAILSCALE_STATUS" = "true" ]; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null)
    TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.HostName' 2>/dev/null || hostname)
    
    echo ""
    echo "✅ TAILSCALE CONNECTED SUCCESSFULLY"
    echo ""
    echo "Connection Details:"
    echo "  Tailscale IP: $TAILSCALE_IP"
    echo "  Tailscale Hostname: $TAILSCALE_HOSTNAME"
    echo "  Status: Online"
    echo ""
else
    echo ""
    echo "⚠️  Warning: Tailscale authentication may have failed"
    echo "You may need to manually authenticate later with:"
    echo "  sudo tailscale up"
    echo ""
fi

echo "========================================="
echo "✅ Tailscale Installation Complete"
echo "========================================="
echo ""

###############################################################################
# STEP 3: Install and Configure VNC Server
###############################################################################
echo "========================================="
echo "Step 3: VNC Server Installation & Setup"
echo "========================================="
echo "Installing and configuring VNC..."
echo ""

# Find X Display and Auth File
echo "Finding X Display and Auth File..."

XAUTH_FILE=""
DISPLAY_NUM=":0"

# Check common locations for .Xauthority
for user_home in /home/*; do
    if [ -f "$user_home/.Xauthority" ]; then
        XAUTH_FILE="$user_home/.Xauthority"
        echo "✓ Found .Xauthority: $XAUTH_FILE"
        break
    fi
done

# If not found in home, check /run/user
if [ -z "$XAUTH_FILE" ]; then
    for auth_file in /run/user/*/gdm/Xauthority; do
        if [ -f "$auth_file" ]; then
            XAUTH_FILE="$auth_file"
            echo "✓ Found .Xauthority in /run: $XAUTH_FILE"
            break
        fi
    done
fi

if [ -z "$XAUTH_FILE" ]; then
    echo "⚠️  Could not find .Xauthority file automatically"
    echo ""
    echo "Searching all possible locations..."
    find /home /root /run/user -name ".Xauthority" -o -name "Xauthority" 2>/dev/null
    echo ""
    echo "❌ CRITICAL ERROR: X authority file not found"
    echo "VNC cannot start without X display authorization"
    exit 1
fi

echo ""

# Create VNC password file
mkdir -p /etc/x11vnc

echo "Creating VNC password file..."

# Create password using x11vnc
(
    exec 3>&1
    exec 4>&2
    {
        echo "$VNC_PASSWORD"
        echo "$VNC_PASSWORD"
        echo "y"
    } | x11vnc -storepasswd /etc/x11vnc/passwd 1>&3 2>&4
    exec 3>&-
    exec 4>&-
) 2>/dev/null || {
    echo "⚠️  Interactive method failed, using direct method..."
    x11vnc -storepasswd "$VNC_PASSWORD" /etc/x11vnc/passwd </dev/null 2>&1 | grep -v "stty" || {
        echo "⚠️  Direct method failed, using echo method..."
        { echo "$VNC_PASSWORD"; echo "$VNC_PASSWORD"; echo "y"; } | x11vnc -storepasswd /etc/x11vnc/passwd 2>&1 | grep -v "stty" | grep -v "Inappropriate ioctl"
    }
}

chmod 644 /etc/x11vnc/passwd
chown root:root /etc/x11vnc/passwd

# Verify password file was created
if [ ! -s /etc/x11vnc/passwd ]; then
    echo "⚠️  Password file not created yet, trying vncpasswd..."
    apt-get install -y tigervnc-standalone-server 2>/dev/null || apt-get install -y tigervnc-common 2>/dev/null
    echo "$VNC_PASSWORD" | vncpasswd -f > /etc/x11vnc/passwd 2>/dev/null || {
        echo "❌ VNC password creation failed"
        exit 1
    }
fi

echo "✓ VNC password set successfully"
echo "✓ Password file: /etc/x11vnc/passwd"
echo ""

# Stop any existing VNC processes
echo "Stopping any existing VNC processes..."
pkill -9 x11vnc || true
systemctl stop x11vnc.service 2>/dev/null || true
sleep 2

# Create VNC system service
echo "Creating VNC system service..."
cat > /etc/systemd/system/x11vnc.service << EOFVNCSERVICE
[Unit]
Description=x11vnc VNC Server
After=display-manager.service network.target

[Service]
Type=simple
Environment="DISPLAY=$DISPLAY_NUM"
ExecStart=/usr/bin/x11vnc -auth $XAUTH_FILE -display $DISPLAY_NUM -forever -loop -noxdamage -repeat -rfbauth /etc/x11vnc/passwd -rfbport 5900 -shared -listen 0.0.0.0 -noshm
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOFVNCSERVICE

echo "✓ VNC service created"
echo "  Display: $DISPLAY_NUM"
echo "  Auth File: $XAUTH_FILE"
echo "  Password File: /etc/x11vnc/passwd"
echo "  MIT-SHM: Disabled"
echo ""

# Start VNC service
echo "Starting VNC service..."
systemctl daemon-reload
systemctl enable x11vnc.service
systemctl start x11vnc.service

# Wait for VNC to start
sleep 3

# Verify VNC is running
echo "Verifying VNC is running..."
if systemctl is-active --quiet x11vnc.service; then
    echo "✅ VNC service is active"
    
    # Show connection details
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    echo ""
    echo "✅ VNC SERVER IS RUNNING SUCCESSFULLY"
    echo ""
    echo "Connection Details:"
    echo "  IP: $IP_ADDRESS"
    echo "  Port: 5900"
    echo "  Password: $VNC_PASSWORD"
    echo ""
else
    echo "❌ CRITICAL ERROR: VNC service failed to start"
    echo ""
    echo "Service logs:"
    journalctl -u x11vnc.service -n 50 --no-pager
    echo ""
    exit 1
fi

echo ""

# Register with VNC Dashboard
echo "Registering with VNC Dashboard..."
HOSTNAME=$(hostname)
IP_ADDRESS=$(hostname -I | awk '{print $1}')
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
MACHINE_ID=$(ip link show | awk '/ether/ {print $2; exit}' | tr -d ':')

# Construct JSON payload
JSON_PAYLOAD=$(cat <<EOF
{
  "machineName": "$HOSTNAME",
  "ipAddress": "$IP_ADDRESS",
  "machineId": "$MACHINE_ID",
  "vncPort": 5900,
  "osType": "Ubuntu 22.04",
  "tailscaleIp": "$TAILSCALE_IP"
}
EOF
)

echo ""
echo "Sending registration to VNC Dashboard..."

# Send registration
RESPONSE=$(curl -s -X POST "$SUPABASE_URL/functions/v1/make-server-93820e45/api/register-vnc" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -d "$JSON_PAYLOAD" 2>&1) || {
    echo "⚠️  Warning: VNC dashboard registration failed"
    echo "   VNC server is still accessible locally"
}

# Check response
if echo "$RESPONSE" | grep -q "success.*true"; then
    echo "✅ VNC Dashboard registration successful"
    VNC_ID=$(echo "$RESPONSE" | grep -oP '"id":"[^"]+' | cut -d'"' -f4 || echo "unknown")
    echo "  Machine ID: $VNC_ID"
else
    echo "⚠️  VNC Dashboard registration response:"
    echo "$RESPONSE"
fi

echo ""
echo "========================================="
echo "✅ VNC Installation & Registration Complete"
echo "========================================="
echo ""

###############################################################################
# STEP 4: Start Tailscale Funnel
###############################################################################
echo "========================================="
echo "Step 4: Starting Tailscale Funnel"
echo "========================================="
echo "Starting Tailscale Funnel on port 3000..."
echo ""

# Check if PLC Gateway is running on port 3000
if ! netstat -tuln | grep -q ":3000"; then
    echo "⚠️  Warning: PLC Gateway doesn't appear to be running on port 3000"
    echo "   Funnel will be configured, but may not work until gateway starts"
fi

# Start funnel in background
tailscale funnel --bg 3000 2>&1 || {
    echo "⚠️  Warning: Could not start Tailscale Funnel yet"
    echo "   This is OK - it will be configured later"
}

# Wait for funnel to initialize
sleep 3

# Try to get the funnel URL
FUNNEL_URL=""
FUNNEL_STATUS=$(tailscale funnel status 2>/dev/null || echo "")
if echo "$FUNNEL_STATUS" | grep -q "https://"; then
    FUNNEL_URL=$(echo "$FUNNEL_STATUS" | grep -oP 'https://[^/]+' | head -1)
    echo "✅ Tailscale Funnel URL: $FUNNEL_URL"
else
    echo "⚠️  Funnel URL not yet available"
fi

# Create Tailscale Funnel systemd service
echo ""
echo "Creating Tailscale Funnel service..."
cat > /etc/systemd/system/tailscale-funnel.service << EOFFUNNELSERVICE
[Unit]
Description=Tailscale Funnel for PLC Gateway
After=network.target tailscaled.service
Requires=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/tailscale funnel --bg 3000
ExecStop=/usr/bin/tailscale funnel --bg 3000 off
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOFFUNNELSERVICE

systemctl daemon-reload
systemctl enable tailscale-funnel.service

echo "✓ Tailscale Funnel service created and enabled"
echo ""
echo "========================================="
echo "✅ Tailscale Funnel Complete"
echo "========================================="
echo ""

###############################################################################
# STEP 5: Machine Registration with Remote UI
###############################################################################
echo "========================================="
echo "Step 5: Machine Registration with Remote UI"
echo "========================================="
echo "Registering this machine with remoteui.octoberautomation.com..."
echo ""

# Clean slate - remove any previous registration artifacts
echo "🧹 Cleaning up previous registration files (if any)..."
rm -f /opt/plc-gateway/.machine-id
rm -f /opt/plc-gateway/CLAIM_CODE.txt
rm -f /opt/plc-gateway/machine-config.json
echo "✓ Clean slate ready"
echo ""

REGISTRATION_API="$SUPABASE_URL/functions/v1/make-server-93820e45/api/register-machine"
CONFIG_FILE="/opt/plc-gateway/machine-config.json"
MACHINE_ID_FILE="/opt/plc-gateway/.machine-id"

# Create directory if it doesn't exist
mkdir -p /opt/plc-gateway

# Generate machine ID
REMOTE_MACHINE_ID=$(cat /proc/sys/kernel/random/uuid)
echo "$REMOTE_MACHINE_ID" > "$MACHINE_ID_FILE"
chmod 600 "$MACHINE_ID_FILE"
echo "🆔 Generated new Machine ID: $REMOTE_MACHINE_ID"

echo ""
echo "📊 Gathering machine information..."

# Get system information
REGISTRATION_HOSTNAME=$(hostname)
OS_VERSION=$(lsb_release -d 2>/dev/null | cut -f2 || echo "Ubuntu 22.04")
KERNEL_VERSION=$(uname -r)
ARCHITECTURE=$(uname -m)

# Get primary IP address
REGISTRATION_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "unknown")

# Get Tailscale info
if [ -n "$FUNNEL_URL" ]; then
    REGISTRATION_TAILSCALE_HOSTNAME=$(echo "$FUNNEL_URL" | sed 's|https://||')
    echo "  📡 Using Tailscale Funnel URL: $REGISTRATION_TAILSCALE_HOSTNAME"
else
    REGISTRATION_TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.HostName' 2>/dev/null || echo "pending")
fi
REGISTRATION_TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "pending")

# Default PLC IP
PLC_IP="192.168.50.2"

echo "  • Hostname: $REGISTRATION_HOSTNAME"
echo "  • Machine ID: $REMOTE_MACHINE_ID"
echo "  • IP Address: $REGISTRATION_IP"
echo "  • OS: $OS_VERSION"
echo "  • Tailscale: $REGISTRATION_TAILSCALE_HOSTNAME"

echo ""
echo "🌐 Registering with October Automation Remote UI..."

# Create registration payload
REGISTER_PAYLOAD=$(cat <<EOFREGISTER
{
  "machineId": "$REMOTE_MACHINE_ID",
  "hostname": "$REGISTRATION_HOSTNAME",
  "ipAddress": "$REGISTRATION_IP",
  "tailscaleHostname": "$REGISTRATION_TAILSCALE_HOSTNAME",
  "tailscaleIp": "$REGISTRATION_TAILSCALE_IP",
  "plcIp": "$PLC_IP",
  "funnelUrl": "https://$REGISTRATION_TAILSCALE_HOSTNAME",
  "remoteCameraAddress": "192.168.50.7:8080",
  "osVersion": "$OS_VERSION",
  "kernelVersion": "$KERNEL_VERSION",
  "architecture": "$ARCHITECTURE",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOFREGISTER
)

# Send registration request
REGISTER_RESPONSE=$(curl -s -X POST "$REGISTRATION_API" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -d "$REGISTER_PAYLOAD" 2>&1) || {
    echo "⚠️  Warning: Could not register with central service"
    echo "   This machine can still be used locally"
}

# Parse response
if [ -n "$REGISTER_RESPONSE" ]; then
    CLAIM_CODE=$(echo "$REGISTER_RESPONSE" | grep -oP '"claimCode":"\K[^"]+' || echo "")
    REGISTERED=$(echo "$REGISTER_RESPONSE" | grep -q '"success":true' && echo "true" || echo "false")
    
    if [ "$REGISTERED" = "true" ] && [ -n "$CLAIM_CODE" ]; then
        echo "✅ Registration successful!"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🎫 CLAIM CODE"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "   $CLAIM_CODE"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "📋 To activate this machine:"
        echo "   1. Go to: https://remoteui.octoberautomation.com/claim"
        echo "   2. Create an account or sign in"
        echo "   3. Enter claim code: $CLAIM_CODE"
        echo "   4. Name your machine and complete setup"
        echo ""
        echo "⏰ Claim code expires in: 24 hours"
        echo ""
        
        # Save configuration
        cat > "$CONFIG_FILE" <<EOFCONFIG
{
  "machineId": "$REMOTE_MACHINE_ID",
  "claimCode": "$CLAIM_CODE",
  "hostname": "$REGISTRATION_HOSTNAME",
  "registeredAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "claimed": false,
  "tailscaleHostname": "$REGISTRATION_TAILSCALE_HOSTNAME"
}
EOFCONFIG
        chmod 600 "$CONFIG_FILE"
        
        # Display claim code in a file
        cat > "/opt/plc-gateway/CLAIM_CODE.txt" <<EOFCLAIM
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   🎫 MACHINE CLAIM CODE                                      ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

Your Claim Code: $CLAIM_CODE

To activate this machine:

1. Go to: https://remoteui.octoberautomation.com/claim
2. Create an account or sign in
3. Enter the claim code above
4. Name your machine and complete setup

This code expires in 24 hours.

Claim URL: https://remoteui.octoberautomation.com/claim?code=$CLAIM_CODE
EOFCLAIM
        chmod 644 "/opt/plc-gateway/CLAIM_CODE.txt"
        
        echo "💾 Claim code saved to: /opt/plc-gateway/CLAIM_CODE.txt"
    else
        echo "⚠️  Registration response:"
        echo "$REGISTER_RESPONSE"
    fi
fi

echo ""
echo "========================================="
echo "✅ Machine Registration Complete"
echo "========================================="
echo ""

###############################################################################
# COMPLETION SUMMARY
###############################################################################
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║   ✅ VNC + Tailscale + Registration Installation Complete!   ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "📊 INSTALLATION SUMMARY:"
echo ""
echo "✅ Tailscale VPN:"
echo "   • Status: Connected"
echo "   • IP: $REGISTRATION_TAILSCALE_IP"
echo "   • Hostname: $REGISTRATION_TAILSCALE_HOSTNAME"
if [ -n "$FUNNEL_URL" ]; then
echo "   • Funnel URL: $FUNNEL_URL"
fi
echo ""
echo "✅ VNC Server:"
echo "   • Port: 5900"
echo "   • Password: $VNC_PASSWORD"
echo "   • Local IP: $REGISTRATION_IP"
echo "   • Service: x11vnc.service (enabled)"
echo ""
echo "✅ Machine Registration:"
echo "   • Machine ID: $REMOTE_MACHINE_ID"
if [ -n "$CLAIM_CODE" ]; then
echo "   • Claim Code: $CLAIM_CODE"
echo "   • Claim URL: https://remoteui.octoberautomation.com/claim"
echo "   • Expires: 24 hours"
fi
echo ""
echo "📝 NEXT STEPS:"
echo ""
if [ -n "$CLAIM_CODE" ]; then
echo "1. Go to https://remoteui.octoberautomation.com/claim"
echo "2. Sign in or create an account"
echo "3. Enter your claim code: $CLAIM_CODE"
echo "4. Name your machine and complete setup"
echo ""
fi
echo "📚 USEFUL COMMANDS:"
echo ""
echo "  VNC Service:"
echo "    Status:  sudo systemctl status x11vnc"
echo "    Restart: sudo systemctl restart x11vnc"
echo "    Logs:    sudo journalctl -u x11vnc -f"
echo ""
echo "  Tailscale:"
echo "    Status:  tailscale status"
echo "    IP:      tailscale ip"
echo "    Funnel:  tailscale funnel status"
echo ""
echo "  Machine Info:"
echo "    Claim Code: cat /opt/plc-gateway/CLAIM_CODE.txt"
echo "    Config:     cat /opt/plc-gateway/machine-config.json"
echo ""
echo "✅ Installation complete!"
echo ""
