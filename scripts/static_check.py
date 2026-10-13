"""Repository-level layout checks; native compilation/runtime are covered by CI."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
required = (
    "CMakeLists.txt",
    "include/godot_soci/database.h",
    "src/database.cpp",
    "src/register_types.cpp",
    "addons/godot_soci/soci.gdextension",
    "addons/godot_soci/database.gd",
    "project.godot",
    "demo/common/demo.tscn",
    "demo/common/demo_scene.gd",
    "demo/sqlite/basic.gd",
    "demo/sqlite/threaded.gd",
    "demo/postgresql/basic.gd",
    "tests/sqlite_test.gd",
    "tests/postgresql_test.gd",
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
