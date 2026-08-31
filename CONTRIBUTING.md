# Contributing

This is a personal dotfiles repo, but it is public and the gates are real — so
the rules below are the same ones CI enforces.

## Before you push

```bash
pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

That is the exact command CI runs: the full suite plus the coverage bar, the
test-file match, and the test-case floor. A bare `Invoke-Pester` skips the gate.

For a faster inner loop:

```bash
pwsh -NoProfile -File tests/Invoke-Validation.ps1
```

Dependency-free (no PowerShell Gallery): parser, JSON/manifest, and editorconfig
checks. This is what `.githooks/pre-commit` runs.

First time on a machine:

```bash
pwsh -NoProfile -File tests/Install-DevDeps.ps1
```

Installs the **pinned** Pester and PSScriptAnalyzer. The pin matters — the runner
loads Pester by exact version, because a box with several installed would
otherwise run different code than CI.

## The rules that bite

- **Don't hand-edit `nvim/`, `starship/starship.toml` or `theme/palette.toml`.** They
  are mirrored from [`dotfiles-core`](https://github.com/dotgibson/dotfiles-core) and
  CI diffs them against the commit recorded in `.core-ref`. Fix it in Core, then re-run
  `nvim-sync.ps1` / `starship-sync.ps1` / `theme-sync.ps1`. A local edit will fail the
  parity gate, and `robocopy /MIR` would purge nvim's on the next sync anyway.
- **Don't hand-edit a colour.** Every hex inside a `# core:theme:gen <id>` marker in
  `powershell/core/` and `psmux/` is rendered from `theme/palette.toml` by
  `gen-theme.ps1`, and `gen-theme.ps1 -Check` fails the PR that edits one by hand.
  Change the colour in Core, `theme-sync.ps1`, then `gen-theme.ps1`. This rule exists
  because the previous convention — a comment saying the block was "kept byte-for-byte
  in step with Core" — was false for three fzf values and nothing noticed (#228). The
  gate also rejects any hex in those files that the palette does not define at all, so
  a new hand-typed colour cannot sneak in beside a generated one.
- **`bootstrap.ps1` must stay ASCII.** It is stored UTF-8 with no BOM, so Windows
  PowerShell 5.1 reads it as the ANSI codepage — a single em-dash makes the
  *parser* fail before the version guard can print anything useful. 5.1 users are
  exactly the audience of that guard. A test enforces this.
- **Change `bootstrap.ps1`, update the README hash in the same commit.** The
  integrity-gated one-liner only works if the pin tracks the script; a test
  enforces it.
- **A fragment's `# provides:` / `# requires:` header is a contract.** It is
  AST-checked against the actual code by `tests/LoadContract.Tests.ps1`.
- **`windows-terminal/settings.json` is app-owned.** Windows Terminal rewrites it
  on exit. Run `pwsh -NoProfile -File tests/Format-AppJson.ps1` (the pre-commit
  hook does this) rather than hand-fixing whitespace, and don't re-indent it — the
  `.editorconfig` carve-out matches what the app writes on purpose.

## Style

- LF endings everywhere except `*.cmd`/`*.bat`; final newline; no trailing
  whitespace. `.editorconfig` is the source of truth and the validator enforces it.
- Comments explain **why**, not what. The existing files set the bar — match it.
- Conventional Commits (`fix(install):`, `test(packages):`, `docs:`).

## Machine-specific things

Never commit them. Every layer has an escape hatch: `powershell/local.ps1`,
`~/.gitconfig.local`, per-host SSH includes, and the `DOTFILES_*` environment
knobs documented in `powershell/local.ps1.example`.
