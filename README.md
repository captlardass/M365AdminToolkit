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
- **Sign in once a session, never by accident.** Microsoft Graph and Exchange Online sessions are kept between
  runs, so you don't sign in again for every script. Each module only asks for the Graph permissions it
  declares. Sessions end at midnight, after a set time or idle period, when the PC sleeps and when the toolkit
  closes. The header always shows the tenant name and tenant ID you're working in. See
  [Sign-in sessions and tenants](#sign-in-sessions-and-tenants).
- **Safe by default.** Modules that change things open in *dry-run* mode. Scripts that support `-WhatIf`
  describe their own changes. For scripts that don't, the toolkit blocks every Microsoft 365 write and lists
  it in the *Blocked changes* tab, so you can see what *would* have happened. Modules marked read-only
  are never allowed to change anything.
- **Easy to find.** Search by name, category, tag or description. Group by category, tag or name, and star
  favourites.
- **Results you can use.** Output lands in a sortable grid, opens as an Excel table, or exports to CSV in one
  click.
- **Tenant readiness.** Modules that can measure a security-posture factor (e.g. how many users have a
  passkey) show it after the run as a percentage with counts, or as Pass / Warn / Fail.
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

1. **Choose an edition.** Every release comes in two editions with the same program. Only the modules differ:

   | Edition | Release file | Pick it when |
   |---|---|---|
   | **Full** | `M365AdminToolkit-<version>-Full.zip` | You want to start straight away with the ready-made modules (see [Included modules](#included-modules)) |
   | **Core** | `M365AdminToolkit-<version>.zip` | You want a clean toolkit and will add your own modules: only the module template and a self-test |

   You can switch later: install the other edition over the top. Modules you added yourself are always kept.
   The edition you have is shown in the tooltip on the version number in the toolkit window.

2. **Download and install it.** Download **`Get-M365AdminToolkit.ps1`** from the latest
   [release](https://github.com/captlardass/M365AdminToolkit/releases/latest), then run it in a normal PowerShell
   window. Don't use *Run as administrator*. It asks which edition you want:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$env:USERPROFILE\Downloads\Get-M365AdminToolkit.ps1"
   ```

   It asks where to install, downloads the edition you chose, then checks it before anything runs:
   - the ZIP's SHA-256 must match the release's checksum file
   - every script and the file catalog that covers all other files must carry a valid signature from the same
     publisher that signed `Get-M365AdminToolkit.ps1`
   - no file in the ZIP may point outside the package folder

   If any check fails, it stops and installs nothing. Options: `-Edition Full` or `-Edition Core` (skips the
   question; `-NoGui` without `-Edition` installs Core), `-Destination <folder>`, `-Version 1.2.0`,
   `-IncludePrerelease`, `-DesktopShortcut`, `-Portable`, and `-NoGui` for scripted installs.

   Alternatively, clone the repository or download and check the ZIP yourself (see
   [Checking a download](#checking-a-download)), extract it and double-click **`Install-Toolkit.cmd`**.

3. **What the installer does.** No admin rights are needed, and nothing is written machine-wide. The installer:
   - copies the toolkit to the folder you choose (default `%LOCALAPPDATA%\Programs\M365AdminToolkit`) and unblocks the files
   - adds **M365 Admin Toolkit** to the Start menu and the desktop
   - adds an uninstall entry under *Settings > Apps* (for your account only)

   The install folder must be private to you. Network paths, system folders such as `Program Files`, and
   folders that other users can change are refused: anyone who can edit the scripts could run code with your
   admin sign-ins. A new folder is created with access for you, SYSTEM and Administrators only.

   From PowerShell you can choose the folder or skip the desktop shortcut:

   ```powershell
   .\Install-Toolkit.ps1                                   # Start menu shortcut only
   .\Install-Toolkit.ps1 -DesktopShortcut -Destination D:\Tools\M365AdminToolkit
   .\Install-Toolkit.ps1 -Portable -Destination E:\M365AdminToolkit   # files only, e.g. on a USB stick
   ```

   **To upgrade**, run the installer again from a newer copy. Core files are replaced. Modules you created or
   edited in the installed copy are kept, and so are `Config\settings.json` and the logs.

   **To uninstall**, use *Settings > Apps*, or run `.\Install-Toolkit.ps1 -Uninstall`. Your modules, settings
   and logs stay in the folder unless you add `-RemoveUserData`.

   You can also skip the installer and run the toolkit straight from the extracted folder (see below). In that
   case, unblock a downloaded ZIP first: `Get-ChildItem -Recurse | Unblock-File`.

4. **Install the service modules** for your user. No admin rights are needed. The toolkit's **Settings** tab
   (*Installed PowerShell modules*) can do this for you, or run:

   ```powershell
   Install-Module Microsoft.Graph.Authentication, ExchangeOnlineManagement -Scope CurrentUser
   ```

   The toolkit calls Graph through `Invoke-MgGraphRequest`, so the full `Microsoft.Graph` bundle is not required.

5. **(Optional) Set up app-only sign-in.** See [App-only sign-in](#app-only-sign-in-optional).

## Running the toolkit

Open **M365 Admin Toolkit** from the Start menu if you installed it. Otherwise double-click
**`Start-Toolkit.cmd`**, or start it from PowerShell:

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
6. Use **Open in Excel** to see the results as a filterable Excel table. Numbers and dates get real
   number and date types, while IDs, serial numbers and anything that looks like a formula stay text. The
   workbook is built straight in Excel and isn't saved anywhere until you save it. This needs desktop
   Excel. Use **Export CSV...** to save the results as a file. The *Log* tab shows progress, warnings and errors, and
   **Export log...** saves it as a text file. The export holds everything shown on screen, including
   blocked changes, which can name users or mailboxes. The daily file in `Logs\` deliberately leaves
   those out.

To use another tenant, click **Disconnect all** and connect again with an account in that tenant.

### Sign-in sessions and tenants

The toolkit works in customer tenants, so it is strict about which sign-in it uses.

**The header shows the tenant.** Next to the title you see the tenant's name and tenant ID, read from the
tenant itself, never guessed from your account's domain. (With delegated admin (GDAP) your account belongs to
a different tenant than the one you manage.) The window title shows the same, so it's visible in the
taskbar too. The log names the tenant at the start of every run. If the name can't be read (the sign-in
lacks `User.Read` and Exchange isn't connected), the ID is still shown.

**One tenant per session.** The first sign-in pins the session to its tenant. If Graph or Exchange then signs
in to a different tenant, or the toolkit can't tell which tenant a sign-in belongs to, it signs out of
everything. The same happens if a script connects to another tenant on its own. To switch tenant, click
**Disconnect all** first.

**Sessions end, and you sign in again**, at the first of:

| Reason | Default |
|---|---|
| Midnight (the date changes) | always |
| Time since sign-in | 8 hours (`Session.MaxAgeHours`, 1-24) |
| No module run or connect | 60 minutes (`Session.IdleMinutes`, 1-1440) |
| The PC slept or hibernated | always |
| The system clock went backwards | always |
| The toolkit closed | always |

The check runs before every connect and module run, and once a minute while the toolkit is idle. When a
session ends, the header says why until you sign in again. Change the two limits under **Settings >
Sign-in sessions**. They are saved in `Config\settings.json` (so they apply to everyone using that copy of
the toolkit) and take effect at once: a shorter limit can end the current session straight away. Midnight,
sleep and closing the toolkit always end a session and can't be switched off.

**Nothing is reused from an earlier launch.** Graph signs in with an in-memory token cache
(`-ContextScope Process`), so no token is written to disk. Sign-in also bypasses WAM, the Windows sign-in
broker. WAM silently reuses an account's tokens even after a restart, so without it the browser asks which
account to use every time. Your own Graph WAM setting is put back straight after sign-in. Graph and Exchange
keep connections for the whole PowerShell process, so a connection the toolkit didn't make in this launch
is ended before use. That includes one from an earlier launch in the same PowerShell window or from a
`Connect-MgGraph` you ran yourself.

### Light and dark mode

The toolkit follows the Windows app mode (*Settings > Personalisation > Colours > Choose your app mode*).
If you change it while the toolkit is open, the toolkit switches when you return to its window. To always
use one mode, pick **Light** or **Dark** under **Settings > Appearance**. **Match Windows** goes back
to following Windows. The choice is saved per user.

### Checking installed PowerShell modules

The window has two pages, shown as tabs under the header: **Modules**, where you work and where the toolkit
opens, and **Settings**. Under *Installed PowerShell modules*, **Settings** lists the Microsoft 365
PowerShell modules on this PC. When something needs fixing, the tab says so, for example
*Settings (1 to fix)*. The list covers the two the toolkit
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

**Module folders** lists the folders PowerShell loads modules from (`$env:PSModulePath`, with their scope) and,
if rows are selected, where each installed version of those modules is. It then offers to open the selected
module's folder, or your own module folder, in Explorer. The paths are only shown on screen, never logged.

**Uninstall** removes every installed version of the selected modules with `Uninstall-Module`, after you confirm.
It fails closed and leaves these alone, saying why:
- versions the toolkit has loaded (for example after **Connect Graph**): their files are locked, so removing them
  would leave a half-deleted module. Restart the toolkit and uninstall before connecting.
- versions installed for all users, unless the toolkit runs as administrator.
- copies that weren't installed with `Install-Module` (use **Module folders** to find and delete them by hand).

Removing the `Microsoft.Graph` bundle doesn't remove its sub-modules: tick **Show Graph sub-modules** and select
them too. Bundles are removed before their sub-modules, and `Microsoft.Graph.Authentication` last.

## Included modules

Both editions include the samples. The **Full** edition also has the ready-made modules below. All of them only
read, except *Set default calendar permission*, which supports a dry run.

| Module | Category | What it does | Core | Full |
|---|---|---|---|---|
| Toolkit self-test | Toolkit | Generates dummy results without touching a tenant, to check the GUI, dry run, cancel and CSV export | Yes | Yes |
| `_Template` | - | The blank module that *+ Add module* and `New-ToolkitModule.ps1` start from | Yes | Yes |
| Get passkey registration status | Custom | Which licensed or role-holding users have registered a passkey (FIDO2) | - | Yes |
| Dynamic groups using memberOf | Entra ID | Dynamic groups whose rule uses `memberOf`, so they can be rewritten before the attribute is retired | - | Yes |
| Licensed users with privileged roles | Entra ID | Licensed users holding Entra ID roles, including PIM eligible and group-based assignments | - | Yes |
| Nested group membership | Entra ID | Every group that is a member of another group, direct or inherited | - | Yes |
| Primary MFA method per user | Entra ID | Which MFA method each user is prompted with first, and how strong it is | - | Yes |
| SMS/Voice MFA retirement check | Entra ID | SMS/Voice method policy, migration and campaign state ahead of the retirement | - | Yes |
| Stale guest accounts report | Entra ID | Guests without a sign-in in the chosen number of days, or that never redeemed | - | Yes |
| Set default calendar permission | Exchange Online | Sets the Default or Anonymous permission on mailbox calendars (dry run first) | - | Yes |
| Shared mailbox report | Exchange Online | Shared mailboxes with Sent Items settings and effective permission counts | - | Yes |
| Intune PC inventory | Intune | Intune managed devices with serial number, model, primary user and dates | - | Yes |

**Which modules ship.** `.gitignore` decides: a module ships (in Full) only if it is listed there as an
exception (`!Modules/<Id>/`). A new module you create stays private on your PC until you add that line.
Before you add one, make sure it contains no real tenant data: the release build stops if it finds an e-mail
address or `*.onmicrosoft.com` name that isn't a placeholder such as `contoso.example`.

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
- **Report tenant readiness when the script can prove it.** See [Tenant readiness](#tenant-readiness).
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
| `Readiness` | no | `{ "Pass": 90, "Warn": 70 }`: thresholds (0-100) for Pass / Warn / Fail. See [Tenant readiness](#tenant-readiness) |

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
- `Readiness`, if present, has only `Pass` and `Warn`, both numbers from 0 to 100, and `Warn` is not above `Pass`.

### Tenant readiness

A module that can prove a security-posture factor reports it once, at the end of its script:

```powershell
if (Test-Path Function:\Write-TkReadiness) {
    Write-TkReadiness -Ready $withPasskey -Total $checked -NotEvaluated $couldNotCheck -Label 'users have a passkey'
}
```

After the run, a **Tenant readiness** box appears beside the module's inputs. It holds a ring filled to the
percentage and coloured by rating, the counts (e.g. "146 of 200 users have a passkey"), the "not evaluated"
count and the thresholds. The **Percentage / Pass / Warn / Fail** switch picks what the ring shows in large
type, and the choice is saved in your preferences. The box shows the selected module's last run in
this session. It is hidden for modules that haven't reported a figure, and the inputs then use the full width.

- **Count everything the module checked**, not only the rows it outputs. A report filtered to "problems only"
  still reports against the whole population.
- **Items that couldn't be checked go in `-NotEvaluated`**, never in `-Ready` or `-Total`.
- **Ratings:** Pass at 90% or more, Warn at 70% or more, otherwise Fail. A module can set its own thresholds
  with `"Readiness": { "Pass": 95, "Warn": 80 }` in `module.json`. The percentage is rounded down, so 89.9%
  is a Warn, not a Pass.
- **Fail closed.** Nothing is shown if the figure is impossible (ready above total, a total of 0), or if the run
  failed or was cancelled, because a partial count would give the wrong score. Figures are kept in memory
  only, never saved, and aren't added to the grid or the CSV.
- The `Test-Path` check lets the script still run outside the toolkit.

The self-test module shows a working example with dummy data.

## App-only sign-in (optional)

To sign in with an app registration instead of your own account, copy `Config\settings.example.json` to
`Config\settings.json` and fill in the tenant ID, client ID and certificate thumbprint. The certificate
must be in your certificate store. Leave the values empty for interactive sign-in.
App-only sessions follow the same [session rules](#sign-in-sessions-and-tenants). When a session ends,
the toolkit signs in again with the certificate the next time it's needed.

Only certificate authentication is supported. Client secrets are deliberately not supported.
`settings.json` is git-ignored and must never be committed.

## Releases, checksums and signing

### Checking a download

`Get-M365AdminToolkit.ps1` does all of the checks below for you. To check a download by hand instead: each
release has one `M365AdminToolkit-<version>.SHA256SUMS.txt` file with a line for each edition's ZIP. Before you
install, check that the ZIP is the one that was published:

```powershell
(Get-FileHash .\M365AdminToolkit-1.0.0-Full.zip -Algorithm SHA256).Hash   # must match its line in SHA256SUMS.txt (case doesn't matter)
```

If the scripts are signed, also check who signed them after extracting:

```powershell
Get-AuthenticodeSignature .\M365AdminToolkit\Start-Toolkit.ps1 | Format-List Status, SignerCertificate
```

`Status` must be `Valid`. A checksum proves the file hasn't changed. Only a signature proves who published it.

### Making a release (maintainers)

1. Commit everything and tag the version, using [semantic versioning](https://semver.org). In **GitHub
   Desktop**: commit, open *History*, right-click the commit, choose *Create Tag...* and enter `v1.0.0`, then
   click *Push origin* (it pushes the tag too). Or from the command line:

   ```powershell
   git tag -a v1.0.0 -m "M365 Admin Toolkit 1.0.0"
   git push origin v1.0.0
   ```

2. Build the release: one run builds both editions. Add `-CertificateThumbprint` to sign the scripts with a
   code-signing certificate:

   ```powershell
   .\Tools\New-ToolkitRelease.ps1 -Version 1.0.0
   .\Tools\New-ToolkitRelease.ps1 -Version 1.0.0 -CertificateThumbprint <thumbprint>
   ```

   The script packages exactly the tagged commit. Local changes, tests and git-ignored (private) modules are
   never included. From it, it builds the **Core** edition (`M365AdminToolkit-<version>.zip`, sample modules
   only, the same file name as before the split, so older copies of `Get-M365AdminToolkit.ps1` still work) and
   the **Full** edition (`M365AdminToolkit-<version>-Full.zip`, every committed module). Each has an `EDITION`
   file. The build stops if a shipped file contains an e-mail address or tenant name that isn't a placeholder. It signs the scripts with a timestamp, so the signatures stay valid after the certificate
   expires. Then it zips each edition and writes the SHA-256 of both final ZIPs into one checksum file, so the
   checksums cover the signed files. It never overwrites a version that has already been built. When signing, it also writes a signed
   file catalog (`M365AdminToolkit.cat`) that covers the files a signature can't (XAML, JSON). It also puts a
   copy of the signed `Get-M365AdminToolkit.ps1` next to the ZIP.

3. Publish it with the GitHub CLI (`gh auth login` first). This creates the release for the pushed tag as a
   draft, uploads both ZIPs, the checksum file and `Get-M365AdminToolkit.ps1`, then publishes it. The release
   notes explain which edition to pick and list the Full modules from their `module.json`, so they always match
   what ships (`-WhatIf` shows them). It refuses an existing release, a ZIP that no longer matches its checksum
   and an unsigned build:

   ```powershell
   .\Tools\Publish-ToolkitRelease.ps1 -Version 1.0.0 -WhatIf   # check first
   .\Tools\Publish-ToolkitRelease.ps1 -Version 1.0.0
   ```

   Turn on **release immutability** once for the repository (*Settings > General > Releases*), so the tag
   and the assets of a published release can't be changed or swapped later.

`Get-M365AdminToolkit.ps1` trusts only the certificate that signed it, so every release must be signed with
the same certificate. If you change certificates, users need the new `Get-M365AdminToolkit.ps1` once.

You need a code-signing certificate to sign. Use your organisation's internal PKI for internal use, or a
public CA or Azure Trusted Signing for public releases. Don't use a self-signed certificate: other PCs won't
trust it, and the build stops when a signature isn't `Valid`. Keep the certificate and its private key out of
the repository. The `.cmd` launchers can't carry a signature; the Start menu shortcut runs `Start-Toolkit.ps1`
directly.

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
  non-GET REST calls before they run, and reports them as blocked. Exchange Online's own REST calls for
  `Get-*` cmdlets (EXO v3 sends every classic cmdlet as a POST) are recognised as reads and let through. It can't see changes made by other
  processes or by .NET web clients. The GUI tells you when a module does something it can't guard.
- **Privacy.** The log file in `Logs\` records which module ran and *which* inputs were supplied, never the
  values. Personal preferences such as favourites and grouping are stored in
  `%APPDATA%\M365AdminToolkit\preferences.json`, not in the toolkit folder.

## Troubleshooting

| Problem | Fix |
|---|---|
| *Scripts are blocked* / *not digitally signed* | Run `Unblock-File` on the folder (see [Installation](#installation)) |
| Graph and Exchange together fail with an assembly or MSAL error | Known conflict between the two modules in Windows PowerShell 5.1. Connect to Exchange first, or run under PowerShell 7. Also check *Settings > Installed PowerShell modules* for Graph version mismatches |
| A module shows in red | Select it to see the problems, or run `.\Tools\Test-ToolkitModules.ps1` |
| A run finishes with 0 results and an error | Check the *Log* tab. The error is from the module script |
| Strange characters in output or errors | Save the script as ASCII or UTF-8 with BOM |
