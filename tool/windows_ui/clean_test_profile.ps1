$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Only the isolated GitHub Actions profile may be cleaned.' }
$companyRoot = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'ZGCC3890'))
$target = [IO.Path]::GetFullPath((Join-Path $companyRoot "Kazumi's book"))
if (!(Test-Path -LiteralPath $target)) { return }
$resolved = (Resolve-Path -LiteralPath $target).Path
if ($resolved -ne $target -or !(Split-Path $resolved -Parent).Equals($companyRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Unexpected native test profile path.'
}
$entries = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
if ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint -or
    @($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
  throw 'Native test profile contains a redirected path.'
}
foreach ($file in $entries | Where-Object { !$_.PSIsContainer }) {
  Remove-Item -LiteralPath $file.FullName -Force
}
foreach ($directory in $entries | Where-Object PSIsContainer | Sort-Object { $_.FullName.Length } -Descending) {
  Remove-Item -LiteralPath $directory.FullName -Force
}
Remove-Item -LiteralPath $resolved -Force
Write-Output 'Removed only native test files and empty app directories before release startup verification.'
