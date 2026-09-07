function Get-UTServiceStartup {
    <#
    .SYNOPSIS
        Returns Automatic / AutomaticDelayedStart / Manual / Disabled / Boot / System, or $null if the service is missing.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $start = [string]$svc.StartType
    if ($start -eq 'Automatic') {
        $delayed = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name DelayedAutostart -ErrorAction SilentlyContinue).DelayedAutostart
        if ($delayed -eq 1) { $start = 'AutomaticDelayedStart' }
    }
    return $start
}

function Set-UTService {
    <#
    .SYNOPSIS
        Changes a service startup type. Handles Automatic (Delayed Start) on Windows PowerShell 5.1 via sc.exe.
    .OUTPUTS
        $true when the startup type is now what was asked for (including a service that does not exist on
        this build, which is a normal skip), $false when the change failed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$StartupType
    )
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-UTLog "Service $Name not present on this Windows build, skipped" -Level Warn; return $true }
    try {
        $current = Get-UTServiceStartup -Name $Name
        if ($current -eq $StartupType) { Write-UTLog "Service $Name already $StartupType"; return $true }
        if ($StartupType -eq 'AutomaticDelayedStart') {
            $out = & sc.exe config $Name start= delayed-auto 2>&1
            if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed: $out" }
        } elseif ($StartupType -eq 'Automatic' -and $current -eq 'AutomaticDelayedStart') {
            # Set-Service writes the start type but not the delayed-auto flag, so a service that was
            # "Automatic (Delayed Start)" would still read back delayed and the undo would not round
            # trip. sc.exe owns that flag; start= auto and start= delayed-auto are distinct values.
            $out = & sc.exe config $Name start= auto 2>&1
            if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed: $out" }
        } else {
            Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        }
        # Stopping a running service also stops whatever depends on it, which is not recorded anywhere,
        # so leave it running: the new startup type takes effect at the next boot either way.
        if ($StartupType -eq 'Disabled' -and $svc.Status -eq 'Running') {
            Write-UTLog "Service $Name is set to Disabled but is still running; it stays stopped from the next reboot"
        }
        Write-UTLog "Service $Name : $current -> $StartupType"
        return $true
    } catch {
        Write-UTLog "Service $Name could not be changed: $($_.Exception.Message)" -Level Error
        return $false
    }
}
