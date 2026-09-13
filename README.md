# Mac mini M4 Headless & LLM Node Provisioner

![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-89e051)
![License](https://img.shields.io/badge/license-MIT-blue)

A single Bash script that turns a fresh **Mac mini M4 / M4 Pro** into an unattended, always-on headless server, ready for local LLM inference (Ollama, MLX, llama.cpp) and other background workloads — no monitor, no keyboard, no babysitting.

---

## Contents

- [Key Features](#key-features)
- [What the Script Changes](#what-the-script-changes)
- [Risk Analysis & Trade-offs](#risk-analysis--trade-offs)
- [Prerequisites](#prerequisites)
- [Installation & Usage](#installation--usage)
- [Post-Execution Checklist](#post-execution-checklist)
- [Logging & Backups](#logging--backups)
- [License](#license)

---

## Key Features

- **Autonomous Power Recovery** — configures the hardware to power back on automatically after an electrical outage (`pmset autorestart`).
- **Sleep & Power Assertions** — disables system sleep, display sleep, and standby permanently while keeping network keep-alives active.
- **Metal / Unified Memory Tuning** — raises `iogpu.wired_mem_limit` to 90%, so macOS doesn't artificially cap GPU memory for large local models.
- **File Descriptor Expansion** — installs a `launchd` daemon raising open-file limits (`maxfiles`) to `524288`.
- **Headless GUI Optimization** — clears the Dock, disables UI animations, and suppresses error dialogs to save RAM and GPU cycles.
- **Remote Access Out-of-the-Box** — enables SSH (`Remote Login`) with keep-alive tuning, plus native Screen Sharing (VNC).
- **Bloatware Stripping** — removes `Keynote`, `Numbers`, `Pages`, `GarageBand`, and `iMovie` from `/Applications`.
- **System Stability** — disables automatic OS updates/reboots and Spotlight indexing, to avoid surprise interruptions and unnecessary disk writes.
- **Auditability & Safe Execution** — colored console reporting, timestamped logs, and config backups before every edit.

---

## What the Script Changes

Each block below is one area of macOS the script touches: what gets set, and why. Every original file the script edits is backed up first (see [Logging & Backups](#logging--backups)).

<details open>
<summary><strong>System Identity</strong> — <code>scutil</code></summary>

| Key | Value |
| :--- | :--- |
| `ComputerName` / `HostName` / `LocalHostName` | your chosen hostname |

Keeps the POSIX hostname, Bonjour/mDNS name, and NetBIOS identity in sync, so you don't end up with a duplicate `machine-2.local` on the network.
</details>

<details open>
<summary><strong>Power Management</strong> — <code>pmset</code></summary>

| Key | Value |
| :--- | :--- |
| `sleep` / `displaysleep` / `standby` / `autopoweroff` | `0` (disabled) |
| `womp` (Wake on LAN) | `1` |
| `autorestart` | `1` |
| `tcpkeepalive` | `1` |

Keeps the machine awake indefinitely, lets it wake over the network, and guarantees it powers back on after an outage.
</details>

<details open>
<summary><strong>High Power Mode</strong> — <code>pmset</code> (M4 Pro/Max only)</summary>

| Key | Value |
| :--- | :--- |
| `highpowermode` (or `perfmode`) | `1` |

Unlocks elevated fan curves and sustained thermal headroom on chips that support it. Base M4 is left on the standard thermal profile.
</details>

<details open>
<summary><strong>Remote Access</strong> — SSH & Screen Sharing</summary>

| Key | Value |
| :--- | :--- |
| `systemsetup -setremotelogin` | `on` |
| `com.apple.screensharing` (launchd) | enabled |
| `ClientAliveInterval` / `ClientAliveCountMax` (`sshd_config`) | `30` / `5` |

Turns on SSH and native VNC (Screen Sharing, port 5900) and tunes SSH keep-alives so headless sessions don't get silently dropped.
</details>

<details open>
<summary><strong>Application Firewall</strong> — <code>socketfilterfw</code></summary>

| Key | Value |
| :--- | :--- |
| `globalstate` | `off` |

Stops GUI confirmation prompts from blocking headless background services that bind to a network port. See [Risk #2](#2-host-vulnerability-exposure-firewall-off) before enabling this on an exposed network.
</details>

<details>
<summary><strong>Dock & UI</strong> — <code>com.apple.dock</code>, <code>NSGlobalDomain</code></summary>

| Key | Value |
| :--- | :--- |
| `persistent-apps` | cleared |
| `show-recents` | `false` |
| `launchanim`, window/animation settings | `false` / `0` |
| `com.apple.CrashReporter DialogType` | `none` |

Purges pinned Dock icons, turns off animations, and suppresses crash dialogs — mostly cosmetic, but it reduces rendering overhead over Screen Sharing.
</details>

<details>
<summary><strong>Telemetry, Updates & Spotlight</strong></summary>

| Key | Value |
| :--- | :--- |
| Siri / diagnostic submission | `false` |
| `SoftwareUpdate AutomaticDownload` / `AutomaticallyInstallMacOSUpdates` | `false` |
| Spotlight (`mdutil -a -i`) | `off` |

Disables Siri and diagnostic reporting, switches OS updates to manual-only (see [Risk #5](#5-delayed-security-patches)), and turns off Spotlight indexing to reduce background CPU/disk writes. Finder search (`Cmd+Space`) stops working — use `find`/`mdfind` from the terminal instead.
</details>

<details>
<summary><strong>Memory & File Limits</strong></summary>

| Key | Value |
| :--- | :--- |
| `iogpu.wired_mem_limit` (`/etc/sysctl.conf`) | `90` (%) |
| `launchctl limit maxfiles` (`limit.maxfiles.plist`) | `524288` / `524288` |

Lets Metal buffers use up to 90% of Unified Memory (instead of the conservative default cap), and raises the open-file-descriptor ceiling from macOS's default `256` to handle thousands of concurrent sockets/vector-index files. See [Risk #6](#6-kernel-panic-potential-under-memory-starvation) for the trade-off.
</details>

<details>
<summary><strong>Application Removal</strong> — <code>/Applications</code></summary>

Removes `Keynote.app`, `Numbers.app`, `Pages.app`, `GarageBand.app`, and `iMovie.app` if present.
</details>

---

## Risk Analysis & Trade-offs

This script trades several default macOS protections for unattended uptime. Read this before deploying to anything but an isolated test machine — see also [`SECURITY.md`](SECURITY.md) for deployment-level recommendations.

### 1. Physical Security Compromise (FileVault off)
Full unattended recovery after a power outage requires FileVault to be disabled — the operator disables it manually (see [Prerequisites](#prerequisites)). **Impact:** storage is unencrypted at rest; anyone with physical access to the drive can read it. **Mitigation:** keep the machine in a physically secured location (locked room, rack, or cabinet).

### 2. Host Vulnerability Exposure (Firewall off)
The macOS Application Firewall is turned off entirely. **Impact:** any process binding to a network interface is reachable without a prompt. **Mitigation:** never connect this machine directly to the public internet — keep it behind a router/NAT, an edge firewall, or an isolated VLAN.

### 3. Thermal and Acoustic Output
High Power Mode (M4 Pro) combined with `sleep 0` keeps the machine fully active 24/7. **Impact:** higher idle power draw and potentially continuous fan noise depending on workload and ambient temperature.

### 4. File Search and Finder Limitations
Spotlight indexing is disabled. **Impact:** `Cmd+Space` search and Finder search return nothing. **Workaround:** use `find`, `fd`, or `mdfind` from the terminal.

### 5. Delayed Security Patches
Automatic OS updates and reboots are disabled. **Impact:** Apple's security patches are not applied automatically. **Mitigation:** schedule a recurring manual maintenance window: `sudo softwareupdate -ia --restart`.

### 6. Kernel Panic Potential under Memory Starvation
`iogpu.wired_mem_limit` is raised to 90%, letting a single inference process claim nearly all Unified Memory. **Impact:** if an LLM runtime hits that ceiling while the system is also under memory pressure (with no swap headroom), macOS can panic instead of gracefully killing the offending process. **Mitigation:** size context windows and quantization (`Q4_K_M`, `Q8_0`, etc.) to comfortably fit available RAM.

---

## Prerequisites

1. **Clean macOS installation** — validated on macOS Sonoma and Sequoia, Apple Silicon only.
2. **Root privileges** — the script must run via `sudo`.
3. **FileVault disabled** before deployment:
   ```bash
   # Check status
   fdesetup status

   # Disable if enabled
   sudo fdesetup disable
   ```

---

## Installation & Usage

1. Clone the repository onto the target Mac mini:
   ```bash
   git clone https://github.com/arleylambert/mac-headless-node.git
   cd mac-headless-node
   ```

2. Make the script executable:
   ```bash
   chmod +x bootstrap_macmini_pro.sh
   ```

3. Run it:
   ```bash
   sudo ./bootstrap_macmini_pro.sh <TARGET_USERNAME> [OPTIONAL_NODE_HOSTNAME]
   ```

   **Example:**
   ```bash
   sudo ./bootstrap_macmini_pro.sh admin macmini-node01
   ```

---

## Post-Execution Checklist

1. **HDMI dummy plug (optional)** — if you have one, plug it in now. It keeps the GPU framebuffer active during headless Screen Sharing sessions. Without it, SSH works identically, but Screen Sharing may show a blank display until one is connected.
2. **Reboot** to apply all kernel parameters, `sysctl` changes, and daemon registrations:
   ```bash
   sudo reboot
   ```
3. **Verify connectivity** from another machine on the same network:
   ```bash
   # SSH
   ssh <TARGET_USERNAME>@macmini-node01.local

   # Screen Sharing (VNC)
   open vnc://macmini-node01.local
   ```

---

## Logging & Backups

Every run creates timestamped artifacts alongside the script:

- **Execution log** — `bootstrap_YYYYMMDD_HHMMSS.log` (combined `stdout`/`stderr`)
- **Config backups** — `backups_YYYYMMDD_HHMMSS/` (original copies of every file the script edits, e.g. `/etc/sysctl.conf`, `/etc/ssh/sshd_config`)

---

## License

MIT — see [LICENSE](LICENSE) for details.
