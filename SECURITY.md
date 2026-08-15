# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use [private vulnerability reporting](https://github.com/dotgibson/dotfiles-Windows/security/advisories/new),
which is enabled on this repository. That opens a private advisory only the
maintainer can see.

This is a personal dotfiles repo, not a product — there is no SLA. Expect a first
response within about a week.

## What is in scope

This repo installs and configures a Windows host, so the interesting surface is
the **install path**, not the shell aliases:

- **`bootstrap.ps1`** — fetched over HTTPS and piped to `iex` by the documented
  one-liner. Its LF-normalized SHA-256 is pinned in the README and gated by
  `tests/Bootstrap.Tests.ps1`, so a tampered `main` can be detected before it runs.
- **`install.ps1` / `packages/Install-Packages.ps1`** — create symlinks into
  `$HOME`, set the CurrentUser execution policy, and install packages. The scoop
  installer is fetched to a string and can be hash-gated via
  `DOTFILES_SCOOP_SHA256` before execution.
- **`nvim-sync.ps1` / `starship-sync.ps1`** — mirror content from
  [`dotfiles-core`](https://github.com/dotgibson/dotfiles-core). Both provenance
  markers (`.core-ref`) are treated as untrusted, PR-editable input: the recorded
  commit must be a valid git SHA, and the clone remote is restricted to an
  allowlist, so a hostile PR cannot redirect CI's outbound fetch.
- **GitHub Actions workflows** — every third-party action is pinned to a full
  40-character commit SHA.

## What is out of scope

- Anything requiring an attacker to already have code execution as your user.
- The tools this repo installs. Report those to their own projects.
- Configuration you supply yourself (`~/.gitconfig.local`, `powershell/local.ps1`,
  `~/.ssh/config` includes) — those files are deliberately gitignored and never
  committed here.

## Secrets

No credentials are committed. Identity and secrets live in gitignored local
layers (`powershell/local.ps1`, `~/.gitconfig.local`, per-host SSH includes).
Secret scanning and push protection are enabled on the repository.

If you believe a secret has been committed here, report it privately using the
link above rather than opening an issue that would draw attention to it.
