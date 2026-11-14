# Project Rules

## Branching and delivery

- Work **always on `main`**. Do not create feature, fix, or topic branches, and do not
  leave extra branches behind (local or remote).
- Commit directly to `main` and **push after every completed change**. Finishing the work
  includes the push; do not stop at a dirty or committed-but-unpushed tree waiting for
  approval.
- Keep history readable with conventional commits (`feat(scope): …`, `fix(scope): …`,
  `docs: …`, `test(scope): …`), one logical change per commit.
- Never rewrite published history: no `--force` and no `--force-with-lease` on `main`.
- No AI attribution and no `Co-Authored-By` trailers.

## Verification before pushing

```bash
bash -n fedora-postinstall.sh
bash tests/*.test.sh
```

A change is not finished until both pass. This script runs as root on a real system, so a
red test or a syntax error is a blocker, not a follow-up.
