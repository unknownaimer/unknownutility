function New-UTRestorePoint {
    <#
    .SYNOPSIS
        Creates a System Restore point (Windows PowerShell 5.1 only). Returns $true on success.
    .NOTES
        Windows refuses a second restore point within 24 hours unless SystemRestorePointCreationFrequency is 0.
        System Protection is off by default on many PCs; Enable-ComputerRestore turns it on for the system drive.
    #>
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $previous = Get-UTRegistryValue -Path $key -Name 'SystemRestorePointCreationFrequency'
    try {
        Write-UTLog 'Creating a System Restore point, this can take a minute...'
        # Windows refuses a second restore point within 24 hours unless this is 0. It is a system-wide
        # setting, so it is put back exactly as it was in the finally block below.
        Set-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description ('unknowntweaks {0:yyyy-MM-dd HH:mm}' -f (Get-Date)) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-UTLog 'Restore point created' -Level Ok
        return $true
    } catch {
        Write-UTLog ('Restore point could not be created: {0}' -f $_.Exception.Message) -Level Warn
        return $false
    } finally {
        if ($previous.Exists) {
            Set-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -Type DWord -Value ([int]$previous.Value) -Force -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -Force -ErrorAction SilentlyContinue
        }
    }
}
