#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
ARCHIVE_URL="https://archive.clustereye.com"
LATEST_RELEASE="vv1.0.11"
INSTALL_DIR="/opt/clustereye"
SERVICE_NAME="clustereye-agent"

# Usage
usage() {
    echo -e "${BLUE}ClusterEye Agent Installation Script${NC}"
    echo -e "Usage: $0 -p <platform> [-k <license-key>] [-d <install-dir>] [-v <version>]"
    echo -e "\nParameters:"
    echo -e "  -p  Platform (required): 'postgres', 'mongo', or 'mssql'"
    echo -e "  -k  License key (optional)"
    echo -e "  -d  Install directory (default: /opt/clustereye)"
    echo -e "  -v  Version (default: ${LATEST_RELEASE})"
    echo -e "  -h  Show this help message"
    exit 1
}

# Parse arguments
while getopts "p:k:d:v:h" opt; do
    case $opt in
        p) PLATFORM="$OPTARG";;
        k) LICENSE_KEY="$OPTARG";;
        d) INSTALL_DIR="$OPTARG";;
        v) LATEST_RELEASE="$OPTARG";;
        h) usage;;
        ?) usage;;
    esac
done

# Validate platform
if [ -z "$PLATFORM" ] || [[ ! "$PLATFORM" =~ ^(postgres|mongo|mssql)$ ]]; then
    echo -e "${RED}Error: Invalid platform specified. Use 'postgres', 'mongo', or 'mssql'${NC}"
    usage
fi

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script must be run as root.${NC}"
    echo -e "Please run with: sudo $0 $@"
    exit 1
fi

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        BINARY_ARCH="amd64"
        ;;
    aarch64|arm64)
        BINARY_ARCH="arm64"
        ;;
    *)
        echo -e "${RED}Unsupported architecture: $ARCH${NC}"
        exit 1
        ;;
esac

# Set download URL
BINARY_NAME="clustereye-agent-linux-${BINARY_ARCH}"
DOWNLOAD_URL="${ARCHIVE_URL}/downloads/agent/${LATEST_RELEASE}/${BINARY_NAME}"
SHA256_URL="${DOWNLOAD_URL}.sha256"
CONFIG_URL="${ARCHIVE_URL}/downloads/agent/${LATEST_RELEASE}/config.yaml"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}  ClusterEye Agent Installation${NC}"
echo -e "${BLUE}================================================${NC}"
echo -e "Version:    ${GREEN}${LATEST_RELEASE}${NC}"
echo -e "Platform:   ${GREEN}${PLATFORM}${NC}"
echo -e "Arch:       ${GREEN}${BINARY_ARCH}${NC}"
echo -e "Directory:  ${GREEN}${INSTALL_DIR}${NC}"
echo -e "${BLUE}================================================${NC}\n"

# Step 1: Create install directory
echo -e "${YELLOW}[1/5] Creating installation directory...${NC}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Step 2: Download binary
echo -e "${YELLOW}[2/5] Downloading agent binary...${NC}"
if ! curl -fSL -o "${BINARY_NAME}" "${DOWNLOAD_URL}"; then
    echo -e "${RED}Failed to download binary!${NC}"
    exit 1
fi

# Step 3: Verify checksum
echo -e "${YELLOW}[3/5] Verifying checksum...${NC}"
if curl -fsSL -o "${BINARY_NAME}.sha256" "${SHA256_URL}" 2>/dev/null; then
    EXPECTED_SHA=$(cat "${BINARY_NAME}.sha256" | awk '{print $1}')
    ACTUAL_SHA=$(sha256sum "${BINARY_NAME}" | awk '{print $1}')
    if [ "$EXPECTED_SHA" = "$ACTUAL_SHA" ]; then
        echo -e "${GREEN}Checksum verified!${NC}"
    else
        echo -e "${RED}Checksum mismatch!${NC}"
        echo -e "Expected: ${EXPECTED_SHA}"
        echo -e "Got:      ${ACTUAL_SHA}"
        exit 1
    fi
    rm -f "${BINARY_NAME}.sha256"
else
    echo -e "${YELLOW}Warning: Could not verify checksum (sha256 file not found)${NC}"
fi

chmod +x "${BINARY_NAME}"
ln -sf "${BINARY_NAME}" clustereye-agent

# Step 4: Download config
echo -e "${YELLOW}[4/5] Downloading configuration file...${NC}"
if ! curl -fSL -o "config.yaml" "${CONFIG_URL}"; then
    echo -e "${YELLOW}Warning: Could not download config file. Creating default...${NC}"
    cat > "config.yaml" << 'EOF'
# ClusterEye Agent Configuration
server:
  host: "localhost"
  port: 8080

license:
  key: "YOUR-LICENSE-KEY"

platform: "postgres"

logging:
  level: "info"
  format: "json"
EOF
fi

# Update config with license key if provided
if [ ! -z "$LICENSE_KEY" ]; then
    sed -i "s/YOUR-LICENSE-KEY/$LICENSE_KEY/" config.yaml
fi

# Update config with platform
sed -i "s/platform: .*/platform: \"$PLATFORM\"/" config.yaml

# Step 5: Create systemd service
echo -e "${YELLOW}[5/5] Creating systemd service...${NC}"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=ClusterEye Agent Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/clustereye-agent
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=5
Environment=PATH=/usr/bin:/bin:/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo -e "\n${YELLOW}Next steps:${NC}"
echo -e "1. Edit the configuration file:"
echo -e "   ${BLUE}sudo nano ${INSTALL_DIR}/config.yaml${NC}"
echo -e "\n2. Start the service:"
echo -e "   ${BLUE}sudo systemctl start ${SERVICE_NAME}${NC}"
echo -e "   ${BLUE}sudo systemctl enable ${SERVICE_NAME}${NC}"
echo -e "\n3. Check service status:"
echo -e "   ${BLUE}sudo systemctl status ${SERVICE_NAME}${NC}"
echo -e "\n4. View logs:"
echo -e "   ${BLUE}sudo journalctl -u ${SERVICE_NAME} -f${NC}"
echo -e "\n${GREEN}================================================${NC}"
