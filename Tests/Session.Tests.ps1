# Sign-in session suite: the policy that ends stale sign-ins (midnight, max age, idle, sleep, clock) and
# pins a session to one tenant. Connect-TkGraph / Connect-TkExchange run against fake Graph and Exchange
# modules generated below; PSModulePath is narrowed so the real modules (and a real sign-in) can't load.
# Run all suites with: .\Tools\Invoke-ToolkitTests.ps1
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }

$fakeRoot = Join-Path ([IO.Path]::GetTempPath()) ('tk-session-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path "$fakeRoot\Microsoft.Graph.Authentication", "$fakeRoot\ExchangeOnlineManagement" -Force | Out-Null
Set-Content -LiteralPath "$fakeRoot\Microsoft.Graph.Authentication\Microsoft.Graph.Authentication.psm1" -Encoding UTF8 -Value @'
$script:Context = $null
$script:Wam = $false
function Get-MgContext { $script:Context }
function Connect-MgGraph {
    [CmdletBinding()]
    param([string[]] $Scopes, [string] $TenantId, [string] $ClientId, [string] $CertificateThumbprint, [string] $ContextScope, [switch] $NoWelcome, [switch] $UseDeviceCode)
    $global:FakeGraphConnects.Add([pscustomobject]@{ Scopes = $Scopes; ContextScope = $ContextScope; WamDisabled = $script:Wam; ClientId = $ClientId; DeviceCode = [bool]$UseDeviceCode })
    if ($UseDeviceCode) {
        'To sign in, use a web browser to open the page ' + $env:FAKE_DEVICE_URL + ' and enter the code FAKE12345 to authenticate.'
        if ($env:FAKE_DEVICE_FAIL) { throw 'AADSTS50199: device code flow is blocked by policy' }
    }
    elseif ($env:FAKE_CONNECT_FAIL) { throw ('InteractiveBrowserCredential authentication failed: ' + $env:FAKE_CONNECT_FAIL) }
    $script:Context = [pscustomobject]@{ TenantId = $env:FAKE_GRAPH_TENANT; Scopes = $Scopes; Account = 'admin@contoso.example'
        AuthType = $(if ($CertificateThumbprint) { 'AppOnly' } else { 'Delegated' }); AppName = 'Contoso app' }
}
function Disconnect-MgGraph { [CmdletBinding()] param() if (-not $env:FAKE_STUCK) { $script:Context = $null } }
function Get-MgGraphOption { [pscustomobject]@{ DisableLoginByWAM = $script:Wam } }
function Set-MgGraphOption { [CmdletBinding()] param([bool] $DisableLoginByWAM) $script:Wam = $DisableLoginByWAM }
function Invoke-MgGraphRequest {
    [CmdletBinding()] param([string] $Method, [string] $Uri, [string] $OutputType)
    if (-not $env:FAKE_ORG_NAME) { throw 'Forbidden' }
    [pscustomobject]@{ value = @([pscustomobject]@{ id = $env:FAKE_GRAPH_TENANT; displayName = $env:FAKE_ORG_NAME }) }
}
'@
Set-Content -LiteralPath "$fakeRoot\ExchangeOnlineManagement\ExchangeOnlineManagement.psm1" -Encoding UTF8 -Value @'
$script:Connection = $null
function Get-ConnectionInformation { [CmdletBinding()] param() $script:Connection }
function Connect-ExchangeOnline {
    [CmdletBinding()] param([switch] $ShowBanner, [switch] $DisableWAM, [string] $AppId, [string] $CertificateThumbprint, [string] $Organization)
    $global:FakeExoConnects.Add([pscustomobject]@{ DisableWAM = [bool]$DisableWAM })
    $script:Connection = [pscustomobject]@{ State = 'Connected'; TenantID = [guid]$env:FAKE_EXO_TENANT; UserPrincipalName = 'admin@contoso.example' }
}
function Disconnect-ExchangeOnline { [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')] param() $script:Connection = $null }
function Get-OrganizationConfig { [CmdletBinding()] param() [pscustomobject]@{ DisplayName = 'Contoso Exchange' } }
'@
# Only the fakes and the built-in modules: the real Graph / Exchange modules must be unreachable.
$env:PSModulePath = "$fakeRoot;$PSHOME\Modules"
$global:FakeGraphConnects = New-Object System.Collections.Generic.List[object]
$global:FakeExoConnects = New-Object System.Collections.Generic.List[object]
$tenantA = '00000000-0000-0000-0000-00000000000a'
$tenantB = '00000000-0000-0000-0000-00000000000b'
$env:FAKE_GRAPH_TENANT = $tenantA
$env:FAKE_EXO_TENANT = $tenantA
$env:FAKE_ORG_NAME = 'Contoso Example'
$env:FAKE_STUCK = ''
$env:FAKE_CONNECT_FAIL = ''
$env:FAKE_DEVICE_FAIL = ''
$env:FAKE_DEVICE_URL = 'https://login.microsoft.com/device'

$global:TkSettings = $null
. "$Root\Core\Toolkit.Worker.ps1"
# Never open a browser or touch the clipboard from a test: record the call instead.
$global:FakeDeviceLogins = New-Object System.Collections.Generic.List[object]
function Open-TkDeviceLogin { param([string] $Url, [string] $Code) $global:FakeDeviceLogins.Add([pscustomobject]@{ Url = $Url; Code = $Code }) }
$global:InformationPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

function Reset-Fakes {
    $env:FAKE_GRAPH_TENANT = $tenantA; $env:FAKE_EXO_TENANT = $tenantA; $env:FAKE_ORG_NAME = 'Contoso Example'; $env:FAKE_STUCK = ''; $env:FAKE_CONNECT_FAIL = ''
    $env:FAKE_DEVICE_FAIL = ''; $env:FAKE_DEVICE_URL = 'https://login.microsoft.com/device'; $global:FakeDeviceLogins.Clear()
    $global:TkSettings = $null
    try { Disconnect-TkAll } catch { }
    $global:TkSignOutReason = ''
    $global:FakeGraphConnects.Clear(); $global:FakeExoConnects.Clear()
}
function Get-Error([scriptblock] $Script) { try { & $Script; '' } catch { $_.Exception.Message } }

try {
    #region Policy settings
    $p = Get-TkSessionPolicy
    Check 'Default policy: 8 hours, 60 idle minutes' ($p.MaxAgeHours -eq 8 -and $p.IdleMinutes -eq 60) ($p | ConvertTo-Json -Compress)
    $global:TkSettings = [pscustomobject]@{ Session = [pscustomobject]@{ MaxAgeHours = 4; IdleMinutes = 15 } }
    $p = Get-TkSessionPolicy
    Check 'settings.json Session values are used' ($p.MaxAgeHours -eq 4 -and $p.IdleMinutes -eq 15) ($p | ConvertTo-Json -Compress)
    foreach ($bad in 0, -1, 'abc', 2000) {
        $global:TkSettings = [pscustomobject]@{ Session = [pscustomobject]@{ MaxAgeHours = $bad; IdleMinutes = $bad } }
        $p = Get-TkSessionPolicy
        Check "Out-of-range setting '$bad' falls back to the defaults" ($p.MaxAgeHours -eq 8 -and $p.IdleMinutes -eq 60) ($p | ConvertTo-Json -Compress)
    }
    $global:TkSettings = $null
    #endregion

    #region Expiry rules (pure: time is a parameter)
    $policy = [pscustomobject]@{ MaxAgeHours = 8; IdleMinutes = 60 }
    $minute = [TimeSpan]::FromMinutes(1).Ticks
    $awake0 = [long]1000 * $minute
    function New-TestSession([datetime] $SignedIn, [datetime] $LastUsed = $SignedIn) {
        [pscustomobject]@{ TenantId = $tenantA; TenantName = 'x'; SignedIn = $SignedIn; LastUsed = $LastUsed; AwakeAtSignIn = $awake0 }
    }
    function Get-Expiry($Session, [datetime] $Now, [double] $AwakeMinutes) {
        Get-TkSessionExpiry -Session $Session -Now $Now -AwakeTime ($awake0 + [long]($AwakeMinutes * $minute)) -Policy $policy
    }
    $d = [datetime]'2026-10-13 10:00'

    $r = Get-Expiry (New-TestSession $d) $d.AddMinutes(30) 30
    Check 'A fresh session stays valid' (-not $r) $r
    $r = Get-TkSessionExpiry -Session $null -Policy $policy
    Check 'A connection without a session record is not trusted' ($r -match 'not made by this toolkit') $r
    $late = [datetime]'2026-10-13 23:50'
    $r = Get-Expiry (New-TestSession $late) $late.AddMinutes(15) 15
    Check 'Midnight ends the session (23:50 -> 00:05)' ($r -match 'new day') $r
    $r = Get-Expiry (New-TestSession $d $d.AddHours(7.95)) $d.AddHours(8) 480
    Check 'Max age (8 h) ends the session even while in use' ($r -match 'hour') $r
    $r = Get-Expiry (New-TestSession $d) $d.AddMinutes(61) 61
    Check 'Idle for more than 60 minutes ends the session' ($r -match 'idle') $r
    $r = Get-Expiry (New-TestSession $d $d.AddMinutes(30)) $d.AddMinutes(80) 80
    Check 'Use resets the idle timer' (-not $r) $r
    $r = Get-Expiry (New-TestSession $d $d.AddMinutes(20)) $d.AddMinutes(30) 10
    Check 'Sleep or hibernation (20 of 30 min asleep) ends the session' ($r -match 'asleep') $r
    $r = Get-Expiry (New-TestSession $d $d.AddMinutes(20)) $d.AddMinutes(30) 29.5
    Check 'Small clock drift (30 s) is not taken for sleep' (-not $r) $r
    $r = Get-Expiry (New-TestSession $d) $d.AddMinutes(-5) 1
    Check 'The clock going backwards ends the session' ($r -match 'clock') $r
    $r = Get-TkSessionExpiry -Session (New-TestSession $d) -Now $d.AddMinutes(5) -AwakeTime $null -Policy $policy
    Check 'Fails closed when sleep cannot be ruled out' ([bool]$r) $r
    Check 'The awake clock works on this machine' ((Get-TkAwakeTime) -gt 0) "awake=$(Get-TkAwakeTime)"
    $end = Get-TkSessionEnd -Session (New-TestSession $d) -Policy $policy
    Check 'Session end: sign-in at 10:00 ends at 18:00' ($end -eq $d.AddHours(8)) "$end"
    $end = Get-TkSessionEnd -Session (New-TestSession ([datetime]'2026-10-13 20:00')) -Policy $policy
    Check 'Session end: sign-in at 20:00 ends at midnight' ($end -eq [datetime]'2026-10-14 00:00') "$end"
    #endregion

    #region Connect through the fakes
    Check 'Test setup: the fake Graph module is the one that loads' ((Get-Module -ListAvailable Microsoft.Graph.Authentication).ModuleBase -like "$fakeRoot*") ''

    Reset-Fakes
    Connect-TkGraph -Scopes 'User.Read.All'
    $c = $global:FakeGraphConnects | Select-Object -Last 1
    Check 'Graph signs in with an in-memory token cache (ContextScope Process)' ($c.ContextScope -eq 'Process') ($c | ConvertTo-Json -Compress)
    Check 'Graph sign-in bypasses WAM, so the account picker appears' ($c.WamDisabled -eq $true) ($c | ConvertTo-Json -Compress)
    Check "The user's own WAM setting is put back afterwards" ((Get-MgGraphOption).DisableLoginByWAM -eq $false) ''
    Check 'User.Read is requested so the tenant name can be read' ($c.Scopes -contains 'User.Read' -and $c.Scopes -contains 'User.Read.All') ($c.Scopes -join ',')
    Check 'The session is pinned to the signed-in tenant, with its name' ($global:TkSession.TenantId -eq $tenantA -and $global:TkSession.TenantName -eq 'Contoso Example') ($global:TkSession | ConvertTo-Json -Compress)

    $global:TkSession.LastUsed = (Get-Date).AddMinutes(-5)
    $before = $global:FakeGraphConnects.Count
    Connect-TkGraph -Scopes 'User.Read.All'
    Check 'Within a valid session the connection is reused' ($global:FakeGraphConnects.Count -eq $before) "connects=$($global:FakeGraphConnects.Count)"
    Check 'Reuse counts as use (idle timer reset)' (((Get-Date) - $global:TkSession.LastUsed).TotalSeconds -lt 30) "$($global:TkSession.LastUsed)"

    Connect-TkExchange
    Check 'Exchange sign-in bypasses WAM (-DisableWAM)' (($global:FakeExoConnects | Select-Object -Last 1).DisableWAM) ''
    Check 'Exchange in the same tenant joins the session' ($global:TkSession.TenantId -eq $tenantA -and (Test-TkExchangeConnected)) ''

    $s = Get-TkConnectionStatus
    Check 'Connection status reports tenant name and ID' ($s.TenantId -eq $tenantA -and $s.TenantName -eq 'Contoso Example' -and $s.SessionEnd -and -not $s.SignOutReason) ($s | ConvertTo-Json -Compress)
    #endregion

    #region Tenant pinning
    Reset-Fakes
    Connect-TkGraph
    $env:FAKE_EXO_TENANT = $tenantB
    $err = Get-Error { Connect-TkExchange }
    Check 'Exchange signing in to another tenant is refused' ($err -match 'another|but this session is for') $err
    Check '...and everything is signed out' (-not (Test-TkGraphConnected) -and -not (Test-TkExchangeConnected) -and -not $global:TkSession) ''
    $s = Get-TkConnectionStatus
    Check '...and the GUI is told why, once' ($s.SignOutReason -match 'tenant' -and -not (Get-TkConnectionStatus).SignOutReason) $s.SignOutReason

    Reset-Fakes
    Connect-TkGraph
    $env:FAKE_GRAPH_TENANT = $tenantB
    Connect-MgGraph -Scopes 'User.Read'       # a script connecting on its own
    Confirm-TkSession
    Check 'A connection moved to another tenant by a script is signed out' (-not (Test-TkGraphConnected) -and $global:TkSignOutReason -match 'another tenant') $global:TkSignOutReason

    Reset-Fakes
    $env:FAKE_GRAPH_TENANT = 'not-a-guid'
    $err = Get-Error { Connect-TkGraph }
    Check 'A sign-in whose tenant cannot be read is refused and signed out' ($err -match 'could not be confirmed' -and -not (Test-TkGraphConnected)) $err

    Reset-Fakes
    $env:FAKE_ORG_NAME = ''
    Connect-TkGraph
    Check 'Without permission for the name, the ID is still known' ($global:TkSession.TenantId -eq $tenantA -and -not $global:TkSession.TenantName) ''
    Connect-TkExchange
    Check 'The name is then read from Exchange Online' ($global:TkSession.TenantName -eq 'Contoso Exchange') $global:TkSession.TenantName
    #endregion

    #region Stale sessions are ended before use
    Reset-Fakes
    Connect-TkGraph
    $global:TkSession.SignedIn = $global:TkSession.SignedIn.AddDays(-1)
    $global:TkSession.LastUsed = $global:TkSession.SignedIn
    $before = $global:FakeGraphConnects.Count
    Connect-TkGraph
    Check "Yesterday's sign-in is not reused: a new sign-in is made" ($global:FakeGraphConnects.Count -eq $before + 1 -and $global:TkSignOutReason -match 'new day') "connects=$($global:FakeGraphConnects.Count) reason=$global:TkSignOutReason"
    Check '...and the new session starts now' (((Get-Date) - $global:TkSession.SignedIn).TotalSeconds -lt 30) ''

    Reset-Fakes
    Connect-TkGraph
    $global:TkSession.AwakeAtSignIn += 10 * $minute     # 10 minutes less awake time than wall-clock time
    Confirm-TkSession
    Check 'A sign-in from before the PC slept is signed out' (-not (Test-TkGraphConnected) -and $global:TkSignOutReason -match 'asleep') $global:TkSignOutReason

    Reset-Fakes
    Connect-TkGraph
    $global:TkSession = $null       # e.g. inherited from an earlier launch in the same process
    Confirm-TkSession
    Check 'A connection this toolkit session did not make is signed out' (-not (Test-TkGraphConnected) -and $global:TkSignOutReason -match 'not made by this toolkit') $global:TkSignOutReason

    Reset-Fakes
    Connect-TkGraph
    $global:TkSession.LastUsed = (Get-Date).AddMinutes(-61)
    $probe = Join-Path $fakeRoot 'probe.ps1'
    Set-Content -LiteralPath $probe -Value '[pscustomobject]@{ GraphConnected = [bool](Get-MgContext) }' -Encoding UTF8
    $out = Invoke-TkModule -EntryPath $probe -Requires ([pscustomobject]@{ ExchangeOnline = $false; GraphScopes = [string[]]@() })
    Check 'A module that declares no connection cannot use a stale one' ($out.GraphConnected -eq $false) ($out | ConvertTo-Json -Compress)

    Reset-Fakes
    $global:TkSettings = [pscustomobject]@{ Graph = [pscustomobject]@{ TenantId = $tenantA; ClientId = '11111111-1111-1111-1111-111111111111'; CertificateThumbprint = 'ABCDEF' } }
    Connect-TkGraph
    Check 'App-only sign-in also uses an in-memory token cache' (($global:FakeGraphConnects | Select-Object -Last 1).ContextScope -eq 'Process' -and $global:TkSession.TenantId -eq $tenantA) ''

    Reset-Fakes
    $global:TkSettings = [pscustomobject]@{ Graph = [pscustomobject]@{ ClientId = '22222222-2222-2222-2222-222222222222' } }
    Connect-TkGraph -Scopes 'User.Read.All'
    $c = $global:FakeGraphConnects | Select-Object -Last 1
    Check 'A ClientId without a certificate signs in interactively with that app' ($c.ClientId -eq '22222222-2222-2222-2222-222222222222' -and (Get-MgContext).AuthType -eq 'Delegated') ($c | ConvertTo-Json -Compress)
    Check '...still bypassing WAM, with an in-memory token cache' ($c.WamDisabled -eq $true -and $c.ContextScope -eq 'Process' -and (Get-MgGraphOption).DisableLoginByWAM -eq $false) ($c | ConvertTo-Json -Compress)
    Check '...and pinned to the signed-in tenant' ($global:TkSession.TenantId -eq $tenantA) ''

    Reset-Fakes
    $env:FAKE_CONNECT_FAIL = ' '
    Connect-TkGraph -Scopes 'User.Read.All'
    $c = $global:FakeGraphConnects | Select-Object -Last 1
    Check 'When WAM sign-in fails, sign-in with a code takes over (no app needed)' ($global:FakeGraphConnects.Count -eq 2 -and $c.DeviceCode -and -not $c.ClientId -and (Test-TkGraphConnected)) ($global:FakeGraphConnects | ConvertTo-Json -Compress)
    Check '...with the same scopes and an in-memory token cache' ($c.ContextScope -eq 'Process' -and $c.Scopes -contains 'User.Read.All') ($c | ConvertTo-Json -Compress)
    Check '...opening the device page with the code' ($global:FakeDeviceLogins.Count -eq 1 -and $global:FakeDeviceLogins[0].Url -eq 'https://login.microsoft.com/device' -and $global:FakeDeviceLogins[0].Code -eq 'FAKE12345') ($global:FakeDeviceLogins | ConvertTo-Json -Compress)
    Check '...still pinned to the signed-in tenant' ($global:TkSession.TenantId -eq $tenantA) ''
    Check "...and the user's own WAM setting is put back" ((Get-MgGraphOption).DisableLoginByWAM -eq $false) ''

    Reset-Fakes
    $env:FAKE_CONNECT_FAIL = ' '
    $env:FAKE_DEVICE_URL = 'https://contoso.example/device'
    Connect-TkGraph
    Check 'A sign-in page that is not Microsoft''s is never opened' ($global:FakeDeviceLogins.Count -eq 0) ($global:FakeDeviceLogins | ConvertTo-Json -Compress)

    Reset-Fakes
    $env:FAKE_CONNECT_FAIL = 'User canceled authentication'
    $err = Get-Error { Connect-TkGraph }
    Check 'A cancelled sign-in is not retried with a code' ($err -match 'cancel' -and $global:FakeGraphConnects.Count -eq 1 -and -not $global:TkSession) $err

    Reset-Fakes
    $env:FAKE_CONNECT_FAIL = ' '
    $env:FAKE_DEVICE_FAIL = '1'
    $err = Get-Error { Connect-TkGraph }
    Check 'If sign-in with a code is blocked too, the error says what to do' ($err -match 'device code' -and -not (Test-TkGraphConnected) -and -not $global:TkSession) $err
    Check "...and the user's own WAM setting is still put back" ((Get-MgGraphOption).DisableLoginByWAM -eq $false) ''

    Reset-Fakes
    $global:TkSettings = [pscustomobject]@{ Graph = [pscustomobject]@{ ClientId = '22222222-2222-2222-2222-222222222222' } }
    $env:FAKE_CONNECT_FAIL = ' '
    $err = Get-Error { Connect-TkGraph }
    Check 'With an own app, a failed browser sign-in is reported as is' ($err -match 'InteractiveBrowserCredential' -and $global:FakeGraphConnects.Count -eq 1) $err

    Reset-Fakes
    Connect-TkGraph
    $env:FAKE_STUCK = '1'
    $err = Get-Error { Disconnect-TkAll }
    Check 'Disconnect fails closed when the sign-out does not take' ($err -match 'Could not sign out' -and -not $global:TkSession) $err
    $env:FAKE_STUCK = ''
    #endregion

    #region Editing the limits from Settings (Core) and applying them (worker)
    Import-Module "$Root\Core\Toolkit.Core.psm1" -Force
    $l = Get-TkSessionLimit -Settings $null
    Check 'Settings shows the defaults without settings.json' ($l.MaxAgeHours -eq 8 -and $l.IdleMinutes -eq 60) ($l | ConvertTo-Json -Compress)
    $l = Get-TkSessionLimit -Settings ([pscustomobject]@{ Session = [pscustomobject]@{ MaxAgeHours = 30; IdleMinutes = 20 } })
    Check 'Settings shows what the worker enforces (bad hours -> default, good minutes kept)' ($l.MaxAgeHours -eq 8 -and $l.IdleMinutes -eq 20) ($l | ConvertTo-Json -Compress)

    $t = Test-TkSessionLimit -MaxAgeHours ' 4 ' -IdleMinutes '15'
    Check 'Valid input is accepted' (-not $t.Problems.Count -and $t.MaxAgeHours -eq 4 -and $t.IdleMinutes -eq 15) ($t | ConvertTo-Json -Compress)
    foreach ($bad in @(@('0', '15'), @('25', '15'), @('2.5', '15'), @('4', '0'), @('4', '1441'), @('x', ''))) {
        $t = Test-TkSessionLimit -MaxAgeHours $bad[0] -IdleMinutes $bad[1]
        Check "Invalid input is refused: hours '$($bad[0])', minutes '$($bad[1])'" ($t.Problems.Count -gt 0) ($t.Problems -join ' ')
    }

    $file = Join-Path $fakeRoot 'Config\settings.json'
    Save-TkSessionLimit -Path $file -MaxAgeHours 4 -IdleMinutes 15
    $saved = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    Check 'Saving creates settings.json when there is none' ($saved.Session.MaxAgeHours -eq 4 -and $saved.Session.IdleMinutes -eq 15) ''
    Set-Content -LiteralPath $file -Encoding UTF8 -Value '{ "Graph": { "TenantId": "t", "ClientId": "c", "CertificateThumbprint": "x" }, "Session": { "_comment": "keep me", "MaxAgeHours": 8, "IdleMinutes": 60 } }'
    Save-TkSessionLimit -Path $file -MaxAgeHours 6 -IdleMinutes 30
    $saved = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    Check 'Saving keeps every other setting' ($saved.Graph.ClientId -eq 'c' -and $saved.Session._comment -eq 'keep me' -and $saved.Session.MaxAgeHours -eq 6 -and $saved.Session.IdleMinutes -eq 30) ($saved | ConvertTo-Json -Compress -Depth 5)
    Set-Content -LiteralPath $file -Encoding UTF8 -Value '{ "Graph": { broken'
    $err = Get-Error { Save-TkSessionLimit -Path $file -MaxAgeHours 6 -IdleMinutes 30 }
    Check 'An unreadable settings.json is left alone, not overwritten' ($err -match 'left unchanged' -and (Get-Content -LiteralPath $file -Raw) -match 'broken') $err

    $global:TkSettings = $null
    Set-TkSessionLimit -MaxAgeHours 2 -IdleMinutes 10
    $p = Get-TkSessionPolicy
    Check 'Saved limits apply to the running worker at once' ($p.MaxAgeHours -eq 2 -and $p.IdleMinutes -eq 10) ($p | ConvertTo-Json -Compress)
    Reset-Fakes
    Connect-TkGraph
    $global:TkSession.LastUsed = (Get-Date).AddMinutes(-20)
    $global:TkSettings = $null
    Set-TkSessionLimit -MaxAgeHours 8 -IdleMinutes 15
    Confirm-TkSession
    Check 'Tightening the idle limit ends a session that is now over it' (-not (Test-TkGraphConnected) -and $global:TkSignOutReason -match 'idle') $global:TkSignOutReason
    #endregion
}
catch { Check 'Suite ran to the end' $false $_.Exception.Message }
finally {
    try { Disconnect-TkAll } catch { }
    Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Output
$failed = @($results | Where-Object Result -eq 'FAIL').Count
Write-Output ("{0} passed, {1} failed" -f ($results.Count - $failed), $failed)
if ($failed) { exit 1 }
