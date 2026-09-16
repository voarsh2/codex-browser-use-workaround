[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Apply", "Undo", "Status")]
    [string]$Action = "Apply",
    [switch]$Force,
    [string]$CodexHome
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
}
$CodexHome = [IO.Path]::GetFullPath($CodexHome)

$Original = "this.requestHeaderEnabled||this.clientInfo.agentRequestHeaderEnabled===!0||await this.readRequestHeaderEnabled()"
$Patched = "this.requestHeaderEnabled||this.clientInfo.agentRequestHeaderEnabled===!0"
$StateRoot = Join-Path $CodexHome "plugin-rollbacks\codex-browser-use-workaround"
$BackupRoot = Join-Path $StateRoot "backups"
$StatePath = Join-Path $StateRoot "state.json"

function Get-Hash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringHash([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Write-AtomicText([string]$Path, [string]$Text) {
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [pscustomobject]@{ version = 1; files = @() }
    }
    $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
    if ($state.version -ne 1 -or $null -eq $state.files) {
        throw "Unsupported state file: $StatePath"
    }
    $state
}

function Save-State($State) {
    Write-AtomicText $StatePath (($State | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
}

function Get-ServiceRoots {
    $roots = @(
        (Join-Path $CodexHome "plugins\cache\openai-bundled\browser"),
        (Join-Path $CodexHome "plugins\cache\openai-bundled\chrome")
    )
    $configPath = Join-Path $CodexHome "config.toml"
    if (Test-Path -LiteralPath $configPath) {
        $moduleDirs = Select-String -Path $configPath -Pattern "NODE_REPL_NODE_MODULE_DIRS\s*=\s*'([^']+)'" |
            ForEach-Object { $_.Matches.Groups[1].Value -split ";" }
        foreach ($moduleDir in $moduleDirs) {
            $roots += Join-Path $moduleDir "@oai\browser-desktop"
            $roots += Join-Path $moduleDir "@oai\cua"
        }
    }
    $hosts = Join-Path $CodexHome "hosts"
    if (Test-Path -LiteralPath $hosts) {
        $roots += Get-ChildItem -LiteralPath $hosts -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                Join-Path $_.FullName "plugins\cache\openai-bundled\browser"
                Join-Path $_.FullName "plugins\cache\openai-bundled\chrome"
            }
    }
    $roots | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique
}

function Get-ServiceFiles {
    $files = foreach ($root in Get-ServiceRoots) {
        Get-ChildItem -LiteralPath $root -Filter "browser-service.mjs" -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    }
    $files | Sort-Object -Unique
}

function Set-StateEntry($State, $Entry) {
    $State.files = @($State.files | Where-Object { $_.path -ne $Entry.path }) + $Entry
}

function Remove-StateEntry($State, [string]$Path) {
    $State.files = @($State.files | Where-Object { $_.path -ne $Path })
}

function Apply-File([string]$Path, $State) {
    $text = [IO.File]::ReadAllText($Path)
    $originalCount = ([regex]::Matches($text, [regex]::Escape($Original))).Count
    $patchedCount = ([regex]::Matches($text, [regex]::Escape($Patched))).Count
    $currentHash = Get-Hash $Path
    $entry = @($State.files | Where-Object { $_.path -eq $Path }) | Select-Object -Last 1

    if ($originalCount -eq 0 -and $patchedCount -eq 1) {
        if ($null -eq $entry) {
            Write-Warning "Already patched but not managed by this script: $Path"
        } else {
            Write-Output "Already patched: $Path"
        }
        return $false
    }
    if ($originalCount -ne 1) {
        if ($originalCount -eq 0 -and $patchedCount -eq 0) {
            Write-Output "Skipped (upstream changed or already fixed): $Path"
            return $false
        }
        throw "Refusing to patch unexpected content in $Path (original=$originalCount, patched=$patchedCount)."
    }

    $backup = if ($entry -and $entry.originalHash -eq $currentHash) {
        $entry.backup
    } else {
        Join-Path $BackupRoot ("{0}-{1}.mjs.bak" -f (Get-StringHash $Path), $currentHash)
    }
    if (Test-Path -LiteralPath $backup) {
        if ((Get-Hash $backup) -ne $currentHash) {
            throw "Backup does not match the current original; refusing to overwrite it: $Path"
        }
    } elseif ($PSCmdlet.ShouldProcess($backup, "Create rollback backup")) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
        Copy-Item -LiteralPath $Path -Destination $backup
    }

    if (-not $PSCmdlet.ShouldProcess($Path, "Apply browser auth regression workaround")) {
        return $false
    }
    $updated = $text.Replace($Original, $Patched)
    Write-AtomicText $Path $updated
    $patchedHash = Get-Hash $Path
    Set-StateEntry $State ([pscustomobject]@{
        path = $Path
        backup = $backup
        originalHash = $currentHash
        patchedHash = $patchedHash
        appliedAt = [DateTime]::UtcNow.ToString("o")
    })
    Write-Output "Patched: $Path"
    $true
}

function Undo-File($Entry, $State) {
    if (-not (Test-Path -LiteralPath $Entry.path)) {
        Write-Warning "Missing; leaving rollback state intact: $($Entry.path)"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Entry.backup)) {
        throw "Rollback backup is missing: $($Entry.backup)"
    }
    if ((Get-Hash $Entry.backup) -ne $Entry.originalHash) {
        throw "Rollback backup hash mismatch: $($Entry.backup)"
    }

    $currentHash = Get-Hash $Entry.path
    if ($currentHash -eq $Entry.originalHash) {
        Remove-StateEntry $State $Entry.path
        Write-Output "Already undone: $($Entry.path)"
        return $false
    }
    if ($currentHash -ne $Entry.patchedHash -and -not $Force) {
        throw "Refusing to overwrite a file changed after apply: $($Entry.path) (use -Force to restore anyway)"
    }
    if ($PSCmdlet.ShouldProcess($Entry.path, "Restore original browser service")) {
        Write-AtomicText $Entry.path ([IO.File]::ReadAllText($Entry.backup))
        Remove-StateEntry $State $Entry.path
        Write-Output "Restored: $($Entry.path)"
        return $true
    }
    $false
}

$state = Read-State
$changed = $false

switch ($Action) {
    "Apply" {
        $files = @(Get-ServiceFiles)
        if ($files.Count -eq 0) {
            throw "No cached browser-service.mjs files found under $CodexHome"
        }
        foreach ($file in $files) {
            $result = @(Apply-File $file $state)
            $result | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
            if (($result | Where-Object { $_ -is [bool] -and $_ }) -contains $true) {
                $changed = $true
            }
        }
        if (-not $WhatIfPreference) { Save-State $state }
    }
    "Undo" {
        foreach ($entry in @($state.files)) {
            $result = @(Undo-File $entry $state)
            $result | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
            if (($result | Where-Object { $_ -is [bool] -and $_ }) -contains $true) {
                $changed = $true
            }
        }
        if (-not $WhatIfPreference) { Save-State $state }
    }
    "Status" {
        $files = @(Get-ServiceFiles)
        foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file)
            $mode = if ($text.Contains($Original)) { "original" } elseif ($text.Contains($Patched)) { "patched" } else { "unknown/upstream" }
            [pscustomobject]@{ Path = $file; State = $mode; Hash = Get-Hash $file }
        }
        if ($state.files.Count -gt 0) {
            Write-Output "Managed rollback entries: $($state.files.Count)"
        }
    }
}

if ($changed -and $Action -ne "Status") {
    $running = Get-Process -Name "Codex","ChatGPT" -ErrorAction SilentlyContinue
    if ($running) {
        Write-Warning "Restart Codex before retrying browser use; the running helper keeps the old service loaded."
    }
}
