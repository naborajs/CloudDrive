#!/usr/bin/env bash
# ==============================================================================
# NS Cloud Drive - Cross-distribution Linux Installer & Setup Script
# Automatically verifies dependencies (pwsh, rclone, fuse3), configures
# FUSE permissions, installs Desktop GUI app, icons, launchers, and systemd units.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# `sudo ./install-linux.sh` commonly changes HOME to /root. Re-enter as the
# invoking desktop user so portable runtime, desktop entries, and user services
# are installed into that user's directories; privileged actions still use sudo.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && [ "${NSCD_INSTALLER_USER_CONTEXT:-0}" != 1 ]; then
    invoking_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
    if [ -z "$invoking_home" ] || [ ! -d "$invoking_home" ]; then
        echo "[ERROR] Could not resolve the invoking user's home directory for $SUDO_USER." >&2
        exit 1
    fi
    if command -v runuser >/dev/null 2>&1; then
        exec runuser -u "$SUDO_USER" -- env HOME="$invoking_home" NSCD_INSTALLER_USER_CONTEXT=1 bash "$SCRIPT_DIR/install-linux.sh" "$@"
    elif command -v sudo >/dev/null 2>&1; then
        exec sudo -u "$SUDO_USER" env HOME="$invoking_home" NSCD_INSTALLER_USER_CONTEXT=1 bash "$SCRIPT_DIR/install-linux.sh" "$@"
    else
        echo "[ERROR] Cannot switch the installer's user context; install runuser or invoke this script without sudo." >&2
        exit 1
    fi
fi

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

run_as_root() {
    if [ -n "$SUDO" ]; then
        "$SUDO" "$@"
    else
        "$@"
    fi
}

systemd_quote_path() {
    local value="$1"
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        echo "[ERROR] A filesystem path for a systemd unit cannot contain a newline." >&2
        return 1
    fi
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"
    printf '"%s"' "$value"
}

install_powershell_archive() {
    local arch runtime_target release_info release_tag asset_url expected_sha256 actual_sha256 python_bin install_root install_dir local_bin stage
    local is_musl=false
    if [ -f /etc/alpine-release ] || compgen -G '/lib/ld-musl-*.so.1' >/dev/null; then
        is_musl=true
    elif command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
        is_musl=true
    fi
    case "$(uname -m)" in
        x86_64|amd64)
            arch="x64"
            if [ "$is_musl" = true ]; then
                runtime_target="linux-musl-x64"
            else
                runtime_target="linux-x64"
            fi
            ;;
        aarch64|arm64)
            arch="arm64"
            if [ "$is_musl" = true ]; then
                echo "[ERROR] The official PowerShell release does not provide a musl archive for Linux ${arch}. Install PowerShell from a distribution package or build it for this platform." >&2
                return 1
            fi
            runtime_target="linux-arm64"
            ;;
        armv7l|armv7*)
            arch="arm32"
            if [ "$is_musl" = true ]; then
                echo "[ERROR] The official PowerShell release does not provide a musl archive for Linux ${arch}. Install PowerShell from a distribution package or build it for this platform." >&2
                return 1
            fi
            runtime_target="linux-arm32"
            ;;
        *) echo "[ERROR] No PowerShell release archive is available for architecture $(uname -m)." >&2; return 1 ;;
    esac

    python_bin="$(command -v python3 || command -v python || true)"
    if [ -z "$python_bin" ] || ! command -v curl >/dev/null 2>&1; then
        echo "[ERROR] python3 and curl are required to install the portable PowerShell runtime." >&2
        return 1
    fi

release_info="$("$python_bin" - "$runtime_target" <<'PY'
import json
import sys
import urllib.request

runtime_target = sys.argv[1]
request = urllib.request.Request(
    "https://api.github.com/repos/PowerShell/PowerShell/releases/latest",
    headers={"Accept": "application/vnd.github+json", "User-Agent": "NSCloudDrive-Linux-Installer"},
)
with urllib.request.urlopen(request, timeout=30) as response:
    release = json.load(response)
if not isinstance(release, dict):
    raise SystemExit("The PowerShell release API returned an invalid response.")
tag = release.get("tag_name", "")
if not isinstance(tag, str):
    raise SystemExit("The PowerShell release API returned an invalid version tag.")
version = tag[1:] if tag.startswith("v") else tag
expected = f"powershell-{version}-{runtime_target}.tar.gz"
assets = release.get("assets", [])
if not isinstance(assets, list):
    raise SystemExit("The PowerShell release API returned an invalid asset list.")
asset = next((item for item in assets if isinstance(item, dict) and item.get("name") == expected), None)
asset_url = asset.get("browser_download_url", "") if asset else ""
if not tag or not asset or not isinstance(asset_url, str) or not asset_url:
    raise SystemExit(f"No PowerShell archive asset found for {runtime_target} in the latest release.")
digest_value = asset.get("digest")
digest = digest_value.strip() if isinstance(digest_value, str) else ""
if digest.startswith("sha256:"):
    digest = digest.split(":", 1)[1]
else:
    hashes = next((item for item in assets if isinstance(item, dict) and item.get("name") == "hashes.sha256"), None)
    hashes_url = hashes.get("browser_download_url", "") if hashes else ""
    if not hashes or not isinstance(hashes_url, str) or not hashes_url:
        raise SystemExit("The PowerShell release did not publish a SHA-256 digest for the selected archive.")
    with urllib.request.urlopen(hashes_url, timeout=30) as response:
        hash_lines = response.read().decode("ascii", errors="strict").splitlines()
    expected_line = next((line for line in hash_lines if line.split() and line.split()[-1].lstrip("*") == expected), "")
    digest = expected_line.split()[0] if expected_line else ""
if len(digest) != 64 or any(char not in "0123456789abcdefABCDEF" for char in digest):
    raise SystemExit(f"No valid SHA-256 digest was found for {expected}.")
print(tag)
print(asset_url)
print(digest.lower())
PY
)" || return 1

    release_tag="$(printf '%s\n' "$release_info" | sed -n '1p')"
    asset_url="$(printf '%s\n' "$release_info" | sed -n '2p')"
    expected_sha256="$(printf '%s\n' "$release_info" | sed -n '3p')"
    if [ -z "$release_tag" ] || [ -z "$asset_url" ] || [ -z "$expected_sha256" ]; then
        echo "[ERROR] Could not resolve the official PowerShell archive and SHA-256 digest." >&2
        return 1
    fi
    if [[ ! "$release_tag" =~ ^v[0-9]+(\.[0-9]+){2,3}$ ]]; then
        echo "[ERROR] The PowerShell release returned an invalid version tag." >&2
        return 1
    fi
    case "$asset_url" in
        https://github.com/PowerShell/PowerShell/releases/download/*) ;;
        *) echo "[ERROR] The PowerShell release returned an unexpected archive URL." >&2; return 1 ;;
    esac

    install_root="${HOME}/.local/share/nsclouddrive/runtime/powershell"
    install_dir="${install_root}/${release_tag}"
    local_bin="${HOME}/.local/bin"
    if [ -x "${install_dir}/pwsh" ]; then
        :
    elif [ -e "$install_dir" ]; then
        echo "[ERROR] PowerShell install path already exists but is incomplete: $install_dir" >&2
        return 1
    else
        mkdir -p "$install_root"
        stage="$(mktemp -d "${install_root}/.install.XXXXXX")"
        if ! curl --fail --location --silent --show-error "$asset_url" -o "${stage}/powershell.tar.gz"; then
            rm -rf -- "$stage"
            return 1
        fi
        mkdir "${stage}/runtime"
        actual_sha256="$("$python_bin" - "${stage}/powershell.tar.gz" <<'PY'
import hashlib
import pathlib
import sys

digest = hashlib.sha256()
with pathlib.Path(sys.argv[1]).open("rb") as archive:
    for chunk in iter(lambda: archive.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
        )" || {
            rm -rf -- "$stage"
            return 1
        }
        if [ "${actual_sha256,,}" != "${expected_sha256,,}" ]; then
            rm -rf -- "$stage"
            echo "[ERROR] PowerShell archive SHA-256 verification failed." >&2
            return 1
        fi
        if ! tar -xzf "${stage}/powershell.tar.gz" -C "${stage}/runtime"; then
            rm -rf -- "$stage"
            return 1
        fi
        if [ ! -x "${stage}/runtime/pwsh" ]; then
            rm -rf -- "$stage"
            echo "[ERROR] The downloaded PowerShell archive did not contain an executable pwsh binary." >&2
            return 1
        fi
        if ! "${stage}/runtime/pwsh" -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' >/dev/null 2>&1; then
            rm -rf -- "$stage"
            echo "[ERROR] PowerShell could not start with this distribution's installed runtime libraries. Install the PowerShell runtime dependencies for this Linux distribution, then retry." >&2
            return 1
        fi
        mv "${stage}/runtime" "$install_dir"
        chmod +x "${install_dir}/pwsh"
        rm -rf -- "$stage"
    fi

    mkdir -p "$local_bin"
    if [ -e "${local_bin}/pwsh" ] && [ ! -x "${local_bin}/pwsh" ]; then
        echo "[ERROR] Refusing to replace a non-executable file at ${local_bin}/pwsh." >&2
        return 1
    fi
    if [ ! -e "${local_bin}/pwsh" ]; then
        ln -s "${install_dir}/pwsh" "${local_bin}/pwsh"
    fi
    export PATH="${local_bin}:${PATH}"
    command -v pwsh >/dev/null 2>&1 || return 1
    echo "Installed official PowerShell ${release_tag} archive for Linux ${runtime_target} (${arch})."
}

install_powershell_runtime_dependencies() {
    local icu_package="" ssl_package="" gcc_package=""
    echo "Installing PowerShell runtime libraries for the detected package manager..."
    if command -v apt-get >/dev/null 2>&1; then
        # ICU and OpenSSL package names carry ABI versions on Debian-family systems.
        # Select the newest candidate published by the configured distro repositories.
        for candidate in libicu80 libicu78 libicu76 libicu74 libicu72 libicu70 libicu67 libicu66 libicu63 libicu60 libicu57 libicu55; do
            if apt-cache show "$candidate" >/dev/null 2>&1; then icu_package="$candidate"; break; fi
        done
        for candidate in libssl3t64 libssl3 libssl1.1 libssl1.0.2; do
            if apt-cache show "$candidate" >/dev/null 2>&1; then ssl_package="$candidate"; break; fi
        done
        for candidate in libgcc-s1 libgcc1; do
            if apt-cache show "$candidate" >/dev/null 2>&1; then gcc_package="$candidate"; break; fi
        done
        if [ -z "$icu_package" ] || [ -z "$ssl_package" ] || [ -z "$gcc_package" ]; then
            echo "[ERROR] Could not resolve PowerShell's ICU, OpenSSL, or GCC runtime library package from APT repositories." >&2
            return 1
        fi
        run_as_root apt-get install -y ca-certificates "$icu_package" "$ssl_package" libgssapi-krb5-2 "$gcc_package" libstdc++6 zlib1g
    elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y ca-certificates libicu openssl-libs krb5-libs libgcc libstdc++ zlib lttng-ust
    elif command -v yum >/dev/null 2>&1; then
        run_as_root yum install -y ca-certificates libicu openssl-libs krb5-libs libgcc libstdc++ zlib lttng-ust
    elif command -v pacman >/dev/null 2>&1; then
        run_as_root pacman -S --needed --noconfirm ca-certificates icu openssl krb5 gcc-libs zlib lttng-ust
    elif command -v zypper >/dev/null 2>&1; then
        run_as_root zypper --non-interactive install ca-certificates libicu libopenssl3 krb5 libgcc_s1 libstdc++6 zlib liblttng-ust0
    elif command -v apk >/dev/null 2>&1; then
        # Keep this list aligned with Microsoft's Alpine binary-archive guidance.
        run_as_root apk add --no-cache ca-certificates ncurses-terminfo-base krb5-libs libgcc libintl libssl3 libstdc++ tzdata userspace-rcu zlib icu-libs
    else
        echo "[ERROR] No supported package manager was detected. Install PowerShell and its distribution-specific runtime dependencies, then retry." >&2
        return 1
    fi
}

# 1. Install Dependencies
echo "[1/5] Checking and installing dependencies (fuse3, rclone, powershell)..."
if command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update -y
    run_as_root apt-get install -y fuse3 rclone curl wget python3 tar
elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y fuse3 rclone curl wget python3 tar
elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y fuse3 rclone curl wget python3 tar
elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -S --needed --noconfirm fuse3 rclone curl wget python tar
elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive refresh
    run_as_root zypper --non-interactive install fuse3 rclone curl wget python3 tar
elif command -v apk >/dev/null 2>&1; then
    run_as_root apk add fuse3 rclone curl wget python3 tar bash
else
    echo "[INFO] No supported package manager detected; checking existing dependencies."
fi

if ! command -v pwsh >/dev/null 2>&1; then
    echo "PowerShell was not found; installing the official portable release for this CPU architecture..."
    install_powershell_runtime_dependencies
    install_powershell_archive
fi

for required_command in pwsh rclone; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "[ERROR] Required command '$required_command' is unavailable after dependency setup." >&2
        exit 1
    fi
done
if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
    echo "[ERROR] FUSE 3 mount helper is missing. Install the FUSE 3 package for this distribution." >&2
    exit 1
fi

# 2. Configure FUSE permissions for user mounting
echo "[2/5] Configuring FUSE permissions..."
if [ -f /etc/fuse.conf ]; then
    if ! grep -q "^user_allow_other" /etc/fuse.conf; then
        echo "user_allow_other" | run_as_root tee -a /etc/fuse.conf >/dev/null
    fi
fi

# 3. Create Global CLI & Desktop App Symlinks
echo "[3/5] Installing /usr/local/bin/nsclouddrive & desktop app launchers..."
    run_as_root chmod +x "$SCRIPT_DIR/nsclouddrive"
    run_as_root chmod +x "$SCRIPT_DIR/nsclouddrive-app"
    run_as_root ln -sf "$SCRIPT_DIR/nsclouddrive" /usr/local/bin/nsclouddrive
    run_as_root ln -sf "$SCRIPT_DIR/nsclouddrive-app" /usr/local/bin/nsclouddrive-app
    run_as_root ln -sf "$SCRIPT_DIR/nsclouddrive-app" /usr/local/bin/nsclouddrive-gui

# 4. Install Application Icons & Desktop Entries
echo "[4/5] Installing desktop menu launchers, icons, and desktop shortcuts..."
ICON_SRC="$REPO_ROOT/assets/logos/clouddrive.png"
if [ -f "$ICON_SRC" ]; then
    run_as_root mkdir -p /usr/share/pixmaps
    run_as_root cp "$ICON_SRC" /usr/share/pixmaps/nsclouddrive.png

    for size in 256x256 128x128 64x64 48x48 32x32; do
        run_as_root mkdir -p "/usr/share/icons/hicolor/$size/apps"
        run_as_root cp "$ICON_SRC" "/usr/share/icons/hicolor/$size/apps/nsclouddrive.png"
    done
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        $SUDO gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
    fi
fi

DESKTOP_SRC="$SCRIPT_DIR/desktop/nsclouddrive.desktop"
if [ -f "$DESKTOP_SRC" ]; then
    run_as_root mkdir -p /usr/share/applications
    run_as_root cp "$DESKTOP_SRC" /usr/share/applications/nsclouddrive.desktop
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
echo "[5/5] Configuring systemd user services when available..."
USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
mkdir -p "$USER_SYSTEMD_DIR"
cp "$SCRIPT_DIR/systemd/nsclouddrive.service" "$USER_SYSTEMD_DIR/nsclouddrive.service"
if [ -f "$SCRIPT_DIR/systemd/nsclouddrive-ui.service" ]; then
    ui_working_directory="$(systemd_quote_path "$REPO_ROOT")"
    ui_service_temp="$(mktemp "${USER_SYSTEMD_DIR}/.nsclouddrive-ui.XXXXXX")"
    while IFS= read -r service_line || [ -n "$service_line" ]; do
        case "$service_line" in
            WorkingDirectory=*) printf 'WorkingDirectory=%s\n' "$ui_working_directory" ;;
            *) printf '%s\n' "$service_line" ;;
        esac
    done < "$SCRIPT_DIR/systemd/nsclouddrive-ui.service" > "$ui_service_temp"
    if ! grep -q '^WorkingDirectory=' "$ui_service_temp"; then
        rm -f -- "$ui_service_temp"
        echo "[ERROR] The NS Cloud Drive UI service template is missing WorkingDirectory." >&2
        exit 1
    fi
    mv "$ui_service_temp" "$USER_SYSTEMD_DIR/nsclouddrive-ui.service"
fi
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable --now nsclouddrive.service
    systemctl --user enable --now nsclouddrive-ui.service
else
    echo "[INFO] systemd user services are not available in this session. Run 'nsclouddrive daemon' to start the background service."
fi

echo ""
echo "=== Installation Complete! ==="
echo "NS Cloud Drive Desktop App is installed and ready."
echo "Launch it via:"
echo "  * Applications Menu -> Internet / Accessories -> NS Cloud Drive"
echo "  * Desktop icon: 'NS Cloud Drive'"
echo "  * Terminal command: nsclouddrive app"
