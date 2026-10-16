# Runtime test suite: non-PowerShell modules (cmd, bash, zsh, Python) through the real worker.
# Cases for an interpreter that isn't installed are reported as skipped. Nothing touches a tenant.
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }
function Skip([string] $Case, [string] $Why) { $results.Add([pscustomobject]@{ Result = 'PASS'; Case = $Case; Detail = "skipped: $Why" }) }

Import-Module "$Root\Core\Toolkit.Core.psm1" -Force
$work = Join-Path ([IO.Path]::GetTempPath()) ('TkRuntimeTest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $work)
$worker = New-TkWorker -HelperScript "$Root\Core\Toolkit.Worker.ps1" -Settings $null
$noConnections = [pscustomobject]@{ ExchangeOnline = $false; GraphScopes = [string[]]@() }

function New-Script([string] $Name, [string] $Text, [switch] $Crlf) {
    $dir = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($Name) + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [void](New-Item -ItemType Directory -Path $dir)
    $path = Join-Path $dir $Name
    $body = $Text -replace "`r`n", "`n"
    if ($Crlf) { $body = $body -replace "`n", "`r`n" }
    [IO.File]::WriteAllText($path, $body, (New-Object Text.UTF8Encoding $false))
    $path
}

function Invoke-Run {
    param([string] $Path, [string] $Runtime, [hashtable] $Parameters = @{}, [string] $Guard = 'Off', [string] $DryRunArgument, [bool] $DryRun, [int] $StopAfterMs = 0, $Requires = $noConnections)
    $status = Get-TkRuntimeStatus $Runtime
    $job = Start-TkJob -Runspace $worker -Name 'runtime-test' -Parameters @{ E = $Path; R = $Requires; P = $Parameters; G = $Guard; T = $status; A = $DryRunArgument; D = $DryRun } -ScriptBlock {
        param($E, $R, $P, $G, $T, $A, $D) Invoke-TkModule -EntryPath $E -Requires $R -Parameters $P -Guard $G -Runtime $T -DryRunArgument $A -DryRun $D
    }
    $started = Get-Date
    if ($StopAfterMs) { Start-Sleep -Milliseconds $StopAfterMs; Stop-TkJob $job }
    $log = @()
    while ($true) { $done = $job.Handle.IsCompleted; $r = Receive-TkJob $job; $log += $r.Log; if ($done) { break }; Start-Sleep -Milliseconds 50 }
    $end = Complete-TkJob $job
    [pscustomobject]@{
        State     = $end.State
        Failure   = $end.Failure
        Seconds   = ((Get-Date) - $started).TotalSeconds
        Output    = $job.Collected.ToArray()
        Readiness = $job.Readiness
        Info      = @($log | Where-Object Level -eq 'INFO' | ForEach-Object Message)
        Warnings  = @($log | Where-Object Level -eq 'WARN' | ForEach-Object Message)
    }
}

function Invoke-InWorker([string] $Script, [hashtable] $Parameters) {
    $ps = [powershell]::Create(); $ps.Runspace = $worker
    try { [void]$ps.AddScript($Script).AddParameters($Parameters); $ps.Invoke() } finally { $ps.Dispose() }
}

# Values that break naive quoting: spaces, quotes, trailing backslashes, shell and cmd metacharacters.
$tricky = [string[]]@('plain', 'with space', 'quote"inside', 'trail\', 'back\\"slash', 'a&b|c^d%PATH%e!x', "tab`there", '$HOME `id` $(echo x)')

try {
    # --- cmd.exe: always available on Windows ---
    $protocol = New-Script 'module.cmd' -Crlf @'
@echo off
echo ##tk:row {"Name":"alpha","Count":1}
echo ##tk:row [{"Name":"beta","Count":2},{"Name":"gamma","Count":3}]
echo ##tk:readiness {"Ready":3,"Total":4,"Label":"things are ready","NotEvaluated":1}
echo a plain log line
echo ##tk:row {broken
echo something on stderr 1>&2
'@
    $r = Invoke-Run $protocol 'Cmd'
    Check 'cmd: ##tk:row lines become result rows (objects and arrays)' ($r.State -eq 'Completed' -and -not $r.Failure -and @($r.Output).Count -eq 3 -and $r.Output[2].Name -eq 'gamma' -and $r.Output[2].Count -eq 3) "$(@($r.Output).Count) row(s) $($r.Failure)"
    Check 'cmd: ##tk:readiness is reported like Write-TkReadiness' ($r.Readiness -and $r.Readiness.Ready -eq 3 -and $r.Readiness.Total -eq 4 -and $r.Readiness.NotEvaluated -eq 1 -and $r.Readiness.Label -eq 'things are ready') ''
    Check 'cmd: other stdout lines go to the log' ($r.Info -contains 'a plain log line') ($r.Info -join ' | ')
    Check 'cmd: invalid JSON is a warning, not a row' (@($r.Warnings | Where-Object { $_ -like '*isn''t valid JSON*' }).Count -eq 1) ($r.Warnings -join ' | ')
    Check 'cmd: stderr becomes a warning' ($r.Warnings -contains 'something on stderr') ($r.Warnings -join ' | ')
    Check 'The log says the run is unguarded' (@($r.Info | Where-Object { $_ -like '*unguarded*' }).Count -eq 1) ($r.Info -join ' | ')

    $injected = Join-Path $work 'injected.txt'
    $echo = New-Script 'module.cmd' -Crlf @'
@echo off
setlocal EnableDelayedExpansion
echo value=!TK_PARAM_TEXT!
echo dry=%TK_DRYRUN%
'@
    $value = "x & echo INJECTED> `"$injected`" | ^ %PATH%"
    $r = Invoke-Run $echo 'Cmd' -Parameters @{ Text = $value }
    Check 'cmd: a value with & | ^ % never runs as a command' ($r.State -eq 'Completed' -and -not (Test-Path $injected)) "$($r.Failure)"
    Check 'cmd: the value arrives unchanged through TK_PARAM_<NAME>' ($r.Info -contains "value=$value" -and $r.Info -contains 'dry=0') ($r.Info -join ' | ')
    $call = Invoke-InWorker 'param($E, $T, $P) Get-TkExternalInvocation -EntryPath $E -Runtime $T -Parameters $P' @{ E = $echo; T = (Get-TkRuntimeStatus Cmd); P = @{ Text = $value } }
    Check 'cmd: parameter values are never on the command line' ($call.Arguments -notlike '*INJECTED*' -and $call.Arguments -eq '/d /c "".\module.cmd""') $call.Arguments

    $fail = New-Script 'module.cmd' -Crlf "@echo off`necho about to fail`nexit /b 3"
    $r = Invoke-Run $fail 'Cmd'
    Check 'A non-zero exit code fails the run' ($r.Failure -like '*exited with code 3*') "$($r.Failure)"

    $marker = Join-Path $work 'not-cancelled.txt'
    $slow = New-Script 'module.cmd' -Crlf "@echo off`necho started`nping -n 6 127.0.0.1 >nul`necho finished> `"%TK_PARAM_MARKER%`""
    $r = Invoke-Run $slow 'Cmd' -Parameters @{ Marker = $marker } -StopAfterMs 1500
    Start-Sleep -Seconds 6
    Check 'Cancel kills the script and what it started' ($r.State -eq 'Stopped' -and $r.Seconds -lt 5 -and -not (Test-Path $marker)) "state $($r.State), $([int]$r.Seconds)s, marker $(Test-Path $marker)"

    $probe = Join-Path $work 'guarded-ran.txt'
    $guarded = New-Script 'module.cmd' -Crlf "@echo off`necho ran> `"$probe`""
    $r = Invoke-Run $guarded 'Cmd' -Guard 'DryRun'
    Check 'Refuses a guarded (dry run) run of a non-PowerShell script, before it starts' ($r.Failure -like '*change guard*' -and -not (Test-Path $probe)) "$($r.Failure)"
    $r = Invoke-Run $guarded 'Cmd' -Guard 'ReadOnly'
    Check 'Refuses a read-only run of a non-PowerShell script, before it starts' ($r.Failure -like '*change guard*' -and -not (Test-Path $probe)) "$($r.Failure)"
    $r = Invoke-Run $guarded 'Cmd' -Requires ([pscustomobject]@{ ExchangeOnline = $true; GraphScopes = [string[]]@() })
    Check 'Refuses a non-PowerShell script that asks for a Microsoft 365 connection' ($r.Failure -like '*sign-in*' -and -not (Test-Path $probe)) "$($r.Failure)"
    $r = Invoke-Run $guarded 'Cmd' -DryRun $true
    Check 'Refuses a dry run when the script has no dry-run switch' ($r.Failure -like '*no dry-run switch*' -and -not (Test-Path $probe)) "$($r.Failure)"

    $dry = New-Script 'module.cmd' -Crlf "@echo off`necho args=%*`necho dry=%TK_DRYRUN%"
    $r = Invoke-Run $dry 'Cmd' -DryRunArgument '/dryrun' -DryRun $true
    Check 'Dry run passes the DryRunArgument and TK_DRYRUN=1' ($r.Info -contains 'args=/dryrun' -and $r.Info -contains 'dry=1') ($r.Info -join ' | ')

    # --- Python: argv round trip ---
    if ((Get-TkRuntimeStatus Python).Available) {
        $py = New-Script 'module.py' @'
import json, os, sys
print("##tk:row " + json.dumps({"Args": sys.argv[1:], "Env": os.environ.get("TK_PARAM_ITEMS", "")}))
print("caf\u00e9")
'@
        $r = Invoke-Run $py 'Python' -Parameters @{ Items = $tricky; Flag = $true; Off = $false; Count = 7 }
        $expected = @('--Count', '7', '--Flag') + @($tricky | ForEach-Object { '--Items'; $_ })
        $got = @($r.Output | Select-Object -First 1 | ForEach-Object { $_.Args })
        Check 'Python: every value arrives as exactly one argument (quotes, backslashes, metacharacters)' ($r.State -eq 'Completed' -and -not (Compare-Object $expected $got -SyncWindow 0)) "got: $($got -join ' <> ') $($r.Failure)"
        Check 'Python: a List is also in TK_PARAM_<NAME>, one value per line' ($r.Output[0].Env -eq ($tricky -join "`n")) ''
        Check 'Python: output is read as UTF-8' ($r.Info -contains ('caf' + [char]0xE9)) ($r.Info -join ' | ')
    }
    else { Skip 'Python round trip' 'no Python interpreter' }

    # --- bash and zsh through WSL (or Git Bash) ---
    $bashCase = 'module.sh'
    $sh = @'
#!/usr/bin/env bash
for a in "$@"; do printf 'ARG:%s\n' "$a"; done
printf 'ENV:%s\n' "$TK_PARAM_NAME"
printf 'DRY:%s\n' "$TK_DRYRUN"
'@
    foreach ($runtime in 'Bash', 'Zsh') {
        $status = Get-TkRuntimeStatus $runtime
        if (-not $status.Available) { Skip "$runtime round trip" $status.Reason; continue }
        if ($runtime -eq 'Zsh') {
            $has = & $status.Interpreter -e sh -c 'command -v zsh' 2>$null
            if (-not $has) { Skip 'Zsh round trip' 'zsh is not installed in the WSL distribution'; continue }
            $bashCase = 'module.zsh'; $sh = $sh.Replace('#!/usr/bin/env bash', '#!/usr/bin/env zsh')
        }
        $path = New-Script $bashCase $sh
        $values = [string[]]@($tricky | Where-Object { $_ -notmatch "`t" })    # WSL turns a tab argument into a space
        $r = Invoke-Run $path $runtime -Parameters @{ Name = 'Pat Doe'; Items = $values } -DryRunArgument '--dry-run' -DryRun $true
        $args2 = @($r.Info | Where-Object { $_ -like 'ARG:*' } | ForEach-Object { $_.Substring(4) })
        $expected = @(@($values | ForEach-Object { '--Items'; $_ }) + '--Name', 'Pat Doe', '--dry-run')
        Check "$($status.Label): every value arrives as exactly one argument" ($r.State -eq 'Completed' -and -not (Compare-Object $expected $args2 -SyncWindow 0)) "got: $($args2 -join ' <> ') $($r.Failure) $($r.Warnings -join ' | ')"
        Check "$($status.Label): TK_* environment variables reach the script" ($r.Info -contains 'ENV:Pat Doe' -and $r.Info -contains 'DRY:1') ($r.Info -join ' | ')
    }

    # --- module.json rules for other languages ---
    function Test-Module([hashtable] $Manifest, [string] $File, [string] $Body = '#!/bin/sh') {
        $dir = Join-Path $work ('m_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        [void](New-Item -ItemType Directory -Path $dir)
        [IO.File]::WriteAllText((Join-Path $dir $File), $Body)
        $base = [ordered]@{ Id = 'Local.Test'; Name = 'Test'; Category = 'Local'; Description = 'x'; Version = '1.0.0'; EntryPoint = $File }
        foreach ($k in $Manifest.Keys) { $base[$k] = $Manifest[$k] }
        $json = [pscustomobject]$base | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        @(Test-TkManifest -Manifest $json -ModuleDirectory $dir)
    }
    $p = Test-Module @{ Runtime = 'Bash' } 'module.sh'
    Check 'A plain Bash module is valid' (-not $p.Count) ($p -join ' | ')
    $p = Test-Module @{ Runtime = 'Bash'; ReadOnly = $true } 'module.sh'
    Check 'Refuses ReadOnly for a Bash module (the guard cannot enforce it)' ($p -like '*ReadOnly can''t be enforced*') ($p -join ' | ')
    $p = Test-Module @{ Runtime = 'Python'; Requires = @{ GraphScopes = @('User.Read.All') } } 'module.py'
    Check 'Refuses Graph scopes for a Python module' ($p -like '*Graph or Exchange*') ($p -join ' | ')
    $p = Test-Module @{ Runtime = 'Bash'; SupportsWhatIf = $true } 'module.sh'
    Check 'Refuses SupportsWhatIf without DryRunArgument' ($p -like '*needs DryRunArgument*') ($p -join ' | ')
    $p = Test-Module @{ Runtime = 'Bash'; SupportsWhatIf = $true; DryRunArgument = '--dry-run; rm -rf /' } 'module.sh'
    Check 'Refuses a DryRunArgument that is not a plain switch' ($p -like '*plain switch*') ($p -join ' | ')
    $p = Test-Module @{ Runtime = 'Bash' } 'module.py'
    Check 'Refuses an entry point that does not match the runtime' ($p -like '*must end in .sh*') ($p -join ' | ')
    $p = Test-Module @{ Runtime = 'Ruby' } 'module.rb'
    Check 'Refuses an unknown runtime' ($p -like '*Runtime ''Ruby'' is unknown*') ($p -join ' | ')
    $p = Test-Module @{ Runtime = 'Cmd'; Parameters = @(@{ Name = 'Bad-Name'; Type = 'String' }) } 'module.cmd'
    Check 'Refuses a parameter name that cannot be an environment variable' ($p -like '*only use letters, digits and _*') ($p -join ' | ')
    $p = Test-Module @{ DryRunArgument = '--dry-run' } 'module.ps1' 'param()'
    Check 'Refuses DryRunArgument on a PowerShell module' ($p -like '*only for non-PowerShell*') ($p -join ' | ')
    $p = Test-Module @{ Runtime = 'Bash'; Platforms = @('Linux', 'Amiga') } 'module.sh'
    Check 'Refuses an unknown platform' ($p -like '*Platforms may only list*') ($p -join ' | ')

    $modules = Join-Path $work 'Modules'
    [void](New-Item -ItemType Directory -Path "$modules\Local.Hello")
    [IO.File]::WriteAllText("$modules\Local.Hello\module.sh", "#!/bin/sh`necho hi`n")
    [IO.File]::WriteAllText("$modules\Local.Hello\module.json", '{ "Id": "Local.Hello", "Name": "Hello", "Category": "Local", "Description": "x", "Version": "1.0.0", "EntryPoint": "module.sh", "Runtime": "bash", "Platforms": ["Linux", "macOS"] }')
    $m = Get-TkModule -Path $modules
    Check 'Get-TkModule reports the runtime, unguarded dry-run profile and platforms' ($m.IsValid -and $m.Runtime -eq 'Bash' -and $m.External -and $m.DryRun.Mode -eq 'External' -and $m.DryRun.Caveats[0] -like '*nothing is guarded*' -and ($m.Platforms -join ',') -eq 'Linux,macOS') "$($m.Errors -join ' | ')"
    Check 'Get-TkRuntimeForFile maps extensions' ((Get-TkRuntimeForFile 'x.BAT') -eq 'Cmd' -and (Get-TkRuntimeForFile 'x.zsh') -eq 'Zsh' -and (Get-TkRuntimeForFile 'x.ps1') -eq 'PowerShell' -and -not (Get-TkRuntimeForFile 'x.rb')) ''
    $override = Get-TkRuntimeStatus Python -Settings ([pscustomobject]@{ Runtimes = [pscustomobject]@{ Python = [pscustomobject]@{ Path = 'C:\nowhere\python.exe' } } }) -Refresh
    Check 'A settings override that does not exist makes the runtime unavailable (no silent fallback)' (-not $override.Available -and $override.Reason -like '*not found*') $override.Reason
    [void](Get-TkRuntimeStatus Python -Refresh)
}
catch { Check 'Runtime suite runs without errors' $false "$($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)" }
finally {
    $worker.Dispose()
    if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }
