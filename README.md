# Apple Silicon Headless & LLM Node Provisioner

![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-89e051)
![License](https://img.shields.io/badge/license-MIT-blue)

A single Bash script that turns a fresh **Apple Silicon Mac** into an unattended, always-on headless server, ready for local LLM inference (Ollama, MLX, llama.cpp) and other background workloads — no monitor, no keyboard, no babysitting. Built and validated on a **Mac mini M4 / M4 Pro**, but nothing in it is hardware-gated to that model — see [Tested Hardware & Compatibility](#tested-hardware--compatibility) for the full picture across Mac mini, Mac Studio, Mac Pro, iMac, and MacBook.

---

## Contents

- [Key Features](#key-features)
- [What the Script Changes](#what-the-script-changes)
- [Risk Analysis & Trade-offs](#risk-analysis--trade-offs)
- [Tested Hardware & Compatibility](#tested-hardware--compatibility)
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
- **Dev Tooling Bootstrap** — installs Xcode Command Line Tools (`git`) and Homebrew unattended, as the last step, if they aren't already present.

---

## What the Script Changes

Each block below is one area of macOS the script touches: what gets set, and why. Every original file the script edits is backed up first (see [Logging & Backups](#logging--backups)).

<details>
<summary><strong>System Identity</strong> — <code>scutil</code></summary>

| Key | Value |
| :--- | :--- |
| `ComputerName` / `HostName` / `LocalHostName` | your chosen hostname |

Keeps the POSIX hostname, Bonjour/mDNS name, and NetBIOS identity in sync, so you don't end up with a duplicate `machine-2.local` on the network.
</details>

<details>
<summary><strong>Power Management</strong> — <code>pmset</code></summary>

| Key | Value |
| :--- | :--- |
| `sleep` / `displaysleep` / `standby` / `autopoweroff` | `0` (disabled) |
| `womp` (Wake on LAN) | `1` |
| `autorestart` | `1` |
| `tcpkeepalive` | `1` |

Keeps the machine awake indefinitely, lets it wake over the network, and guarantees it powers back on after an outage.
</details>

<details>
<summary><strong>High Power Mode</strong> — <code>pmset</code> (Pro/Max/Ultra chips only)</summary>

| Key | Value |
| :--- | :--- |
| `highpowermode` (or `perfmode`) | `1` |

Unlocks elevated fan curves and sustained thermal headroom on chips that support it. Base-tier chips (plain M1–M4, no suffix) are left on the standard thermal profile.
</details>

<details>
<summary><strong>Remote Access</strong> — SSH & Screen Sharing</summary>

| Key | Value |
| :--- | :--- |
| `systemsetup -setremotelogin` | `on` |
| `com.apple.screensharing` (launchd) | enabled |
| `ClientAliveInterval` / `ClientAliveCountMax` (`sshd_config`) | `30` / `5` |

Turns on SSH and native VNC (Screen Sharing, port 5900) and tunes SSH keep-alives so headless sessions don't get silently dropped.
</details>

<details>
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

<details>
<summary><strong>Dev Tooling</strong> — Xcode Command Line Tools &amp; Homebrew</summary>

Runs as the last step. Installs the Xcode Command Line Tools (which is what actually provides `git`) via `softwareupdate` — not `xcode-select --install`, which pops an interactive GUI dialog with no unattended equivalent — then installs [Homebrew](https://brew.sh) for `TARGET_USER` by creating and `chown`-ing `/opt/homebrew` as root and extracting the brew tarball directly (Homebrew's documented method for non-interactive installs) rather than running its official `install.sh`, which needs an interactive `sudo` password mid-install that this script has no way to supply — and adds brew to that user's `~/.zprofile`. Both steps are skipped if already present, and both **require internet access on the target machine** — if you provisioned it offline (see [Option C](#option-c--offline-transfer-usb-drive-airdrop-etc)), this step will report as failed rather than block the rest of the script; connect it to the network and re-run later, or install manually.
</details>

---

## Risk Analysis & Trade-offs

This script trades several default macOS protections for unattended uptime. Read this before deploying to anything but an isolated test machine — see also [`SECURITY.md`](SECURITY.md) for deployment-level recommendations.

### 1. Physical Security Compromise (FileVault off)
Full unattended recovery after a power outage requires FileVault to be disabled — the operator disables it manually (see [Prerequisites](#prerequisites)). **Impact:** storage is unencrypted at rest; anyone with physical access to the drive can read it. **Mitigation:** keep the machine in a physically secured location (locked room, rack, or cabinet).

### 2. Host Vulnerability Exposure (Firewall off)
The macOS Application Firewall is turned off entirely. **Impact:** any process binding to a network interface is reachable without a prompt. **Mitigation:** never connect this machine directly to the public internet — keep it behind a router/NAT, an edge firewall, or an isolated VLAN.

### 3. Thermal and Acoustic Output
High Power Mode (on Pro/Max/Ultra chips) combined with `sleep 0` keeps the machine fully active 24/7. **Impact:** higher idle power draw and potentially continuous fan noise depending on workload and ambient temperature.

### 4. File Search and Finder Limitations
Spotlight indexing is disabled. **Impact:** `Cmd+Space` search and Finder search return nothing. **Workaround:** use `find`, `fd`, or `mdfind` from the terminal.

### 5. Delayed Security Patches
Automatic OS updates and reboots are disabled. **Impact:** Apple's security patches are not applied automatically. **Mitigation:** schedule a recurring manual maintenance window: `sudo softwareupdate -ia --restart`.

### 6. Kernel Panic Potential under Memory Starvation
`iogpu.wired_mem_limit` is raised to 90%, letting a single inference process claim nearly all Unified Memory. **Impact:** if an LLM runtime hits that ceiling while the system is also under memory pressure (with no swap headroom), macOS can panic instead of gracefully killing the offending process. **Mitigation:** size context windows and quantization (`Q4_K_M`, `Q8_0`, etc.) to comfortably fit available RAM.

---

## Tested Hardware & Compatibility

This script was built and **actively validated on a Mac mini M4 / M4 Pro**. It doesn't call anything M4-specific, though — every command it uses (`scutil`, `pmset`, `launchctl`, `socketfilterfw`, `defaults`, and the `iogpu.wired_mem_limit` unified-memory tuning) is standard across Apple Silicon, and the "High Power Mode" step already tries several pmset keys and skips itself cleanly if none apply. Since M1, the script requires **Apple Silicon (arm64)** — it now checks for this explicitly and exits with a clear error on Intel Macs, which don't have Unified Memory or the `iogpu` tuning this project relies on.

| Model | Status | Notes |
| :--- | :--- | :--- |
| **Mac mini** (M4 / M4 Pro) | ✅ Tested | Validated on macOS Tahoe (26) — the hardware this project was built for |
| **Mac mini** (M1 / M2 / M2 Pro) | 🟡 Expected to work | Same headless use case, untested |
| **Mac Studio** (M1/M2 Max/Ultra, M3 Ultra, and later) | 🟡 Expected to work | Arguably an even better fit — more sustained thermal headroom for larger models |
| **Mac Pro** (Apple Silicon, M2 Ultra and later) | 🟡 Expected to work | Same reasoning as Mac Studio |
| **iMac** (M1, M3, M4) | 🟡 Expected to work | Compatible, but running a display-equipped all-in-one headless is an unusual choice |
| **MacBook Air / MacBook Pro** (M1–M4 family) | 🟡 Expected to work, with caveats | Needs external power and clamshell (lid-closed) mode configured so the built-in display sleeping doesn't put the whole system to sleep; battery wear from 24/7 operation is also a consideration |
| **Any Intel Mac** | ❌ Not supported | The script now exits immediately — no Unified Memory / `iogpu` tuning available on Intel |

"🟡 Expected to work" means: no code path in the script is hardware-gated to the M4 specifically, so there's no known reason it wouldn't run — but it hasn't been run there yet. If you test it on one of these and it works (or doesn't), opening an issue or a PR to update this table is very welcome.

---

## Prerequisites

1. **Clean macOS installation** — validated on macOS Sonoma, Sequoia, and Tahoe (26), Apple Silicon only.
2. **Root privileges** — the script must run via `sudo`.
3. **No `git` required** — see [Installation & Usage](#installation--usage) for a `curl`-only path if you're working with a genuinely fresh install.
4. **Full Disk Access for Terminal** (or whichever app runs the script) — required by macOS before `systemsetup` is allowed to turn Remote Login (SSH) on or off. This is a one-time, GUI-only step Apple doesn't allow scripting around:
   `System Settings → Privacy & Security → Full Disk Access → enable it for Terminal`.
   Without this, the script still completes everything else — it just reports the SSH/Screen Sharing step as failed (with a hint pointing back here) and you re-run it after granting access.
5. **FileVault disabled** before deployment:
   ```bash
   # Check status
   fdesetup status

   # Disable if enabled
   sudo fdesetup disable
   ```

---

## Installation & Usage

A clean macOS install does **not** ship with `git` — the first time you run it, macOS prompts you to install the Xcode Command Line Tools, which is an interactive GUI dialog and needs an internet connection of its own. That's fine if you're setting the machine up in person, but it gets in the way of a fast, scriptable bootstrap. Pick the path that fits:

### Option A — No `git` required (recommended for a fresh machine)

`curl` is preinstalled on every Mac, so you can pull just the script directly:

```bash
curl -O https://raw.githubusercontent.com/arleylambert/mac-headless-node/main/bootstrap_mac_node.sh
chmod +x bootstrap_mac_node.sh
sudo ./bootstrap_mac_node.sh <TARGET_USERNAME> [OPTIONAL_NODE_HOSTNAME]
```

This gets you only the script — enough to run it. Grab the [README](README.md) and [SECURITY.md](SECURITY.md) separately (or read them here on GitHub) if you want the full documentation on the machine too.

### Option B — Full clone (if `git` is already installed, or you don't mind installing it)

```bash
git clone https://github.com/arleylambert/mac-headless-node.git
cd mac-headless-node
chmod +x bootstrap_mac_node.sh
sudo ./bootstrap_mac_node.sh <TARGET_USERNAME> [OPTIONAL_NODE_HOSTNAME]
```

Useful if you plan to track updates, contribute changes, or just prefer having the whole repository (docs included) on the box.

### Option C — Offline transfer (USB drive, AirDrop, etc.)

For a Mac mini with no network access yet (or one you'd rather not connect to the internet before it's locked down), download the files on another computer and copy them over physically:

1. On any computer with internet access, download the script — either right-click → **Save Link As** on [`bootstrap_mac_node.sh`](bootstrap_mac_node.sh), or use the **Code → Download ZIP** button on the [repository page](https://github.com/arleylambert/mac-headless-node) for everything (docs included).
2. Copy the file(s) onto a USB flash drive, or transfer via AirDrop if the other computer is also a Mac.
3. On the target Mac mini, copy the script from the drive to a working directory and continue from step 2 of Option A/B:
   ```bash
   # Example, assuming the drive is mounted as NODE_SETUP
   cp "/Volumes/NODE_SETUP/bootstrap_mac_node.sh" ~/bootstrap_mac_node.sh
   cd ~
   chmod +x bootstrap_mac_node.sh
   sudo ./bootstrap_mac_node.sh <TARGET_USERNAME> [OPTIONAL_NODE_HOSTNAME]
   ```

**Example (any option):**
```bash
sudo ./bootstrap_mac_node.sh admin macmini-node01
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
