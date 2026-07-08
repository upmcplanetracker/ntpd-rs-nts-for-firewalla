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
> **NEVER RUN `APT UPGRADE`.** This script only installs `ntpd-rs` from its official pre-built binary (or a dedicated PPA); it does **not** upgrade system packages. Firewalla uses a custom Ubuntu OS; upgrading generic Ubuntu packages will probably **destabilize or brick** your box. The script uses Firewalla's safe `apt-get.sh` wrapper where possible and installs ntpd-rs in a contained manner.
> 
> **TESTED ON FIREWALLA GOLD PLUS** running **Ubuntu 22.04** (fresh image from Firewalla). It should work on other modern models, but is **not guaranteed** on older OS versions (18.04, 20.04).
> 
> **PLEASE READ THIS ENTIRE README** to understand what you’re getting into **and how to revert** if needed.
> 
> **NTP INTERCEPT STILL APPLIES.** Clients on your LAN behind NTP intercept must still use **plain NTP** (not NTS) because Firewalla only intercepts NTP. If you have devices with NTS-capable clients (like newer systemd-timesyncd or Chrony) behind NTP intercept on your LAN, they will fail to sync unless you either:
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
*   **Auto detect** the precise subnets (CIDR) and add them to `/etc/ntpd-rs/ntp.toml` (e.g., `allow 192.168.1.0/24`).
*   **Install** `ntpd-rs` using the [official Github pre-built `.deb` binary (currently 1.9.0)](https://github.com/pendulum-project/ntpd-rs/releases/tag/v1.9.0).
*   **Mask & Lock** competing NTP services (including `chrony`, `ntp`, `ntpdate`, `systemd-timesyncd`) via custom apt preferences to completely avoid package conflicts.
*   **Append** NTS server IPs to `/etc/hosts` so ntpd-rs can resolve hostnames even when local DNS tracking is lagging during early boot phases.
*   **Apply** iptables and ip6tables redirection rules to route NTP traffic cleanly on all active LAN interfaces.

* * *

How to Verify
-------------

### 1\. Check Time Sources & Status

Run:

    ntp-ctl status
    

This shows a summary of the system clock (dispersion, delay, stratum) and a detailed breakdown for each NTS source. Look for:

*   **Offset** – how far your clock drifts (in seconds).
*   **Uncertainty** – the estimated error margin.
*   **Missing polls** – if a server isn’t responding, this number climbs.
*   **NTS cookies** – active encrypted sessions; for example, `8/8 available` means the server is fully encrypted and reachable.

A server with many missing polls or a low cookie count (e.g., `5/8`) may be experiencing temporary connectivity issues, but the daemon will automatically retry.

### 2\. Verify NTS Encryption

Look at the **NTS cookies** line for each source in the `ntp-ctl status` output. A value of `8/8 available` indicates NTS is fully active for that server. If cookies are lower but still present, encryption is working; the daemon manages the pool automatically.

You can also check the `ntpd-rs` journal for NTS key exchange events:

    sudo journalctl -u ntpd-rs --no-pager | grep -i "nts\|new source"
    

Successful connections show `new source` messages with the server address. Warnings like `error while attempting key exchange … TimedOut` indicate a temporary handshake failure that the daemon will retry.

### 3\. Validate Configuration

Confirm that the generated `ntp.toml` is syntactically correct:

    ntp-ctl validate
    

This prints the config file path and `Config looks good` if everything is fine.

### 4\. Confirm Firewall Rules

Run:

    sudo iptables -t nat -L PREROUTING -v -n
    

You should see an explicit `REDIRECT` rule for NTP (port 123) matching your individual LAN interfaces and actively capturing packets.

* * *

Troubleshooting FAQ
-------------------

### Q: One of my servers shows many missing polls or low NTS cookies. What does that mean?

Missing polls and a drop in available cookies (e.g., `5/8` instead of `8/8`) usually indicate that the server is temporarily unreachable or the NTS key exchange is struggling. The daemon will keep retrying. If the problem persists, check the server’s DNS resolution and network reachability.

Example from `ntp-ctl status` (a healthy system):

    ntppool1.time.nl:4460 94.198.159.15:123 [NTS] (3)
    	Offset:			-0.000670
    	Uncertainty:		±0.000652
    	Delay:			±0.109154
    	Poll interval:		128s
    	Missing polls:		0
    	NTS cookies:		8/8 available
    
    ohio.time.system76.com:4460 3.134.129.152:123 [NTS] (2)
    	Offset:			+0.003713
    	Uncertainty:		±0.000427
    	Delay:			±0.030009
    	Poll interval:		64s
    	Missing polls:		0
    	NTS cookies:		8/8 available
    
    ptbtime1.ptb.de:4460 192.53.103.108:123 [NTS] (52)
    	Offset:			+0.000000
    	Uncertainty:		±2147483648.500000
    	Delay:			±2147483648.500000
    	Poll interval:		16s
    	Missing polls:		8
    	NTS cookies:		5/8 available
    
    time.cloudflare.com:4460 162.159.200.1:123 [NTS] (1)
    	Offset:			+0.001174
    	Uncertainty:		±0.000316
    	Delay:			±0.010982
    	Poll interval:		128s
    	Missing polls:		0
    	NTS cookies:		8/8 available
    

Here, `ptbtime1.ptb.de` has **8 missing polls** and only **5/8 cookies** – it’s experiencing intermittent issues. The clock remains accurate because other servers are fully available.

**What to do:**

1.  Wait 10–15 minutes – ntpd-rs will keep retrying.
2.  Check DNS resolution: `nslookup ptbtime1.ptb.de` (should return `192.53.103.108`).
3.  Verify the IP is reachable: `ping 192.53.103.108`.
4.  If the server is permanently gone, edit the server entries in the script’s configuration block and the `/etc/hosts` mappings, then re‑run the script (see _Customizing Your Time Servers_).

### Q: All servers show high missing polls or no NTS cookies. What’s wrong?

This usually indicates ntpd-rs cannot resolve server hostnames (DNS blocked) or cannot reach the internet on port 123/4460 (NTS). Steps:

1.  Check that ntpd-rs is running: `sudo systemctl status ntpd-rs`.
2.  Look at the daemon log: `sudo journalctl -u ntpd-rs --no-pager | tail -40`. Search for “could not resolve” or “error while attempting key exchange”.
3.  Ensure the script has added the correct IPs to `/etc/hosts`: `cat /etc/hosts | grep -E 'time.cloudflare|ntppool1|ptbtime1|system76'`. If missing, re‑run the configuration script manually.
4.  Verify the WAN interface allows outbound NTP/NTS traffic (the script does not block it, but a strict Firewalla policy might). Temporarily disable any NTP‑related app rules to test.

### Q: How do I know if NTS encryption is actually working?

In the `ntp-ctl status` output, each source shows an **NTS cookies** line. A value of `8/8 available` confirms NTS is active. You can also check the journal for successful key exchanges. If the daemon logs `error while attempting key exchange` for a server, that particular connection may have failed (but others likely still work). Check your firewall and ISP for port 4460/tcp.

### Q: I changed the server list in the script, but the new servers don’t work.

*   Did you update both the `[[server]]` entries in the ntpd-rs config block **and** the `/etc/hosts` block inside the script? Both must match.
*   After editing the script, re‑run it manually to regenerate system profiles: `sudo /home/pi/.firewalla/config/scripts/install_and_enforce_ntpd-rs.sh`.
*   Verify the new entries in `/etc/hosts` are present and correct.
*   Check if the server actually supports NTS (the script requires the `nts` flag). Use the community list at [https://github.com/jauderho/nts-servers](https://github.com/jauderho/nts-servers).

### Q: The “NTP Intercept” slider in the Firewalla app shows OFF, but clients still can’t use their own NTP servers.

That’s expected. The script enforces interception independently via `iptables` rules at every boot and via cron. The app slider only controls Firewalla’s built‑in intercept feature, not the custom rules. If you truly want to disable interception, you must uninstall the script (see _Uninstall / Revert to Stock_).

### Q: How can I temporarily disable interception for testing?

Manually flush the NAT rules (they will be automatically re‑applied on the next cron run or reboot sequence):

    sudo iptables -t nat -F PREROUTING
    

To restore immediately, re‑run the script: `sudo /home/pi/.firewalla/config/scripts/install_and_enforce_ntpd-rs.sh`.

* * *

What About Updates & Boot Persistence?
--------------------------------------

*   **Boot persistence service:** The script generates a native local systemd service file (`/etc/systemd/system/ntpd-rs-boot-enforce.service`) mapped to the `multi-user.target` sequence. This guarantees it triggers reliably every boot without racing other startup configurations.
*   **Daily cron job:** The script **automatically** adds or updates its own cleanly tagged cron entry (`0 4 * * * root /path/to/script.sh &>/dev/null`) directly inside the **system crontab** (`/etc/crontab`). It runs as root with full privileges to manage routing updates and reload underlying service states.
*   **Health checks & Self-Repair:** Every script execution (boot, cron, manual) triggers a lightweight evaluation loop. It validates that the `ntpd-rs` daemon is fully active and has at least one healthy time source. If an error or an unhealthy loop state is isolated, it attempts to restart the service up to 3 times before generating a critical log block.

* * *

Technical Details & Caveats
---------------------------

### Competing Services Neutralization

This script features a built-in block engine that neutralizes all conflicting NTP services. It masks and stops `chrony`, `ntp`, `ntpdate`, `systemd-timesyncd`, and even older `ntpd-rs` instances if present. It also places an apt preferences pin to prevent those packages from being reinstalled by future system updates.

### Hosts File Fix

Firewalla’s sandbox may block the unprivileged `ntp` user (under which ntpd-rs runs) from accessing generic local DNS profiles during early boot. To bypass this, the script **hardcodes** the NTS server IPs into `/etc/hosts`.

After running, your `/etc/hosts` file will include:

    162.159.200.1    time.cloudflare.com
    94.198.159.15    ntppool1.time.nl
    192.53.103.108   ptbtime1.ptb.de
    3.134.129.152    ohio.time.system76.com
    52.203.218.175   virginia.time.system76.com
    

### Why 5 Servers?

We moved beyond a minimal set to a 5-server quorum for better geographic diversity and failover reliability. Most NTS experts recommend at least 4 servers but no more than 10. The five selected are:

*   Cloudflare – Global Anycast
*   TimeNL & PTB – European government-backed stability
*   System76 (Ohio & Virginia) – Low-latency US regional redundancy

**Limitation:** If these upstream IPs change (rare), you’ll need to adjust them inside your script definitions and let it rebuild your `/etc/hosts` file.

### Auto Detection of Interfaces & Subnets

The script automatically discovers:

*   All active **bridge** interfaces (`br0`, `br1`, …)
*   Physical interfaces (if no bridges are active) – explicitly skipping WAN configurations (`wan`, `ppp`, `tun`, `wg`, `vpn`)
*   For each active configuration, it extracts the **precise CIDR** (e.g., `192.168.1.0/24`) and builds localized `allow` directives in `/etc/ntpd-rs/ntp.toml`.

This means **you don’t need to manually edit any interface or subnet settings** – it Just Works.

### Customizing Your Time Servers

If you want to use different NTS servers, update two places in the script:

1.  **`ntp.toml` configuration block**: Modify the `[[server]]` entries (address and NTS flag).
2.  **`/etc/hosts` block**: Update the corresponding IP address mappings so the system can resolve them during early boot.

**Tip:** You can find a list of reliable NTS-capable servers at the community tracker: [https://github.com/jauderho/nts-servers](https://github.com/jauderho/nts-servers).

### Cron & Permissions

The script injects its cron job into `/etc/crontab` with the **user field explicitly declared as `root`** – so the command runs with full systemic permissions. You do **not** need to manually use `sudo` inside the cron layout string.

* * *

Uninstall / Revert to Stock
---------------------------

If you want to remove ntpd-rs and cleanly restore Firewalla’s default time configuration, execute these clean-up commands as root.

### Step 1: Remove the Services & Core Scripts

    sudo systemctl disable ntpd-rs-boot-enforce.service 2>/dev/null
    sudo rm -f /etc/systemd/system/ntpd-rs-boot-enforce.service
    sudo systemctl daemon-reload
    sudo rm -f /home/pi/.firewalla/config/scripts/install_and_enforce_ntpd-rs.sh
    sudo rm -f /etc/ntpd-rs/ntp.toml
    

### Step 2: Delete Automated Crontab Entries

    sudo sed -i '/# ntpd-rs NTS Service/,+1d' /etc/crontab
    

### Step 3: Clean Up Apt Preferences & Hosts Definitions

    sudo rm -f /etc/apt/preferences.d/block-ntp
    sudo sed -i '/# Cloudflare/,$d' /etc/hosts
    

### Step 4: Remove ntpd-rs Package

If you installed via the script’s packaged method, remove it accordingly (the script may have placed a `.deb` or used a PPA purge). For a manual binary installation:

    sudo rm -f /usr/local/bin/ntpd-rs /usr/local/bin/ntp-ctl
    sudo rm -rf /etc/ntpd-rs
    

### Step 5: Restore Default Time Service

Firewalla uses `systemd-timesyncd` by default. To restore and clear systemic blocks:

    /home/pi/firewalla/scripts/apt-get.sh install systemd-timesyncd
    sudo systemctl unmask systemd-timesyncd
    sudo systemctl enable systemd-timesyncd
    sudo systemctl start systemd-timesyncd
    

### Step 6: Reboot (Mandatory)

    sudo reboot
    

A full system reboot is required to drop active `iptables` redirects safely and return complete time configuration management back to the native Firewalla mobile application interface.

* * *

Final Notes
-----------

*   The script is built to be entirely low-risk and completely revertible—it doesn't leave orphaned configuration modifications, does not lock running dependencies, and explicitly tracks system status metrics.
*   The automated cron task fires daily at **4:00 AM**, cleanly falling outside Firewalla's typical firmware update window so that configuration modifications are evaluated and restored rapidly.

* * *

Credits & Community
-------------------

This project was built with input from the Firewalla community. If you have improvements or find issues, please open an issue or pull request. Contributions are welcome!
