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

That is all. On a terminal with **no flags** it opens an **interactive picker** where you
check the sections you want (`x` = install, blank = skip). The defaults come pre-checked,
optionals start unchecked — press Enter to install exactly what is marked, or `n` to
uncheck everything and build your own set. `--menu` forces the picker; it is otherwise
the default behaviour whenever stdin is a terminal. Without a terminal (cron, SSH, a
pipe, an unattended script) the defaults run straight through instead, so nothing ever
hangs waiting on a prompt.

With flags, the picker is skipped — everything after `--` is passed to the script:

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

Prefer to pick sections interactively instead of memorizing flags? The local file does that
by default on a terminal; `--menu` forces the picker explicitly:

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
| `nvidia`  | Proprietary driver (akmod) + CUDA/NVENC, **driver branch matched to the GPU** (legacy `580xx`/`470xx`/`390xx` for pre-Turing cards), **open kernel modules** (needed for RTX 50-series), and **Secure Boot module signing** (MOK enrollment) — *auto-detected* |
| `flatpak` | Flathub (unfiltered) + Flatseal, Warehouse (rollback, runtimes, leftover user data) and Gear Lever (AppImage integration), plus Extension Manager on GNOME |
| `snapper` | Btrfs snapshots **around every dnf transaction** (dnf5 actions hook, verified at install time), **Btrfs Assistant** GUI, and a **GRUB snapshot submenu** (`grub-btrfs`) so a broken system can boot back into an older snapshot. Skipped if root isn't Btrfs. See [Snapshots and rollback](#snapshots-and-rollback-default-snapper-section) |
| `media`   | mpv + yt-dlp (the player and the downloader everyone appreciates), + **EasyEffects** (per-device EQ and mic noise reduction via RNNoise, a PipeWire effect chain) |
| `virt`    | KVM/QEMU + virt-manager |
| `qol`     | Archive formats, fonts, monitors (htop/btop/fastfetch + **Mission Center** for per-process GPU, VRAM and encoder load, which the terminal ones can't see), **Obsidian** (notes/PKM, via Flathub), **Aura** live wallpapers (GNOME support experimental), tldr, desktop-matched extras |

### Optional sections (only with `--with`)

| Section      | What it does |
|--------------|--------------|
| `privacy`    | Encrypted DNS (**DNS-over-TLS**) via systemd-resolved. **Quad9** by default — malware/phishing blocking, DNSSEC validation, no user IP logging. `--dns cloudflare` for the unfiltered alternative. Off unless you ask for it |
| `legion`     | LenovoLegionLinux — community fan/power control (falls back to source instructions if COPR is stale) |
| `asus`       | asusctl + supergfxctl (ASUS laptops, asus-linux.org COPR) |
| `battery`    | Charge threshold, default 80%, persisted across reboot **and** resume. Vendor-neutral: detected from the `power_supply` sysfs class, so Lenovo, ASUS, ThinkPad, Huawei and Framework are one code path. Installs the `battery-limit` tool |
| `peripherals`| Solaar (Logitech HID++ — pairing, battery, per-device settings), Piper + `ratbagd` (gaming mice — DPI, buttons and LEDs written to the mouse's onboard memory), OpenRGB, input-remapper. All from Fedora's own repos: no COPR, no out-of-tree module. None of them is a driver — `hid-logitech-hidpp` is in-tree and already handles the device — they are configuration front-ends |
| `distrobox`  | Containerized dev environments (Podman-backed) + DistroShelf GUI |
| `dev`        | git/gh/build tools, **Podman-as-Docker** (docker CLI alias, **Docker Compose v2** de referencia contra el socket Docker-API rootless — build de imágenes con `podman build` + `up --no-build`) + **Podman Desktop** (GUI), nvm (Node LTS), uv (Python), VS Code, the Go toolchain, and **DBeaver Community** (database IDE, via Flathub), and **Orca** (Stably's Agent Development Environment — run coding agents in parallel worktrees; its Linux CLI is `orca-ide`, so it never collides with the GNOME screen reader at `/usr/bin/orca`). Orca is installed from the latest `.rpm` on GitHub Releases — no vendor repository. Plus **OpenCode** (terminal AI coding agent, installed per-user via the official installer into `~/.opencode/bin` and wired into the shell rc) |
| `wine`       | Wine + winetricks for non-Steam Windows software |
| `lutris`     | Lutris launcher (Epic / GOG / emulators / community install scripts) |
| `heroic`     | Heroic Games Launcher (Flathub) — GOG, Epic and Amazon libraries. GOG Galaxy still has no Linux client (announced July 2026, no release date), so this is how you get a GOG library on Fedora. Overlaps `lutris`: Heroic is store-first, Lutris is the full platform |
| `faugus`     | Faugus Launcher — minimal UMU/Proton launcher for individual Windows games (native COPR build; built-in GE-Proton manager). Overlaps `lutris`: pick the simple per-`.exe` tool (`faugus`) or the full platform (`lutris`) |
| `gametweaks` | `scx_lavd` scheduler as a **toggle** (stock kernel) + `split_lock_detect=off` |
| `gaming`     | Steam, `steam-devices`, gamescope, MangoHud, GOverlay, vkBasalt, GameMode, protontricks, ProtonPlus, **Bottles** (GUI Wine-prefix manager, via Flathub), **Heronite** (multi-store game library and launcher, latest Fedora RPM with SHA-256 verification), `vm.max_map_count` tweak |
| `streaming` | OBS Studio + virtual camera (`v4l2loopback`) — screen capture and streaming. Split out of `media` on purpose: OBS is a niche tool and drags a kernel module with it, so it belongs behind an opt-in, while mpv/yt-dlp stay in the defaults |
| `creative`   | GIMP, Inkscape, Kdenlive, **Drift**, Audacity, Blender, draw.io. All Flatpaks: every one is published on Flathub by its own upstream and tracks releases immediately, while Fedora's builds trail (Blender and Kdenlive worst of all), and none of them needs host integration. Drift is the quick-export counterpart to Kdenlive (Qt6/FFmpeg, Reels/Shorts, no subscription); draw.io Desktop is the web editor with the network side cut out — no account, no upload, files stay local as diffable `.drawio` XML |
| `communication` | Vesktop (Discord, with working Wayland screenshare), Telegram, ZapZap (WhatsApp — the platform has no Linux client and no API, so every option wraps WhatsApp Web; ZapZap is the one with tray icon, native notifications and multi-account). All Flathub |
| `music`      | Spotify (Flathub) |
| `reading`    | Foliate e-book reader — EPUB/MOBI/FB2/CBZ, dark mode, notes. The one **native** entry among the app sections: Fedora packages it from the same upstream tags Flathub does, so the Flatpak buys no freshness and only adds a second WebKitGTK — and native reads books off any mounted drive without sandbox permissions |
| `browser`    | Brave (Chromium-based, Flathub build from Brave itself). Fedora's default browser stays Firefox; this section only installs an alternative. **No vendor RPM repo, deliberately** — Brave ships one channel with no per-Fedora chroots, the same upgrade risk that keeps ONLYOFFICE/Collabora off their vendor repos |
| `filesharing`| LocalSend (AirDrop-style device-to-device transfer over the LAN, no account — Flathub), FreeFileSync + RealTimeSync (comparison-first sync, Flathub), and Syncthing (continuous, private sync across your own devices — from Fedora's own repos, enabled per-user at boot, web UI at `localhost:8384`) |
| `photos`     | **Ente Photos**, an end-to-end encrypted photo backup app, installed from verified Flathub (`io.ente.photos`) |
| `onlyoffice` | ONLYOFFICE Desktop Editors (Flathub). See [Office suite: pick one](#office-suite-pick-one) |
| `collabora`  | Collabora Office (Flathub). See [Office suite: pick one](#office-suite-pick-one) |

### Snapshots and rollback (default `snapper` section)

This is the only thing in the script that undoes a bad update, so it is a default
section rather than an opt-in. It does four things:

1. Creates a snapper config for `/` (plus `/home` when that is its own Btrfs subvolume).
2. Enables `snapper-timeline.timer` **and** `snapper-cleanup.timer`. Fedora ships the
   first enabled and the second disabled, so snapshots accumulate with nothing pruning them.
3. Snapshots **every `dnf` transaction** through the dnf5 actions plugin
   (`/etc/dnf/libdnf5-plugins/actions.d/snapper.actions` plus two small hooks in
   `/usr/local/bin`). The dnf4 plugin `python3-dnf-plugin-snapper` is deliberately not
   used: it installs cleanly on Fedora 43+, dnf5 never loads it, and it produces zero
   snapshots while looking installed.
4. Adds a **snapshot submenu to GRUB** with `grub-btrfs` (COPR `kylegospo/grub-btrfs` —
   the package is not in Fedora's own repos) and unhides the boot menu, which Fedora
   hides after a successful boot.

The section then **verifies the hook**: it runs the pre/post pair once and requires a
linked snapshot to appear. A rollback plan that was never exercised is a guess.

**Recovery means booting a snapshot, not `snapper rollback`:**

- Choose the snapshot in the GRUB *snapshots* submenu, confirm it boots, then swap the
  `root` subvolume from inside that session.
- `snapper rollback` **does nothing on Fedora.** It cannot detect the boot layout
  (`root`/`home` subvolumes named on the kernel command line), and `--ambit classic`
  reports success while changing nothing after a reboot.
- **`/boot` is a separate ext4 partition**, so kernels and initramfs are *not* in the
  snapshot. A snapshot cannot undo a broken kernel — boot an older one instead (Fedora
  keeps three plus the rescue kernel by default, `installonly_limit=3`).
- `/var` sits inside `root` on a stock Workstation, so a root rollback also reverts
  journals, container images and VM disks.

These are rollback points on the same disk, not backups. Pair them with an off-machine
copy of `/home`.

Revert:

```bash
sudo rm -f /etc/dnf/libdnf5-plugins/actions.d/snapper.actions \
           /usr/local/bin/dnf-snapper-pre /usr/local/bin/dnf-snapper-post
sudo systemctl disable --now grub-btrfs-watch.path
sudo dnf copr remove kylegospo/grub-btrfs && sudo dnf -y remove grub-btrfs
```

### Encrypted DNS (`--with privacy`)

The `privacy` section is **off by default**. It enables `systemd-resolved` and writes
`/etc/systemd/resolved.conf.d/99-privacy.conf`, sending every DNS query over
**DNS-over-TLS (port 853)** to **Quad9**:

| Provider | Addresses | Notes |
|---|---|---|
| `quad9` (default) | `9.9.9.9`, `149.112.112.112` (+ IPv6) | Blocks malware/phishing/fraud at the DNS layer, validates DNSSEC, does not record user IPs (Swiss foundation) |
| `cloudflare` | `1.1.1.1`, `1.0.0.1` (+ IPv6) | No filtering; often a few ms faster on cold lookups |

```bash
sudo ./fedora-postinstall.sh --with privacy
sudo ./fedora-postinstall.sh --with privacy --dns cloudflare
```

`DNSOverTLS=yes` is strict — a resolver that cannot complete the TLS handshake is not
used — and `FallbackDNS=` is emptied so resolved never silently falls back to plaintext.
**If your network blocks port 853, DNS stops working**; remove the drop-in to revert.

A drop-in alone would not be enough. NetworkManager hands the DHCP resolvers to
`systemd-resolved` as **per-link** servers, and resolved queries those *in parallel* with
the global `DNS=` list, preferring the link for routed domains — so your router would still
receive plaintext queries. The section therefore also sets `ipv4.ignore-auto-dns` and
`ipv6.ignore-auto-dns` on every Ethernet and Wi-Fi profile, leaving the drop-in as the only
upstream. Profiles are re-applied in place (no link drop). A profile that carries its own
static `ipv4.dns` is reported but not rewritten — remove it if you want everything to go
through the drop-in.

Revert:

```bash
sudo rm -f /etc/systemd/resolved.conf.d/99-privacy.conf
sudo systemctl disable --now systemd-resolved
sudo ln -sfn ../run/NetworkManager/resolv.conf /etc/resolv.conf
# Restore the per-connection DNS values the script changed, then re-apply them:
bash /var/lib/fedora-postinstall/privacy-dns-revert.sh
sudo systemctl restart NetworkManager
# If the script backed up a regular resolv.conf, restore it instead of the symlink:
# sudo mv /etc/resolv.conf.pre-privacy /etc/resolv.conf
```

The script backs up a regular `/etc/resolv.conf` to `/etc/resolv.conf.pre-privacy` before
replacing it with the resolved stub symlink. It also generates
`/var/lib/fedora-postinstall/privacy-dns-revert.sh`, one `nmcli connection modify` line per
profile with the **exact** values that profile had before the run, so reverting does not
clobber a per-connection DNS setup you had configured by hand.

### Office suite: pick one

Fedora Workstation already ships **LibreOffice**, so a second suite has to earn its ~1 GB. Both
sections are optional and **mutually redundant** — install one, not both, or two apps end up
fighting over the `.docx`/`.xlsx` associations. Each section warns you if the other one (or
LibreOffice) is already present.

| | `onlyoffice` | `collabora` |
|---|---|---|
| **Engine** | OOXML is the **native** format | LibreOffice core |
| **Strong at** | `.docx` / `.xlsx` / `.pptx` round-trips | ODF and legacy formats |
| **UI** | Ribbon — shortest path off Office 365 | LibreOffice-derived, Collabora's shell |
| **Also does** | PDF and diagram editing | The full LibreOffice module set |

**The deciding fact:** LibreOffice converts OOXML into ODF on open and back out on save, and that
round-trip is where tracked changes, form fields and pivot-table layout get mangled in files that
came from Microsoft Office. ONLYOFFICE never does the conversion — that is the one thing Fedora's
preinstalled suite cannot give you. Collabora Office Desktop *is* LibreOffice core underneath, so
next to the LibreOffice you already have it mostly buys you Collabora's shell, QA and backports.

> If you do pick `collabora`: this is **Collabora Office Desktop**, launched November 2025.
> Collabora still point corporate/LTS deployments at *Collabora Office Classic* instead.

**Neither is installed from its vendor RPM repository, deliberately.** Both vendors publish a single
channel with no per-Fedora chroots, so the repo keeps resolving after Fedora branches and then stops
the next `dnf system-upgrade` dead — exactly the failure the *third-party repositories* summary at
the end of the run exists to warn about. The Flathub builds come from the same upstreams and update
with everything else via `update-all`.

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
--dns PROVIDER         Encrypted DNS for --with privacy: quad9 (default)|cloudflare
--scx VERB             Gaming scheduler toggle: on|off|status|boot-on|boot-off
--battery VERB         Charge cap: <40-100>|full|status|apply
--list                 List available sections and exit
-h, --help             Show usage (works both locally and via curl)
```

`--menu` opens a terminal checklist (defaults pre-checked, optionals off). The highlight
stays **on the list**: ↑/↓ move over the sections, **SPACE** toggles the row between
`[x]` and `[ ]`, Enter installs, `q` quits. `a`/`n` check all/none, `d` resets to
defaults. It writes the checked set to `--only`, so it needs a real TTY — the
`bash -c "$(curl …)"` form above keeps one, so the picker works remotely too. Only the
`curl | bash` **pipe** form breaks it, because there stdin *is* the download stream (and
without a stdin TTY the "no flags" path degrades to the defaults instead). Running with
**no flags at all** is the same picker — you only need `--menu` to force it when there
are other flags around.

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

## Runtime toggle: battery charge cap

Installing `battery` caps charging at 80% and keeps it there across reboots, suspend/resume and
AC re-plugs:

```bash
sudo battery-limit 80      # stop charging at 80% (persisted)
sudo battery-limit full    # charge to 100% before travelling
battery-limit status       # current cap, interface in use, boot state
```

**Why a cap and not "fewer charges".** A charge cycle is not one plug-in — it is 100% of capacity
moved in total, however it accumulates. Two days of 80% → 30% is *one* cycle. So counting how often
you plug in optimises nothing. What actually kills the cell is time spent at a high state of charge,
and heat — which is why this matters more on a gaming laptop, where the pack sits next to a heatsink
dumping 100 W+. Shallow cycles help too: laboratory data puts 100% depth-of-discharge at roughly
300–500 cycles versus ~1200–1500 at 50%.

**How the detection works.** Lenovo (`ideapad_laptop`, `thinkpad_acpi`), ASUS (`asus-wmi`), Huawei,
System76 and Framework all register the same kernel attributes, so there is no per-vendor code —
only three interfaces, probed at runtime:

| Interface      | What the firmware exposes | Typical driver |
|----------------|---------------------------|----------------|
| `range`        | Start *and* stop thresholds, any value | `thinkpad_acpi` |
| `end`          | Stop threshold only | `asus-wmi`, many Legions |
| `conservation` | On/off; firmware picks ~55–60%, your number is ignored | `ideapad_acpi` |

Every write is read back and verified — some firmware accepts only fixed steps (often 60/80/100)
and rejects anything else with `EINVAL`, which otherwise looks exactly like success while the
battery keeps charging to 100%.

**Deliberately not TLP.** TLP is the usual forum answer for charge thresholds and it is the wrong
one on Fedora: it conflicts with `power-profiles-daemon`, which backs the GNOME/KDE power panels and
the `platform_profile` modes the `legion` section points at. A oneshot systemd unit sets the same
threshold without trading those away.

**Recalibrate now and then.** A permanently capped battery decalibrates its gauge — the percentage
readout drifts because it never observes a full charge. Every few months run `sudo battery-limit
full`, charge to 100%, then set the cap back.

> If GNOME's **Settings → Power → Battery charge limit** is also on, set the limit in one place
> only — both write the same sysfs attribute. Same for `asusctl -c` if `asusctl` is installed.

---

## After it finishes

If you have an NVIDIA GPU, the updater checks the driver for the newest
installed kernel before it proceeds to Flatpak or firmware. You can also check
it manually before rebooting:

```bash
kernel=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | sort -V | tail -n1)
modinfo -k "$kernel" -F version nvidia    # must print a version number
```

- Check the **target kernel**, not just `modinfo -F version nvidia`: without
  `-k`, `modinfo` reports the module for the currently running kernel, which
  may be older than the one Fedora just installed.
- The version must belong to the branch your card needs. Driver **595** dropped
  Maxwell, Pascal and Volta (GTX 900 / 10-series, Quadro P), so those cards get
  the legacy `580xx` packages instead. The script picks the branch by GPU, but
  the check is worth doing: a module from the wrong branch builds and loads
  metadata fine, then leaves you on a black screen.
- With **Secure Boot** enabled, the updater also checks that the target module
  is signed and that its akmods key is enrolled. If that exact key is queued for
  enrollment, the next reboot opens **MOK Manager**: choose *Enroll MOK →
  Continue → Yes*, enter the password you set, then reboot. If the module is
  unsigned or the key is neither enrolled nor pending, **do not reboot**; fix
  the build/signing issue first.
- Then reboot: `systemctl reboot`

Update everything later with the installed helper:

```bash
update-all               # RPM + NVIDIA readiness + Flatpak + firmware
```

The phases are deliberate: an RPM transaction failure stops the run; an NVIDIA
readiness failure tells you not to reboot and stops before Flatpak/firmware;
Flatpak and firmware failures are reported and produce a non-zero exit status.
The helper does not roll back RPM changes automatically. The currently running
kernel remains active until reboot; if a reboot has already happened, choose the
previous kernel from GRUB. Re-running the post-install script refreshes the
managed `update-all` helper on existing installations.

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
