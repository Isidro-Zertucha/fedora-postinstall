#!/usr/bin/env bash
#
# kde-gnomify.sh — make KDE Plasma 6 look and behave like GNOME
#
# Target look:
#   Thin top panel (centred clock, weather + system tray on the right)
#   Floating centred dock at the bottom (Icons-Only Task Manager, dash style)
#   Meta key -> Overview (window + app grid, the way GNOME does it)
#   Neutral dark colour scheme on the Adwaita palette (no Breeze blue)
#   Papirus-Dark icons, Cantarell typography
#   Rounded corners: stock Breeze — no Klassy, so nothing to maintain
#
# Usage:
#   ./kde-gnomify.sh                     # everything
#   ./kde-gnomify.sh --no-packages       # skip the dnf phase (never asks for sudo)
#   ./kde-gnomify.sh --no-panels         # leave the current panel layout alone
#   ./kde-gnomify.sh --wallpaper-accent  # accent colour follows the wallpaper
#   ./kde-gnomify.sh --yes               # don't ask before rebuilding panels
#   ./kde-gnomify.sh --restore           # roll back the newest backup and exit
#
# Run it from inside the Plasma session you want to restyle, as your normal
# user. NEVER as root: the user phases write to $HOME, and one root-owned
# config file there is enough to break the session. Only the package phase
# calls sudo, and only for dnf.
#
# Every phase is idempotent and re-running is safe. Configs are backed up
# before anything is touched; --restore puts them back in one command.
#
# ---------------------------------------------------------------------------
# VERIFIED vs ASSUMED — project rule: nothing invented
# ---------------------------------------------------------------------------
# VERIFIED:
#   Since Plasma 6.1 modifier-only shortcuts (Meta) live in
#   ~/.config/kglobalshortcutsrc, NOT in kwinrc [ModifierOnlyShortcuts] —
#   that method is obsolete. Sources: KDE "This week in KDE" Apr-2024,
#   lorenzobettini.it Jun-2024, forums.opensuse.org.
#   Adwaita dark palette (documented libadwaita values): window #242424,
#   view #1e1e1e, headerbar #303030, accent #3584e4.
#   Plasma's weather widget is org.kde.plasma.weather.
#
# ASSUMED — every one of these is now checked at runtime instead of trusted,
# because none could be verified while writing this:
#   1. qdbus binary name on current Fedora KDE — probed across qdbus6 /
#      qdbus-qt6 / qdbus.
#   2. panel.floating and panel.lengthMode="fit" in the Plasma 6 scripting
#      API — present in the develop.kde.org docs, minimum version unconfirmed.
#      The panel script reports back instead of failing silently.
#   3. Fedora's Cantarell package name — abattis-cantarell-vf-fonts is tried
#      first, then abattis-cantarell-fonts.
#   4. accentColorFromWallpaper in kdeglobals [General] — only written with
#      --wallpaper-accent, and read back afterwards.
#   5. The Overview entry format in kglobalshortcutsrc — community-documented
#      tab-separated pattern, not official. Read back afterwards; if it did
#      not take, the exact GUI path is printed.
#   6. kdeplasma-addons shipping the weather widget on Fedora — the widget is
#      added inside a try/catch so its absence cannot break the whole panel.
# ---------------------------------------------------------------------------

set -uo pipefail

# ---------------------------------------------------------------------------
# Globals & helpers
# ---------------------------------------------------------------------------
REPO_RAW="https://raw.githubusercontent.com/Isidro-Zertucha/fedora-postinstall/main/kde-gnomify.sh"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kde-gnomify"
LOG_FILE="$STATE_DIR/kde-gnomify.log"
BACKUP_ROOT="$STATE_DIR/backups"
SCHEME_NAME="GnomishAdwaitaDark"

# Config files saved before any phase runs, and the exact set --restore puts back.
BACKUP_FILES=(kdeglobals kwinrc kglobalshortcutsrc \
              plasma-org.kde.plasma.desktop-appletsrc plasmashellrc)

DO_PACKAGES=1
DO_PANELS=1
WALLPAPER_ACCENT=0
ASSUME_YES=0
DO_RESTORE=0
BACKUP_DIR=""
QDBUS=""
FAILED_STEPS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

mkdir -p "$STATE_DIR" 2>/dev/null || true

# tee's stderr is dropped for the same reason as in fedora-postinstall.sh:
# early errors are printed before the log directory is guaranteed to exist.
log()    { echo -e "${BLUE}[*]${NC} $*" | tee -a "$LOG_FILE" 2>/dev/null; }
ok()     { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE" 2>/dev/null; }
warn()   { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE" 2>/dev/null; }
err()    { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE" 2>/dev/null; }
header() { echo -e "\n${BOLD}==> $*${NC}\n" | tee -a "$LOG_FILE" 2>/dev/null; }
die()    { err "$*"; exit 1; }

# Run a step; record failure but keep going. A dead weather widget must not
# cost you the colour scheme, so nothing here aborts the whole run.
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

step_soft() {
    local desc="$1"; shift
    log "$desc"
    if "$@" >>"$LOG_FILE" 2>&1; then ok "$desc"; else warn "skipped (optional): $desc"; fi
}

# $0 is a real path only when the file is on disk; run the documented
# bash -c "$(curl …)" one-liner and it is the '--' placeholder instead.
if [[ -f "$0" ]]; then
    SELF="$0"
else
    SELF="bash -c \"\$(curl -fsSL $REPO_RAW)\" --"
fi

usage() {
    cat <<USAGE
kde-gnomify.sh — make KDE Plasma 6 look and behave like GNOME.

Usage:
  ./kde-gnomify.sh [flags]
  bash -c "\$(curl -fsSL $REPO_RAW)" -- [flags]

Flags:
  --no-packages        Skip the dnf phase (runs without ever calling sudo)
  --no-panels          Leave the current panel layout untouched
  --wallpaper-accent   Let the accent colour follow the wallpaper
  --yes                Do not ask before rebuilding panels
  --restore            Restore the newest config backup and exit
  -h, --help           This text

What it changes:
  packages    papirus-icon-theme, kdeplasma-addons, Cantarell fonts
  colours     $SCHEME_NAME colour scheme (Adwaita dark palette)
  icons       Papirus-Dark, plus Cantarell for UI/menu/toolbar/titlebar fonts
  shortcut    Meta opens the Overview instead of the application launcher
  effects     fade, scale, slide, magic lamp; squash off
  panels      DESTRUCTIVE: removes every panel, builds a top bar and a dock

Notes:
  Run it as your normal user, inside the Plasma session you want to restyle.
  Configs are backed up to $BACKUP_ROOT before anything is written.
  Roll back at any time with:  $SELF --restore
  Full log: $LOG_FILE
USAGE
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
require_not_root() {
    if [[ $EUID -eq 0 ]]; then
        err "Do not run this as root."
        err "The user phases write to \$HOME, and a root-owned config file there"
        err "is enough to break your Plasma session. Run it as yourself —"
        err "the package phase calls sudo on its own when it needs to."
        exit 1
    fi
}

require_plasma6() {
    local bin
    for bin in kwriteconfig6 kreadconfig6 plasma-apply-colorscheme; do
        command -v "$bin" >/dev/null 2>&1 || die "$bin not found — is this Plasma 6?"
    done
}

# Probed rather than hardcoded: the Qt6 tools package renames this binary
# across distributions and releases.
detect_qdbus() {
    local cand
    for cand in qdbus6 qdbus-qt6 qdbus; do
        if command -v "$cand" >/dev/null 2>&1; then QDBUS="$cand"; return 0; fi
    done
    die "No qdbus/qdbus6/qdbus-qt6 found (package qt6-qttools on Fedora)."
}

# Over SSH or from a TTY every D-Bus call below fails while kwriteconfig6 keeps
# succeeding, which leaves the config half-written and the desktop untouched.
# Refuse that outright instead of reporting a success nobody can see.
require_live_session() {
    if ! "$QDBUS" org.kde.plasmashell /PlasmaShell >/dev/null 2>&1; then
        err "plasmashell is not answering on D-Bus."
        err "Run this inside the Plasma session you want to restyle — from a TTY"
        err "or over SSH half of these settings silently do nothing."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Verification helpers
# ---------------------------------------------------------------------------
# kwriteconfig6 exits 0 whether or not the key landed where you think it did,
# so anything that matters is read back. A wrong group name or a renamed key
# is otherwise indistinguishable from success.
verify_key() {
    local desc="$1" file="$2" group="$3" key="$4" want="$5" got
    got=$(kreadconfig6 --file "$file" --group "$group" --key "$key" 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
        ok "$desc"
    else
        warn "$desc — did not take (wanted '$want', got '${got:-<empty>}')"
        FAILED_STEPS+=("$desc")
    fi
}

# ---------------------------------------------------------------------------
# Backup / restore
# ---------------------------------------------------------------------------
backup_configs() {
    local stamp dest f saved=0
    stamp=$(date +%Y%m%d-%H%M%S)
    dest="$BACKUP_ROOT/$stamp"
    mkdir -p "$dest" || die "Cannot create backup directory: $dest"

    for f in "${BACKUP_FILES[@]}"; do
        if [[ -f "$HOME/.config/$f" ]]; then
            cp -a "$HOME/.config/$f" "$dest/" && saved=$((saved + 1))
        fi
    done

    ln -sfn "$dest" "$BACKUP_ROOT/latest"
    BACKUP_DIR="$dest"
    ok "Backed up $saved config file(s) to $dest"
}

# Restores the files that were saved. A config that did not exist before the
# run is left in place — it has no "previous" state to return to, and deleting
# files the user may have edited since is worse than leaving them.
restore_backup() {
    local src f restored=0
    src="$BACKUP_ROOT/latest"
    [[ -d "$src" ]] || die "No backup found under $BACKUP_ROOT"

    header "RESTORE — $(readlink -f "$src" 2>/dev/null || echo "$src")"
    for f in "${BACKUP_FILES[@]}"; do
        if [[ -f "$src/$f" ]]; then
            cp -a "$src/$f" "$HOME/.config/$f" && { ok "restored $f"; restored=$((restored + 1)); }
        fi
    done
    [[ $restored -eq 0 ]] && die "Backup directory holds no known config files"

    # Restoring from a TTY is a supported path, so a dead plasmashell is not an
    # error here — the files are already back and take effect at next login.
    if "$QDBUS" org.kde.plasmashell /PlasmaShell >/dev/null 2>&1; then
        restart_plasmashell
    else
        warn "No live Plasma session — restored config applies at next login."
    fi
    warn "Log out and back in for icons, fonts and shortcuts to fully revert."
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
phase_packages() {
    header "PACKAGES — icons, widgets, fonts"

    if ! command -v dnf >/dev/null 2>&1; then
        warn "dnf not found — skipping the package phase (not a Fedora system?)"
        return
    fi

    step "Papirus icons + Plasma addons" sudo dnf install -y \
        papirus-icon-theme kdeplasma-addons

    step_soft "Cantarell font" bash -c \
        'sudo dnf install -y abattis-cantarell-vf-fonts ||
         sudo dnf install -y abattis-cantarell-fonts'
}

phase_colorscheme() {
    header "COLOURS — $SCHEME_NAME (Adwaita dark palette)"

    local dir="$HOME/.local/share/color-schemes"
    mkdir -p "$dir" || { err "Cannot create $dir"; FAILED_STEPS+=("colour scheme"); return; }

    cat > "$dir/$SCHEME_NAME.colors" <<'COLORS'
[ColorEffects:Disabled]
ColorAmount=0.3
ColorEffect=2
ContrastAmount=0.1
ContrastEffect=0
IntensityAmount=-1
IntensityEffect=0

[ColorEffects:Inactive]
ChangeSelectionColor=true
ColorAmount=0.5
ColorEffect=3
ContrastAmount=0
ContrastEffect=0
Enable=true
IntensityAmount=0
IntensityEffect=0

[Colors:Button]
BackgroundAlternate=48,48,48
BackgroundNormal=55,55,55
DecorationFocus=53,132,228
DecorationHover=53,132,228
ForegroundActive=53,132,228
ForegroundInactive=154,153,150
ForegroundLink=120,174,237
ForegroundNegative=192,28,40
ForegroundNeutral=229,165,10
ForegroundNormal=255,255,255
ForegroundPositive=38,162,105
ForegroundVisited=192,97,203

[Colors:Header]
BackgroundAlternate=36,36,36
BackgroundNormal=48,48,48
DecorationFocus=53,132,228
DecorationHover=53,132,228
ForegroundActive=53,132,228
ForegroundInactive=154,153,150
ForegroundLink=120,174,237
ForegroundNegative=192,28,40
ForegroundNeutral=229,165,10
ForegroundNormal=255,255,255
ForegroundPositive=38,162,105
ForegroundVisited=192,97,203

[Colors:Selection]
BackgroundAlternate=53,132,228
BackgroundNormal=53,132,228
DecorationFocus=53,132,228
DecorationHover=53,132,228
ForegroundActive=255,255,255
ForegroundInactive=222,235,252
ForegroundLink=253,253,253
ForegroundNegative=255,161,155
ForegroundNeutral=255,221,157
ForegroundNormal=255,255,255
ForegroundPositive=153,255,204
ForegroundVisited=219,206,255

[Colors:Tooltip]
BackgroundAlternate=42,42,42
BackgroundNormal=48,48,48
DecorationFocus=53,132,228
DecorationHover=53,132,228
ForegroundActive=53,132,228
ForegroundInactive=154,153,150
ForegroundLink=120,174,237
ForegroundNegative=192,28,40
ForegroundNeutral=229,165,10
ForegroundNormal=255,255,255
ForegroundPositive=38,162,105
ForegroundVisited=192,97,203

[Colors:View]
BackgroundAlternate=36,36,36
BackgroundNormal=30,30,30
DecorationFocus=53,132,228
DecorationHover=53,132,228
ForegroundActive=53,132,228
ForegroundInactive=154,153,150
ForegroundLink=120,174,237
ForegroundNegative=192,28,40
ForegroundNeutral=229,165,10
ForegroundNormal=255,255,255
ForegroundPositive=38,162,105
ForegroundVisited=192,97,203

[Colors:Window]
BackgroundAlternate=48,48,48
BackgroundNormal=36,36,36
DecorationFocus=53,132,228
DecorationHover=53,132,228
ForegroundActive=53,132,228
ForegroundInactive=154,153,150
ForegroundLink=120,174,237
ForegroundNegative=192,28,40
ForegroundNeutral=229,165,10
ForegroundNormal=255,255,255
ForegroundPositive=38,162,105
ForegroundVisited=192,97,203

[Colors:Complementary]
BackgroundAlternate=36,36,36
BackgroundNormal=30,30,30
DecorationFocus=53,132,228
DecorationHover=53,132,228
ForegroundActive=53,132,228
ForegroundInactive=154,153,150
ForegroundLink=120,174,237
ForegroundNegative=192,28,40
ForegroundNeutral=229,165,10
ForegroundNormal=255,255,255
ForegroundPositive=38,162,105
ForegroundVisited=192,97,203

[General]
ColorScheme=GnomishAdwaitaDark
Name=Gnomish Adwaita Dark
shadeSortColumn=true

[KDE]
contrast=4

[WM]
activeBackground=48,48,48
activeBlend=255,255,255
activeForeground=255,255,255
inactiveBackground=36,36,36
inactiveBlend=154,153,150
inactiveForeground=154,153,150
COLORS

    step "Apply colour scheme" plasma-apply-colorscheme "$SCHEME_NAME"
}

phase_icons_fonts() {
    header "ICONS & FONTS — Papirus-Dark, Cantarell"

    kwriteconfig6 --file kdeglobals --group Icons --key Theme "Papirus-Dark"
    verify_key "Papirus-Dark icons" kdeglobals Icons Theme "Papirus-Dark"

    if fc-list 2>/dev/null | grep -qi cantarell; then
        # KDE font format: "Family,size,…" — the rest of the fields are the
        # Qt font descriptor and are left at their stock values.
        local ui="Cantarell,11,-1,5,50,0,0,0,0,0"
        kwriteconfig6 --file kdeglobals --group General --key font "$ui"
        kwriteconfig6 --file kdeglobals --group General --key menuFont "$ui"
        kwriteconfig6 --file kdeglobals --group General --key toolBarFont "Cantarell,10,-1,5,50,0,0,0,0,0"
        kwriteconfig6 --file kdeglobals --group WM --key activeFont "Cantarell,11,-1,5,57,0,0,0,0,0"
        verify_key "Cantarell UI font" kdeglobals General font "$ui"
    else
        warn "Cantarell not visible to fontconfig — fonts left unchanged"
        FAILED_STEPS+=("Cantarell font (not installed)")
    fi
}

phase_overview_shortcut() {
    header "SHORTCUT — Meta opens the Overview"

    kwriteconfig6 --file kglobalshortcutsrc --group kwin --key "Overview" \
        "$(printf 'Meta\tMeta+W,Meta+W,Toggle Overview')"
    "$QDBUS" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true

    # Compared loosely on purpose: KConfig re-escapes the tab separator, so an
    # exact string match would report a false failure on a key that did land.
    local got
    got=$(kreadconfig6 --file kglobalshortcutsrc --group kwin --key Overview 2>/dev/null)
    if [[ "$got" == *Meta* ]]; then
        ok "Overview bound to Meta"
        warn "Still opening the launcher? System Settings > Shortcuts > KWin >"
        warn "  'Toggle Overview' > assign Meta. Ten seconds in the GUI."
    else
        warn "Overview shortcut did not take (got '${got:-<empty>}')"
        warn "Set it by hand: System Settings > Shortcuts > KWin > 'Toggle Overview'"
        FAILED_STEPS+=("Meta -> Overview shortcut")
    fi
}

phase_effects() {
    header "EFFECTS — GNOME-ish transitions"

    # Most of these ship enabled on Plasma 6; written anyway so a machine that
    # had them off ends up in the same state as one that had them on.
    kwriteconfig6 --file kwinrc --group Plugins --key overviewEnabled true
    kwriteconfig6 --file kwinrc --group Plugins --key fadeEnabled true
    kwriteconfig6 --file kwinrc --group Plugins --key scaleEnabled true
    kwriteconfig6 --file kwinrc --group Plugins --key slideEnabled true
    kwriteconfig6 --file kwinrc --group Plugins --key kwin4_effect_squashEnabled false
    kwriteconfig6 --file kwinrc --group Plugins --key magiclampEnabled true
    "$QDBUS" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true

    verify_key "KWin Overview effect" kwinrc Plugins overviewEnabled "true"
    ok "fade, scale, slide and magic lamp configured"
}

phase_wallpaper_accent() {
    header "ACCENT — follow the wallpaper"

    kwriteconfig6 --file kdeglobals --group General --key accentColorFromWallpaper true
    verify_key "Accent from wallpaper" kdeglobals General accentColorFromWallpaper "true"
}

# ---------------------------------------------------------------------------
# Panels — the one destructive phase
# ---------------------------------------------------------------------------
confirm_panel_wipe() {
    [[ $ASSUME_YES -eq 1 ]] && return 0

    if [[ ! -t 0 ]]; then
        warn "Panel rebuild needs confirmation and stdin is not a terminal."
        warn "Re-run with --yes to accept it, or --no-panels to skip. Skipping."
        return 1
    fi

    echo
    warn "The panel phase DELETES every panel you currently have and builds two"
    warn "new ones. Your layout, widgets and pinned launchers go with them."
    warn "Backup already taken: $BACKUP_DIR"
    local reply
    read -rp "$(echo -e "${BOLD}Rebuild panels? [y/N]${NC} ")" reply || return 1
    [[ "$reply" =~ ^[yY]([eE][sS])?$ ]]
}

# The weather widget is added inside try/catch so a missing kdeplasma-addons
# costs you the widget, not the panel. The trailing sentinel is how success is
# told apart from failure — see apply_panel_layout.
panel_script() {
    cat <<'JS'
panels().forEach(function (p) { p.remove(); });

var top = new Panel;
top.location = "top";
top.height = Math.round(gridUnit * 1.6);
top.floating = false;
top.hiding = "none";
top.addWidget("org.kde.plasma.kickoff");
top.addWidget("org.kde.plasma.panelspacer");
top.addWidget("org.kde.plasma.digitalclock");
top.addWidget("org.kde.plasma.panelspacer");
try { top.addWidget("org.kde.plasma.weather"); } catch (e) { }
top.addWidget("org.kde.plasma.systemtray");

var dock = new Panel;
dock.location = "bottom";
dock.height = Math.round(gridUnit * 2.4);
dock.floating = true;
dock.lengthMode = "fit";
dock.hiding = "none";
dock.addWidget("org.kde.plasma.icontasks");

"KDE_GNOMIFY_OK";
JS
}

apply_panel_layout() {
    local reply rc
    reply=$("$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
        "$(panel_script)" 2>&1)
    rc=$?

    # Plasma hands JavaScript errors back in the D-Bus reply body and still
    # exits 0, so the exit status alone would call a wrecked layout a success.
    # Both engine behaviours are accepted: an empty reply, or one carrying the
    # sentinel. Anything else is the error text.
    if [[ $rc -ne 0 ]]; then
        err "Panel script: D-Bus call failed (exit $rc)"
        err "Roll back with:  $SELF --restore"
        FAILED_STEPS+=("panel layout")
        return 1
    fi
    if [[ -n "$reply" && "$reply" != *KDE_GNOMIFY_OK* ]]; then
        err "Panel script failed: $reply"
        err "Roll back with:  $SELF --restore"
        FAILED_STEPS+=("panel layout")
        return 1
    fi

    ok "Panels rebuilt — top bar + floating dock"
}

phase_panels() {
    header "PANELS — top bar + floating dock (DESTRUCTIVE)"

    if ! confirm_panel_wipe; then
        warn "Panel rebuild declined — layout left as it was"
        return
    fi
    apply_panel_layout
}

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------
restart_plasmashell() {
    log "Restarting plasmashell"
    if systemctl --user restart plasma-plasmashell.service 2>/dev/null; then
        ok "plasmashell restarted via systemd"
    else
        kquitapp6 plasmashell 2>/dev/null || killall plasmashell 2>/dev/null || true
        (kstart plasmashell >/dev/null 2>&1 &)
        ok "plasmashell relaunched (fallback)"
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-packages)      DO_PACKAGES=0; shift ;;
        --no-panels)        DO_PANELS=0; shift ;;
        --wallpaper-accent) WALLPAPER_ACCENT=1; shift ;;
        --yes|-y)           ASSUME_YES=1; shift ;;
        --restore)          DO_RESTORE=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  err "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_not_root
require_plasma6
detect_qdbus

# --restore runs BEFORE the live-session check on purpose. If the panel rebuild
# wrecked the session badly enough, a TTY is all you have left — and that is
# precisely the moment the rollback has to work. Gating it behind "is plasmashell
# answering?" would disable the recovery path exactly when it is needed.
if [[ $DO_RESTORE -eq 1 ]]; then
    restore_backup
    exit 0
fi

require_live_session
log "Using qdbus binary: $QDBUS"

header "kde-gnomify — Plasma 6 the GNOME way (log: $LOG_FILE)"

backup_configs

if [[ $DO_PACKAGES -eq 1 ]]; then
    phase_packages
else
    warn "Package phase skipped (--no-packages)"
fi

phase_colorscheme
phase_icons_fonts
phase_overview_shortcut
phase_effects
[[ $WALLPAPER_ACCENT -eq 1 ]] && phase_wallpaper_accent

if [[ $DO_PANELS -eq 1 ]]; then
    phase_panels
else
    warn "Panel layout skipped (--no-panels)"
fi

restart_plasmashell

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "DONE"
if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
    err "Some steps did not land:"
    for f in "${FAILED_STEPS[@]}"; do err "  - $f"; done
    warn "Re-running is safe; it only redoes what is still missing."
else
    ok "Everything applied."
fi

echo
ok "Manual bits, once:"
echo "  1. Weather: click the panel widget > Configure > pick your location."
echo "  2. Pin your apps to the dock: right-click an icon > Pin."
echo "  3. Icons, fonts and shortcuts settle fully after a log out and back in."
echo
warn "Full rollback:  $SELF --restore"
