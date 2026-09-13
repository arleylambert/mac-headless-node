#!/usr/bin/env bash
set -uo pipefail

TARGET_USER_ARG="${1:-}"
NODE_HOSTNAME_ARG="${2:-}"

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

# --- Resolve TARGET_USER / NODE_HOSTNAME: argument > saved value from a
# previous successful run > empty. A value passed on the command line always
# wins and becomes the new saved value once preflight checks pass below.
STATE_FILE="/etc/mac-headless-node.env"
SAVED_TARGET_USER=""
SAVED_NODE_HOSTNAME=""
if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
fi

TARGET_USER_SOURCE=""
if [[ -n "$TARGET_USER_ARG" ]]; then
    TARGET_USER="$TARGET_USER_ARG"
    TARGET_USER_SOURCE="argument"
elif [[ -n "$SAVED_TARGET_USER" ]]; then
    TARGET_USER="$SAVED_TARGET_USER"
    TARGET_USER_SOURCE="saved"
else
    TARGET_USER=""
fi

NODE_HOSTNAME_SOURCE=""
if [[ -n "$NODE_HOSTNAME_ARG" ]]; then
    NODE_HOSTNAME="$NODE_HOSTNAME_ARG"
    NODE_HOSTNAME_SOURCE="argument"
elif [[ -n "$SAVED_NODE_HOSTNAME" ]]; then
    NODE_HOSTNAME="$SAVED_NODE_HOSTNAME"
    NODE_HOSTNAME_SOURCE="saved"
else
    NODE_HOSTNAME=""
fi

# --- Local Log File and Backup Directory Configuration ---
# Set up logging now (before preflight checks run) so the preflight output
# and the "using saved value" notes below all end up in the log too.
# Ownership of these paths is fixed to TARGET_USER once preflight confirms
# it's a real user.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${SCRIPT_DIR}/bootstrap_${TIMESTAMP}.log"
BACKUP_DIR="${SCRIPT_DIR}/backups_${TIMESTAMP}"

mkdir -p "$BACKUP_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Redirect stdout and stderr simultaneously to terminal and log file
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ "$TARGET_USER_SOURCE" == "saved" ]]; then
    echo -e "${CLR_CYN}Using saved target user '${TARGET_USER}' from a previous run (${STATE_FILE}). Pass a username explicitly to use a different one.${CLR_RST}"
fi
if [[ "$NODE_HOSTNAME_SOURCE" == "saved" ]]; then
    echo -e "${CLR_CYN}Using saved hostname '${NODE_HOSTNAME}' from a previous run (${STATE_FILE}). Pass a hostname explicitly to use a different one.${CLR_RST}"
fi

# --- Preflight Checks ---
#
# Everything below is checked *before* the script touches the system at all.
# Every problem found is collected and printed together with the exact steps
# to fix it, instead of failing once, getting fixed, re-run, failing on the
# next thing, etc.

declare -a PREFLIGHT_ERRORS=()

if [[ -z "$TARGET_USER" ]]; then
    PREFLIGHT_ERRORS+=("Target username required as the first argument (no saved value found from a previous run).
      Usage: sudo bash $0 <username> [node_hostname]
      Once this succeeds with a username, future runs can omit it entirely
      -- it's remembered in ${STATE_FILE}.")
elif ! id "$TARGET_USER" >/dev/null 2>&1; then
    if [[ "$TARGET_USER_SOURCE" == "saved" ]]; then
        PREFLIGHT_ERRORS+=("Target user '$TARGET_USER' (saved from a previous run in ${STATE_FILE}) no longer exists on this system.
          Pass a different, existing username explicitly as the first argument,
          or delete ${STATE_FILE} to clear the saved value.")
    else
        PREFLIGHT_ERRORS+=("Target user '$TARGET_USER' does not exist on this system.
          Create it first (System Settings -> Users & Groups -> Add Account),
          or pass the correct existing username as the first argument.")
    fi
fi

# Optional hostname must be a valid RFC-1123 label if provided (letters, digits,
# hyphens; no leading/trailing hyphen) so scutil doesn't get fed something that
# breaks Bonjour/mDNS resolution.
if [[ -n "$NODE_HOSTNAME" ]] && ! [[ "$NODE_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    PREFLIGHT_ERRORS+=("'$NODE_HOSTNAME' is not a valid hostname (letters, digits, hyphens only; cannot start/end with a hyphen).
      Example of a valid hostname: macmini-node01")
fi

if fdesetup status 2>/dev/null | grep -q "FileVault is On"; then
    PREFLIGHT_ERRORS+=("FileVault is currently ENABLED. This script assumes it's off so the
      machine can auto-login and reboot unattended after a power cut (see
      SECURITY.md for that trade-off). To disable it:
        1. Check status:   fdesetup status
        2. Disable it:     sudo fdesetup disable
        3. Follow the prompts (may require a reboot to fully apply, then
           re-run this script)")
fi

# Best-effort, and known to be unreliable: the 'Enable Remote Login' step
# later needs Full Disk Access granted to whatever app is running this script
# (usually Terminal), which macOS only lets a human grant via the GUI. There's
# no supported way to query that grant directly. This probes the read-only
# equivalent of the command that will actually fail -- but 'systemsetup
# -getremotelogin' is a read, and only the write path ('-setremotelogin')
# has been observed to actually require Full Disk Access, so this check may
# simply never trigger even when FDA is missing. It's left in because it's
# harmless and *might* catch it on some macOS versions, but don't rely on it:
# the real safety net is that 'enable_remote_access' further down still
# fails cleanly with the same actionable instructions if this doesn't catch
# it first -- confirmed against real Mac mini M4 hardware.
fda_probe=$(systemsetup -getremotelogin 2>&1)
if [[ "$fda_probe" == *"Full Disk Access"* ]]; then
    PREFLIGHT_ERRORS+=("Full Disk Access is not granted to the app running this script
      (usually Terminal). macOS requires this before 'systemsetup' can read
      or change Remote Login (SSH). To fix:
        1. Open System Settings -> Privacy & Security -> Full Disk Access
        2. Enable the toggle for Terminal (or whichever app is running this
           script)
        3. Re-run this script")
fi

if [[ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]]; then
    echo -e "${CLR_RED}=================================================="
    echo -e "     ${#PREFLIGHT_ERRORS[@]} PREFLIGHT CHECK(S) FAILED — NOTHING WAS CHANGED     "
    echo -e "==================================================${CLR_RST}"
    i=1
    for err in "${PREFLIGHT_ERRORS[@]}"; do
        echo -e "${CLR_RED}[$i] ${err}${CLR_RST}"
        echo ""
        i=$((i + 1))
    done
    echo -e "${CLR_YEL}Fix the item(s) above, then re-run this script.${CLR_RST}"
    exit 1
fi

echo -e "${CLR_GRN}Preflight checks passed.${CLR_RST}"

# Fix ownership now that we know TARGET_USER is a real, existing user
# (log/backup dir were created earlier, before preflight, so the log could
# capture preflight output too).
chown "$TARGET_USER" "$BACKUP_DIR"
chown "$TARGET_USER" "$LOG_FILE"

# Persist the resolved values so future runs don't need them passed again --
# a plain re-run of this script (e.g. after fixing a failed step) will pick
# these back up automatically and just say so.
cat > "$STATE_FILE" <<STATEEOF
SAVED_TARGET_USER="${TARGET_USER}"
SAVED_NODE_HOSTNAME="${NODE_HOSTNAME}"
STATEEOF
chmod 600 "$STATE_FILE"

echo -e "${CLR_CYN}Host: $(sysctl -n hw.model 2>/dev/null || echo unknown) | macOS $(sw_vers -productVersion 2>/dev/null || echo unknown) (build $(sw_vers -buildVersion 2>/dev/null || echo unknown)) | $(uname -m)${CLR_RST}"

declare -a SUCCESS_STEPS=()
declare -a FAILED_STEPS=()
FDA_SSH_ISSUE=0

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
    # pmset is known to silently accept keys it doesn't actually recognize
    # (exit 0, no effect), so a successful exit code alone isn't proof the
    # setting stuck -- read it back from 'pmset -g custom' before trusting it.
    local key
    for key in highpowermode perfmode highpower; do
        if pmset -a "$key" 1 2>/dev/null; then
            if pmset -g custom 2>/dev/null | grep -qE "^[[:space:]]*${key}[[:space:]]+1"; then
                echo "Enabled High Power Mode via 'pmset -a ${key} 1' (confirmed via 'pmset -g custom')."
                return 0
            fi
            echo -e "${CLR_YEL}'pmset -a ${key} 1' exited successfully but the setting doesn't show up in 'pmset -g custom' -- this macOS version likely doesn't support that key. Trying the next one.${CLR_RST}"
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
                FDA_SSH_ISSUE=1
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

    local backup="${BACKUP_DIR}/sshd_config.bak"
    cp "$sshd_config" "$backup" || return 1

    if grep -q "^ClientAliveInterval" "$sshd_config"; then
        sed -i '' 's/^ClientAliveInterval.*/ClientAliveInterval 30/' "$sshd_config" || { cp "$backup" "$sshd_config"; return 1; }
    else
        echo "ClientAliveInterval 30" >> "$sshd_config"
    fi

    if grep -q "^ClientAliveCountMax" "$sshd_config"; then
        sed -i '' 's/^ClientAliveCountMax.*/ClientAliveCountMax 5/' "$sshd_config" || { cp "$backup" "$sshd_config"; return 1; }
    else
        echo "ClientAliveCountMax 5" >> "$sshd_config"
    fi

    # This machine is fully headless -- a broken sshd_config would mean losing
    # SSH for good until someone gets physical/Screen Sharing access. Validate
    # the edited file before trusting it, and restore the pristine backup
    # immediately if it doesn't pass, rather than leaving a bad config in
    # place until the next reboot surfaces the problem.
    local test_output
    if ! test_output=$(sshd -t -f "$sshd_config" 2>&1); then
        echo -e "${CLR_RED}sshd_config failed validation after edit -- restoring original from backup:${CLR_RST}"
        echo "$test_output"
        cp "$backup" "$sshd_config"
        return 1
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

    local ok=0
    /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off || ok=1
    return "$ok"
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

    # Pin Terminal.app back into the now-empty Dock -- useful for headless
    # boxes accessed over Screen Sharing, where you still want one-click
    # access to a shell. Rebuilt from scratch every run (clear, then add),
    # so this is idempotent by construction rather than needing its own
    # "already pinned?" check.
    local candidate term_path=""
    for candidate in "/System/Applications/Utilities/Terminal.app" "/Applications/Utilities/Terminal.app"; do
        if [[ -d "$candidate" ]]; then
            term_path="$candidate"
            break
        fi
    done
    if [[ -n "$term_path" ]]; then
        local dock_entry="<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>${term_path}</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
        su - "$TARGET_USER" -c "defaults write com.apple.dock persistent-apps -array-add '${dock_entry}'" || ok=1
    else
        echo -e "${CLR_YEL}Warning: could not find Terminal.app in the usual locations. Skipping Dock pin.${CLR_RST}"
    fi

    su - "$TARGET_USER" -c 'defaults write com.apple.dock show-recents -bool false' || ok=1
    su - "$TARGET_USER" -c 'defaults write com.apple.dock launchanim -bool false' || ok=1
    su - "$TARGET_USER" -c 'defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false' || ok=1
    su - "$TARGET_USER" -c 'defaults write -g QLPanelAnimationDuration -float 0' || ok=1
    su - "$TARGET_USER" -c 'defaults write NSGlobalDomain NSWindowResizeTime -float 0.001' || ok=1
    su - "$TARGET_USER" -c 'defaults write com.apple.CrashReporter DialogType none' || ok=1
    su - "$TARGET_USER" -c 'killall Dock 2>/dev/null || true'
    return "$ok"
}

set_black_wallpaper() {
    local wallpaper_dir="/Library/Desktop Pictures"
    local wallpaper_path="${wallpaper_dir}/headless-black.png"

    if [[ ! -f "$wallpaper_path" ]]; then
        mkdir -p "$wallpaper_dir" || return 1
        # A minimal, valid 1x1 solid-black PNG (macOS scales it to fill the
        # screen) -- avoids depending on any image tool being installed yet.
        printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\x60\x60\x60\x00\x00\x00\x04\x00\x01\xf6\x178U\x00\x00\x00\x00IEND\xaeB\x60\x82' > "$wallpaper_path" || return 1
        chmod 644 "$wallpaper_path"
    fi

    # Setting the desktop picture goes through System Events (there's no
    # 'defaults write' for this on modern macOS), which can require a
    # one-time "Automation" permission grant for the app running this
    # script -- the same category of manual, GUI-only TCC gate as Full Disk
    # Access for SSH, just for a purely cosmetic setting. Report failure
    # honestly rather than assume it worked.
    local ok=0
    su - "$TARGET_USER" -c "osascript -e 'tell application \"System Events\" to tell every desktop to set picture to \"${wallpaper_path}\"'" || ok=1
    if [[ "$ok" -eq 1 ]]; then
        echo -e "${CLR_YEL}Could not set the desktop wallpaper via System Events -- this can require a one-time 'Automation' permission grant (System Settings -> Privacy & Security -> Automation -> allow Terminal to control 'System Events'), similar to Full Disk Access for SSH. Purely cosmetic and non-blocking -- re-run after granting it if you want the wallpaper applied.${CLR_RST}"
    else
        echo "Desktop wallpaper set to solid black ($wallpaper_path)."
    fi
    return "$ok"
}

hide_desktop_icons_and_widgets() {
    local ok=0

    local current_icons current_widgets
    current_icons=$(su - "$TARGET_USER" -c 'defaults read com.apple.finder CreateDesktop' 2>/dev/null || echo "")
    current_widgets=$(su - "$TARGET_USER" -c 'defaults read com.apple.WindowManager StandardHideWidgets' 2>/dev/null || echo "")

    if [[ "$current_icons" == "0" && "$current_widgets" == "1" ]]; then
        echo "Desktop icons and widgets already hidden (CreateDesktop=false, StandardHideWidgets=true). Skipping."
        return "$ok"
    fi

    # CreateDesktop hides regular Finder desktop icons -- long-established,
    # confirmed on real hardware. It does NOT touch the 3 default macOS
    # desktop widgets (Weather, Calendar, Photos); that's a separate toggle,
    # StandardHideWidgets, which is what System Settings -> Desktop & Dock ->
    # Widgets -> Show Widgets -> "On Desktop" actually flips under the hood.
    su - "$TARGET_USER" -c 'defaults write com.apple.finder CreateDesktop -bool false' || ok=1
    su - "$TARGET_USER" -c 'defaults write com.apple.WindowManager StandardHideWidgets -bool true' || ok=1

    su - "$TARGET_USER" -c 'killall Finder 2>/dev/null || true'
    su - "$TARGET_USER" -c 'killall Dock 2>/dev/null || true'

    echo "Desktop icons hidden and widgets disabled (CreateDesktop=false, StandardHideWidgets=true)."
    echo -e "${CLR_YEL}Note: this stops the 3 default widgets (Weather, Calendar, Photos) from displaying, but macOS may not reclaim the space they occupied. Not personally confirmed on this hardware yet -- if a widget is still visible after a reboot, right-click it and choose 'Remove Widget' as a manual fallback.${CLR_RST}"
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

    local ok=0
    mdutil -a -i off || ok=1
    return "$ok"
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
    local desired=524288

    # Check the *actual* effective limit (not just "is our daemon loaded") so
    # a stale plist with different numbers, or one that failed to apply, isn't
    # mistaken for "already configured".
    local soft hard
    read -r _ soft hard < <(launchctl limit maxfiles 2>/dev/null)

    if [[ -f "$plist_path" && "$soft" == "$desired" && "$hard" == "$desired" ]]; then
        echo "maxfiles limit already at ${desired}/${desired} (LaunchDaemon installed and loaded). Skipping."
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

    local ok=0
    if ! launchctl bootstrap system "$plist_path" 2>/dev/null; then
        launchctl load -w "$plist_path" 2>/dev/null || ok=1
    fi

    read -r _ soft hard < <(launchctl limit maxfiles 2>/dev/null)
    if [[ "$soft" != "$desired" || "$hard" != "$desired" ]]; then
        echo -e "${CLR_YEL}Warning: maxfiles limit reports ${soft:-?}/${hard:-?} after loading the daemon, not ${desired}/${desired}. It may need a reboot to fully take effect.${CLR_RST}"
    fi
    return "$ok"
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

        su - "$TARGET_USER" -c "set -o pipefail; curl -fsSL https://github.com/Homebrew/brew/tarball/main | tar xz --strip-components 1 -C '${brew_prefix}'" || ok=1

        # Put brew on PATH for future login shells (Apple Silicon prefix).
        # Guarded with [[ -x ... ]] so a login shell never prints a "no such
        # file" error during the brief window before brew actually exists
        # (e.g. mid-install, or if it's ever removed later). An older run of
        # this script may have already appended the unguarded version; once
        # brew actually exists that line is harmless, so it's left alone
        # rather than risk a fragile in-place edit of the user's dotfile.
        local brew_shellenv='[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"'
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
run_step "Set Solid Black Wallpaper" set_black_wallpaper
run_step "Hide Desktop Icons and Widgets" hide_desktop_icons_and_widgets
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

if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
    echo -e "\n${CLR_RED}--- FAILED STEPS (${#FAILED_STEPS[@]}) ---${CLR_RST}"
    for item in "${FAILED_STEPS[@]}"; do
        echo -e "${CLR_RED} [✖] ${item}${CLR_RST}"
    done
else
    echo -e "\n${CLR_GRN}No failures reported.${CLR_RST}"
fi

if [[ "$FDA_SSH_ISSUE" == "1" ]]; then
    echo -e "\n${CLR_RED}=================================================="
    echo -e "  ACTION REQUIRED: FULL DISK ACCESS FOR SSH / SCREEN SHARING  "
    echo -e "==================================================${CLR_RST}"
    echo -e "${CLR_YEL}Remote Login (SSH) could not be turned on. macOS requires Full Disk Access"
    echo -e "for whichever app is running this script (usually Terminal) before"
    echo -e "'systemsetup' is allowed to toggle it -- a one-time, GUI-only step Apple"
    echo -e "doesn't allow scripting around.${CLR_RST}"
    echo -e ""
    echo -e "${CLR_CYN}To fix it:${CLR_RST}"
    echo -e "  1. Open System Settings -> Privacy & Security -> Full Disk Access"
    echo -e "  2. Enable the toggle for Terminal (or whichever app is running this script)"
    echo -e "  3. Re-run this script: ${CLR_YEL}sudo $0${CLR_RST}"
    echo -e "     (TARGET_USER/NODE_HOSTNAME are already saved -- no need to pass them again)"
    echo -e ""
    echo -e "${CLR_RED}Security consideration:${CLR_RST} Full Disk Access is a broad grant, not a"
    echo -e "narrow one for this one setting. Once enabled for an app, anything that runs"
    echo -e "inside it (including this script, or any other command you run there later)"
    echo -e "can read virtually every file on this Mac -- Mail, Photos, Messages, Time"
    echo -e "Machine backups, other users' home directories -- bypassing the per-app"
    echo -e "privacy prompts macOS normally shows. It's only actually needed for this one"
    echo -e "'systemsetup -setremotelogin' call; SSH keeps working fine afterward without"
    echo -e "it. Once this step succeeds, you can safely revoke Full Disk Access from that"
    echo -e "app again (same System Settings screen) if you'd rather not leave it granted"
    echo -e "long-term."
fi

echo -e "\n--------------------------------------------------"
# FileVault is guaranteed to be off here -- the preflight check at the top of
# this script aborts before touching anything if it's still on, so there's no
# code path that reaches this point with FileVault enabled.
echo -e "${CLR_GRN}[✔] FileVault status: DISABLED (verified during preflight; ready for autonomous reboots).${CLR_RST}"

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
