function ConvertTo-UTRegistryValue {
    <#
    .SYNOPSIS
        Converts the string form used in tweaks.json / backups into the .NET value Set-ItemProperty expects.
    #>
    param([string]$Type, [string]$Value)
    switch ($Type) {
        'DWord' {
            # DWord values above Int32.MaxValue (e.g. 4294967295) must be passed as the equivalent negative Int32
            $u = [uint32]0
            if ([uint32]::TryParse($Value, [ref]$u)) { return [BitConverter]::ToInt32([BitConverter]::GetBytes($u), 0) }
            return [int]$Value
        }
        'QWord'       { return [int64]$Value }
        'Binary'      { return [byte[]](@($Value -split ',' | Where-Object { $_.Trim() } | ForEach-Object { [Convert]::ToByte($_.Trim(), 16) })) }
        'MultiString' { return [string[]](@($Value -split '\|')) }
        default       { return [string]$Value }
    }
}

function ConvertFrom-UTRegistryValue {
    <#
    .SYNOPSIS
        Serialises a value read from the registry into the string form used by backups.
    #>
    param($Raw, [string]$Kind)
    if ($null -eq $Raw) { return '' }
    switch ($Kind) {
        'DWord'       { return ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Raw), 0)).ToString() }
        'QWord'       { return ([int64]$Raw).ToString() }
        'Binary'      { return ((@($Raw) | ForEach-Object { '{0:X2}' -f $_ }) -join ',') }
        'MultiString' { return ((@($Raw)) -join '|') }
        default       { return [string]$Raw }
    }
}

function Get-UTRegistryValue {
    <#
    .SYNOPSIS
        Reads a registry value with its kind, reporting whether it exists at all (needed for undo).
    #>
    param([string]$Path, [string]$Name)
    $result = @{ Exists = $false; Kind = ''; Value = '' }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $result }
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $names = @($key.GetValueNames())
        $match = $names | Where-Object { $_ -eq $Name } | Select-Object -First 1
        if ($null -eq $match) { return $result }
        $kind = [string]$key.GetValueKind($match)
        $raw = $key.GetValue($match, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $result.Exists = $true
        $result.Kind = $kind
        $result.Value = ConvertFrom-UTRegistryValue -Raw $raw -Kind $kind
    } catch { }
    return $result
}

function Set-UTRegistryValueDirect {
    <#
    .SYNOPSIS
        Writes one value through Microsoft.Win32.Registry instead of the PowerShell provider.
    .DESCRIPTION
        The registry provider reuses key handles it opened earlier in the session, so a key that was
        first read through a read-only handle can refuse a later write with "Requested registry access
        is not allowed" even though the ACL grants FullControl. Opening our own writable handle side
        steps that, and fails with a genuine access error when the ACL really does say no.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Type,
        $Value
    )
    # Plain string work, not a regex: the hive prefix is a fixed 6 characters and a backslash class
    # in a pattern is one more thing to get wrong.
    $hive = $null
    if ($Path.StartsWith('HKLM:' + [char]92, [System.StringComparison]::OrdinalIgnoreCase))      { $hive = [Microsoft.Win32.Registry]::LocalMachine }
    elseif ($Path.StartsWith('HKCU:' + [char]92, [System.StringComparison]::OrdinalIgnoreCase)) { $hive = [Microsoft.Win32.Registry]::CurrentUser }
    else { throw "unsupported hive in $Path" }
    $sub = $Path.Substring(6)
    $key = $hive.OpenSubKey($sub, $true)
    if (-not $key) { $key = $hive.CreateSubKey($sub) }
    if (-not $key) { throw "could not open $Path for writing" }
    # An array loses its element type crossing an untyped parameter boundary: a byte[] arrives as
    # Object[] and SetValue then refuses it. Put the type back before handing it over.
    $kind = [Microsoft.Win32.RegistryValueKind]$Type
    if ($kind -eq [Microsoft.Win32.RegistryValueKind]::Binary) { $Value = [byte[]]$Value }
    elseif ($kind -eq [Microsoft.Win32.RegistryValueKind]::MultiString) { $Value = [string[]]$Value }
    try { $key.SetValue($Name, $Value, $kind) }
    finally { $key.Close() }
}

function Set-UTRegistry {
    <#
    .SYNOPSIS
        Creates the key if needed and sets (or removes, for '<RemoveEntry>') a registry value.
    .OUTPUTS
        $true when the change was made, $false when it failed. The caller must not report a tweak as
        applied when this returns $false.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Type = 'DWord',
        [string]$Value = ''
    )
    try {
        if ($Value -eq '<RemoveEntry>') {
            if (Test-Path -LiteralPath $Path) {
                Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
            }
            Write-UTLog "Removed $Path\$Name"
            return $true
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        if ([string]::IsNullOrEmpty($Type)) { $Type = 'String' }
        $converted = ConvertTo-UTRegistryValue -Type $Type -Value $Value
        try {
            Set-ItemProperty -LiteralPath $Path -Name $Name -Type $Type -Value $converted -Force -ErrorAction Stop
        } catch [System.Security.SecurityException] {
            Set-UTRegistryValueDirect -Path $Path -Name $Name -Type $Type -Value $converted
        } catch [System.UnauthorizedAccessException] {
            Set-UTRegistryValueDirect -Path $Path -Name $Name -Type $Type -Value $converted
        }
        Write-UTLog "Set $Path\$Name = $Value ($Type)"
        return $true
    } catch [System.Security.SecurityException] {
        # Keep the real message: "access denied" on its own is not enough to tell a locked-down
        # policy key apart from a hive that belongs to another account.
        Write-UTLog "Access denied writing $Path\$Name : $($_.Exception.Message)" -Level Error
        return $false
    } catch [System.UnauthorizedAccessException] {
        Write-UTLog "Access denied writing $Path\$Name : $($_.Exception.Message)" -Level Error
        return $false
    } catch {
        Write-UTLog "Failed to write $Path\$Name : $($_.Exception.GetType().Name): $($_.Exception.Message)" -Level Error
        return $false
    }
}
