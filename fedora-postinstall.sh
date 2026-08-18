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
#   qol      archives, fonts (incl. MS core fonts), monitors, tldr, desktop extras
#
# Optional sections (only with --with):
#   legion      Lenovo Legion power modes (verifies native kernel support first)
#   asus        asusctl + supergfxctl (ASUS laptops, asus-linux.org COPR)
#   battery     charge threshold (default 80%) — vendor-neutral, detected at
#               runtime from the power_supply sysfs class, so Lenovo/ASUS/
#               ThinkPad/Huawei/Framework are all the same code path
#   distrobox   containerized dev environments (Podman-backed)
#   wine        Wine + winetricks (non-Steam Windows software)
#   lutris      Lutris game launcher (Epic/GOG/emulators/install scripts)
#   heroic      Heroic Games Launcher — GOG/Epic/Amazon libraries (Flatpak)
#   faugus      Faugus Launcher — minimal UMU/Proton launcher for Windows games
#   gametweaks  scx_lavd scheduler as a TOGGLE (stock kernel), split_lock_detect=off
#   creative    GIMP, Inkscape, Kdenlive, Audacity, Blender — Flatpaks
#   apps        Discord (Vesktop), Spotify, Telegram — Flatpaks
#   mycomputer  "My Computer" drives/volumes panel for GNOME Files (Nautilus
#               extension, upstream COPR — needs Fedora 43+ and Nautilus)
#
# Runtime toggles (after gametweaks is installed):
#   sudo ./fedora-postinstall.sh --scx on|off|status|boot-on|boot-off
#   (or the installed shortcut:  scx-toggle on|off|status|boot-on|boot-off)
#   on/off    = this session only (game session vs compile session)
#   boot-on/off = persist across reboots
#   AUTO: games launched with 'gamemoderun %command%' flip scx_lavd on/off themselves.
#
# Runtime toggles (after battery is installed):
#   sudo ./fedora-postinstall.sh --battery 80|full|status
#   (or the installed shortcut:  battery-limit 80|full|status)
#   80    = stop charging at 80% — the setting that actually extends cell life
#   full  = charge to 100% before travelling
#   Persists across reboot AND resume; re-run 'full' every few months to let
#   the gauge recalibrate.
#
# Desktop-aware: GNOME, KDE Plasma and COSMIC — GNOME gets Extension
# Manager/Tweaks/file-roller, KDE gets ark/filelight, COSMIC gets
# file-roller/baobab (cosmic-settings covers the rest); shared bits unchanged.
#
# Package-based Fedora only: image-based variants (Silverblue, Kinoite, COSMIC
# Atomic, Bazzite) are refused up front — they layer with rpm-ostree, not dnf.
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
REPO_RAW="https://raw.githubusercontent.com/Isidro-Zertucha/fedora-postinstall/main/fedora-postinstall.sh"
DEFAULT_SECTIONS=(base codecs nvidia flatpak gaming snapper media dev virt qol)
OPTIONAL_SECTIONS=(legion asus battery distrobox wine lutris heroic faugus gametweaks creative apps mycomputer)
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

# tee's stderr is dropped on purpose: argument errors and the "run with sudo"
# hint are printed before the log file exists, and a permission-denied warning
# on every line is not what someone who just forgot sudo needs to read. Once
# main() touches the log as root the file is writable, so nothing is lost.
log()    { echo -e "${BLUE}[*]${NC} $*" | tee -a "$LOG_FILE" 2>/dev/null; }
ok()     { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE" 2>/dev/null; }
warn()   { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE" 2>/dev/null; }
err()    { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE" 2>/dev/null; }
header() { echo -e "\n${BOLD}==> $*${NC}\n" | tee -a "$LOG_FILE" 2>/dev/null; }

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

# $0 is a usable path only when the script sits on disk. Run the documented
# bash -c "$(curl …)" form and $0 is the '--' placeholder instead, so the hint
# has to name the remote invocation rather than print "sudo --".
require_root() {
    [[ $EUID -eq 0 ]] && return
    if [[ -f "$0" ]]; then
        err "Run with sudo: sudo $0 $*"
    else
        err "Run with sudo — prefix the whole command:"
        err "  sudo bash -c \"\$(curl -fsSL $REPO_RAW)\" -- $*"
    fi
    exit 1
}

require_fedora() {
    if ! grep -qi "fedora" /etc/os-release; then
        err "This script targets Fedora. Aborting."
        exit 1
    fi
    FEDORA_VER=$(rpm -E %fedora)
    log "Detected Fedora $FEDORA_VER"
}

# Image-based Fedora (Silverblue, Kinoite, COSMIC Atomic, Bazzite) boots an
# ostree deployment: /usr is read-only and packages are layered with rpm-ostree.
# /etc/os-release still says "fedora", so require_fedora waves it through — and
# then every dnf transaction fails while the steps that write /etc, sudoers and
# kernel args still land, leaving the deployment half-configured. Refuse early.
require_mutable_system() {
    if [[ -f /run/ostree-booted ]]; then
        err "Image-based Fedora detected (ostree deployment)."
        err "This script installs with dnf and assumes a writable /usr."
        err "Layer packages with 'rpm-ostree install', or use Flatpak/Distrobox."
        exit 1
    fi
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
has_cosmic()     { rpm -q cosmic-session >/dev/null 2>&1 || rpm -q cosmic-comp >/dev/null 2>&1; }
has_nautilus()   { rpm -q nautilus >/dev/null 2>&1; }

# Which NVIDIA driver branch this GPU needs — echoes a legacy suffix ("580xx",
# "470xx", "390xx") or nothing for the current branch.
#
# R595 dropped Maxwell, Pascal and Volta, and `akmod-nvidia` always resolves to
# the newest branch. On a GTX 10-series that builds a module which does not
# support the card: it compiles, `modinfo -F version nvidia` prints a version,
# every check in this script goes green, and the machine boots to a black
# screen. The failure has to be caught here or it is not caught at all.
#
# Routing is by chip codename because that is how NVIDIA's own support matrix is
# written. An unrecognised name falls through to the current branch on purpose —
# a chip missing from this machine's pci.ids is newer than the last drop, not
# older.
nvidia_branch() {
    local codename
    codename=$(lspci -nn | grep -Ei 'vga|3d' | grep -i nvidia |
        grep -oE 'NVIDIA Corporation [A-Z]{2}[0-9]+' | awk '{print $3}' | head -n1)

    case "$codename" in
        G[MPV][0-9]*) echo "580xx" ;;   # Maxwell, Pascal, Volta
        GK[0-9]*)     echo "470xx" ;;   # Kepler
        GF[0-9]*)     echo "390xx" ;;   # Fermi
        *)            echo "" ;;        # Turing and newer
    esac
}

# A typo in --only/--skip/--with matches no section at all, and the run then
# reports "All steps completed successfully" having installed precisely nothing.
# Silence is the wrong answer to a misspelled flag.
validate_sections() {
    local flag="$1" list="$2" name s known
    local -a names bad=()
    [[ -z "$list" ]] && return 0

    IFS=',' read -ra names <<< "$list"
    for name in "${names[@]}"; do
        [[ -z "$name" ]] && continue
        known=0
        for s in "${DEFAULT_SECTIONS[@]}" "${OPTIONAL_SECTIONS[@]}"; do
            [[ "$name" == "$s" ]] && { known=1; break; }
        done
        [[ $known -eq 0 ]] && bad+=("$name")
    done

    if [[ ${#bad[@]} -gt 0 ]]; then
        err "$flag: unknown section(s): ${bad[*]}"
        err "Valid sections: ${DEFAULT_SECTIONS[*]} ${OPTIONAL_SECTIONS[*]}"
        exit 1
    fi
}

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

# Enable a COPR only if it actually serves the packages we want on THIS Fedora
# release. When Fedora branches, COPR auto-forks a project's existing binaries
# into the new chroot, so a repo can look alive while shipping packages nobody
# has rebuilt in a year. Worse, an enabled COPR with nothing installable is pure
# liability: it contributes zero packages and still blocks `dnf system-upgrade`
# once it lags a release behind.
#
# Querying the repo by id also catches package-name typos and case mismatches —
# COPR package names are case-sensitive, and asking for the wrong case looks
# exactly like an empty repository.
#
# On success the repo stays enabled with skip_if_unavailable, so a future
# missing chroot degrades to a warning instead of wedging every dnf run. On
# failure the repo is disabled again, leaving the system as we found it.
copr_enable_guarded() {
    local copr="$1"; shift
    local repo="copr:copr.fedorainfracloud.org:${copr%%/*}:${copr##*/}"
    local pkg

    if ! dnf copr enable -y "$copr" >>"$LOG_FILE" 2>&1; then
        warn "COPR could not be enabled: $copr"
        return 1
    fi

    for pkg in "$@"; do
        if [[ -z "$(dnf -q repoquery --repo="$repo" "$pkg" 2>/dev/null)" ]]; then
            warn "COPR $copr serves no '$pkg' for Fedora $FEDORA_VER — disabling it again"
            dnf copr disable -y "$copr" >>"$LOG_FILE" 2>&1 || true
            return 1
        fi
    done

    dnf config-manager setopt "${repo}.skip_if_unavailable=1" >>"$LOG_FILE" 2>&1 ||
        dnf config-manager --save "--setopt=${repo}.skip_if_unavailable=1" >>"$LOG_FILE" 2>&1 || true
    ok "COPR verified for Fedora $FEDORA_VER: $copr"
    return 0
}

# Every Flatpak-installing section can be run on its own (--only apps, --only
# creative), so none of them may assume the 'flatpak' section went first. Both
# halves are idempotent and cost nothing when they are already satisfied.
ensure_flatpak() {
    command -v flatpak >/dev/null 2>&1 || dnf -y install flatpak || return 1
    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo
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

    # Anything that is not a plain integer becomes 0. curl can return an empty
    # figure on a failed transfer, or a locale-formatted one with a comma where
    # the decimal point was expected — and a non-numeric value here would make
    # the comparisons below fail and write an EMPTY max_parallel_downloads into
    # dnf.conf. Zero routes to the "assume the worst" branch, which is correct.
    [[ "$speed" =~ ^[0-9]+$ ]] || speed=0

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
    [flatpak]="Flathub + Flatseal (+ Extension Manager on GNOME)"
    [gaming]="Steam, gamescope, MangoHud, GameMode, ProtonPlus"
    [snapper]="Btrfs snapshots + Btrfs Assistant GUI"
    [media]="OBS Studio + virtual camera, mpv, yt-dlp"
    [dev]="git tooling, Docker CE, nvm, uv, VS Code"
    [virt]="KVM/QEMU + virt-manager"
    [qol]="fonts, archives, monitors, desktop-matched extras"
    [legion]="Lenovo Legion power modes (native kernel check)"
    [asus]="asusctl + supergfxctl (ASUS laptops)"
    [battery]="charge cap at 80% — any vendor, persists reboot/resume"
    [distrobox]="containerized dev environments (Podman)"
    [wine]="Wine + winetricks (non-Steam Windows software)"
    [lutris]="launcher for Epic/GOG/emulators/install scripts"
    [heroic]="GOG/Epic/Amazon library launcher (Flathub)"
    [faugus]="minimal UMU/Proton launcher for Windows games"
    [gametweaks]="scx_lavd game-mode toggle, split-lock off"
    [creative]="GIMP, Inkscape, Kdenlive, Audacity, Blender (Flathub)"
    [apps]="Discord (Vesktop), Spotify, Telegram (Flatpaks)"
    [mycomputer]="'My Computer' drives panel for GNOME Files (Nautilus)"
)

# Help text. Deliberately NOT parsed out of the file's own header: run remotely
# as bash -c "$(curl …)" and $0 is the '--' placeholder, not a path — the old
# self-parse read stdin instead and hung on a terminal. The section tables are
# printed from SECTION_DESC so they cannot drift from what actually runs.
usage() {
    local s
    cat <<USAGE
fedora-postinstall.sh (v3) — opinionated, idempotent Fedora post-install.

Usage:
  sudo ./fedora-postinstall.sh [flags]
  sudo bash -c "\$(curl -fsSL $REPO_RAW)" -- [flags]

Flags:
  --menu                 Interactive picker: check/uncheck sections, then install
  --nvidia               Force NVIDIA setup even if no card is detected
  --no-nvidia            Skip NVIDIA even if a card is present
  --only  a,b,c          Run ONLY these sections
  --skip  a,b,c          Run the defaults EXCEPT these
  --with  a,b,c          Add optional sections to the defaults
  --parallel N           Force dnf parallel downloads (1-20); default: auto-probe
  --scx VERB             Gaming scheduler: on|off|status|boot-on|boot-off
  --battery VERB         Charge cap: <40-100>|full|status|apply
  --list                 Print section names only, and exit
  -h, --help             This text

Default sections (run in order):
USAGE
    for s in "${DEFAULT_SECTIONS[@]}"; do
        printf '  %-11s %s\n' "$s" "${SECTION_DESC[$s]:-}"
    done
    printf '\nOptional sections (only with --with):\n'
    for s in "${OPTIONAL_SECTIONS[@]}"; do
        printf '  %-11s %s\n' "$s" "${SECTION_DESC[$s]:-}"
    done
    cat <<USAGE

Notes:
  Every step is idempotent — re-running only does what is still missing.
  Package-based Fedora only: image-based variants (Silverblue, Kinoite, COSMIC
  Atomic, Bazzite) are refused, they layer with rpm-ostree instead of dnf.
  Full log: $LOG_FILE
USAGE
}

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

    # Every package of a legacy branch must carry the same suffix. A mixed set
    # (akmod-nvidia-580xx with a current xorg-x11-drv-nvidia) installs cleanly
    # and then fails to load, which looks identical to a build failure.
    local branch suffix=""
    branch=$(nvidia_branch)
    if [[ -n "$branch" ]]; then
        suffix="-$branch"
        warn "This GPU predates the current driver branch — using legacy $branch"
        warn "Open kernel modules need Turing or newer, so they stay off here."
    fi

    # Secure Boot: generate & enroll a MOK so signed kernel modules load.
    # Critical on dual-boot machines where Secure Boot stays ON for Windows 11.
    # mokutil has to be INSTALLED before it can be trusted to answer. It is not
    # present on every Fedora variant, and "command not found" is swallowed by
    # 2>/dev/null, so a missing binary reads exactly like "Secure Boot is off".
    # Get that backwards and MOK enrollment is skipped silently — the driver
    # installs, the unsigned module is refused at boot, and the machine comes up
    # to a black screen. Install first, ask afterwards.
    step "Module signing tooling" dnf -y install kmodtool akmods mokutil openssl

    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        warn "Secure Boot is ENABLED — setting up module signing key"
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
        "akmod-nvidia${suffix}" "xorg-x11-drv-nvidia${suffix}-cuda"

    # The settings GUI ships as a dependency today, but it is branch-suffixed
    # too — naming it keeps a legacy install from pulling the current-branch one.
    step_soft "NVIDIA settings GUI" dnf -y install "nvidia-settings${suffix}"

    # RPM Fusion builds open modules by default since the R595 move, so this is
    # a no-op on an up-to-date box and a fallback on an older one. Current
    # branch only: open modules do not support Maxwell/Pascal/Volta.
    if [[ -z "$branch" ]] &&
       ! grep -q "kmod_nvidia_open" /etc/rpm/macros.nvidia-kmod 2>/dev/null; then
        echo '%_with_kmod_nvidia_open 1' > /etc/rpm/macros.nvidia-kmod
        ok "Open kernel modules pinned on (required for RTX 50-series)"
    fi

    log "Building kernel module now (this takes a few minutes)..."
    step "Build NVIDIA kmod" akmods --force

    warn "Do NOT reboot until the module is built. Verify with:"
    warn "    modinfo -F version nvidia"
    warn "If it prints a version number, you are safe to reboot."
}

section_flatpak() {
    header "FLATPAK — Flathub + app bundle"

    step "Flatpak + Flathub (system-wide)" ensure_flatpak
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
    if has_cosmic; then
        # COSMIC Store reads the system remotes, so Flathub is enough here.
        ok "COSMIC detected — COSMIC Store picks up Flathub; Flatseal covers permissions"
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

    step "Flatpak + Flathub" ensure_flatpak
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

    # OBS stays NATIVE on purpose, even though upstream also ships a Flatpak.
    # The virtual camera below is a host kernel module, and third-party OBS
    # plugins expect the system plugin path — inside the sandbox both turn into
    # extension plumbing. This is the one place where "newer upstream build"
    # loses to integration; the creative section goes the other way.
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
    # Without a usable home, "$REAL_HOME/.nvm" collapses to "/.nvm" and nvm gets
    # installed into the filesystem root. Skip rather than make that mess.
    if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
        warn "No home directory for $REAL_USER — skipping nvm/Node"
        FAILED_STEPS+=("nvm (no home directory for $REAL_USER)")
    elif [[ ! -d "$REAL_HOME/.nvm" ]]; then
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

# Microsoft TrueType core fonts: Arial, Times New Roman, Courier New, Verdana,
# Georgia, Impact, Comic Sans, Trebuchet, Andale Mono, Webdings.
#
# Deliberately NOT the msttcore-fonts-installer RPM. That package is unsigned,
# was built in 2013 with SHA-1 digests, and current rpm rejects it outright on
# Fedora 43+ ("fails verification: no digest"). The --nodigest workaround that
# circulates in forums just disables the last integrity check standing, and its
# %post scriptlet fetches archives from the network as root.
#
# This does what Debian's ttf-mscorefonts-installer does instead: download
# Microsoft's original self-extracting cabinets, verify each against known-good
# SHA-256 sums, then extract locally. Nothing runs as root from the network and
# nothing is redistributed — the EULA covers downloading and extracting here.
#
# Sums are Debian's cabfiles.sha256sums (msttcorefonts 3.8.1), cross-checked
# against cabinets downloaded fresh from the mirror below. These files have not
# changed since 2001; a mismatch means the download is wrong, not stale.
install_msttcore_fonts() {
    local dest="/usr/share/fonts/msttcore"

    if compgen -G "$dest/*.ttf" >/dev/null 2>&1; then
        ok "Microsoft core fonts already installed"
        return 0
    fi

    declare -A sums=(
        [andale32.exe]="0524fe42951adc3a7eb870e32f0920313c71f170c859b5f770d82b4ee111e970"
        [arial32.exe]="85297a4d146e9c87ac6f74822734bdee5f4b2a722d7eaa584b7f2cbf76f478f6"
        [arialb32.exe]="a425f0ffb6a1a5ede5b979ed6177f4f4f4fdef6ae7c302a7b7720ef332fec0a8"
        [comic32.exe]="9c6df3feefde26d4e41d4a4fe5db2a89f9123a772594d7f59afd062625cd204e"
        [courie32.exe]="bb511d861655dde879ae552eb86b134d6fae67cb58502e6ff73ec5d9151f3384"
        [georgi32.exe]="2c2c7dcda6606ea5cf08918fb7cd3f3359e9e84338dc690013f20cd42e930301"
        [impact32.exe]="6061ef3b7401d9642f5dfdb5f2b376aa14663f6275e60a51207ad4facf2fccfb"
        [times32.exe]="db56595ec6ef5d3de5c24994f001f03b2a13e37cee27bc25c58f6f43e8f807ab"
        [trebuc32.exe]="5a690d9bb8510be1b8b4fe49f1f2319651fe51bbe54775ddddd8ef0bd07fdac9"
        [verdan32.exe]="c1cb61255e363166794e47664e2f21af8e3a26cb6346eb8d2ae2fa85dd5aad96"
        [webdin32.exe]="64595b5abc1080fba8610c5c34fab5863408e806aafe84653ca8575bed17d75a"
    )

    local mirror="https://downloads.sourceforge.net/corefonts"
    local tmp; tmp=$(mktemp -d) || return 1
    local verified=0 cab sum

    for cab in "${!sums[@]}"; do
        if ! curl -fsSL --retry 3 --max-time 120 -o "$tmp/$cab" "$mirror/$cab"; then
            warn "msttcore: download failed for $cab"
            continue
        fi
        sum=$(sha256sum "$tmp/$cab" | cut -d' ' -f1)
        if [[ "$sum" != "${sums[$cab]}" ]]; then
            warn "msttcore: SHA-256 mismatch for $cab ($sum) — discarded"
            rm -f "$tmp/$cab"
            continue
        fi
        if cabextract -L -q -d "$tmp/ttf" "$tmp/$cab" >/dev/null 2>&1; then
            verified=$((verified + 1))
        else
            warn "msttcore: extraction failed for $cab"
        fi
    done

    if [[ $verified -eq 0 ]]; then
        rm -rf "$tmp"
        return 1
    fi

    mkdir -p "$dest"
    find "$tmp/ttf" -iname '*.ttf' -exec install -m 0644 -t "$dest" {} +
    rm -rf "$tmp"

    if ! compgen -G "$dest/*.ttf" >/dev/null 2>&1; then
        warn "msttcore: cabinets verified but no .ttf extracted"
        return 1
    fi

    fc-cache -f "$dest" >/dev/null 2>&1
    log "msttcore: $verified/${#sums[@]} cabinets verified, $(find "$dest" -iname '*.ttf' | wc -l) fonts in $dest"
    return 0
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
    if has_cosmic; then
        # No gnome-tweaks equivalent to install — cosmic-settings already covers
        # that ground. These two are standalone GTK apps and pull in no shell.
        step_soft "Archive GUI (file-roller)" dnf -y install file-roller
        step_soft "Disk usage viewer (baobab)" dnf -y install baobab
    fi

    step "Utilities" dnf -y install \
        htop btop fastfetch wl-clipboard tldr

    step_soft "Fonts" dnf -y install \
        google-noto-emoji-fonts google-noto-sans-fonts jetbrains-mono-fonts \
        fira-code-fonts

    # Metric-compatible substitutes, from Fedora's own signed repos: Liberation
    # covers Arial/Times New Roman/Courier New, Carlito covers Calibri, Caladea
    # covers Cambria. They keep line breaks and page counts close when a document
    # asks for a font that is not installed.
    #
    # Treat this as a floor, not a fix. LibreOffice has its own substitution
    # table and leans on these heavily; OnlyOffice targets OOXML fidelity and
    # matches on real font metrics instead, so it benefits far more from the
    # genuine cabinets fetched below than from these stand-ins.
    step_soft "Metric-compatible MS font substitutes" dnf -y install \
        liberation-fonts google-carlito-fonts google-crosextra-caladea-fonts

    # The genuine Microsoft fonts — downloaded and SHA-256 verified, no RPM.
    # step_soft: SourceForge fetches are flaky and this is non-essential polish.
    step "Font extraction tooling" dnf -y install curl cabextract fontconfig
    step_soft "Microsoft core fonts (verified download)" install_msttcore_fonts
}

# ---------------------------------------------------------------------------
# Optional sections (require --with)
# ---------------------------------------------------------------------------

section_legion() {
    header "LEGION — Lenovo Legion power/fan control"

    # The mainline kernel now carries the whole Lenovo WMI stack under
    # drivers/platform/x86/lenovo/: wmi-gamezone.c (LENOVO_WMI_GAMEZONE) and
    # wmi-other.c (LENOVO_WMI_TUNING), both wired into ACPI_PLATFORM_PROFILE.
    # On a current Fedora kernel the power modes are already there natively.
    #
    # So we deliberately do NOT enable mrduarte/LenovoLegionLinux. Its last real
    # build was April 2025; the F43/F44 chroots are COPR auto-forks of that same
    # build rather than rebuilds. Shipping a 2025 DKMS module against a 2026
    # kernel means a rebuild that can fail on every kernel update, plus MOK
    # signing under Secure Boot — all to duplicate what the kernel does already.
    if [[ -e /sys/firmware/acpi/platform_profile ]]; then
        ok "Native power modes present — no third-party module needed"
        log "  current:   $(< /sys/firmware/acpi/platform_profile)"
        if [[ -e /sys/firmware/acpi/platform_profile_choices ]]; then
            log "  available: $(< /sys/firmware/acpi/platform_profile_choices)"
        fi
        ok "Switch with Fn+Q, your desktop's power panel, or: powerprofilesctl set <mode>"
        ok "Fan RPM readout:  dnf install lm_sensors && sensors-detect"
        return
    fi

    # Only worth the community module if the kernel genuinely does not cover it.
    warn "No /sys/firmware/acpi/platform_profile — the kernel does not drive this model."
    warn "Only in that case is the community module worth the maintenance cost:"
    warn "  dnf install dkms kernel-devel-\$(uname -r) openssl lm_sensors"
    warn "  git clone https://github.com/johnfanv2/LenovoLegionLinux"
    warn "  cd LenovoLegionLinux/kernel_module && make && sudo make dkms"
    warn "Confirmed models are roughly 2020–2023; newer Legions rely on the WMI drivers."
    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        warn "Secure Boot is ON: that DKMS module must be signed with your MOK key"
    fi
    FAILED_STEPS+=("Legion power modes — no native platform_profile, manual build needed")
}

section_asus() {
    header "ASUS — asusctl + supergfxctl (asus-linux.org)"

    # Actively built (last rebuild Jun 2026) and the COPR asus-linux.org itself
    # points at — there is no in-repo alternative for asusctl/supergfxctl.
    if ! copr_enable_guarded lukenukem/asus-linux asusctl supergfxctl; then
        err "asus-linux COPR unusable on Fedora $FEDORA_VER — section skipped"
        FAILED_STEPS+=("asusctl/supergfxctl — COPR has no packages for F$FEDORA_VER")
        return
    fi

    step "Install asusctl + supergfxctl" dnf -y install asusctl supergfxctl
    step "Enable services" bash -c \
        'systemctl enable --now asusd 2>/dev/null; systemctl enable --now supergfxd 2>/dev/null || true'
    ok "ROG Control Center: rog-control-center | GPU modes: supergfxctl -m <mode>"
}

section_battery() {
    header "BATTERY — charge threshold (Lenovo, ASUS, ThinkPad, anything that exposes it)"

    # Deliberately vendor-neutral, and that is the whole design.
    #
    # Lenovo (ideapad_laptop, thinkpad_acpi), ASUS (asus-wmi), Huawei
    # (huawei-wmi), System76 and Framework all register the SAME power_supply
    # attributes: charge_control_start_threshold / charge_control_end_threshold.
    # A per-vendor section would be N copies of one write to sysfs, gated on a
    # DMI string that says nothing about whether the feature is actually there —
    # plenty of Legions expose it and plenty of others do not, same model line.
    # What genuinely differs is which of three interfaces the firmware offers,
    # so that is detected at runtime and nothing is inferred from the vendor.
    #
    # Deliberately NOT TLP. TLP is the answer every forum gives for charge
    # thresholds and it is the wrong one here: it conflicts with
    # power-profiles-daemon, which Fedora ships by default and which backs the
    # GNOME/KDE power panels AND the platform_profile modes the 'legion'
    # section points at. Trading working Fn+Q power modes for a threshold that
    # a oneshot unit writes just as well is a bad deal.
    install_battery_limit_tool

    local iface
    iface=$(/usr/local/bin/battery-limit detect 2>/dev/null | awk '{print $1}')

    case "$iface" in
        range|end)
            ok "Charge threshold supported natively (interface: $iface)"
            ;;
        conservation)
            warn "Only ideapad conservation mode is exposed: an on/off switch, no free value."
            warn "The firmware picks the cap (~55-60%) and ignores any percentage you pass."
            ;;
        nobattery)
            warn "No system battery found — desktop or VM. Section skipped."
            rm -f /usr/local/bin/battery-limit
            return
            ;;
        *)
            warn "This machine's firmware exposes no charge-threshold interface."
            warn "Checked: charge_control_end_threshold on every power_supply battery,"
            warn "         and ideapad_acpi conservation_mode."
            warn "Some models only expose it once the vendor module is loaded:"
            warn "  Lenovo Legion 2020-2023 → LenovoLegionLinux (see the 'legion' section)"
            warn "  ASUS                    → asusctl/asus-wmi (--with asus)"
            warn "Nothing to persist, so no service was installed."
            rm -f /usr/local/bin/battery-limit
            return
            ;;
    esac

    # Re-running must not silently overwrite a threshold the user has since
    # tuned by hand — the whole point of the config file is that it outlives
    # this script.
    if [[ -f /etc/default/battery-limit ]]; then
        ok "Keeping existing setting: $(grep -s '^BATTERY_STOP' /etc/default/battery-limit)"
    else
        cat > /etc/default/battery-limit <<'BATCONF'
# Stop charging at this percentage. 100 disables the cap (travel mode).
# Change it with:  sudo battery-limit 80   /   sudo battery-limit full
BATTERY_STOP_THRESHOLD=80
BATCONF
        ok "Default cap set to 80%"
    fi

    install_battery_limit_service

    step "Apply charge threshold now" /usr/local/bin/battery-limit apply
    /usr/local/bin/battery-limit status | while read -r l; do ok "  $l"; done

    ok "Change it anytime:  sudo battery-limit 80   |   travel: sudo battery-limit full"
    ok "Check it:           battery-limit status"

    # Two conflicts worth naming while the user is looking at the output.
    if has_gnome; then
        warn "GNOME's Settings > Power has its own 'Battery charge limit' toggle."
        warn "It writes the same sysfs attribute — set it in ONE place, not both."
    fi
    if command -v asusctl >/dev/null 2>&1; then
        warn "asusctl is installed and asusd also manages the charge limit."
        warn "Keep them in sync ('asusctl -c 80') or asusd will win at boot."
    fi

    # Capping forever is correct for the cell and wrong for the gauge.
    warn "Capped batteries drift out of calibration: the percentage readout slowly"
    warn "lies because the gauge never sees a full charge. Every few months run"
    warn "'sudo battery-limit full', charge to 100%, then set the cap back."
}

# The runtime tool. Self-contained on purpose: it is also what the systemd unit
# and the udev rule invoke, long after this installer has exited.
install_battery_limit_tool() {
    cat > /usr/local/bin/battery-limit <<'BATLIM'
#!/usr/bin/env bash
# battery-limit — cap charging to protect the cell.
#
#   battery-limit             show current state
#   battery-limit 80          stop charging at 80% (persisted across reboots)
#   battery-limit full        charge to 100% (travel mode, persisted)
#   battery-limit apply       re-apply the saved value (systemd/udev entry point)
#   battery-limit detect      print "<interface> <battery path>" for scripts
#
# Works on any laptop whose driver exposes the standard power_supply controls:
# Lenovo, ASUS, ThinkPad, Huawei, System76, Framework.
set -uo pipefail

CONF=/etc/default/battery-limit

# Read a sysfs attribute, empty string if it is missing or unreadable.
#
# This exists because $(< "$f" 2>/dev/null) does NOT do what it looks like.
# $(<file) is a bash fast path only when the redirection is the ONLY thing
# inside the substitution; adding 2>/dev/null turns it into a command
# substitution running an empty command, which yields an empty string for
# every file — including ones that read perfectly well. Silent, and it would
# have made every verify() below pass an empty value against its target.
readval() {
    [[ -r "$1" ]] || return 1
    printf '%s' "$(< "$1")"
}

# The node is not always BAT0 — BAT1, BATT and CMB0 all ship in the wild, and
# /sys/class/power_supply also lists AC adapters and USB-PD ports. Filter on
# the type attribute, then drop scope=Device: wireless mice and controllers
# register as type=Battery too, and capping a mouse is not the goal.
batteries() {
    local p scope
    for p in /sys/class/power_supply/*; do
        [[ -r "$p/type" ]] || continue
        [[ "$(< "$p/type")" == "Battery" ]] || continue
        scope=""
        [[ -r "$p/scope" ]] && scope=$(< "$p/scope")
        [[ "$scope" == "Device" ]] && continue
        printf '%s\n' "$p"
    done
}

conservation_node() {
    local n
    for n in /sys/bus/platform/drivers/ideapad_acpi/*/conservation_mode; do
        [[ -e "$n" ]] && { printf '%s\n' "$n"; return 0; }
    done
    return 1
}

iface_for() {
    local bat="$1"
    if [[ -e "$bat/charge_control_start_threshold" && -e "$bat/charge_control_end_threshold" ]]; then
        echo range
    elif [[ -e "$bat/charge_control_end_threshold" ]]; then
        echo end
    elif conservation_node >/dev/null; then
        echo conservation
    else
        echo none
    fi
}

first_battery() { batteries | head -n1; }

detect() {
    local bat
    bat=$(first_battery)
    [[ -z "$bat" ]] && { echo "nobattery -"; return; }
    echo "$(iface_for "$bat") $bat"
}

read_conf() {
    local v=80
    [[ -r "$CONF" ]] && v=$(awk -F= '/^BATTERY_STOP_THRESHOLD=/{gsub(/[^0-9]/,"",$2); print $2}' "$CONF")
    [[ "$v" =~ ^[0-9]+$ ]] || v=80
    (( v < 1 || v > 100 )) && v=80
    echo "$v"
}

write_conf() {
    cat > "$CONF" <<EOF
# Stop charging at this percentage. 100 disables the cap (travel mode).
# Change it with:  sudo battery-limit 80   /   sudo battery-limit full
BATTERY_STOP_THRESHOLD=$1
EOF
}

# Writing a value that is already set still emits a sysfs change event, and the
# udev rule that calls this script listens for exactly those. Skipping the
# no-op write is what keeps that from looping.
poke() {
    local node="$1" val="$2"
    [[ -e "$node" ]] || return 1
    [[ "$(readval "$node")" == "$val" ]] && return 0
    printf '%s\n' "$val" > "$node" 2>/dev/null
}

apply_to() {
    local bat="$1" stop="$2" iface start
    iface=$(iface_for "$bat")

    case "$iface" in
        range)
            # Order matters. Both drivers reject a write that would put start
            # above end, so going UP fails if start is written first and going
            # DOWN fails if end is. Dropping start to 0 first (always legal,
            # means "no start threshold") makes either direction valid.
            start=0
            (( stop > 5 && stop < 100 )) && start=$(( stop - 5 ))
            poke "$bat/charge_control_start_threshold" 0
            poke "$bat/charge_control_end_threshold" "$stop"
            poke "$bat/charge_control_start_threshold" "$start"
            ;;
        end)
            poke "$bat/charge_control_end_threshold" "$stop"
            ;;
        conservation)
            local node
            node=$(conservation_node) || return 1
            if (( stop >= 100 )); then poke "$node" 0; else poke "$node" 1; fi
            ;;
        *)
            return 1
            ;;
    esac

    # Never trust the write. Drivers accept only certain values on some models
    # and fail with EINVAL on the rest; an unverified write reports success
    # while the battery keeps charging to 100%.
    verify "$bat" "$stop"
}

verify() {
    local bat="$1" want="$2" got iface
    iface=$(iface_for "$bat")
    case "$iface" in
        range|end) got=$(readval "$bat/charge_control_end_threshold") ;;
        conservation)
            got=$(readval "$(conservation_node)")
            [[ "$got" == "1" && "$want" -lt 100 ]] && return 0
            [[ "$got" == "0" && "$want" -ge 100 ]] && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
    [[ "$got" == "$want" ]]
}

need_root() {
    [[ $EUID -eq 0 ]] && return 0
    exec sudo -- "$0" "$@"
}

status() {
    local bat iface stop cap
    bat=$(first_battery)
    if [[ -z "$bat" ]]; then echo "no system battery found"; return 1; fi
    iface=$(iface_for "$bat")
    cap=$(readval "$bat/capacity")
    stop=$(read_conf)

    echo "battery:   ${bat##*/} (${cap:-?}% now)"
    echo "interface: $iface"
    case "$iface" in
        range|end)
            echo "cap:       $(readval "$bat/charge_control_end_threshold")% (configured: ${stop}%)"
            ;;
        conservation)
            if [[ "$(readval "$(conservation_node)")" == "1" ]]; then
                echo "cap:       conservation mode ON (firmware picks ~55-60%)"
            else
                echo "cap:       conservation mode OFF (charges to 100%)"
            fi
            ;;
        *) echo "cap:       unsupported on this hardware" ;;
    esac
    systemctl is-enabled battery-limit.service &>/dev/null &&
        echo "at boot:   enabled" || echo "at boot:   not enabled"
}

case "${1:-status}" in
    status|"")  status ;;
    detect)     detect ;;
    apply)
        need_root "$@"
        stop=$(read_conf); rc=0
        while read -r bat; do
            apply_to "$bat" "$stop" || rc=1
        done < <(batteries)
        exit $rc
        ;;
    full|100)
        need_root "$@"
        write_conf 100
        rc=0
        while read -r bat; do apply_to "$bat" 100 || rc=1; done < <(batteries)
        (( rc == 0 )) && echo "travel mode: charging to 100%"
        status
        exit $rc
        ;;
    [0-9]|[0-9][0-9])
        need_root "$@"
        want="$1"
        if (( want < 40 )); then
            echo "refusing ${want}%: below ~40% the cap fights normal use and the" >&2
            echo "gauge decalibrates fast. 60-80 is the useful range." >&2
            exit 1
        fi
        write_conf "$want"
        rc=0
        while read -r bat; do apply_to "$bat" "$want" || rc=1; done < <(batteries)
        if (( rc != 0 )); then
            echo "the driver rejected ${want}% — some firmware accepts only fixed steps" >&2
            echo "(often 60/80/100). Try one of those." >&2
        fi
        status
        exit $rc
        ;;
    -h|--help)
        echo "usage: battery-limit {status|<40-100>|full|apply|detect}"
        ;;
    *)
        echo "usage: battery-limit {status|<40-100>|full|apply|detect}" >&2
        exit 1
        ;;
esac
BATLIM
    chmod +x /usr/local/bin/battery-limit
}

# sysfs thresholds do not survive a reboot, and several drivers drop them across
# suspend or when the AC adapter is re-plugged. Boot alone is not enough.
install_battery_limit_service() {
    cat > /etc/systemd/system/battery-limit.service <<'BATSVC'
[Unit]
Description=Apply battery charge threshold
Documentation=man:systemd.sleep(7)
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
ConditionPathExists=/usr/local/bin/battery-limit

[Service]
Type=oneshot
ExecStart=/usr/local/bin/battery-limit apply
RemainAfterExit=no

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
BATSVC

    # WantedBy=multi-user covers boot; the sleep targets combined with After=
    # make the same unit run on the way OUT of suspend, which is when several
    # ideapad and asus-wmi models have quietly reset the threshold.
    #
    # The udev rule catches the third case: the battery being re-added on an AC
    # transition. It starts the unit rather than running the tool directly so
    # udev is not blocked on sysfs writes, and apply skips no-op writes so the
    # change event it would otherwise emit cannot feed back into this rule.
    cat > /etc/udev/rules.d/99-battery-limit.rules <<'BATUDEV'
ACTION=="add|change", SUBSYSTEM=="power_supply", ATTR{type}=="Battery", \
    RUN+="/usr/bin/systemctl start --no-block battery-limit.service"
BATUDEV

    step "Enable battery-limit at boot and after resume" bash -c \
        'systemctl daemon-reload && systemctl enable battery-limit.service && udevadm control --reload-rules'
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

section_heroic() {
    header "HEROIC — GOG / Epic / Amazon library launcher"

    step "Flatpak + Flathub" ensure_flatpak
    step "Install Heroic Games Launcher" \
        flatpak install -y --noninteractive flathub com.heroicgameslauncher.hgl

    ok "GOG Galaxy has no Linux client yet (announced Jul 2026, no release date)"
    ok "Overlaps Lutris — Heroic is store-first (log in, install, play);"
    ok "Lutris is the full platform (emulators, install scripts, custom runners)."
}

section_faugus() {
    header "FAUGUS — minimal UMU/Proton launcher for Windows games"

    # Deliberately the COPR (native) build, NOT the Flatpak: the Flatpak has
    # known breakage (gamescope doesn't work, the 'stop' button won't close
    # games, themes). The native build integrates with the gamescope/MangoHud/
    # GameMode stack installed by the 'gaming' section.
    # The upstream author's own COPR, rebuilt within days (last Jul 2026).
    if ! copr_enable_guarded faugus/faugus-launcher faugus-launcher; then
        err "Faugus COPR unusable on Fedora $FEDORA_VER — section skipped"
        FAILED_STEPS+=("faugus-launcher — COPR has no packages for F$FEDORA_VER")
        return
    fi

    step "Install Faugus Launcher" dnf -y install faugus-launcher

    ok "Built-in Proton manager (GE-Proton / Proton-EM). Overlaps Lutris —"
    ok "Faugus is the simple 'point at an .exe' option; Lutris is the full platform."
}

section_creative() {
    header "CREATIVE — image/video/audio/3D suite (Flathub)"

    # Flatpak wins outright here, so Flatpak it is. All five are published on
    # Flathub by their own upstreams and track releases immediately, while
    # Fedora's builds trail — Blender and Kdenlive worst of all. And none of
    # them needs host integration: they are self-contained desktop apps, so the
    # argument that keeps Steam/OBS native (talking to the gaming stack, kernel
    # modules, daemons) simply does not apply.
    #
    # This section is optional and can run alone (--only creative), so ensure
    # Flathub exists instead of assuming the 'flatpak' section ran first.
    step "Flatpak + Flathub" ensure_flatpak

    step "GIMP" \
        flatpak install -y --noninteractive flathub org.gimp.GIMP
    step "Inkscape" \
        flatpak install -y --noninteractive flathub org.inkscape.Inkscape
    step "Kdenlive" \
        flatpak install -y --noninteractive flathub org.kde.kdenlive
    step "Audacity" \
        flatpak install -y --noninteractive flathub org.audacityteam.Audacity
    step "Blender" \
        flatpak install -y --noninteractive flathub org.blender.Blender
}

section_apps() {
    header "APPS — communication & music (Flatpaks)"

    step "Flatpak + Flathub" ensure_flatpak
    step "Vesktop (Discord with proper Wayland screenshare)" \
        flatpak install -y --noninteractive flathub dev.vencord.Vesktop
    step "Spotify" \
        flatpak install -y --noninteractive flathub com.spotify.Client
    step "Telegram" \
        flatpak install -y --noninteractive flathub org.telegram.desktop
}

section_mycomputer() {
    header "MY COMPUTER — drives & volumes panel for GNOME Files"

    # Gated on Nautilus itself, not on has_gnome: this is a Nautilus extension,
    # and Nautilus is perfectly installable next to Plasma or COSMIC. Checking
    # for gnome-shell would refuse a setup that actually works and accept a
    # GNOME install where the user swapped Files out.
    if ! has_nautilus; then
        warn "Nautilus is not installed — nothing to extend. Section skipped."
        return
    fi

    # Upstream's own COPR, which only builds for Fedora 43+ (the README claims
    # 41-44, but the repo is empty below 43). The guard turns that into a clean
    # skip instead of a dead repo left behind on the system.
    if ! copr_enable_guarded yannmasoch/nautilus-my-computer nautilus-my-computer; then
        err "my-computer COPR unusable on Fedora $FEDORA_VER — section skipped"
        FAILED_STEPS+=("nautilus-my-computer — COPR has no packages for F$FEDORA_VER")
        return
    fi

    step "Install My Computer for GNOME Files" dnf -y install nautilus-my-computer

    local nver
    nver=$(rpm -q --qf '%{VERSION}' nautilus 2>/dev/null)
    nver=${nver%%.*}
    if [[ "$nver" =~ ^[0-9]+$ ]] && (( nver < 50 )); then
        warn "GNOME Files $nver — the panel loads, but the full feature set needs Files 50+"
    fi

    # Not the documented nautilus-python provider API (MenuProvider and friends):
    # it injects into Nautilus' internal widget tree, which upstream GNOME makes
    # no stability promise about. That is precisely why this section is optional.
    ok "Restart Files to see the panel:  nautilus -q"
    ok "Hooks into Nautilus internals, not the stable extension API — a GNOME"
    ok "major bump can break it. Back out with: sudo dnf remove nautilus-my-computer"
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
        --battery)     if [[ -z "${2:-}" ]]; then
                           err "--battery needs a verb: <40-100>|full|status|apply"; exit 1
                       elif command -v battery-limit >/dev/null 2>&1; then
                           exec battery-limit "$2"
                       else
                           err "battery-limit not installed — run with --with battery first"
                           exit 1
                       fi ;;
        --list)        printf 'default:  %s\n' "${DEFAULT_SECTIONS[*]}"
                       printf 'optional: %s\n' "${OPTIONAL_SECTIONS[*]}"; exit 0 ;;
        -h|--help)     usage; exit 0 ;;
        *)             err "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
validate_sections --only "$ONLY_SECTIONS"
validate_sections --skip "$SKIP_SECTIONS"
validate_sections --with "$WITH_SECTIONS"

require_root "${ORIGINAL_ARGS[@]}"
require_fedora
require_mutable_system
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
    NVIDIA_BRANCH=$(nvidia_branch)
    warn "NVIDIA checklist before reboot:"
    warn "  1. modinfo -F version nvidia   → must print a version"
    if [[ -n "$NVIDIA_BRANCH" ]]; then
        warn "     This GPU needs the ${NVIDIA_BRANCH%xx}.x branch — a version from any"
        warn "     other branch means the module will not drive the card."
    fi
    warn "  2. If Secure Boot: expect the MOK Manager screen on reboot"
fi
# Third-party repos are the usual reason `dnf system-upgrade` fails: a COPR or
# vendor repo with no chroot for the new release stops the transaction dead. The
# COPRs we enable get skip_if_unavailable, but vendor repos (Docker, VS Code,
# RPM Fusion) do not — so list everything non-Fedora while the user is looking.
header "THIRD-PARTY REPOSITORIES"
mapfile -t EXTRA_REPOS < <(dnf repolist --enabled 2>/dev/null |
    awk 'NR>1 && $1 !~ /^(fedora|updates|repo|Last)/ {print $1}')
if [[ ${#EXTRA_REPOS[@]} -gt 0 ]]; then
    warn "These are not Fedora repos. Before a 'dnf system-upgrade', disable any"
    warn "that has not published packages for the new release:"
    for r in "${EXTRA_REPOS[@]}"; do warn "  - $r"; done
    warn "Disable one:  dnf config-manager setopt <repo-id>.enabled=0"
else
    ok "No third-party repositories enabled"
fi

warn "Reboot recommended:  systemctl reboot"
