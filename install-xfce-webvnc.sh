#!/usr/bin/env bash
# Install a minimal XFCE desktop with TigerVNC + noVNC inside a systemd LXC.
# Supported container guests: Debian 13 (trixie) and Ubuntu 24.04 (noble).
set -Eeuo pipefail
export LC_ALL=C
DESKTOP_USER=webdesktop
DESKTOP_HOME=/home/webdesktop
VNC_UNIT=/etc/systemd/system/xfce-vnc.service
WEB_UNIT=/etc/systemd/system/xfce-webvnc.service
MARKER='# Managed by install-xfce-webvnc'

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Run this script as root inside the target container.'
[[ -d /run/systemd/system ]] || die 'This script needs a container booted with systemd.'
trap 'echo "Failed at line $LINENO. Check the error above; service logs: journalctl -u xfce-vnc -u xfce-webvnc -n 80 --no-pager" >&2' ERR

if [[ ${1:-} == --uninstall ]]; then
    for unit in "$WEB_UNIT" "$VNC_UNIT"; do
        [[ ! -e $unit ]] || grep -qF "$MARKER" "$unit" || die "Unmanaged file: $unit"
    done
    systemctl disable --now xfce-webvnc.service xfce-vnc.service 2>/dev/null || true
    rm -f "$WEB_UNIT" "$VNC_UNIT"
    systemctl daemon-reload
    echo 'Services removed. Desktop packages, account and user files are retained.'
    exit 0
fi
[[ $# == 0 ]] || die 'Usage: bash install-xfce-webvnc.sh [--uninstall]'

source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
    debian:13|ubuntu:24.04) ;;
    *) die "Supported container systems: Debian 13 and Ubuntu 24.04. Detected: ${PRETTY_NAME:-unknown} (ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown})." ;;
esac
for unit in "$VNC_UNIT" "$WEB_UNIT"; do
    [[ ! -e $unit ]] || grep -qF "$MARKER" "$unit" || die "Will not overwrite existing file: $unit"
done

if [[ -z ${VNC_PASSWORD:-} ]]; then
    [[ -r /dev/tty ]] || die 'Run interactively, or supply VNC_PASSWORD through the environment.'
    read -r -s -p 'Set VNC password (6-8 printable ASCII characters): ' VNC_PASSWORD < /dev/tty
    echo
    read -r -s -p 'Repeat password: ' VNC_CONFIRM < /dev/tty
    echo
    [[ $VNC_PASSWORD == "$VNC_CONFIRM" ]] || die 'Passwords do not match.'
    unset VNC_CONFIRM
fi
[[ ${#VNC_PASSWORD} -ge 6 && ${#VNC_PASSWORD} -le 8 ]] || die 'Classic VNC uses at most 8 characters; supply 6-8.'
[[ ! $VNC_PASSWORD =~ [^[:print:]] ]] || die 'Use printable ASCII characters for the VNC password.'
# Keep the password out of package-manager subprocess environments.
export -n VNC_PASSWORD

echo '[1/4] Installing XFCE, TigerVNC and noVNC...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xfce4 xfce4-terminal dbus-x11 dbus-user-session \
    tigervnc-standalone-server tigervnc-common tigervnc-tools novnc websockify \
    fonts-dejavu-core fonts-wqy-microhei iproute2
[[ -x /usr/bin/tigervncserver && -x /usr/bin/tigervncpasswd && -x /usr/bin/websockify ]] || die 'Required program missing after installation.'
[[ -r /usr/share/novnc/vnc.html ]] || die 'noVNC web files are missing.'

# Catch common collisions without interrupting unrelated desktop services.
if [[ ! -e $VNC_UNIT ]]; then
    [[ -z $(ss -H -ltn 'sport = :5901') && ! -e /tmp/.X1-lock && ! -S /tmp/.X11-unix/X1 ]] || die 'VNC port 5901 or X display :1 is already in use.'
fi
if [[ ! -e $WEB_UNIT ]]; then
    [[ -z $(ss -H -ltn 'sport = :6080') ]] || die 'TCP 6080 is already in use.'
fi

echo '[2/4] Preparing the desktop account...'
if id "$DESKTOP_USER" >/dev/null 2>&1; then
    [[ $(getent passwd "$DESKTOP_USER" | cut -d: -f6) == "$DESKTOP_HOME" ]] || die 'Existing webdesktop account has an unexpected home directory.'
else
    useradd --create-home --home-dir "$DESKTOP_HOME" --shell /bin/bash "$DESKTOP_USER"
fi
[[ -d $DESKTOP_HOME ]] || die 'Desktop home directory is missing.'
[[ $(id -u "$DESKTOP_USER") != 0 ]] || die 'Desktop account must not be root.'
install -d -m 700 -o "$DESKTOP_USER" -g "$(id -gn "$DESKTOP_USER")" "$DESKTOP_HOME/.vnc"
# Stop only services managed by this installer before updating their configuration.
if [[ -e $WEB_UNIT ]]; then systemctl stop xfce-webvnc.service; fi
if [[ -e $VNC_UNIT ]]; then systemctl stop xfce-vnc.service; fi
(umask 077; printf '%s\n' "$VNC_PASSWORD" | /usr/bin/tigervncpasswd -f > "$DESKTOP_HOME/.vnc/passwd")
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

echo '[3/4] Installing boot services...'
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

echo '[4/4] Starting services...'
systemctl daemon-reload
systemctl enable --now xfce-vnc.service xfce-webvnc.service
ready=0
for attempt in {1..15}; do
    if systemctl is-active --quiet xfce-vnc.service && \
       systemctl is-active --quiet xfce-webvnc.service && \
       [[ -n $(ss -H -ltn 'sport = :5901') && -n $(ss -H -ltn 'sport = :6080') ]]; then
        ready=1
        break
    fi
    sleep 1
done
if [[ $ready != 1 ]]; then
    journalctl -u xfce-vnc.service -u xfce-webvnc.service -n 80 --no-pager
    die 'Services did not become ready. See logs above.'
fi
echo
echo 'Ready: http://CONTAINER_IP:6080/vnc.html?autoconnect=1&resize=remote'
echo 'Browser login uses the VNC password set above; no Linux username is needed.'
echo 'For external access, map an A host TCP port to this container TCP 6080.'
echo 'Container IPv4 addresses:'
ip -4 -o addr show scope global
