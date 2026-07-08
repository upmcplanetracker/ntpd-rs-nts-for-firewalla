#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

SCRIPT_PATH="$(realpath "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
URL_CONFIG="/etc/ntpd-rs-url.conf"
SYSTEMD_BOOT_SERVICE="/etc/systemd/system/ntpd-rs-boot-enforce.service"

DEB_URL=""

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            echo "Usage: ${SCRIPT_NAME} <url-to-ntpd-rs-deb-package>"
            echo "   or if URL is already saved: ${SCRIPT_NAME}"
            exit 0
            ;;
        *)
            if [ -z "$DEB_URL" ]; then DEB_URL="$arg"; fi
            ;;
    esac
done

if [ -z "$DEB_URL" ]; then
    if [ -f "$URL_CONFIG" ]; then
        DEB_URL=$(head -n1 "$URL_CONFIG")
    else
        echo "Error: No package URL provided and $URL_CONFIG not found."
        echo "Usage: ${SCRIPT_NAME} <url-to-ntpd-rs-deb-package>"
        exit 1
    fi
fi

echo "$DEB_URL" > "$URL_CONFIG"

CONFIG_FILE="/etc/ntpd-rs-interface.conf"
HEALTH_CHECK_INTERVAL=300           5 minutes
MAX_RESTARTS=3
RESTART_COUNTER_FILE="/tmp/ntpd_rs_restart_counter"
LAST_HEALTH_CHECK="/tmp/ntpd_rs_last_health"
CRON_TAG="# NTPD-RS NTS Service"
CRON_JOB="0 4 * * * root $SCRIPT_PATH &>/dev/null"
CRON_FILE="/etc/crontab"
DEB_FILE="/log/ntpd-rs_latest.deb"
LOG_FILE="/log/ntpd-rs-installer.log"
NTPD_CONFIG="/etc/ntpd-rs/ntp.toml"

OLD_CHRONY_TAG="# Chrony NTS Service"

APT_GET_WRAPPER="/home/pi/firewalla/scripts/apt-get.sh"
SYSTEMCTL="/usr/bin/systemctl"
IPTABLES="/sbin/iptables"
IP6TABLES="/sbin/ip6tables"
IP="/sbin/ip"
SED="/bin/sed"
GREP="/bin/grep"
CAT="/bin/cat"
ECHO="/bin/echo"
DATE="/bin/date"
SLEEP="/bin/sleep"
RM="/bin/rm"
FUSER="/usr/bin/fuser"

unalias -a 2>/dev/null || true

FROM_CRON=0
if [ -z "$TERM" ] && [ -t 0 ] 2>/dev/null; then
    FROM_CRON=1
fi

log() {
    local msg="[$($DATE '+%Y-%m-%d %H:%M:%S')] $1"
    $ECHO "$msg" | tee -a "$LOG_FILE"
}

manage_crontab() {
    local action="$1"
    case "$action" in
        "check")  $GREP -q "$CRON_TAG" "$CRON_FILE" 2>/dev/null; return $? ;;
        "update")
            $SED -i "/$CRON_TAG/,+1d" "$CRON_FILE" 2>/dev/null || true
            $ECHO "$CRON_TAG" >> "$CRON_FILE"
            $ECHO "$CRON_JOB" >> "$CRON_FILE"
            log "Updated crontab with daily enforcement job."
            ;;
        "show")   $GREP -A1 "$CRON_TAG" "$CRON_FILE" 2>/dev/null || $ECHO "No cron entry found" ;;
    esac
}

remove_old_chrony_cron() {
    if $GREP -q "$OLD_CHRONY_TAG" "$CRON_FILE" 2>/dev/null; then
        log "Removing old chrony cron entry..."
        $SED -i "/$OLD_CHRONY_TAG/,+1d" "$CRON_FILE" 2>/dev/null || true
        log "Old chrony cron entry removed."
    fi
}

get_lan_interfaces() {
    local interfaces=""
    for iface in $($IP link show type bridge 2>/dev/null | $GREP -E '^[0-9]+:' | awk -F': ' '{print $2}'); do
        if $IP addr show "$iface" | $GREP -q "inet "; then
            interfaces="$interfaces $iface"
        fi
    done
    if [ -z "$interfaces" ]; then
        for iface in $($IP link show | $GREP -E '^[0-9]+: (eth|en|wl)' | awk -F': ' '{print $2}' | cut -d'@' -f1); do
            if $IP addr show "$iface" | $GREP -q "inet " && [[ ! "$iface" =~ (wan|ppp|tun|wg|vpn) ]]; then
                interfaces="$interfaces $iface"
            fi
        done
    fi
    [ -z "$interfaces" ] && $ECHO "br0" && return
    $ECHO "$interfaces" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

get_lan_ips() {
    local ips=""
    local interfaces=$(get_lan_interfaces)
    for iface in $interfaces; do
        $IP -4 addr show "$iface" | $GREP 'inet ' | while read line; do
            local cidr=$(echo "$line" | awk '{print $2}')
            local ip=$(echo "$cidr" | cut -d'/' -f1)
            if [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^10\. ]] || \
               [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
               [[ "$ip" =~ ^169\.254\. ]]; then
                echo "$ip"
            fi
        done
    done | sort -u | tr '\n' ' '
}

apply_iptables_rules() {
    local interfaces=$(get_lan_interfaces)
    for iface in $interfaces; do
        $IPTABLES -t nat -D PREROUTING -i "$iface" -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
        $IP6TABLES -t nat -D PREROUTING -i "$iface" -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
    done
    for iface in $interfaces; do
        log "Adding redirect rule for interface: $iface"
        $IPTABLES -t nat -A PREROUTING -i "$iface" -p udp --dport 123 -j REDIRECT --to-port 123
        if $IP -6 addr show "$iface" | $GREP -q "inet6"; then
            $IP6TABLES -t nat -A PREROUTING -i "$iface" -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
        fi
    done
}

is_ntpd_rs_healthy() {
    if ! $SYSTEMCTL is-active --quiet "$NTPD_SERVICE"; then
        return 1
    fi

    local stratum=""

    if command -v jq &>/dev/null; then
        local status_json
        status_json=$(ntp-ctl -c "$NTPD_CONFIG" -j status 2>/dev/null || true)
        if [ -n "$status_json" ]; then
            stratum=$(echo "$status_json" | jq -r '.stratum // empty' 2>/dev/null)
        fi
    fi

    if [ -z "$stratum" ]; then
        stratum=$(ntp-ctl -c "$NTPD_CONFIG" status 2>/dev/null | awk '/Stratum:/{print $2}')
    fi

    if [ -n "$stratum" ] && [ "$stratum" -lt 16 ] 2>/dev/null; then
        return 0
    fi

    return 1
}

should_check_health() {
    [ ! -f "$LAST_HEALTH_CHECK" ] && return 0
    local last_check=$($CAT "$LAST_HEALTH_CHECK")
    local current_time=$($DATE +%s)
    [ $((current_time - last_check)) -ge $HEALTH_CHECK_INTERVAL ]
}

manage_restart_counter() {
    case "$1" in
        "increment")
            local count=1
            [ -f "$RESTART_COUNTER_FILE" ] && count=$($CAT "$RESTART_COUNTER_FILE")
            count=$((count + 1))
            $ECHO "$count" > "$RESTART_COUNTER_FILE"
            ;;
        "reset") $RM -f "$RESTART_COUNTER_FILE" ;;
        "get")
            if [ -f "$RESTART_COUNTER_FILE" ]; then $CAT "$RESTART_COUNTER_FILE"; else $ECHO "0"; fi
            ;;
    esac
}

neutralize_and_purge_conflicts() {
    log "Neutralizing competing NTP services..."
    $CAT > /etc/apt/preferences.d/block-ntp <<EOF
Package: ntp ntpdate systemd-timesyncd chrony ntpsec
Pin: origin *
Pin-Priority: -1
EOF

    for svc in ntp ntpdate systemd-timesyncd ntp-systemd-netif chrony chronyd ntpsec; do
        $SYSTEMCTL stop "$svc.service" 2>/dev/null || true
        $SYSTEMCTL disable "$svc.service" 2>/dev/null || true
        $SYSTEMCTL mask "$svc.service" 2>/dev/null || true
    done

    CONFLICTING_DAEMONS=("chrony" "ntpsec" "ntp" "ntpdate")
    for daemon in "${CONFLICTING_DAEMONS[@]}"; do
        STATE=$(dpkg-query -W -f='${Status}' "$daemon" 2>/dev/null || echo "")
        if [[ "$STATE" == "install ok installed" ]] || [[ "$STATE" == *"config-files"* ]] || [[ "$STATE" == *"deinstall"* ]]; then
            log "Purging $daemon..."
            $APT_GET_WRAPPER purge -y "$daemon" 2>/dev/null || apt-get purge -y "$daemon" 2>/dev/null || true
        fi
    done
}

find_ntpd_service_name() {
    if $SYSTEMCTL list-unit-files | $GREP -q "^ntpd-rsd.service"; then
        echo "ntpd-rsd"
    elif $SYSTEMCTL list-unit-files | $GREP -q "^ntpd-rs.service"; then
        echo "ntpd-rs"
    else
        echo "ntpd-rs"
    fi
}

install_boot_service() {
    log "Installing boot-time enforcement service..."
    $CAT > "$SYSTEMD_BOOT_SERVICE" <<EOF
[Unit]
Description=Re-apply ntpd-rs NTP rules and start daemon
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    $SYSTEMCTL daemon-reload
    $SYSTEMCTL enable ntpd-rs-boot-enforce.service 2>/dev/null || true
    log "Boot-time enforcement service enabled."
}

log "===== NTPD-RS enforcement script started ====="

if [ $FROM_CRON -eq 0 ]; then
    log "Checking crontab..."
    remove_old_chrony_cron
    if manage_crontab "check"; then
        if ! $GREP -A1 "$CRON_TAG" "$CRON_FILE" | $GREP -q "$SCRIPT_PATH"; then
            log "Updating cron entry (path changed)..."
            manage_crontab "update"
        else
            log "Cron entry OK."
        fi
    else
        log "Adding cron entry..."
        manage_crontab "update"
    fi
    install_boot_service
fi

log "Discovering LAN interfaces..."
LAN_INTERFACES=$(get_lan_interfaces)
log "Found: $LAN_INTERFACES"
LAN_IPS=$(get_lan_ips)
log "Detected binding IPs: $LAN_IPS"

$CAT > "$CONFIG_FILE" <<EOF
LAN_INTERFACES="$LAN_INTERFACES"
LAN_IPS="$LAN_IPS"
SCRIPT_PATH="$SCRIPT_PATH"
URL="$DEB_URL"
EOF

if [ $FROM_CRON -eq 0 ]; then
    log "Waiting 30s for system settle..."
    $SLEEP 30
fi

NTPD_SERVICE=$(find_ntpd_service_name)

if $SYSTEMCTL is-active --quiet "$NTPD_SERVICE" && \
   $IPTABLES -t nat -L PREROUTING -v -n 2>/dev/null | $GREP -q "dpt:123.*REDIRECT"; then
    log "$NTPD_SERVICE already configured and running."
    neutralize_and_purge_conflicts
    if should_check_health; then
        log "Performing periodic health check..."
        $ECHO "$($DATE +%s)" > "$LAST_HEALTH_CHECK"
        if ! is_ntpd_rs_healthy; then
            log "WARNING: $NTPD_SERVICE unhealthy – restarting once..."
            $SYSTEMCTL restart "$NTPD_SERVICE"
            $SLEEP 10
            if is_ntpd_rs_healthy; then
                log "$NTPD_SERVICE recovered."
                manage_restart_counter "reset"
            else
                log "ERROR: $NTPD_SERVICE still unhealthy."
                local rc=$(manage_restart_counter "get")
                if [ "$rc" -ge "$MAX_RESTARTS" ]; then
                    log "CRITICAL: $NTPD_SERVICE repeatedly failing – manual intervention needed."
                fi
            fi
        else
            log "Health check passed."
            manage_restart_counter "reset"
        fi
    fi
    exit 0
fi

if [ $FROM_CRON -eq 0 ]; then
    log "Checking internet connectivity..."
    INTERNET_UP=0
    for i in {1..30}; do
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            log "Internet is UP."
            INTERNET_UP=1
            break
        fi
        log "Still waiting... ($i/30)"
        $SLEEP 2
    done
    if [ $INTERNET_UP -eq 0 ]; then
        log "ERROR: No internet—cannot download package. Exiting."
        exit 1
    fi
fi

neutralize_and_purge_conflicts

log "Downloading ntpd-rs from: ${DEB_URL}"
if ! wget -q -O "$DEB_FILE" "$DEB_URL"; then
    log "Error: Download failed."
    exit 1
fi

log "Installing/upgrading ntpd-rs using Firewalla Wrapper..."
lock_wait=0
while $FUSER /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock &>/dev/null; do
    if [ $lock_wait -ge 120 ]; then
        log "ERROR: Apt locked >2 min – exiting."
        exit 1
    fi
    log "Apt busy – waiting 5s ($lock_wait/120s)"
    $SLEEP 5
    lock_wait=$((lock_wait + 5))
done

for attempt in {1..3}; do
    log "Install attempt $attempt/3..."
    if $APT_GET_WRAPPER install "$DEB_FILE"; then
        log "ntpd-rs package installed."
        break
    fi
    if [ $attempt -lt 3 ]; then
        log "Retrying in 10s..."
        $SLEEP 10
    else
        log "ERROR: Failed to install ntpd-rs."
        exit 1
    fi
done

NTPD_SERVICE=$(find_ntpd_service_name)
log "Using systemd unit: ${NTPD_SERVICE}.service"

# ─────────────────── CONFIGURATION (NTS ONLY) ──────────────────────
log "Applying ntpd-rs NTS configuration..."

$SED -i '/# Cloudflare/,$d' /etc/hosts 2>/dev/null || true
$CAT >> /etc/hosts <<EOF
162.159.200.1    time.cloudflare.com
94.198.159.15    ntppool1.time.nl
3.134.129.152    ohio.time.system76.com
85.163.168.227   time.cincura.net
91.177.126.188   nts.teambelgium.net
173.206.104.134  time.web-clock.ca
18.228.202.30    brazil.time.system76.com
EOF

mkdir -p /etc/ntpd-rs
$CAT > "$NTPD_CONFIG" <<EOF
# ntpd-rs NTS Configuration for Firewalla
# Generated on $($DATE)

[[source]]
mode = "nts"
address = "time.cloudflare.com"

[[source]]
mode = "nts"
address = "ohio.time.system76.com"

[[source]]
mode = "nts"
address = "ntppool1.time.nl"

[[source]]
mode = "nts"
address = "brazil.time.system76.com"

[[source]]
mode = "nts"
address = "time.cincura.net"

[[source]]
mode = "nts"
address = "nts.teambelgium.net"

[[source]]
mode = "nts"
address = "time.web-clock.ca"

# Listen on all discovered LAN IPs
$(for ip in $LAN_IPS; do
echo "[[server]]"
echo "listen = \"$ip:123\""
echo ""
done)

# Observability socket for ntp-ctl (ntpd-rs >= 1.9.0)
[observability]
observation-path = "/run/ntpd-rs/observe"
EOF
chmod 644 "$NTPD_CONFIG"

# Ensure socket directory exists (tmpfs, so create at runtime)
mkdir -p /run/ntpd-rs

# Unit overrides
mkdir -p /etc/systemd/system/${NTPD_SERVICE}.service.d
$CAT > /etc/systemd/system/${NTPD_SERVICE}.service.d/override.conf <<EOF
[Unit]
Conflicts=chrony.service chronyd.service ntp.service ntpsec.service systemd-timesyncd.service
EOF

log "Starting $NTPD_SERVICE..."
$SYSTEMCTL daemon-reload
$SYSTEMCTL unmask "$NTPD_SERVICE" 2>/dev/null || true
$SYSTEMCTL enable "$NTPD_SERVICE"
$SYSTEMCTL restart "$NTPD_SERVICE"
$SLEEP 10

apply_iptables_rules
neutralize_and_purge_conflicts

log "Initial health check..."
if is_ntpd_rs_healthy; then
    log "$NTPD_SERVICE is healthy!"
    $ECHO "$($DATE +%s)" > "$LAST_HEALTH_CHECK"
    manage_restart_counter "reset"
else
    log "$NTPD_SERVICE started but verification is pending (stratum may be 16 initially)."
fi

log "=== Status ==="
if command -v ntp-ctl &>/dev/null; then
    ntp-ctl -c "$NTPD_CONFIG" status || log "Unable to fetch status"
else
    log "ntp-ctl not available"
fi
log "LAN interfaces: $LAN_INTERFACES"
log "Binding IPs: $LAN_IPS"
log "=========================================="

exit 0
