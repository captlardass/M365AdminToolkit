# M365 Admin Toolkit - notes for Claude

Modular WPF GUI (PowerShell 5.1 compatible) that runs Microsoft 365 admin modules.
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
- Don't call commands via `& (Get-Command X)` in modules: it bypasses the dry-run guard.
- Tags: reuse existing tags before inventing new ones; short, no commas.
- Prefer `Invoke-MgGraphRequest` over Microsoft.Graph.* sub-modules so only Microsoft.Graph.Authentication is needed.
- Log with Write-Information/Write-Warning; never Read-Host or other prompts.
- Always finish with `.\Tools\Test-ToolkitModules.ps1 -IncludeTemplate` (must exit 0).
- Modules in `Modules/` may be the user's own work - don't edit ones you didn't create unless asked.
- `Modules/` is git-ignored except `_Template` and `Demo.SelfTest`: the user's modules stay private. Never un-ignore or `git add -f` them.

## Releases
- Build with `Tools/New-ToolkitRelease.ps1` only: it packages a tagged commit, signs, then hashes. Order matters - hash after signing.
- Never overwrite or rebuild a published version; bump the version. Never commit certificates, keys or thumbprints.

## Installer
- `Install-Toolkit.ps1` keeps a `$programItems` list (replaced on upgrade, removed on uninstall). Add new top-level program files or folders there; anything not listed is treated as user data.
- Upgrades must never overwrite `Config/settings.json`, `Logs/` or newer module files in the installed copy.
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
- Personal preferences (favourites, group-by, theme) go in `%APPDATA%\M365AdminToolkit\preferences.json`, never in the toolkit folder.
- Never put real tenant data, UPNs, usernames or secrets in code, manifests, examples or tests - use contoso.example placeholders.
