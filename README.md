Firewalla NTS: Encrypted Time & Transparent Intercept Using ntpd-rs
===================================================================

Secure your network time with authenticated **NTS (Network Time Security)** via **ntpd-rs** and force all devices on your LAN to use it via Firewalla's NTP Intercept feature **without sacrificing security or stability**.

* * *

BIG DISCLAIMER (READ THIS FIRST)
--------------------------------

> **I AM NOT AFFILIATED WITH FIREWALLA.** This is a **community contribution** and is **NOT supported** by Firewalla.
> 
> **USE AT YOUR OWN RISK.** Modifying your router always carries risks. I am not responsible if your device malfunctions. Know how to **reflash** your Firewalla and have a recovery drive ready **before** proceeding.
> 
> **NEVER RUN `APT UPGRADE`.** This script only installs `ntpd-rs` from its official pre-built binary; it does **not** upgrade system packages. Firewalla uses a custom Ubuntu OS; upgrading generic Ubuntu packages will probably **destabilize or brick** your box. The script uses Firewalla's safe `apt-get.sh` wrapper where possible and installs ntpd-rs in a contained manner.
> 
> **TESTED ON FIREWALLA GOLD PLUS** running **Ubuntu 22.04** (fresh image from Firewalla). It should work on other modern models, but is **not guaranteed** on older OS versions (18.04, 20.04).
> 
> **PLEASE READ THIS ENTIRE README** to understand what you're getting into **and how to revert** if needed.
> 
> **NTP INTERCEPT STILL APPLIES.** Clients on your LAN behind NTP intercept must still use **plain NTP** (not NTS) because Firewalla only intercepts NTP. If you have devices with NTS-capable clients (like newer `systemd-timesyncd` or Chrony) behind NTP intercept on your LAN, they will fail to sync unless you either:
> 
> *   Reconfigure them to use plain NTP, **or**
> *   Turn off NTP Intercept for that network (so their NTS requests reach the internet/WAN directly).
> 
> **Important:** Because this script applies its own firewall rules (`iptables`) at every boot, the **"NTP Intercept" slider in the Firewalla App may no longer reflect reality**. Even if you turn the slider **OFF**, the script will re-enable interception on reboot and network changes by design to keep your network secure and transparently intercepted.

* * *

Why Replace the Default NTP?
----------------------------

Default NTP sends time data in **unencrypted plain text**. Anyone on the path -- hacker, ISP, government -- can inspect or spoof your time requests (Man-in-the-Middle).

This project replaces the default time service with **ntpd-rs**, configured to use **NTS (Network Time Security)**.

### The Benefits

*   **Encryption & Authentication** -- ntpd-rs uses **TLS** to verify the time server's identity and ensure the time has not been altered.
*   **The "Force Field" (Intercept)** -- Many IoT devices have hardcoded, insecure NTP servers. This script transparently intercepts **all** NTP traffic on your LAN and redirects it to your secure ntpd-rs instance -- devices never know.
*   **Robustness** -- The script runs from Firewalla's `post_main.d` hook directory, which automatically executes after every boot and network change. It self-heals: checks health, re-applies iptables rules, and restarts the daemon if needed.

* * *

Installation
------------

Place the script in Firewalla's `post_main.d` hook directory. This is the native way Firewalla runs custom scripts after boot and network changes.

    sudo mkdir -p /home/pi/.firewalla/config/post_main.d
    cd /home/pi/.firewalla/config/post_main.d
    sudo wget https://raw.githubusercontent.com/upmcplanetracker/ntpd-rs-nts-for-firewalla/main/install_and_enforce_ntpd-rs.sh
    sudo chmod +x ./install_and_enforce_ntpd-rs.sh

    sudo wget -O /etc/ntpd-rs.env https://raw.githubusercontent.com/upmcplanetracker/ntpd-rs-nts-for-firewalla/main/ntpd-rs.env

    sudo ./install_and_enforce_ntpd-rs.sh

The **`/etc/ntpd-rs.env`** file holds the editable NTS server list and observation socket path -- see [Configuration](#configuration-etcntpd-rsenv) below. The script will refuse to run if this file is missing, so grab it **before** running the installer.

The script will:

*   **Auto discover** all your LAN interfaces (bridges and physical, excluding WAN structures like `wan`, `ppp`, `tun`, `wg`, `vpn`).
*   **Auto detect** the precise LAN IPs and configure them in `/etc/ntpd-rs/ntp.toml`.
*   **Install** `ntpd-rs` using the official pre-built `.deb` binary.
*   **Mask & Lock** competing NTP services (including `chrony`, `ntp`, `ntpdate`, `systemd-timesyncd`) via custom apt preferences to completely avoid package conflicts.
*   **Append** NTS server IPs to `/etc/hosts` (read from `/etc/ntpd-rs.env`) so ntpd-rs can resolve hostnames even when local DNS tracking is lagging during early boot phases.
*   **Apply** iptables and ip6tables redirection rules to route NTP traffic cleanly on all active LAN interfaces.
*   **Use** seven working (as of July 2026) NTS servers, defined in `/etc/ntpd-rs.env`.

* * *

Configuration (`/etc/ntpd-rs.env`)
-----------------------------------

All editable settings -- the NTS server list and the `ntp-ctl` observation socket path -- live in **`/etc/ntpd-rs.env`**, not in the script itself. You never need to open `install_and_enforce_ntpd-rs.sh` to change servers.

    NTPD_RS_NTS_SERVERS=(
      "time.cloudflare.com:162.159.200.1"
      "ntppool1.time.nl:94.198.159.15"
      "ohio.time.system76.com:3.134.129.152"
      "time.cincura.net:85.163.168.227"
      "nts.teambelgium.net:91.177.126.188"
      "time.web-clock.ca:173.206.104.134"
      "brazil.time.system76.com:18.228.202.30"
    )

    NTPD_RS_OBSERVATION_PATH="/run/ntpd-rs/observe"

*   Each server entry is `hostname:ip`. The hostname becomes the NTS source address in `ntp.toml`; the IP is pinned in `/etc/hosts` (see [Hosts File Fix](#hosts-file-fix)) so the handshake doesn't depend on local DNS being ready this early in boot.
*   Add, remove, or edit entries as needed -- at least one server is required, or the script exits with an error.
*   `NTPD_RS_OBSERVATION_PATH` sets the `ntp-ctl` observation socket path (defaults to `/run/ntpd-rs/observe`; only change it if you have a specific reason to).
*   Keep this file root-owned and non-world-writable (`chmod 644` or stricter, `root:root`) since it's sourced directly into a root-running script.

After changing anything in `/etc/ntpd-rs.env`, apply it with:

    sudo /home/pi/.firewalla/config/post_main.d/install_and_enforce_ntpd-rs.sh --update-config

This regenerates the `/etc/hosts` pin block and `/etc/ntpd-rs/ntp.toml` from the file and restarts `ntpd-rs` -- it does **not** touch the installed package, so it's safe to run as often as you like.

* * *

How to Verify
-------------

### 1\. Check Time Sources & Status

Run:

    ntp-ctl status

Example output from a healthy system with all seven servers:

    Synchronization status:
    \tDispersion:\t0.000137s
    \tDelay:\t\t0.024822s
    \tStratum:\t2
    
    Sources:
    
    brazil.time.system76.com:4460 18.228.202.30:123 [NTS] (7)
    \tOffset:\t\t\t-0.005129
    \tUncertainty:\t\t±0.000341
    \tDelay:\t\t\t±0.131975
    \tPoll interval:\t\t64s
    \tMissing polls:\t\t0
    \tRoot dispersion:\t0.001663s
    \tRoot delay:\t\t0.001083s
    \tNTS cookies:\t\t8/8 available
    
    ntppool1.time.nl:4460 94.198.159.15:123 [NTS] (5)
    \tOffset:\t\t\t-0.000165
    \tUncertainty:\t\t±0.000592
    \tDelay:\t\t\t±0.108101
    \tPoll interval:\t\t64s
    \tMissing polls:\t\t0
    \tRoot dispersion:\t0.000015s
    \tRoot delay:\t\t0.000015s
    \tNTS cookies:\t\t8/8 available
    
    nts.teambelgium.net:4460 91.177.126.188:123 [NTS] (4)
    \tOffset:\t\t\t-0.001769
    \tUncertainty:\t\t±0.000466
    \tDelay:\t\t\t±0.101369
    \tPoll interval:\t\t64s
    \tMissing polls:\t\t0
    \tRoot dispersion:\t0.000015s
    \tRoot delay:\t\t0.000015s
    \tNTS cookies:\t\t8/8 available
    
    ohio.time.system76.com:4460 3.134.129.152:123 [NTS] (2)
    \tOffset:\t\t\t+0.003098
    \tUncertainty:\t\t±0.000406
    \tDelay:\t\t\t±0.029935
    \tPoll interval:\t\t64s
    \tMissing polls:\t\t0
    \tRoot dispersion:\t0.002136s
    \tRoot delay:\t\t0.021332s
    \tNTS cookies:\t\t8/8 available
    
    time.cincura.net:4460 85.163.168.227:123 [NTS] (6)
    \tOffset:\t\t\t+0.000507
    \tUncertainty:\t\t±0.000443
    \tDelay:\t\t\t±0.116651
    \tPoll interval:\t\t64s
    \tMissing polls:\t\t0
    \tRoot dispersion:\t0.000031s
    \tRoot delay:\t\t0.000015s
    \tNTS cookies:\t\t8/8 available
    
    time.cloudflare.com:4460 162.159.200.1:123 [NTS] (1)
    \tOffset:\t\t\t+0.001761
    \tUncertainty:\t\t±0.000346
    \tDelay:\t\t\t±0.011394
    \tPoll interval:\t\t64s
    \tMissing polls:\t\t0
    \tRoot dispersion:\t0.000610s
    \tRoot delay:\t\t0.013428s
    \tNTS cookies:\t\t8/8 available
    
    time.web-clock.ca:4460 173.206.104.134:123 [NTS] (3)
    \tOffset:\t\t\t+0.000342
    \tUncertainty:\t\t±0.000188
    \tDelay:\t\t\t±0.035697
    \tPoll interval:\t\t32s
    \tMissing polls:\t\t0
    \tRoot dispersion:\t0.000031s
    \tRoot delay:\t\t0.000015s
    \tNTS cookies:\t\t8/8 available
    
    Servers:
    
    192.168.1.1:123
    \tIgnored\t\t\t0
    \tResponse send errors\t0
    \tNTS NAK\t\t\t0
    \tReceived\t\t311
    \tAccepted\t\t311
    \tDenied\t\t\t0
    \tRate limited\t\t0
    \tNTS Received\t\t0
    \tNTS Accepted\t\t0
    \tNTS Denied\t\t0
    \tNTS Rate limited\t0
    

Look for:

*   **Offset** -- how far your clock drifts (in seconds).
*   **Uncertainty** -- the estimated error margin.
*   **Missing polls** -- if a server isn't responding, this number climbs.
*   **NTS cookies** -- active encrypted sessions; `8/8 available` means the server is fully encrypted and reachable.

### 2\. Verify NTS Encryption

Look at the **NTS cookies** line for each source. A value of `8/8 available` indicates NTS is fully active. Even if cookies are lower but still present, encryption is working; the daemon manages the pool automatically.

You can also check the journal:

    sudo journalctl -u ntpd-rs --no-pager | grep -i "nts\\|new source"

Successful connections show `new source` messages. Warnings like `error while attempting key exchange ... TimedOut` indicate a temporary handshake failure that the daemon will retry.

### 3\. Validate Configuration

    ntp-ctl validate

If the syntax is correct, you'll see `Config looks good`.

### 4\. Confirm Firewall Rules

    sudo iptables -t nat -L PREROUTING -v -n

You should see an explicit `REDIRECT` rule for port 123 matching your LAN interfaces and actively capturing packets.

* * *

Understanding `ntp-ctl status` Output
-------------------------------------

The output is split into two main parts: **Synchronization status** (your clock's overall health) and **Sources** (each upstream server).

### Synchronization Status

*   **Dispersion** -- How "spread out" the time measurements are. Lower is better; a few microseconds is excellent.
*   **Delay** -- Round-trip network delay to the selected source. A few tens of milliseconds is typical for an internet connection.
*   **Stratum** -- Distance from a reference clock (atomic clock, GPS). Stratum 2 means you are two steps away, which is perfect for a home router.

### Source Metrics

| Metric | Meaning |
|--------|---------|
| **Offset** | Difference between your clock and the server's clock. Small values (<1 ms) are good. |
| **Uncertainty** | The daemon's confidence interval. Smaller is better. |
| **Delay** | Measured network delay to that server. |
| **Poll interval** | How often the daemon queries the server (in seconds). It adapts automatically. |
| **Missing polls** | How many expected responses never arrived. A healthy server should show 0. |
| **Root dispersion / delay** | Cumulative error from the server to the reference clock. Small values indicate a well-synchronised server. |
| **NTS cookies** | Number of pre-shared keys available for NTS. 8/8 = fully encrypted. Fewer cookies still mean NTS is active, but may require re-keying. |

### Server Statistics (Local)

The `Servers:` block shows your local NTP server statistics -- i.e. how many client requests your Firewalla has handled.

*   **Received / Accepted** -- Total NTP requests received and successfully answered. They should be equal under normal conditions.
*   **Ignored / Denied / Rate limited** -- Requests dropped due to configuration, rate limits, or access rules. Zero is healthy.
*   **NTS NAK** -- Number of NTS key exchange failures (should stay 0).
*   **NTS Received / Accepted** -- If you had NTS clients connecting directly, these would show activity. In an intercept-only setup they remain 0.

* * *

Troubleshooting FAQ
-------------------

### Q: One of my servers shows many missing polls or low NTS cookies. What does that mean?

Missing polls and a drop in available cookies (e.g. `5/8` instead of `8/8`) usually indicate that the server is temporarily unreachable or the NTS key exchange is struggling. The daemon will keep retrying. If the problem persists, check DNS and network reachability.

**Example of a struggling server** (from a previous test configuration -- _not_ part of the default seven servers anymore):

    ptbtime1.ptb.de:4460 192.53.103.108:123 [NTS] (52)
    \tOffset:\t\t\t+0.000000
    \tUncertainty:\t\t±2147483648.500000
    \tDelay:\t\t\t±2147483648.500000
    \tPoll interval:\t\t16s
    \tMissing polls:\t\t8
    \tNTS cookies:\t\t5/8 available
    

Here the server shows huge uncertainty, 8 missing polls, and only 5 cookies -- it is essentially unusable. The clock remains accurate because the other servers are fully functional.

### Q: What if a server doesn't appear in the list at all?

If a configured server never responds, ntpd-rs may simply not show it in the output (or list it with extremely high missing polls). That's fine -- the daemon will ignore it and rely on the healthy ones. Check the journal for `could not resolve` or `error while attempting key exchange` to see why it failed.

### Q: All servers show high missing polls or no NTS cookies. What's wrong?

This usually means ntpd-rs cannot resolve hostnames (DNS blocked) or cannot reach the internet on port 123/4460 (NTS). Steps:

1.  Check that ntpd-rs is running: `sudo systemctl status ntpd-rs`
2.  Look at the daemon log: `sudo journalctl -u ntpd-rs --no-pager | tail -40`
3.  Ensure the script added correct IPs to `/etc/hosts`: `cat /etc/hosts | grep -E 'time.cloudflare|ntppool1|time.nl|cincura|teambelgium|web-clock|system76'`
4.  Verify WAN outbound rules -- temporarily disable any NTP-related app rules to test.

### Q: How do I know if NTS encryption is actually working?

In the `ntp-ctl status` output, each source shows an **NTS cookies** line. `8/8 available` confirms active NTS. You can also grep the journal for `new source` messages. If you see `error while attempting key exchange`, that particular connection failed -- but others likely still work.

### Q: I changed the server list, but the new servers don't work.

*   Did you edit `/etc/ntpd-rs.env` (not the script)? That's the only place the server list lives now -- see [Configuration](#configuration-etcntpd-rsenv).
*   Did you use the `hostname:ip` format for each entry?
*   After editing, apply the change: `sudo /home/pi/.firewalla/config/post_main.d/install_and_enforce_ntpd-rs.sh --update-config`
*   Verify the server actually supports NTS. Check the community list at [https://github.com/jauderho/nts-servers](https://github.com/jauderho/nts-servers).

### Q: The "NTP Intercept" slider in the Firewalla app shows OFF, but clients still can't use their own NTP servers.

That's expected. The script enforces interception independently via `iptables` rules at every boot and network change. The app slider only controls Firewalla's built-in intercept, not the custom rules. To truly disable interception, you must uninstall the script (see [Uninstall](#uninstall--revert-to-stock)).

### Q: How can I temporarily disable interception for testing?

    sudo iptables -t nat -F PREROUTING

The rules will be automatically re-applied on the next `post_main.d` run (reboot or network change).

* * *

What About Updates & Boot Persistence?
--------------------------------------

The script lives in **/home/pi/.firewalla/config/post_main.d/**, which is Firewalla's native hook directory for scripts that need to run after boot and after any network change. This is more robust than cron or custom systemd services because:

*   It runs **after** Firewalla's main services are fully up (network is guaranteed).
*   It re-runs automatically when interfaces change (VPN up/down, bridge reconfig, etc.).
*   It is **native to Firewalla** -- no custom systemd units to maintain.
*   It **self-heals** on every invocation: checks daemon health, re-applies iptables rules, and restarts if needed.

There is no separate cron job or boot service. The script handles everything on its own schedule via the `post_main.d` mechanism.

* * *

Technical Details & Caveats
---------------------------

### Competing Services Neutralization

The script stops and masks `chrony`, `ntp`, `ntpdate`, `systemd-timesyncd`, and any old ntpd-rs instances. It also places an apt preferences pin to block those packages from being reinstalled by future updates.

### Hosts File Fix

Firewalla's sandbox may block the unprivileged `ntp` user from accessing local DNS early in boot. To bypass this, the script inserts a marked block in `/etc/hosts`, generated from the server list in `/etc/ntpd-rs.env`:

    # BEGIN NTPD-RS HOSTS
    162.159.200.1    time.cloudflare.com
    94.198.159.15    ntppool1.time.nl
    3.134.129.152    ohio.time.system76.com
    85.163.168.227   time.cincura.net
    91.177.126.188   nts.teambelgium.net
    173.206.104.134  time.web-clock.ca
    18.228.202.30    brazil.time.system76.com
    # END NTPD-RS HOSTS
    

### Why 7 Servers?

The NTP community often recommends at least **four to five** NTS servers for robust time keeping. However, many public NTS servers are run by individuals or small groups and can be less reliable than traditional NTP servers. After testing, we found **seven** servers that were consistently reachable and delivered correct time. We included all seven in the default configuration, but you are free to trim the list to five (or even fewer) by editing `/etc/ntpd-rs.env` and running `--update-config`. The chosen servers are:

*   **Cloudflare** -- Global anycast, highly reliable.
*   **TimeNL** -- European government-backed stability.
*   **System76** (Ohio & Brazil) -- US and South American redundancy.
*   **Cincura.net, TeamBelgium, Web-Clock.ca** -- Community-maintained, geographically diverse.

**Limitation:** If any of these IPs change (rare), you'll need to update them in `/etc/ntpd-rs.env` and re-run with `--update-config`.

### Auto Detection of Interfaces & IPs

The script automatically discovers your LAN bridges and physical interfaces, extracts their IPv4 addresses, and writes corresponding `[[server]]` stanzas into `ntp.toml`. No manual subnet configuration is needed.

### Customizing Your Time Servers

To add or remove servers, edit **`/etc/ntpd-rs.env`** (see [Configuration](#configuration-etcntpd-rsenv) above) -- not the script -- then run:

    sudo /home/pi/.firewalla/config/post_main.d/install_and_enforce_ntpd-rs.sh --update-config

This regenerates the `/etc/hosts` block and `ntp.toml` from `/etc/ntpd-rs.env` and restarts ntpd-rs in seconds. It does not re-download or reinstall the `ntpd-rs` package.

* * *

Uninstall / Revert to Stock
---------------------------

To remove ntpd-rs and restore Firewalla's default time configuration, run the following as root:

    # Stop and disable any running ntpd-rs service
    sudo systemctl stop ntpd-rs ntpd-rsd 2>/dev/null
    sudo systemctl disable ntpd-rs ntpd-rsd 2>/dev/null
    
    # Purge the package
    sudo /home/pi/firewalla/scripts/apt-get.sh purge -y ntpd-rs
    
    # Remove apt preferences
    sudo rm -f /etc/apt/preferences.d/block-ntp
    
    # Remove /etc/hosts block
    sudo sed -i '/# BEGIN NTPD-RS HOSTS/,/# END NTPD-RS HOSTS/d' /etc/hosts
    
    # Delete all remaining files and directories
    sudo rm -f /etc/ntpd-rs-url.conf \
              /etc/ntpd-rs-interface.conf \
              /etc/ntpd-rs.env \
              /var/lib/ntpd-rs/restart_counter \
              /var/lib/ntpd-rs/last_health \
              /log/ntpd-rs-installer.log
    sudo rm -rf /etc/ntpd-rs
    sudo systemctl daemon-reload
    
    # Delete the installer script from post_main.d
    sudo rm -f /home/pi/.firewalla/config/post_main.d/install_and_enforce_ntpd-rs.sh
    
    # Restore systemd-timesyncd
    sudo /home/pi/firewalla/scripts/apt-get.sh install systemd-timesyncd && \
    sudo systemctl unmask systemd-timesyncd && \
    sudo systemctl enable systemd-timesyncd && \
    sudo systemctl start systemd-timesyncd
    
    # Reboot
    sudo reboot
    

A full reboot is required to drop the iptables redirects and return time management entirely to Firewalla's mobile app.

Note: this removes `/etc/ntpd-rs.env` along with everything else. If you've customized your server list and might reinstall later, back that file up first: `sudo cp /etc/ntpd-rs.env ~/ntpd-rs.env.bak`.

* * *

Final Notes
-----------

*   The script is designed to be low-risk and completely revertible. It leaves no orphaned configuration and tracks its own health metrics.
*   The `post_main.d` hook ensures the script runs after every boot and network change, keeping your NTP interception and NTS encryption always active.

