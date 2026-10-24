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
Copy-Item -LiteralPath 'demo' -Destination (Join-Path $script:TestProject 'demo') -Recurse
Write-Host "Windows native CI project: $script:TestProject"

# Keep diagnostic evidence outside the disposable test project. Native crashes
# may terminate Godot before any GDScript exception or stack trace is printed.
$script:DiagnosticsRoot = Join-Path $env:RUNNER_TEMP 'godot-soci-diagnostics'
$script:LogsDir = Join-Path $script:DiagnosticsRoot 'logs'
$script:DumpsDir = Join-Path $script:DiagnosticsRoot 'dumps'
New-Item -ItemType Directory -Force -Path $script:LogsDir, $script:DumpsDir | Out-Null
Write-Host "Godot diagnostic files: $script:DiagnosticsRoot"

function Invoke-GodotNativeCrashDebugger {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Label,
        [int] $TimeoutSeconds = 90
    )

    $cdb = $env:GODOT_SOCI_CDB
    if (-not $cdb -or -not (Test-Path -LiteralPath $cdb)) {
        Write-Warning 'CDB is unavailable; cannot produce a native stack trace.'
        return
    }

    # Godot's *_console.exe is a small launcher that starts the real engine
    # as a child process. Debug the actual engine or CDB will exit too soon.
    $engineExe = $Godot -replace '_console\.exe$', '.exe'
    if ($engineExe -eq $Godot -or -not (Test-Path -LiteralPath $engineExe)) {
        Write-Warning "Cannot locate actual Godot engine executable for CDB: $engineExe"
        return
    }
    Write-Host "Attaching CDB to real Godot engine: $engineExe"

    $safeLabel = $Label -replace '[^a-zA-Z0-9_.-]', '_'
    $debuggerLog = Join-Path $script:LogsDir "$safeLabel.cdb.log"
    $commandFile = Join-Path $script:LogsDir "$safeLabel.cdbcmd.txt"
    $dump = Join-Path $script:DumpsDir "$safeLabel.cdb.dmp"
    # CDB's sxe -c parser treats backslashes inside its quoted command
    # string as escapes. Use forward slashes so the dump is actually written
    # into the diagnostics directory and included in the CI artifact.
    $dumpForCdb = $dump -replace '\\', '/'
    $symbols = (Resolve-Path 'addons/godot_soci/bin/windows').Path

    # First-chance AV interception avoids Godot/Windows exception handlers
    # swallowing the fault before a postmortem crash dump can be produced.
    # Debug only a failed test replay; normal tests remain unaffected.
    $onCrash = ".echo GODOT_SOCI_NATIVE_ACCESS_VIOLATION; .exr -1; r; kv; ~* kb; lm m godot_soci; .dump /m $dumpForCdb; q"
    @(
        "sxe -c `"$onCrash`" av"
        'g'
    ) | Set-Content -LiteralPath $commandFile -Encoding ascii

    # Start-Process joins ArgumentList into one command line, so quote paths.
    $debuggerArgs = @(
        '-G', '-lines',
        '-y', ("`"" + $symbols + "`""),
        '-logo', ("`"" + $debuggerLog + "`""),
        '-cf', ("`"" + $commandFile + "`""),
        ("`"" + $engineExe + "`"")
    ) + $Arguments

    $process = $null
    $debugOut = Join-Path $script:LogsDir "$safeLabel.cdb.stdout.log"
    $debugErr = Join-Path $script:LogsDir "$safeLabel.cdb.stderr.log"
    Write-Host "::group::CDB native crash replay: $Label"
    try {
        $process = Start-Process -FilePath $cdb -ArgumentList $debuggerArgs -NoNewWindow -PassThru -WorkingDirectory $script:TestProject -RedirectStandardOutput $debugOut -RedirectStandardError $debugErr
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            Write-Warning "CDB replay exceeded $TimeoutSeconds seconds."
        }

        if (Test-Path -LiteralPath $debuggerLog) {
            $lines = @(Get-Content -LiteralPath $debuggerLog -ErrorAction SilentlyContinue)
            # The CDB startup transcript echoes the sxe command containing
            # the marker; only the standalone .echo output proves the handler ran.
            $crashLine = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Trim() -eq 'GODOT_SOCI_NATIVE_ACCESS_VIOLATION') {
                    $crashLine = $i
                    break
                }
            }
            if ($crashLine -ge 0) {
                Write-Host 'Native access violation intercepted by CDB. Exception and stacks:'
                $end = [Math]::Min($lines.Count - 1, $crashLine + 120)
                $lines[$crashLine..$end] | ForEach-Object { Write-Host $_ }
            } else {
                Write-Warning 'CDB did not intercept an access violation in the engine process. Inspect the full CDB log.'
                $lines | Select-Object -Last 60 | ForEach-Object { Write-Host $_ }
            }
        } else {
            Write-Warning 'CDB did not produce a debugger transcript.'
        }
        if (Test-Path -LiteralPath $dump) {
            Write-Host "CDB minidump available: $dump"
        }
    }
    catch {
        Write-Warning "CDB diagnostic replay failed: $_"
    }
    finally {
        if ($process) { $process.Dispose() }
        Write-Host '::endgroup::'
    }
}

function Invoke-GodotBounded {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Label,
        [string] $ExpectedMarker = '',
        [int] $TimeoutSeconds = 60
    )
    $safeLabel = $Label -replace '[^a-zA-Z0-9_.-]', '_'
    $out = Join-Path $script:LogsDir "$safeLabel.stdout.log"
    $err = Join-Path $script:LogsDir "$safeLabel.stderr.log"
    $summary = Join-Path $script:LogsDir "$safeLabel.result.txt"
    $process = $null
    $timedOut = $false
    try {
        Write-Host "::group::Godot: $Label"
        $process = Start-Process -FilePath $Godot -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -WorkingDirectory $script:TestProject
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            $process.Kill()
            $process.WaitForExit()
        }

        $stdout = Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue
        if ($stdout) { Write-Host $stdout }
        if ($stderr) { Write-Host $stderr }
        $hexExit = '0x{0:X8}' -f ([long]$process.ExitCode -band 4294967295)
        @(
            "Test: $Label"
            "PID: $($process.Id)"
            "Exit code: $($process.ExitCode) ($hexExit)"
            "Timed out: $timedOut"
            "Expected marker: $ExpectedMarker"
            "Diagnostic directory: $script:DiagnosticsRoot"
        ) | Set-Content -LiteralPath $summary

        if ($timedOut -or $process.ExitCode -ne 0) {
            # A native exception deserves a real stack, not just an NTSTATUS.
            # Keep the original failure code even if the diagnostic replay fails.
            if (-not $timedOut -and $process.ExitCode -lt 0) {
                Invoke-GodotNativeCrashDebugger -Arguments $Arguments -Label $Label
            }
            # CDB replay stores a minidump if the access violation recurs.
            $dumps = @(Get-ChildItem -Path $script:DumpsDir -Filter '*.dmp' -File -ErrorAction SilentlyContinue)
            if ($dumps.Count -gt 0) {
                Write-Host "Crash minidumps: $($dumps.Name -join ', ')"
            }
            Write-Host "::error title=Godot native test failed::$Label exited $hexExit (decimal $($process.ExitCode)); logs/minidumps available in CI artifacts."
            if ($timedOut) { throw "Timed out after $TimeoutSeconds seconds: $Label" }
            throw "Godot failed ($($process.ExitCode), $hexExit): $Label"
        }
        if ($ExpectedMarker -and -not ($stdout + $stderr).Contains($ExpectedMarker)) {
            Write-Host "::error title=Godot test missing PASS marker::$Label exited successfully, but did not print '$ExpectedMarker'."
            throw "Godot script ended without PASS marker '$ExpectedMarker': $Label"
        }
    }
    finally {
        Write-Host '::endgroup::'
        if ($process) { $process.Dispose() }
        # Retain stdout/stderr and the result summary for CI artifact upload.
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
    @{ Name = 'sqlite_result_types_test.gd'; Marker = 'SQLITE RESULT TYPES PASS' },
    @{ Name = 'async_sqlite_test.gd'; Marker = 'ASYNC SQLITE PASS' },
    @{ Name = 'sqlite_wal_concurrency_test.gd'; Marker = 'SQLITE WAL CONCURRENCY PASS' },
    @{ Name = 'async_failure_test.gd'; Marker = 'ASYNC FAILURE PATHS PASS' },
    @{ Name = 'async_observability_test.gd'; Marker = 'ASYNC OBSERVABILITY PASS' },
    @{ Name = 'postgresql_test.gd'; Marker = 'POSTGRESQL INTEGRATION PASS' },
    @{ Name = 'native_error_test.gd'; Marker = 'NATIVE ERROR INTEGRATION PASS' },
    @{ Name = 'async_postgresql_test.gd'; Marker = 'ASYNC POSTGRESQL PASS' },
    @{ Name = 'backend_parity_test.gd'; Marker = 'BACKEND TYPE PARITY PASS' }
)
foreach ($test in $tests) {
    Invoke-GodotBounded -Arguments @('--headless', '--path', '.',
        '--script', "res://tests/$($test.Name)") -Label $test.Name -ExpectedMarker $test.Marker -TimeoutSeconds 60
}
Write-Host 'WINDOWS SQLITE + POSTGRESQL INTEGRATION PASS'
