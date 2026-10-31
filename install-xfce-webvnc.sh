#!/usr/bin/env bash
# Install XFCE, Chrome and TigerVNC + noVNC inside a systemd LXC.
# Supported container guests: Debian 13 (trixie) and Ubuntu 24.04 (noble).
set -Eeuo pipefail
export LC_ALL=C
DESKTOP_USER=root
DESKTOP_HOME=/root
VNC_UNIT=/etc/systemd/system/xfce-vnc.service
WEB_UNIT=/etc/systemd/system/xfce-webvnc.service
PRIVILEGE_DROPIN=/etc/systemd/system/xfce-vnc.service.d/zzzz-webdesktop-privileges.conf
SUDOERS_FILE=/etc/sudoers.d/90-xfce-webdesktop
CHROME_WRAPPER=/usr/local/bin/chrome-vnc
CHROME_MENU=/root/.local/share/applications/google-chrome.desktop
CHROME_DESKTOP=/root/Desktop/google-chrome.desktop
MARKER='# Managed by install-xfce-webvnc'
MODE=install
PACKAGE_DIR=''
REPAIR_PASSWORD_SOURCE=''
MANAGED_FILES=("$WEB_UNIT" "$VNC_UNIT" "$PRIVILEGE_DROPIN" "$SUDOERS_FILE" "$CHROME_WRAPPER" "$CHROME_MENU" "$CHROME_DESKTOP")

cleanup() {
    if [[ -n $PACKAGE_DIR ]]; then
        rm -f "$PACKAGE_DIR/google-chrome-stable.deb"
        rmdir "$PACKAGE_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Run this script as root inside the target container.'
[[ -d /run/systemd/system ]] || die 'This script needs a container booted with systemd.'
trap 'echo "Failed at line $LINENO. Check the error above; service logs: journalctl -u xfce-vnc -u xfce-webvnc -n 80 --no-pager" >&2' ERR

if [[ ${1:-} == --uninstall ]]; then
    for unit in "${MANAGED_FILES[@]}"; do
        [[ ! -e $unit ]] || grep -qF "$MARKER" "$unit" || die "Unmanaged file: $unit"
    done
    systemctl disable --now xfce-webvnc.service xfce-vnc.service 2>/dev/null || true
    rm -f "${MANAGED_FILES[@]}"
    systemctl daemon-reload
    echo 'Services, managed Chrome launchers and old managed sudo permission removed. Packages and desktop files are retained.'
    exit 0
fi
if [[ $# == 1 && $1 == --repair ]]; then
    MODE=repair
else
    [[ $# == 0 ]] || die 'Usage: bash install-xfce-webvnc.sh [--repair | --uninstall]'
fi

source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
    debian:13|ubuntu:24.04) ;;
    *) die "Supported container systems: Debian 13 and Ubuntu 24.04. Detected: ${PRETTY_NAME:-unknown} (ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown})." ;;
esac
[[ $(dpkg --print-architecture) == amd64 ]] || die 'Official Google Chrome for Linux requires an amd64 container.'
for unit in "${MANAGED_FILES[@]}"; do
    [[ ! -e $unit ]] || grep -qF "$MARKER" "$unit" || die "Will not overwrite existing file: $unit"
done
if [[ $MODE == repair ]]; then
    [[ -f $VNC_UNIT && -f $WEB_UNIT ]] || die '--repair requires an existing managed installation. Use no arguments for a new installation.'
    for password_file in /root/.vnc/passwd /root/.config/tigervnc/passwd /home/webdesktop/.vnc/passwd /home/webdesktop/.config/tigervnc/passwd; do
        if [[ -s $password_file ]]; then
            REPAIR_PASSWORD_SOURCE=$password_file
            break
        fi
    done
    [[ -n $REPAIR_PASSWORD_SOURCE ]] || die 'No existing VNC password found. Run without --repair to set a new password.'
fi

if [[ $MODE != repair && -z ${VNC_PASSWORD:-} ]]; then
    [[ -r /dev/tty ]] || die 'Run interactively, or supply VNC_PASSWORD through the environment.'
    read -r -s -p 'Set VNC password (6-8 printable ASCII characters): ' VNC_PASSWORD < /dev/tty
    echo
    read -r -s -p 'Repeat password: ' VNC_CONFIRM < /dev/tty
    echo
    [[ $VNC_PASSWORD == "$VNC_CONFIRM" ]] || die 'Passwords do not match.'
    unset VNC_CONFIRM
fi
if [[ $MODE != repair ]]; then
    [[ ${#VNC_PASSWORD} -ge 6 && ${#VNC_PASSWORD} -le 8 ]] || die 'Classic VNC uses at most 8 characters; supply 6-8.'
    [[ ! $VNC_PASSWORD =~ [^[:print:]] ]] || die 'Use printable ASCII characters for the VNC password.'
fi
# Keep the password out of package-manager subprocess environments.
export -n VNC_PASSWORD

echo '[1/5] Installing XFCE, TigerVNC and noVNC...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xfce4 xfce4-terminal dbus-x11 dbus-user-session \
    tigervnc-standalone-server tigervnc-common tigervnc-tools novnc websockify \
    fonts-dejavu-core fonts-wqy-microhei iproute2 curl ca-certificates
[[ -x /usr/bin/tigervncserver && -x /usr/bin/tigervncpasswd && -x /usr/bin/websockify ]] || die 'Required program missing after installation.'
[[ -r /usr/share/novnc/vnc.html ]] || die 'noVNC web files are missing.'

echo '[2/5] Installing official Google Chrome...'
if [[ $(dpkg-query -W -f='${Status}' google-chrome-stable 2>/dev/null || true) != 'install ok installed' || ! -x /usr/bin/google-chrome-stable ]]; then
    PACKAGE_DIR=$(mktemp -d /var/tmp/xfce-webvnc.XXXXXX)
    chmod 755 "$PACKAGE_DIR"
    curl --fail --location --retry 3 --connect-timeout 15 --max-time 600 \
        --output "$PACKAGE_DIR/google-chrome-stable.deb" \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    [[ $(dpkg-deb -f "$PACKAGE_DIR/google-chrome-stable.deb" Package) == google-chrome-stable ]] || die 'Unexpected Chrome package name.'
    [[ $(dpkg-deb -f "$PACKAGE_DIR/google-chrome-stable.deb" Architecture) == amd64 ]] || die 'Unexpected Chrome package architecture.'
    chmod 644 "$PACKAGE_DIR/google-chrome-stable.deb"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$PACKAGE_DIR/google-chrome-stable.deb"
    cleanup
    PACKAGE_DIR=''
fi
/usr/bin/google-chrome-stable --version

# Catch common collisions without interrupting unrelated desktop services.
if [[ ! -e $VNC_UNIT ]]; then
    [[ -z $(ss -H -ltn 'sport = :5901') && ! -e /tmp/.X1-lock && ! -S /tmp/.X11-unix/X1 ]] || die 'VNC port 5901 or X display :1 is already in use.'
fi
if [[ ! -e $WEB_UNIT ]]; then
    [[ -z $(ss -H -ltn 'sport = :6080') ]] || die 'TCP 6080 is already in use.'
fi

echo '[3/5] Preparing the root desktop and migrating the VNC password...'
[[ -d $DESKTOP_HOME ]] || die 'Desktop home directory is missing.'
# Stop only services managed by this installer before updating their configuration.
if [[ -e $WEB_UNIT ]]; then systemctl stop xfce-webvnc.service; fi
if [[ -e $VNC_UNIT ]]; then systemctl stop xfce-vnc.service; fi
if [[ $ID == debian ]]; then
    # Debian 13's TigerVNC 1.15 migrates ~/.vnc only if this directory
    # is absent; migration fails in minimal homes without a ~/.config parent.
    # Pre-create the modern directories. Explicit password/startup paths below
    # continue using ~/.vnc, so existing installations keep their paths.
    install -d -m 700 -o "$DESKTOP_USER" -g "$(id -gn "$DESKTOP_USER")" \
        "$DESKTOP_HOME/.config" "$DESKTOP_HOME/.config/tigervnc"
fi
install -d -m 700 -o "$DESKTOP_USER" -g "$(id -gn "$DESKTOP_USER")" "$DESKTOP_HOME/.vnc"
if [[ $MODE != repair ]]; then
    (umask 077; printf '%s\n' "$VNC_PASSWORD" | /usr/bin/tigervncpasswd -f > "$DESKTOP_HOME/.vnc/passwd")
elif [[ ! $REPAIR_PASSWORD_SOURCE -ef $DESKTOP_HOME/.vnc/passwd ]]; then
    install -m 600 -o root -g root "$REPAIR_PASSWORD_SOURCE" "$DESKTOP_HOME/.vnc/passwd"
fi
unset VNC_PASSWORD
cat > "$DESKTOP_HOME/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-run-session -- startxfce4
EOF
chown "$DESKTOP_USER:$(id -gn "$DESKTOP_USER")" "$DESKTOP_HOME/.vnc/passwd" "$DESKTOP_HOME/.vnc/xstartup"
chmod 600 "$DESKTOP_HOME/.vnc/passwd"
chmod 700 "$DESKTOP_HOME/.vnc/xstartup"

# The desktop now starts as UID 0 and does not elevate through sudo. Retire only
# the privilege overrides written by earlier versions; keep the old user's files.
rm -f "$PRIVILEGE_DROPIN" "$SUDOERS_FILE"

# Chrome refuses to run as root with its regular sandbox. This launcher is
# specifically for the user-requested root desktop; it disables Chrome's sandbox.
install -d -m 755 /usr/local/bin "$DESKTOP_HOME/Desktop" "$DESKTOP_HOME/.local/share/applications"
cat > "$CHROME_WRAPPER" <<EOF
#!/bin/sh
$MARKER
exec /usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --user-data-dir=/root/.config/google-chrome-vnc "\$@"
EOF
chmod 755 "$CHROME_WRAPPER"
cat > "$CHROME_MENU" <<EOF
$MARKER
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Comment=Chrome for the root VNC desktop (sandbox disabled)
Exec=$CHROME_WRAPPER %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
StartupWMClass=Google-chrome
EOF
install -m 755 -o root -g root "$CHROME_MENU" "$CHROME_DESKTOP"

echo '[4/5] Installing root desktop boot services...'
cat > "$VNC_UNIT" <<EOF
$MARKER
[Unit]
Description=XFCE desktop on TigerVNC display :1
After=network.target

[Service]
Type=simple
User=$DESKTOP_USER
WorkingDirectory=$DESKTOP_HOME
Environment=HOME=$DESKTOP_HOME
Environment=LANG=C.UTF-8
Environment=XDG_RUNTIME_DIR=/run/xfce-vnc
RuntimeDirectory=xfce-vnc
RuntimeDirectoryMode=0700
ExecStart=/usr/bin/tigervncserver :1 -fg -localhost yes -geometry 1600x900 -depth 24 -SecurityTypes VncAuth -PasswordFile $DESKTOP_HOME/.vnc/passwd -xstartup $DESKTOP_HOME/.vnc/xstartup
ExecStop=-/usr/bin/tigervncserver -kill :1
Restart=on-failure
RestartSec=3
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

cat > "$WEB_UNIT" <<EOF
$MARKER
[Unit]
Description=noVNC browser access to XFCE
Wants=xfce-vnc.service
After=network.target xfce-vnc.service

[Service]
Type=simple
User=$DESKTOP_USER
WorkingDirectory=$DESKTOP_HOME
Environment=HOME=$DESKTOP_HOME
ExecStart=/usr/bin/websockify --web=/usr/share/novnc 0.0.0.0:6080 127.0.0.1:5901
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo '[5/5] Starting services and checking the root desktop...'
systemctl daemon-reload
systemctl enable --now xfce-vnc.service xfce-webvnc.service
ready=0
stable_checks=0
for attempt in {1..15}; do
    if systemctl is-active --quiet xfce-vnc.service && \
       systemctl is-active --quiet xfce-webvnc.service && \
       [[ -n $(ss -H -ltn 'sport = :5901') && -n $(ss -H -ltn 'sport = :6080') ]]; then
        stable_checks=$((stable_checks + 1))
        if (( stable_checks >= 3 )); then
            ready=1
            break
        fi
    else
        stable_checks=0
    fi
    sleep 1
done
if [[ $ready != 1 ]]; then
    journalctl -u xfce-vnc.service -u xfce-webvnc.service -n 80 --no-pager
    die 'Services did not become ready. See logs above.'
fi
desktop_pid=$(systemctl show xfce-vnc.service -p MainPID --value)
[[ $desktop_pid =~ ^[1-9][0-9]*$ && -r /proc/$desktop_pid/status ]] || die 'Cannot inspect desktop process privileges.'
[[ $(awk '$1 == "Uid:" {print $2, $3}' "/proc/$desktop_pid/status") == '0 0' ]] || die 'Desktop process is not running with real/effective UID 0.'
desktop_nnp=$(awk '$1 == "NoNewPrivs:" {print $2}' "/proc/$desktop_pid/status")
python3 - <<'PY'
import socket
with socket.create_connection(('127.0.0.1', 5901), timeout=3) as connection:
    banner = connection.recv(12)
    if not banner.startswith(b'RFB '):
        raise SystemExit('VNC backend did not return an RFB banner.')
print('VNC backend responds with an RFB banner.')
PY
echo
echo 'Ready: http://CONTAINER_IP:6080/vnc.html?autoconnect=1&resize=remote'
echo 'Browser login uses the VNC password set above; no Linux username is needed.'
echo 'For external access, map an A host TCP port to this container TCP 6080.'
echo "Desktop runs as root (UID 0). NoNewPrivs=$desktop_nnp does not require sudo elevation."
echo 'Chrome is available in the applications menu and on the desktop, or run: chrome-vnc'
echo 'The root Chrome launcher uses --no-sandbox; Chrome sandbox protection is disabled.'
echo 'Reconnect noVNC to use the restarted desktop session.'
echo 'Container IPv4 addresses:'
ip -4 -o addr show scope global
