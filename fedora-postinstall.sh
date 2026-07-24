#!/usr/bin/env bash
#
# fedora-postinstall.sh (v3) — Opinionated Fedora Workstation post-install
#
# Default sections (run in order):
#   base     dnf tuning, update, RPM Fusion, firmware (LVFS), boot tweak, update-all
#   codecs   full ffmpeg, GStreamer, per-GPU hardware video acceleration
#   nvidia   proprietary driver + CUDA/NVENC + Secure Boot signing (auto-detected)
#   flatpak  Flathub (unfiltered) + Flatseal + Extension Manager
#   gaming   Steam, steam-devices, gamescope, MangoHud, GOverlay, vkBasalt,
#            GameMode, protontricks, ProtonPlus, vm.max_map_count tweak
#   snapper  Btrfs snapshots + Btrfs Assistant GUI
#   media    OBS Studio + virtual camera (v4l2loopback), mpv, yt-dlp
#   dev      git/tooling, Docker CE, nvm (Node), uv (Python), VS Code
#   virt     KVM/QEMU + virt-manager
#   qol      archives, fonts, monitors, tldr, GNOME tweaks
#
# Optional sections (only with --with):
#   legion      LenovoLegionLinux (fan curves / power modes, community module)
#   asus        asusctl + supergfxctl (ASUS laptops, asus-linux.org COPR)
#   distrobox   containerized dev environments (Podman-backed)
#   wine        Wine + winetricks (non-Steam Windows software)
#   lutris      Lutris game launcher (Epic/GOG/emulators/install scripts)
#   faugus      Faugus Launcher — minimal UMU/Proton launcher for Windows games
#   gametweaks  scx_lavd scheduler as a TOGGLE (stock kernel), split_lock_detect=off
#   creative    GIMP, Inkscape, Kdenlive, Audacity, Blender
#   apps        Discord (Vesktop), Spotify, Telegram — Flatpaks
#
# Runtime toggles (after gametweaks is installed):
#   sudo ./fedora-postinstall.sh --scx on|off|status|boot-on|boot-off
#   (or the installed shortcut:  scx-toggle on|off|status|boot-on|boot-off)
#   on/off    = this session only (game session vs compile session)
#   boot-on/off = persist across reboots
#   AUTO: games launched with 'gamemoderun %command%' flip scx_lavd on/off themselves.
#
# Desktop-aware: GNOME and KDE Plasma both supported — GNOME gets Extension
# Manager/Tweaks/file-roller, KDE gets ark/filelight; shared bits unchanged.
#
# Usage:
#   sudo ./fedora-postinstall.sh                      # all defaults, auto GPU
#   sudo ./fedora-postinstall.sh --menu               # interactive section picker
#   sudo ./fedora-postinstall.sh --no-nvidia          # skip NVIDIA even if present
#   sudo ./fedora-postinstall.sh --with legion,gametweaks
#   sudo ./fedora-postinstall.sh --parallel 1               # bad network: serial downloads
#   sudo ./fedora-postinstall.sh --parallel 10              # force max parallelism
#   sudo ./fedora-postinstall.sh --only codecs,gaming
#   sudo ./fedora-postinstall.sh --skip virt,media
#   sudo ./fedora-postinstall.sh --list
#
# Safe to re-run: every step is idempotent.

set -uo pipefail

# ---------------------------------------------------------------------------
# Globals & helpers
# ---------------------------------------------------------------------------
LOG_FILE="/var/log/fedora-postinstall.log"
DEFAULT_SECTIONS=(base codecs nvidia flatpak gaming snapper media dev virt qol)
OPTIONAL_SECTIONS=(legion asus distrobox wine lutris faugus gametweaks creative apps)
FORCE_NVIDIA=""          # "", "yes", "no"
ONLY_SECTIONS=""
SKIP_SECTIONS=""
WITH_SECTIONS=""
FAILED_STEPS=()
NVM_VERSION="v0.40.3"    # bump when nvm releases; check github.com/nvm-sh/nvm
PARALLEL_DL=""           # "" = auto-detect from network probe; or forced via --parallel N
MENU_MODE=""             # "yes" = show the interactive section picker before running

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${BLUE}[*]${NC} $*" | tee -a "$LOG_FILE"; }
ok()     { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()    { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE"; }
header() { echo -e "\n${BOLD}==> $*${NC}\n" | tee -a "$LOG_FILE"; }

# Run a step; record failure but keep going (one bad repo shouldn't kill the run)
step() {
    local desc="$1"; shift
    log "$desc"
    if "$@" >>"$LOG_FILE" 2>&1; then
        ok "$desc"
    else
        err "FAILED: $desc (see $LOG_FILE)"
        FAILED_STEPS+=("$desc")
    fi
}

# Like step, but failure is logged without polluting the failure summary
# (for genuinely optional packages that vary across Fedora releases).
step_soft() {
    local desc="$1"; shift
    log "$desc"
    if "$@" >>"$LOG_FILE" 2>&1; then ok "$desc"; else warn "skipped (optional): $desc"; fi
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Run with sudo: sudo $0 $*"
        exit 1
    fi
}

require_fedora() {
    if ! grep -qi "fedora" /etc/os-release; then
        err "This script targets Fedora. Aborting."
        exit 1
    fi
    FEDORA_VER=$(rpm -E %fedora)
    log "Detected Fedora $FEDORA_VER"
}

# The real (non-root) user, for flatpak/nvm/user-level operations
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

as_user() { sudo -u "$REAL_USER" bash -c "$1"; }

has_nvidia_gpu() { lspci -nn | grep -Ei 'vga|3d' | grep -qi nvidia; }
has_amd_gpu()    { lspci -nn | grep -Ei 'vga|3d' | grep -qEi 'amd|radeon'; }
has_intel_gpu()  { lspci -nn | grep -Ei 'vga|3d' | grep -qi intel; }
has_gnome()      { rpm -q gnome-shell >/dev/null 2>&1; }
has_kde()        { rpm -q plasma-desktop >/dev/null 2>&1 || rpm -q plasma-workspace >/dev/null 2>&1; }

section_enabled() {
    local s="$1"
    if [[ -n "$ONLY_SECTIONS" ]]; then
        [[ ",$ONLY_SECTIONS," == *",$s,"* ]] && return 0 || return 1
    fi
    for opt in "${OPTIONAL_SECTIONS[@]}"; do
        if [[ "$s" == "$opt" ]]; then
            [[ ",$WITH_SECTIONS," == *",$s,"* ]] && return 0 || return 1
        fi
    done
    [[ ",$SKIP_SECTIONS," == *",$s,"* ]] && return 1
    return 0
}

# Set (replace or append) a key=value in dnf.conf — idempotent, updates stale values
set_dnf_opt() {
    local key="$1" val="$2"
    if grep -q "^${key}=" /etc/dnf/dnf.conf; then
        sed -i "s/^${key}=.*/${key}=${val}/" /etc/dnf/dnf.conf
    else
        echo "${key}=${val}" >> /etc/dnf/dnf.conf
    fi
}

# Probe network quality and pick a parallel-download count.
# Uses a small fetch from Fedora's mirror service; TCP slow-start means small
# files UNDER-estimate bandwidth, which errs toward fewer streams — the safe
# direction on bad networks.
probe_parallel_downloads() {
    local speed
    speed=$(curl -sL --max-time 8 -o /dev/null -w '%{speed_download}' \
        "https://mirrors.fedoraproject.org/metalink?repo=fedora-${FEDORA_VER}&arch=x86_64" \
        2>/dev/null | cut -d. -f1)
    speed=${speed:-0}

    if [[ "$speed" -eq 0 ]]; then
        echo 1   # probe failed/timed out → assume the worst
    elif [[ "$speed" -lt 204800 ]]; then      # < 200 KB/s
        echo 1
    elif [[ "$speed" -lt 1572864 ]]; then     # < 1.5 MB/s
        echo 4
    else
        echo 10
    fi
}

# One-line descriptions for the interactive picker (--menu). Keys must match
# DEFAULT_SECTIONS / OPTIONAL_SECTIONS entries.
declare -A SECTION_DESC=(
    [base]="dnf tuning, update, RPM Fusion, firmware, boot tweak"
    [codecs]="full ffmpeg, GStreamer, hardware video acceleration"
    [nvidia]="proprietary driver + CUDA/NVENC (auto-skips if no NVIDIA)"
    [flatpak]="Flathub + Flatseal + Extension Manager"
    [gaming]="Steam, gamescope, MangoHud, GameMode, ProtonPlus"
    [snapper]="Btrfs snapshots + Btrfs Assistant GUI"
    [media]="OBS Studio + virtual camera, mpv, yt-dlp"
    [dev]="git tooling, Docker CE, nvm, uv, VS Code"
    [virt]="KVM/QEMU + virt-manager"
    [qol]="fonts, archives, monitors, GNOME tweaks"
    [legion]="LenovoLegionLinux fan/power control (community)"
    [asus]="asusctl + supergfxctl (ASUS laptops)"
    [distrobox]="containerized dev environments (Podman)"
    [wine]="Wine + winetricks (non-Steam Windows software)"
    [lutris]="launcher for Epic/GOG/emulators/install scripts"
    [faugus]="minimal UMU/Proton launcher for Windows games"
    [gametweaks]="scx_lavd game-mode toggle, split-lock off"
    [creative]="GIMP, Inkscape, Kdenlive, Audacity, Blender"
    [apps]="Discord (Vesktop), Spotify, Telegram (Flatpaks)"
)

# Interactive section picker. Defaults start checked, optionals unchecked.
# The result is written into ONLY_SECTIONS so exactly the checked set runs.
run_menu() {
    if [[ ! -t 0 ]]; then
        err "--menu needs an interactive terminal (stdin is not a TTY)"
        exit 1
    fi

    local all=("${DEFAULT_SECTIONS[@]}" "${OPTIONAL_SECTIONS[@]}")
    declare -A checked
    local s
    for s in "${DEFAULT_SECTIONS[@]}";  do checked[$s]=1; done
    for s in "${OPTIONAL_SECTIONS[@]}"; do checked[$s]=0; done

    local reply i tok
    while true; do
        clear 2>/dev/null || true
        echo -e "${BOLD}==> Select sections${NC}  (defaults pre-checked; optionals off)"
        echo -e "    number = toggle | 'a' all | 'n' none | 'd' defaults | Enter = install | q = quit\n"
        i=1
        for s in "${all[@]}"; do
            local mark=" "
            [[ ${checked[$s]} -eq 1 ]] && mark="x"
            printf "  %2d) [%s] %-11s %s\n" "$i" "$mark" "$s" "${SECTION_DESC[$s]:-}"
            ((i++))
        done
        echo
        read -rp "> " reply || { echo; err "Cancelled."; exit 0; }
        case "$reply" in
            "")   break ;;
            q|Q)  echo "Cancelled."; exit 0 ;;
            a|A)  for s in "${all[@]}"; do checked[$s]=1; done ;;
            n|N)  for s in "${all[@]}"; do checked[$s]=0; done ;;
            d|D)  for s in "${DEFAULT_SECTIONS[@]}";  do checked[$s]=1; done
                  for s in "${OPTIONAL_SECTIONS[@]}"; do checked[$s]=0; done ;;
            *)    for tok in $reply; do
                      if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#all[@]} )); then
                          s="${all[$((tok-1))]}"
                          checked[$s]=$(( 1 - checked[$s] ))
                      else
                          warn "Ignored: '$tok'"
                      fi
                  done ;;
        esac
    done

    local sel=()
    for s in "${all[@]}"; do [[ ${checked[$s]} -eq 1 ]] && sel+=("$s"); done
    if [[ ${#sel[@]} -eq 0 ]]; then
        err "Nothing selected — aborting."
        exit 0
    fi
    ONLY_SECTIONS=$(IFS=,; echo "${sel[*]}")
    log "Selected: $ONLY_SECTIONS"
}

# ---------------------------------------------------------------------------
# Default sections
# ---------------------------------------------------------------------------

section_base() {
    header "BASE — dnf tuning, update, RPM Fusion, firmware, boot tweak"

    # Parallel downloads: forced via --parallel, else probed from the network.
    local pdl
    if [[ -n "$PARALLEL_DL" ]]; then
        pdl="$PARALLEL_DL"
        log "Parallel downloads: $pdl (forced via --parallel)"
    else
        log "Probing network quality..."
        pdl=$(probe_parallel_downloads)
        case "$pdl" in
            1)  warn "Slow/unstable network detected → serial downloads (1 at a time)" ;;
            4)  log  "Moderate network → 4 parallel downloads" ;;
            10) log  "Fast network → 10 parallel downloads" ;;
        esac
    fi
    set_dnf_opt max_parallel_downloads "$pdl"
    ok "dnf: max_parallel_downloads=$pdl"

    # NOTE: we deliberately do NOT set defaultyes=True. Every dnf call here
    # already passes -y; flipping the global default would silently auto-confirm
    # every future dnf command on this system (a footgun for later 'dnf remove').

    step "Full system update" dnf -y upgrade --refresh

    step "Enable RPM Fusion (free + nonfree)" dnf -y install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm"

    step "Enable RPM Fusion tainted (free)" dnf -y install \
        rpmfusion-free-release-tainted

    # Firmware updates via LVFS (BIOS, SSD, touchpad, etc.)
    step "Firmware update tooling (fwupd)" dnf -y install fwupd
    step_soft "Refresh LVFS firmware metadata" fwupdmgr refresh --force
    systemctl enable --now fwupd-refresh.timer 2>/dev/null || true
    ok "Check firmware updates anytime:  fwupdmgr get-updates"

    # Boot time: desktop machines don't need to block boot on network-online
    if systemctl is-enabled NetworkManager-wait-online.service &>/dev/null; then
        step "Disable NetworkManager-wait-online (faster boot)" \
            systemctl disable NetworkManager-wait-online.service
    fi

    # One-command full system update (dnf + flatpak + firmware)
    if [[ ! -f /usr/local/bin/update-all ]]; then
        cat > /usr/local/bin/update-all <<'UPD'
#!/usr/bin/env bash
# Update everything: rpm packages, flatpaks, firmware.
set -uo pipefail
echo "==> dnf" && sudo dnf upgrade --refresh -y
echo "==> flatpak" && flatpak update -y
echo "==> firmware" && sudo fwupdmgr refresh --force; sudo fwupdmgr update || true
echo "==> done"
UPD
        chmod +x /usr/local/bin/update-all
        ok "Installed 'update-all' → one command updates dnf + flatpak + firmware"
    fi
}

section_codecs() {
    header "CODECS — full ffmpeg, GStreamer plugins, hardware acceleration"

    if rpm -q ffmpeg-free >/dev/null 2>&1; then
        step "Swap ffmpeg-free → ffmpeg (full)" \
            dnf -y swap ffmpeg-free ffmpeg --allowerasing
    else
        step "Install full ffmpeg" dnf -y install ffmpeg --allowerasing
    fi

    step "Multimedia group (GStreamer bad/ugly, etc.)" \
        dnf -y group install multimedia --setopt=install_weak_deps=False \
        --exclude=PackageKit-gstreamer-plugin

    step "Extra codec bits" dnf -y install \
        libavcodec-freeworld gstreamer1-plugins-{bad-free,good,base} \
        gstreamer1-plugin-openh264 mozilla-openh264 lame\*

    if has_amd_gpu; then
        step "AMD: VA-API/VDPAU freeworld drivers" bash -c '
            dnf -y swap mesa-va-drivers mesa-va-drivers-freeworld;
            dnf -y swap mesa-vdpau-drivers mesa-vdpau-drivers-freeworld || true'
    fi
    if has_intel_gpu; then
        step "Intel: media driver" dnf -y install intel-media-driver
    fi
    if has_nvidia_gpu; then
        step_soft "NVIDIA: VA-API bridge" dnf -y install nvidia-vaapi-driver
    fi
}

section_nvidia() {
    local do_nvidia="no"
    case "$FORCE_NVIDIA" in
        yes) do_nvidia="yes" ;;
        no)  do_nvidia="no" ;;
        *)   has_nvidia_gpu && do_nvidia="yes" ;;
    esac

    if [[ "$do_nvidia" != "yes" ]]; then
        header "NVIDIA — skipped (no NVIDIA GPU detected or --no-nvidia)"
        return
    fi

    header "NVIDIA — proprietary driver (akmod), CUDA/NVENC, Secure Boot signing"

    # Secure Boot: generate & enroll a MOK so signed kernel modules load.
    # Critical on dual-boot machines where Secure Boot stays ON for Windows 11.
    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        warn "Secure Boot is ENABLED — setting up module signing key"
        step "Install signing tooling" dnf -y install kmodtool akmods mokutil openssl
        if [[ ! -f /etc/pki/akmods/certs/public_key.der ]]; then
            step "Generate signing key (kmodgenca)" kmodgenca -a
            warn "Enrolling MOK key — you will be asked to CREATE A PASSWORD."
            warn "On next reboot, a blue 'MOK Manager' screen appears:"
            warn "  Enroll MOK → Continue → Yes → enter that password → reboot."
            mokutil --import /etc/pki/akmods/certs/public_key.der || \
                FAILED_STEPS+=("MOK import — run manually: mokutil --import /etc/pki/akmods/certs/public_key.der")
        else
            ok "Signing key already exists (enrolled previously or pending)"
        fi
    fi

    step "Install NVIDIA driver (akmod) + CUDA/NVENC support" dnf -y install \
        akmod-nvidia xorg-x11-drv-nvidia-cuda

    # RTX 50-series (Blackwell) requires the open kernel module.
    if ! grep -q "kmod_nvidia_open" /etc/rpm/macros.nvidia-kmod 2>/dev/null; then
        echo '%_with_kmod_nvidia_open 1' > /etc/rpm/macros.nvidia-kmod
        ok "Forced open kernel modules (required for RTX 50-series)"
    fi

    log "Building kernel module now (this takes a few minutes)..."
    step "Build NVIDIA kmod" akmods --force

    warn "Do NOT reboot until the module is built. Verify with:"
    warn "    modinfo -F version nvidia"
    warn "If it prints a version number, you are safe to reboot."
}

section_flatpak() {
    header "FLATPAK — Flathub + app bundle"

    step "Add Flathub (system-wide)" flatpak remote-add --if-not-exists \
        flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak remote-modify flathub --no-filter --enable 2>/dev/null || true
    ok "Flathub enabled and unfiltered"

    step "Flatseal (Flatpak permission manager)" \
        flatpak install -y --noninteractive flathub com.github.tchx84.Flatseal

    if has_gnome; then
        step "Extension Manager (GNOME extensions)" \
            flatpak install -y --noninteractive flathub com.mattjakeman.ExtensionManager
    fi
    if has_kde; then
        # KDE manages extensions/widgets natively; Flatseal covers permissions.
        ok "KDE detected — Discover + System Settings cover the GNOME-only tools"
    fi
}

section_gaming() {
    header "GAMING — Steam, gamescope, MangoHud, GOverlay, vkBasalt, ProtonPlus"

    step "Enable RPM Fusion Steam repo" bash -c \
        'dnf config-manager setopt rpmfusion-nonfree-steam.enabled=1 2>/dev/null ||
         dnf config-manager --set-enabled rpmfusion-nonfree-steam 2>/dev/null || true'

    step "Install gaming stack" dnf -y install \
        steam steam-devices gamescope mangohud goverlay vkBasalt gamemode \
        protontricks

    step_soft "32-bit graphics libraries" dnf -y install \
        mesa-vulkan-drivers.i686 mesa-dri-drivers.i686

    step "ProtonPlus (GE-Proton manager)" \
        flatpak install -y --noninteractive flathub com.vysp3r.ProtonPlus

    # SteamOS/Nobara-style: some titles exhaust the default mmap count
    if [[ ! -f /etc/sysctl.d/99-gaming.conf ]]; then
        echo "vm.max_map_count=2147483642" > /etc/sysctl.d/99-gaming.conf
        sysctl --system >/dev/null 2>&1 || true
        ok "vm.max_map_count raised (SteamOS value — fixes crashes in some titles)"
    fi

    ok "Tip: launch options →  gamescope -f -- mangohud %command%"
    ok "Tip: configure MangoHud graphically with GOverlay"
}

section_snapper() {
    header "SNAPPER — Btrfs snapshots (rollback insurance)"

    if ! findmnt -n -o FSTYPE / | grep -q btrfs; then
        warn "Root filesystem is not Btrfs — skipping snapper"
        return
    fi

    step "Install snapper + dnf integration" bash -c \
        'dnf -y install snapper python3-dnf-plugin-snapper ||
         dnf -y install snapper libdnf5-plugin-actions'


    step_soft "Btrfs Assistant (GUI for snapshots/rollback)" \
        dnf -y install btrfs-assistant

    if ! snapper list-configs 2>/dev/null | grep -q "^root"; then
        step "Create snapper config for /" snapper -c root create-config /
    fi
    if findmnt /home >/dev/null 2>&1 && findmnt -n -o FSTYPE /home | grep -q btrfs; then
        if ! snapper list-configs 2>/dev/null | grep -q "^home"; then
            step "Create snapper config for /home" snapper -c home create-config /home
        fi
    fi

    step "Enable snapshot timers" systemctl enable --now \
        snapper-timeline.timer snapper-cleanup.timer

    ok "Snapshots active. GUI: btrfs-assistant | CLI: snapper list"
}

section_media() {
    header "MEDIA — OBS Studio + virtual camera, mpv, yt-dlp"

    step "OBS Studio" dnf -y install obs-studio

    # Virtual camera for OBS (RPM Fusion akmod — auto-rebuilds per kernel)
    step "v4l2loopback (OBS virtual camera)" bash -c \
        'dnf -y install akmod-v4l2loopback v4l2loopback-utils ||
         dnf -y install akmod-v4l2loopback'


    step "mpv (lightweight media player)" dnf -y install mpv

    step "yt-dlp" dnf -y install yt-dlp

    ok "Virtual camera appears in OBS after next reboot (module builds like NVIDIA's)"
}

section_dev() {
    header "DEV — tooling, Docker CE, nvm (Node), uv (Python), VS Code"

    step "Core dev tools" dnf -y install \
        git gh make gcc gcc-c++ zsh tmux jq ripgrep fd-find fzf

    # --- Python: uv (no direct pip usage) ----------------------------------
    step "uv (Python project/tool manager)" dnf -y install uv

    # --- Node: nvm, installed for the real user ----------------------------
    if [[ ! -d "$REAL_HOME/.nvm" ]]; then
        step "Install nvm ($NVM_VERSION) for $REAL_USER" as_user \
            "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
        step "Install latest LTS Node via nvm" as_user \
            "export NVM_DIR=\"$REAL_HOME/.nvm\"; . \"\$NVM_DIR/nvm.sh\"; nvm install --lts"
    else
        ok "nvm already installed for $REAL_USER"
    fi

    # --- Docker CE (matches Dokploy & most production/CI environments) -----
    # Podman ships with Fedora and coexists fine. Do NOT install podman-docker.
    if ! command -v docker >/dev/null 2>&1; then
        step "Add Docker CE repo" bash -c \
            'dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null ||
             dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo'
        step "Install Docker CE" dnf -y install \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        step "Enable Docker daemon" systemctl enable --now docker
        if [[ "$REAL_USER" != "root" ]]; then
            step "Add $REAL_USER to docker group" usermod -aG docker "$REAL_USER"
            warn "Log out/in for docker group to apply"
        fi
    else
        ok "Docker already present"
    fi

    # --- VS Code (Microsoft repo) -------------------------------------------
    if ! command -v code >/dev/null 2>&1; then
        step "Import Microsoft GPG key" \
            rpm --import https://packages.microsoft.com/keys/microsoft.asc
        if [[ ! -f /etc/yum.repos.d/vscode.repo ]]; then
            cat > /etc/yum.repos.d/vscode.repo <<'REPO'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO
            ok "VS Code repo added"
        fi
        step "Install VS Code" dnf -y install code
    else
        ok "VS Code already present"
    fi
}

section_virt() {
    header "VIRT — KVM/QEMU + virt-manager"

    step "Install virtualization group" bash -c \
        'dnf -y group install virtualization ||
         dnf -y install qemu-kvm libvirt virt-manager virt-install'


    step "Enable libvirt daemon" systemctl enable --now libvirtd
    if [[ "$REAL_USER" != "root" ]]; then
        step "Add $REAL_USER to libvirt group" usermod -aG libvirt "$REAL_USER"
    fi
}

section_qol() {
    header "QOL — fonts, archives, utilities"

    step "Archive formats" dnf -y install \
        unzip p7zip p7zip-plugins unrar

    # Archive GUI matching the desktop
    if has_gnome; then
        step_soft "Archive GUI (file-roller)" dnf -y install file-roller
        step "GNOME Tweaks" dnf -y install gnome-tweaks
    fi
    if has_kde; then
        step_soft "Archive GUI (ark)" dnf -y install ark
        step_soft "Disk usage viewer (filelight)" dnf -y install filelight
    fi

    step "Utilities" dnf -y install \
        htop btop fastfetch wl-clipboard tldr

    step_soft "Fonts" dnf -y install \
        google-noto-emoji-fonts google-noto-sans-fonts jetbrains-mono-fonts \
        fira-code-fonts
}

# ---------------------------------------------------------------------------
# Optional sections (require --with)
# ---------------------------------------------------------------------------

section_legion() {
    header "LEGION — LenovoLegionLinux (community fan/power control)"
    warn "Community kernel module — not official Lenovo software."

    step "Build prerequisites" dnf -y install \
        dkms "kernel-devel-$(uname -r)" openssl lm_sensors

    # Official COPR per the LLL project README: mrduarte/LenovoLegionLinux
    # CAVEAT (verified Jul 2026): its latest build FAILED over a year ago, so
    # packages for current Fedora releases may not exist — source install
    # via the upstream repo is the realistic fallback.
    local installed="no"
    if dnf copr enable -y "mrduarte/LenovoLegionLinux" >>"$LOG_FILE" 2>&1; then
        # Fedora package names differ from the Ubuntu PPA ones:
        if dnf -y install dkms-lenovolegionlinux python-lenovolegionlinux >>"$LOG_FILE" 2>&1; then
            installed="yes"; ok "Installed from COPR: mrduarte/LenovoLegionLinux"
        else
            dnf copr disable -y "mrduarte/LenovoLegionLinux" >>"$LOG_FILE" 2>&1 || true
        fi
    fi

    if [[ "$installed" == "no" ]]; then
        warn "COPR has no packages for this Fedora release (its builds are stale)."
        warn "Install from source instead:"
        warn "  git clone https://github.com/johnfanv2/LenovoLegionLinux"
        warn "  cd LenovoLegionLinux/kernel_module && make && sudo make dkms"
        warn "Also note: LLL's confirmed models are ~2020–2023. On 2025+ Legions,"
        warn "check first whether your kernel already exposes power modes natively"
        warn "(lenovo-wmi drivers / platform_profile) before adding this module."
        FAILED_STEPS+=("LenovoLegionLinux — manual install needed (stale COPR)")
    fi

    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        warn "Secure Boot is ON: the DKMS module must be signed with your MOK key"
    fi
}

section_asus() {
    header "ASUS — asusctl + supergfxctl (asus-linux.org)"

    step "Enable asus-linux COPR" dnf copr enable -y lukenukem/asus-linux
    step "Install asusctl + supergfxctl" dnf -y install asusctl supergfxctl
    step "Enable services" bash -c \
        'systemctl enable --now asusd 2>/dev/null; systemctl enable --now supergfxd 2>/dev/null || true'
    ok "ROG Control Center: rog-control-center | GPU modes: supergfxctl -m <mode>"
}

section_distrobox() {
    header "DISTROBOX — containerized dev environments (Podman-backed)"

    step "Install distrobox" dnf -y install distrobox
    ok "Create an env:  distrobox create -n ubuntu-lts -i ubuntu:24.04"
    ok "Enter it:       distrobox enter ubuntu-lts"
}

section_wine() {
    header "WINE — non-Steam Windows software"

    step "Install Wine + winetricks" dnf -y install wine winetricks
    ok "For GUI management of Wine prefixes, consider Bottles (Flathub)"
}

section_gametweaks() {
    header "GAMETWEAKS — scx_lavd as a toggleable game mode, split-lock off"

    # sched_ext schedulers run on Fedora's STOCK kernel (6.12+) — no custom
    # kernel needed, Secure Boot stays happy. scx_lavd is latency-oriented
    # (developed for the Steam Deck; benefits dual-CCD X3D CPUs).
    #
    # Design: INSTALLED but NOT enabled. Latency schedulers help games and
    # hurt long compiles, so this is a switch you flip, not a setting you set.
    step "Install SCX schedulers" dnf -y install scx-scheds
    if [[ -f /etc/default/scx ]]; then
        sed -i 's/^SCX_SCHEDULER=.*/SCX_SCHEDULER=scx_lavd/' /etc/default/scx \
            2>/dev/null || echo 'SCX_SCHEDULER=scx_lavd' >> /etc/default/scx
    else
        echo 'SCX_SCHEDULER=scx_lavd' > /etc/default/scx
    fi

    # Install the toggle helper
    cat > /usr/local/bin/scx-toggle <<'SCXT'
#!/usr/bin/env bash
# scx-toggle — flip the scx_lavd gaming scheduler on/off
# on/off      = this session only
# boot-on/off = persist across reboots
# status      = show current scheduler state
set -uo pipefail
case "${1:-status}" in
    on)       sudo systemctl start scx && echo "scx_lavd ACTIVE (session)" ;;
    off)      sudo systemctl stop scx && echo "default scheduler restored" ;;
    boot-on)  sudo systemctl enable --now scx && echo "scx_lavd ACTIVE + enabled at boot" ;;
    boot-off) sudo systemctl disable --now scx && echo "default scheduler, disabled at boot" ;;
    status)
        if systemctl is-active scx &>/dev/null; then
            echo "scheduler: scx_lavd (ACTIVE)"
        else
            echo "scheduler: kernel default (EEVDF)"
        fi
        systemctl is-enabled scx &>/dev/null && echo "boot: enabled" || echo "boot: disabled"
        ;;
    *) echo "usage: scx-toggle {on|off|boot-on|boot-off|status}"; exit 1 ;;
esac
SCXT
    chmod +x /usr/local/bin/scx-toggle
    ok "Installed 'scx-toggle' — game session: scx-toggle on | compile session: scx-toggle off"
    ok "Not enabled by default. Check anytime: scx-toggle status"

    # --- GameMode integration: scx_lavd flips on when a game starts ---------
    # GameMode's start/end hooks run as the user, so grant passwordless
    # rights for exactly two commands: starting and stopping the scx unit.
    cat > /etc/sudoers.d/scx-gamemode <<SUDO
# Allow GameMode hooks to toggle the scx scheduler without a password.
# Scoped to exactly these two commands — nothing else.
${REAL_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl start scx, /usr/bin/systemctl stop scx
SUDO
    chmod 0440 /etc/sudoers.d/scx-gamemode
    if visudo -cf /etc/sudoers.d/scx-gamemode >/dev/null 2>&1; then
        ok "sudoers rule for GameMode hooks (scoped to scx start/stop only)"
    else
        rm -f /etc/sudoers.d/scx-gamemode
        err "sudoers validation failed — GameMode auto-toggle disabled"
        FAILED_STEPS+=("scx-gamemode sudoers rule")
    fi

    # Hook scx into GameMode: any game launched with GameMode (or Feral's
    # gamemoderun) automatically gets scx_lavd; it reverts when the game exits.
    if [[ -f /etc/sudoers.d/scx-gamemode ]]; then
        if [[ ! -f /etc/gamemode.ini ]] || ! grep -q "scx-toggle" /etc/gamemode.ini; then
            cat >> /etc/gamemode.ini <<'GMODE'

[custom]
start=/usr/local/bin/scx-toggle on
end=/usr/local/bin/scx-toggle off
GMODE
            ok "GameMode hooks: scx_lavd auto-starts with games, auto-stops after"
            ok "Use per-game in Steam:  gamemoderun %command%"
            ok "Combine with the rest: gamescope -f -- gamemoderun mangohud %command%"
        else
            ok "GameMode scx hooks already configured"
        fi
    fi

    # Some Windows games under Proton trigger x86 split-lock detection and
    # get throttled to unplayable framerates. SteamOS/Nobara disable it.
    # (No compile-time cost — safe to leave permanently on.)
    if ! grep -q "split_lock_detect=off" /proc/cmdline; then
        step "Disable split-lock throttling (kernel arg)" \
            grubby --update-kernel=ALL --args="split_lock_detect=off"
        warn "split_lock_detect=off applies after reboot"
    else
        ok "split_lock_detect=off already active"
    fi
}

section_lutris() {
    header "LUTRIS — launcher for Epic/GOG/emulators/non-Steam games"

    step "Install Lutris" dnf -y install lutris
}

section_faugus() {
    header "FAUGUS — minimal UMU/Proton launcher for Windows games"

    # Deliberately the COPR (native) build, NOT the Flatpak: the Flatpak has
    # known breakage (gamescope doesn't work, the 'stop' button won't close
    # games, themes). The native build integrates with the gamescope/MangoHud/
    # GameMode stack installed by the 'gaming' section.
    step "Enable Faugus COPR" dnf copr enable -y faugus/faugus-launcher
    step "Install Faugus Launcher" dnf -y install faugus-launcher

    ok "Built-in Proton manager (GE-Proton / Proton-EM). Overlaps Lutris —"
    ok "Faugus is the simple 'point at an .exe' option; Lutris is the full platform."
}

section_creative() {
    header "CREATIVE — image/video/audio/3D suite"

    step "Install creative apps" dnf -y install \
        gimp inkscape kdenlive audacity blender
}

section_apps() {
    header "APPS — communication & music (Flatpaks)"

    step "Vesktop (Discord with proper Wayland screenshare)" \
        flatpak install -y --noninteractive flathub dev.vencord.Vesktop
    step "Spotify" \
        flatpak install -y --noninteractive flathub com.spotify.Client
    step "Telegram" \
        flatpak install -y --noninteractive flathub org.telegram.desktop
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
# Preserve the original invocation: the loop below shifts $@ away, so the
# "run with sudo" hint (require_root) would otherwise lose the user's flags.
ORIGINAL_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --menu)        MENU_MODE="yes"; shift ;;
        --nvidia)      FORCE_NVIDIA="yes"; shift ;;
        --no-nvidia)   FORCE_NVIDIA="no"; shift ;;
        --only)        ONLY_SECTIONS="$2"; shift 2 ;;
        --skip)        SKIP_SECTIONS="$2"; shift 2 ;;
        --with)        WITH_SECTIONS="$2"; shift 2 ;;
        --parallel)    if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 20 )); then
                           PARALLEL_DL="$2"; shift 2
                       else
                           err "--parallel takes a number 1-20"; exit 1
                       fi ;;
        --scx)         if [[ -z "${2:-}" ]]; then
                           err "--scx needs a verb: on|off|status|boot-on|boot-off"; exit 1
                       elif command -v scx-toggle >/dev/null 2>&1; then
                           exec scx-toggle "$2"
                       else
                           err "scx-toggle not installed — run with --with gametweaks first"
                           exit 1
                       fi ;;
        --list)        printf 'default:  %s\n' "${DEFAULT_SECTIONS[*]}"
                       printf 'optional: %s\n' "${OPTIONAL_SECTIONS[*]}"; exit 0 ;;
        -h|--help)     sed -n '2,60p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             err "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_root "${ORIGINAL_ARGS[@]}"
require_fedora
touch "$LOG_FILE"

header "Fedora post-install (v3) — log: $LOG_FILE"
log "User: $REAL_USER | GPU(s): $(lspci -nn | grep -Ei 'vga|3d' | sed 's/^[0-9a-f:.]* //' | paste -sd ' | ')"

# Interactive picker overrides section selection with exactly the checked set.
[[ "$MENU_MODE" == "yes" ]] && run_menu

for s in "${DEFAULT_SECTIONS[@]}" "${OPTIONAL_SECTIONS[@]}"; do
    if section_enabled "$s"; then
        "section_$s"
    else
        log "Skipping section: $s"
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "DONE"
if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
    err "Some steps failed:"
    for f in "${FAILED_STEPS[@]}"; do err "  - $f"; done
    warn "Re-running the script is safe; it retries only what's needed."
else
    ok "All steps completed successfully."
fi

if has_nvidia_gpu && [[ "$FORCE_NVIDIA" != "no" ]]; then
    warn "NVIDIA checklist before reboot:"
    warn "  1. modinfo -F version nvidia   → must print a version"
    warn "  2. If Secure Boot: expect the MOK Manager screen on reboot"
fi
warn "Reboot recommended:  systemctl reboot"
