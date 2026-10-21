param(
    [Parameter(Mandatory = $true)][ValidateSet('Prepare', 'Launch', 'Apply')][string]$Phase,
    [Parameter(Mandatory = $true)][string]$StageDirectory
)

$ErrorActionPreference = 'Stop'
$stageRoot = (Resolve-Path -LiteralPath $StageDirectory).Path
$payloadRoot = Join-Path $stageRoot 'payload'
$settings = Get-Content -LiteralPath (Join-Path $stageRoot 'update.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$executable = [IO.Path]::GetFullPath($settings.executable)
$installRoot = [IO.Path]::GetDirectoryName($executable)
$installPrefix = $installRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$executableName = [IO.Path]::GetFileName($executable)

try {
    if ($Phase -eq 'Launch') {
        # Windows PowerShell must be launched with a normal Windows process environment.
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', ('"' + $PSCommandPath + '"'), '-Phase', 'Apply',
            '-StageDirectory', ('"' + $stageRoot + '"'))
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden
        return
    }
    if ($Phase -eq 'Prepare') {
        Expand-Archive -LiteralPath $settings.archive -DestinationPath $payloadRoot
        foreach ($required in @($executableName, 'flutter_windows.dll', 'data\flutter_assets')) {
            if (-not (Test-Path -LiteralPath (Join-Path $payloadRoot $required))) {
                throw "The update archive is missing: $required"
            }
        }
        # Test the actual installation directory before closing the application.
        $probe = Join-Path $installRoot ([IO.Path]::GetRandomFileName())
        $stream = [IO.File]::Open($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        $stream.Dispose()
        Remove-Item -LiteralPath $probe
        return
    }

    $parent = [Diagnostics.Process]::GetProcessById([int]$settings.processId)
    [IO.File]::WriteAllText((Join-Path $stageRoot 'ready'), '')
    if (-not $parent.WaitForExit(60000)) {
        throw 'The application did not exit; no files were replaced.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stageRoot 'apply-approved'))) {
        throw 'The application did not authorize replacement; no files were replaced.'
    }
    $payloadPrefix = [IO.Path]::GetFullPath($payloadRoot) + [IO.Path]::DirectorySeparatorChar
    foreach ($file in Get-ChildItem -LiteralPath $payloadRoot -Recurse -File) {
        $relative = $file.FullName.Substring($payloadPrefix.Length)
        $destination = [IO.Path]::GetFullPath((Join-Path $installRoot $relative))
        if (-not $destination.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Update destination is outside the installation directory: $destination"
        }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        [IO.File]::Copy($file.FullName, $destination, $true)
    }
    # ProcessStartInfo treats paths literally, including square brackets.
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.WorkingDirectory = $installRoot
    $startInfo.UseShellExecute = $false
    [Diagnostics.Process]::Start($startInfo) | Out-Null
    [IO.File]::WriteAllText((Join-Path $stageRoot 'result.txt'), 'updated-and-restarted')
    # Delete staged files individually; never remove the installation directory.
    foreach ($file in Get-ChildItem -LiteralPath $payloadRoot -Recurse -File) {
        Remove-Item -LiteralPath $file.FullName
    }
} catch {
    $message = $_.Exception.Message + "`n" + $_.ScriptStackTrace
    [IO.File]::WriteAllText((Join-Path $stageRoot 'error.txt'), $message)
    if ($Phase -eq 'Apply' -and (Test-Path -LiteralPath (Join-Path $stageRoot 'ready'))) {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show("$message`n`nLog: $stageRoot", "Kazumi's book update failed") | Out-Null
    }
    Write-Error $message
    exit 1
}
