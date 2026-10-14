"""Unit checks for the actual Windows DLL linker command inspector."""
import unittest

from check_windows_sqlite_link import verify, RELEASE_LIBRARY, DEBUG_LIBRARY, TRIPLET


CACHE = f"CMAKE_BUILD_TYPE:STRING=Release\nVCPKG_TARGET_TRIPLET:STRING={TRIPLET}\n"


class WindowsSqliteLinkTests(unittest.TestCase):
    def command(self, library: str, flavor: str = "release") -> str:
        return ("cmd.exe /C link.exe /OUT:godot_soci.windows.template_"
                f"{flavor}.x86_64.dll C:/work/{library} soci_sqlite3.lib")

    def test_optimized_release_sqlite_is_accepted(self):
        verify(CACHE, self.command(RELEASE_LIBRARY), "release")

    def test_debug_sqlite_library_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "debug/lib"):
            verify(CACHE, self.command(DEBUG_LIBRARY), "release")

    def test_optimizations_disabled_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "CMAKE_BUILD_TYPE"):
            verify(CACHE.replace("Release", "Debug"),
                   self.command(RELEASE_LIBRARY), "release")

    def test_wrong_triplet_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "x64-windows-static-md"):
            verify(CACHE.replace(TRIPLET, "x64-windows"),
                   self.command(RELEASE_LIBRARY), "release")

    def test_debug_template_can_use_optimized_vcpkg_sqlite(self):
        verify(CACHE, self.command(RELEASE_LIBRARY, "debug"), "debug")


if __name__ == "__main__":
    unittest.main()
