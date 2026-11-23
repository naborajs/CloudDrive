#!/usr/bin/env bash
# ==============================================================================
# NS Cloud Drive - Linux VPS / Ubuntu Installer & Setup Script
# Automatically verifies dependencies (pwsh, rclone, fuse3), configures
# FUSE permissions, installs Desktop GUI app, icons, launchers, and systemd units.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== NS Cloud Drive Linux Installer ==="

# Check Root / Sudo
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "[ERROR] Root or sudo access required to install packages and system launchers." >&2
        exit 1
    fi
fi

# 1. Install Dependencies
echo "[1/5] Checking and installing dependencies (fuse3, rclone, powershell)..."
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
echo "[2/5] Configuring FUSE permissions..."
if [ -f /etc/fuse.conf ]; then
    if ! grep -q "^user_allow_other" /etc/fuse.conf; then
        echo "user_allow_other" | $SUDO tee -a /etc/fuse.conf >/dev/null
    fi
fi

# 3. Create Global CLI & Desktop App Symlinks
echo "[3/5] Installing /usr/local/bin/nsclouddrive & desktop app launchers..."
$SUDO chmod +x "$SCRIPT_DIR/nsclouddrive"
$SUDO chmod +x "$SCRIPT_DIR/nsclouddrive-app"
$SUDO ln -sf "$SCRIPT_DIR/nsclouddrive" /usr/local/bin/nsclouddrive
$SUDO ln -sf "$SCRIPT_DIR/nsclouddrive-app" /usr/local/bin/nsclouddrive-app
$SUDO ln -sf "$SCRIPT_DIR/nsclouddrive-app" /usr/local/bin/nsclouddrive-gui

# 4. Install Application Icons & Desktop Entries
echo "[4/5] Installing desktop menu launchers, icons, and desktop shortcuts..."
ICON_SRC="$REPO_ROOT/assets/logos/clouddrive.png"
if [ -f "$ICON_SRC" ]; then
    $SUDO mkdir -p /usr/share/pixmaps
    $SUDO cp "$ICON_SRC" /usr/share/pixmaps/nsclouddrive.png

    for size in 256x256 128x128 64x64 48x48 32x32; do
        $SUDO mkdir -p "/usr/share/icons/hicolor/$size/apps"
        $SUDO cp "$ICON_SRC" "/usr/share/icons/hicolor/$size/apps/nsclouddrive.png"
    done
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        $SUDO gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
    fi
fi

DESKTOP_SRC="$SCRIPT_DIR/desktop/nsclouddrive.desktop"
if [ -f "$DESKTOP_SRC" ]; then
    $SUDO mkdir -p /usr/share/applications
    $SUDO cp "$DESKTOP_SRC" /usr/share/applications/nsclouddrive.desktop
    if command -v update-desktop-database >/dev/null 2>&1; then
        $SUDO update-desktop-database /usr/share/applications 2>/dev/null || true
    fi

    # User level desktop entry
    USER_APPS_DIR="${HOME}/.local/share/applications"
    mkdir -p "$USER_APPS_DIR"
    cp "$DESKTOP_SRC" "$USER_APPS_DIR/nsclouddrive.desktop"

    # Desktop shortcut on user's Desktop
    USER_DESKTOP_DIR="${HOME}/Desktop"
    if [ -d "$USER_DESKTOP_DIR" ]; then
        cp "$DESKTOP_SRC" "$USER_DESKTOP_DIR/NS Cloud Drive.desktop"
        chmod +x "$USER_DESKTOP_DIR/NS Cloud Drive.desktop"
        if command -v gio >/dev/null 2>&1; then
            gio set "$USER_DESKTOP_DIR/NS Cloud Drive.desktop" metadata::trusted true 2>/dev/null || true
        fi
    fi
fi

# 5. Configure Systemd Services (Daemon & Web UI)
echo "[5/5] Configuring systemd user services..."
USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
mkdir -p "$USER_SYSTEMD_DIR"
cp "$SCRIPT_DIR/systemd/nsclouddrive.service" "$USER_SYSTEMD_DIR/nsclouddrive.service"
if [ -f "$SCRIPT_DIR/systemd/nsclouddrive-ui.service" ]; then
    cp "$SCRIPT_DIR/systemd/nsclouddrive-ui.service" "$USER_SYSTEMD_DIR/nsclouddrive-ui.service"
fi
systemctl --user daemon-reload || true
systemctl --user enable --now nsclouddrive.service || true
systemctl --user enable --now nsclouddrive-ui.service || true

echo ""
echo "=== Installation Complete! ==="
echo "NS Cloud Drive Desktop App is installed and ready."
echo "Launch it via:"
echo "  * Applications Menu -> Internet / Accessories -> NS Cloud Drive"
echo "  * Desktop icon: 'NS Cloud Drive'"
echo "  * Terminal command: nsclouddrive app"
