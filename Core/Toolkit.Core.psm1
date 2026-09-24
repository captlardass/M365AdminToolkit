#Requires -Version 5.1
<#
    Toolkit.Core - UI-side engine for the M365 Admin Toolkit.

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
    }

    if (-not $Manifest.EntryPoint) { return $problems.ToArray() }
    $entryPath = Join-Path $ModuleDirectory $Manifest.EntryPoint
    if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        $problems.Add("Entry point '$($Manifest.EntryPoint)' was not found.")
        return $problems.ToArray()
    }

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
        $dryRun = $null
        if ($problems.Count -eq 0) {
            try { $dryRun = Get-TkDryRunProfile -Path $entryPath -SupportsWhatIf $supportsWhatIf }
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
        Enforced = the toolkit's change guard) and lists what the guard cannot cover.
        Static analysis only - the script is never run.
    #>
    param([Parameter(Mandatory)] [string] $Path, [bool] $SupportsWhatIf)

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

function Get-TkScriptAnalysis {
    <#
    .SYNOPSIS
        Reads a .ps1 without running it and works out what a module manifest for it should say:
        GUI inputs from the param() block, WhatIf support, likely connections and Graph scopes,
        plus warnings about things that would misbehave inside the toolkit.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

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
        $warnings.Add('Uses Microsoft Graph, but no scopes could be detected. Enter the scopes it needs below.')
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
        Parameters           = $parameters.ToArray()
        SupportsWhatIf       = $supportsWhatIf
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
        Creates a module folder from an existing script (manifest generated from its param block)
        or, without -ScriptPath, from Modules\_Template. The result is validated; if it isn't
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
        [string] $Author = ''
    )

    if ($Id -notmatch '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$') {
        throw "Id '$Id' must look like 'Area.TaskName' (letters and digits, separated by dots)."
    }
    $target = Join-Path $ModulesPath $Id
    if (Test-Path -LiteralPath $target) { throw "A folder named '$Id' already exists in $ModulesPath." }
    if (@(Get-TkModule -Path $ModulesPath | Where-Object { $_.Id -eq $Id }).Count) { throw "Another module already uses the Id '$Id'." }

    if ($ScriptPath) {
        $analysis = Get-TkScriptAnalysis -Path $ScriptPath
        $source = $analysis.Path
        $parameters = $analysis.Parameters
        $supportsWhatIf = $analysis.SupportsWhatIf
        if (-not $Description) { $Description = $analysis.SuggestedDescription }
        if (-not $Description) { $Description = "Imported from $(Split-Path -Leaf $source)." }
    }
    else {
        $templateDir = Join-Path $ModulesPath '_Template'
        $source = Join-Path $templateDir 'module.ps1'
        if (-not (Test-Path -LiteralPath $source)) { throw "Template not found in $templateDir." }
        $template = Get-Content -LiteralPath (Join-Path $templateDir 'module.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $parameters = @(Get-TkManifestParameter $template | ForEach-Object { ConvertTo-TkParameterDefinition $_ })
        $supportsWhatIf = [bool]$template.SupportsWhatIf
        if (-not $Description) { $Description = 'TODO: describe what this module does and why the admin center cannot.' }
    }

    $manifest = [ordered]@{
        Id             = $Id
        Name           = $Name
        Category       = $Category
        Tags           = [string[]]@(Split-TkList $Tags)
        Description    = $Description
        Version        = '1.0.0'
        Author         = $Author
        EntryPoint     = 'module.ps1'
        SupportsWhatIf = $supportsWhatIf
        ReadOnly       = [bool]$ReadOnly
        Requires       = [ordered]@{
            ExchangeOnline = [bool]$ExchangeOnline
            GraphScopes    = [string[]]@(Split-TkList $GraphScopes -Separator '[,\s]+')
        }
        Parameters     = @($parameters | ForEach-Object { ConvertTo-TkManifestParameter $_ })
    }

    if (-not $PSCmdlet.ShouldProcess($target, 'Create module')) { return }

    New-Item -ItemType Directory -Path $target | Out-Null
    try {
        Copy-Item -LiteralPath $source -Destination (Join-Path $target 'module.ps1')
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
    Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'M365AdminToolkit\preferences.json'
}

function Get-TkPreference {
    param([string] $Path = (Get-TkPreferencePath))
    $preference = [pscustomobject]@{ Favorites = [string[]]@(); GroupBy = 'Category' }
    if (Test-Path -LiteralPath $Path) {
        try {
            $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.Favorites) { $preference.Favorites = [string[]]@($saved.Favorites) }
            if ($saved.GroupBy) { $preference.GroupBy = [string]$saved.GroupBy }
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
    $grey = [System.Windows.Media.Brushes]::DimGray

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
            $help.Foreground = $grey
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
        $none.Foreground = $grey
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
        Loads a ResourceDictionary into application resources so every window can use its styles.
    #>
    param([Parameter(Mandatory)] [string] $Path)
    $dictionary = [System.Windows.Markup.XamlReader]::Parse((Get-Content -LiteralPath $Path -Raw -Encoding UTF8))
    if (-not [System.Windows.Application]::Current) {
        $app = New-Object System.Windows.Application
        $app.ShutdownMode = 'OnExplicitShutdown'   # we drive windows with ShowDialog, not Application.Run
    }
    [System.Windows.Application]::Current.Resources.MergedDictionaries.Add($dictionary)
}

function Import-TkXaml {
    <#
    .SYNOPSIS
        Loads a XAML window and returns a hashtable of every x:Name'd element plus 'Window'.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $window = [System.Windows.Markup.XamlReader]::Parse($text)
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

Export-ModuleMember -Function Get-TkModule, Test-TkManifest, New-TkParameterForm, Get-TkParameterValue,
    New-TkWorker, Start-TkJob, Receive-TkJob, Complete-TkJob, Stop-TkJob,
    ConvertTo-TkFlatObject, ConvertTo-TkDataTable, Import-TkStyle, Import-TkXaml, Write-TkLogFile,
    Split-TkList, ConvertTo-TkLabel, Get-TkSuggestedId, Get-TkScriptAnalysis, New-TkModule, Set-TkModuleTag,
    Get-TkPreference, Save-TkPreference, ConvertTo-TkJson,
    Get-TkDryRunProfile, ConvertTo-TkCodeLine, Get-TkFileSummary
