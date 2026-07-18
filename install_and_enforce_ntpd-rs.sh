#!/bin/bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

# ─────────────────── TRAP / CLEANUP ──────────────────────
cleanup() {
    local exit_code=$?
    rm -f "${DEB_FILE}.tmp.$$" 2>/dev/null || true
    if [ ${exit_code} -ne 0 ]; then
        log "Script exited with error code ${exit_code}."
    fi
}
trap cleanup EXIT INT TERM

SCRIPT_PATH="$(realpath "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
URL_CONFIG="/etc/ntpd-rs-url.conf"
ENV_FILE="/etc/ntpd-rs.env"

# Firewalla post-main hook directory
POST_MAIN_DIR="/home/pi/.firewalla/config/post_main.d"

DEB_URL=""
UPDATE_CONFIG=0

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            echo "Usage: sudo ${SCRIPT_PATH} [--update-config] <url-to-ntpd-rs-deb-package>"
            echo "   or if URL is already saved: sudo ${SCRIPT_PATH}"
            echo "   --update-config   Regenerate /etc/hosts and ntp.toml only, then restart service."
            echo "   --rollback        Restore chrony as the NTP service (emergency recovery)."
            echo ""
            echo "NTS server list and observation socket path are read from ${ENV_FILE}."
            echo "Edit that file, then run --update-config to apply changes."
            echo ""
            echo "Place this script in ${POST_MAIN_DIR} for automatic enforcement"
            echo "on boot and after network changes."
            exit 0
            ;;
        --update-config)
            UPDATE_CONFIG=1
            ;;
        --rollback)
            rollback
            ;;
        *)
            if [ -z "$DEB_URL" ]; then DEB_URL="$arg"; fi
            ;;
    esac
done

if [ -z "$DEB_URL" ] && [ "$UPDATE_CONFIG" -eq 0 ]; then
    if [ -f "$URL_CONFIG" ]; then
        DEB_URL=$(head -n1 "$URL_CONFIG")
    else
        echo "Error: No package URL provided and $URL_CONFIG not found." >&2
        echo "Usage: sudo ${SCRIPT_PATH} [--update-config] <url-to-ntpd-rs-deb-package>" >&2
        exit 1
    fi
fi

if [ "$UPDATE_CONFIG" -eq 0 ] && [ -n "$DEB_URL" ]; then
    echo "$DEB_URL" > "$URL_CONFIG"
fi

CONFIG_FILE="/etc/ntpd-rs-interface.conf"
HEALTH_CHECK_INTERVAL=300
MAX_RESTARTS=3
RESTART_COUNTER_FILE="/var/lib/ntpd-rs/restart_counter"
LAST_HEALTH_CHECK="/var/lib/ntpd-rs/last_health"
DEB_FILE="/log/ntpd-rs_latest.deb"
LOG_FILE="/log/ntpd-rs-installer.log"
NTPD_CONFIG="/etc/ntpd-rs/ntp.toml"

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

unalias -a 2>/dev/null || true
mkdir -p /log /var/lib/ntpd-rs

# ─────────────────── DETECT INVOCATION CONTEXT ──────────────────────
# post_main.d scripts run after Firewalla's main services come up.
# Detect if we're being run from the hook directory.
FROM_HOOK=0
if [[ "$SCRIPT_PATH" == *"post_main.d"* ]]; then
    FROM_HOOK=1
fi

log() {
    local msg="[$($DATE '+%Y-%m-%d %H:%M:%S')] $1"
    $ECHO "$msg" | tee -a "$LOG_FILE"
}

# ─────────────────── ROLLBACK ──────────────────────
rollback() {
    log "===== ROLLBACK MODE ====="
    log "Restoring chrony as the active NTP service..."

    local ntpd_svc
    ntpd_svc=$(find_ntpd_service_name 2>/dev/null || echo "ntpd-rs")
    $SYSTEMCTL stop "${ntpd_svc}.service" 2>/dev/null || true
    $SYSTEMCTL disable "${ntpd_svc}.service" 2>/dev/null || true
    $SYSTEMCTL mask "${ntpd_svc}.service" 2>/dev/null || true

    # Remove iptables redirects
    local interfaces
    interfaces=$(get_lan_interfaces 2>/dev/null || true)
    for iface in $interfaces; do
        $IPTABLES -t nat -D PREROUTING -i "$iface" -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
        $IP6TABLES -t nat -D PREROUTING -i "$iface" -p udp --dport 123 -j REDIRECT --to-port 123 2>/dev/null || true
    done

    # Unmask and enable chrony
    $SYSTEMCTL unmask chrony.service 2>/dev/null || true
    $SYSTEMCTL unmask chronyd.service 2>/dev/null || true
    $SYSTEMCTL enable chrony.service 2>/dev/null || true
    $SYSTEMCTL start chrony.service 2>/dev/null || true

    # Remove hosts block
    $SED -i '/# BEGIN NTPD-RS HOSTS/,/# END NTPD-RS HOSTS/d' /etc/hosts 2>/dev/null || true

    log "Rollback complete. Chrony should now be active."
    log "Run 'systemctl status chrony' to verify."
    exit 0
}

# ─────────────────── ENV FILE ──────────────────────
load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        log "ERROR: $ENV_FILE not found."
        echo "Error: $ENV_FILE not found." >&2
        exit 1
    fi

    local file_owner file_perms
    file_owner=$(stat -c '%u' "$ENV_FILE" 2>/dev/null || echo "")
    file_perms=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "")

    if [ "$file_owner" != "0" ]; then
        log "ERROR: $ENV_FILE is not owned by root. Refusing to source."
        echo "Error: $ENV_FILE is not owned by root." >&2
        exit 1
    fi

    if [ "$file_perms" != "600" ] && [ "$file_perms" != "644" ] && [ "$file_perms" != "640" ]; then
        log "WARNING: $ENV_FILE has permissions $file_perms (expected 600, 640, or 644)."
    fi

    # shellcheck source=/etc/ntpd-rs.env
    source "$ENV_FILE"

    if ! declare -p NTPD_RS_NTS_SERVERS &>/dev/null; then
        log "ERROR: NTPD_RS_NTS_SERVERS is not defined in $ENV_FILE."
        echo "Error: NTPD_RS_NTS_SERVERS is not defined in $ENV_FILE." >&2
        exit 1
    fi

    if [ "${#NTPD_RS_NTS_SERVERS[@]}" -eq 0 ]; then
        log "ERROR: NTPD_RS_NTS_SERVERS in $ENV_FILE is empty."
        echo "Error: NTPD_RS_NTS_SERVERS in $ENV_FILE is empty." >&2
        exit 1
    fi

    for entry in "${NTPD_RS_NTS_SERVERS[@]}"; do
        if [[ "$entry" != *:* ]]; then
            log "ERROR: Malformed entry in NTPD_RS_NTS_SERVERS: '$entry' (expected hostname:ip)."
            echo "Error: Malformed entry: '$entry'" >&2
            exit 1
        fi
    done

    : "${NTPD_RS_OBSERVATION_PATH:=/run/ntpd-rs/observe}"
}

generate_hosts_block() {
    $ECHO "# BEGIN NTPD-RS HOSTS"
    for entry in "${NTPD_RS_NTS_SERVERS[@]}"; do
        local hostname="${entry%%:*}"
        local ip="${entry#*:}"
        printf '%-16s %s\n' "$ip" "$hostname"
    done
    $ECHO "# END NTPD-RS HOSTS"
}

generate_ntp_sources() {
    for entry in "${NTPD_RS_NTS_SERVERS[@]}"; do
        local hostname="${entry%%:*}"
        $ECHO "[[source]]"
        $ECHO "mode = \"nts\""
        $ECHO "address = \"${hostname}\""
        $ECHO ""
    done
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
    if [ -z "$interfaces" ]; then
        log "ERROR: No LAN interfaces detected. Cannot configure ntpd-rs."
        echo "Error: No LAN interfaces detected." >&2
        exit 1
    fi
    $ECHO "$interfaces" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

get_lan_ips() {
    local interfaces
    interfaces=$(get_lan_interfaces)
    for iface in $interfaces; do
        $IP -4 addr show "$iface" | $GREP 'inet ' | while read -r line; do
            local cidr ip
            cidr=$(echo "$line" | awk '{print $2}')
            ip=$(echo "$cidr" | cut -d'/' -f1)
            if [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^10\. ]] || \
               [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
               [[ "$ip" =~ ^169\.254\. ]]; then
                echo "$ip"
            fi
        done
    done | sort -u | tr '\n' ' '
}

apply_iptables_rules() {
    local interfaces
    interfaces=$(get_lan_interfaces)
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
    local ntp_ctl_bin
    ntp_ctl_bin=$(command -v ntp-ctl 2>/dev/null || true)

    if [ -z "$ntp_ctl_bin" ]; then
        ntp_ctl_bin=$(dpkg -L ntpd-rs 2>/dev/null | $GREP 'bin/ntp-ctl$' | head -n1 || true)
    fi

    if [ -z "$ntp_ctl_bin" ] || [ ! -x "$ntp_ctl_bin" ]; then
        log "WARNING: ntp-ctl not found. Skipping stratum health check."
        return 0
    fi

    local config_flag="-c"
    if "$ntp_ctl_bin" --help 2>&1 | $GREP -q -- '--config'; then
        config_flag="--config"
    fi

    if command -v jq &>/dev/null; then
        local status_json
        status_json=$("$ntp_ctl_bin" "$config_flag" "$NTPD_CONFIG" -j status 2>/dev/null || true)
        if [ -n "$status_json" ]; then
            stratum=$(echo "$status_json" | jq -r '.stratum // empty' 2>/dev/null)
        fi
    fi

    if [ -z "$stratum" ]; then
        stratum=$("$ntp_ctl_bin" "$config_flag" "$NTPD_CONFIG" status 2>/dev/null | awk '/Stratum:/{print $2}')
    fi

    if [ -n "$stratum" ] && [ "$stratum" -lt 16 ] 2>/dev/null; then
        return 0
    fi

    return 1
}

should_check_health() {
    [ ! -f "$LAST_HEALTH_CHECK" ] && return 0
    local last_check current_time
    last_check=$($CAT "$LAST_HEALTH_CHECK")
    current_time=$($DATE +%s)
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
    $CAT > /etc/apt/preferences.d/block-ntp <<'EOF'
Package: ntp ntpdate systemd-timesyncd chrony ntpsec
Pin: origin *
Pin-Priority: -1
EOF

    for svc in ntp ntpdate systemd-timesyncd ntp-systemd-netif chrony chronyd ntpsec; do
        $SYSTEMCTL stop "${svc}.service" 2>/dev/null || true
        $SYSTEMCTL disable "${svc}.service" 2>/dev/null || true
        $SYSTEMCTL mask "${svc}.service" 2>/dev/null || true
    done

    local CONFLICTING_DAEMONS=("chrony" "ntpsec" "ntp" "ntpdate")
    for daemon in "${CONFLICTING_DAEMONS[@]}"; do
        local STATE
        STATE=$(dpkg-query -W -f='${Status}' "$daemon" 2>/dev/null || echo "")
        if [[ "$STATE" == "install ok installed" ]] || [[ "$STATE" == *"config-files"* ]] || [[ "$STATE" == *"deinstall"* ]]; then
            log "Purging $daemon..."
            $APT_GET_WRAPPER purge -y "$daemon" 2>/dev/null || apt-get purge -y "$daemon" 2>/dev/null || true
        fi
    done
}

find_ntpd_service_name() {
    if $SYSTEMCTL cat ntpd-rsd.service &>/dev/null; then
        echo "ntpd-rsd"
    elif $SYSTEMCTL cat ntpd-rs.service &>/dev/null; then
        echo "ntpd-rs"
    else
        echo "ntpd-rs"
    fi
}

# ─────────────────── DOWNLOAD HELPER ──────────────────────
download_file() {
    local url="$1" dest="$2"
    if command -v wget &>/dev/null; then
        wget -q -O "$dest" "$url"
    elif command -v curl &>/dev/null; then
        curl -fsSL -o "$dest" "$url"
    else
        log "ERROR: Neither wget nor curl is available."
        echo "Error: Neither wget nor curl is available." >&2
        exit 1
    fi
}

# ─────────────────── URL VALIDATION ──────────────────────
validate_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?:// ]]; then
        log "ERROR: URL must start with http:// or https://"
        echo "Error: Invalid URL scheme." >&2
        exit 1
    fi
}

log "===== NTPD-RS enforcement script started ====="
log "Invocation: SCRIPT_PATH=${SCRIPT_PATH}, FROM_HOOK=${FROM_HOOK}"

load_env

# ─────────────────── FAST UPDATE MODE ──────────────────────
if [ "$UPDATE_CONFIG" -eq 1 ]; then
    log "Update-config mode: regenerating /etc/hosts and ntp.toml, then restarting service."

    LAN_INTERFACES=$(get_lan_interfaces)
    LAN_IPS=$(get_lan_ips)
    log "Detected binding IPs: $LAN_IPS"

    NTPD_SERVICE=$(find_ntpd_service_name)

    $SED -i '/# BEGIN NTPD-RS HOSTS/,/# END NTPD-RS HOSTS/d' /etc/hosts 2>/dev/null || true
    generate_hosts_block >> /etc/hosts

    mkdir -p /etc/ntpd-rs
    {
        $ECHO "# ntpd-rs NTS Configuration for Firewalla"
        $ECHO "# Generated on $($DATE)"
        $ECHO ""
        generate_ntp_sources
        $ECHO "# Listen on all discovered LAN IPs"
        for ip in $LAN_IPS; do
            $ECHO "[[server]]"
            $ECHO "listen = \"$ip:123\""
            $ECHO ""
        done
        $ECHO "# Observability socket for ntp-ctl (ntpd-rs >= 1.9.0)"
        $ECHO "[observability]"
        $ECHO "observation-path = \"$NTPD_RS_OBSERVATION_PATH\""
    } > "$NTPD_CONFIG"
    chmod 644 "$NTPD_CONFIG"

    mkdir -p /run/ntpd-rs

    $SYSTEMCTL restart "$NTPD_SERVICE"

    log "Configuration updated and $NTPD_SERVICE restarted."
    exit 0
fi

# ─────────────────── NORMAL MODE ──────────────────────

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

# When running from the hook, network is already up — no need to wait.
# When running interactively, still wait briefly.
if [ "$FROM_HOOK" -eq 0 ]; then
    log "Waiting 10s for system settle (interactive mode)..."
    $SLEEP 10
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
            mkdir -p /run/ntpd-rs
            $SYSTEMCTL restart "$NTPD_SERVICE"
            $SLEEP 10
            if is_ntpd_rs_healthy; then
                log "$NTPD_SERVICE recovered."
                manage_restart_counter "reset"
            else
                log "ERROR: $NTPD_SERVICE still unhealthy."
                local rc
                rc=$(manage_restart_counter "get")
                if [ "$rc" -ge "$MAX_RESTARTS" ]; then
                    log "CRITICAL: $NTPD_SERVICE repeatedly failing – manual intervention needed."
                else
                    manage_restart_counter "increment"
                fi
            fi
        else
            log "Health check passed."
            manage_restart_counter "reset"
        fi
    fi
    exit 0
fi

# Internet check: skip when running from hook (network is already up),
# but keep it for interactive first-time installs
if [ "$FROM_HOOK" -eq 0 ]; then
    log "Checking internet connectivity..."
    INTERNET_UP=0
    for i in $(seq 1 30); do
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            log "Internet is UP."
            INTERNET_UP=1
            break
        fi
        log "Still waiting... ($i/30)"
        $SLEEP 2
    done
    if [ "$INTERNET_UP" -eq 0 ]; then
        log "ERROR: No internet—cannot download package. Exiting."
        exit 1
    fi
fi

neutralize_and_purge_conflicts

validate_url "$DEB_URL"

log "Downloading ntpd-rs from: ${DEB_URL}"
TMP_DEB="${DEB_FILE}.tmp.$$"
if ! download_file "$DEB_URL" "$TMP_DEB"; then
    log "Error: Download failed."
    rm -f "$TMP_DEB"
    exit 1
fi
mv "$TMP_DEB" "$DEB_FILE"

log "Installing/upgrading ntpd-rs using Firewalla Wrapper..."

for attempt in $(seq 1 3); do
    log "Install attempt $attempt/3..."
    if $APT_GET_WRAPPER -o DPkg::Lock::Timeout=120 install "$DEB_FILE"; then
        log "ntpd-rs package installed."
        break
    fi
    if [ "$attempt" -lt 3 ]; then
        log "Retrying in 10s..."
        $SLEEP 10
    else
        log "ERROR: Failed to install ntpd-rs."
        exit 1
    fi
done

NTPD_SERVICE=$(find_ntpd_service_name)
log "Using systemd unit: ${NTPD_SERVICE}.service"

# ─────────────────── CONFIGURATION ──────────────────────
log "Applying ntpd-rs NTS configuration..."

$SED -i '/# BEGIN NTPD-RS HOSTS/,/# END NTPD-RS HOSTS/d' /etc/hosts 2>/dev/null || true
generate_hosts_block >> /etc/hosts

mkdir -p /etc/ntpd-rs
{
    $ECHO "# ntpd-rs NTS Configuration for Firewalla"
    $ECHO "# Generated on $($DATE)"
    $ECHO ""
    generate_ntp_sources
    $ECHO "# Listen on all discovered LAN IPs"
    for ip in $LAN_IPS; do
        $ECHO "[[server]]"
        $ECHO "listen = \"$ip:123\""
        $ECHO ""
    done
    $ECHO "# Observability socket for ntp-ctl (ntpd-rs >= 1.9.0)"
    $ECHO "[observability]"
    $ECHO "observation-path = \"$NTPD_RS_OBSERVATION_PATH\""
} > "$NTPD_CONFIG"
chmod 644 "$NTPD_CONFIG"

mkdir -p /run/ntpd-rs

# Unit overrides with RuntimeDirectory
mkdir -p /etc/systemd/system/${NTPD_SERVICE}.service.d
$CAT > /etc/systemd/system/${NTPD_SERVICE}.service.d/override.conf <<EOF
[Unit]
Conflicts=chrony.service chronyd.service ntp.service ntpsec.service systemd-timesyncd.service

[Service]
RuntimeDirectory=ntpd-rs
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
NTP_CTL_BIN=$(command -v ntp-ctl 2>/dev/null || dpkg -L ntpd-rs 2>/dev/null | $GREP 'bin/ntp-ctl$' | head -n1 || true)
if [ -n "$NTP_CTL_BIN" ] && [ -x "$NTP_CTL_BIN" ]; then
    CONFIG_FLAG="-c"
    "$NTP_CTL_BIN" --help 2>&1 | $GREP -q -- '--config' && CONFIG_FLAG="--config"
    "$NTP_CTL_BIN" "$CONFIG_FLAG" "$NTPD_CONFIG" status || log "Unable to fetch status"
else
    log "ntp-ctl not available"
fi
log "LAN interfaces: $LAN_INTERFACES"
log "Binding IPs: $LAN_IPS"
log "=========================================="

exit 0
