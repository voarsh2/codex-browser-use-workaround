# Codex browser-use workaround

Temporary workaround for the Codex `Codex auth token is unavailable` regression
in the Chrome/Chromium extension backend.

Run PowerShell from this repo:

```powershell
.\Apply-CodexBrowserUseWorkaround.ps1 -Action Apply
.\Apply-CodexBrowserUseWorkaround.ps1 -Action Status
.\Apply-CodexBrowserUseWorkaround.ps1 -Action Undo
```

`Apply` changes cached and CUA runtime `browser-service.mjs` files when the
exact known upstream line is present. It creates hash-checked rollback backups under
`$CODEX_HOME\plugin-rollbacks\codex-browser-use-workaround`, refuses to overwrite
files changed after applying, and never touches credentials or the main provider
configuration. Restart Codex after applying.

Use `-WhatIf` to preview changes and `-Force` only when undoing after Codex has
rewritten a patched file.
