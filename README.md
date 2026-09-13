# Mac mini M4 Headless & LLM Node Provisioner

Production-grade Bash bootstrap script designed to transform a fresh macOS installation (specifically optimized for Apple Silicon **Mac mini M4 / M4 Pro**) into an unattended, autonomous headless server ready for local LLM inference engines (Metal/GPU) and distributed workloads.

---

## Key Features

- **Autonomous Power Recovery**: Configures the hardware to automatically power back on after an electrical outage (`pmset autorestart`).
- **Sleep & Power Assertions**: Disables system sleep, display sleep, and standby states permanently while keeping network keep-alives active.
- **Metal / Unified Memory Tuning**: Sets `iogpu.wired_mem_limit` to 90%, preventing macOS from artificially capping GPU memory allocation for large local models (Ollama, MLX, llama.cpp).
- **File Descriptor Expansion**: Deploys a native `launchd` daemon raising system and process open-file descriptor limits (`maxfiles`) to `524288`.
- **Headless GUI Optimization**: Removes all default pinned apps from the Dock, disables UI animations, and suppresses error dialogue boxes to conserve RAM and GPU cycles.
- **Remote Access Out-of-the-Box**: Enables native SSH (`Remote Login`) with connection keep-alive configurations and macOS Screen Sharing (VNC).
- **Bloatware Stripping**: Recursively removes consumer packages (`Keynote`, `Numbers`, `Pages`, `GarageBand`, `iMovie`) from `/Applications`.
- **System Stability**: Turns off automatic OS updates and reboots while leaving manual terminal updates intact; disables Spotlight indexing to preserve NVMe write endurance.
- **Auditability & Safe Execution**: Idempotent execution, colored console reporting, atomic file backups before edits, and timestamped execution logs.

---

## Architectural Breakdown & Exact File Modifications

The script modifies specific system preferences, domain property lists (`.plist`), and core UNIX configuration files. Below is the exact inventory of changes:

| Target Component / File | Configuration Key / Parameter | Applied Value | Purpose |
| :--- | :--- | :--- | :--- |
| **System Identity** (`scutil`) | `ComputerName`<br>`HostName`<br>`LocalHostName` | User-defined string | Synchronizes POSIX hostname, Bonjour/mDNS, and NetBIOS identities to prevent duplicate `.local` names. |
| **Power Management** (`NVRAM / SMC`) | `sleep`<br>`displaysleep`<br>`womp`<br>`autorestart`<br>`tcpkeepalive`<br>`standby`<br>`autopoweroff` | `0`<br>`0`<br>`1`<br>`1`<br>`1`<br>`0`<br>`0` | Forces system threads to stay awake indefinitely, enables Wake on LAN, and guarantees automatic power-on after power restoration. |
| **High Power Profile** (`pmset`) | `perfmode` or `highpower` | `1` (if M4 Pro) | Unlocks elevated fan curves and maximum sustained thermal headroom on supported M4 Pro chips. |
| **SSH Daemon Config** (`/etc/ssh/sshd_config`) | `ClientAliveInterval`<br>`ClientAliveCountMax` | `30`<br>`5` | Emits a keep-alive probe every 30 seconds; terminates dead TCP pipes after 5 dropped responses to avoid orphaned headless sessions. |
| **Remote Screen Sharing** (`launchd`) | `com.apple.screensharing` | `enable` / `kickstart` | Launches native Apple Remote Desktop / VNC daemon on port 5900. |
| **Application Firewall** (`socketfilterfw`) | `globalstate` | `off` | Prevents GUI confirmation prompts from blocking headless background processes binding to TCP ports. |
| **User Dock Configuration** (`~/Library/Preferences/com.apple.dock.plist`) | `persistent-apps`<br>`show-recents`<br>`launchanim` | `()` (empty array)<br>`false`<br>`false` | Purges all pinned application shortcuts, hides recent items, and stops Dock icon launch bounce animations. |
| **Window Server & CoreGraphics** (`NSGlobalDomain`) | `NSAutomaticWindowAnimationsEnabled`<br>`QLPanelAnimationDuration`<br>`NSWindowResizeTime` | `false`<br>`0`<br>`0.001` | Strips CoreAnimation transitions, drastically reducing remote frame rendering latency over VNC sessions. |
| **Diagnostic Reporting** (`~/Library/Preferences/com.apple.CrashReporter.plist`) | `DialogType` | `none` | Suppresses graphical alert modals on process crashes, preventing background queues from hanging. |
| **Software Update Engine** (`/Library/Preferences/com.apple.SoftwareUpdate.plist`) | `AutomaticDownload`<br>`AutomaticallyInstallMacOSUpdates` | `false`<br>`false` | Halts uncoordinated operating system downloads and midnight reboots. Updates remain available on-demand. |
| **Spotlight Metadata Store** (`/.Spotlight-V100/`) | `mdutil -a -i off` | Indexing disabled | Halts `mds` and `mdworker` process loops, conserving host CPU cycles and eliminating redundant disk writes. |
| **Kernel Memory Allocator** (`/etc/sysctl.conf`) | `iogpu.wired_mem_limit` | `90` | Instructs the Apple Silicon IOGPU driver to allow up to 90% of total Unified Memory to be pinned by Metal buffers. |
| **Kernel Open File Limits** (`/Library/LaunchDaemons/limit.maxfiles.plist`) | `launchctl limit maxfiles` | `524288 524288` (Soft/Hard) | Replaces the restrictive default limit (`256`) to handle thousands of open network sockets and vector index files. |
| **Consumer Applications** (`/Applications/`) | Directory deletion (`rm -rf`) | Files removed | Deletes `Keynote.app`, `Numbers.app`, `Pages.app`, `GarageBand.app`, and `iMovie.app` from user space. |

---

## Risk Analysis & Potential Side Effects

Before running this script in production, review the following potential system impacts, trade-offs, and operational risks:

### 1. Physical Security Compromise (Disabling FileVault)
- **Risk**: To achieve true 100% unattended recovery after power outages, FileVault must be disabled.
- **Impact**: Storage is no longer encrypted at rest. If the physical Mac mini is stolen, an adversary with physical access can extract unencrypted data directly from the internal storage.
- **Mitigation**: Deploy the node inside a physically secured server room, lockable rack enclosure, or isolated access cabinet.

### 2. Host Vulnerability Exposure (Disabling Local Firewall)
- **Risk**: The macOS Application Firewall (`socketfilterfw`) is turned completely off.
- **Impact**: Any service or container that binds to `0.0.0.0` or local interfaces will be reachable across the network without confirmation prompts.
- **Mitigation**: Do not connect this machine directly to the public internet. Isolate the node behind a dedicated hardware router, edge firewall, or within an isolated VLAN.

### 3. Thermal and Acoustic Output
- **Risk**: High Power Mode (on M4 Pro) coupled with `sleep 0` keeps the machine active 24/7.
- **Impact**: The node will consume more idle power from the wall and may exhibit higher continuous fan noise depending on ambient temperatures and ongoing background workloads.

### 4. File Search and Finder Limitations
- **Risk**: Spotlight metadata indexing is disabled (`mdutil -a -i off`).
- **Impact**: File indexing inside Finder will cease to work. Searching for files via `Cmd + Space` (Spotlight UI) or using native macOS search queries will return empty results. Terminal-based utilities (`find`, `fd`, `mdfind`) must be used instead.

### 5. Delayed Security Patches
- **Risk**: Automatic updates and reboot permissions are disabled.
- **Impact**: Critical operating system vulnerabilities will not be patched automatically by Apple.
- **Mitigation**: Operators must establish a scheduled maintenance window to run manual updates via terminal (`sudo softwareupdate -ia --restart`).

### 6. Kernel Panic Potential under Memory Starvation
- **Risk**: Raising `iogpu.wired_mem_limit` to 90% allows a single LLM process to consume almost all Unified Memory.
- **Impact**: If an inference runtime (e.g., Ollama or MLX) consumes exactly 90% and system-level host daemons experience memory pressure spikes with swap disabled or full, the macOS kernel (`Mach`) may suffer an unrecoverable out-of-memory panic rather than gracefully terminating the offending process.
- **Mitigation**: Ensure LLM context window sizes and quantization profiles (`Q4_K_M`, `Q8_0`) are mathematically sized to fit well within available RAM.

---

## Prerequisites

1. **Clean macOS Installation**: Validated on macOS Sonoma and macOS Sequoia on Apple Silicon architecture.
2. **Root Privileges**: Execution must be performed via `sudo`.
3. **Disable FileVault**: FileVault must be disabled prior to deployment:
   ```bash
   # Check FileVault status
   fdesetup status

   # Disable FileVault if enabled
   sudo fdesetup disable
   ```

---

## Installation & Usage

1. Clone or download the repository to the target Mac mini:
   ```bash
   git clone [https://github.com/](https://github.com/)<your-username>/<your-repo-name>.git
   cd <your-repo-name>
   ```

2. Make the script executable:
   ```bash
   chmod +x bootstrap_macmini_pro.sh
   ```

3. Execute the bootstrap script:
   ```bash
   sudo ./bootstrap_macmini_pro.sh <TARGET_USERNAME> [OPTIONAL_NODE_HOSTNAME]
   ```

### Execution Example:
```bash
sudo ./bootstrap_macmini_pro.sh admin macmini-node01
```

---

## Post-Execution Checklist

1. **HDMI Dummy Plug (Conditional)**:
   - **If you have an active 4K HDMI Dummy Plug**: Insert it into the HDMI port now. This forces the macOS WindowServer and CoreGraphics pipelines to maintain active GPU framebuffers, preventing blank displays and severe latency when connecting via Screen Sharing (VNC).
   - **If you do not have one**: Leave the port disconnected. Headless terminal operations via SSH remain unaffected.
2. **Reboot**:
   - Apply all kernel parameters, `sysctl` modifications, and daemon registrations by rebooting the system:
   ```bash
   sudo reboot
   ```
3. **Verify Connectivity**:
   - From another workstation on the same network:
   ```bash
   # Connect via SSH
   ssh <TARGET_USERNAME>@macmini-node01.local

   # Connect via macOS Screen Sharing (VNC)
   open vnc://macmini-node01.local
   ```

---

## Logging & Backups

Every execution creates isolated artifacts within the script's root execution directory:
- **Execution Log**: `bootstrap_YYYYMMDD_HHMMSS.log` (captures combined `stdout` and `stderr` streams).
- **Configuration Backups**: `backups_YYYYMMDD_HHMMSS/` (stores untouched original copies of modified system configuration files like `/etc/sysctl.conf` and `/etc/ssh/sshd_config`).

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
