"""Cheap repository-level sanity checks; not a substitute for native compile/CI."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
assert (root / 'CMakeLists.txt').exists()
assert (root / 'addons/godot_soci/godot_soci.gdextension').exists()
assert (root / 'project.godot').exists()
source = (root / 'src/godot_soci_database.cpp').read_text()
for name in ('begin_immediate', 'bind_arguments', 'statement.define_and_bind', 'rollback()', 'GODOT_SOCI_WITH_POSTGRESQL'):
    assert name in source, name
for script in ('sqlite_demo', 'postgres_demo', 'threaded_sqlite'):
    p = root / f'demo/scripts/{script}.gd'
    assert p.is_file(), p
for path in (root / 'demo').rglob('*.gd'):
    content = path.read_text()
    assert '\t' not in content, path
for match in re.findall(r'res://(demo/[^"\n]+)', (root / 'demo/scenes/demo.tscn').read_text()):
    assert (root / match).exists(), match
print('STATIC SOURCE LAYOUT PASS (native build/runtime not tested)')
