function Test-UTBetaGate {
    <#
    .SYNOPSIS
        Asks the private-beta gate whether this key and build may run. Returns @{ Ok; Reason }.
    .DESCRIPTION
        Fails closed. Anything other than a plain "ok" - a revoked key, a closed beta, an unknown
        key, a typo in the URL, no network - means the build does not start. That is the point of
        a kill switch, and it is also why public builds pass no StatusUrl and are never gated.
        This is the only request a beta build makes that a public build does not; it carries the
        tester's key and the build version and nothing else.
        -Fetch lets the tests supply the answer without a server.
    #>
    param(
        [string]$StatusUrl,
        [string]$Version = '',
        [int]$TimeoutSec = 8,
        [scriptblock]$Fetch
    )
    if ([string]::IsNullOrWhiteSpace($StatusUrl)) { return @{ Ok = $true; Reason = 'not gated' } }
    $sep = '?'
    if ($StatusUrl.Contains('?')) { $sep = '&' }
    $uri = $StatusUrl + $sep + 'v=' + [uri]::EscapeDataString([string]$Version)
    try {
        if ($Fetch) { $raw = & $Fetch $uri }
        else { $raw = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop }
        $answer = ([string]$raw).Trim().ToLowerInvariant()
        if ($answer -eq 'ok') { return @{ Ok = $true; Reason = 'ok' } }
        if (-not $answer) { $answer = 'empty answer from the gate' }
        return @{ Ok = $false; Reason = $answer }
    } catch {
        return @{ Ok = $false; Reason = ('gate unreachable: ' + $_.Exception.Message) }
    }
}
