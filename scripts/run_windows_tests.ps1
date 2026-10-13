param([Parameter(Mandatory = $true)][string] $Godot)

$ErrorActionPreference = 'Stop'

# Godot must not scan vcpkg/buildtrees/CMake output as project resources.
# Test the compiled extension inside a fresh, minimal Godot project.
$script:TestProject = Join-Path $env:RUNNER_TEMP 'godot-soci-integration'
if (Test-Path $script:TestProject) {
    Remove-Item -LiteralPath $script:TestProject -Force -Recurse
}
New-Item -ItemType Directory -Force -Path $script:TestProject | Out-Null
Copy-Item -LiteralPath 'project.godot' -Destination $script:TestProject
Copy-Item -LiteralPath 'addons' -Destination (Join-Path $script:TestProject 'addons') -Recurse
Copy-Item -LiteralPath 'tests' -Destination (Join-Path $script:TestProject 'tests') -Recurse
New-Item -ItemType Directory -Force -Path (Join-Path $script:TestProject 'demo') | Out-Null
Copy-Item -LiteralPath 'demo/backend_switch.gd' -Destination (Join-Path $script:TestProject 'demo/backend_switch.gd')
Write-Host "Windows native CI project: $script:TestProject"

function Invoke-GodotBounded {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Label,
        [string] $ExpectedMarker = '',
        [int] $TimeoutSeconds = 60
    )
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    $process = $null
    try {
        Write-Host "::group::Godot: $Label"
        $process = Start-Process -FilePath $Godot -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -WorkingDirectory $script:TestProject
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Timed out after $TimeoutSeconds seconds: $Label"
        }
        $stdout = Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue
        Write-Host $stdout
        if ($stderr) { Write-Host $stderr }
        if ($process.ExitCode -ne 0) {
            throw "Godot failed ($($process.ExitCode)): $Label"
        }
        if ($ExpectedMarker -and -not ($stdout + $stderr).Contains($ExpectedMarker)) {
            throw "Godot script ended without PASS marker '$ExpectedMarker': $Label"
        }
    }
    finally {
        Write-Host '::endgroup::'
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

# GitHub's Windows 2022 image includes PostgreSQL 14 (service is stopped).
$postgres = Get-Service -Name 'postgresql-x64-14' -ErrorAction Stop
if ($postgres.Status -ne 'Running') {
    Set-Service -Name 'postgresql-x64-14' -StartupType Manual
    Start-Service -Name 'postgresql-x64-14'
}
$ready = Join-Path $env:PGBIN 'pg_isready.exe'
if (!(Test-Path $ready)) { throw 'PostgreSQL tool not found on runner' }
$available = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    & $ready -h 127.0.0.1 -p 5432 -U postgres -d postgres
    if ($LASTEXITCODE -eq 0) { $available = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $available) { throw 'Local PostgreSQL did not become ready within 30 seconds' }
if (-not $env:GODOT_SOCI_PG) { throw 'GODOT_SOCI_PG missing' }

# Avoid Godot 4.7 GDExtension docs race at immediate editor shutdown.
Invoke-GodotBounded -Arguments @('--headless', '--path', '.', '--editor',
    '--quit-after', '120', '--frame-delay', '50') -Label 'editor import' -TimeoutSeconds 45

$tests = @(
    @{ Name = 'sqlite_test.gd'; Marker = 'SQLITE INTEGRATION PASS' },
    @{ Name = 'async_sqlite_test.gd'; Marker = 'ASYNC SQLITE PASS' },
    @{ Name = 'sqlite_wal_concurrency_test.gd'; Marker = 'SQLITE WAL CONCURRENCY PASS' },
    @{ Name = 'async_failure_test.gd'; Marker = 'ASYNC FAILURE PATHS PASS' },
    @{ Name = 'postgresql_test.gd'; Marker = 'POSTGRESQL INTEGRATION PASS' },
    @{ Name = 'async_postgresql_test.gd'; Marker = 'ASYNC POSTGRESQL PASS' },
    @{ Name = 'backend_parity_test.gd'; Marker = 'BACKEND TYPE PARITY PASS' }
)
foreach ($test in $tests) {
    Invoke-GodotBounded -Arguments @('--headless', '--path', '.',
        '--script', "res://tests/$($test.Name)") -Label $test.Name -ExpectedMarker $test.Marker -TimeoutSeconds 60
}
Write-Host 'WINDOWS SQLITE + POSTGRESQL INTEGRATION PASS'
