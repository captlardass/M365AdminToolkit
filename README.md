# M365 Admin Toolkit

A desktop GUI for Microsoft 365 administrators who want **one place to run their PowerShell scripts**,
without a console, without remembering parameters and without worrying about pressing Enter too early.

Most admins collect a folder of useful scripts over the years: reports, clean-ups, bulk changes and fixes for
things the admin centers don't expose. The toolkit turns each of those scripts into a **module** with its own
input form, a results grid, CSV export and a safe dry run.

## Why use it

- **Modular.** Every task is a small folder: a `module.json` manifest plus a PowerShell script. Add as many
  as you like. Drop a folder into `Modules\` and click *Reload modules*. The GUI never needs to change.
- **Bring your own scripts.** *+ Add module* turns an existing `.ps1` into a module. It reads the `param()`
  block to build the form and detects Graph scopes and Exchange Online use. It also warns about
  things that won't work in a GUI, such as `Read-Host` prompts or the script connecting on its own.
- **Sign in once.** Microsoft Graph and Exchange Online sessions are kept between runs, so you don't sign in
  again for every script. Each module only asks for the Graph permissions it declares.
- **Safe by default.** Modules that change things open in *dry-run* mode. Scripts that support `-WhatIf`
  describe their own changes. For scripts that don't, the toolkit blocks every Microsoft 365 write and lists
  it in the *Blocked changes* tab, so you can see what *would* have happened. Modules marked read-only
  are never allowed to change anything.
- **Easy to find.** Search by name, category, tag or description. Group by category, tag or name, and star
  favourites.
- **Results you can use.** Output lands in a sortable grid and exports to CSV in one click.
- **Stays responsive.** Scripts run in a background worker, so the window never freezes and long runs can
  be cancelled.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in) or PowerShell 7
- The PowerShell modules for the services you use:

| Service | Module | Needed by |
|---|---|---|
| Microsoft Graph (Entra ID, Intune, Teams, ...) | `Microsoft.Graph.Authentication` | Modules that list Graph scopes |
| Exchange Online | `ExchangeOnlineManagement` | Modules that require Exchange Online |

- An admin account with the right roles for the modules you run. Each module shows the Graph scopes it
  needs, and you consent to them the first time.

## Installation

1. **Get the files.** Clone the repository or download it and extract it to a folder, for example
   `C:\Tools\M365AdminToolkit`.

2. **Unblock the files** if you downloaded a ZIP. Windows marks internet files as blocked:

   ```powershell
   Get-ChildItem -Path 'C:\Tools\M365AdminToolkit' -Recurse | Unblock-File
   ```

3. **Install the service modules** for your user. No admin rights are needed:

   ```powershell
   Install-Module Microsoft.Graph.Authentication, ExchangeOnlineManagement -Scope CurrentUser
   ```

   The toolkit calls Graph through `Invoke-MgGraphRequest`, so the full `Microsoft.Graph` bundle is not required.

4. **(Optional) Set up app-only sign-in.** See [App-only sign-in](#app-only-sign-in-optional).

## Running the toolkit

Double-click **`Start-Toolkit.cmd`**, or start it from PowerShell:

```powershell
powershell.exe -STA -File .\Start-Toolkit.ps1
```

The `.cmd` launcher sets `-ExecutionPolicy RemoteSigned` for its own process only. It does not change your
system settings.

### Running a module

1. Click **Connect Graph** and/or **Connect Exchange** at the top. You can also skip this: the toolkit connects
   automatically when a module needs it.
2. Pick a module in the list on the left. Search, grouping and tags help once you have many.
3. Fill in the inputs. Hover over a field for its help text.
4. For modules that change things, leave **Dry run (WhatIf)** ticked first and click **Run**. Check the
   *Results* and *Blocked changes* tabs.
5. When you're happy, untick **Dry run** and run again. The toolkit asks for confirmation before a real run.
6. Use **Export CSV...** to save the results. The *Log* tab shows progress, warnings and errors.

To use another tenant, click **Disconnect all** and connect again with an account in that tenant.

### Checking installed PowerShell modules

The **Installed modules** tab lists the Microsoft 365 PowerShell modules on this PC: the two the toolkit
needs, common optional ones (Microsoft Graph SDK, Teams, PnP, SharePoint Online, Az.Accounts) and retired
ones (AzureAD, MSOnline) if they are still installed. It scans when the toolkit starts. Scanning never
changes anything; only the **Update** button does, and it asks first.

| Status | Meaning |
|---|---|
| Missing | A module the toolkit needs is not installed |
| Update available | The PowerShell Gallery has a newer version |
| Version mismatch | A Graph sub-module is on a different version than `Microsoft.Graph.Authentication`, a common cause of assembly errors |
| Retired | Microsoft has retired the module. Move scripts to Microsoft Graph |
| Up to date / Installed | Nothing to do (*Installed* means the gallery hasn't been checked) |

Click **Check for updates** to compare the versions with the PowerShell Gallery (this needs internet access).
Graph SDK sub-modules are hidden unless you tick **Show Graph sub-modules**. The summary line still counts them.

After checking, click **Update all** to install the latest version of every module that is *Missing*, has an
*Update available* or a *Version mismatch*. If you select rows first, the button changes to **Update selected**
and only updates those. A version mismatch always brings `Microsoft.Graph.Authentication` along. When the
`Microsoft.Graph` bundle is updated, its sub-modules come with it.

- You confirm the list of modules and versions first. Progress shows on the **Log** tab. Installing the
  Graph bundle takes several minutes.
- Modules are installed with `Install-Module -Force` from the PowerShell Gallery, so nothing prompts. Older
  versions stay installed next to the new ones, and PowerShell loads the newest.
- Modules installed for all users can only be updated in place when the toolkit runs as administrator.
  Otherwise the new version is installed for the current user, and the confirmation says so.
- Retired modules are never removed automatically. Move the scripts that use them to Microsoft Graph first.
- **Restart the toolkit afterwards.** The running session keeps the module versions it already loaded.

## Included modules

| Module | Category | What it does |
|---|---|---|
| Dynamic groups using memberOf | Entra ID | Finds dynamic groups whose rule uses `memberOf`, and the groups each rule points to. Read-only |
| Stale guest accounts report | Entra ID | Lists guests with no sign-in for N days, including ones that never redeemed their invitation. Read-only |
| Set default calendar permission | Exchange Online | Sets the *Default* or *Anonymous* permission on mailbox calendars, e.g. LimitedDetails. Supports dry run |
| Toolkit self-test | Toolkit | Generates dummy results without touching a tenant, to check the GUI, dry run, cancel and CSV export |

## Adding your own scripts

### From the GUI

Click **+ Add module**, pick your `.ps1` file (or start from the blank template) and review what the toolkit
detected: name, category, inputs, Graph scopes, Exchange Online and read-only. Save, and the module appears
in the list straight away.

### From the command line

```powershell
# Wrap an existing script
.\Tools\New-ToolkitModule.ps1 -Id Exchange.SharedSentItems -Name 'Shared mailbox sent items' `
    -Category 'Exchange Online' -FromScript C:\Scripts\Set-SentItems.ps1 -ExchangeOnline -Tags 'Shared mailbox'

# Start from the blank template
.\Tools\New-ToolkitModule.ps1 -Id Entra.LicenseReport -Name 'License report' -Category 'Entra ID' `
    -GraphScopes User.Read.All, Organization.Read.All -Tags Licensing, Report
```

Then check the module against the contract:

```powershell
.\Tools\Test-ToolkitModules.ps1 -IncludeTemplate
```

A module that breaks the contract is shown in red in the GUI with the reasons. It can't be run, and it can't
crash the app.

### Tips for making a script GUI-friendly

- **Take input through `param()`.** Every parameter becomes a field on the form. Don't use `Read-Host`,
  `Get-Credential` or `Out-GridView`: there is no console to answer them.
- **Don't connect or disconnect.** Remove `Connect-MgGraph` / `Connect-ExchangeOnline` and the matching
  `Disconnect-*` calls. The toolkit signs in before your script runs and keeps the session for the next one.
- **Declare the Graph scopes in a comment**, e.g. `# GraphScopes: User.Read.All, Organization.Read.All`.
  The Add module dialog then fills them in. Without scopes the toolkit doesn't connect to Graph at all.
- **Output objects, not text.** Each object becomes a row in the grid and the CSV.
- **Log with `Write-Information` and `Write-Warning`.** Throw an error to fail the run.
- **Support WhatIf if your script changes things.** Use `[CmdletBinding(SupportsShouldProcess)]` and wrap each
  change in `$PSCmdlet.ShouldProcess(...)`, then report `WhatIf` in the output row. The dry run then shows
  exactly what would change.
- **Prefer `Invoke-MgGraphRequest`** over the `Microsoft.Graph.*` sub-modules, so only
  `Microsoft.Graph.Authentication` is needed.
- **Keep scripts ASCII-only**, or save them as UTF-8 *with* BOM. Windows PowerShell 5.1 reads files without a
  BOM as ANSI.

## Module reference

A module is a folder under `Modules\`, named after its Id:

```
Modules\
  Entra.LicenseReport\
    module.json     <- manifest: name, inputs, requirements
    module.ps1      <- your script
```

### module.json

```json
{
  "Id": "Entra.LicenseReport",
  "Name": "License report",
  "Category": "Entra ID",
  "Description": "Lists assigned licenses per user. Read-only.",
  "Version": "1.0.0",
  "EntryPoint": "module.ps1",
  "Tags": ["Licensing", "Report"],
  "SupportsWhatIf": false,
  "ReadOnly": true,
  "Requires": {
    "ExchangeOnline": false,
    "GraphScopes": ["User.Read.All", "Organization.Read.All"]
  },
  "Parameters": [
    { "Name": "Users", "Label": "Users", "Type": "List", "Required": true, "HelpText": "One UPN per line, e.g. user@contoso.example" },
    { "Name": "IncludeDisabled", "Label": "Include disabled users", "Type": "Bool", "Default": false }
  ]
}
```

| Field | Required | Notes |
|---|---|---|
| `Id` | yes | `Area.TaskName`, unique. Also the folder name |
| `Name`, `Category`, `Description` | yes | Shown in the GUI. Category groups the list |
| `Version` | yes | e.g. `1.2.0` |
| `EntryPoint` | yes | Script file, usually `module.ps1` |
| `Tags` | no | Short labels for search and grouping, without commas |
| `SupportsWhatIf` | no | `true` requires `[CmdletBinding(SupportsShouldProcess)]` in the script |
| `ReadOnly` | no | `true` blocks every Microsoft 365 change, on every run |
| `Requires.ExchangeOnline` | no | Connect to Exchange Online before running |
| `Requires.GraphScopes` | no | Delegated Graph scopes. A non-empty list means the toolkit connects to Graph |
| `Parameters[]` | no | The form inputs. See below |

### Parameters

Each entry has `Name` (must match the script parameter), `Label`, `Type`, `Required`, `Default`,
`Options` (Choice only) and `HelpText`.

| Type | Control | Script receives |
|---|---|---|
| `String` | text box | `[string]` |
| `Int` | text box, validated | `[int]` |
| `Bool` | check box | `[bool]` |
| `Choice` | drop-down of `Options` | `[string]` |
| `List` | multi-line box, one value per line | `[string[]]` |

Rules checked by `Test-ToolkitModules.ps1`:

- Every parameter in `module.json` exists in the script's `param()` block, with the same name.
- A `[Parameter(Mandatory)]` script parameter is `"Required": true` in the manifest.
- `WhatIf`, `Confirm`, `Verbose`, `Debug`, `ErrorAction` and `InformationAction` are reserved names.
- Empty optional inputs are not passed, so the script's own default applies.

## App-only sign-in (optional)

To sign in with an app registration instead of your own account, copy `Config\settings.example.json` to
`Config\settings.json` and fill in the tenant ID, client ID and certificate thumbprint. The certificate
must be in your certificate store. Leave the values empty for interactive sign-in.

Only certificate authentication is supported. Client secrets are deliberately not supported.
`settings.json` is git-ignored and must never be committed.

## How it works

```
 Start-Toolkit.ps1  (UI thread, WPF)             Worker runspace  (one, long-lived)
 +--------------------------------+   job   +-----------------------------------+
 | module list + generated form   | ------> | Invoke-TkModule                   |
 | collects input values          |         |   Connect-TkGraph / -TkExchange   |
 | timer drains output every 250ms| <------ |   change guard (dry run/read-only)|
 | results grid / log / CSV       | streams |   & Modules\<Id>\module.ps1       |
 +--------------------------------+         +-----------------------------------+
```

| Piece | File | Role |
|---|---|---|
| Launcher | `Start-Toolkit.ps1` | Window wiring, event handlers and GUI state |
| Engine | `Core\Toolkit.Core.psm1` | Discovery, contract validation, form builder, job runner, result flattening, installed-modules inventory |
| Worker | `Core\Toolkit.Worker.ps1` | Connections, change guard, runs modules. Loaded into the worker |
| Dialogs | `Core\AddModuleDialog.ps1`, `Core\ScriptViewer.ps1` | *+ Add module* and *View script* |
| Layout | `Core\*.xaml` | WPF markup and styles |
| Tools | `Tools\New-ToolkitModule.ps1`, `Tools\Test-ToolkitModules.ps1` | Create and validate modules |

- **One worker runspace.** Connections made for one module are reused by the next, and the UI never blocks.
  Jobs run one at a time.
- **The worker never touches the UI.** The UI thread polls the job's streams, so there are no cross-thread calls.
- **Change guard.** In a dry run or a read-only module, the worker intercepts Microsoft 365 write commands and
  non-GET REST calls before they run, and reports them as blocked. It can't see changes made by other
  processes or by .NET web clients. The GUI tells you when a module does something it can't guard.
- **Privacy.** The log file in `Logs\` records which module ran and *which* inputs were supplied, never the
  values. Personal preferences such as favourites and grouping are stored in
  `%APPDATA%\M365AdminToolkit\preferences.json`, not in the toolkit folder.

## Troubleshooting

| Problem | Fix |
|---|---|
| *Scripts are blocked* / *not digitally signed* | Run `Unblock-File` on the folder (see [Installation](#installation)) |
| Graph and Exchange together fail with an assembly or MSAL error | Known conflict between the two modules in Windows PowerShell 5.1. Connect to Exchange first, or run under PowerShell 7. Also check *Installed modules* for Graph version mismatches |
| A module shows in red | Select it to see the problems, or run `.\Tools\Test-ToolkitModules.ps1` |
| A run finishes with 0 results and an error | Check the *Log* tab. The error is from the module script |
| Strange characters in output or errors | Save the script as ASCII or UTF-8 with BOM |
