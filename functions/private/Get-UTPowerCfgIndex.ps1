function Get-UTPowerCfgIndex {
    <#
    .SYNOPSIS
        Reads the current AC index of a power setting from the active scheme, language-neutral.
    .NOTES
        powercfg output is localised, but the two "Current ... Power Setting Index" lines are always the last two
        lines that end in an 8-digit hex value: AC first, then DC. Returns $null if the setting is unavailable.
        Values are read as UInt32 because a setting can legitimately be 0xFFFFFFFF (e.g. "never"), which
        overflows Int32.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SubGroup,
        [Parameter(Mandatory = $true)][string]$Setting,
        [switch]$DC
    )
    try {
        $r = Invoke-UTNative -FilePath 'powercfg.exe' -Arguments @('/q', 'SCHEME_CURRENT', $SubGroup, $Setting)
        if ($r.ExitCode -ne 0) { return $null }
        $hex = @($r.Lines | ForEach-Object { if ($_ -match ':\s*(0x[0-9A-Fa-f]{8})\s*$') { $Matches[1] } })
        if ($hex.Count -lt 2) { return $null }
        $pick = $hex[$hex.Count - 2]
        if ($DC) { $pick = $hex[$hex.Count - 1] }
        return [uint32]([Convert]::ToUInt32($pick.Substring(2), 16))
    } catch { return $null }
}

function Set-UTPowerCfgIndex {
    <#
    .SYNOPSIS
        Writes the AC index of one power setting in the active scheme, activates it, and logs it.
    .NOTES
        The tweak scripts used to pipe powercfg straight to Out-Null, so a refusal looked exactly like
        a success: nothing in the log either way, and the tweak still counted as applied. Throwing
        here lets Invoke-UTTweakApply report the failure and keep the snapshot.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SubGroup,
        [Parameter(Mandatory = $true)][string]$Setting,
        [Parameter(Mandatory = $true)][uint32]$Index,
        [Parameter(Mandatory = $true)][string]$What
    )
    $r = Invoke-UTNative -FilePath 'powercfg.exe' -Arguments @('/SETACVALUEINDEX', 'SCHEME_CURRENT', $SubGroup, $Setting, ([string]$Index))
    if ($r.ExitCode -ne 0) { throw ("powercfg could not set {0} (exit {1}): {2}" -f $What, $r.ExitCode, $r.Output.Trim()) }
    # The scheme has to be re-activated for a changed index to take effect.
    $a = Invoke-UTNative -FilePath 'powercfg.exe' -Arguments @('/setactive', 'SCHEME_CURRENT')
    if ($a.ExitCode -ne 0) { throw ("powercfg could not re-activate the current scheme (exit {0}): {1}" -f $a.ExitCode, $a.Output.Trim()) }
    Write-UTLog ("{0}: AC power index set to {1}" -f $What, $Index)
}

function Get-UTBitLockerStatus {
    <#
    .SYNOPSIS
        Protection state of the system drive: 'On', 'Off', or 'Unknown' when it cannot be determined.
    .NOTES
        Never returns 'Off' on an error. A bcdedit change on an encrypted drive whose protection was not
        suspended can demand the 48-digit recovery key at the next boot, so "I could not tell" must be
        treated as "assume encrypted".
    #>
    try {
        $vol = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
            Where-Object { $_.DriveLetter -eq $env:SystemDrive } | Select-Object -First 1
        if (-not $vol) { return 'Off' }
        $r = Invoke-CimMethod -InputObject $vol -MethodName GetProtectionStatus -ErrorAction Stop
        if ([int]$r.ReturnValue -ne 0) { return 'Unknown' }
        if ([int]$r.ProtectionStatus -eq 0) { return 'Off' }
        return 'On'
    } catch {
        # The WMI provider is absent on some Home installs that genuinely have no encryption, but it also
        # fails on a locked-down machine that does. Unknown is the safe answer.
        return 'Unknown'
    }
}

function Suspend-UTBitLocker {
    <#
    .SYNOPSIS
        Suspends BitLocker protection for exactly one reboot. Returns $true only when it is safe to
        change boot configuration afterwards.
    #>
    $status = Get-UTBitLockerStatus
    if ($status -eq 'Off') { return $true }
    if ($status -eq 'Unknown') {
        Write-UTLog 'Could not determine whether this drive is encrypted, so it is treated as encrypted. Suspending protection for one reboot before touching boot settings.' -Level Warn
    } else {
        Write-UTLog 'BitLocker / Device Encryption is ON. Suspending protection for one reboot so this boot setting change cannot trigger a recovery key prompt.' -Level Warn
    }
    $r = Invoke-UTNative -FilePath 'manage-bde.exe' -Arguments @('-protectors', '-disable', $env:SystemDrive, '-RebootCount', '1')
    $code = $r.ExitCode
    $text = $r.Output.Trim()
    if ($code -eq 0) {
        Write-UTLog 'BitLocker protection suspended for one reboot; it resumes automatically.' -Level Ok
        return $true
    }
    if ($status -eq 'Unknown') {
        # manage-bde also fails on a machine with no encryption at all; only then is it safe to continue.
        if ($text -match 'ERROR_NOT_ENCRYPTED|not have BitLocker|is not protected|0x80310008') {
            Write-UTLog 'The drive is not encrypted, continuing.'
            return $true
        }
    }
    Write-UTLog ("BitLocker protection could NOT be suspended (exit {0}): {1}. The boot setting was left unchanged to avoid a recovery-key lockout." -f $code, $text) -Level Error
    return $false
}

function Invoke-UTBcdEdit {
    <#
    .SYNOPSIS
        Runs a bcdedit change, but only after BitLocker protection is known to be safe to change.
    #>
    param([Parameter(Mandatory = $true)][string]$Arguments)
    if (-not (Suspend-UTBitLocker)) {
        throw 'Refused to change boot configuration: BitLocker protection could not be suspended, and changing it now could lock you out at the next boot.'
    }
    $argv = @($Arguments -split '\s+' | Where-Object { $_ })
    $r = Invoke-UTNative -FilePath 'bcdedit.exe' -Arguments $argv
    $code = $r.ExitCode
    $text = $r.Output.Trim()
    if ($code -ne 0) { throw "bcdedit $Arguments failed (exit $code): $text" }
    Write-UTLog "bcdedit $Arguments -> $text"
}
