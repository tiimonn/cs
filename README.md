## Deploy

```powershell
.\deploy.ps1 -Check     # lint + diff + launch-option report, never writes
.\deploy.ps1             # deploy autoexec.cfg
.\deploy.ps1 -IncludeVideo   # also deploy cs2_video.txt
.\deploy.ps1 -ListAccounts   # list local Steam accounts / SteamID3s
```

Or, via `make` (git-bash, if you have it installed - `make` just shells out to `pwsh -File deploy.ps1`, see the `Makefile`):

```
make check
make deploy
make deploy-all
make accounts
```

`autoexec.cfg` is install-scoped and needs no account selection. `cs2_video.txt`
is Steam-Cloud/account-scoped (keyed by SteamID3, **not** SteamID64, under
`userdata\<SteamID3>\730\local\cfg`) - `-IncludeVideo` auto-detects the account
when only one has a CS2 cfg folder, otherwise it prompts. Pass `-AccountId`
(SteamID3, SteamID64, or your persona/account name) to skip the prompt.

Both destinations are auto-detected: the CS2 library is resolved from
`steamapps\libraryfolders.vdf` (whichever library actually has app 730), not
hardcoded to a drive letter.

Every deploy backs up the file it's about to overwrite into `.backups\`
(gitignored) before writing, and `deploy.ps1` refuses to run while `cs2.exe`
is open (and while `steam.exe` is open, for `-IncludeVideo`) since both
rewrite cfg state on exit and could clobber the deploy.

Steam launch options are **reported only, never written** by the script - see
`launch-options.expected`. CS2 auto-executes `csgo/cfg/autoexec.cfg` on
startup, so the launch option is belt-and-braces, not load-bearing:

```
+exec autoexec.cfg -console -high -fullscreen
```

(`-novid` and `-tickrate` are CS:GO-era flags with no effect in CS2.)

---

## Manual fallback

If you'd rather copy by hand:

```
...\SteamLibrary\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg
```

```
code "D:\SteamLibrary\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg\autoexec.cfg"
```

Video settings live per-account under
`C:\Program Files\Steam\userdata\<SteamID3>\730\local\cfg\cs2_video.txt` -
set it read-only afterward so Steam Cloud doesn't overwrite it:

```powershell
Set-ItemProperty -Path "...\cs2_video.txt" -Name IsReadOnly -Value $true
```

---

## Secret scanning

This is a public repo, so [gitleaks](https://github.com/gitleaks/gitleaks)
runs at two points, both using the same `.gitleaks.toml` (default ruleset
plus a custom rule for Steam/CS:GO-style product keys, which the default
rules don't catch):

- **Locally, before every commit.** A hook blocks the commit if gitleaks
  finds a likely secret in your staged changes. Install gitleaks
  (`winget install --id Gitleaks.Gitleaks -e`, or `choco`/`scoop`), then
  enable the hook once per clone:
  ```
  git config core.hooksPath .githooks
  ```
- **On GitHub**, via `.github/workflows/gitleaks.yml` - runs on every push to
  `main` and every pull request, so anything that slips past the local hook
  (a `--no-verify` commit, a fork, an edit made on github.com) still gets
  caught.

A hook only ever sees *new* commits - it can't retroactively clean history.
If a real secret is ever confirmed to have leaked, the correct response is
to revoke/rotate it (a CD key, an API token, ...) and only then decide
whether rewriting history is worth the disruption, since a public repo has
to be treated as already fully cloned/cached the moment something is pushed.

---

## Resources

[Scancodes](https://totalcsgo.com/binds/converter)

[Bind](https://developer.valvesoftware.com/wiki/Bind)

PageUp scancode75
PageDown scancode78
