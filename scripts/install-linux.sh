#!/usr/bin/env bash
# ==============================================================================
# NS Cloud Drive - Linux VPS / Ubuntu Installer & Setup Script
# Automatically verifies dependencies (pwsh, rclone, fuse3), configures
# FUSE permissions, creates symlinks, and sets up systemd service.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== NS Cloud Drive Linux VPS Installer ==="

# Check Root / Sudo
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "[ERROR] Root or sudo access required to install packages and system service." >&2
        exit 1
    fi
fi

# 1. Install Dependencies
echo "[1/4] Checking and installing dependencies (fuse3, rclone, powershell)..."
if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y fuse3 rclone curl wget

    if ! command -v pwsh >/dev/null 2>&1; then
        echo "Installing PowerShell Core on Ubuntu/Debian..."
        UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
        $SUDO apt-get install -y wget apt-transport-https software-properties-common
        wget -q "https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb || true
        if [ -f /tmp/packages-microsoft-prod.deb ]; then
            $SUDO dpkg -i /tmp/packages-microsoft-prod.deb || true
            $SUDO apt-get update -y
            $SUDO apt-get install -y powershell || true
            rm -f /tmp/packages-microsoft-prod.deb
        fi
    fi
elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y fuse3 rclone powershell || true
elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -Sy --noconfirm fuse3 rclone powershell || true
fi

# 2. Configure FUSE permissions for user mounting
echo "[2/4] Configuring FUSE permissions..."
if [ -f /etc/fuse.conf ]; then
    if ! grep -q "^user_allow_other" /etc/fuse.conf; then
        echo "user_allow_other" | $SUDO tee -a /etc/fuse.conf >/dev/null
    fi
fi

# 3. Create Global Symlink
echo "[3/4] Installing /usr/local/bin/nsclouddrive..."
$SUDO chmod +x "$SCRIPT_DIR/nsclouddrive"
$SUDO ln -sf "$SCRIPT_DIR/nsclouddrive" /usr/local/bin/nsclouddrive

# 4. Configure Systemd Service (Optional)
echo "[4/4] Configuring systemd user service..."
USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
mkdir -p "$USER_SYSTEMD_DIR"
cp "$SCRIPT_DIR/systemd/nsclouddrive.service" "$USER_SYSTEMD_DIR/nsclouddrive.service"
systemctl --user daemon-reload || true

echo ""
echo "=== Installation Complete! ==="
echo "Run 'nsclouddrive status' to check your setup."
echo "To enable background auto-mount & sync daemon on boot:"
echo "  systemctl --user enable --now nsclouddrive"
