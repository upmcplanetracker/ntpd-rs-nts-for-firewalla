# =============================================================================
# ntpd-rs NTS Configuration — EDIT THIS FILE, not the installer script.
#
# After changing anything below, apply it with:
#   sudo ntpd-rs-installer.sh --update-config
#
# This file should stay root-owned, root-writable only (chmod 600 or 644
# with root:root ownership) since its contents are sourced directly into
# a root-running script.
#
# This regenerates /etc/hosts (the pinned IP block) and /etc/ntpd-rs/ntp.toml
# from what's defined here, then restarts the ntpd-rs service. It does NOT
# re-download or reinstall the ntpd-rs package.
# =============================================================================

# -----------------------------------------------------------------------------
# NTS time servers
#
# One entry per server, format:  "hostname:ip_address"
#
#   hostname   -> used as the NTS source address in ntp.toml, and as the
#                 hostname side of the /etc/hosts pin.
#   ip_address -> used as the IP side of the /etc/hosts pin, so the NTS
#                 handshake connects to a known-good IP instead of depending
#                 on the box's own DNS resolver.
#
# To add a server: add a new "hostname:ip" line inside the parentheses.
# To remove a server: delete its line.
# To change a server's IP (e.g. it moved): edit the ip_address part.
# Keep at least one entry — the array cannot be empty.
# -----------------------------------------------------------------------------
NTPD_RS_NTS_SERVERS=(
  "time.cloudflare.com:162.159.200.1"
  "ntppool1.time.nl:94.198.159.15"
  "ohio.time.system76.com:3.134.129.152"
  "time.cincura.net:85.163.168.227"
  "nts.teambelgium.net:91.177.126.188"
  "time.web-clock.ca:173.206.104.134"
  "brazil.time.system76.com:18.228.202.30"
)

# -----------------------------------------------------------------------------
# Observability socket path (ntpd-rs >= 1.9.0)
#
# Used by `ntp-ctl` to query daemon status. Only change this if you have a
# specific reason to move the socket.
# -----------------------------------------------------------------------------
NTPD_RS_OBSERVATION_PATH="/run/ntpd-rs/observe"
