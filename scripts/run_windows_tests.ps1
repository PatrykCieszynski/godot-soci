param([Parameter(Mandatory = $true)][string] $Godot)

$ErrorActionPreference = 'Stop'
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
    if ($LASTEXITCODE -eq 0) {
        $available = $true
        break
    }
    Start-Sleep -Seconds 1
}
if (-not $available) { throw 'Local PostgreSQL did not become ready within 30 seconds' }
if (-not $env:GODOT_SOCI_PG) { throw 'GODOT_SOCI_PG missing' }

# Godot 4.7: delay editor shutdown to avoid GDExtension documentation race.
& $Godot --headless --path . --editor --quit-after 120 --frame-delay 50
if ($LASTEXITCODE -ne 0) { throw 'Headless editor import failed' }

foreach ($script in @(
    'sqlite_test.gd',
    'async_sqlite_test.gd',
    'sqlite_wal_concurrency_test.gd',
    'async_failure_test.gd',
    'postgresql_test.gd',
    'async_postgresql_test.gd'
)) {
    Write-Host "Testing: $script"
    & $Godot --headless --path . --script "res://tests/$script"
    if ($LASTEXITCODE -ne 0) { throw "Godot integration failed: $script" }
}
Write-Host 'WINDOWS SQLITE + POSTGRESQL INTEGRATION PASS'
