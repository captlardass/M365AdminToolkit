[CmdletBinding()]
param(
    [bool] $IncludeAllPlatforms = $false
)

# Uses Invoke-MgGraphRequest so only Microsoft.Graph.Authentication is required.
# Intune has no purchase date: EntraRegisteredDate and EnrolledDate are the closest match, but they reset when a
# device is re-joined to Entra or wiped and re-enrolled.
$select = 'id,deviceName,serialNumber,manufacturer,model,operatingSystem,osVersion,userPrincipalName,userDisplayName,' +
    'enrolledDateTime,lastSyncDateTime,managedDeviceOwnerType,complianceState,totalStorageSpaceInBytes,azureADDeviceId'
$uri = "v1.0/deviceManagement/managedDevices?`$select=$select"

# Graph returns 0001-01-01 for dates that were never set.
function ConvertTo-LocalDate($Value) {
    if (-not $Value) { return $null }
    $date = [datetime]$Value
    if ($date.Year -le 1) { return $null }
    $date.ToLocalTime()
}

Write-Information 'Fetching managed devices from Intune...'
$devices = New-Object System.Collections.Generic.List[object]
while ($uri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    foreach ($device in $page.value) {
        if ($IncludeAllPlatforms -or $device.operatingSystem -eq 'Windows') { $devices.Add($device) }
    }
    $uri = $page.'@odata.nextLink'
}

if ($devices.Count -eq 0) {
    Write-Warning 'No devices found.'
    return
}

# One paged read of all Entra devices instead of a lookup per device; keyed on the Entra deviceId.
Write-Information 'Fetching Entra device registration dates...'
$registered = @{}
$uri = 'v1.0/devices?$select=deviceId,registrationDateTime'
while ($uri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    foreach ($entraDevice in $page.value) {
        if ($entraDevice.deviceId) { $registered[[string]$entraDevice.deviceId] = $entraDevice.registrationDateTime }
    }
    $uri = $page.'@odata.nextLink'
}

$now = Get-Date
$staleDays = 30
$noSerial = 0
$noUser = 0
$stale = 0

foreach ($d in ($devices | Sort-Object { $_.deviceName })) {
    $enrolled = ConvertTo-LocalDate $d.enrolledDateTime
    $entraRegistered = if ($d.azureADDeviceId) { ConvertTo-LocalDate $registered[[string]$d.azureADDeviceId] } else { $null }
    $lastSync = ConvertTo-LocalDate $d.lastSyncDateTime
    $daysSinceSync = if ($lastSync) { [int]($now - $lastSync).TotalDays } else { $null }

    if ([string]::IsNullOrWhiteSpace($d.serialNumber)) { $noSerial++ }
    if ([string]::IsNullOrWhiteSpace($d.userPrincipalName)) { $noUser++ }
    if ($null -ne $daysSinceSync -and $daysSinceSync -gt $staleDays) { $stale++ }

    $ownership = switch ($d.managedDeviceOwnerType) {
        'company'  { 'Company' }
        'personal' { 'Personal' }
        default    { "$($d.managedDeviceOwnerType)" }
    }

    [pscustomobject]@{
        DeviceName          = $d.deviceName
        SerialNumber        = $d.serialNumber
        Manufacturer        = $d.manufacturer
        Model               = $d.model
        PrimaryUser         = $d.userDisplayName
        UserPrincipalName   = $d.userPrincipalName
        Ownership           = $ownership
        EntraRegisteredDate = if ($entraRegistered) { $entraRegistered.ToString('yyyy-MM-dd') } else { $null }
        EnrolledDate        = if ($enrolled) { $enrolled.ToString('yyyy-MM-dd') } else { $null }
        LastSync            = if ($lastSync) { $lastSync.ToString('yyyy-MM-dd HH:mm') } else { $null }
        DaysSinceSync       = $daysSinceSync
        OS                  = $d.operatingSystem
        OSVersion           = $d.osVersion
        Compliance          = $d.complianceState
        StorageGB           = if ($d.totalStorageSpaceInBytes) { [math]::Round($d.totalStorageSpaceInBytes / 1GB, 0) } else { $null }
        Id                  = $d.id
    }
}

Write-Information "Done. $($devices.Count) device(s)."
Write-Information "Quality check: $noSerial without serial number, $noUser without primary user, $stale not synced in $staleDays days."
