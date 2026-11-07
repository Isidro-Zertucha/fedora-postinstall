# Add five apps to Fedora post-install

## Objective
Add Heronite, Morrow, Safe Disk Cleaner, Aura, and Ente Photos to their appropriate installer sections and document them.

## Problem and why
The post-install script lacks these requested applications. User explicitly approved the proposed section mapping and install approach.

## Scope and constraints
- Modify `fedora-postinstall.sh`, `README.md`, focused shell tests, and this recovery document.
- No subagents. No remote operation.
- Technical artifacts in English.
- Heronite -> gaming; Aura -> qol; Ente Photos -> new photos section. User removed Morrow and Safe Disk Cleaner from scope.
- Prefer Flathub where a suitable published package exists; use explicit upstream installers otherwise; no piped remote shell.

## Tasks
- [x] ODD-1 Add focused regression test coverage for app entries and section categorization. Route: inline; trigger evidence: bounded one-file test. RED observed: the test failed because `io.ente.photos` was absent.
- [x] ODD-2 Implement installation entries/section integration and README catalog updates. Route: inline; trigger evidence: limited to known files after focused context. Ente's Flathub metadata confirms `verified: true`; Heronite's release publishes Fedora RPMs and SHA256SUMS; Aura's upstream installer downloads releases with checksum verification.
- [x] ODD-3 Run focused checks and inspect resulting diff. Route: inline; trigger evidence: bounded shell validation. `bash -n fedora-postinstall.sh`, `bash tests/app-catalog.test.sh`, `bash tests/update-all.test.sh`, `fedora-postinstall.sh --list` (shows `photos`), and `git diff --check` passed.

## Acceptance criteria
All five applications appear under sensible sections, installer mechanisms are explicit and safe, README descriptions align, tests pass, and no unrelated changes occur.

## Checks
Relevant shell test(s), bash syntax check, diff review.

## Progress
Implementation and checks completed. No application was installed during this repository change. Created feature branch `feat/postinstall-three-apps`; commit is pending because the native review-mode status command was blocked by Windows Application Control.

## Next step
Resolve the local Application Control block for the read-only native status command, then follow the repository's ordinary review and commit policy. Do not claim a commit exists.
