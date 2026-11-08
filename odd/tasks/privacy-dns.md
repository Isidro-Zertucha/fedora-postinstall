# Optional privacy section: encrypted DNS

## Objective
Add an optional `privacy` section, disabled by default, that configures encrypted DNS
(DNS-over-TLS) through systemd-resolved with Quad9 as the default resolver.

## Problem and why
The post-install script configures applications and desktop defaults but never touches DNS,
so queries still go to the ISP resolver in plaintext. The user asked for an optional privacy
section that sets a good DNS. GNOME telemetry and firewall checks were explicitly excluded:
telemetry is chosen during installation, and the user does not run a firewall.

## Scope and constraints
- Modify `fedora-postinstall.sh`, `README.md`, and add `tests/privacy-dns.test.sh`.
- `privacy` is optional and off by default; it runs only with `--with privacy` or
  `--only privacy`.
- Default provider: Quad9 (malware blocking, DNSSEC validation, no user IP logging,
  Swiss foundation). `--dns cloudflare` selects the unfiltered alternative.
- Strict DoT: `DNSOverTLS=yes` and `FallbackDNS=` empty so resolution never silently
  falls back to plaintext.
- No telemetry changes, no firewall checks, no SELinux changes.
- Technical artifacts in English.
- Delivery: direct on `main`, one conventional commit, no Co-Authored-By (standing repo
  preference).

## Tasks
- [x] ODD-1 Add `privacy` to OPTIONAL_SECTIONS, its picker description, the `--dns` flag,
      and usage text.
- [x] ODD-2 Implement `section_privacy`: systemd-resolved drop-in, enable + stub
      resolv.conf, reload, verify DoT.
- [x] ODD-3 Document the section, the provider choice, the port-853 caveat, and the revert
      path in README.
- [x] ODD-4 Add `tests/privacy-dns.test.sh` and run the full check set.

## Acceptance criteria
`--list` shows `privacy` under optional; `--help` documents `--dns`; the section writes
`/etc/systemd/resolved.conf.d/99-privacy.conf` with Quad9 DoT servers; a regular
`/etc/resolv.conf` is backed up before replacement; verification reports DoT state; README
documents usage and revert; all shell tests and `bash -n` pass.

## Checks
`bash -n fedora-postinstall.sh`, `bash tests/privacy-dns.test.sh`,
`bash tests/app-catalog.test.sh`, `bash tests/update-all.test.sh`,
`bash fedora-postinstall.sh --list`, `bash fedora-postinstall.sh --help`,
`git diff --check`.

## Progress
ODD-1 through ODD-4 complete. `bash -n`, the three shell tests, `--list`, `--help`,
`--dns` validation (bogus rejected, cloudflare accepted), and `git diff --check` pass.
Route: inline; trigger evidence: fully specified mechanical edits on known files, and the
user's standing preference is a direct single-branch workflow.

## Next step
Commit on `main` with a conventional message after the native review-mode check.
