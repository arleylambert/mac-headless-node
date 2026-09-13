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

set_hostname() {
    scutil --set ComputerName "$NODE_HOSTNAME"
    scutil --set HostName "$NODE_HOSTNAME"
    scutil --set LocalHostName "$NODE_HOSTNAME"
    dscacheutil -flushcache
}

set_power_policies() {
    pmset -a sleep 0
    pmset -a displaysleep 0
    pmset -a disksleep 0 2>/dev/null || true
    pmset -a womp 1
    pmset -a autorestart 1
    pmset -a powernap 0 2>/dev/null || true
    pmset -a tcpkeepalive 1
    pmset -a standby 0 2>/dev/null || true
    pmset -a autopoweroff 0 2>/dev/null || true
}

set_high_power_mode() {
    local chip_model
    chip_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
    if [[ "$chip_model" =~ "Pro" ]]; then
        if pmset -g cap | grep -q "perfmode"; then
            pmset -a perfmode 1
        elif pmset -g cap | grep -q "highpower"; then
            pmset -a highpower 1
        fi
    else
        echo "Base M4 chip detected ($chip_model). Standard thermal profile retained."
    fi
}

enable_remote_access() {
    systemsetup -setremotelogin on
    launchctl enable system/com.apple.screensharing
    launchctl kickstart -k system/com.apple.screensharing 2>/dev/null || true
}

tune_ssh_keepalive() {
    local sshd_config="/etc/ssh/sshd_config"
    if [[ -f "$sshd_config" ]]; then
        cp "$sshd_config" "${BACKUP_DIR}/sshd_config.bak"
        grep -q "^ClientAliveInterval" "$sshd_config" && \
            sed -i '' 's/^ClientAliveInterval.*/ClientAliveInterval 30/' "$sshd_config" || \
            echo "ClientAliveInterval 30" >> "$sshd_config"
        grep -q "^ClientAliveCountMax" "$sshd_config" && \
            sed -i '' 's/^ClientAliveCountMax.*/ClientAliveCountMax 5/' "$sshd_config" || \
            echo "ClientAliveCountMax 5" >> "$sshd_config"
    fi
}

disable_firewall() {
    /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off 2>/dev/null || true
}

remove_unneeded_apps() {
    rm -rf /Applications/Keynote.app \
           /Applications/Numbers.app \
           /Applications/Pages.app \
           /Applications/GarageBand.app \
           /Applications/iMovie.app 2>/dev/null || true
}

clean_dock_and_ui() {
    su - "$TARGET_USER" -c 'defaults write com.apple.dock persistent-apps -array'
    su - "$TARGET_USER" -c 'defaults write com.apple.dock show-recents -bool false'
    su - "$TARGET_USER" -c 'defaults write com.apple.dock launchanim -bool false'
    su - "$TARGET_USER" -c 'defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false'
    su - "$TARGET_USER" -c 'defaults write -g QLPanelAnimationDuration -float 0'
    su - "$TARGET_USER" -c 'defaults write NSGlobalDomain NSWindowResizeTime -float 0.001'
    su - "$TARGET_USER" -c 'defaults write com.apple.CrashReporter DialogType none'
    su - "$TARGET_USER" -c 'killall Dock 2>/dev/null || true'
}

disable_telemetry_and_siri() {
    su - "$TARGET_USER" -c 'defaults write com.apple.assistant.support "Assistant Enabled" -bool false'
    defaults write /Library/Preferences/com.apple.assistant.support "Assistant Enabled" -bool false
    defaults write /Library/Preferences/com.apple.SubmitDiagInfo AutoSubmit -bool false
    defaults write /Library/Preferences/com.apple.SubmitDiagInfo AutoSubmitVersion -int 4
}

set_manual_updates() {
    defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
    defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
}

disable_spotlight() {
    mdutil -a -i off 2>/dev/null || true
}

set_unified_memory_limit() {
    sysctl -w iogpu.wired_mem_limit=90 2>/dev/null || true
    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf "${BACKUP_DIR}/sysctl.conf.bak"
        if grep -q "iogpu.wired_mem_limit" /etc/sysctl.conf; then
            sed -i '' 's/iogpu.wired_mem_limit=.*/iogpu.wired_mem_limit=90/' /etc/sysctl.conf
        else
            echo "iogpu.wired_mem_limit=90" >> /etc/sysctl.conf
        fi
    else
        echo "iogpu.wired_mem_limit=90" > /etc/sysctl.conf
    fi
}

set_maxfiles_limit() {
    local plist_path="/Library/LaunchDaemons/limit.maxfiles.plist"
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
    chown root:wheel "$plist_path"
    chmod 644 "$plist_path"
    launchctl load -w "$plist_path" 2>/dev/null || true
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