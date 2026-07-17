Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EchoPatchBuildFlavor {
    [CmdletBinding()]
    param(
        [switch]$RemixCameraDiagnostics,
        [switch]$CameraDiagnostics,
        [switch]$RtxFocusPreservation,
        [switch]$RtxCameraReassertion
    )

    if ($RemixCameraDiagnostics -and $CameraDiagnostics) {
        throw '-RemixCameraDiagnostics and -CameraDiagnostics are mutually exclusive package modes.'
    }
    if ($RtxFocusPreservation -and -not $CameraDiagnostics) {
        throw '-RtxFocusPreservation requires -CameraDiagnostics so the RTX package retains the query-light camera capability.'
    }
    if ($RtxCameraReassertion -and (-not $CameraDiagnostics -or -not $RtxFocusPreservation)) {
        throw '-RtxCameraReassertion requires both -CameraDiagnostics and -RtxFocusPreservation.'
    }

    if ($RtxCameraReassertion) {
        return [pscustomobject]@{
            PackageMode = 'RtxCameraReassertionEchoPatch'
            DefaultOutputLeaf = 'echopatch-rtx-camera-reassertion'
        }
    }
    if ($RtxFocusPreservation) {
        return [pscustomobject]@{
            PackageMode = 'RtxCameraDiagnosticEchoPatch'
            DefaultOutputLeaf = 'echopatch-rtx-camera-diagnostics'
        }
    }
    if ($RemixCameraDiagnostics) {
        return [pscustomobject]@{
            PackageMode = 'RemixDiagnosticEchoPatch'
            DefaultOutputLeaf = 'echopatch-remix-diagnostics'
        }
    }
    if ($CameraDiagnostics) {
        return [pscustomobject]@{
            PackageMode = 'CameraDiagnosticEchoPatch'
            DefaultOutputLeaf = 'echopatch-camera-diagnostics'
        }
    }
    return [pscustomobject]@{
        PackageMode = 'EngineOnlyEchoPatch'
        DefaultOutputLeaf = 'echopatch-engine-only'
    }
}

Export-ModuleMember -Function Get-EchoPatchBuildFlavor
