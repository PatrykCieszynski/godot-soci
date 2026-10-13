"""Repository-level layout checks; native compilation/runtime are covered by CI."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
required = (
    "CMakeLists.txt",
    "include/godot_soci/database.h",
    "src/database.cpp",
    "src/register_types.cpp",
    "src/query_worker.cpp",
    "src/query_dispatcher.cpp",
    "src/query_request.cpp",
    "include/godot_soci/query_dispatcher.h",
    "include/godot_soci/query_request.h",
    "include/godot_soci/query_worker.h",
    "addons/godot_soci/soci.gdextension",
    "addons/godot_soci/database.gd",
    "addons/godot_soci/async_database.gd",
    "project.godot",
    "demo/common/demo.tscn",
    "demo/common/demo_scene.gd",
    "demo/sqlite/basic.gd",
    "demo/sqlite/threaded.gd",
    "demo/postgresql/basic.gd",
    "demo/postgresql/docker-compose.yml",
    "tests/sqlite_test.gd",
    "tests/postgresql_test.gd",
    "tests/async_sqlite_test.gd",
    "tests/async_postgresql_test.gd",
    "tests/sqlite_wal_concurrency_test.gd",
    "tests/async_failure_test.gd",
    "scripts/run_windows_tests.ps1",
    "docs/API.md",
    "docs/TESTING.md",
)
for rel in required:
    assert (root / rel).is_file(), rel
cmake = (root / "CMakeLists.txt").read_text()
manifest = (root / "addons/godot_soci/soci.gdextension").read_text()
source = (root / "src/database.cpp").read_text()
assert 'GODOTCPP_API_VERSION "4.7"' in cmake
assert 'compatibility_minimum = "4.7"' in manifest
assert "Duplicate SQL result column name" in source
assert "src/database.cpp" in cmake
assert "target_include_directories(godot_soci PRIVATE src include)" in cmake
for path in (root / "demo").rglob("*.gd"):
    assert "\t" not in path.read_text(), path
print("STATIC SOURCE LAYOUT PASS (not a substitute for Godot integration tests)")
