<#
.SYNOPSIS
    Prepares a customized azd app package for manual Teams admin center upload.
.DESCRIPTION
    Runs offline without Azure, Graph or Toolkit authentication. Preserves the
    source ZIP, deployment identities, permissions and agent configuration.
    Adds token.botframework.com to validDomains for Teams OAuth sign-in while
    preserving existing domains.
    Writes a versioned archive beside this script and optionally copies it to
    another unused path. Never overwrites files or submits an app to Teams.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][Alias('PublishRequestFile')][string]$MetadataFile,
    [string]$PackagePath = (Join-Path $PSScriptRoot '..\..\agent-deployment\agent\appPackage.zip'),
    [string]$OutputPackagePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\common-scripts\Common.ps1')
$metadata = Read-PublishingMetadata -Path $MetadataFile
$PackagePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackagePath)
$archivePath = Join-Path $PSScriptRoot "appPackage.$($metadata.appVersion).zip"
if ([string]::IsNullOrWhiteSpace($OutputPackagePath)) { $OutputPackagePath = $archivePath }
$OutputPackagePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPackagePath)
if ($PackagePath -ieq $archivePath -or $PackagePath -ieq $OutputPackagePath -or
    [IO.File]::Exists($archivePath) -or (Test-Path -LiteralPath $OutputPackagePath)) {
    throw 'The archive/output already exists or matches the source ZIP. Choose a higher appVersion and an unused output path; no files will be overwritten.'
}
if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($OutputPackagePath))) {
    throw 'The output package directory must already exist.'
}
$package = New-CustomizedM365Package -Path $PackagePath -Metadata $metadata -HistoryDirectory $PSScriptRoot
if (-not $PSCmdlet.ShouldProcess($archivePath,
    'Prepare a customized, identity-preserving ZIP for manual Teams admin center upload')) {
    Write-Host 'No ZIP was written and no Azure, Toolkit, Graph or Teams action was run.'
    return
}
$lock = $null
try {
    try {
        $lock = [IO.FileStream]::new((Join-Path $PSScriptRoot '.appPackage.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None,
            1, [IO.FileOptions]::DeleteOnClose)
    } catch [IO.IOException] {
        throw "Cannot lock package history. Another package preparation may be active. No ZIP was written: $($_.Exception.Message)"
    }
    Assert-NewM365AppVersion -AppId $package.Manifest.id -SourceVersion $package.SourceVersion `
        -AppVersion $metadata.appVersion -HistoryDirectory $PSScriptRoot
    $stream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $stream.Write($package.Bytes, 0, $package.Bytes.Length)
    } catch {
        $stream.Dispose()
        [IO.File]::Delete($archivePath)
        throw
    } finally { $stream.Dispose() }
    if (-not (Test-M365ArchiveContent -Path $archivePath -ExpectedBytes $package.Bytes)) {
        throw "Archive verification failed at '$archivePath'. The file is retained for inspection; do not upload it."
    }
    if ($OutputPackagePath -ine $archivePath) {
        try { [IO.File]::Copy($archivePath, $OutputPackagePath, $false) } catch {
            throw "Version $($metadata.appVersion) was archived at '$archivePath', but the additional copy failed: $($_.Exception.Message). The verified archive is retained; do not regenerate this version."
        }
    }
} finally {
    if ($lock) { $lock.Dispose() }
}
Write-Host "Prepared package: '$OutputPackagePath'. Original azd package unchanged. No app was published."
Write-Host 'Next: open https://admin.teams.microsoft.com > Teams apps > Manage apps > Upload new app and select the prepared ZIP. For an existing app, open its details and use Upload file to update it. Check organization app availability/policies and test user sign-in after upload.'
[pscustomobject]@{
    PackagePath = $OutputPackagePath
    ArchivePath = $archivePath
    AppId = $package.Manifest.id
    AppVersion = $metadata.appVersion
    Published = $false
    NextAction = 'ManualTeamsAdminCenterUpload'
}
