# fedora-postinstall

An opinionated, **idempotent** post-install script for **Fedora Workstation** (GNOME, KDE Plasma & COSMIC).
Codecs, hardware video acceleration, NVIDIA with Secure Boot signing, Flatpak, a gaming stack,
Btrfs snapshots, a dev environment, virtualization, and quality-of-life tooling — one command, safe to re-run.

Desktop-aware and GPU-aware: it detects your hardware and desktop and only installs what fits.

A companion script, [`kde-gnomify.sh`](#companion-kde-gnomifysh), restyles KDE Plasma 6 to look and
behave like GNOME. Separate script, separate command — it is not part of the post-install run.

---

## Quick start

> Requires **Fedora Workstation** and a user with `sudo`. Nothing is installed until you run it.
> Image-based Fedora (Silverblue, Kinoite, **COSMIC Atomic**, Bazzite) is **not supported**: the
> script detects the ostree deployment and aborts instead of failing halfway through.

### Run it straight from GitHub (no download)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Isidro-Zertucha/fedora-postinstall/main/fedora-postinstall.sh)"
```

With flags — everything after `--` is passed to the script:

```bash
# Add optional sections
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Isidro-Zertucha/fedora-postinstall/main/fedora-postinstall.sh)" -- --with gametweaks,lutris

# Skip NVIDIA even if a card is present
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Isidro-Zertucha/fedora-postinstall/main/fedora-postinstall.sh)" -- --no-nvidia

# Only a couple of sections
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Isidro-Zertucha/fedora-postinstall/main/fedora-postinstall.sh)" -- --only codecs,gaming
```

> **Why `bash -c "$(curl …)"` and not `curl … | sudo bash`?**
> With a pipe, the script's **stdin becomes the download stream**, so interactive prompts break —
> in particular the **Secure Boot MOK password** prompt (`mokutil --import`) in the NVIDIA section.
> The command-substitution form keeps stdin attached to your terminal, so those prompts work, and
> it lets you pass flags naturally.

### Review first, then run (recommended for any root script)

You're piping code that runs as **root** and touches repos, kernel args, and sudoers. Reading it
first is the responsible move:

```bash
curl -fsSLO https://raw.githubusercontent.com/Isidro-Zertucha/fedora-postinstall/main/fedora-postinstall.sh
less fedora-postinstall.sh          # read it
chmod +x fedora-postinstall.sh
sudo ./fedora-postinstall.sh --with gametweaks
```

Prefer to pick sections interactively instead of memorizing flags? Run the local file with `--menu`:

```bash
sudo ./fedora-postinstall.sh --menu
```

---

## What it installs

### Default sections (run in order)

| Section   | What it does |
|-----------|--------------|
| `base`    | dnf tuning (auto-probed parallel downloads), full update, RPM Fusion (free + nonfree + tainted), firmware updates via LVFS, faster boot, an `update-all` helper |
| `codecs`  | Full `ffmpeg`, GStreamer plugins, and per-GPU hardware video acceleration (AMD / Intel / NVIDIA) |
| `nvidia`  | Proprietary driver (akmod) + CUDA/NVENC, **open kernel modules** (needed for RTX 50-series), and **Secure Boot module signing** (MOK enrollment) — *auto-detected* |
| `flatpak` | Flathub (unfiltered) + Flatseal, plus Extension Manager on GNOME |
| `gaming`  | Steam, `steam-devices`, gamescope, MangoHud, GOverlay, vkBasalt, GameMode, protontricks, ProtonPlus, `vm.max_map_count` tweak |
| `snapper` | Btrfs snapshots + dnf integration + Btrfs Assistant GUI (skipped if root isn't Btrfs) |
| `media`   | OBS Studio + virtual camera (`v4l2loopback`), mpv, yt-dlp |
| `dev`     | git/gh/build tools, Docker CE, nvm (Node LTS), uv (Python), VS Code |
| `virt`    | KVM/QEMU + virt-manager |
| `qol`     | Archive formats, fonts, monitors (htop/btop/fastfetch), tldr, desktop-matched extras |

### Optional sections (only with `--with`)

| Section      | What it does |
|--------------|--------------|
| `legion`     | LenovoLegionLinux — community fan/power control (falls back to source instructions if COPR is stale) |
| `asus`       | asusctl + supergfxctl (ASUS laptops, asus-linux.org COPR) |
| `distrobox`  | Containerized dev environments (Podman-backed) |
| `wine`       | Wine + winetricks for non-Steam Windows software |
| `lutris`     | Lutris launcher (Epic / GOG / emulators / community install scripts) |
| `faugus`     | Faugus Launcher — minimal UMU/Proton launcher for individual Windows games (native COPR build; built-in GE-Proton manager). Overlaps `lutris`: pick the simple per-`.exe` tool (`faugus`) or the full platform (`lutris`) |
| `gametweaks` | `scx_lavd` scheduler as a **toggle** (stock kernel) + `split_lock_detect=off` |
| `creative`   | GIMP, Inkscape, Kdenlive, Audacity, Blender |
| `apps`       | Discord (Vesktop), Spotify, Telegram — Flatpaks |

---

## Flags

```
--menu                 Interactive picker: check/uncheck sections before running
--nvidia               Force NVIDIA setup even if no card is detected
--no-nvidia            Skip NVIDIA even if a card is present
--only  a,b,c          Run ONLY these sections
--skip  a,b,c          Run defaults EXCEPT these
--with  a,b,c          Add optional sections to the defaults
--parallel N           Force dnf parallel downloads (1–20); default: auto-probe the network
--scx VERB             Gaming scheduler toggle: on|off|status|boot-on|boot-off
--list                 List available sections and exit
-h, --help             Show usage (works both locally and via curl)
```

`--menu` opens a terminal checklist (defaults pre-checked, optionals off): type a number
to toggle a section, `a`/`n` for all/none, `d` to reset to defaults, Enter to install, `q` to
quit. It writes the checked set to `--only`, so it needs a real TTY — the `bash -c "$(curl …)"`
form above keeps one, so `--menu` works remotely too. Only the `curl | bash` **pipe** form breaks
it, because there stdin *is* the download stream.

Everything is **idempotent** — re-running only does what's still missing, and a failed step (one bad
repo, one missing package) is logged and skipped instead of aborting the whole run. Full log at
`/var/log/fedora-postinstall.log`.

---

## Runtime toggle: gaming scheduler

Installing `gametweaks` sets up `scx_lavd` (a latency-oriented `sched_ext` scheduler on Fedora's
stock kernel) **as a switch, not a default** — it helps games and hurts long compiles, so you flip
it per session:

```bash
scx-toggle on          # this session only (game session)
scx-toggle off         # back to the default scheduler (compile session)
scx-toggle boot-on     # persist across reboots
scx-toggle status      # show current state
```

Games launched with `gamemoderun %command%` flip it on/off **automatically** via GameMode hooks.

---

## After it finishes

If you have an NVIDIA GPU, **verify before rebooting**:

```bash
modinfo -F version nvidia    # must print a version number
```

- If **Secure Boot** is on, a blue **MOK Manager** screen appears on the next reboot:
  *Enroll MOK → Continue → Yes → enter the password you set → reboot.*
- Then reboot: `systemctl reboot`

Update everything later with the installed helper:

```bash
update-all               # dnf + flatpak + firmware, one command
```

---

## Companion: `kde-gnomify.sh`

Makes **KDE Plasma 6** look and behave like GNOME: thin top panel with a centred clock, floating dock
at the bottom, `Meta` opening the Overview, an Adwaita-dark colour scheme, Papirus-Dark icons and
Cantarell. Rounded corners come from stock Breeze — no Klassy, so there is nothing to maintain.

Note the missing `sudo`: the script **refuses to run as root** (a root-owned file in `~/.config` is
enough to break a Plasma session) and calls `sudo` itself, only for the package phase.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Isidro-Zertucha/fedora-postinstall/main/kde-gnomify.sh)"
```

```
--no-packages        Skip the dnf phase (then it never calls sudo at all)
--no-panels          Leave the current panel layout untouched
--wallpaper-accent   Accent colour follows the wallpaper
--yes                Don't ask before rebuilding panels
--restore            Restore the newest config backup and exit
-h, --help           Show usage
```

Run it **inside the Plasma session you want to restyle**. From a TTY or over SSH the D-Bus calls fail
while the config writes keep succeeding, which leaves you with a half-applied theme and no error — so
the script checks that `plasmashell` answers and refuses to start otherwise.

> **The panel phase is destructive.** It deletes every panel you have and builds two new ones, so it
> asks before doing it (`--yes` skips the prompt, `--no-panels` skips the phase). Every config it
> touches is backed up to `~/.local/state/kde-gnomify/backups/` first, and
> `kde-gnomify.sh --restore` puts the newest backup back and restarts plasmashell in one command.

Settings that could not be verified from a script — the Plasma panel API, the Overview shortcut
format, the Cantarell package name — are written and then **read back**, so anything that did not
land is reported with the GUI path to fix it by hand, instead of failing quietly.

---

## Requirements & notes

- **Fedora Workstation** (the script aborts on non-Fedora systems).
- **Package-based Fedora only.** On an ostree deployment (Silverblue, Kinoite, COSMIC Atomic,
  Bazzite) `/usr` is read-only and packages are layered with `rpm-ostree`, so the script refuses
  to run: `/etc/os-release` still says *fedora*, but every `dnf` transaction would fail while the
  steps that write `/etc`, sudoers and kernel args still land.
- **Desktop-aware.** GNOME gets Extension Manager, Tweaks and file-roller; KDE gets ark and
  filelight; COSMIC gets file-roller and baobab (`cosmic-settings` covers the rest). Everything
  else — codecs, drivers, gaming, dev, virt — is identical on all three.
- Run with `sudo`; user-level bits (Flatpak, nvm) are installed for the invoking user, not root.
- Some pieces (NVIDIA kmod, `v4l2loopback` virtual camera) build against your kernel and become
  active **after the next reboot**.

## License

[MIT](LICENSE).
