[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateRange(1, 3650)] [int] $InactiveDays,
    [bool] $IncludeNeverSignedIn = $true
)

# Uses Invoke-MgGraphRequest so only Microsoft.Graph.Authentication is required.
$cutoff = (Get-Date).ToUniversalTime().AddDays(-$InactiveDays)
$filter = [uri]::EscapeDataString("userType eq 'Guest'")
$select = 'id,displayName,mail,userPrincipalName,createdDateTime,accountEnabled,externalUserState,signInActivity'
$uri = "v1.0/users?`$filter=$filter&`$select=$select"

function ConvertTo-UtcDate($Value) {
    if (-not $Value) { return $null }
    ([datetime]$Value).ToUniversalTime()
}

Write-Information "Looking for guests inactive since $($cutoff.ToString('yyyy-MM-dd'))..."
$scanned = 0
$stale = 0
$neverSkipped = 0   # never signed in, but IncludeNeverSignedIn is off: not judged either way

while ($uri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    foreach ($guest in $page.value) {
        $scanned++
        $activity = $guest.signInActivity
        $interactive = if ($activity) { ConvertTo-UtcDate $activity.lastSignInDateTime } else { $null }
        $nonInteractive = if ($activity) { ConvertTo-UtcDate $activity.lastNonInteractiveSignInDateTime } else { $null }
        $lastSignIn = @($interactive, $nonInteractive) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1

        $isStale = if ($lastSignIn) { $lastSignIn -lt $cutoff } else { $IncludeNeverSignedIn }
        if (-not $lastSignIn -and -not $IncludeNeverSignedIn) { $neverSkipped++ }
        if (-not $isStale) { continue }
        $stale++

        [pscustomobject]@{
            DisplayName       = $guest.displayName
            Mail              = $guest.mail
            UserPrincipalName = $guest.userPrincipalName
            InvitationState   = $guest.externalUserState
            AccountEnabled    = $guest.accountEnabled
            Created           = ConvertTo-UtcDate $guest.createdDateTime
            LastSignInUtc     = $lastSignIn
            DaysInactive      = if ($lastSignIn) { [int]((Get-Date).ToUniversalTime() - $lastSignIn).TotalDays } else { $null }
            Id                = $guest.id
        }
    }
    $uri = $page.'@odata.nextLink'
    Write-Information "Scanned $scanned guest(s)..."
}

Write-Information "Done. Scanned $scanned guest account(s), $stale stale."

# Tenant readiness: guests that are active, out of every guest that was judged.
$judged = $scanned - $neverSkipped
if ($judged -gt 0 -and (Test-Path Function:\Write-TkReadiness)) {
    Write-TkReadiness -Ready ($judged - $stale) -Total $judged -NotEvaluated $neverSkipped -Label "guests signed in within $InactiveDays days"
}
