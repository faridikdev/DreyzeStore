param(
    [string]$SourceDirectory = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path '.build/zsign-upstream'),
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$expectedCommit = '614caa8d1ca949e260e5746144aa52d27a4b08d6'
$sourcePath = [System.IO.Path]::GetFullPath($SourceDirectory)

if (-not (Test-Path (Join-Path $sourcePath '.git'))) {
    git clone --no-checkout https://github.com/zhlynn/zsign.git $sourcePath
    if ($LASTEXITCODE -ne 0) { throw 'Could not clone the upstream zsign repository.' }
    git -C $sourcePath fetch --depth 1 origin $expectedCommit
    if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the pinned upstream zsign revision.' }
}
git -C $sourcePath checkout --detach $expectedCommit
if ($LASTEXITCODE -ne 0) { throw 'Could not check out the pinned upstream zsign revision.' }
$actualCommit = (git -C $sourcePath rev-parse HEAD).Trim()
if ($actualCommit -ne $expectedCommit) { throw "Unexpected zsign revision: $actualCommit" }

$sourceFile = Join-Path $sourcePath 'src/zsign.cpp'
python (Join-Path $PSScriptRoot 'patch-zsign-stdin.py') $sourceFile
if ($LASTEXITCODE -ne 0) { throw 'Could not apply the DreyzeStore stdin-only password patch.' }

if (-not $SkipBuild) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw 'Visual Studio 2022 Build Tools with the C++ workload are required.' }
    $visualStudio = (& $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $visualStudio) { throw 'Visual Studio MSBuild was not found.' }
    $msbuild = Join-Path $visualStudio 'MSBuild/Current/Bin/MSBuild.exe'
    $solution = Join-Path $sourcePath 'build/windows/vs2022/zsign.sln'
    & $msbuild $solution /m /p:Configuration=Release /p:Platform=x64 /verbosity:minimal
    if ($LASTEXITCODE -ne 0) { throw 'The patched upstream zsign source did not build.' }
}

$builtBinary = Join-Path $sourcePath 'build/windows/vs2022/x64/Release/zsign.exe'
if (-not (Test-Path $builtBinary)) { throw "Expected zsign output was not produced: $builtBinary" }
$destination = Join-Path $repositoryRoot 'apps/windows-companion/src-tauri/binaries'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$sidecar = Join-Path $destination 'zsign-x86_64-pc-windows-msvc.exe'
Copy-Item -LiteralPath $builtBinary -Destination $sidecar -Force
Write-Output "Patched zsign $expectedCommit built at $sidecar"
