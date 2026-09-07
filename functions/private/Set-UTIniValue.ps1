function Read-UTIniFile {
    <#
    .SYNOPSIS
        Parses an Unreal-style INI into an ordered structure: Sections (name -> ordered key/value list) plus raw lines.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $result = @{ Path = $Path; Exists = $false; HasBom = $false; Lines = @(); Sections = @{} }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $result.Exists = $true
    $result.HasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $result.Lines = @([System.IO.File]::ReadAllLines($Path))
    $current = ''
    foreach ($line in $result.Lines) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $current = $Matches[1]; if (-not $result.Sections.ContainsKey($current)) { $result.Sections[$current] = @{} }; continue }
        if ($line -match '^\s*([^=;#\s][^=]*?)\s*=(.*)$') {
            if (-not $result.Sections.ContainsKey($current)) { $result.Sections[$current] = @{} }
            $result.Sections[$current][$Matches[1]] = $Matches[2]
        }
    }
    return $result
}

function Get-UTIniValue {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Section, [Parameter(Mandatory = $true)][string]$Key)
    $ini = Read-UTIniFile -Path $Path
    foreach ($s in $ini.Sections.Keys) {
        if ($s -ne $Section) { continue }
        foreach ($k in $ini.Sections[$s].Keys) { if ($k -eq $Key) { return $ini.Sections[$s][$k] } }
    }
    return $null
}

function Set-UTIniValues {
    <#
    .SYNOPSIS
        Key-level merge into an INI file: existing keys are replaced in place, missing keys are appended to their
        section, missing sections are created at the end. Unknown keys, comments, BOM and CRLF are preserved.
    .PARAMETER Settings
        Hashtable: section name -> hashtable of key -> value (values are written verbatim).
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][hashtable]$Settings)
    $ini = Read-UTIniFile -Path $Path
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in $ini.Lines) { $lines.Add($l) }
    $changed = 0

    foreach ($section in $Settings.Keys) {
        $pairs = $Settings[$section]
        # locate section bounds
        $start = -1; $end = $lines.Count
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[(.+)\]\s*$') {
                if ($start -ge 0) { $end = $i; break }
                if ($Matches[1] -eq $section) { $start = $i }
            }
        }
        if ($start -lt 0) {
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { $lines.Add('') }
            $lines.Add("[$section]")
            $start = $lines.Count - 1
            $end = $lines.Count
        }
        foreach ($key in $pairs.Keys) {
            $value = [string]$pairs[$key]
            $found = $false
            # A key can appear more than once in a hand-edited file. Unreal's config parser keeps the last
            # occurrence, so every one has to be rewritten or the file would still hold the old value.
            for ($i = $start + 1; $i -lt $end; $i++) {
                if ($lines[$i] -match '^\s*([^=;#\s][^=]*?)\s*=(.*)$' -and $Matches[1] -eq $key) {
                    if ($lines[$i] -ne "$key=$value") { $lines[$i] = "$key=$value"; $changed++ }
                    $found = $true
                }
            }
            if (-not $found) {
                # insert before trailing blank lines of the section so the file stays tidy
                $insertAt = $end
                while ($insertAt -gt ($start + 1) -and $lines[$insertAt - 1].Trim() -eq '') { $insertAt-- }
                $lines.Insert($insertAt, "$key=$value")
                $end++
                $changed++
            }
        }
    }
    $enc = New-Object System.Text.UTF8Encoding($ini.HasBom)
    $text = ($lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $text, $enc)
    return $changed
}
