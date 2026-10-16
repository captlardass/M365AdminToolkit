#Requires -Version 5.1
<#
    Toolkit.Core - UI-side engine for the Admin Toolkit.

    Responsibilities:
      * Discover and validate modules (module.json + entry script)
      * Build parameter forms from a module's manifest
      * Run work in the background worker runspace and collect its streams
      * Flatten results for the grid and CSV export

    Nothing in here talks to Microsoft 365 directly - that is the worker's job
    (see Toolkit.Worker.ps1). Keeping the two apart keeps the UI responsive and
    lets connections survive between module runs.
#>

$script:ParameterTypes = @('String', 'List', 'Bool', 'Choice', 'Int')
$script:ManifestFields = @('Id', 'Name', 'Category', 'Description', 'Version', 'EntryPoint')
$script:ReservedNames  = @('WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction', 'InformationAction')
# Tenant readiness: Pass at or above Pass %, Warn at or above Warn %, otherwise Fail. module.json "Readiness" overrides.
$script:ReadinessDefault = [pscustomobject]@{ Pass = 90; Warn = 70 }

# Script languages a module can be written in (module.json "Runtime", default PowerShell). This table is the
# one place to add a language. PowerShell runs in the worker under the change guard; every other runtime is
# an external process the guard can't see into, so those modules are always unguarded (see Test-TkManifest).
#   Candidates  - interpreters to try, in order: @{ Path; Arguments; Wsl; Label }. Settings "Runtimes.<Name>.Path" goes first.
#   ParamStyle  - Argv: --Name value (plus TK_PARAM_<NAME> env vars). Env: env vars only - cmd.exe would expand
#                 & | ^ % in arguments, so values never go on its command line.
#   Unix        - exported with LF line endings, no BOM and the executable bit.
$script:TkRuntimes = [ordered]@{
    PowerShell = @{ Extensions = '.ps1'; Language = 'PowerShell'; Unix = $false; ParamStyle = 'Splat'; Encoding = 'Utf8'; Candidates = @() }
    Cmd        = @{ Extensions = '.cmd', '.bat'; Language = 'Plain'; Unix = $false; ParamStyle = 'Env'; Encoding = 'Oem'
                    Candidates = @(@{ Path = '%SystemRoot%\System32\cmd.exe'; Arguments = '/d', '/c'; Label = 'cmd.exe' }) }
    Bash       = @{ Extensions = '.sh'; Language = 'Plain'; Unix = $true; ParamStyle = 'Argv'; Encoding = 'Utf8'
                    Candidates = @(@{ Path = '%SystemRoot%\System32\wsl.exe'; Arguments = '-e', 'bash'; Wsl = $true; Label = 'bash (WSL)' },
                                   @{ Path = '%ProgramFiles%\Git\bin\bash.exe'; Arguments = @(); Label = 'bash (Git for Windows)' }) }
    Zsh        = @{ Extensions = '.zsh'; Language = 'Plain'; Unix = $true; ParamStyle = 'Argv'; Encoding = 'Utf8'
                    Candidates = @(@{ Path = '%SystemRoot%\System32\wsl.exe'; Arguments = '-e', 'zsh'; Wsl = $true; Label = 'zsh (WSL)' }) }
    Python     = @{ Extensions = '.py'; Language = 'Plain'; Unix = $true; ParamStyle = 'Argv'; Encoding = 'Utf8'
                    Candidates = @(@{ Path = 'py.exe'; Arguments = , '-3'; Label = 'Python (py launcher)' },
                                   @{ Path = 'python.exe'; Arguments = @(); Label = 'Python' }) }
}
$script:RuntimeCache = @{}
$script:Platforms = @('Windows', 'Linux', 'macOS')

#region Runtimes

function Get-TkRuntimeName {
    <# The runtime names module.json may use, in table order. #>
    [string[]]@($script:TkRuntimes.Keys)
}

function Get-TkRuntimeDefinition {
    <# The table entry for a runtime (case-insensitive), or $null for an unknown name. #>
    param([string] $Name)
    if (-not $Name) { $Name = 'PowerShell' }
    foreach ($key in $script:TkRuntimes.Keys) {
        if ($key -eq $Name) { return [pscustomobject]($script:TkRuntimes[$key] + @{ Name = $key }) }
    }
    $null
}

function Get-TkRuntimeForFile {
    <# The runtime whose extension matches a script file, or $null. #>
    param([Parameter(Mandatory)] [string] $Path)
    $extension = [IO.Path]::GetExtension($Path)
    foreach ($key in $script:TkRuntimes.Keys) {
        if ($script:TkRuntimes[$key].Extensions -contains $extension) { return $key }
    }
    $null
}

function ConvertTo-TkScriptBytes {
    <# A script's bytes with the line endings its runtime needs: LF for Unix runtimes (bash fails on CRLF), with a
       UTF-8 BOM removed (it would hide the #! line); CRLF for cmd/PowerShell. Byte level, so a cmd file saved in
       the OEM code page keeps its characters. #>
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Runtime)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $unix = (Get-TkRuntimeDefinition $Runtime).Unix
    $start = if ($unix -and $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $out = New-Object System.IO.MemoryStream ($bytes.Length + 64)
    for ($i = $start; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -eq 13 -and $i + 1 -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { continue }    # CR of a CRLF
        if ($b -eq 10 -and -not $unix) { $out.WriteByte(13) }
        $out.WriteByte($b)
    }
    , $out.ToArray()
}

function Test-TkWslDistribution {
    <# Whether WSL has a Linux distribution for this user (read from the registry: wsl.exe itself may boot the VM). #>
    [bool]@(Get-ChildItem -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue).Count
}

function Resolve-TkInterpreterPath {
    <# Full path of an interpreter candidate, or $null. Skips the Microsoft Store "python.exe" placeholder,
       which opens the Store instead of running anything when Python isn't installed from it. #>
    param([Parameter(Mandatory)] [string] $Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) { if (Test-Path -LiteralPath $expanded -PathType Leaf) { return $expanded }; return $null }
    foreach ($command in @(Get-Command -Name $expanded -CommandType Application -ErrorAction SilentlyContinue)) {
        $source = $command.Source
        if ($source -like '*\Microsoft\WindowsApps\*') {
            $leaf = [IO.Path]::GetFileNameWithoutExtension($source)
            $store = @(Get-ChildItem -LiteralPath (Split-Path $source -Parent) -Directory -Filter 'PythonSoftwareFoundation.Python.*' -ErrorAction SilentlyContinue)
            if ($leaf -like 'python*' -and -not $store.Count) { continue }
        }
        return $source
    }
    $null
}

function Get-TkRuntimeStatus {
    <#
    .SYNOPSIS
        Finds the interpreter for a runtime: Available, Interpreter (full path), Arguments, Wsl, Label,
        ParamStyle, Encoding and Reason (why it isn't available). Cached; -Refresh looks again.
        $Settings.Runtimes.<Name>.Path (Config\settings.json) is tried first and, when set, is the only choice.
    #>
    param([Parameter(Mandatory)] [string] $Name, $Settings, [switch] $Refresh)
    $definition = Get-TkRuntimeDefinition $Name
    if (-not $definition) { throw "Unknown runtime '$Name'. Use one of: $((Get-TkRuntimeName) -join ', ')." }
    $key = $definition.Name
    $override = $null
    if ($Settings -and $Settings.PSObject.Properties['Runtimes'] -and $Settings.Runtimes -and $Settings.Runtimes.PSObject.Properties[$key]) {
        $override = $Settings.Runtimes.$key
    }
    # Keyed by the override too, so a lookup without settings never hides one with them.
    $cacheKey = "$key|$(if ($override) { "$($override.Path)|$(@($override.Arguments) -join ' ')" })"
    if (-not $Refresh -and $script:RuntimeCache.ContainsKey($cacheKey)) { return $script:RuntimeCache[$cacheKey] }

    $status = [pscustomobject]@{
        Name = $key; Available = $false; Interpreter = $null; Arguments = [string[]]@(); Wsl = $false
        Label = $key; ParamStyle = $definition.ParamStyle; Encoding = $definition.Encoding; Reason = ''
    }
    if ($key -eq 'PowerShell') {
        $status.Available = $true; $status.Label = 'PowerShell (in the toolkit)'
        $script:RuntimeCache[$cacheKey] = $status
        return $status
    }
    $candidates = if ($override -and $override.Path) {
        $path = [string]$override.Path
        , @{ Path = $path; Arguments = [string[]]@($override.Arguments | Where-Object { $_ }); Wsl = ((Split-Path $path -Leaf) -eq 'wsl.exe'); Label = "$key ($path)" }
    }
    else { $definition.Candidates }

    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        $found = Resolve-TkInterpreterPath $candidate.Path
        if (-not $found) { $reasons.Add("$($candidate.Label): not found"); continue }
        if ($candidate.Wsl -and -not (Test-TkWslDistribution)) { $reasons.Add("$($candidate.Label): WSL has no Linux distribution installed"); continue }
        $status.Available = $true
        $status.Interpreter = $found
        $status.Arguments = [string[]]@($candidate.Arguments)
        $status.Wsl = [bool]$candidate.Wsl
        $status.Label = $candidate.Label
        break
    }
    if (-not $status.Available) { $status.Reason = $reasons -join '; ' }
    $script:RuntimeCache[$cacheKey] = $status
    $status
}

#endregion

#region Discovery & validation

function Get-TkManifestParameter {
    param([Parameter(Mandatory)] $Manifest)
    if ($Manifest.PSObject.Properties['Parameters'] -and $Manifest.Parameters) { @($Manifest.Parameters) }
}

function ConvertTo-TkParameterDefinition {
    param([Parameter(Mandatory)] $Parameter)
    [pscustomobject]@{
        Name     = [string]$Parameter.Name
        Label    = if ($Parameter.Label) { [string]$Parameter.Label } else { [string]$Parameter.Name }
        Type     = if ($Parameter.Type) { [string]$Parameter.Type } else { 'String' }
        Required = [bool]$Parameter.Required
        Default  = $Parameter.Default
        Options  = @($Parameter.Options | Where-Object { $null -ne $_ })
        HelpText = [string]$Parameter.HelpText
    }
}

function Test-TkReadinessThreshold {
    <# Problems with a module.json "Readiness" block: { "Pass": 0-100, "Warn": 0-100 }, Warn <= Pass. #>
    param($Readiness)
    if ($Readiness -isnot [pscustomobject]) { return "'Readiness' must be an object such as { `"Pass`": 90, `"Warn`": 70 }." }
    $unknown = @($Readiness.PSObject.Properties.Name | Where-Object { 'Pass', 'Warn' -notcontains $_ })
    if ($unknown.Count) { "'Readiness' only takes Pass and Warn (found: $($unknown -join ', '))." }
    $ok = $true
    foreach ($key in 'Pass', 'Warn') {
        $value = $Readiness.$key
        $isNumber = $value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]
        if (-not $isNumber -or $value -lt 0 -or $value -gt 100) { "'Readiness.$key' must be a number from 0 to 100."; $ok = $false }
    }
    if ($ok -and $Readiness.Warn -gt $Readiness.Pass) { "'Readiness.Warn' can't be higher than 'Readiness.Pass'." }
}

function Get-TkReadiness {
    <#
    .SYNOPSIS
        Turns a module's readiness report (Write-TkReadiness) into what the GUI shows:
        Ready, Total, NotEvaluated, Label, Percent (rounded down) and Rating (Pass, Warn or Fail).
        Returns $null when the report is not a usable figure, so nothing is shown rather than a wrong score.
    #>
    param($Report, $Threshold)
    if (-not $Report) { return }
    if (-not $Threshold) { $Threshold = $script:ReadinessDefault }
    $ready = $Report.Ready -as [int]
    $total = $Report.Total -as [int]
    $notEvaluated = if ($null -eq $Report.NotEvaluated) { 0 } else { $Report.NotEvaluated -as [int] }
    $label = [string]$Report.Label
    if ($null -eq $ready -or $null -eq $total -or $null -eq $notEvaluated -or [string]::IsNullOrWhiteSpace($label)) { return }
    if ($total -le 0 -or $ready -lt 0 -or $ready -gt $total -or $notEvaluated -lt 0) { return }
    if (Test-TkReadinessThreshold $Threshold) { return }

    # Rate on the exact share, display it rounded down: 89.9 % is never shown or rated as 90 %.
    $share = 100.0 * $ready / $total
    $rating = if ($share -ge $Threshold.Pass) { 'Pass' } elseif ($share -ge $Threshold.Warn) { 'Warn' } else { 'Fail' }
    [pscustomobject]@{
        Ready        = $ready
        Total        = $total
        NotEvaluated = $notEvaluated
        Label        = $label.Trim()
        Percent      = [int][math]::Floor($share)
        Rating       = $rating
        Pass         = $Threshold.Pass
        Warn         = $Threshold.Warn
    }
}

function Test-TkManifest {
    <#
    .SYNOPSIS
        Validates a parsed module.json (and its entry script) against the toolkit contract.
        Returns the list of problems - an empty result means the module is valid.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] [string] $ModuleDirectory
    )

    $problems = New-Object System.Collections.Generic.List[string]

    foreach ($field in $script:ManifestFields) {
        if ([string]::IsNullOrWhiteSpace([string]$Manifest.$field)) {
            $problems.Add("Missing required field '$field'.")
        }
    }
    if ($Manifest.Id -and $Manifest.Id -notmatch '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$') {
        $problems.Add("Id '$($Manifest.Id)' must use the form 'Area.TaskName'.")
    }
    $parsedVersion = $null
    if ($Manifest.Version -and -not [version]::TryParse([string]$Manifest.Version, [ref]$parsedVersion)) {
        $problems.Add("Version '$($Manifest.Version)' is not a valid version number.")
    }

    foreach ($flag in 'SupportsWhatIf', 'ReadOnly') {
        if ($Manifest.PSObject.Properties[$flag] -and $null -ne $Manifest.$flag -and $Manifest.$flag -isnot [bool]) {
            $problems.Add("'$flag' must be true or false.")
        }
    }

    if ($Manifest.PSObject.Properties['Tags'] -and $null -ne $Manifest.Tags) {
        foreach ($tag in @($Manifest.Tags)) {
            if ($tag -isnot [string] -or [string]::IsNullOrWhiteSpace($tag) -or $tag.Contains(',') -or $tag.Length -gt 40) {
                $problems.Add('Tags must be a list of short, non-empty strings without commas.')
                break
            }
        }
    }

    if ($Manifest.PSObject.Properties['Readiness'] -and $null -ne $Manifest.Readiness) {
        foreach ($problem in Test-TkReadinessThreshold $Manifest.Readiness) { $problems.Add($problem) }
    }

    $runtimeName = if ($Manifest.PSObject.Properties['Runtime'] -and $Manifest.Runtime) { [string]$Manifest.Runtime } else { 'PowerShell' }
    $runtime = Get-TkRuntimeDefinition $runtimeName
    $external = $runtime -and $runtime.Name -ne 'PowerShell'
    if (-not $runtime) { $problems.Add("Runtime '$runtimeName' is unknown. Use one of: $((Get-TkRuntimeName) -join ', ').") }
    elseif ($Manifest.EntryPoint -and $runtime.Extensions -notcontains [IO.Path]::GetExtension([string]$Manifest.EntryPoint)) {
        $problems.Add("A $($runtime.Name) entry point must end in $($runtime.Extensions -join ' or ') (found '$($Manifest.EntryPoint)').")
    }
    if ($Manifest.PSObject.Properties['Platforms'] -and $null -ne $Manifest.Platforms) {
        $badPlatform = @(@($Manifest.Platforms) | Where-Object { $script:Platforms -notcontains $_ })
        if ($badPlatform.Count) { $problems.Add("Platforms may only list $($script:Platforms -join ', ') (found: $($badPlatform -join ', ')).") }
    }
    $dryRunArgument = if ($Manifest.PSObject.Properties['DryRunArgument']) { [string]$Manifest.DryRunArgument } else { '' }
    if ($external) {
        # The change guard can't see inside another process: never promise what it can't enforce (fail closed).
        if ($Manifest.ReadOnly -eq $true) {
            $problems.Add("ReadOnly can't be enforced for a $($runtime.Name) script: the change guard only sees PowerShell. Remove it (the module then always asks before it runs).")
        }
        $requires = $Manifest.Requires
        if ($requires -and ($requires.ExchangeOnline -eq $true -or @($requires.GraphScopes | Where-Object { $_ }).Count)) {
            $problems.Add("A $($runtime.Name) script can't use the toolkit's Graph or Exchange Online sign-in: remove Requires, or write the module in PowerShell.")
        }
        if ($Manifest.SupportsWhatIf -eq $true -and -not $dryRunArgument) {
            $problems.Add("SupportsWhatIf needs DryRunArgument for a $($runtime.Name) script: the switch the script takes for a dry run, e.g. --dry-run.")
        }
        if ($dryRunArgument -and $Manifest.SupportsWhatIf -ne $true) { $problems.Add('DryRunArgument needs "SupportsWhatIf": true.') }
        # Passed on the command line (cmd: appended after the script), so only a plain switch is allowed.
        if ($dryRunArgument -and $dryRunArgument -notmatch '^(--?|/)[A-Za-z][A-Za-z0-9-]*$') {
            $problems.Add("DryRunArgument '$dryRunArgument' must be a plain switch such as --dry-run, -n or /dryrun.")
        }
    }
    elseif ($dryRunArgument) { $problems.Add('DryRunArgument is only for non-PowerShell scripts; PowerShell scripts use SupportsShouldProcess.') }

    $declared = @(Get-TkManifestParameter $Manifest | ForEach-Object { ConvertTo-TkParameterDefinition $_ })
    $seen = @{}
    foreach ($p in $declared) {
        if ([string]::IsNullOrWhiteSpace($p.Name)) { $problems.Add('A parameter is missing its Name.'); continue }
        if ($seen.ContainsKey($p.Name)) { $problems.Add("Parameter '$($p.Name)' is declared more than once.") }
        $seen[$p.Name] = $true
        if ($script:ReservedNames -contains $p.Name) {
            $problems.Add("Parameter name '$($p.Name)' is reserved by the toolkit.")
        }
        if ($script:ParameterTypes -notcontains $p.Type) {
            $problems.Add("Parameter '$($p.Name)' has unknown Type '$($p.Type)'. Use one of: $($script:ParameterTypes -join ', ').")
        }
        if ($p.Type -eq 'Choice' -and $p.Options.Count -eq 0) {
            $problems.Add("Choice parameter '$($p.Name)' needs a non-empty Options list.")
        }
        # Becomes --Name and the environment variable TK_PARAM_<NAME>.
        if ($external -and $p.Name -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            $problems.Add("Parameter '$($p.Name)' may only use letters, digits and _ in a $($runtime.Name) module.")
        }
    }

    if (-not $Manifest.EntryPoint) { return $problems.ToArray() }
    $entryPath = Join-Path $ModuleDirectory $Manifest.EntryPoint
    if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        $problems.Add("Entry point '$($Manifest.EntryPoint)' was not found.")
        return $problems.ToArray()
    }
    # Other languages have no param() block to compare: module.json is the only description of the inputs.
    if ($external -or -not $runtime) { return $problems.ToArray() }

    # Parse (never execute) the entry script so manifest and param() block can't drift apart.
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$tokens, [ref]$parseErrors)
    foreach ($e in $parseErrors) {
        $problems.Add("Syntax error at line $($e.Extent.StartLineNumber): $($e.Message)")
    }

    $scriptParams = @()
    $supportsShouldProcess = $false
    if ($ast.ParamBlock) {
        $scriptParams = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

        $binding = $ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        if ($binding -and ($binding.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' })) {
            $supportsShouldProcess = $true
        }

        # A mandatory script parameter the GUI doesn't know about would make the run prompt (and hang).
        foreach ($sp in $ast.ParamBlock.Parameters) {
            $name = $sp.Name.VariablePath.UserPath
            $mandatory = $sp.Attributes | Where-Object {
                $_.TypeName.Name -eq 'Parameter' -and ($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' })
            }
            $definition = $declared | Where-Object { $_.Name -eq $name }
            if ($mandatory -and -not ($definition -and $definition.Required)) {
                $problems.Add("Script parameter '$name' is Mandatory, so module.json must declare it with Required: true.")
            }
        }
    }

    foreach ($p in $declared) {
        if ($p.Name -and $scriptParams -notcontains $p.Name) {
            $problems.Add("Parameter '$($p.Name)' is in module.json but missing from the script's param() block.")
        }
    }
    if ($Manifest.SupportsWhatIf -and -not $supportsShouldProcess) {
        $problems.Add("SupportsWhatIf is true, but the script lacks [CmdletBinding(SupportsShouldProcess)].")
    }

    $problems.ToArray()
}

function Get-TkModule {
    <#
    .SYNOPSIS
        Discovers every module folder under -Path. Folders starting with '_' (e.g. _Template) are skipped.
        Invalid modules are still returned (IsValid = $false) so the GUI can explain what is wrong.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $modules = foreach ($dir in Get-ChildItem -LiteralPath $Path -Directory | Where-Object { $_.Name -notlike '_*' }) {
        $manifestPath = Join-Path $dir.FullName 'module.json'
        $manifest = $null
        $problems = @()

        if (-not (Test-Path -LiteralPath $manifestPath)) {
            $problems = @('module.json not found.')
        }
        else {
            try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { $problems = @("module.json is not valid JSON: $($_.Exception.Message)") }
        }
        if ($manifest) { $problems = @(Test-TkManifest -Manifest $manifest -ModuleDirectory $dir.FullName) }

        $requires = if ($manifest) { $manifest.Requires } else { $null }
        $supportsWhatIf = [bool]($manifest -and $manifest.SupportsWhatIf -eq $true)
        $entryPath = if ($manifest -and $manifest.EntryPoint) { Join-Path $dir.FullName $manifest.EntryPoint } else { $null }
        $runtimeName = if ($manifest -and $manifest.PSObject.Properties['Runtime'] -and $manifest.Runtime) { [string]$manifest.Runtime } else { 'PowerShell' }
        $runtime = Get-TkRuntimeDefinition $runtimeName
        if ($runtime) { $runtimeName = $runtime.Name }
        $dryRun = $null
        if ($problems.Count -eq 0) {
            try { $dryRun = Get-TkDryRunProfile -Path $entryPath -SupportsWhatIf $supportsWhatIf -Runtime $runtimeName }
            catch { $problems = @("Could not analyse the script: $($_.Exception.Message)") }
        }
        [pscustomobject]@{
            Id             = if ($manifest -and $manifest.Id) { [string]$manifest.Id } else { $dir.Name }
            Name           = if ($manifest -and $manifest.Name) { [string]$manifest.Name } else { $dir.Name }
            Category       = if ($manifest -and $manifest.Category) { [string]$manifest.Category } else { 'Uncategorised' }
            Tags           = [string[]]@(if ($manifest) { Split-TkList $manifest.Tags })
            Description    = if ($manifest) { [string]$manifest.Description } else { '' }
            Version        = if ($manifest) { [string]$manifest.Version } else { '' }
            Author         = if ($manifest) { [string]$manifest.Author } else { '' }
            Requires       = [pscustomobject]@{
                ExchangeOnline = [bool]($requires -and $requires.ExchangeOnline)
                GraphScopes    = [string[]]@(if ($requires -and $requires.GraphScopes) { $requires.GraphScopes })
            }
            SupportsWhatIf = $supportsWhatIf
            ReadOnly       = [bool]($manifest -and $manifest.ReadOnly -eq $true)
            Runtime        = $runtimeName
            External       = $runtimeName -ne 'PowerShell'
            DryRunArgument = if ($manifest -and $manifest.PSObject.Properties['DryRunArgument']) { [string]$manifest.DryRunArgument } else { '' }
            Platforms      = [string[]]@(if ($manifest -and $manifest.PSObject.Properties['Platforms']) { $manifest.Platforms | Where-Object { $_ } })
            Readiness      = if ($manifest -and $manifest.Readiness -and $problems.Count -eq 0) {
                                 [pscustomobject]@{ Pass = $manifest.Readiness.Pass; Warn = $manifest.Readiness.Warn }
                             } else { $script:ReadinessDefault }
            DryRun         = $dryRun
            Parameters     = @(if ($manifest) { Get-TkManifestParameter $manifest | ForEach-Object { ConvertTo-TkParameterDefinition $_ } })
            EntryPath      = $entryPath
            ManifestPath   = $manifestPath
            Directory      = $dir.FullName
            IsValid        = $problems.Count -eq 0
            Errors         = $problems
        }
    }

    # Ids must be unique across the whole toolkit.
    foreach ($dupe in @($modules) | Group-Object Id | Where-Object Count -gt 1) {
        foreach ($m in $dupe.Group) {
            $m.IsValid = $false
            $m.Errors += "Id '$($m.Id)' is used by more than one module folder."
        }
    }
    $modules
}

function Get-TkDryRunProfile {
    <#
    .SYNOPSIS
        Describes how a dry run works for a script (Native = its own ShouldProcess/WhatIf,
        Enforced = the toolkit's change guard, External = another language: nothing is guarded, a dry
        run only exists when the script takes DryRunArgument) and lists what the guard cannot cover.
        Static analysis only - the script is never run.
    #>
    param([Parameter(Mandatory)] [string] $Path, [bool] $SupportsWhatIf, [string] $Runtime = 'PowerShell')

    if ($Runtime -and $Runtime -ne 'PowerShell') {
        $caveats = @("Runs outside PowerShell ($Runtime), so nothing is guarded: it runs with your rights and can change anything you can.")
        if ($SupportsWhatIf) { $caveats += 'The dry run is the script''s own: the toolkit only passes its dry-run switch and can''t check what it does.' }
        return [pscustomobject]@{ Mode = 'External'; Caveats = [string[]]$caveats }
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    $text = [System.IO.File]::ReadAllText($Path)
    $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)

    $caveats = New-Object System.Collections.Generic.List[string]
    $spawners = 'Start-Process', 'saps', 'start', 'Start-Job', 'sajb', 'Start-ThreadJob', 'Invoke-Command', 'icm',
        'powershell', 'powershell.exe', 'pwsh', 'pwsh.exe', 'cmd', 'cmd.exe', 'az', 'az.cmd', 'm365', 'azcopy', 'curl.exe', 'wget.exe'
    $spawn = @($names | Where-Object { $spawners -contains $_ })
    if ($spawn) {
        $caveats.Add("Starts other processes or remote sessions ($($spawn -join ', ')); what they do is outside the dry run.")
    }
    if ($text -match '(?i)\b(Net\.WebClient|Net\.Http\.|HttpClient|HttpWebRequest|Net\.WebRequest)\b') {
        $caveats.Add('Makes web calls through .NET classes, which the dry run cannot intercept.')
    }
    $localChanges = 'Remove-Item', 'rm', 'del', 'Move-Item', 'Rename-Item', 'Clear-Content', 'Set-ItemProperty', 'New-ItemProperty',
        'Remove-ItemProperty', 'Stop-Process', 'kill', 'Stop-Service', 'Set-Service', 'Restart-Service', 'Restart-Computer', 'Stop-Computer'
    $local = @($names | Where-Object { $localChanges -contains $_ })
    if ($local) {
        $caveats.Add("Changes things on this computer ($($local -join ', ')); the dry run only blocks Microsoft 365 changes.")
    }
    if ($names -contains 'Get-Command' -or $names -contains 'gcm') {
        $caveats.Add('Uses Get-Command; commands invoked through its result bypass the dry-run guard.')
    }

    [pscustomobject]@{
        Mode    = if ($SupportsWhatIf) { 'Native' } else { 'Enforced' }
        Caveats = $caveats.ToArray()
    }
}

#endregion

#region Script viewer helpers

function Get-TkTokenKind {
    param($Token)
    $kind = [string]$Token.Kind
    $flags = $Token.TokenFlags
    if ($kind -eq 'Comment') { return 'Comment' }
    if ('StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable' -contains $kind) { return 'String' }
    if ('Variable', 'SplattedVariable' -contains $kind) { return 'Variable' }
    if ($kind -eq 'Parameter') { return 'Parameter' }
    if ($kind -eq 'Number') { return 'Number' }
    if ($flags -band [System.Management.Automation.Language.TokenFlags]::Keyword) { return 'Keyword' }
    if ($flags -band [System.Management.Automation.Language.TokenFlags]::CommandName) { return 'Command' }
    if ($flags -band ([System.Management.Automation.Language.TokenFlags]::TypeName -bor [System.Management.Automation.Language.TokenFlags]::AttributeName)) { return 'Type' }
    $null
}

function ConvertTo-TkCodeLine {
    <#
    .SYNOPSIS
        Splits source text into numbered lines of coloured parts for the script viewer.
        PowerShell is tokenised (never executed); multi-line tokens such as here-strings and
        block comments are split across the lines they span. Returns one object per line:
        Number, Text, Parts (array of @(Kind, Text) pairs; Kind is $null for plain text).
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [ValidateSet('PowerShell', 'Plain')] [string] $Language = 'PowerShell'
    )

    $Text = $Text -replace "`t", '    '
    # Parallel typed lists instead of objects: this loop runs once per token and must stay fast.
    $segStart = New-Object System.Collections.Generic.List[int]
    $segEnd = New-Object System.Collections.Generic.List[int]
    $segKind = New-Object System.Collections.Generic.List[string]
    if ($Language -eq 'PowerShell' -and $Text.Length -le 2MB) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
        foreach ($t in $tokens) {
            $kind = Get-TkTokenKind $t
            $extent = $t.Extent
            if ($kind -and $extent.EndOffset -gt $extent.StartOffset) {
                $segStart.Add($extent.StartOffset)
                $segEnd.Add($extent.EndOffset)
                $segKind.Add($kind)
            }
        }
    }
    $segCount = $segStart.Count

    $lineStart = New-Object System.Collections.Generic.List[int]
    $lineEnd = New-Object System.Collections.Generic.List[int]
    $pos = 0
    foreach ($m in [regex]::Matches($Text, "\r\n|\n|\r")) {
        $lineStart.Add($pos)
        $lineEnd.Add($m.Index)
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $Text.Length -or $lineStart.Count -eq 0) { $lineStart.Add($pos); $lineEnd.Add($Text.Length) }

    $segIndex = 0
    for ($n = 0; $n -lt $lineStart.Count; $n++) {
        $start = $lineStart[$n]
        $end = $lineEnd[$n]
        $parts = New-Object System.Collections.Generic.List[object]
        $cursor = $start
        while ($segIndex -lt $segCount -and $segEnd[$segIndex] -le $start) { $segIndex++ }
        $i = $segIndex
        while ($i -lt $segCount -and $segStart[$i] -lt $end) {
            $from = [Math]::Max($segStart[$i], $start)
            $to = [Math]::Min($segEnd[$i], $end)
            if ($from -gt $cursor) { $parts.Add(@($null, $Text.Substring($cursor, $from - $cursor))) }
            if ($to -gt $from) { $parts.Add(@($segKind[$i], $Text.Substring($from, $to - $from))) }
            if ($to -gt $cursor) { $cursor = $to }
            if ($segEnd[$i] -le $end) { $i++ } else { break }     # token continues on the next line
        }
        $segIndex = $i
        if ($cursor -lt $end) { $parts.Add(@($null, $Text.Substring($cursor, $end - $cursor))) }
        # Parts are @(Kind, Text) pairs; Kind is $null for plain text.
        [pscustomobject]@{ Number = $n + 1; Text = $Text.Substring($start, $end - $start); Parts = $parts.ToArray() }
    }
}

function Get-TkFileSummary {
    <# Size, line count, last change and SHA-256 - lets an admin confirm exactly which script they reviewed. #>
    param([Parameter(Mandatory)] [string] $Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $text = [System.IO.File]::ReadAllText($item.FullName)
    [pscustomobject]@{
        Path     = $item.FullName
        Text     = $text
        Lines    = @([regex]::Matches($text, "\r\n|\n|\r")).Count + $(if ($text -and $text -notmatch '(\r\n|\n|\r)$') { 1 } else { 0 })
        SizeKB   = [Math]::Round($item.Length / 1KB, 1)
        Modified = $item.LastWriteTime
        Sha256   = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }
}

#endregion

#region Adding modules & tags

function Split-TkList {
    <#
    .SYNOPSIS
        Normalises a list given as array and/or delimited string: trims, drops empties and
        removes case-insensitive duplicates while keeping the original order.
    #>
    param($InputObject, [string] $Separator = ',')
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $InputObject) {      # not @(): that throws for List[object] in PS 5.1
        foreach ($part in ([string]$item -split $Separator)) {
            $value = $part.Trim()
            if ($value -and $seen.Add($value)) { $value }
        }
    }
}

function ConvertTo-TkLabel {
    <# 'AllUserMailboxes' -> 'All user mailboxes', 'Set-CalendarPermission' -> 'Set calendar permission', keeps acronyms. #>
    param([string] $Name)
    $spaced = [regex]::Replace($Name, '(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', ' ') -replace '[_\-\.]+', ' '
    $words = @($spaced -split '\s+' | Where-Object { $_ })
    if (-not $words) { return $Name }
    $out = for ($i = 0; $i -lt $words.Count; $i++) {
        $w = $words[$i]
        if ($w -cmatch '^[A-Z0-9]{2,}$') { $w }
        elseif ($i -eq 0) { $w.Substring(0, 1).ToUpper() + $w.Substring(1).ToLower() }
        else { $w.ToLower() }
    }
    $out -join ' '
}

function Get-TkSuggestedId {
    <# 'Exchange Online' + 'Room settings' -> 'ExchangeOnline.RoomSettings' #>
    param([string] $Category, [string] $Name)
    $pascal = {
        param($text)
        $joined = (@([string]$text -split '[^A-Za-z0-9]+' | Where-Object { $_ } |
            ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '')
        if ($joined -match '^[0-9]') { "M$joined" } else { $joined }
    }
    $area = & $pascal $Category
    $task = & $pascal $Name
    if ($area -and $task) { "$area.$task" } else { '' }
}

function Get-TkAstValue {
    param($Ast)
    if ($null -eq $Ast) { return $null }
    # SafeGetValue only evaluates constants/literals; anything computed throws and we treat as unknown.
    try { $Ast.SafeGetValue() } catch { $null }
}

function Get-TkExternalScriptAnalysis {
    <#
    .SYNOPSIS
        Reads a cmd, bash, zsh or Python script without running it. There is no param() block, so inputs
        come from optional header comments (# for bash/zsh/Python, REM or :: for cmd):
            # tk-description: Lists the largest folders under a path
            # tk-param: Path | String | Required | Folder to scan
            # tk-param: Top | Int | | How many folders to list
            # tk-dryrun: --dry-run
            # tk-platforms: Linux, macOS
        Types: String, Int, Bool, List, or Choice(a/b/c). Warns about what misbehaves in the toolkit.
    #>
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Runtime)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $definition = Get-TkRuntimeDefinition $Runtime
    $text = [System.IO.File]::ReadAllText($resolved)
    $lines = $text -split '\r?\n'
    $warnings = New-Object System.Collections.Generic.List[string]
    $parameters = New-Object System.Collections.Generic.List[object]
    $description = ''
    $dryRunArgument = ''
    $platforms = @()
    $comment = if ($definition.Name -eq 'Cmd') { '^\s*(@?rem\b|::)\s*' } else { '^\s*#\s*' }

    foreach ($line in $lines) {
        if ($line -notmatch ($comment + 'tk-(?<key>param|description|dryrun|platforms)\s*:\s*(?<value>.*?)\s*$')) { continue }
        $value = $Matches['value']
        switch ($Matches['key']) {
            'description' { $description = $value }
            'dryrun' { $dryRunArgument = $value }
            'platforms' { $platforms = @(Split-TkList $value) }
            'param' {
                $parts = @($value -split '\|' | ForEach-Object { $_.Trim() })
                $name = $parts[0]
                if ($name -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { $warnings.Add("tk-param '$name' was skipped: names may only use letters, digits and _."); continue }
                $type = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { 'String' }
                $options = @()
                if ($type -match '^Choice\((?<o>.*)\)$') { $options = @(Split-TkList $Matches['o'] -Separator '/'); $type = 'Choice' }
                if ($script:ParameterTypes -notcontains $type) { $warnings.Add("tk-param '$name' has unknown type '$type'; it is a text box."); $type = 'String' }
                $parameters.Add([pscustomobject]@{
                    Name     = $name
                    Label    = ConvertTo-TkLabel $name
                    Type     = $type
                    Required = $parts.Count -gt 2 -and $parts[2] -match '^(Required|Mandatory|yes|true)$'
                    Default  = $null
                    Options  = $options
                    HelpText = if ($parts.Count -gt 3) { ($parts[3..($parts.Count - 1)] -join ' | ') } else { '' }
                })
            }
        }
    }

    if ($definition.Unix -and $definition.Name -ne 'Python' -and $lines[0] -notmatch '^#!') {
        $warnings.Add("No #! line at the top: add e.g. '#!/usr/bin/env $($definition.Name.ToLowerInvariant())' so it also runs on its own after export.")
    }
    if ($definition.Unix -and $text.Contains("`r`n")) { $warnings.Add('Has Windows (CRLF) line endings: they are converted to LF when the module is created.') }
    $prompts = switch ($definition.Name) {
        'Cmd' { '(?im)^\s*(pause\b|set\s+/p\b|choice\b)' }
        'Python' { '\binput\s*\(|getpass\.' }
        default { '(?m)(^\s*|[;&|]\s*)read\b|\bselect\s+\w+\s+in\b' }
    }
    if ($text -match $prompts) { $warnings.Add('Asks for input while running (e.g. read / input() / pause). There is no console: it gets end-of-file. Turn the prompts into tk-param inputs.') }
    if ($definition.Name -ne 'Cmd' -and $text -match '(?m)(^\s*|[;&|]\s*)sudo\b') { $warnings.Add('Uses sudo, which waits for a password the toolkit cannot type. Run it on the target machine after export, or allow the command without a password.') }
    if ($dryRunArgument -and $dryRunArgument -notmatch '^(--?|/)[A-Za-z][A-Za-z0-9-]*$') {
        $warnings.Add("tk-dryrun '$dryRunArgument' is not a plain switch such as --dry-run, so it was ignored.")
        $dryRunArgument = ''
    }
    $badPlatforms = @($platforms | Where-Object { $script:Platforms -notcontains $_ })
    if ($badPlatforms.Count) { $warnings.Add("Unknown platform(s) ignored: $($badPlatforms -join ', '). Use $($script:Platforms -join ', ')."); $platforms = @($platforms | Where-Object { $script:Platforms -contains $_ }) }
    $warnings.Add("Not PowerShell: the toolkit can't guard what it does, so every run asks first. It can't be read-only or use the toolkit's Microsoft 365 sign-in.")

    [pscustomobject]@{
        Path                 = $resolved
        Runtime              = $definition.Name
        Parameters           = $parameters.ToArray()
        SupportsWhatIf       = [bool]$dryRunArgument
        DryRunArgument       = $dryRunArgument
        Platforms            = [string[]]$platforms
        SuggestedName        = ConvertTo-TkLabel ([System.IO.Path]::GetFileNameWithoutExtension($resolved))
        SuggestedDescription = $description
        UsesExchange         = $false
        UsesGraph            = $false
        GraphScopes          = [string[]]@()
        LooksReadOnly        = $false
        Warnings             = $warnings.ToArray()
    }
}

function Get-TkScriptAnalysis {
    <#
    .SYNOPSIS
        Reads a .ps1 without running it and works out what a module manifest for it should say:
        GUI inputs from the param() block, WhatIf support, likely connections and Graph scopes,
        plus warnings about things that would misbehave inside the toolkit.
        Scripts in another language (.cmd, .bat, .sh, .zsh, .py) go to Get-TkExternalScriptAnalysis.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $runtime = Get-TkRuntimeForFile $Path
    if (-not $runtime) { throw "Unsupported script type '$([IO.Path]::GetExtension($Path))'. Use .ps1, .cmd, .bat, .sh, .zsh or .py." }
    if ($runtime -ne 'PowerShell') { return Get-TkExternalScriptAnalysis -Path $Path -Runtime $runtime }

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) {
        $first = @($parseErrors | Select-Object -First 3 | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" })
        throw "The script has syntax errors - $($first -join '; ')"
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    $parameters = New-Object System.Collections.Generic.List[object]
    $help = $ast.GetHelpContent()
    $supportsWhatIf = $false

    if ($ast.ParamBlock) {
        $binding = $ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        if ($binding -and ($binding.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' })) {
            $supportsWhatIf = $true
        }

        foreach ($p in $ast.ParamBlock.Parameters) {
            $name = $p.Name.VariablePath.UserPath
            if ($script:ReservedNames -contains $name) {
                $warnings.Add("Parameter '$name' is reserved by the toolkit and was left out of the form.")
                continue
            }

            $attributes = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] })
            $paramAttr = $attributes | Where-Object { $_.TypeName.Name -in 'Parameter', 'ParameterAttribute' } | Select-Object -First 1
            $validateSet = $attributes | Where-Object { $_.TypeName.Name -in 'ValidateSet', 'ValidateSetAttribute' } | Select-Object -First 1

            $mandatory = $false
            $helpText = ''
            if ($paramAttr) {
                foreach ($arg in $paramAttr.NamedArguments) {
                    if ($arg.ArgumentName -eq 'Mandatory') {
                        $mandatory = if ($arg.ExpressionOmitted) { $true } else { [bool](Get-TkAstValue $arg.Argument) }
                    }
                    if ($arg.ArgumentName -eq 'HelpMessage') { $helpText = [string](Get-TkAstValue $arg.Argument) }
                }
            }
            if (-not $helpText -and $help -and $help.Parameters) {
                $key = @($help.Parameters.Keys | Where-Object { $_ -eq $name }) | Select-Object -First 1
                if ($key) { $helpText = ($help.Parameters[$key] -replace '\s+', ' ').Trim() }
            }

            $type = $p.StaticType
            $guiType = 'String'
            $options = @()
            if ($validateSet) {
                $guiType = 'Choice'
                $options = @($validateSet.PositionalArguments | ForEach-Object { [string](Get-TkAstValue $_) } | Where-Object { $_ })
                if ($type.IsArray) { $warnings.Add("'$name' accepts several values from a set; the GUI lets you pick one.") }
            }
            elseif ($type -eq [switch] -or $type -eq [bool]) { $guiType = 'Bool' }
            elseif (@([int], [long], [int16], [byte], [uint16], [uint32]) -contains $type) { $guiType = 'Int' }
            elseif ($type.IsArray) { $guiType = 'List' }
            elseif ($type -ne [string] -and $type -ne [object]) {
                $warnings.Add("'$name' is of type [$($type.Name)]; the GUI passes it as text and PowerShell will try to convert it.")
            }

            $default = if ($p.DefaultValue) { Get-TkAstValue $p.DefaultValue } else { $null }
            if ($guiType -eq 'Choice' -and $null -ne $default -and $options -notcontains [string]$default) { $default = $null }
            if ($guiType -eq 'Bool' -and $null -ne $default) { $default = [bool]$default }

            $parameters.Add([pscustomobject]@{
                Name     = $name
                Label    = ConvertTo-TkLabel $name
                Type     = $guiType
                Required = $mandatory
                Default  = $default
                Options  = $options
                HelpText = $helpText
            })
        }
    }

    $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $names = @($commands | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })

    $exchangeNouns = 'EXO|Mailbox|CASMailbox|DistributionGroup|UnifiedGroup|CalendarProcessing|TransportRule|MailContact|MailUser|Recipient|InboxRule|OrganizationConfig|AcceptedDomain|MessageTrace'
    $usesExchange = [bool]@($names | Where-Object { $_ -eq 'Connect-ExchangeOnline' -or $_ -match "^\w+-($exchangeNouns)" }).Count
    $usesGraph = [bool]@($names | Where-Object { $_ -match '^\w+-Mg' }).Count

    # Pick up literal scopes from Connect-MgGraph -Scopes 'a','b' so the user doesn't have to.
    $scopes = New-Object System.Collections.Generic.List[string]
    foreach ($cmd in $commands | Where-Object { $_.GetCommandName() -eq 'Connect-MgGraph' }) {
        $elements = $cmd.CommandElements
        for ($i = 1; $i -lt $elements.Count; $i++) {
            $el = $elements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -like 'Scope*') {
                $valueAst = if ($el.Argument) { $el.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }
                foreach ($scope in Split-TkList @(Get-TkAstValue $valueAst) -Separator '[,\s]+') {
                    if (-not $scopes.Contains($scope)) { $scopes.Add($scope) }
                }
            }
        }
    }
    # Scripts written for the toolkit don't connect themselves, so they declare scopes in a comment:
    #   # GraphScopes: User.Read.All, RoleManagement.Read.Directory
    foreach ($token in $tokens | Where-Object { $_.Kind -eq 'Comment' }) {
        foreach ($line in $token.Text -split '\r?\n') {
            if ($line -notmatch '^\s*(<#|#)?\s*GraphScopes\s*:\s*(?<list>.+?)\s*(#>)?\s*$') { continue }
            foreach ($scope in Split-TkList @($Matches['list']) -Separator '[,\s]+') {
                if (-not $scopes.Contains($scope)) { $scopes.Add($scope) }
            }
        }
    }

    $connects = @($names | Where-Object { $_ -in 'Connect-MgGraph', 'Connect-ExchangeOnline', 'Connect-IPPSSession' } | Sort-Object -Unique)
    if ($connects) {
        $warnings.Add("The script calls $($connects -join ', ') itself. The toolkit signs in before running, so those lines can go.")
    }
    $disconnects = @($names | Where-Object { $_ -match '^Disconnect-(MgGraph|ExchangeOnline)$' } | Sort-Object -Unique)
    if ($disconnects) {
        $warnings.Add("The script calls $($disconnects -join ', '), which signs the toolkit out for every module. Remove it.")
    }
    $legacy = @($names | Where-Object { $_ -match '^\w+-(AzureAD|Msol)' } | Sort-Object -Unique)
    if ($legacy) {
        $warnings.Add("Uses the retired AzureAD/MSOnline modules ($($legacy[0])...). Port these calls to Microsoft Graph.")
    }
    $interactive = @($names | Where-Object { $_ -in 'Read-Host', 'Get-Credential', 'Out-GridView', 'Pause' } | Sort-Object -Unique)
    if ($interactive) {
        $warnings.Add("Uses $($interactive -join ', '), which needs a console and will hang or fail. Turn those prompts into parameters.")
    }
    if ($usesGraph -and -not $scopes.Count) {
        $warnings.Add("Uses Microsoft Graph, but no scopes could be detected. Enter the scopes it needs below, or add a '# GraphScopes: User.Read.All, ...' line to the script.")
    }
    $harmless = 'Start-Sleep', 'New-Object', 'Add-Member', 'Add-Type', 'Set-StrictMode', 'Set-Variable', 'New-Variable',
        'Remove-Variable', 'Clear-Variable', 'New-TimeSpan', 'Set-Location', 'Clear-Host', 'Add-Content', 'Set-Content',
        'New-Item', 'Start-Transcript', 'Stop-Transcript', 'New-Guid', 'Set-Alias', 'New-Alias', 'Update-TypeData', 'Update-FormatData'
    $changing = @($names | Where-Object { $_ -match '^(Set|New|Remove|Add|Update|Grant|Revoke|Enable|Disable|Clear|Reset|Move|Send|Start|Stop|Restore|Invoke)-' -and $harmless -notcontains $_ -and $_ -notin 'Invoke-MgGraphRequest', 'Invoke-RestMethod', 'Invoke-WebRequest' } | Sort-Object -Unique)
    # REST calls count as changes unless every one of them is a literal read (no -Method, or -Method GET).
    $restWrites = @($commands | Where-Object { $_.GetCommandName() -in 'Invoke-MgGraphRequest', 'Invoke-RestMethod', 'Invoke-WebRequest', 'irm', 'iwr' } | Where-Object {
        $cmd = $_
        $methodIndex = -1
        for ($i = 1; $i -lt $cmd.CommandElements.Count; $i++) {
            $el = $cmd.CommandElements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -like 'Method*') { $methodIndex = $i }
        }
        if ($methodIndex -lt 0) { return $false }
        $el = $cmd.CommandElements[$methodIndex]
        $valueAst = if ($el.Argument) { $el.Argument } elseif ($methodIndex + 1 -lt $cmd.CommandElements.Count) { $cmd.CommandElements[$methodIndex + 1] } else { $null }
        $value = [string](Get-TkAstValue $valueAst)
        $value -notmatch '^(GET|HEAD|OPTIONS)$'
    })
    if (-not $supportsWhatIf -and ($changing -or $restWrites)) {
        $what = @($changing | Select-Object -First 3) + @(if ($restWrites) { 'REST calls' })
        $warnings.Add("Makes changes ($($what -join ', ')) but has no [CmdletBinding(SupportsShouldProcess)]. Dry runs still work - the toolkit blocks the changes and lists them - but the script can't describe them itself.")
    }
    $looksReadOnly = -not $changing -and -not $restWrites

    [pscustomobject]@{
        Path                 = $resolved
        Runtime              = 'PowerShell'
        Parameters           = $parameters.ToArray()
        SupportsWhatIf       = $supportsWhatIf
        DryRunArgument       = ''
        Platforms            = [string[]]@()
        SuggestedName        = ConvertTo-TkLabel ([System.IO.Path]::GetFileNameWithoutExtension($resolved))
        SuggestedDescription = if ($help -and $help.Synopsis) { ($help.Synopsis -replace '\s+', ' ').Trim() } else { '' }
        UsesExchange         = $usesExchange
        UsesGraph            = $usesGraph
        GraphScopes          = $scopes.ToArray()
        LooksReadOnly        = $looksReadOnly
        Warnings             = $warnings.ToArray()
    }
}

function ConvertTo-TkManifestParameter {
    param([Parameter(Mandatory)] $Definition)
    $entry = [ordered]@{ Name = $Definition.Name; Label = $Definition.Label; Type = $Definition.Type }
    if ($Definition.Required) { $entry.Required = $true }
    if ($null -ne $Definition.Default -and [string]$Definition.Default -ne '') { $entry.Default = $Definition.Default }
    if ($Definition.Type -eq 'Choice') { $entry.Options = [string[]]@($Definition.Options) }
    if ($Definition.HelpText) { $entry.HelpText = $Definition.HelpText }
    $entry
}

function New-TkModule {
    <#
    .SYNOPSIS
        Creates a module folder from an existing script (manifest generated from its param block,
        or its tk-param lines for other languages) or, without -ScriptPath, from Modules\_Template
        (PowerShell) or Core\Templates\<Runtime>.<ext>. The result is validated; if it isn't
        valid nothing is left behind.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ModulesPath,
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Category,
        [string] $Description,
        [string[]] $Tags = @(),
        [string] $ScriptPath,
        [switch] $ExchangeOnline,
        [string[]] $GraphScopes = @(),
        [switch] $ReadOnly,
        [string] $Author = '',
        # Only without -ScriptPath (a script's extension decides its runtime): which blank template to start from.
        [string] $Runtime = 'PowerShell'
    )

    if ($Id -notmatch '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$') {
        throw "Id '$Id' must look like 'Area.TaskName' (letters and digits, separated by dots)."
    }
    $target = Join-Path $ModulesPath $Id
    if (Test-Path -LiteralPath $target) { throw "A folder named '$Id' already exists in $ModulesPath." }
    if (@(Get-TkModule -Path $ModulesPath | Where-Object { $_.Id -eq $Id }).Count) { throw "Another module already uses the Id '$Id'." }

    $dryRunArgument = ''
    $platforms = @()
    if ($ScriptPath) {
        $analysis = Get-TkScriptAnalysis -Path $ScriptPath
        $source = $analysis.Path
        $runtimeName = $analysis.Runtime
        $parameters = $analysis.Parameters
        $supportsWhatIf = $analysis.SupportsWhatIf
        $dryRunArgument = $analysis.DryRunArgument
        $platforms = $analysis.Platforms
        if (-not $Description) { $Description = $analysis.SuggestedDescription }
        if (-not $Description) { $Description = "Imported from $(Split-Path -Leaf $source)." }
    }
    else {
        $definition = Get-TkRuntimeDefinition $Runtime
        if (-not $definition) { throw "Unknown runtime '$Runtime'. Use one of: $((Get-TkRuntimeName) -join ', ')." }
        $runtimeName = $definition.Name
        if ($runtimeName -eq 'PowerShell') {
            $templateDir = Join-Path $ModulesPath '_Template'
            $source = Join-Path $templateDir 'module.ps1'
            if (-not (Test-Path -LiteralPath $source)) { throw "Template not found in $templateDir." }
            $template = Get-Content -LiteralPath (Join-Path $templateDir 'module.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $parameters = @(Get-TkManifestParameter $template | ForEach-Object { ConvertTo-TkParameterDefinition $_ })
            $supportsWhatIf = [bool]$template.SupportsWhatIf
        }
        else {
            $source = Join-Path $PSScriptRoot "Templates\$runtimeName$(@($definition.Extensions)[0])"
            if (-not (Test-Path -LiteralPath $source)) { throw "Template not found: $source." }
            $analysis = Get-TkExternalScriptAnalysis -Path $source -Runtime $runtimeName
            $parameters = $analysis.Parameters
            $supportsWhatIf = $analysis.SupportsWhatIf
            $dryRunArgument = $analysis.DryRunArgument
            $platforms = $analysis.Platforms
        }
        if (-not $Description) { $Description = 'TODO: describe what this module does and why the admin center cannot.' }
    }
    $definition = Get-TkRuntimeDefinition $runtimeName
    $external = $runtimeName -ne 'PowerShell'
    $entryPoint = 'module' + $(if ($external) { [IO.Path]::GetExtension($source).ToLowerInvariant() } else { '.ps1' })

    $manifest = [ordered]@{
        Id             = $Id
        Name           = $Name
        Category       = $Category
        Tags           = [string[]]@(Split-TkList $Tags)
        Description    = $Description
        Version        = '1.0.0'
        Author         = $Author
        EntryPoint     = $entryPoint
        SupportsWhatIf = $supportsWhatIf
        ReadOnly       = [bool]$ReadOnly -and -not $external
        Requires       = [ordered]@{
            ExchangeOnline = [bool]$ExchangeOnline -and -not $external
            GraphScopes    = [string[]]@(if (-not $external) { Split-TkList $GraphScopes -Separator '[,\s]+' })
        }
        Parameters     = @($parameters | ForEach-Object { ConvertTo-TkManifestParameter $_ })
    }
    if ($external) {
        # Next to EntryPoint, so the language is easy to spot in module.json.
        $manifest.Insert(7, 'Runtime', $runtimeName)
        if ($dryRunArgument) { $manifest.Insert(9, 'DryRunArgument', $dryRunArgument) }
        if (@($platforms).Count) { $manifest.Insert(8, 'Platforms', [string[]]@($platforms)) }
        if ($ReadOnly -or $ExchangeOnline -or $GraphScopes.Count) { Write-Warning "$runtimeName modules can't be read-only or use Graph/Exchange Online sign-in; those settings were left out." }
    }

    if (-not $PSCmdlet.ShouldProcess($target, 'Create module')) { return }

    New-Item -ItemType Directory -Path $target | Out-Null
    try {
        $entry = Join-Path $target $entryPoint
        if ($external) { [System.IO.File]::WriteAllBytes($entry, (ConvertTo-TkScriptBytes -Path $source -Runtime $runtimeName)) }
        else { Copy-Item -LiteralPath $source -Destination $entry }
        $manifestPath = Join-Path $target 'module.json'
        ConvertTo-TkJson $manifest | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $written = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $problems = @(Test-TkManifest -Manifest $written -ModuleDirectory $target)
        if ($problems) { throw "The generated module is not valid: $($problems -join ' ')" }
    }
    catch {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    Get-TkModule -Path $ModulesPath | Where-Object { $_.Id -eq $Id }
}

function Set-TkModuleTag {
    <# Rewrites the Tags of a module's module.json, leaving everything else as it was. #>
    param(
        [Parameter(Mandatory)] [string] $ModuleDirectory,
        [string[]] $Tags = @()
    )
    $path = Join-Path $ModuleDirectory 'module.json'
    $manifest = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $clean = [string[]]@(Split-TkList $Tags)
    if ($manifest.PSObject.Properties['Tags']) { $manifest.Tags = $clean }
    else { $manifest | Add-Member -NotePropertyName Tags -NotePropertyValue $clean }
    ConvertTo-TkJson $manifest | Set-Content -LiteralPath $path -Encoding UTF8
}

#endregion

#region Preferences & JSON

function Get-TkPreferencePath {
    # Per user, outside the toolkit folder, so a shared install gives everyone their own favourites.
    # -Legacy: where M365 Admin Toolkit kept them before the rename.
    param([switch] $Legacy)
    Join-Path ([Environment]::GetFolderPath('ApplicationData')) "$(if ($Legacy) { 'M365AdminToolkit' } else { 'AdminToolkit' })\preferences.json"
}

function Get-TkPreference {
    param([string] $Path = (Get-TkPreferencePath))
    # Theme: System follows the Windows app mode; Light or Dark override it.
    # ReadinessView: Percent (73 % with counts) or Rating (Pass/Warn/Fail).
    $preference = [pscustomobject]@{ Favorites = [string[]]@(); GroupBy = 'Category'; Theme = 'System'; ReadinessView = 'Percent' }
    # Nothing saved since the rename yet: start from the M365 Admin Toolkit preferences. The next save
    # writes the new file; the old one stays for an older copy.
    if (-not $PSBoundParameters.ContainsKey('Path') -and -not (Test-Path -LiteralPath $Path)) { $Path = Get-TkPreferencePath -Legacy }
    if (Test-Path -LiteralPath $Path) {
        try {
            $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.Favorites) { $preference.Favorites = [string[]]@($saved.Favorites) }
            if ($saved.GroupBy) { $preference.GroupBy = [string]$saved.GroupBy }
            if ($saved.Theme -in 'System', 'Light', 'Dark') { $preference.Theme = [string]$saved.Theme }
            if ($saved.ReadinessView -in 'Percent', 'Rating') { $preference.ReadinessView = [string]$saved.ReadinessView }
        }
        catch {
            # A corrupt preferences file is not worth failing over - start from defaults.
        }
    }
    $preference
}

function Save-TkPreference {
    param(
        [Parameter(Mandatory)] $Preference,
        [string] $Path = (Get-TkPreferencePath)
    )
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ConvertTo-TkJson $Preference | Set-Content -LiteralPath $Path -Encoding UTF8
}

function ConvertTo-TkJson {
    <#
    .SYNOPSIS
        ConvertTo-Json with human-friendly output on Windows PowerShell 5.1:
        two-space indents and no '-style escaping of quotes and angle brackets.
    #>
    param([Parameter(Mandatory)] $InputObject)

    $raw = ConvertTo-Json -InputObject $InputObject -Depth 8 -Compress
    $raw = [regex]::Replace($raw, '\\u00(27|3c|3e|26)', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })

    $sb = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $escaped = $false
    $newLine = "`r`n"
    for ($i = 0; $i -lt $raw.Length; $i++) {
        $c = $raw[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $inString = $false }
            continue
        }
        if ($c -eq '"') { $inString = $true; [void]$sb.Append($c) }
        elseif ($c -eq '{' -or $c -eq '[') {
            $next = if ($i + 1 -lt $raw.Length) { $raw[$i + 1] } else { '' }
            if (($c -eq '{' -and $next -eq '}') -or ($c -eq '[' -and $next -eq ']')) {
                [void]$sb.Append($c).Append($next)
                $i++
            }
            else {
                $indent++
                [void]$sb.Append($c).Append($newLine).Append('  ' * $indent)
            }
        }
        elseif ($c -eq '}' -or $c -eq ']') {
            $indent--
            [void]$sb.Append($newLine).Append('  ' * $indent).Append($c)
        }
        elseif ($c -eq ',') { [void]$sb.Append(',').Append($newLine).Append('  ' * $indent) }
        elseif ($c -eq ':') { [void]$sb.Append(': ') }
        else { [void]$sb.Append($c) }
    }
    $sb.ToString()
}

#endregion

#region Parameter forms

function New-TkParameterForm {
    <#
    .SYNOPSIS
        Renders input controls for a module's parameters into a WPF panel.
        Returns an ordered map of Name -> @{ Control; Definition } used by Get-TkParameterValue.
    #>
    param(
        [Parameter(Mandatory)] [System.Windows.Controls.Panel] $Panel,
        [Parameter(Mandatory)] $Module
    )

    $Panel.Children.Clear()
    $controls = [ordered]@{}

    foreach ($p in $Module.Parameters) {
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = if ($p.Required) { "$($p.Label) *" } else { $p.Label }
        $label.FontWeight = [System.Windows.FontWeights]::SemiBold
        $label.Margin = New-Object System.Windows.Thickness 0, 10, 0, 3
        [void]$Panel.Children.Add($label)

        switch ($p.Type) {
            'Bool' {
                $control = New-Object System.Windows.Controls.CheckBox
                $control.Content = if ($p.HelpText) { $p.HelpText } else { 'Enabled' }
                $control.IsChecked = [bool]$p.Default
            }
            'Choice' {
                $control = New-Object System.Windows.Controls.ComboBox
                $control.MaxWidth = 360
                $control.HorizontalAlignment = 'Left'
                $control.MinWidth = 220
                foreach ($option in $p.Options) { [void]$control.Items.Add([string]$option) }
                $control.SelectedItem = if ($null -ne $p.Default) { [string]$p.Default } else { [string]$p.Options[0] }
            }
            'List' {
                $control = New-Object System.Windows.Controls.TextBox
                $control.AcceptsReturn = $true
                $control.Height = 90
                $control.VerticalScrollBarVisibility = 'Auto'
                $control.TextWrapping = 'NoWrap'
                $control.Text = (@($p.Default | Where-Object { $_ }) -join [Environment]::NewLine)
            }
            default {
                # String and Int
                $control = New-Object System.Windows.Controls.TextBox
                $control.Width = 360
                $control.HorizontalAlignment = 'Left'
                if ($null -ne $p.Default) { $control.Text = [string]$p.Default }
            }
        }
        if ($p.HelpText) { $control.ToolTip = $p.HelpText }
        [void]$Panel.Children.Add($control)

        if ($p.HelpText -and $p.Type -ne 'Bool') {
            $help = New-Object System.Windows.Controls.TextBlock
            $help.Text = $p.HelpText
            $help.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Tk.SubtleText')
            $help.FontSize = 11
            $help.TextWrapping = 'Wrap'
            $help.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
            [void]$Panel.Children.Add($help)
        }
        $controls[$p.Name] = @{ Control = $control; Definition = $p }
    }

    if ($controls.Count -eq 0) {
        $none = New-Object System.Windows.Controls.TextBlock
        $none.Text = 'This module takes no input.'
        $none.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Tk.SubtleText')
        [void]$Panel.Children.Add($none)
    }
    $controls
}

function Get-TkParameterValue {
    <#
    .SYNOPSIS
        Reads and type-converts the form's values. Empty optional fields are omitted so the
        script's own defaults apply. Returns @{ Values = <hashtable>; Problems = <string[]> }.
    #>
    param([System.Collections.IDictionary] $Controls)

    $values = @{}
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not $Controls) { return [pscustomobject]@{ Values = $values; Problems = @() } }

    foreach ($name in $Controls.Keys) {
        $control = $Controls[$name].Control
        $def = $Controls[$name].Definition

        if ($def.Type -eq 'Bool') {
            $values[$name] = [bool]$control.IsChecked
            continue
        }

        $value = $null
        if ($def.Type -eq 'Choice') {
            $value = [string]$control.SelectedItem
        }
        elseif ($def.Type -eq 'List') {
            $value = [string[]]@($control.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($value.Count -eq 0) { $value = $null }
        }
        elseif ($def.Type -eq 'Int') {
            $text = $control.Text.Trim()
            if ($text) {
                $number = 0
                if ([int]::TryParse($text, [ref]$number)) { $value = $number }
                else { $problems.Add("'$($def.Label)' must be a whole number.") ; continue }
            }
        }
        else {
            $value = $control.Text.Trim()
            if (-not $value) { $value = $null }
        }

        if ($null -eq $value) {
            if ($def.Required) { $problems.Add("'$($def.Label)' is required.") }
            continue
        }
        $values[$name] = $value
    }
    [pscustomobject]@{ Values = $values; Problems = $problems.ToArray() }
}

#endregion

#region Background worker

function New-TkWorker {
    <#
    .SYNOPSIS
        Opens the single long-lived worker runspace. All M365 work runs here, one job at a time,
        so Graph / Exchange sessions persist between runs while the UI thread stays free.
    #>
    param(
        [Parameter(Mandatory)] [string] $HelperScript,
        $Settings
    )

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA      # interactive sign-in dialogs need STA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    try {
        [void]$ps.AddScript('param($HelperScript, $Settings) . $HelperScript; $global:TkSettings = $Settings')
        [void]$ps.AddArgument($HelperScript).AddArgument($Settings)
        [void]$ps.Invoke()
        if ($ps.Streams.Error.Count) { throw "Worker initialisation failed: $($ps.Streams.Error[0])" }
    }
    finally { $ps.Dispose() }
    $runspace
}

function Start-TkJob {
    <#
    .SYNOPSIS
        Starts a script asynchronously in the worker runspace. Poll it with Receive-TkJob and
        finish it with Complete-TkJob. The script is passed as text, never as a live scriptblock,
        because scriptblocks are bound to the runspace that created them.
    #>
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.Runspace] $Runspace,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [hashtable] $Parameters = @{}
    )

    $ps = [powershell]::Create()
    $ps.Runspace = $Runspace
    [void]$ps.AddScript($ScriptBlock.ToString())
    if ($Parameters.Count) { [void]$ps.AddParameters($Parameters) }

    $inputData = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inputData.Complete()
    $output = New-Object 'System.Management.Automation.PSDataCollection[psobject]'

    [pscustomobject]@{
        Name       = $Name
        PowerShell = $ps
        Handle     = $ps.BeginInvoke($inputData, $output)
        Output     = $output
        Collected  = New-Object System.Collections.Generic.List[object]
        Blocked    = New-Object System.Collections.Generic.List[object]   # changes stopped by the guard
        Readiness  = $null                                                 # last Write-TkReadiness report
        Seen       = @{ Output = 0; Error = 0; Warning = 0; Verbose = 0; Information = 0 }
        Started    = Get-Date
    }
}

function Receive-TkJob {
    <#
    .SYNOPSIS
        Drains everything the job produced since the last call.
        Returns @{ Log = <entries with Level/Message>; Output = <new objects>; Blocked = <new guard entries> }.
    #>
    param([Parameter(Mandatory)] $Job)

    $streams = $Job.PowerShell.Streams
    $log = New-Object System.Collections.Generic.List[object]
    $newBlocked = New-Object System.Collections.Generic.List[object]
    $sources = @(
        @{ Key = 'Information'; Level = 'INFO';    Items = $streams.Information }
        @{ Key = 'Verbose';     Level = 'VERBOSE'; Items = $streams.Verbose }
        @{ Key = 'Warning';     Level = 'WARN';    Items = $streams.Warning }
        @{ Key = 'Error';       Level = 'ERROR';   Items = $streams.Error }
    )
    foreach ($source in $sources) {
        $items = $source.Items
        $i = $Job.Seen[$source.Key]
        for (; $i -lt $items.Count; $i++) {
            $record = $items[$i]
            # The worker's change guard reports blocked calls on the Information stream.
            if ($source.Key -eq 'Information' -and $record.Tags -contains 'TkBlocked') {
                $newBlocked.Add($record.MessageData)
                $Job.Blocked.Add($record.MessageData)
                continue
            }
            # Write-TkReadiness: kept on the job (last one wins), not logged. Get-TkReadiness validates it.
            if ($source.Key -eq 'Information' -and $record.Tags -contains 'TkReadiness') {
                $Job.Readiness = $record.MessageData
                continue
            }
            $message = switch ($source.Key) {
                'Information' { [string]$record.MessageData }
                'Error'       { $record.ToString() }
                default       { $record.Message }
            }
            $log.Add([pscustomobject]@{ Level = $source.Level; Message = $message })
        }
        $Job.Seen[$source.Key] = $i
    }

    $newOutput = New-Object System.Collections.Generic.List[object]
    $i = $Job.Seen.Output
    for (; $i -lt $Job.Output.Count; $i++) {
        $newOutput.Add($Job.Output[$i])
        $Job.Collected.Add($Job.Output[$i])
    }
    $Job.Seen.Output = $i

    [pscustomobject]@{ Log = $log; Output = $newOutput; Blocked = $newBlocked }
}

function Complete-TkJob {
    <#
    .SYNOPSIS
        Ends a finished job, disposes it and reports how it went. Call Receive-TkJob first -
        the streams are gone after this.
    #>
    param([Parameter(Mandatory)] $Job)

    $failure = $null
    try { [void]$Job.PowerShell.EndInvoke($Job.Handle) }
    catch {
        $inner = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
        if ($inner -isnot [System.Management.Automation.PipelineStoppedException]) { $failure = $inner.Message }
    }
    $state = [string]$Job.PowerShell.InvocationStateInfo.State
    $Job.PowerShell.Dispose()

    [pscustomobject]@{
        Name     = $Job.Name
        State    = $state
        Failure  = $failure
        Duration = (Get-Date) - $Job.Started
    }
}

function Stop-TkJob {
    param([Parameter(Mandatory)] $Job)
    # BeginStop so the UI thread never blocks on a stuck cmdlet.
    [void]$Job.PowerShell.BeginStop($null, $null)
}

function Invoke-TkWorkerCommand {
    <#
    .SYNOPSIS
        Runs a short script in the worker and waits at most TimeoutSeconds. Returns $true when it
        finished without error. For shutdown: never throws, never waits longer than the timeout.
    #>
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.Runspace] $Runspace,
        [Parameter(Mandatory)] [string] $Script,
        [int] $TimeoutSeconds = 10
    )
    $ps = [powershell]::Create()
    $ps.Runspace = $Runspace
    try {
        [void]$ps.AddScript($Script)
        $handle = $ps.BeginInvoke()
        if (-not $handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            [void]$ps.BeginStop($null, $null)
            return $false       # not disposed: that would wait for the stuck pipeline
        }
        [void]$ps.EndInvoke($handle)
        $ok = $ps.Streams.Error.Count -eq 0
        $ps.Dispose()
        $ok
    }
    catch { $false }     # e.g. the worker is still busy with a job that is being stopped
}

#endregion

#region Installed PowerShell modules

# The M365-related modules the inventory always lists, installed or not.
# Role: Required (the toolkit needs it), Optional (only some scripts need it), Retired (replace it).
$script:TkKnownModules = @(
    @{ Name = 'Microsoft.Graph.Authentication'; Role = 'Required'; Purpose = 'Microsoft Graph sign-in and Invoke-MgGraphRequest' }
    @{ Name = 'ExchangeOnlineManagement'; Role = 'Required'; Purpose = 'Exchange Online (and Security & Compliance)' }
    @{ Name = 'Microsoft.Graph'; Role = 'Optional'; Purpose = 'Full Graph SDK bundle (only for scripts that use Microsoft.Graph.* cmdlets)' }
    @{ Name = 'Microsoft.Graph.Beta'; Role = 'Optional'; Purpose = 'Graph SDK bundle for the beta endpoint' }
    @{ Name = 'MicrosoftTeams'; Role = 'Optional'; Purpose = 'Microsoft Teams' }
    @{ Name = 'PnP.PowerShell'; Role = 'Optional'; Purpose = 'SharePoint Online and Teams via PnP (v2 and later need PowerShell 7)' }
    @{ Name = 'Microsoft.Online.SharePoint.PowerShell'; Role = 'Optional'; Purpose = 'SharePoint Online admin' }
    @{ Name = 'Az.Accounts'; Role = 'Optional'; Purpose = 'Azure sign-in (Az modules)' }
    @{ Name = 'AzureAD'; Role = 'Retired'; Purpose = 'Retired by Microsoft - use Microsoft Graph instead' }
    @{ Name = 'AzureADPreview'; Role = 'Retired'; Purpose = 'Retired by Microsoft - use Microsoft Graph instead' }
    @{ Name = 'MSOnline'; Role = 'Retired'; Purpose = 'Retired by Microsoft - use Microsoft Graph instead' }
)
# Other installed modules that are listed too: every Graph SDK sub-module (their versions must match).
$script:TkInventoryPattern = '^Microsoft\.Graph\.'

function Get-TkModuleScope {
    <# Where a module is installed, without exposing the path (it contains the user name). #>
    param([string] $ModuleBase)
    if (-not $ModuleBase) { return '' }
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $programFiles = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    if ($documents -and $ModuleBase.StartsWith($documents, [StringComparison]::OrdinalIgnoreCase)) { return 'CurrentUser' }
    foreach ($p in $programFiles) { if ($ModuleBase.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return 'AllUsers' } }
    if ($env:windir -and $ModuleBase.StartsWith($env:windir, [StringComparison]::OrdinalIgnoreCase)) { return 'System' }
    'Other'
}

function ConvertTo-TkVersion {
    <# Parses '2.41.0' or '1.2.3-preview' into [version]; $null when it can't. #>
    param($Value)
    if ($Value -is [version]) { return $Value }
    $parsed = $null
    if ([version]::TryParse(([string]$Value -replace '[-+].*$', ''), [ref]$parsed)) { return $parsed }
    $null
}

function Get-TkGalleryVersion {
    <#
    .SYNOPSIS
        Latest stable version of each named module on the PowerShell Gallery, as @{ Name = [version] }.
        Uses the gallery's REST feed directly: Find-Module can stop to ask for the NuGet provider,
        and nothing may prompt here. Modules that aren't on the gallery are simply absent.
    #>
    param([Parameter(Mandatory)] [string[]] $Name, [int] $TimeoutSec = 30)

    # Windows PowerShell 5.1 may still default to TLS 1.0, which the gallery refuses.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $latest = @{}
    $names = @($Name | Where-Object { $_ -match '^[\w.-]+$' } | Sort-Object -Unique)
    for ($i = 0; $i -lt $names.Count; $i += 15) {
        $chunk = $names[$i..([math]::Min($i + 14, $names.Count - 1))]
        $ids = ($chunk | ForEach-Object { "Id eq '$_'" }) -join ' or '
        $filter = [uri]::EscapeDataString("IsLatestVersion and ($ids)")
        $uri = "https://www.powershellgallery.com/api/v2/Packages()?`$filter=$filter&`$select=Id,Version"
        foreach ($entry in @(Invoke-RestMethod -Uri $uri -TimeoutSec $TimeoutSec -ErrorAction Stop)) {
            if (-not $entry.properties) { continue }
            $version = ConvertTo-TkVersion $entry.properties.Version
            $id = [string]$entry.properties.Id
            if ($version -and (-not $latest[$id] -or $version -gt $latest[$id])) { $latest[$id] = $version }
        }
    }
    $latest
}

function Get-TkModuleInventory {
    <#
    .SYNOPSIS
        One row per M365-related PowerShell module: installed version, latest gallery version and a
        Status that flags what needs attention (Missing, Update available, Version mismatch, Retired).
    .PARAMETER Installed
        Module info objects (Name, Version, ModuleBase). Defaults to Get-Module -ListAvailable.
    .PARAMETER Latest
        @{ Name = version } from the gallery. Omit to report installed versions only.
    #>
    param(
        [object[]] $Installed,
        [hashtable] $Latest,
        [switch] $CheckGallery
    )

    if (-not $PSBoundParameters.ContainsKey('Installed')) {
        $names = @($script:TkKnownModules | ForEach-Object { $_.Name }) + 'Microsoft.Graph.*'
        $Installed = @(Get-Module -ListAvailable -Name $names -ErrorAction SilentlyContinue)
    }
    $byName = @{}
    foreach ($m in $Installed) {
        if (-not $m -or -not $m.Name) { continue }
        if (-not $byName[$m.Name]) { $byName[$m.Name] = New-Object System.Collections.Generic.List[object] }
        $byName[$m.Name].Add($m)
    }

    $catalog = [ordered]@{}
    foreach ($k in $script:TkKnownModules) { $catalog[$k.Name] = $k }
    foreach ($n in $byName.Keys | Sort-Object) {
        if (-not $catalog.Contains($n) -and $n -match $script:TkInventoryPattern) {
            $catalog[$n] = @{ Name = $n; Role = 'Optional'; Purpose = 'Graph SDK sub-module' }
        }
    }

    if ($CheckGallery -and -not $Latest) {
        $Latest = @{}
        try { $Latest = Get-TkGalleryVersion -Name @($catalog.Keys) }
        catch { Write-Warning "Could not reach the PowerShell Gallery, so update checks were skipped: $($_.Exception.Message)" }
    }

    # Graph sub-modules must be the same version as Microsoft.Graph.Authentication, or assemblies clash.
    $graphAuth = $null
    if ($byName['Microsoft.Graph.Authentication']) {
        $graphAuth = @($byName['Microsoft.Graph.Authentication'] | ForEach-Object { ConvertTo-TkVersion $_.Version } | Sort-Object -Descending)[0]
    }

    $order = @{ Required = 0; Optional = 1; Retired = 2 }
    $rows = foreach ($entry in $catalog.Values) {
        $name = $entry.Name
        # @() around the pipeline, not inside an if: an if would unroll a single copy to a scalar.
        $copies = @($byName[$name] | Where-Object { $_ } | Sort-Object { ConvertTo-TkVersion $_.Version } -Descending)
        $current = if ($copies.Count) { ConvertTo-TkVersion $copies[0].Version } else { $null }
        if (-not $current -and $entry.Role -eq 'Retired') { continue }    # not having these is the goal
        $newest = if ($Latest) { $Latest[$name] } else { $null }
        $others = @($copies | Select-Object -Skip 1 | ForEach-Object { [string]$_.Version } | Select-Object -Unique)

        $status, $action = if (-not $current) {
            if ($entry.Role -eq 'Required') { 'Missing', "Install-Module $name -Scope CurrentUser" } else { 'Not installed', '' }
        }
        elseif ($entry.Role -eq 'Retired') { 'Retired', "Rewrite scripts for Microsoft Graph, then Uninstall-Module $name" }
        elseif ($graphAuth -and $name -like 'Microsoft.Graph.*' -and $name -notlike 'Microsoft.Graph.Beta*' -and $name -ne 'Microsoft.Graph.Authentication' -and $current -ne $graphAuth) {
            'Version mismatch', "Update-Module Microsoft.Graph.Authentication, $name (keep all Graph modules on one version)"
        }
        elseif ($newest -and $current -lt $newest) { 'Update available', "Update-Module $name" }
        elseif ($newest) { 'Up to date', '' }
        else { 'Installed', '' }

        [pscustomobject]@{
            Module        = $name
            Role          = $entry.Role
            Status        = $status
            Installed     = if ($current) { [string]$current } else { '' }
            Latest        = if ($newest) { [string]$newest } else { '' }
            Scope         = if ($copies.Count) { Get-TkModuleScope $copies[0].ModuleBase } else { '' }
            OtherVersions = $others -join ', '
            Action        = $action
            Purpose       = $entry.Purpose
            SortKey       = '{0}{1}' -f $order[$entry.Role], $name
        }
    }
    $rows | Sort-Object SortKey | Select-Object -Property * -ExcludeProperty SortKey
}

function Test-TkElevated {
    <# Whether this PowerShell runs as administrator (needed to update AllUsers modules in place). #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TkModuleUpdatePlan {
    <#
    .SYNOPSIS
        Turns inventory rows into the installs that fix them: one entry per module with the version
        and scope to install (Module, From, To, Scope, Note). Nothing is installed here.
    .PARAMETER Inventory
        Rows from Get-TkModuleInventory, ideally compared with the gallery so Latest is filled in.
    .PARAMETER Name
        Only plan these modules (the rows selected in the GUI). Omit to plan everything that needs it.
    .PARAMETER Elevated
        Whether AllUsers copies can be updated in place. Defaults to the current session.
    #>
    param(
        [object[]] $Inventory,
        [string[]] $Name,
        [Nullable[bool]] $Elevated
    )
    if ($null -eq $Elevated) { $Elevated = Test-TkElevated }
    $byName = @{}
    foreach ($row in $Inventory) { if ($row -and $row.Module) { $byName[$row.Module] = $row } }
    $chosen = if ($Name) { @($Name | ForEach-Object { $byName[$_] } | Where-Object { $_ }) } else { @($Inventory | Where-Object { $_ }) }

    # A version mismatch is fixed by moving Authentication and the sub-module to the latest version.
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($row in $chosen | Where-Object { $_.Status -in 'Missing', 'Update available', 'Version mismatch' }) {
        if ($row.Status -eq 'Version mismatch' -and -not $candidates.Contains('Microsoft.Graph.Authentication')) { $candidates.Add('Microsoft.Graph.Authentication') }
        if (-not $candidates.Contains($row.Module)) { $candidates.Add($row.Module) }
    }

    $plan = foreach ($n in $candidates) {
        $row = $byName[$n]
        if (-not $row) { continue }
        $current = ConvertTo-TkVersion $row.Installed
        $target = ConvertTo-TkVersion $row.Latest
        if ($current -and (-not $target -or $current -ge $target)) { continue }    # nothing newer known
        $scope, $note = switch ([string]$row.Scope) {
            'AllUsers' {
                if ($Elevated) { 'AllUsers', '' }
                else { 'CurrentUser', 'Goes to the current user: updating the all-users copy needs the toolkit to run as administrator.' }
            }
            { $_ -in '', 'CurrentUser' } { 'CurrentUser', '' }
            default { 'CurrentUser', "The installed copy is in a $($row.Scope) folder, so the new version goes to the current user." }
        }
        [pscustomobject]@{
            Module = $n
            From   = [string]$row.Installed
            To     = if ($target) { [string]$target } else { 'latest' }
            Scope  = $scope
            Note   = $note
        }
    }

    # The Microsoft.Graph and Microsoft.Graph.Beta bundles install their sub-modules at the same version.
    $plan = @($plan)
    $bundles = @($plan | Where-Object { $_.Module -in 'Microsoft.Graph', 'Microsoft.Graph.Beta' })
    $plan = @($plan | Where-Object {
        $item = $_
        -not @($bundles | Where-Object {
            $item.Module -like "$($_.Module).*" -and $item.Module -ne 'Microsoft.Graph.Authentication' -and $item.To -eq $_.To -and
            -not ($_.Module -eq 'Microsoft.Graph' -and $item.Module -like 'Microsoft.Graph.Beta*')
        }).Count
    })
    # Authentication first: every other Graph module depends on it.
    @($plan | Where-Object Module -eq 'Microsoft.Graph.Authentication') + @($plan | Where-Object Module -ne 'Microsoft.Graph.Authentication')
}

function Update-TkInstalledModule {
    <#
    .SYNOPSIS
        Installs the versions in an update plan from the PowerShell Gallery, without any prompt.
        Outputs one row per module with Status Updated, Installed, Failed or WhatIf. Older versions
        stay side by side and PowerShell loads the newest; sessions that already loaded a module
        keep the old one until they restart.
    .PARAMETER Plan
        Entries from Get-TkModuleUpdatePlan.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [object[]] $Plan)

    $install = Get-Command Install-Module -ErrorAction SilentlyContinue
    if (-not $install) { throw 'Install-Module (PowerShellGet) is not available in this PowerShell.' }
    $prepared = $false

    foreach ($item in $Plan) {
        $target = '{0} {1} ({2})' -f $item.Module, $item.To, $item.Scope
        $result = [ordered]@{ Module = $item.Module; From = $item.From; To = $item.To; Scope = $item.Scope; Status = ''; Message = [string]$item.Note }
        if (-not $PSCmdlet.ShouldProcess($target, 'Install module from the PowerShell Gallery')) {
            $result.Status = 'WhatIf'
            [pscustomobject]$result
            continue
        }
        try {
            if (-not $prepared) {
                # Windows PowerShell 5.1 may still default to TLS 1.0, which the gallery refuses.
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                # Install-Module would stop to ask for the NuGet provider; install it up front instead.
                $nuget = @(Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'NuGet' -and $_.Version -ge [version]'2.8.5.201' })
                if (-not $nuget.Count) {
                    Write-Information 'Installing the NuGet package provider for the current user (Install-Module needs it)...'
                    [void](Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop)
                }
                $prepared = $true
            }
            Write-Information "Installing $target from the PowerShell Gallery..."
            # -Force skips the 'untrusted repository' prompt and installs side by side with older versions.
            $splat = @{ Name = $item.Module; Scope = $item.Scope; Repository = 'PSGallery'; Force = $true; Confirm = $false; ErrorAction = 'Stop' }
            if ($item.To -and $item.To -ne 'latest') { $splat.RequiredVersion = $item.To }
            if ($install.Parameters.ContainsKey('AcceptLicense')) { $splat.AcceptLicense = $true }
            Install-Module @splat
            $result.Status = if ($item.From) { 'Updated' } else { 'Installed' }
            Write-Information "Done: $target"
        }
        catch {
            $result.Status = 'Failed'
            $result.Message = $_.Exception.Message
            Write-Warning "Could not install ${target}: $($_.Exception.Message)"
        }
        [pscustomobject]$result
    }
}

function Get-TkModuleFolder {
    <#
    .SYNOPSIS
        The folders PowerShell loads modules from ($env:PSModulePath), in search order, with their
        Scope and whether they exist. Paths contain the user name: show them on screen, never log them.
    #>
    param([string] $ModulePath = $env:PSModulePath)
    $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($ModulePath -split ';')) {
        $path = ([string]$p).Trim().TrimEnd('\')
        if (-not $path -or -not $seen.Add($path)) { continue }
        [pscustomobject]@{
            Path   = $path
            Scope  = Get-TkModuleScope $path
            Exists = Test-Path -LiteralPath $path -PathType Container
        }
    }
}

function Get-TkModuleLocation {
    <# Every installed copy of the named modules: Module, Version, Scope and the folder it is in (on screen only). #>
    param([Parameter(Mandatory)] [string[]] $Name, [object[]] $Available)
    if (-not $PSBoundParameters.ContainsKey('Available')) { $Available = @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue) }
    $Available | Where-Object { $_ -and $_.Name -in $Name } | Sort-Object Name, { ConvertTo-TkVersion $_.Version } | ForEach-Object {
        [pscustomobject]@{ Module = $_.Name; Version = [string]$_.Version; Scope = Get-TkModuleScope $_.ModuleBase; Path = $_.ModuleBase }
    }
}

function Uninstall-TkInstalledModule {
    <#
    .SYNOPSIS
        Removes every installed version of the named modules with Uninstall-Module, without any prompt.
        Outputs one row per version (Module, Version, Scope, Status, Message) with Status Removed,
        Failed, Skipped or WhatIf. Fails closed: a copy that is loaded in this process (its files are
        locked, so a removal would leave it half deleted), an all-users copy without admin rights and a
        copy that Install-Module didn't install are left alone.
    .PARAMETER Installed
        Get-InstalledModule results (Name, Version, InstalledLocation). Defaults to the real ones.
    .PARAMETER Available
        Get-Module -ListAvailable results (Name, Version, ModuleBase). Defaults to the real ones.
    .PARAMETER LoadedPath
        Files loaded in this process. Defaults to every loaded assembly and module.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string[]] $Name,
        [object[]] $Installed,
        [object[]] $Available,
        [string[]] $LoadedPath,
        [Nullable[bool]] $Elevated
    )
    if (-not $PSBoundParameters.ContainsKey('Installed')) {
        if (-not (Get-Command Get-InstalledModule -ErrorAction SilentlyContinue)) { throw 'Get-InstalledModule (PowerShellGet) is not available in this PowerShell.' }
        $Installed = @(Get-InstalledModule -Name $Name -AllVersions -ErrorAction SilentlyContinue)
    }
    if (-not $PSBoundParameters.ContainsKey('Available')) { $Available = @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue) }
    if (-not $PSBoundParameters.ContainsKey('LoadedPath')) {
        $LoadedPath = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { -not $_.IsDynamic } | ForEach-Object { try { $_.Location } catch { } }) +
            @(Get-Module | ForEach-Object Path)
    }
    if ($null -eq $Elevated) { $Elevated = Test-TkElevated }
    $LoadedPath = @($LoadedPath | Where-Object { $_ })

    # Dependants first: the Graph bundles need their sub-modules, and every Graph module needs Authentication.
    $rank = { param($n) if ($n -in 'Microsoft.Graph', 'Microsoft.Graph.Beta') { 0 } elseif ($n -eq 'Microsoft.Graph.Authentication') { 2 } else { 1 } }
    $names = @($Name | Where-Object { $_ } | Sort-Object -Unique | Sort-Object { & $rank $_ }, { $_ })

    foreach ($n in $names) {
        $managed = @($Installed | Where-Object { $_ -and $_.Name -eq $n })
        $managedPaths = @($managed | ForEach-Object { ([string]$_.InstalledLocation).TrimEnd('\') })
        foreach ($copy in @($Available | Where-Object { $_ -and $_.Name -eq $n })) {
            if ($managedPaths -contains ([string]$copy.ModuleBase).TrimEnd('\')) { continue }
            [pscustomobject]@{ Module = $n; Version = [string]$copy.Version; Scope = Get-TkModuleScope $copy.ModuleBase; Status = 'Skipped'
                Message = 'Not installed with Install-Module, so it is not removed here. Use Module folders to find it and delete it by hand.' }
        }
        foreach ($m in $managed | Sort-Object { ConvertTo-TkVersion $_.Version } -Descending) {
            $location = ([string]$m.InstalledLocation).TrimEnd('\')
            $result = [ordered]@{ Module = $n; Version = [string]$m.Version; Scope = Get-TkModuleScope $location; Status = ''; Message = '' }
            $target = '{0} {1} ({2})' -f $n, $result.Version, $result.Scope
            if (-not $location -or $result.Scope -in 'System', 'Other') {
                $result.Status = 'Skipped'
                $result.Message = "Installed in a $($result.Scope) folder, which the toolkit doesn't remove from."
            }
            elseif (@($LoadedPath | Where-Object { $_.StartsWith("$location\", [StringComparison]::OrdinalIgnoreCase) }).Count) {
                $result.Status = 'Skipped'
                $result.Message = 'In use by the toolkit (its files are locked). Restart the toolkit and remove it before connecting.'
            }
            elseif ($result.Scope -eq 'AllUsers' -and -not $Elevated) {
                $result.Status = 'Failed'
                $result.Message = 'Installed for all users: run the toolkit as administrator to remove it.'
            }
            elseif (-not $PSCmdlet.ShouldProcess($target, 'Uninstall module')) {
                $result.Status = 'WhatIf'
            }
            else {
                try {
                    Write-Information "Removing $target..."
                    Uninstall-Module -Name $n -RequiredVersion $result.Version -Confirm:$false -ErrorAction Stop
                    $result.Status = 'Removed'
                    Write-Information "Removed: $target"
                }
                catch {
                    $result.Status = 'Failed'
                    $result.Message = $_.Exception.Message
                    Write-Warning "Could not remove ${target}: $($_.Exception.Message)"
                }
            }
            [pscustomobject]$result
        }
    }
}

#endregion

#region Results, XAML & logging

function Format-TkValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
        return (@($Value | ForEach-Object { Format-TkValue $_ }) -join '; ')
    }
    [string]$Value
}

function ConvertTo-TkFlatObject {
    <#
    .SYNOPSIS
        Turns arbitrary module output into flat objects with string values and one shared column set,
        suitable for both the DataGrid and Export-Csv.
    #>
    param([object[]] $InputObject)

    $columns = New-Object System.Collections.Generic.List[string]
    $rows = foreach ($item in $InputObject) {
        if ($null -eq $item) { continue }
        $base = $item.PSObject.BaseObject
        $props = [ordered]@{}
        if ($base -is [string] -or $base -is [ValueType]) {
            $props['Value'] = Format-TkValue $base
        }
        elseif ($base -is [System.Collections.IDictionary]) {
            foreach ($key in $base.Keys) { $props[[string]$key] = Format-TkValue $base[$key] }
        }
        else {
            foreach ($p in $item.PSObject.Properties) { $props[$p.Name] = Format-TkValue $p.Value }
        }
        foreach ($key in $props.Keys) { if (-not $columns.Contains($key)) { $columns.Add($key) } }
        $props
    }

    foreach ($row in $rows) {
        $flat = [ordered]@{}
        foreach ($c in $columns) { $flat[$c] = if ($row.Contains($c)) { $row[$c] } else { '' } }
        [pscustomobject]$flat
    }
}

function ConvertTo-TkDataTable {
    param([object[]] $FlatObject)

    $table = New-Object System.Data.DataTable 'Results'
    if ($FlatObject) {
        $names = @($FlatObject[0].PSObject.Properties.Name)
        foreach ($n in $names) { [void]$table.Columns.Add($n, [string]) }
        foreach ($o in $FlatObject) {
            $row = $table.NewRow()
            foreach ($n in $names) { $row[$n] = [string]$o.$n }
            $table.Rows.Add($row)
        }
    }
    # Comma: PowerShell would otherwise enumerate the table's rows.
    , $table
}

function Import-TkStyle {
    <#
    .SYNOPSIS
        Loads a ResourceDictionary into application resources so every window can use its styles,
        plus the colour palette from Themes\<Theme>.xaml next to it.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('Light', 'Dark')] [string] $Theme = 'Light'
    )
    $dictionary = [System.Windows.Markup.XamlReader]::Parse((Get-Content -LiteralPath $Path -Raw -Encoding UTF8))
    if (-not [System.Windows.Application]::Current) {
        $app = New-Object System.Windows.Application
        $app.ShutdownMode = 'OnExplicitShutdown'   # we drive windows with ShowDialog, not Application.Run
    }
    $script:TkThemeFolder = Join-Path (Split-Path -Path $Path -Parent) 'Themes'
    Set-TkTheme -Theme $Theme
    # The WPF Application outlives this module: a second launch in the same PowerShell session finds
    # the first launch's styles still loaded. Replace them rather than stacking another copy.
    $merged = [System.Windows.Application]::Current.Resources.MergedDictionaries
    foreach ($old in @($merged | Where-Object { $_.Contains('Card') })) { [void]$merged.Remove($old) }
    $merged.Add($dictionary)
}

function Get-TkSystemTheme {
    <#
    .SYNOPSIS
        'Dark' when Windows is set to dark mode for apps (Settings > Personalisation > Colours),
        otherwise 'Light' - also when the setting doesn't exist (older Windows, Server Core).
    #>
    try {
        $personalize = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ($personalize.AppsUseLightTheme -eq 0) { return 'Dark' }
    }
    catch {
        # No setting: Windows' default is light.
    }
    'Light'
}

function Resolve-TkTheme {
    <# Turns a preference (System, Light or Dark) into the theme to show. #>
    param([string] $Preference)
    if ($Preference -in 'Light', 'Dark') { return $Preference }
    Get-TkSystemTheme
}

function Get-TkTheme { $script:TkTheme }

function Set-TkTheme {
    <#
    .SYNOPSIS
        Swaps the colour palette. Everything uses DynamicResource, so open windows recolour at once.
    #>
    param([Parameter(Mandatory)] [ValidateSet('Light', 'Dark')] [string] $Theme)
    $merged = [System.Windows.Application]::Current.Resources.MergedDictionaries
    $path = Join-Path $script:TkThemeFolder "$Theme.xaml"
    $palette = [System.Windows.Markup.XamlReader]::Parse((Get-Content -LiteralPath $path -Raw -Encoding UTF8))
    # Remove every palette already loaded, not just the one this module remembers: a second launch in the
    # same PowerShell session re-imports the module (forgetting it) while the WPF Application keeps the old
    # palette. A leftover palette outranks the new one and freezes the colours - only keys it lacks would switch.
    foreach ($old in @($merged | Where-Object { $_.Contains('Tk.WindowBackground') })) { [void]$merged.Remove($old) }
    $merged.Insert(0, $palette)
    $script:TkTheme = $Theme
    foreach ($window in [System.Windows.Application]::Current.Windows) { Set-TkWindowTheme -Window $window }
}

function Set-TkWindowTheme {
    <#
    .SYNOPSIS
        Gives a window a dark or light title bar to match the theme. Windows 10 20H1 and later;
        a no-op elsewhere. Cosmetic, so it never throws.
    #>
    param([System.Windows.Window] $Window)
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }       # not shown yet: SourceInitialized calls this again
        $dark = [int]($script:TkTheme -eq 'Dark')
        $loaded = [bool]('TkNative.Dwm' -as [type])
        if (-not $dark -and -not $loaded) { return }   # light is the default: nothing to undo
        if (-not $loaded) {
            Add-Type -Namespace TkNative -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@
        }
        # 20 = DWMWA_USE_IMMERSIVE_DARK_MODE; Windows 10 builds before 19041 used 19.
        if ([TkNative.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4) -ne 0) {
            [void][TkNative.Dwm]::DwmSetWindowAttribute($hwnd, 19, [ref]$dark, 4)
        }
        # Redraw the frame now: NOSIZE | NOMOVE | NOZORDER | NOACTIVATE | FRAMECHANGED.
        [void][TkNative.Dwm]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x37)
    }
    catch {
        # Older Windows or no dwmapi: keep the default title bar.
    }
}

function Import-TkXaml {
    <#
    .SYNOPSIS
        Loads a XAML window and returns a hashtable of every x:Name'd element plus 'Window'.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $window = [System.Windows.Markup.XamlReader]::Parse($text)
    # The title bar colour needs a window handle, which exists from SourceInitialized on.
    if ($window -is [System.Windows.Window]) { $window.Add_SourceInitialized({ Set-TkWindowTheme -Window $this }) }
    $ui = @{ Window = $window }
    foreach ($match in [regex]::Matches($text, 'x:Name="([^"]+)"')) {
        $name = $match.Groups[1].Value
        $ui[$name] = $window.FindName($name)
    }
    $ui
}

function Write-TkLogFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Level = 'INFO',
        [string] $Message
    )
    try {
        $dir = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never take the GUI down.
    }
}

#endregion

#region Session limits (Config\settings.json)

# Same defaults and accepted ranges as Get-TkSessionPolicy in Toolkit.Worker.ps1, which enforces them.
$script:TkSessionDefaults = @{ MaxAgeHours = 8; IdleMinutes = 60 }

function Get-TkSessionLimit {
    <# The session limits in effect for these settings (defaults for missing or out-of-range values). #>
    param($Settings)
    $limit = [pscustomobject]@{ MaxAgeHours = $script:TkSessionDefaults.MaxAgeHours; IdleMinutes = $script:TkSessionDefaults.IdleMinutes }
    $cfg = if ($Settings -and $Settings.PSObject.Properties['Session']) { $Settings.Session }
    if ($cfg) {
        $v = $cfg.MaxAgeHours -as [double]
        if ($v -gt 0 -and $v -le 24) { $limit.MaxAgeHours = $v }
        $v = $cfg.IdleMinutes -as [double]
        if ($v -gt 0 -and $v -le 1440) { $limit.IdleMinutes = $v }
    }
    $limit
}

function Test-TkSessionLimit {
    <# Checks what was typed in Settings. Returns @{ MaxAgeHours; IdleMinutes; Problems }. Whole numbers only. #>
    param([string] $MaxAgeHours, [string] $IdleMinutes)
    $problems = New-Object System.Collections.Generic.List[string]
    $hours = 0
    $minutes = 0
    if (-not [int]::TryParse($MaxAgeHours.Trim(), [ref]$hours) -or $hours -lt 1 -or $hours -gt 24) { $problems.Add('Hours after sign-in must be a whole number from 1 to 24.') }
    if (-not [int]::TryParse($IdleMinutes.Trim(), [ref]$minutes) -or $minutes -lt 1 -or $minutes -gt 1440) { $problems.Add('Minutes without use must be a whole number from 1 to 1440.') }
    [pscustomobject]@{ MaxAgeHours = $hours; IdleMinutes = $minutes; Problems = $problems.ToArray() }
}

function Save-TkSessionLimit {
    <#
    .SYNOPSIS
        Writes the session limits into settings.json, keeping every other setting (e.g. app-only sign-in).
        Refuses to touch a file it cannot read, rather than overwrite it.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateRange(1, 24)] [int] $MaxAgeHours,
        [Parameter(Mandatory)] [ValidateRange(1, 1440)] [int] $IdleMinutes
    )
    $settings = [pscustomobject]@{}
    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($raw -and $raw.Trim()) {
            try { $settings = $raw | ConvertFrom-Json -ErrorAction Stop }
            catch { throw "settings.json could not be read, so it was left unchanged: $($_.Exception.Message)" }
        }
    }
    else {
        $dir = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    $session = if ($settings.PSObject.Properties['Session'] -and $settings.Session -is [pscustomobject]) { $settings.Session } else { [pscustomobject]@{} }
    $session | Add-Member -NotePropertyName MaxAgeHours -NotePropertyValue $MaxAgeHours -Force
    $session | Add-Member -NotePropertyName IdleMinutes -NotePropertyValue $IdleMinutes -Force
    $settings | Add-Member -NotePropertyName Session -NotePropertyValue $session -Force
    ConvertTo-TkJson $settings | Set-Content -LiteralPath $Path -Encoding UTF8
}

#endregion

#region Open in Excel

function ConvertTo-TkExcelData {
    <#
    .SYNOPSIS
        Turns flat result rows (string values) into a 2-D cell array for Excel, header row first, with a
        type per column: Number, Date, DateTime or Text. A column is a number or date column only when
        every non-empty value is one; everything else stays text, so serials like '0042' or versions like
        '10.0.26200' are not mangled and a value starting with '=' is never run as a formula.
    #>
    param([object[]] $Rows)

    $rows = @($Rows | Where-Object { $null -ne $_ })
    if (-not $rows.Count) { return }
    $names = @($rows[0].PSObject.Properties.Name)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $kinds = foreach ($n in $names) {
        $values = @($rows | ForEach-Object { [string]$_.$n } | Where-Object { $_ -ne '' })
        if (-not $values.Count) { 'Text' }
        elseif (-not @($values | Where-Object { $_ -notmatch '^-?(0|[1-9]\d{0,14})(\.\d+)?$' }).Count) { 'Number' }
        # Date-only: no time, or always midnight (the toolkit writes dates as 'yyyy-MM-dd 00:00:00').
        elseif (-not @($values | Where-Object { $_ -notmatch '^\d{4}-\d{2}-\d{2}( 00:00(:00)?)?$' }).Count) { 'Date' }
        elseif (-not @($values | Where-Object { $_ -notmatch '^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$' }).Count) { 'DateTime' }
        else { 'Text' }
    }
    $kinds = @($kinds)
    $formats = [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm', 'yyyy-MM-dd')

    $cells = New-Object 'object[,]' ($rows.Count + 1), $names.Count
    for ($c = 0; $c -lt $names.Count; $c++) {
        $cells[0, $c] = $names[$c]
        for ($r = 0; $r -lt $rows.Count; $r++) {
            $text = [string]$rows[$r].($names[$c])
            $cells[($r + 1), $c] = if ($text -eq '') { $null }
                elseif ($kinds[$c] -eq 'Number') { [double]::Parse($text, $invariant) }
                elseif ($kinds[$c] -in 'Date', 'DateTime') {
                    # As an Excel serial number; a date that doesn't exist (2026-02-30) stays as text.
                    $date = [datetime]::MinValue
                    if ([datetime]::TryParseExact($text, $formats, $invariant, 'None', [ref]$date)) { $date.ToOADate() } else { $text }
                }
                else { $text }
        }
    }
    [pscustomobject]@{ Names = $names; Kinds = $kinds; Cells = $cells; RowCount = $rows.Count + 1 }
}

function Open-TkExcelTable {
    <#
    .SYNOPSIS
        Opens rows as a formatted table (filters, typed columns) in a new, unsaved Excel workbook.
        Built through Excel automation, so no temporary file with the data is written. Needs desktop Excel.
    #>
    param(
        [Parameter(Mandatory)] [object[]] $Rows,
        [string] $SheetName = 'Results'
    )
    $data = ConvertTo-TkExcelData -Rows $Rows
    if (-not $data) { throw 'There is nothing to open.' }

    try { $excel = New-Object -ComObject Excel.Application -ErrorAction Stop }
    catch { throw 'Microsoft Excel (desktop) is not installed or could not be started. Use Export CSV instead.' }

    $book = $sheet = $range = $null
    try {
        $excel.ScreenUpdating = $false
        # Format codes in Excel's own language (Norwegian Excel wants its own year letter, not 'yyyy'): ask it for the letters.
        # xlYearCode 19, xlMonthCode 20, xlDayCode 21, xlHourCode 22, xlMinuteCode 23
        $code = @{}
        foreach ($k in @{ Y = 19; M = 20; D = 21; H = 22; N = 23 }.GetEnumerator()) { $code[$k.Key] = [string]$excel.International($k.Value) }
        $dateFormat = ($code.Y * 4) + '-' + ($code.M * 2) + '-' + ($code.D * 2)
        $localFormats = @{ Date = $dateFormat; DateTime = $dateFormat + ' ' + ($code.H * 2) + ':' + ($code.N * 2) }
        $book = $excel.Workbooks.Add()
        $sheet = $book.Worksheets.Item(1)
        # Sheet names: at most 31 characters, none of : \ / ? * [ ]
        $name = ($SheetName -replace '[:\\/\?\*\[\]]', ' ').Trim()
        if ($name.Length -gt 31) { $name = $name.Substring(0, 31).Trim() }
        if ($name) { $sheet.Name = $name }

        $columns = $data.Names.Count
        for ($c = 0; $c -lt $columns; $c++) {
            $column = $sheet.Range($sheet.Cells(1, $c + 1), $sheet.Cells($data.RowCount, $c + 1))
            # Formats go on before the values: in a Text (@) column Excel stores exactly what it is given.
            # Number columns keep the default format: some Excel languages (e.g. Norwegian) refuse 'General' here.
            $kind = $data.Kinds[$c]
            if ($kind -eq 'Text') { $column.NumberFormat = '@' }
            elseif ($localFormats.ContainsKey($kind)) { $column.NumberFormatLocal = [string]$localFormats[$kind] }
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($column)
        }
        $header = $sheet.Range($sheet.Cells(1, 1), $sheet.Cells(1, $columns))
        $header.NumberFormat = '@'
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($header)

        $range = $sheet.Range($sheet.Cells(1, 1), $sheet.Cells($data.RowCount, $columns))
        $range.Value2 = $data.Cells
        # xlSrcRange = 1, xlYes = 1 (the first row holds the headers)
        $table = $sheet.ListObjects.Add(1, $range, [Type]::Missing, 1)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($table)
        [void]$range.Columns.AutoFit()
        # Keep very wide text columns readable.
        foreach ($col in @($range.Columns)) {
            if ($col.ColumnWidth -gt 60) { $col.ColumnWidth = 60 }
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($col)
        }
        $book.Saved = $true    # nothing of value to lose yet: no save prompt if it is closed straight away
        $excel.ScreenUpdating = $true
        $excel.Visible = $true
        $excel.UserControl = $true     # the user owns Excel now; it stays open when we let go
    }
    catch {
        try { if ($book) { $book.Close($false) }; $excel.Quit() } catch { }
        throw "Could not open the results in Excel: $($_.Exception.Message)"
    }
    finally {
        foreach ($o in $range, $sheet, $book, $excel) { if ($o) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) } }
    }
}

#endregion

Export-ModuleMember -Function Get-TkModule, Test-TkManifest, New-TkParameterForm, Get-TkParameterValue,
    New-TkWorker, Start-TkJob, Receive-TkJob, Complete-TkJob, Stop-TkJob, Invoke-TkWorkerCommand,
    ConvertTo-TkFlatObject, ConvertTo-TkDataTable, Import-TkStyle, Import-TkXaml, Write-TkLogFile,
    Get-TkSystemTheme, Resolve-TkTheme, Get-TkTheme, Set-TkTheme,
    Split-TkList, ConvertTo-TkLabel, Get-TkSuggestedId, Get-TkScriptAnalysis, New-TkModule, Set-TkModuleTag,
    Get-TkPreference, Save-TkPreference, ConvertTo-TkJson, Get-TkReadiness,
    Get-TkDryRunProfile, ConvertTo-TkCodeLine, Get-TkFileSummary,
    Get-TkModuleInventory, Get-TkGalleryVersion, Test-TkElevated, Get-TkModuleUpdatePlan, Update-TkInstalledModule,
    Get-TkModuleFolder, Get-TkModuleLocation, Uninstall-TkInstalledModule,
    Get-TkSessionLimit, Test-TkSessionLimit, Save-TkSessionLimit, ConvertTo-TkExcelData, Open-TkExcelTable,
    Get-TkRuntimeName, Get-TkRuntimeDefinition, Get-TkRuntimeForFile, Get-TkRuntimeStatus,
    Get-TkExternalScriptAnalysis, ConvertTo-TkScriptBytes
