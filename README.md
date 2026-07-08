Firewalla NTS: Encrypted Time & Transparent Intercept Using ntpd-rs
===================================================================

Secure your network time with authenticated **NTS (Network Time Security)** via **ntpd-rs** and force all devices on your LAN to use it via Firewalla’s NTP Intercept feature **without sacrificing security or stability**.

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
> **PLEASE READ THIS ENTIRE README** to understand what you’re getting into **and how to revert** if needed.
> 
> **NTP INTERCEPT STILL APPLIES.** Clients on your LAN behind NTP intercept must still use **plain NTP** (not NTS) because Firewalla only intercepts NTP. If you have devices with NTS-capable clients (like newer `systemd-timesyncd` or Chrony) behind NTP intercept on your LAN, they will fail to sync unless you either:
> 
> *   Reconfigure them to use plain NTP, **or**
> *   Turn off NTP Intercept for that network (so their NTS requests reach the internet/WAN directly).
> 
> **Important:** Because this script applies its own firewall rules (`iptables`) at every boot, the **"NTP Intercept" slider in the Firewalla App may no longer reflect reality**. Even if you turn the slider **OFF**, the script will re‑enable interception on reboot and cron runs by design to keep your network secure and transparently intercepted.

* * *

Why Replace the Default NTP?
----------------------------

Default NTP sends time data in **unencrypted plain text**. Anyone on the path – hacker, ISP, government – can inspect or spoof your time requests (Man‑in‑the‑Middle).

This project replaces the default time service with **ntpd-rs**, configured to use **NTS (Network Time Security)**.

### The Benefits

*   **Encryption & Authentication** – ntpd-rs uses **TLS** to verify the time server’s identity and ensure the time has not been altered.
*   **The "Force Field" (Intercept)** – Many IoT devices have hardcoded, insecure NTP servers. This script transparently intercepts **all** NTP traffic on your LAN and redirects it to your secure ntpd-rs instance – devices never know.
*   **Robustness** – The script automatically sets up a native systemd tracking service and an automatic daily cron job to ensure rules survive reboots, system updates, and firmware overwrites.

* * *

Installation
------------

To avoid race conditions during early bootup, store the script in a persistent configuration directory. Do not place it directly into `post_main.d`, as the script automatically sets up its own systemd service helper (`ntpd-rs-boot-enforce.service`) to handle execution safely during the boot cycle.

    sudo mkdir -p /home/pi/.firewalla/config/scripts
    cd /home/pi/.firewalla/config/scripts
    sudo wget https://raw.githubusercontent.com/upmcplanetracker/ntpd-rs-nts-for-firewalla/main/install_and_enforce_ntpd-rs.sh
    sudo chmod +x ./install_and_enforce_ntpd-rs.sh
    sudo ./install_and_enforce_ntpd-rs.sh
    

The script will:

*   **Auto-populate Cron:** Automatically checks, cleans, and adds its own execution entry (`0 4 * * * root ...`) to the system crontab (`/etc/crontab`). If the script path changes, running it manually updates the cron mapping automatically.
*   **Auto discover** all your LAN interfaces (bridges and physical, excluding WAN structures like `wan`, `ppp`, `tun`, `wg`, `vpn`).
*   **Auto detect** the precise LAN IPs and configure them in `/etc/ntpd-rs/ntp.toml`.
*   **Install** `ntpd-rs` using the official pre-built `.deb` binary.
*   **Mask & Lock** competing NTP services (including `chrony`, `ntp`, `ntpdate`, `systemd-timesyncd`) via custom apt preferences to completely avoid package conflicts.
*   **Append** NTS server IPs to `/etc/hosts` so ntpd-rs can resolve hostnames even when local DNS tracking is lagging during early boot phases.
*   **Apply** iptables and ip6tables redirection rules to route NTP traffic cleanly on all active LAN interfaces.
*   **Use** seven working (as of July 2026) NTS servers.

* * *

How to Verify
-------------

### 1\. Check Time Sources & Status

Run:

    ntp-ctl status

Example output from a healthy system with all seven servers:

    Synchronization status:
    	Dispersion:	0.000137s
    	Delay:		0.024822s
    	Stratum:	2
    
    Sources:
    
    brazil.time.system76.com:4460 18.228.202.30:123 [NTS] (7)
    	Offset:			-0.005129
    	Uncertainty:		±0.000341
    	Delay:			±0.131975
    	Poll interval:		64s
    	Missing polls:		0
    	Root dispersion:	0.001663s
    	Root delay:		0.001083s
    	NTS cookies:		8/8 available
    
    ntppool1.time.nl:4460 94.198.159.15:123 [NTS] (5)
    	Offset:			-0.000165
    	Uncertainty:		±0.000592
    	Delay:			±0.108101
    	Poll interval:		64s
    	Missing polls:		0
    	Root dispersion:	0.000015s
    	Root delay:		0.000015s
    	NTS cookies:		8/8 available
    
    nts.teambelgium.net:4460 91.177.126.188:123 [NTS] (4)
    	Offset:			-0.001769
    	Uncertainty:		±0.000466
    	Delay:			±0.101369
    	Poll interval:		64s
    	Missing polls:		0
    	Root dispersion:	0.000015s
    	Root delay:		0.000015s
    	NTS cookies:		8/8 available
    
    ohio.time.system76.com:4460 3.134.129.152:123 [NTS] (2)
    	Offset:			+0.003098
    	Uncertainty:		±0.000406
    	Delay:			±0.029935
    	Poll interval:		64s
    	Missing polls:		0
    	Root dispersion:	0.002136s
    	Root delay:		0.021332s
    	NTS cookies:		8/8 available
    
    time.cincura.net:4460 85.163.168.227:123 [NTS] (6)
    	Offset:			+0.000507
    	Uncertainty:		±0.000443
    	Delay:			±0.116651
    	Poll interval:		64s
    	Missing polls:		0
    	Root dispersion:	0.000031s
    	Root delay:		0.000015s
    	NTS cookies:		8/8 available
    
    time.cloudflare.com:4460 162.159.200.1:123 [NTS] (1)
    	Offset:			+0.001761
    	Uncertainty:		±0.000346
    	Delay:			±0.011394
    	Poll interval:		64s
    	Missing polls:		0
    	Root dispersion:	0.000610s
    	Root delay:		0.013428s
    	NTS cookies:		8/8 available
    
    time.web-clock.ca:4460 173.206.104.134:123 [NTS] (3)
    	Offset:			+0.000342
    	Uncertainty:		±0.000188
    	Delay:			±0.035697
    	Poll interval:		32s
    	Missing polls:		0
    	Root dispersion:	0.000031s
    	Root delay:		0.000015s
    	NTS cookies:		8/8 available
    
    Servers:
    
    192.168.1.1:123
    	Ignored			0
    	Response send errors	0
    	NTS NAK			0
    	Received		311
    	Accepted		311
    	Denied			0
    	Rate limited		0
    	NTS Received		0
    	NTS Accepted		0
    	NTS Denied		0
    	NTS Rate limited	0
    

Look for:

*   **Offset** – how far your clock drifts (in seconds).
*   **Uncertainty** – the estimated error margin.
*   **Missing polls** – if a server isn’t responding, this number climbs.
*   **NTS cookies** – active encrypted sessions; `8/8 available` means the server is fully encrypted and reachable.

### 2\. Verify NTS Encryption

Look at the **NTS cookies** line for each source. A value of `8/8 available` indicates NTS is fully active. Even if cookies are lower but still present, encryption is working; the daemon manages the pool automatically.

You can also check the journal:

    sudo journalctl -u ntpd-rs --no-pager | grep -i "nts\|new source"

Successful connections show `new source` messages. Warnings like `error while attempting key exchange … TimedOut` indicate a temporary handshake failure that the daemon will retry.

### 3\. Validate Configuration

    ntp-ctl validate

If the syntax is correct, you’ll see `Config looks good`.

### 4\. Confirm Firewall Rules

    sudo iptables -t nat -L PREROUTING -v -n

You should see an explicit `REDIRECT` rule for port 123 matching your LAN interfaces and actively capturing packets.

* * *

Understanding `ntp-ctl status` Output
-------------------------------------

The output is split into two main parts: **Synchronization status** (your clock’s overall health) and **Sources** (each upstream server).

### Synchronization Status

*   **Dispersion** – How “spread out” the time measurements are. Lower is better; a few microseconds is excellent.
*   **Delay** – Round‑trip network delay to the selected source. A few tens of milliseconds is typical for an internet connection.
*   **Stratum** – Distance from a reference clock (atomic clock, GPS). Stratum 2 means you are two steps away, which is perfect for a home router.

### Source Metrics

| Metric | Meaning |
|--------|---------|
| **Offset** | Difference between your clock and the server's clock. Small values (<1 ms) are good. |
| **Uncertainty** | The daemon's confidence interval. Smaller is better. |
| **Delay** | Measured network delay to that server. |
| **Poll interval** | How often the daemon queries the server (in seconds). It adapts automatically. |
| **Missing polls** | How many expected responses never arrived. A healthy server should show 0. |
| **Root dispersion / delay** | Cumulative error from the server to the reference clock. Small values indicate a well‑synchronised server. |
| **NTS cookies** | Number of pre‑shared keys available for NTS. 8/8 = fully encrypted. Fewer cookies still mean NTS is active, but may require re‑keying. |

### Server Statistics (Local)

The `Servers:` block shows your local NTP server statistics – i.e. how many client requests your Firewalla has handled.

*   **Received / Accepted** – Total NTP requests received and successfully answered. They should be equal under normal conditions.
*   **Ignored / Denied / Rate limited** – Requests dropped due to configuration, rate limits, or access rules. Zero is healthy.
*   **NTS NAK** – Number of NTS key exchange failures (should stay 0).
*   **NTS Received / Accepted** – If you had NTS clients connecting directly, these would show activity. In an intercept‑only setup they remain 0.

* * *

Troubleshooting FAQ
-------------------

### Q: One of my servers shows many missing polls or low NTS cookies. What does that mean?

Missing polls and a drop in available cookies (e.g. `5/8` instead of `8/8`) usually indicate that the server is temporarily unreachable or the NTS key exchange is struggling. The daemon will keep retrying. If the problem persists, check DNS and network reachability.

**Example of a struggling server** (from a previous test configuration – _not_ part of the default seven servers anymore):

    ptbtime1.ptb.de:4460 192.53.103.108:123 [NTS] (52)
    	Offset:			+0.000000
    	Uncertainty:		±2147483648.500000
    	Delay:			±2147483648.500000
    	Poll interval:		16s
    	Missing polls:		8
    	NTS cookies:		5/8 available
    

Here the server shows huge uncertainty, 8 missing polls, and only 5 cookies – it is essentially unusable. The clock remains accurate because the other servers are fully functional.

### Q: What if a server doesn’t appear in the list at all?

If a configured server never responds, ntpd-rs may simply not show it in the output (or list it with extremely high missing polls). That’s fine – the daemon will ignore it and rely on the healthy ones. Check the journal for `could not resolve` or `error while attempting key exchange` to see why it failed.

### Q: All servers show high missing polls or no NTS cookies. What’s wrong?

This usually means ntpd-rs cannot resolve hostnames (DNS blocked) or cannot reach the internet on port 123/4460 (NTS). Steps:

1.  Check that ntpd-rs is running: `sudo systemctl status ntpd-rs`
2.  Look at the daemon log: `sudo journalctl -u ntpd-rs --no-pager | tail -40`
3.  Ensure the script added correct IPs to `/etc/hosts`: `cat /etc/hosts | grep -E 'time.cloudflare|ntppool1|time.nl|cincura|teambelgium|web-clock|system76'`
4.  Verify WAN outbound rules – temporarily disable any NTP‑related app rules to test.

### Q: How do I know if NTS encryption is actually working?

In the `ntp-ctl status` output, each source shows an **NTS cookies** line. `8/8 available` confirms active NTS. You can also grep the journal for `new source` messages. If you see `error while attempting key exchange`, that particular connection failed – but others likely still work.

### Q: I changed the server list in the script, but the new servers don’t work.

*   Did you update both the `[[source]]` entries **and** the `/etc/hosts` block inside the script? Both must match.
*   After editing, re‑run the script manually to regenerate configs.
*   Use `--update-config` for a quick regeneration: `sudo /home/pi/.firewalla/config/scripts/install_and_enforce_ntpd-rs.sh --update-config`
*   Verify the server actually supports NTS. Check the community list at [https://github.com/jauderho/nts-servers](https://github.com/jauderho/nts-servers).

### Q: The “NTP Intercept” slider in the Firewalla app shows OFF, but clients still can’t use their own NTP servers.

That’s expected. The script enforces interception independently via `iptables` rules at every boot and via cron. The app slider only controls Firewalla’s built‑in intercept, not the custom rules. To truly disable interception, you must uninstall the script (see _Uninstall_).

### Q: How can I temporarily disable interception for testing?

    sudo iptables -t nat -F PREROUTING

The rules will be automatically re‑applied on the next cron run or reboot.

* * *

What About Updates & Boot Persistence?
--------------------------------------

*   **Boot persistence service:** The script creates `/etc/systemd/system/ntpd-rs-boot-enforce.service` and enables it for `multi-user.target`, ensuring it runs at every boot.
*   **Daily cron job:** A cleanly tagged entry (`0 4 * * * root ...`) is added to `/etc/crontab`. It runs as root and re‑enforces configuration, firewall rules, and health checks.
*   **Health checks & Self-Repair:** Every execution checks that ntpd-rs is active and has healthy sources. If not, it tries to restart the daemon up to 3 times before logging a critical error.

* * *

Technical Details & Caveats
---------------------------

### Competing Services Neutralization

The script stops and masks `chrony`, `ntp`, `ntpdate`, `systemd-timesyncd`, and any old ntpd-rs instances. It also places an apt preferences pin to block those packages from being reinstalled by future updates.

### Hosts File Fix

Firewalla’s sandbox may block the unprivileged `ntp` user from accessing local DNS early in boot. To bypass this, the script inserts a marked block in `/etc/hosts`:

    # BEGIN NTPD-RS HOSTS
    162.159.200.1    time.cloudflare.com
    94.198.159.15    ntppool1.time.nl
    3.134.129.152    ohio.time.system76.com
    18.228.202.30    brazil.time.system76.com
    85.163.168.227   time.cincura.net
    91.177.126.188   nts.teambelgium.net
    173.206.104.134  time.web-clock.ca
    # END NTPD-RS HOSTS
    

### Why 7 Servers?

The NTP community often recommends at least **four to five** NTS servers for robust time keeping. However, many public NTS servers are run by individuals or small groups and can be less reliable than traditional NTP servers. After testing, we found **seven** servers that were consistently reachable and delivered correct time. We included all seven in the default configuration, but you are free to trim the list to five (or even fewer) by editing the script and running `--update-config`. The chosen servers are:

*   **Cloudflare** – Global anycast, highly reliable.
*   **TimeNL** – European government-backed stability.
*   **System76** (Ohio & Brazil) – US and South American redundancy.
*   **Cincura.net, TeamBelgium, Web‑Clock.ca** – Community‑maintained, geographically diverse.

**Limitation:** If any of these IPs change (rare), you’ll need to update them in the script and re‑run it.

### Auto Detection of Interfaces & IPs

The script automatically discovers your LAN bridges and physical interfaces, extracts their IPv4 addresses, and writes corresponding `[[server]]` stanzas into `ntp.toml`. No manual subnet configuration is needed.

### Customizing Your Time Servers

To add or remove servers, edit the script’s two configuration blocks (NTP sources + `/etc/hosts` block) and run:

    sudo /home/pi/.firewalla/config/scripts/install_and_enforce_ntpd-rs.sh --update-config

This regenerates the configuration and restarts ntpd-rs in seconds.

### Cron & Permissions

The cron job is placed in `/etc/crontab` with the user field set to `root`, so it runs with full privileges. You do not need to add `sudo` inside the cron command.

* * *

Uninstall / Revert to Stock
---------------------------

To remove ntpd-rs and restore Firewalla’s default time configuration, run the following as root:

    # Stop and disable any running ntpd-rs service
    sudo systemctl stop ntpd-rs ntpd-rsd 2>/dev/null
    sudo systemctl disable ntpd-rs ntpd-rsd 2>/dev/null
    
    # Purge the package
    sudo /home/pi/firewalla/scripts/apt-get.sh purge -y ntpd-rs
    
    # Disable boot-enforcement service
    sudo systemctl disable ntpd-rs-boot-enforce.service 2>/dev/null
    
    # Remove cron entry
    sudo sed -i '/# NTPD-RS NTS Service/,+1d' /etc/crontab
    
    # Remove apt preferences
    sudo rm -f /etc/apt/preferences.d/block-ntp
    
    # Remove /etc/hosts block
    sudo sed -i '/# BEGIN NTPD-RS HOSTS/,/# END NTPD-RS HOSTS/d' /etc/hosts
    
    # Delete all remaining files and directories
    sudo rm -f /etc/systemd/system/ntpd-rs-boot-enforce.service \
              /etc/ntpd-rs-url.conf \
              /etc/ntpd-rs-interface.conf \
              /tmp/ntpd_rs_restart_counter \
              /tmp/ntpd_rs_last_health \
              /log/ntpd-rs-installer.log
    sudo rm -rf /etc/ntpd-rs
    sudo systemctl daemon-reload
    
    # Delete the installer script itself
    sudo rm -f /home/pi/.firewalla/config/scripts/install_and_enforce_ntpd-rs.sh
    
    # Restore systemd-timesyncd
    sudo /home/pi/firewalla/scripts/apt-get.sh install systemd-timesyncd && \
    sudo systemctl unmask systemd-timesyncd && \
    sudo systemctl enable systemd-timesyncd && \
    sudo systemctl start systemd-timesyncd
    
    # Reboot
    sudo reboot
    

A full reboot is required to drop the iptables redirects and return time management entirely to Firewalla’s mobile app.

* * *

Final Notes
-----------

*   The script is designed to be low‑risk and completely revertible. It leaves no orphaned configuration and tracks its own health metrics.
*   The daily cron fires at **4:00 AM**, outside Firewalla’s typical firmware update window, so configuration is quickly restored if disturbed.

* * *

Credits & Community
-------------------

Built with input from the Firewalla community. If you have improvements or find issues, please open an issue or pull request. Contributions are welcome!
