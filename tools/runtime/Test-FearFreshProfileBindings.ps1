[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,

    [uint32]$MinimumRecordCount = 47
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProfilePath = [IO.Path]::GetFullPath($ProfilePath)
if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
    throw "F.E.A.R. profile database is missing: $ProfilePath"
}

$bytes = [IO.File]::ReadAllBytes($ProfilePath)
if ($bytes.Length -lt 28) {
    throw "F.E.A.R. profile database is too short to contain a GADB header: $ProfilePath"
}

$magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 4)
if ($magic -cne 'GADB') {
    throw "Unexpected F.E.A.R. profile database signature '$magic': $ProfilePath"
}

$recordCount = [BitConverter]::ToUInt32($bytes, 16)
if ($recordCount -lt $MinimumRecordCount) {
    throw "Fresh profile contains only $recordCount records; expected at least $MinimumRecordCount after resolving all stock defaults."
}

$profileText = [Text.Encoding]::ASCII.GetString($bytes)
$requiredBindingRecords = @(
    'JUMP',
    'LookUp',
    'LookDown',
    'Status',
    'STRAFE',
    'TURNLEFT',
    'TURNRIGHT',
    'ZoomIn'
)

$missing = @($requiredBindingRecords | Where-Object {
    -not [regex]::IsMatch(
        $profileText,
        ('(?<![A-Za-z0-9_]){0}(?![A-Za-z0-9_])' -f [regex]::Escape($_)))
})
if ($missing.Count -gt 0) {
    throw "Fresh profile is missing locale-sensitive default binding records: $($missing -join ', ')"
}

[pscustomobject]@{
    ProfilePath       = $ProfilePath
    Length            = $bytes.Length
    Version           = [BitConverter]::ToUInt32($bytes, 4)
    Categories        = [BitConverter]::ToUInt32($bytes, 12)
    Records           = $recordCount
    Attributes        = [BitConverter]::ToUInt32($bytes, 20)
    Values            = [BitConverter]::ToUInt32($bytes, 24)
    RequiredBindings  = $requiredBindingRecords.Count
    Result            = 'Pass'
}
