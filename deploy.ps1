#Requires -Version 7.0
<#
.SYNOPSIS
    Lints, diffs and deploys this repo's CS2 config to the local game install.

.DESCRIPTION
    autoexec.cfg is install-scoped (one copy, shared by every Steam account) and
    is deployed by default. cs2_video.txt is account-scoped (Steam Cloud, keyed
    by SteamID3 under userdata\<id>\730\local\cfg) and is only touched with
    -IncludeVideo. Steam launch options are only ever reported, never written.

.PARAMETER Check
    Lint + diff + launch-option report. Never writes anything. Exit 2 on drift.

.PARAMETER IncludeVideo
    Also deploy cs2_video.txt to the resolved Steam account.

.PARAMETER ListAccounts
    Print every local Steam account with a CS2 cfg folder, then exit.

.PARAMETER AccountId
    SteamID3, SteamID64, [U:1:N] form, PersonaName or AccountName. Only
    consulted for -IncludeVideo (and to pick which account's launch options
    to report). If omitted and more than one account has a CS2 cfg folder,
    you are prompted interactively; non-interactive sessions fail closed.

.PARAMETER Force
    Downgrade the running-process guard from a hard refusal to a warning.

.EXAMPLE
    .\deploy.ps1 -Check
.EXAMPLE
    .\deploy.ps1
.EXAMPLE
    .\deploy.ps1 -IncludeVideo -AccountId timon
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $Check,
    [switch] $IncludeVideo,
    [switch] $ListAccounts,
    [string] $AccountId,
    [switch] $Force,
    [switch] $NoBackup,
    [int]    $BackupKeep = 10
)

$ErrorActionPreference = 'Stop'
$RepoRoot  = $PSScriptRoot
$ExitCode  = 0
$SteamId64Offset = [int64]76561197960265728

# ============================== helpers ====================================

function Resolve-SteamRoot {
    $candidates = @()
    try {
        $p = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop
        if ($p.SteamPath) { $candidates += ($p.SteamPath -replace '/', '\') }
    } catch {}
    try {
        $p = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop
        if ($p.InstallPath) { $candidates += $p.InstallPath }
    } catch {}
    $candidates += "${env:ProgramFiles(x86)}\Steam"

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'steamapps\libraryfolders.vdf'))) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    throw "Could not locate a Steam installation (checked registry and the default Program Files path)."
}

function Resolve-AppLibrary {
    param([Parameter(Mandatory)][string] $SteamRoot, [int] $AppId = 730)

    $vdf = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path -LiteralPath $vdf)) { throw "libraryfolders.vdf not found under $SteamRoot" }

    $libs = @(); $cur = $null; $inApps = $false
    foreach ($line in [System.IO.File]::ReadLines($vdf)) {
        $t = $line.Trim()
        if     ($t -match '^"path"\s+"(.+)"$') {
            $cur = [pscustomobject]@{ Path = ($Matches[1] -replace '\\\\', '\'); Apps = [System.Collections.Generic.List[int]]::new() }
            $libs += $cur
        }
        elseif ($t -match '^"apps"$')            { $inApps = $true }
        elseif ($t -eq '}' -and $inApps)         { $inApps = $false }
        elseif ($inApps -and $t -match '^"(\d+)"') { if ($cur) { $cur.Apps.Add([int]$Matches[1]) } }
    }

    $lib = $libs | Where-Object { $_.Apps -contains $AppId } | Select-Object -First 1
    if (-not $lib) { throw "App $AppId was not found in any of the $($libs.Count) Steam libraries under $SteamRoot." }

    $cfg = Join-Path $lib.Path 'steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg'
    if (-not (Test-Path -LiteralPath $cfg)) {
        throw "Library '$($lib.Path)' claims app $AppId but its cfg dir is missing: $cfg"
    }
    (Resolve-Path -LiteralPath $cfg).Path
}

function Get-SteamAccounts {
    param([Parameter(Mandatory)][string] $SteamRoot)

    $loginUsersPath = Join-Path $SteamRoot 'config\loginusers.vdf'
    $userdataRoot   = Join-Path $SteamRoot 'userdata'

    $users = @{}
    if (Test-Path -LiteralPath $loginUsersPath) {
        $steamId64 = $null; $account = $null; $persona = $null
        foreach ($line in [System.IO.File]::ReadLines($loginUsersPath)) {
            $t = $line.Trim()
            if     ($t -match '^"(\d{17})"$')                 { $steamId64 = $Matches[1]; $account = $null; $persona = $null }
            elseif ($t -match '^"AccountName"\s+"(.*)"$')     { $account = $Matches[1] }
            elseif ($t -match '^"PersonaName"\s+"(.*)"$')     { $persona = $Matches[1] }
            elseif ($t -eq '}' -and $steamId64) {
                $users[$steamId64] = [pscustomobject]@{ AccountName = $account; PersonaName = $persona }
                $steamId64 = $null
            }
        }
    }

    $accounts = @()
    if (Test-Path -LiteralPath $userdataRoot) {
        Get-ChildItem -LiteralPath $userdataRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -notmatch '^\d+$') { return }
            $accountId3 = [int64]$_.Name
            $steamId64  = [string]($accountId3 + $SteamId64Offset)
            $info       = $users[$steamId64]
            $cfgDir     = Join-Path $_.FullName '730\local\cfg'
            $hasCs2     = Test-Path -LiteralPath $cfgDir
            $lastPlayed = $null
            if ($hasCs2) {
                $newest = Get-ChildItem -LiteralPath $cfgDir -File -Recurse -ErrorAction SilentlyContinue |
                          Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                if ($newest) { $lastPlayed = $newest.LastWriteTimeUtc }
            }
            $accounts += [pscustomobject]@{
                AccountId3  = $accountId3
                SteamId64   = $steamId64
                AccountName = $info.AccountName
                PersonaName = $info.PersonaName
                HasCs2Cfg   = $hasCs2
                CfgPath     = $cfgDir
                LastPlayed  = $lastPlayed
            }
        }
    }
    $accounts | Sort-Object LastPlayed -Descending
}

function Find-Account {
    # Resolves one -AccountId value (SteamID3 / SteamID64 / [U:1:N] / persona /
    # account name) against the local account list. Throws on 0 or >1 matches
    # so a typo fails loudly instead of silently falling through to a guess.
    param([Parameter(Mandatory)][object[]] $Accounts, [Parameter(Mandatory)][string] $Identifier)

    $id = $Identifier
    if ($id -match '^\[U:1:(\d+)\]$') { $id = $Matches[1] }

    if ($id -match '^\d{17}$') {
        $id64 = [int64]$id
        $id3  = $id64 - $SteamId64Offset
        Write-Host "[account] interpreted '$id' as SteamID64 -> SteamID3 $id3" -ForegroundColor DarkGray
        $match = $Accounts | Where-Object { $_.AccountId3 -eq $id3 }
    }
    elseif ($id -match '^\d+$') {
        $match = $Accounts | Where-Object { $_.AccountId3 -eq [int64]$id }
    }
    else {
        $match = $Accounts | Where-Object { $_.PersonaName -ieq $id -or $_.AccountName -ieq $id }
    }

    $match = @($match)
    if ($match.Count -eq 0) { throw "No local Steam account matches '$Identifier'. Run -ListAccounts to see candidates." }
    if ($match.Count -gt 1) { throw "'$Identifier' matches multiple accounts: $(($match | ForEach-Object { $_.AccountId3 }) -join ', '). Use the numeric SteamID3." }
    $match[0]
}

function Resolve-Account {
    param(
        [Parameter(Mandatory)][object[]] $Accounts,
        [string] $AccountId,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    $stateFile = Join-Path $RepoRoot '.deploy.local.json'

    if ($AccountId) { return Find-Account -Accounts $Accounts -Identifier $AccountId }

    if (Test-Path -LiteralPath $stateFile) {
        try {
            $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            $match = $Accounts | Where-Object { $_.AccountId3 -eq [int64]$saved.AccountId3 }
            if ($match) {
                Write-Host "[account] using remembered account $($match.AccountId3) ($($match.PersonaName)) from .deploy.local.json" -ForegroundColor DarkGray
                return $match
            }
        } catch { Write-Warning "Could not parse .deploy.local.json, ignoring it: $_" }
    }

    $withCs2 = @($Accounts | Where-Object HasCs2Cfg)
    if ($withCs2.Count -eq 1) { return $withCs2[0] }

    if ($withCs2.Count -eq 0 -or [Console]::IsInputRedirected) {
        throw "Cannot resolve a Steam account for -IncludeVideo without -AccountId in a non-interactive session. Run -ListAccounts, then pass -AccountId."
    }

    Write-Host ""
    Write-Host "Multiple CS2 accounts found. Which one gets cs2_video.txt?" -ForegroundColor Yellow
    Write-Host ""
    $rows = $withCs2 | Sort-Object LastPlayed -Descending
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $persona = if ($r.PersonaName) { $r.PersonaName } else { '(unknown)' }
        $lp = if ($r.LastPlayed) { $r.LastPlayed.ToString('yyyy-MM-dd') } else { 'never' }
        "{0,3}  {1,-11} {2,-18} {3,-15} {4}" -f ($i + 1), $r.AccountId3, $persona, $r.AccountName, $lp
    }
    Write-Host ""
    $sel = Read-Host "Select [1-$($rows.Count)]"
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $rows.Count) { throw "Invalid selection." }
    $chosen = $rows[[int]$sel - 1]

    if (-not $WhatIfPreference) {
        $remember = Read-Host "Remember this choice in .deploy.local.json? [y/N]"
        if ($remember -match '^[Yy]') {
            [pscustomobject]@{ AccountId3 = $chosen.AccountId3 } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
        }
    }
    $chosen
}

function Get-VdfAppValue {
    # Streaming, brace-depth-tracked VDF read scoped to one ancestor path.
    # Never opens for write - Steam holds localconfig.vdf open and rewrites
    # it on exit, so this only ever needs read access with sharing allowed.
    param(
        [Parameter(Mandatory)][string]   $Path,
        [Parameter(Mandatory)][string[]] $KeyPath,
        [Parameter(Mandatory)][string]   $ValueName
    )

    $stack = [System.Collections.Generic.List[string]]::new()
    $pending = $null
    $found = $null
    $hits = 0

    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = [System.IO.StreamReader]::new($fs, [System.Text.UTF8Encoding]::new($false), $true)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                $t = $line.Trim()
                if ($t -eq '' -or $t.StartsWith('//')) { continue }

                if ($t -eq '{') {
                    $stack.Add($(if ($null -ne $pending) { $pending } else { '' }))
                    $pending = $null
                    continue
                }
                if ($t -eq '}') {
                    if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }
                    $pending = $null
                    continue
                }

                if ($t -match '^"((?:[^"\\]|\\.)*)"\s+"((?:[^"\\]|\\.)*)"$') {
                    $k = $Matches[1]; $v = $Matches[2]
                    if ($k -ieq $ValueName -and $stack.Count -eq $KeyPath.Count) {
                        $isMatch = $true
                        for ($i = 0; $i -lt $KeyPath.Count; $i++) {
                            if ($stack[$i] -ine $KeyPath[$i]) { $isMatch = $false; break }
                        }
                        if ($isMatch) { $found = ($v -replace '\\(.)', '$1'); $hits++ }
                    }
                    continue
                }

                if ($t -match '^"((?:[^"\\]|\\.)*)"$') { $pending = $Matches[1]; continue }
            }
        } finally { $reader.Dispose() }
    } finally { $fs.Dispose() }

    [pscustomobject]@{ Value = $found; MatchCount = $hits; Found = ($hits -gt 0) }
}

function Test-LaunchOptions {
    param([Parameter(Mandatory)][string] $LocalConfigPath, [Parameter(Mandatory)][string] $ExpectedFile)

    $result = Get-VdfAppValue -Path $LocalConfigPath `
        -KeyPath @('UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps', '730') `
        -ValueName 'LaunchOptions'

    $expectedLine = Get-Content -LiteralPath $ExpectedFile |
        Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') } |
        Select-Object -First 1
    $expectedTokens = if ($expectedLine) { $expectedLine.Trim() -split '\s+' } else { @() }
    $actualTokens   = if ($result.Found) { $result.Value.Trim() -split '\s+' } else { @() }

    $staleTokens = [ordered]@{
        '-exec'     = "'-exec' is not a CS2 flag; use '+exec autoexec.cfg'"
        '-full'     = "renamed; CS2 uses '-fullscreen'"
        '-novid'    = 'no-op in CS2 (no intro video to skip)'
        '-tickrate' = 'no-op in CS2 (sub-tick, server-side only)'
    }
    $warnings = @($actualTokens | Where-Object { $staleTokens.Contains($_) } | ForEach-Object { "$_ - $($staleTokens[$_])" })

    [pscustomobject]@{
        Found         = $result.Found
        MatchCount    = $result.MatchCount
        Actual        = $result.Value
        Expected      = $expectedLine
        Matches       = ($result.Found -and (($actualTokens -join ' ') -eq ($expectedTokens -join ' ')))
        StaleWarnings = $warnings
    }
}

function Invoke-CfgLint {
    param([Parameter(Mandatory)][string] $Path, [string[]] $RemovedCvars = @())

    $findings = [System.Collections.Generic.List[object]]::new()
    function Add-Finding([string]$Rule, [string]$Sev, [int]$Line, [string]$Message) {
        $findings.Add([pscustomobject]@{ Rule = $Rule; Severity = $Sev; Line = $Line; Message = $Message })
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Add-Finding 'encoding-bom' 'E' 1 'File starts with a UTF-8 BOM; it is consumed as part of the first token.'
    } elseif ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
        Add-Finding 'encoding-bom' 'E' 1 'File starts with a UTF-16 BOM; save as UTF-8 without BOM.'
    }
    $noTrailingNewline = $bytes.Length -gt 0 -and $bytes[-1] -ne 0x0A

    $lines = [System.Text.Encoding]::UTF8.GetString($bytes) -split "`r`n|`n|`r"

    $lastBindLineForKey   = @{}
    $lastUnbindLineForKey = @{}
    $definedAliases       = @{}
    $cvarValues           = @{}
    $hasWriteConfig       = $false
    $writeConfigLine      = 0
    $lastNonEmptyLine     = 0
    $hasEcho              = $false

    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        $lineNo = $idx + 1
        $line = $lines[$idx]
        if ($line.Trim() -ne '') { $lastNonEmptyLine = $lineNo }

        if ($line.ToCharArray() | Where-Object { [int][char]$_ -gt 127 }) {
            Add-Finding 'non-ascii' 'W' $lineNo "Line contains non-ASCII byte(s); CS2's tokenizer is byte-oriented."
        }

        # quote-balance + comment-aware code/comment split (a // inside a quoted string is not a comment)
        $inQuotes = $false; $quoteCount = 0; $commentStart = -1
        for ($c = 0; $c -lt $line.Length; $c++) {
            $ch = $line[$c]
            if ($ch -eq '\' -and $inQuotes) { $c++; continue }
            if ($ch -eq '"') { $inQuotes = -not $inQuotes; $quoteCount++; continue }
            if (-not $inQuotes -and $ch -eq '/' -and $c + 1 -lt $line.Length -and $line[$c + 1] -eq '/') { $commentStart = $c; break }
        }
        $codePart = if ($commentStart -ge 0) { $line.Substring(0, $commentStart) } else { $line }
        if ($quoteCount % 2 -ne 0) {
            Add-Finding 'unbalanced-quote' 'E' $lineNo 'Odd number of unescaped double quotes on this line.'
        }

        $trimmedCode = $codePart.Trim()
        if ($trimmedCode -eq '') { continue }

        if ($trimmedCode -match '^bind(?:toggle)?\s+(.*)$') {
            $rest = $Matches[1].Trim()
            $bindArgs = [regex]::Matches($rest, '"(?:[^"\\]|\\.)*"|\S+') | ForEach-Object { $_.Value }
            if ($bindArgs.Count -lt 2) {
                Add-Finding 'bind-arity' 'E' $lineNo "bind with fewer than 2 arguments: '$trimmedCode'"
            } else {
                $key = $bindArgs[0].Trim('"').ToLowerInvariant()
                if ($lastBindLineForKey.ContainsKey($key) -and $line -notmatch 'lint:allow duplicate-bind') {
                    Add-Finding 'duplicate-bind' 'E' $lineNo "Key '$key' already bound at line $($lastBindLineForKey[$key]) (last one wins). Add '// lint:allow duplicate-bind' to suppress."
                }
                if ($lastUnbindLineForKey.ContainsKey($key) -and $lastUnbindLineForKey[$key] -lt $lineNo) {
                    Add-Finding 'unbind-then-bind' 'W' $lineNo "Key '$key' was unbound at line $($lastUnbindLineForKey[$key]) then re-bound here - confirm this reset is deliberate."
                }
                $lastBindLineForKey[$key] = $lineNo
            }
        }
        elseif ($trimmedCode -match '^unbind\s+"?([^"\s]+)"?') {
            $key = $Matches[1].ToLowerInvariant()
            if ($lastBindLineForKey.ContainsKey($key) -and $lastBindLineForKey[$key] -lt $lineNo) {
                Add-Finding 'dead-bind' 'E' $lineNo "Key '$key' bound at line $($lastBindLineForKey[$key]) is unbound here afterward, making that bind dead."
            }
            $lastUnbindLineForKey[$key] = $lineNo
        }

        if ($trimmedCode -match '^alias\s+"?([A-Za-z0-9_+\-]+)"?\s') {
            $definedAliases[$Matches[1]] = $lineNo
        }

        if ($trimmedCode -match '^([A-Za-z_][A-Za-z0-9_]*)\s+"?([^"\r\n]+?)"?$' -and $trimmedCode -notmatch '^(bind|bindtoggle|unbind|alias|echo)\b') {
            $cvar = $Matches[1]; $val = $Matches[2].Trim()
            if ($cvarValues.ContainsKey($cvar) -and $cvarValues[$cvar].Value -ne $val) {
                Add-Finding 'cvar-set-twice' 'W' $lineNo "'$cvar' previously set to '$($cvarValues[$cvar].Value)' at line $($cvarValues[$cvar].Line), now '$val'."
            }
            $cvarValues[$cvar] = @{ Value = $val; Line = $lineNo }
            if ($RemovedCvars -contains $cvar.ToLowerInvariant()) {
                Add-Finding 'removed-cvar' 'W' $lineNo "'$cvar' was removed from CS2 (CS:GO-era); it prints 'Unknown command' and is otherwise skipped."
            }
        }

        if ($trimmedCode -match '^host_writeconfig\b') { $hasWriteConfig = $true; $writeConfigLine = $lineNo }
        if ($trimmedCode -match '^echo\b') { $hasEcho = $true }

        if ($line.Length -gt 512) {
            Add-Finding 'long-line' 'W' $lineNo "Line exceeds 512 characters ($($line.Length)); console command buffers can truncate long lines."
        }
    }

    # alias-used-before-defined: only for aliases this file itself defines - needs no engine knowledge
    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        $lineNo = $idx + 1
        $codePart = ($lines[$idx] -split '//', 2)[0]
        foreach ($aliasName in $definedAliases.Keys) {
            $definedAt = $definedAliases[$aliasName]
            if ($lineNo -ge $definedAt) { continue }
            if ($codePart -match "(^|[\s""])$([regex]::Escape($aliasName))([\s""]|`$)") {
                Add-Finding 'alias-used-before-defined' 'W' $lineNo "'$aliasName' is referenced here but not defined (via alias) until line $definedAt; cfg executes top-down."
            }
        }
    }

    if ($noTrailingNewline) {
        Add-Finding 'no-trailing-newline' 'E' $lines.Count 'File does not end with a newline; the last line may not execute reliably.'
    }
    if (-not $hasWriteConfig) {
        Add-Finding 'missing-writeconfig' 'W' $lines.Count 'No host_writeconfig found; binds set here will not persist into the local vcfg.'
    } elseif ($writeConfigLine -lt $lastNonEmptyLine) {
        Add-Finding 'writeconfig-not-last' 'W' $writeConfigLine "host_writeconfig is on line $writeConfigLine but the file continues to line $lastNonEmptyLine; anything after it is not persisted."
    }
    if (-not $hasEcho) {
        Add-Finding 'missing-echo-marker' 'W' $lines.Count 'No echo near EOF; there is no console proof this file actually executed.'
    }

    $findings
}

function Get-FileDiff {
    param([Parameter(Mandatory)][string] $RepoFile, [Parameter(Mandatory)][string] $DeployedFile)

    if (-not (Test-Path -LiteralPath $DeployedFile)) {
        return [pscustomobject]@{ HasChanges = $true; Text = "<destination does not exist yet: $DeployedFile>" }
    }

    # -All can legitimately return multiple git.exe on PATH (e.g. Git for
    # Windows ships both cmd\git.exe and mingw64\bin\git.exe); take one.
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $color = if ($Host.UI.SupportsVirtualTerminal) { 'always' } else { 'never' }
        $out = & $git.Source -c core.safecrlf=false diff --no-index --color=$color --src-prefix=repo/ --dst-prefix=deployed/ -- $RepoFile $DeployedFile 2>&1
        $code = $LASTEXITCODE
        if ($code -le 1) { return [pscustomobject]@{ HasChanges = ($code -eq 1); Text = ($out -join "`n") } }
        Write-Warning "git diff failed (exit $code); falling back to Compare-Object."
    }

    $a = Get-Content -LiteralPath $RepoFile
    $b = Get-Content -LiteralPath $DeployedFile
    $d = Compare-Object -ReferenceObject $a -DifferenceObject $b
    $text = ($d | ForEach-Object {
        $marker = if ($_.SideIndicator -eq '<=') { '- (repo)' } else { '+ (deployed)' }
        "$marker $($_.InputObject)"
    }) -join "`n"
    [pscustomobject]@{ HasChanges = [bool]$d; Text = $text }
}

function Backup-DeployedFile {
    param([Parameter(Mandatory)][string] $DeployedFile, [Parameter(Mandatory)][string] $RepoRoot, [int] $Keep = 10)

    if (-not (Test-Path -LiteralPath $DeployedFile)) { return $null }
    if ($WhatIfPreference) { Write-Host "  (WhatIf) would back up $DeployedFile" -ForegroundColor DarkGray; return $null }

    $name = Split-Path -Leaf $DeployedFile
    $dir  = Join-Path $RepoRoot ".backups\$name"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $dest  = Join-Path $dir "$stamp.bak"
    Copy-Item -LiteralPath $DeployedFile -Destination $dest -Force

    Get-ChildItem -LiteralPath $dir -Filter '*.bak' | Sort-Object Name -Descending | Select-Object -Skip $Keep |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $dest
}

function Copy-Deployed {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Source, [Parameter(Mandatory)][string] $Destination, [switch] $ProtectReadOnly)

    $item  = Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    $wasRO = $item -and $item.Attributes.HasFlag([System.IO.FileAttributes]::ReadOnly)

    if (-not $PSCmdlet.ShouldProcess($Destination, 'Overwrite from repo')) { return $false }

    try {
        if ($wasRO) { Set-ItemProperty -LiteralPath $Destination -Name IsReadOnly -Value $false }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    } finally {
        if (($wasRO -or $ProtectReadOnly) -and (Test-Path -LiteralPath $Destination)) {
            Set-ItemProperty -LiteralPath $Destination -Name IsReadOnly -Value $true
        }
    }
    $true
}

function Test-DeployGuard {
    param([switch] $IncludeVideo, [switch] $Force)

    if (Get-Process -Name 'cs2' -ErrorAction SilentlyContinue) {
        if ($Force) { Write-Warning "cs2.exe is running (-Force set, continuing anyway). It rewrites cfg state on exit." }
        else { throw "cs2.exe is running. Close CS2 first - it rewrites cfg/config state on exit and could clobber this deploy. Use -Force to override." }
    }
    if ($IncludeVideo -and (Get-Process -Name 'steam' -ErrorAction SilentlyContinue)) {
        if ($Force) { Write-Warning "steam.exe is running (-Force set, continuing anyway). Steam Cloud owns cs2_video.txt and may overwrite it." }
        else { throw "steam.exe is running and -IncludeVideo was given. Steam Cloud owns userdata\...\cs2_video.txt. Close Steam first, or use -Force." }
    }
}

# ================================ main ======================================

try {
    $steamRoot = Resolve-SteamRoot
    Write-Host "[env] Steam root: $steamRoot" -ForegroundColor DarkGray

    $accounts = Get-SteamAccounts -SteamRoot $steamRoot

    if ($ListAccounts) {
        Write-Host ""
        Write-Host "Local Steam accounts:" -ForegroundColor Cyan
        $accounts | ForEach-Object {
            $persona = if ($_.PersonaName) { $_.PersonaName } else { '(unknown)' }
            $lp  = if ($_.LastPlayed) { $_.LastPlayed.ToString('yyyy-MM-dd') } else { 'never' }
            $cs2 = if ($_.HasCs2Cfg) { '' } else { ' (no CS2 cfg)' }
            "  {0,-11} {1,-18} {2,-16} {3}{4}" -f $_.AccountId3, $persona, $_.AccountName, $lp, $cs2
        }
        exit 0
    }

    $cfgDir = Resolve-AppLibrary -SteamRoot $steamRoot -AppId 730
    Write-Host "[env] CS2 cfg dir: $cfgDir" -ForegroundColor DarkGray

    # Validate -AccountId eagerly (even under -Check, even without -IncludeVideo)
    # so a typo fails loudly here instead of silently falling through to a
    # best-effort guess for the launch-options report.
    $explicitAccount = $null
    if ($AccountId) { $explicitAccount = Find-Account -Accounts $accounts -Identifier $AccountId }

    Test-DeployGuard -IncludeVideo:$IncludeVideo -Force:$Force

    # ---------------------------- autoexec.cfg ------------------------------
    $repoAutoexec   = Join-Path $RepoRoot 'autoexec.cfg'
    $deployAutoexec = Join-Path $cfgDir 'autoexec.cfg'

    Write-Host ""
    Write-Host "=== Lint: autoexec.cfg ===" -ForegroundColor Cyan
    $removedCvars = @(Get-Content -LiteralPath (Join-Path $RepoRoot 'lint\removed-cvars.txt') |
        Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') } |
        ForEach-Object { $_.Trim().ToLowerInvariant() })

    $findings = Invoke-CfgLint -Path $repoAutoexec -RemovedCvars $removedCvars
    $errorFindings = @($findings | Where-Object Severity -eq 'E')

    foreach ($f in ($findings | Sort-Object Line)) {
        $color = if ($f.Severity -eq 'E') { 'Red' } else { 'Yellow' }
        Write-Host ("  [{0}] line {1}: {2} - {3}" -f $f.Severity, $f.Line, $f.Rule, $f.Message) -ForegroundColor $color
    }
    if (-not $findings) { Write-Host "  clean" -ForegroundColor Green }

    if ($errorFindings.Count -gt 0) {
        Write-Host ""
        Write-Host "$($errorFindings.Count) lint error(s) - deploy blocked." -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "=== Diff: autoexec.cfg ===" -ForegroundColor Cyan
    $diff = Get-FileDiff -RepoFile $repoAutoexec -DeployedFile $deployAutoexec
    $checkDrift = $false
    if ($diff.HasChanges) { Write-Host $diff.Text; $checkDrift = $true } else { Write-Host "  no changes" -ForegroundColor Green }

    # --------------------------- launch options ------------------------------
    Write-Host ""
    Write-Host "=== Launch options (report only, never written) ===" -ForegroundColor Cyan
    $loAccount = $explicitAccount
    if (-not $loAccount) { $loAccount = $accounts | Where-Object HasCs2Cfg | Select-Object -First 1 }

    if ($loAccount) {
        $lcPath = Join-Path $steamRoot "userdata\$($loAccount.AccountId3)\config\localconfig.vdf"
        Write-Host "  account: $($loAccount.AccountId3) ($($loAccount.PersonaName))" -ForegroundColor DarkGray
        if (Test-Path -LiteralPath $lcPath) {
            $lo = Test-LaunchOptions -LocalConfigPath $lcPath -ExpectedFile (Join-Path $RepoRoot 'launch-options.expected')
            if (-not $lo.Found -or $lo.MatchCount -ne 1) {
                Write-Host "  could not reliably locate a single LaunchOptions entry for app 730 (matches: $($lo.MatchCount))" -ForegroundColor Yellow
            } else {
                Write-Host "  found   : $($lo.Actual)"
                Write-Host "  expected: $($lo.Expected)"
                if ($lo.Matches) { Write-Host "  in sync" -ForegroundColor Green }
                else { Write-Host "  DRIFTED" -ForegroundColor Yellow; $checkDrift = $true }
                foreach ($w in $lo.StaleWarnings) { Write-Host "  stale token: $w" -ForegroundColor Yellow }
            }
        } else {
            Write-Host "  localconfig.vdf not found for this account" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  no local account with a CS2 cfg folder found - skipping" -ForegroundColor DarkGray
    }

    if ($IncludeVideo -and $loAccount) {
        Write-Host ""
        Write-Host "=== Diff: cs2_video.txt (account $($loAccount.AccountId3)) ===" -ForegroundColor Cyan
        $vdiff = Get-FileDiff -RepoFile (Join-Path $RepoRoot 'cs2_video.txt') -DeployedFile (Join-Path $loAccount.CfgPath 'cs2_video.txt')
        if ($vdiff.HasChanges) { Write-Host $vdiff.Text; $checkDrift = $true } else { Write-Host "  no changes" -ForegroundColor Green }
    }

    if ($Check) {
        Write-Host ""
        if ($checkDrift) { Write-Host "Check complete - drift found (see above)." -ForegroundColor Yellow; exit 2 }
        Write-Host "Check complete - everything in sync." -ForegroundColor Green
        exit 0
    }

    # ------------------------- deploy: autoexec.cfg --------------------------
    Write-Host ""
    Write-Host "=== Deploy: autoexec.cfg ===" -ForegroundColor Cyan
    if (-not $diff.HasChanges) {
        Write-Host "  already up to date, nothing to do" -ForegroundColor Green
    } else {
        if (-not $NoBackup -and (Test-Path -LiteralPath $deployAutoexec)) {
            $backup = Backup-DeployedFile -DeployedFile $deployAutoexec -RepoRoot $RepoRoot -Keep $BackupKeep
            if ($backup) { Write-Host "  backup: $backup" -ForegroundColor DarkGray }
        }
        if (Copy-Deployed -Source $repoAutoexec -Destination $deployAutoexec) {
            $srcHash = (Get-FileHash -LiteralPath $repoAutoexec -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash -LiteralPath $deployAutoexec -Algorithm SHA256).Hash
            if ($srcHash -eq $dstHash) { Write-Host "  deployed, hash verified ($srcHash)" -ForegroundColor Green }
            else { Write-Warning "  hash mismatch after copy! repo=$srcHash deployed=$dstHash"; $ExitCode = 5 }
        }
    }

    # ------------------------ deploy: cs2_video.txt ---------------------------
    if ($IncludeVideo) {
        Write-Host ""
        Write-Host "=== Deploy: cs2_video.txt ===" -ForegroundColor Cyan
        $account = if ($explicitAccount) { $explicitAccount } else { Resolve-Account -Accounts $accounts -AccountId $AccountId -RepoRoot $RepoRoot }
        Write-Host "  account: $($account.AccountId3) ($($account.PersonaName) / $($account.AccountName))" -ForegroundColor DarkGray

        $repoVideo   = Join-Path $RepoRoot 'cs2_video.txt'
        $deployVideo = Join-Path $account.CfgPath 'cs2_video.txt'
        $vdiff = Get-FileDiff -RepoFile $repoVideo -DeployedFile $deployVideo
        if ($vdiff.HasChanges) { Write-Host $vdiff.Text } else { Write-Host "  no changes" -ForegroundColor Green }

        if ($vdiff.HasChanges) {
            if (-not $NoBackup -and (Test-Path -LiteralPath $deployVideo)) {
                $backup = Backup-DeployedFile -DeployedFile $deployVideo -RepoRoot $RepoRoot -Keep $BackupKeep
                if ($backup) { Write-Host "  backup: $backup" -ForegroundColor DarkGray }
            }
            if (Copy-Deployed -Source $repoVideo -Destination $deployVideo -ProtectReadOnly) {
                Write-Host "  deployed, set read-only" -ForegroundColor Green
            }
        } else {
            Write-Host "  already up to date, nothing to do" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    exit $ExitCode
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 4
}
