#!/usr/bin/env bash
# Install XFCE, Chrome and TigerVNC + noVNC inside a systemd LXC.
# Supported container guests: Debian 13 (trixie) and Ubuntu 24.04 (noble).
set -Eeuo pipefail
export LC_ALL=C
DESKTOP_USER=webdesktop
DESKTOP_HOME=/home/webdesktop
VNC_UNIT=/etc/systemd/system/xfce-vnc.service
WEB_UNIT=/etc/systemd/system/xfce-webvnc.service
PRIVILEGE_DROPIN=/etc/systemd/system/xfce-vnc.service.d/zzzz-webdesktop-privileges.conf
SUDOERS_FILE=/etc/sudoers.d/90-xfce-webdesktop
MARKER='# Managed by install-xfce-webvnc'
MODE=install
PACKAGE_DIR=''

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
    for unit in "$WEB_UNIT" "$VNC_UNIT" "$PRIVILEGE_DROPIN" "$SUDOERS_FILE"; do
        [[ ! -e $unit ]] || grep -qF "$MARKER" "$unit" || die "Unmanaged file: $unit"
    done
    systemctl disable --now xfce-webvnc.service xfce-vnc.service 2>/dev/null || true
    rm -f "$WEB_UNIT" "$VNC_UNIT" "$PRIVILEGE_DROPIN" "$SUDOERS_FILE"
    systemctl daemon-reload
    echo 'Services and managed passwordless sudo permission removed. Packages, account and user files are retained.'
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
[[ $(awk '$1 == "NoNewPrivs:" {print $2}' /proc/1/status) == 0 ]] || die 'Container PID 1 has NoNewPrivs=1. This cannot be cleared inside the container. On A, inspect this container LXC configuration (including lxc.no_new_privs), disable the inherited flag and stop/start the container, then rerun.'
for unit in "$VNC_UNIT" "$WEB_UNIT" "$PRIVILEGE_DROPIN" "$SUDOERS_FILE"; do
    [[ ! -e $unit ]] || grep -qF "$MARKER" "$unit" || die "Will not overwrite existing file: $unit"
done
if [[ $MODE == repair ]]; then
    [[ -f $VNC_UNIT && -f $WEB_UNIT && -s $DESKTOP_HOME/.vnc/passwd ]] || die '--repair requires an existing managed installation and VNC password.'
    id "$DESKTOP_USER" >/dev/null 2>&1 || die 'Desktop account is missing.'
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

echo '[1/5] Installing XFCE, TigerVNC, noVNC and administration tools...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xfce4 xfce4-terminal dbus-x11 dbus-user-session \
    tigervnc-standalone-server tigervnc-common tigervnc-tools novnc websockify \
    fonts-dejavu-core fonts-wqy-microhei iproute2 sudo curl ca-certificates
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

echo '[3/5] Preparing the desktop account and sudo permission...'
if id "$DESKTOP_USER" >/dev/null 2>&1; then
    [[ $(getent passwd "$DESKTOP_USER" | cut -d: -f6) == "$DESKTOP_HOME" ]] || die 'Existing webdesktop account has an unexpected home directory.'
else
    useradd --create-home --home-dir "$DESKTOP_HOME" --shell /bin/bash "$DESKTOP_USER"
fi
[[ -d $DESKTOP_HOME ]] || die 'Desktop home directory is missing.'
[[ $(id -u "$DESKTOP_USER") != 0 ]] || die 'Desktop account must not be root.'
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

# This desktop is administered by its owner: permit sudo without an additional
# Linux password. The VNC password remains independent from the Linux account.
install -d -m 755 /etc/sudoers.d
sudoers_tmp=$(mktemp /etc/sudoers.d/.xfce-webdesktop.XXXXXX)
printf '%s\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$MARKER" "$DESKTOP_USER" > "$sudoers_tmp"
chmod 440 "$sudoers_tmp"
visudo -cf "$sudoers_tmp"
mv -f "$sudoers_tmp" "$SUDOERS_FILE"

install -d -m 755 -o "$DESKTOP_USER" -g "$(id -gn "$DESKTOP_USER")" "$DESKTOP_HOME/Desktop"
install -m 755 -o "$DESKTOP_USER" -g "$(id -gn "$DESKTOP_USER")" \
    /usr/share/applications/google-chrome.desktop "$DESKTOP_HOME/Desktop/google-chrome.desktop"

echo '[4/5] Installing boot services and desktop privilege override...'
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
ExecStartPre=/usr/bin/sudo -n /usr/bin/true
ExecStart=/usr/bin/tigervncserver :1 -fg -localhost yes -geometry 1600x900 -depth 24 -SecurityTypes VncAuth -PasswordFile $DESKTOP_HOME/.vnc/passwd -xstartup $DESKTOP_HOME/.vnc/xstartup
ExecStop=-/usr/bin/tigervncserver -kill :1
Restart=on-failure
RestartSec=3
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

# A generic /run/systemd/system/service.d/zzz-lxc-service.conf can set
# NoNewPrivileges for every service. A unit-specific, later-sorting drop-in
# overrides it for this desktop only, without modifying the generated LXC file.
install -d -m 755 "$(dirname "$PRIVILEGE_DROPIN")"
cat > "$PRIVILEGE_DROPIN" <<EOF
$MARKER
[Service]
NoNewPrivileges=no
RestrictSUIDSGID=no
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

echo '[5/5] Starting services and checking desktop privileges...'
systemctl daemon-reload
[[ $(systemctl show xfce-vnc.service -p NoNewPrivileges --value) == no ]] || die 'Another systemd setting still enables NoNewPrivileges. Inspect: systemctl cat xfce-vnc.service'
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
[[ $(awk '$1 == "NoNewPrivs:" {print $2}' "/proc/$desktop_pid/status") == 0 ]] || die 'Desktop still inherits NoNewPrivs=1. Inspect systemd drop-ins and the container parent configuration.'
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
echo 'Desktop NoNewPrivs=0; webdesktop has passwordless sudo. Chrome is available in the applications menu and on the desktop.'
echo 'Reconnect noVNC to use the restarted desktop session.'
echo 'Container IPv4 addresses:'
ip -4 -o addr show scope global
