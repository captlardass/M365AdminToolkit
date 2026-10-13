# Change-guard test suite: runs module scripts through the real worker (Core\Toolkit.Worker.ps1)
# against fake Graph/Exchange modules and checks, via a probe log, that nothing slips through.
# Run all suites with: .\Tools\Invoke-ToolkitTests.ps1
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$Fixtures = Join-Path $PSScriptRoot 'Fixtures'
$Proto = Join-Path ([IO.Path]::GetTempPath()) ('tk-guard-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Proto -Force | Out-Null
Import-Module "$Root\Core\Toolkit.Core.psm1" -Force
$env:TK_PROBE_LOG = "$Proto\probe.log"
$worker = New-TkWorker -HelperScript "$Root\Core\Toolkit.Worker.ps1" -Settings $null

# Load the fake M365 modules into the worker, like a real connection would.
$init = [powershell]::Create(); $init.Runspace = $worker
[void]$init.AddScript("Import-Module '$Fixtures\Microsoft.Graph.FakeUsers.psm1'; Import-Module '$Fixtures\tmpEXO_fake01.psm1'").Invoke()
$init.Dispose()

$results = New-Object System.Collections.Generic.List[object]
$noConnections = [pscustomobject]@{ ExchangeOnline = $false; GraphScopes = [string[]]@() }

function Invoke-Probe {
    param([string] $Name, [string] $Script, [string] $Guard, [hashtable] $Parameters = @{}, [int] $StopAfterMs = 0)
    Set-Content -LiteralPath $env:TK_PROBE_LOG -Value $null
    $file = "$Proto\case.ps1"
    Set-Content -LiteralPath $file -Value $Script -Encoding UTF8
    $job = Start-TkJob -Runspace $worker -Name $Name -Parameters @{ E = $file; R = $noConnections; P = $Parameters; G = $Guard } -ScriptBlock {
        param($E, $R, $P, $G) Invoke-TkModule -EntryPath $E -Requires $R -Parameters $P -Guard $G
    }
    if ($StopAfterMs) { Start-Sleep -Milliseconds $StopAfterMs; Stop-TkJob $job }
    $log = @()
    while ($true) { $done = $job.Handle.IsCompleted; $r = Receive-TkJob $job; $log += $r.Log; if ($done) { break }; Start-Sleep -Milliseconds 50 }
    $blocked = $job.Blocked.ToArray()
    $end = Complete-TkJob $job
    [pscustomobject]@{
        State    = $end.State
        Failure  = $end.Failure
        Output   = $job.Collected.ToArray()
        Blocked  = $blocked
        Executed = @(Get-Content -LiteralPath $env:TK_PROBE_LOG | Where-Object { $_ })
        Errors   = @($log | Where-Object Level -eq 'ERROR' | ForEach-Object Message)
    }
}

function Check {
    param([string] $Case, [bool] $Condition, [string] $Detail = '')
    $results.Add([pscustomobject]@{ Result = if ($Condition) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail })
}

# 1. Every way of calling a Graph write command is blocked in a dry run.
$r = Invoke-Probe 'graph-writes' -Guard DryRun -Script @'
Update-MgFakeUser -Id u1 -Department IT
$splat = @{ Id = 'u2'; Department = 'HR' }; Update-MgFakeUser @splat
Get-MgFakeUser | Update-MgFakeUser -Department X
Set-Alias upd Update-MgFakeUser; upd -Id u3
Microsoft.Graph.FakeUsers\Update-MgFakeUser -Id u4
$new = New-MgFakeUser -DisplayName 'Dummy'
"read count: $(@(Get-MgFakeUser).Count)"
'@
Check 'Graph writes blocked (direct, splat, pipeline x2, alias, qualified, New-)' ($r.Executed.Count -eq 0 -and $r.Blocked.Count -eq 7) "blocked=$($r.Blocked.Count) executed=$($r.Executed -join ';') errors=$($r.Errors -join ' / ')"
Check 'Graph reads still work in dry run' ($r.Output -contains 'read count: 2') ($r.Output -join ';')
Check 'Blocked entries carry command + target' (@($r.Blocked | Where-Object { $_.Command -eq 'Update-MgFakeUser' -and $_.Target -eq 'u1' }).Count -eq 1) (($r.Blocked | ForEach-Object { "$($_.Command)->$($_.Target)" }) -join '; ')
Check 'Piped input recorded per item' (@($r.Blocked | Where-Object Target -like 'user*').Count -eq 2) ''

# 2. Exchange: writes blocked, reads work even though they use a private 'New-' helper.
$r = Invoke-Probe 'exo' -Guard DryRun -Script @'
Set-Mailbox -Identity shared1@contoso.example -MessageCopyForSentAsEnabled:$true
Get-Mailbox -Identity shared2@contoso.example | Set-Mailbox -MessageCopyForSentAsEnabled $true
(Get-Mailbox -Identity shared3@contoso.example).Ctx
'@
Check 'Exchange writes blocked (direct + piped)' ($r.Executed.Count -eq 0 -and $r.Blocked.Count -eq 2) "blocked=$($r.Blocked.Count) executed=$($r.Executed -join ';') errors=$($r.Errors -join ' / ')"
Check 'Exchange reads with internal helpers work' ($r.Output -contains 'ok') ($r.Output -join ';')

# 3. Local side effects: skipped by WhatIfPreference in dry run; script-defined functions still run.
$tmpFile = "$Proto\dryrun-local.txt"; Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue
$r = Invoke-Probe 'local' -Guard DryRun -Script @"
function Set-LocalThing { 'local function ran' }
Set-LocalThing
Set-Content -LiteralPath '$tmpFile' -Value 'should not exist'
"@
Check 'Script-defined write-verb function allowed' ($r.Output -contains 'local function ran') ($r.Output -join ';')
Check 'Local report files are still written in a dry run (only M365 is guarded)' (Test-Path -LiteralPath $tmpFile) ''

# 4. REST: reads pass through, writes are blocked. No network needed: a pass-through GET fails to
#    connect (proving it was really sent), a blocked call produces no error at all.
$r = Invoke-Probe 'rest' -Guard DryRun -Script @'
try { Invoke-RestMethod -Uri 'http://127.0.0.1:9/read' -TimeoutSec 2 } catch { 'GET passed through' }
try { Invoke-RestMethod 'http://127.0.0.1:9/read2' -TimeoutSec 2 -UseBasicParsing:$false } catch { 'positional GET passed through' }
Invoke-RestMethod -Uri 'http://127.0.0.1:9/hook' -Method Post -Body '{}'
Invoke-WebRequest -Uri 'http://127.0.0.1:9/x' -Method Delete -UseBasicParsing
irm -Uri 'http://127.0.0.1:9/alias' -Method Put
try { Invoke-MgGraphRequest -Method GET -Uri 'v1.0/users' } catch { 'graph GET passed through' }
Invoke-MgGraphRequest -Method PATCH -Uri 'v1.0/users/1' -Body @{ department = 'IT' }
Invoke-MgGraphRequest -Uri 'v1.0/groups/1/members/$ref' -Method:POST -Body @{}
try { Invoke-MgGraphRequest -Method POST -Uri 'v1.0/directoryObjects/getByIds' -Body @{ ids = @('1') } } catch { 'read-only POST passed through' }
try { Invoke-MgGraphRequest -Method POST -Uri 'v1.0/$batch' -Body @{ requests = @(@{ id = '1'; method = 'GET'; url = '/me' }) } } catch { 'GET batch passed through' }
Invoke-MgGraphRequest -Method POST -Uri 'v1.0/$batch' -Body @{ requests = @(@{ id = '1'; method = 'GET'; url = '/me' }, @{ id = '2'; method = 'DELETE'; url = '/users/1' }) }
Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/$batch' -Body '{"requests":[{"id":"1","method":"PATCH","url":"/me"}]}'
'@
$expectPass = 'GET passed through', 'positional GET passed through', 'graph GET passed through', 'read-only POST passed through', 'GET batch passed through'
$missing = @($expectPass | Where-Object { $r.Output -notcontains $_ })
Check 'REST reads pass through (IRM, positional, Graph GET, getByIds, GET-only batch)' ($missing.Count -eq 0) "missing: $($missing -join ', ')"
Check 'REST writes blocked (POST, DELETE, alias PUT, PATCH, $ref POST, mixed batch, JSON batch)' ($r.Blocked.Count -eq 7) (($r.Blocked | ForEach-Object Target) -join ' | ')
Check 'No errors from blocked REST calls' ($r.Errors.Count -eq 0) ($r.Errors -join ' | ')

# 5. Guard is switched off after the run: the same write executes in a normal run.
$r = Invoke-Probe 'off' -Guard Off -Script 'Update-MgFakeUser -Id REAL'
Check 'Normal run executes writes (guard removed afterwards)' ($r.Executed -contains 'EXECUTED Update-MgFakeUser REAL ' -and $r.Blocked.Count -eq 0) ($r.Executed -join ';')

# 6. Read-only real run: writes blocked, local work allowed.
$roFile = "$Proto\readonly-local.txt"; Remove-Item -LiteralPath $roFile -ErrorAction SilentlyContinue
$r = Invoke-Probe 'readonly' -Guard ReadOnly -Script @"
Set-Content -LiteralPath '$roFile' -Value 'report'
Update-MgFakeUser -Id sneaky
(Get-MgFakeUser).Count
"@
Check 'Read-only run blocks M365 writes' ($r.Executed.Count -eq 0 -and $r.Blocked.Count -eq 1 -and $r.Blocked[0].Mode -eq 'ReadOnly') "blocked=$($r.Blocked.Count)"
Check 'Read-only run allows local files and reads' ((Test-Path -LiteralPath $roFile) -and $r.Output -contains 2) ''

# 7. A failing dry run still removes the guard.
$r = Invoke-Probe 'throws' -Guard DryRun -Script "Update-MgFakeUser -Id x; throw 'boom'"
Check 'Dry run that throws reports failure' ($r.State -eq 'Failed' -and $r.Failure -like '*boom*') "$($r.State) $($r.Failure)"
$r = Invoke-Probe 'after-throw' -Guard Off -Script 'Update-MgFakeUser -Id AFTERTHROW'
Check 'Guard removed after a failing dry run' ($r.Executed.Count -eq 1) ($r.Executed -join ';')

# 8. A cancelled dry run still removes the guard.
$r = Invoke-Probe 'cancel' -Guard DryRun -StopAfterMs 700 -Script '1..50 | ForEach-Object { Update-MgFakeUser -Id "c$_"; Start-Sleep -Milliseconds 100 }'
Check 'Cancelled dry run stops and blocked everything' ($r.State -eq 'Stopped' -and $r.Executed.Count -eq 0) "$($r.State) executed=$($r.Executed.Count)"
$r = Invoke-Probe 'after-cancel' -Guard Off -Script 'Update-MgFakeUser -Id AFTERCANCEL'
Check 'Guard removed after a cancelled dry run' ($r.Executed.Count -eq 1) ($r.Executed -join ';')

# 9. Dot-sourced helper scripts are guarded too.
Set-Content -LiteralPath "$Proto\helper.ps1" -Value 'function Invoke-Helper { Update-MgFakeUser -Id fromhelper }'
$r = Invoke-Probe 'dotsource' -Guard DryRun -Script ". '$Proto\helper.ps1'; Invoke-Helper"
Check 'Writes inside dot-sourced helpers blocked' ($r.Executed.Count -eq 0 -and $r.Blocked.Count -eq 1) "blocked=$($r.Blocked.Count)"

# 10. Native WhatIf module (the real Demo) - its own ShouldProcess reports, nothing blocked.
$demo = Get-TkModule -Path "$Root\Modules" | Where-Object Id -eq 'Demo.SelfTest'
$r = Invoke-Probe 'native' -Guard DryRun -Script (Get-Content $demo.EntryPath -Raw) -Parameters @{ Count = 2; WhatIf = $true; EmitWarning = $false }
Check 'Native WhatIf module: rows report WhatIf' (@($r.Output | Where-Object Action -eq 'WhatIf').Count -eq 2) (($r.Output | ForEach-Object Action) -join ',')

# 11. Documented gap: invoking through a CommandInfo object skips lookup (static profile must flag it).
$r = Invoke-Probe 'gap' -Guard DryRun -Script '& (Get-Command Update-MgFakeUser) -Id VIAGETCOMMAND'
$profileFile = "$Proto\gap.ps1"; Set-Content $profileFile '& (Get-Command Update-MgFakeUser) -Id x; Start-Process notepad; $c = New-Object System.Net.WebClient; Stop-Service Spooler'
$gap = Get-TkDryRunProfile -Path $profileFile -SupportsWhatIf $false
Check 'Known gap (Get-Command invoke) is flagged by the static profile' ($gap.Caveats.Count -eq 4) ($gap.Caveats -join ' | ')
"(info) Get-Command bypass executed: $($r.Executed.Count) - documented limitation"

# 12. Overhead: 2000 guarded read calls.
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Probe 'perf' -Guard DryRun -Script '1..2000 | ForEach-Object { $null = Get-MgFakeUser -UserId $_ }; "done"'
$sw.Stop()
$sw2 = [Diagnostics.Stopwatch]::StartNew()
$r2 = Invoke-Probe 'perf-off' -Guard Off -Script '1..2000 | ForEach-Object { $null = Get-MgFakeUser -UserId $_ }; "done"'
$sw2.Stop()
Check 'Guard overhead acceptable (<3x on 2000 calls)' ($sw.ElapsedMilliseconds -lt [Math]::Max(3 * $sw2.ElapsedMilliseconds, 1500)) "guarded=$($sw.ElapsedMilliseconds)ms unguarded=$($sw2.ElapsedMilliseconds)ms"

# 13. Real Microsoft.Graph.Authentication aliases and local-only settings.
$r = Invoke-Probe 'graph-aliases' -Guard DryRun -Script @'
try { Invoke-GraphRequest -Method GET -Uri 'v1.0/me' } catch { 'alias GET passed through' }
Invoke-MgRestMethod -Method DELETE -Uri 'v1.0/users/1'
Set-MgRequestContext -MaxRetry 3 | Out-Null
'local setting ok'
'@
Check 'Graph request aliases: GET passes, DELETE blocked' ($r.Output -contains 'alias GET passed through' -and $r.Blocked.Count -eq 1 -and $r.Blocked[0].Target -eq 'DELETE v1.0/users/1') (($r.Blocked | ForEach-Object Target) -join ' | ')
Check 'Local-only Graph settings (Set-MgRequestContext) allowed' ($r.Output -contains 'local setting ok' -and $r.Errors.Count -eq 0) ($r.Errors -join ' / ')

# 14. Exchange Online v3 sends classic cmdlets (Get-MailboxFolderStatistics...) as POST .../InvokeCommand,
#     shaped like the generated tmpEXO module does. Only Get-* with matching header and body is a read.
$r = Invoke-Probe 'exo-rest' -Guard ReadOnly -Script @'
$base = 'http://127.0.0.1:9/adminapi/beta/00000000-0000-0000-0000-000000000000'
# Leading comma: return the byte[] itself, as EXO passes it, not unrolled into object[].
function Get-ExoBody([string] $Cmdlet) { , [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ CmdletInput = @{ CmdletName = $Cmdlet; Parameters = @{ Identity = 'shared1@contoso.example' } } } -Depth 5 -Compress)) }
function Get-ExoBatch([string[]] $Cmdlets) {
    $requests = foreach ($c in $Cmdlets) { @{ id = $c; method = 'POST'; url = "$base/InvokeCommand"; headers = @{ 'X-CmdletName' = $c }; body = @{ CmdletInput = @{ CmdletName = $c; Parameters = @{} } } } }
    , [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ requests = @($requests) } -Depth 10))
}
try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Method 'POST' -Headers @{ 'X-CmdletName' = 'Get-MailboxFolderStatistics' } -Body (Get-ExoBody 'Get-MailboxFolderStatistics') -Uri "$base/InvokeCommand" } catch { 'exo get passed through' }
try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Method 'POST' -Headers @{ 'X-CmdletName' = 'Get-DistributionGroupMember' } -Body '{"CmdletInput":{"CmdletName":"Get-DistributionGroupMember","Parameters":{}}}' -Uri "$base/InvokeCommand?`$skiptoken=abc" } catch { 'exo string-body paged get passed through' }
try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Method 'POST' -Headers @{ 'X-CmdletName' = 'Get-Mailbox' } -Body (Get-ExoBatch 'Get-Mailbox', 'Get-MailboxFolderPermission') -Uri "$base/`$batch" } catch { 'exo get batch passed through' }
Invoke-WebRequest -UseBasicParsing -Method 'POST' -Headers @{ 'X-CmdletName' = 'Set-Mailbox' } -Body (Get-ExoBody 'Set-Mailbox') -Uri "$base/InvokeCommand"
Invoke-WebRequest -UseBasicParsing -Method 'POST' -Headers @{ 'X-CmdletName' = 'Get-Mailbox' } -Body (Get-ExoBody 'Set-Mailbox') -Uri "$base/InvokeCommand"
Invoke-WebRequest -UseBasicParsing -Method 'POST' -Headers @{ 'X-CmdletName' = 'Set-Mailbox' } -Body (Get-ExoBody 'Get-Mailbox') -Uri "$base/InvokeCommand"
Invoke-WebRequest -UseBasicParsing -Method 'POST' -Body (Get-ExoBody 'Get-Mailbox') -Uri "$base/InvokeCommand"
Invoke-WebRequest -UseBasicParsing -Method 'POST' -Headers @{ 'X-CmdletName' = 'Get-Mailbox' } -Body 'not json' -Uri "$base/InvokeCommand"
Invoke-WebRequest -UseBasicParsing -Method 'POST' -Headers @{ 'X-CmdletName' = 'Get-Mailbox' } -Body (Get-ExoBody 'Get-Mailbox') -Uri 'http://127.0.0.1:9/api/somethingElse'
Invoke-WebRequest -UseBasicParsing -Method 'POST' -Headers @{ 'X-CmdletName' = 'Get-Mailbox' } -Body (Get-ExoBatch 'Get-Mailbox', 'Remove-MailboxPermission') -Uri "$base/`$batch"
Invoke-WebRequest -UseBasicParsing -Method 'POST' -Headers @{ 'X-CmdletName' = 'Get-Mailbox; Set-Mailbox' } -Body (Get-ExoBody 'Get-Mailbox; Set-Mailbox') -Uri "$base/InvokeCommand"
'@
$expectPass = 'exo get passed through', 'exo string-body paged get passed through', 'exo get batch passed through'
$missing = @($expectPass | Where-Object { $r.Output -notcontains $_ })
Check 'EXO Get-* InvokeCommand passes (bytes, string + paging, batch)' ($missing.Count -eq 0) "missing: $($missing -join ', ')"
Check 'EXO non-Get or spoofed InvokeCommand blocked (Set, header/body mismatch x2, no header, bad JSON, other path, mixed batch, injection)' ($r.Blocked.Count -eq 8) (($r.Blocked | ForEach-Object Target) -join ' | ')

# 15. The REST proxy re-splats arguments; an array value (EXO's byte[] body) must not be unrolled.
$r = Invoke-Probe 'arg-types' -Guard Off -Script @'
$call = ConvertTo-TkCallArgument -Command (Get-Command Invoke-WebRequest) -Arguments @('-Method', 'POST', '-Body', ([byte[]](1, 2, 3)), '-Uri', 'http://127.0.0.1:9/')
'{0} {1}' -f $call.Named['Body'].GetType().Name, $call.Named['Body'].Count
'@
Check 'Proxied arguments keep their type (byte[] body reaches the real cmdlet intact)' ($r.Output -contains 'Byte[] 3') ($r.Output -join ';')

$worker.Dispose()
$results | Format-Table -AutoSize -Wrap | Out-String -Width 220
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }






