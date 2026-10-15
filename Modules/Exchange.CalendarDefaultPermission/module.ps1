[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $Mailboxes = @(),
    [bool] $AllUserMailboxes = $false,
    [ValidateSet('Default', 'Anonymous')] [string] $User = 'Default',
    [ValidateSet('None', 'AvailabilityOnly', 'LimitedDetails', 'Reviewer', 'Editor')] [string] $AccessRights = 'LimitedDetails'
)

if ($AllUserMailboxes) {
    Write-Information 'Fetching all user mailboxes...'
    $Mailboxes = @(Get-EXOMailbox -RecipientTypeDetails UserMailbox -ResultSize Unlimited -Properties UserPrincipalName |
        Select-Object -ExpandProperty UserPrincipalName)
}
if (-not $Mailboxes) { throw "Enter at least one mailbox, or tick 'All user mailboxes'." }

Write-Information "Processing $($Mailboxes.Count) mailbox(es): '$User' -> $AccessRights"
$done = 0

foreach ($mailbox in $Mailboxes) {
    $done++
    $result = [ordered]@{ Mailbox = $mailbox; Folder = ''; User = $User; Before = ''; After = ''; Status = ''; Error = '' }
    try {
        # The folder name is localised ('Calendar', 'Kalender', ...); the folder type is not.
        $calendar = Get-MailboxFolderStatistics -Identity $mailbox -FolderScope Calendar -ErrorAction Stop |
            Where-Object { $_.FolderType -eq 'Calendar' } | Select-Object -First 1
        if (-not $calendar) { throw 'No primary calendar folder found.' }

        $folderIdentity = '{0}:\{1}' -f $mailbox, $calendar.Name
        $result.Folder = $calendar.Name

        $current = Get-MailboxFolderPermission -Identity $folderIdentity -User $User -ErrorAction Stop
        $result.Before = ($current.AccessRights -join ',')

        if ($result.Before -eq $AccessRights) {
            $result.After = $result.Before
            $result.Status = 'AlreadySet'
        }
        elseif ($PSCmdlet.ShouldProcess($folderIdentity, "Set '$User' permission to $AccessRights")) {
            Set-MailboxFolderPermission -Identity $folderIdentity -User $User -AccessRights $AccessRights -ErrorAction Stop | Out-Null
            $result.After = $AccessRights
            $result.Status = 'Changed'
        }
        else {
            $result.After = $AccessRights
            $result.Status = 'WhatIf'
        }
    }
    catch {
        $result.Status = 'Failed'
        $result.Error = $_.Exception.Message
        Write-Warning "Mailbox $done of $($Mailboxes.Count) failed: $($_.Exception.Message)"
    }
    [pscustomobject]$result

    if ($done % 25 -eq 0) { Write-Information "$done / $($Mailboxes.Count) processed..." }
}
