function Get-UTAppxNeverRemove {
    <#
    .SYNOPSIS
        Packages this tool refuses to remove, whatever config/debloat.json says.
    .DESCRIPTION
        A second lock on the door. config/debloat.json is data and could be edited by hand or by a
        future careless commit; this list is code, and Remove-UTBloatApps checks it last. Everything
        here either cannot be reinstalled from the Store, or takes a documented piece of Windows with
        it. The Xbox two are the ones that matter for a gaming machine:

          XboxIdentityProvider - Xbox sign-in for PC games. Removing it is the documented cause of
                                 Minecraft, Forza and Game Pass titles refusing to sign in.
          GamingServices       - the Game Pass install and licensing service. Removing it breaks
                                 installing or launching Game Pass games and is painful to restore.
    #>
    return @(
        'Microsoft.WindowsStore',
        'Microsoft.StorePurchaseApp',
        'Microsoft.DesktopAppInstaller',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.GamingServices',
        'Microsoft.GamingApp',
        'Microsoft.Windows.SecHealthUI',
        'Microsoft.SecHealthUI',
        'Microsoft.Windows.ShellExperienceHost',
        'Microsoft.Windows.StartMenuExperienceHost',
        'Microsoft.Windows.Search',
        'Microsoft.Windows.CloudExperienceHost',
        'Microsoft.Windows.ContentDeliveryManager',
        'Microsoft.AAD.BrokerPlugin',
        'Microsoft.AccountsControl',
        'Microsoft.CredDialogHost',
        'Microsoft.LockApp',
        'Microsoft.UI.Xaml',
        'Microsoft.VCLibs',
        'Microsoft.NET',
        'Microsoft.WindowsAppRuntime',
        'Microsoft.WebView2',
        'Microsoft.HEIFImageExtension',
        'Microsoft.VP9VideoExtensions',
        'Microsoft.WebMediaExtensions',
        'Microsoft.WebpImageExtension',
        'Microsoft.MicrosoftEdge.Stable',
        'NVIDIACorp.NVIDIAControlPanel',
        'AdvancedMicroDevicesInc',
        'RealtekSemiconductorCorp'
    )
}

function Test-UTAppxRemovable {
    <#
    .SYNOPSIS
        $true when a package name may be removed. Returns the reason in -Reason when it may not.
    #>
    param([Parameter(Mandatory = $true)][string]$Name, [ref]$Reason)
    foreach ($blocked in (Get-UTAppxNeverRemove)) {
        # Prefix match: framework and vendor packages carry a version or product suffix.
        if ($Name -eq $blocked -or $Name -like ($blocked + '.*')) {
            if ($Reason) { $Reason.Value = "on the never-remove list ($blocked)" }
            return $false
        }
    }
    return $true
}

function Get-UTBloatApps {
    <#
    .SYNOPSIS
        The debloat catalogue joined against what is actually installed on this machine.
    .NOTES
        Only packages present here are offered, so the list is never a wall of things that are
        already gone. Anything Windows marks NonRemovable, or that is a framework other packages
        link against, is dropped before the user ever sees it.
    #>
    $installed = @{}
    try {
        foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
            if ($p.IsFramework -or $p.NonRemovable) { continue }
            $installed[[string]$p.Name] = $p
        }
    } catch { }
    $out = @()
    foreach ($prop in @($sync.configs.debloat.PSObject.Properties)) {
        $name = $prop.Name
        if (-not $installed.ContainsKey($name)) { continue }
        $reason = ''
        if (-not (Test-UTAppxRemovable -Name $name -Reason ([ref]$reason))) { continue }
        $out += [pscustomobject]@{
            Name        = $name
            Content     = [string]$prop.Value.Content
            Category    = [string]$prop.Value.Category
            Note        = [string]$prop.Value.Note
            Recommended = [bool]$prop.Value.Recommended
        }
    }
    return @($out | Sort-Object Category, Content)
}

function Remove-UTBloatApps {
    <#
    .SYNOPSIS
        Removes Store apps for this account, and optionally deprovisions them so a new account or a
        feature update does not bring them back. Runs inside a worker runspace.
    .DESCRIPTION
        This is the one thing in the tool that is NOT reversible from a snapshot: an appx package is
        uninstalled, not flagged off. Every name removed is written to
        %ProgramData%\unknowntweaks\backup\removed-apps.txt so there is a list to reinstall from the
        Store afterwards. The UI asks for confirmation and says this in as many words.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Names, [switch]$AllUsers)
    $removed = @()
    $failed = 0
    $skipped = 0
    foreach ($name in $Names) {
        $reason = ''
        if (-not (Test-UTAppxRemovable -Name $name -Reason ([ref]$reason))) {
            Write-UTLog ("Refused to remove {0}: {1}" -f $name, $reason) -Level Warn
            $skipped++
            continue
        }
        $pkgs = @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue | Where-Object { -not $_.NonRemovable })
        if ($pkgs.Count -eq 0) {
            Write-UTLog ("{0} is not installed for this account, nothing to do" -f $name)
            $skipped++
            continue
        }
        $ok = $true
        foreach ($pkg in $pkgs) {
            try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop }
            catch {
                $ok = $false
                Write-UTLog ("{0} could not be removed: {1}" -f $name, $_.Exception.Message) -Level Error
            }
        }
        if (-not $ok) { $failed++; continue }
        Write-UTLog ("Removed {0}" -f $name) -Level Ok
        $removed += $name
        if ($AllUsers) {
            # Deprovisioning stops the package being installed into new accounts and reinstated by a
            # feature update. It needs DISM and therefore elevation, which the tool already has.
            try {
                $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $name })
                foreach ($p in $prov) {
                    Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                    Write-UTLog ("Deprovisioned {0}: it will not come back for new accounts or after a feature update" -f $name)
                }
            } catch {
                Write-UTLog ("{0} was removed for this account but could not be deprovisioned: {1}" -f $name, $_.Exception.Message) -Level Warn
            }
        }
    }
    if ($removed.Count -gt 0) {
        try {
            $file = Join-Path $sync.backupDir 'removed-apps.txt'
            $stamp = Get-Date -Format 's'
            Add-Content -LiteralPath $file -Value (@($removed | ForEach-Object { "$stamp`t$_" })) -Encoding UTF8
            Write-UTLog ("The list of removed apps was appended to {0}. Reinstall any of them from the Microsoft Store." -f $file)
        } catch { }
    }
    $msg = 'Debloat done: {0} removed, {1} failed, {2} skipped' -f $removed.Count, $failed, $skipped
    if ($failed -gt 0) { Write-UTLog $msg -Level Warn } else { Write-UTLog $msg -Level Ok }
    $sync.status = 'ready'
}
