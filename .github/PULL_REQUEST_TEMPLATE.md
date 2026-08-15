## What and why

<!-- What changes, and what problem it solves. If it fixes something subtle, say
     what the failure looked like — that's the part reviewers can't reconstruct. -->

## Verification

<!-- What you actually ran, and what it said. "Tests pass" is weaker than
     "tests/Invoke-Tests.ps1: 705 passed, 0 failed, gate passed". -->

- [ ] `pwsh -NoProfile -File tests/Invoke-Tests.ps1` (full gated suite — what CI runs)
- [ ] Anything that needs a real host / VM is called out below as unverified

## Checklist

- [ ] No hand-edits to `nvim/` or `starship/starship.toml` (mirrored from Core — sync instead)
- [ ] If `bootstrap.ps1` changed: still ASCII-only, and the README SHA-256 pin is updated
- [ ] No machine-specific paths, identities, or secrets
