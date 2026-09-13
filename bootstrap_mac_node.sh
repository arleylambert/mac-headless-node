#!/usr/bin/env bash
set -uo pipefail

TARGET_USER="${1:-}"
NODE_HOSTNAME="${2:-}"

# ANSI Color Codes
CLR_RED="\033[1;31m"
CLR_GRN="\033[1;32m"
CLR_YEL="\033[1;33m"
CLR_BLU="\033[1;34m"
CLR_CYN="\033[1;36m"
CLR_RST="\033[0m"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo -e "${CLR_RED}Error: This script only supports macOS (Darwin). Detected: $(uname -s).${CLR_RST}"
    exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    echo -e "${CLR_RED}Error: This script targets Apple Silicon (arm64) Macs only. Detected: $(uname -m).${CLR_RST}"
    echo -e "${CLR_RED}Intel Macs lack the Unified Memory / iogpu tuning this script relies on.${CLR_RST}"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo -e "${CLR_RED}Error: This script must be run as root (sudo).${CLR_RST}"
    exit 1
fi

if [[ -z "$TARGET_USER" ]]; then
    echo -e "${CLR_RED}Error: Target username required as the first argument.${CLR_RST}"
    echo "Usage: sudo bash $0 <username> [node_hostname]"
    exit 1
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo -e "${CLR_RED}Error: Target user '$TARGET_USER' does not exist on this system.${CLR_RST}"
    exit 1
fi

# Optional hostname must be a valid RFC-1123 label if provided (letters, digits,
# hyphens; no leading/trailing hyphen) so scutil doesn't get fed something that
# breaks Bonjour/mDNS resolution.
if [[ -n "$NODE_HOSTNAME" ]] && ! [[ "$NODE_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo -e "${CLR_RED}Error: '$NODE_HOSTNAME' is not a valid hostname (letters, digits, hyphens only; cannot start/end with a hyphen).${CLR_RST}"
    exit 1
fi

# Local Log File and Backup Directory Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${SCRIPT_DIR}/bootstrap_${TIMESTAMP}.log"
BACKUP_DIR="${SCRIPT_DIR}/backups_${TIMESTAMP}"

mkdir -p "$BACKUP_DIR"
chown "$TARGET_USER" "$BACKUP_DIR"

touch "$LOG_FILE"
chown "$TARGET_USER" "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Redirect stdout and stderr simultaneously to terminal and log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${CLR_CYN}Host: $(sysctl -n hw.model 2>/dev/null || echo unknown) | macOS $(sw_vers -productVersion 2>/dev/null || echo unknown) (build $(sw_vers -buildVersion 2>/dev/null || echo unknown)) | $(uname -m)${CLR_RST}"

declare -a SUCCESS_STEPS=()
declare -a FAILED_STEPS=()

run_step() {
    local step_name="$1"
    shift
    echo -e "\n${CLR_BLU}[$(date '+%Y-%m-%d %H:%M:%S')] Executing: ${step_name}...${CLR_RST}"

    if "$@"; then
        echo -e "${CLR_GRN}✔ Success: ${step_name}${CLR_RST}"
        SUCCESS_STEPS+=("$step_name")
        return 0
    else
        local exit_code=$?
        echo -e "${CLR_RED}✖ Failure (Exit Code ${exit_code}): ${step_name}${CLR_RST}"
        FAILED_STEPS+=("$step_name (Code: $exit_code)")
        return 1
    fi
}

# --- Modular Functions ---
#
# Each function below tracks its own internal failures explicitly (rather than
# relying on the exit code of its last command) so that run_step's pass/fail
# report is accurate even when a function runs several independent commands.
# A sub-command that is genuinely optional (not supported on all macOS/chip
# combinations) stays non-fatal via `|| true` and is not counted as a failure.

set_hostname() {
    local current
    current=$(scutil --get ComputerName 2>/dev/null || echo "")
    if [[ "$current" == "$NODE_HOSTNAME" ]]; then
        echo "Hostname already set to '$NODE_HOSTNAME'. Skipping."
        return 0
    fi

    local ok=0
    scutil --set ComputerName "$NODE_HOSTNAME" || ok=1
    scutil --set HostName "$NODE_HOSTNAME" || ok=1
    scutil --set LocalHostName "$NODE_HOSTNAME" || ok=1
    dscacheutil -flushcache || ok=1
    return "$ok"
}

set_power_policies() {
    local ok=0
    pmset -a sleep 0 || ok=1
    pmset -a displaysleep 0 || ok=1
    pmset -a disksleep 0 2>/dev/null || true   # not present on all chip/OS combos
    pmset -a womp 1 || ok=1
    pmset -a autorestart 1 || ok=1
    pmset -a powernap 0 2>/dev/null || true    # not present on all chip/OS combos
    pmset -a tcpkeepalive 1 || ok=1
    pmset -a standby 0 2>/dev/null || true     # not present on all chip/OS combos
    pmset -a autopoweroff 0 2>/dev/null || true # not present on all chip/OS combos
    return "$ok"
}

set_high_power_mode() {
    local chip_model
    chip_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
    if [[ "$chip_model" != *"Pro"* && "$chip_model" != *"Max"* && "$chip_model" != *"Ultra"* ]]; then
        echo "Base-tier Apple Silicon chip detected ($chip_model). Standard thermal profile retained."
        return 0
    fi

    # macOS exposes "High Power Mode" via different pmset keys depending on
    # version/hardware. Try the known keys in order and only fail the step if
    # none of them are accepted on this machine.
    local key
    for key in highpowermode perfmode highpower; do
        if pmset -a "$key" 1 2>/dev/null; then
            echo "Enabled High Power Mode via 'pmset -a ${key} 1'."
            return 0
        fi
    done

    echo -e "${CLR_YEL}Warning: could not find a supported High Power Mode key (tried highpowermode/perfmode/highpower) on this macOS version. Skipping.${CLR_RST}"
    return 0
}

enable_remote_access() {
    local ok=0

    local remotelogin_status
    remotelogin_status=$(systemsetup -getremotelogin 2>/dev/null)
    if [[ "$remotelogin_status" == *"On"* ]]; then
        echo "Remote Login (SSH) already enabled. Skipping."
    else
        local remotelogin_output
        remotelogin_output=$(systemsetup -setremotelogin on 2>&1)
        if [[ $? -ne 0 ]]; then
            ok=1
            echo "$remotelogin_output"
            if [[ "$remotelogin_output" == *"Full Disk Access"* ]]; then
                echo -e "${CLR_YEL}Hint: macOS requires the app running this script (usually Terminal) to have Full Disk Access before 'systemsetup' can toggle Remote Login. This is a one-time GUI-only step Apple doesn't allow scripting around:${CLR_RST}"
                echo -e "${CLR_YEL}  System Settings -> Privacy & Security -> Full Disk Access -> enable it for Terminal (or whichever app is running this script) -> re-run this script.${CLR_RST}"
            fi
        fi
    fi

    if launchctl print system/com.apple.screensharing >/dev/null 2>&1; then
        echo "Screen Sharing already enabled. Skipping."
    else
        launchctl enable system/com.apple.screensharing || ok=1
        launchctl kickstart -k system/com.apple.screensharing 2>/dev/null || true
    fi
    return "$ok"
}

tune_ssh_keepalive() {
    local sshd_config="/etc/ssh/sshd_config"
    if [[ ! -f "$sshd_config" ]]; then
        echo -e "${CLR_YEL}Warning: ${sshd_config} not found. Skipping SSH keepalive tuning.${CLR_RST}"
        return 0
    fi

    if grep -q "^ClientAliveInterval 30" "$sshd_config" && grep -q "^ClientAliveCountMax 5" "$sshd_config"; then
        echo "SSH keepalive already configured (ClientAliveInterval 30 / ClientAliveCountMax 5). Skipping."
        return 0
    fi

    cp "$sshd_config" "${BACKUP_DIR}/sshd_config.bak" || return 1

    if grep -q "^ClientAliveInterval" "$sshd_config"; then
        sed -i '' 's/^ClientAliveInterval.*/ClientAliveInterval 30/' "$sshd_config" || return 1
    else
        echo "ClientAliveInterval 30" >> "$sshd_config"
    fi

    if grep -q "^ClientAliveCountMax" "$sshd_config"; then
        sed -i '' 's/^ClientAliveCountMax.*/ClientAliveCountMax 5/' "$sshd_config" || return 1
    else
        echo "ClientAliveCountMax 5" >> "$sshd_config"
    fi

    # sshd only picks up config changes on restart; this host reboots at the
    # end of the post-execution checklist, which covers it. If SSH is already
    # in active use and a reboot is deferred, restart it explicitly instead:
    #   sudo launchctl kickstart -k system/com.openssh.sshd
    return 0
}

disable_firewall() {
    local state
    state=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
    if [[ "$state" == *"disabled"* ]]; then
        echo "Application Firewall already disabled. Skipping."
        return 0
    fi
    /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off 2>/dev/null || true
}

remove_unneeded_apps() {
    local app ok=0
    for app in Keynote Numbers Pages GarageBand iMovie; do
        local path="/Applications/${app}.app"
        if [[ -e "$path" ]]; then
            rm -rf "$path" || ok=1
        else
            echo "${app}.app already removed (or never installed). Skipping."
        fi
    done
    return "$ok"
}

clean_dock_and_ui() {
    local ok=0
    su - "$TARGET_USER" -c 'defaults write com.apple.dock persistent-apps -array' || ok=1
    su - "$TARGET_USER" -c 'defaults write com.apple.dock show-recents -bool false' || ok=1
    su - "$TARGET_USER" -c 'defaults write com.apple.dock launchanim -bool false' || ok=1
    su - "$TARGET_USER" -c 'defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false' || ok=1
    su - "$TARGET_USER" -c 'defaults write -g QLPanelAnimationDuration -float 0' || ok=1
    su - "$TARGET_USER" -c 'defaults write NSGlobalDomain NSWindowResizeTime -float 0.001' || ok=1
    su - "$TARGET_USER" -c 'defaults write com.apple.CrashReporter DialogType none' || ok=1
    su - "$TARGET_USER" -c 'killall Dock 2>/dev/null || true'
    return "$ok"
}

disable_telemetry_and_siri() {
    local ok=0
    su - "$TARGET_USER" -c 'defaults write com.apple.assistant.support "Assistant Enabled" -bool false' || ok=1
    defaults write /Library/Preferences/com.apple.assistant.support "Assistant Enabled" -bool false || ok=1
    defaults write /Library/Preferences/com.apple.SubmitDiagInfo AutoSubmit -bool false || ok=1
    defaults write /Library/Preferences/com.apple.SubmitDiagInfo AutoSubmitVersion -int 4 || ok=1
    return "$ok"
}

set_manual_updates() {
    local ok=0
    defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false || ok=1
    defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false || ok=1
    return "$ok"
}

disable_spotlight() {
    if mdutil -s / 2>/dev/null | grep -q "Indexing disabled"; then
        echo "Spotlight indexing already disabled. Skipping."
        return 0
    fi
    mdutil -a -i off 2>/dev/null || true
}

set_unified_memory_limit() {
    local ok=0
    sysctl -w iogpu.wired_mem_limit=90 2>/dev/null || true

    if [[ -f /etc/sysctl.conf ]] && grep -q "^iogpu.wired_mem_limit=90$" /etc/sysctl.conf; then
        echo "/etc/sysctl.conf already has iogpu.wired_mem_limit=90. Skipping file edit."
        return "$ok"
    fi

    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf "${BACKUP_DIR}/sysctl.conf.bak" || ok=1
        if grep -q "iogpu.wired_mem_limit" /etc/sysctl.conf; then
            sed -i '' 's/iogpu.wired_mem_limit=.*/iogpu.wired_mem_limit=90/' /etc/sysctl.conf || ok=1
        else
            echo "iogpu.wired_mem_limit=90" >> /etc/sysctl.conf
        fi
    else
        echo "iogpu.wired_mem_limit=90" > /etc/sysctl.conf
    fi
    return "$ok"
}

set_maxfiles_limit() {
    local plist_path="/Library/LaunchDaemons/limit.maxfiles.plist"

    if [[ -f "$plist_path" ]] && launchctl print system/limit.maxfiles >/dev/null 2>&1; then
        echo "maxfiles LaunchDaemon already installed and loaded (524288/524288). Skipping."
        return 0
    fi

    cat <<EOF > "$plist_path"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>limit.maxfiles</string>
  <key>ProgramArguments</key>
  <array>
    <string>launchctl</string>
    <string>limit</string>
    <string>maxfiles</string>
    <string>524288</string>
    <string>524288</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>ServiceIPC</key>
  <false/>
</dict>
</plist>
EOF
    chown root:wheel "$plist_path" || return 1
    chmod 644 "$plist_path" || return 1
    launchctl bootstrap system "$plist_path" 2>/dev/null || launchctl load -w "$plist_path" 2>/dev/null || true
    return 0
}

install_dev_tools() {
    local ok=0

    # Xcode Command Line Tools (this is what actually provides `git` on a
    # clean macOS install). `xcode-select --install` pops an interactive GUI
    # dialog with no unattended equivalent, so use softwareupdate instead,
    # which can install it headlessly.
    if xcode-select -p >/dev/null 2>&1; then
        echo "Xcode Command Line Tools already installed."
    else
        local clt_placeholder="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
        touch "$clt_placeholder"

        local clt_label
        clt_label=$(softwareupdate -l 2>/dev/null | awk -F': ' '/Label: .*Command Line Tools/{print $2}' | tail -1)

        if [[ -n "$clt_label" ]]; then
            echo "Installing Command Line Tools via softwareupdate ($clt_label)..."
            softwareupdate -i "$clt_label" --verbose || ok=1
        else
            echo -e "${CLR_YEL}Warning: no Command Line Tools package found via 'softwareupdate -l' (needs internet, and availability varies by macOS version/region). Skipping — install manually later with 'xcode-select --install' or 'sudo softwareupdate -i <label>'.${CLR_RST}"
            ok=1
        fi

        rm -f "$clt_placeholder"
    fi

    # Homebrew's official install.sh performs several sudo-gated steps
    # (creating/chowning /opt/homebrew) that need an interactive password
    # prompt from TARGET_USER — not available when this runs unattended via
    # `su -c` inside an already-root script. Instead, do the one privileged
    # part ourselves (create + chown the prefix, since we're root already),
    # then extract the brew tarball directly as TARGET_USER with no sudo
    # calls left in the path at all. This is Homebrew's own documented
    # method for non-interactive/alternative installs.
    local brew_prefix="/opt/homebrew"
    if su - "$TARGET_USER" -c "command -v ${brew_prefix}/bin/brew" >/dev/null 2>&1; then
        echo "Homebrew already installed for $TARGET_USER."
    else
        echo "Installing Homebrew for $TARGET_USER (non-interactive, no sudo prompts)..."
        mkdir -p "$brew_prefix" || ok=1
        chown -R "${TARGET_USER}:admin" "$brew_prefix" 2>/dev/null || chown -R "$TARGET_USER" "$brew_prefix" || ok=1

        su - "$TARGET_USER" -c "curl -fsSL https://github.com/Homebrew/brew/tarball/main | tar xz --strip-components 1 -C '${brew_prefix}'" || ok=1

        # Put brew on PATH for future login shells (Apple Silicon prefix).
        local brew_shellenv='eval "$(/opt/homebrew/bin/brew shellenv)"'
        su - "$TARGET_USER" -c "grep -qxF '${brew_shellenv}' ~/.zprofile 2>/dev/null || echo '${brew_shellenv}' >> ~/.zprofile" || ok=1

        # First-run update, non-fatal (brew is already usable without it).
        su - "$TARGET_USER" -c "eval \"\$(${brew_prefix}/bin/brew shellenv)\" && brew update --force --quiet" >/dev/null 2>&1 || true
    fi

    return "$ok"
}

# --- Main Step Execution ---

if [[ -n "$NODE_HOSTNAME" ]]; then
    run_step "Configure Static Hostname ($NODE_HOSTNAME)" set_hostname
fi

run_step "Configure Power Policies (pmset)" set_power_policies
run_step "Configure High Power Mode (if supported)" set_high_power_mode
run_step "Enable Remote Login (SSH) and Screen Sharing" enable_remote_access
run_step "Configure SSH KeepAlive" tune_ssh_keepalive
run_step "Disable Application Firewall" disable_firewall
run_step "Remove Unneeded Native Apps (/Applications)" remove_unneeded_apps
run_step "Clean Dock and Optimize UI" clean_dock_and_ui
run_step "Disable Siri and Diagnostic Telemetry" disable_telemetry_and_siri
run_step "Configure Software Update to Manual Mode" set_manual_updates
run_step "Disable Spotlight Indexing" disable_spotlight
run_step "Configure Unified Memory Allocation Limit to 90%" set_unified_memory_limit
run_step "Increase Open File Limits (maxfiles)" set_maxfiles_limit
run_step "Install Xcode CLT (git) and Homebrew" install_dev_tools

# --- Execution Report & Post-Installation Instructions ---

echo -e "\n=================================================="
echo -e "                EXECUTION REPORT                  "
echo -e "=================================================="

echo -e "\n${CLR_GRN}--- SUCCESSFULLY EXECUTED STEPS (${#SUCCESS_STEPS[@]}) ---${CLR_RST}"
if [[ ${#SUCCESS_STEPS[@]} -gt 0 ]]; then
    for item in "${SUCCESS_STEPS[@]}"; do
        echo -e "${CLR_GRN} [✔] ${item}${CLR_RST}"
    done
fi

echo -e "\n${CLR_RED}--- FAILED STEPS (${#FAILED_STEPS[@]}) ---${CLR_RST}"
if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
    for item in "${FAILED_STEPS[@]}"; do
        echo -e "${CLR_RED} [✖] ${item}${CLR_RST}"
    done
else
    echo -e "${CLR_GRN}No failures reported.${CLR_RST}"
fi

echo -e "\n--------------------------------------------------"
if fdesetup status | grep -q "FileVault is On"; then
    echo -e "${CLR_RED}[!] CRITICAL WARNING: FileVault is currently ENABLED.${CLR_RST}"
    echo -e "${CLR_RED}    Unattended boots and auto-login after power cuts WILL FAIL.${CLR_RST}"
    echo -e "${CLR_RED}    Action Required: Run 'sudo fdesetup disable' before rebooting.${CLR_RST}"
else
    echo -e "${CLR_GRN}[✔] FileVault status: DISABLED (Ready for autonomous reboots).${CLR_RST}"
fi

echo -e "\n=================================================="
echo -e "           POST-EXECUTION INSTRUCTIONS            "
echo -e "=================================================="
echo -e "1. ${CLR_CYN}Display Hardware (Conditional):${CLR_RST}"
echo -e "   - If you have an active HDMI dummy plug available, plug it into the HDMI port now."
echo -e "     This keeps the GPU render pipeline awake during headless Screen Sharing sessions."
echo -e "   - If you do not have one, you can proceed without it; terminal SSH access will work"
echo -e "     identically, though Screen Sharing (VNC) might show a blank display until connected."
echo -e ""
echo -e "2. ${CLR_CYN}File Backups & Logs:${CLR_RST}"
echo -e "   - Original config backups saved to: ${CLR_BLU}${BACKUP_DIR}${CLR_RST}"
echo -e "   - Full execution log saved to:      ${CLR_BLU}${LOG_FILE}${CLR_RST}"
echo -e ""
echo -e "3. ${CLR_CYN}Finalize Setup:${CLR_RST}"
echo -e "   - Apply all kernel parameters, memory thresholds, and daemons by executing:"
echo -e "     ${CLR_YEL}sudo reboot${CLR_RST}"
echo -e "=================================================="
