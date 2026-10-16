# Admin Toolkit - notes for Claude

Modular WPF GUI (PowerShell 5.1 compatible) that runs admin modules: Microsoft 365 PowerShell modules and local scripts.
Formerly M365 Admin Toolkit: the old names (M365AdminToolkit) remain only for migration and the one-off bridge release.
Read README.md for the architecture and the module contract.

## Adding or changing a module
- Create modules with `New-TkModule` (GUI "+ Add module", or `Tools/New-ToolkitModule.ps1 [-FromScript]`); never hand-copy `_Template` without renaming the Id.
- `module.json` Parameters must match the script `param()` block exactly (names; Mandatory <=> Required).
- Anything that changes tenant state: `SupportsWhatIf: true` + `$PSCmdlet.ShouldProcess`, and output a row with Status `WhatIf`.
- Modules that only read: set `"ReadOnly": true` so the change guard enforces it on every run.
- Tenant readiness: if a module can prove a security-posture factor ("X of Y users have a passkey"), add
  `if (Test-Path Function:\Write-TkReadiness) { Write-TkReadiness -Ready -Total -Label [-NotEvaluated] }` once at the end.
  Count the whole population checked, not just the rows output; anything unchecked goes in -NotEvaluated, never in Ready/Total.
  Don't invent a rule where there is no clear "ready" (e.g. a change module or a plain inventory) - ask the user first.
  Optional thresholds in module.json: `"Readiness": { "Pass": 90, "Warn": 70 }`. See README "Tenant readiness".
- The change guard (Toolkit.Worker.ps1) is safety-critical: after touching it, rerun the guard test suite and keep "fail closed" behaviour (block when unsure).
- The sign-in session policy (Toolkit.Worker.ps1 "Sign-in session policy" region) is safety-critical too:
  every connect goes through Confirm-TkSession + Register-TkSignIn (tenant pinning), Graph uses
  `-ContextScope Process` and bypasses WAM. Keep it failing closed and rerun Tests/Session.Tests.ps1.
- Don't call commands via `& (Get-Command X)` in modules: it bypasses the dry-run guard.
- Tags: reuse existing tags before inventing new ones; short, no commas.
- Prefer `Invoke-MgGraphRequest` over Microsoft.Graph.* sub-modules so only Microsoft.Graph.Authentication is needed.
- Log with Write-Information/Write-Warning; never Read-Host or other prompts.
- Always finish with `.\Tools\Test-ToolkitModules.ps1 -IncludeTemplate` (must exit 0).
- Modules in `Modules/` may be the user's own work - don't edit ones you didn't create unless asked.
- `Modules/` is git-ignored except the modules listed as `!Modules/<Id>/` in `.gitignore`: those are published and ship in the Full edition. New modules stay private: only add one to that list when the user asks, never `git add -f`.

## Releases
- Build with `Tools/New-ToolkitRelease.ps1` only: it packages a tagged commit, signs, then hashes. Order matters - hash after signing.
- Each release has two editions from the same commit: Core (`AdminToolkit-<v>.zip`, only `_Template` + `Demo.SelfTest`) and Full (`AdminToolkit-<v>-Full.zip`, every committed module), one SHA256SUMS file with a line per ZIP, and an `EDITION` file in each. Keep the Core ZIP name unchanged: older `Get-AdminToolkit.ps1` copies look for it. `-LegacyNames` (old `M365AdminToolkit` names and repo) is only for the bridge release that moves pre-rename installs; it must never change any check. Don't weaken the tenant-data gate in the build.
- Publish with `Tools/Publish-ToolkitRelease.ps1` (draft, upload, publish). `Get-AdminToolkit.ps1` trusts only its own signer and fails closed: never add a bypass that skips the hash, signature, catalog or zip-slip checks.
- Never overwrite or rebuild a published version; bump the version. Never commit certificates, keys or thumbprints.

## Installer
- `Install-Toolkit.ps1` keeps a `$programItems` list (replaced on upgrade, removed on uninstall). Add new top-level program files or folders there; anything not listed is treated as user data.
- Upgrades must never overwrite `Config/settings.json`, `Logs/` or newer module files in the installed copy.
- Migration from an M365 Admin Toolkit install (`Find-LegacyToolkit` / `Move-LegacyToolkit`) copies user data and only then removes the old program files; it never deletes the old user data and never runs against a git working copy or the folder setup runs from. Test it with `-Portable -MigrateFrom` only.
- Test it only with `-Portable` into a temp folder (Tests/Installer.Tests.ps1); a normal install writes Start menu shortcuts and an HKCU uninstall key.

## Code rules
- Keep `.ps1`/`.psm1` files ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI. Use `[char]0x2605` etc. for symbols.
- Don't use `$PSScriptRoot` in `param()` defaults (empty in 5.1) - resolve it in the body.
- GUI event handlers can't reassign script variables; mutate `$State` members instead.
- Returning a collection that may be empty (HashSet, DataTable, List) needs a leading comma: `, $set`.
- Never wrap a `List[object]` in `@(...)` - in this PS 5.1 build it throws 'Argument types do not match'. Use `.ToArray()`, `foreach` or the pipeline.
- `$matches`, `$input`, `$args` are automatic variables - don't use them as ordinary names.
- Never set `$WhatIfPreference` for a whole script: it silently disables Set-Alias/Set-Variable/New-Item and changes script logic.
- Don't name helper functions after aliases (`Select`, `Where`, `Sort`...) - aliases win.
- `-WhatIf` doesn't flow from a script into `.psm1` functions; pass `-WhatIf:$WhatIfPreference` explicitly.
- ToggleButtons: react to Checked/Unchecked, not Click, so keyboard and UI Automation work. Give panel-based rows an `AutomationProperties.Name`.
- Colours: never literals in XAML or code. Use `{DynamicResource Tk.*}` names from `Core/Themes/Light.xaml` + `Dark.xaml` (add new names to both), and `SetResourceReference(...)` instead of assigning brushes in code, so the theme can switch live. Tests/Theme.Tests.ps1 checks this.
- Built-in WPF templates hard-code light colours: new control types need a themed style in `Core/Styles.xaml`.
- The WPF Application outlives a launch (relaunching in the same PowerShell session keeps its resources, while the module is re-imported). Find app-level dictionaries by their keys, never by a reference kept in module script state.
- Personal preferences (favourites, group-by, theme) go in `%APPDATA%\AdminToolkit\preferences.json` (read from `%APPDATA%\M365AdminToolkit` until the first save), never in the toolkit folder.
- Never put real tenant data, UPNs, usernames or secrets in code, manifests, examples or tests - use contoso.example placeholders.
