"""Exercise the actual opaque bridge with an injected engine, without Apple SDKs."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class IOSRouterBridgeTests(unittest.TestCase):
    def test_opaque_boundary_contains_exceptions_and_bounds_owned_output(self):
        compiler = shutil.which("g++") or shutil.which("clang++")
        if not compiler:
            self.skipTest("C++20 compiler required for native bridge boundary regression")
        with tempfile.TemporaryDirectory(prefix="trailmesh-bridge-") as directory:
            work = Path(directory)
            (work / "include").mkdir()
            (work / "date").mkdir()
            (work / "date/tz.h").write_text("#include <string>\nnamespace date { inline void set_install(const std::string&) {} inline int get_tzdb() { return 0; } }\n")
            (work / "include/main.h").write_text("""#include <string>
class ValhallaMobileHttpClient;
void *create_valhalla_actor(const char *, ValhallaMobileHttpClient *);
std::string route(const char *, void *);
void delete_valhalla_actor(void *);
""")
            # Compile on non-Apple hosts: timezone resource initialization is tested
            # by the real device/simulator framework smoke, not this injected engine.
            (work / "test.cpp").write_text(r'''#include "TrailMeshValhalla.h"
#include <cassert>
#include <cstring>
#include <stdexcept>
#include <string>
class ValhallaMobileHttpClient;
static int live = 0;
void *create_valhalla_actor(const char *path, ValhallaMobileHttpClient *http) {
    assert(http == nullptr);
    if (std::strcmp(path, "throw") == 0) throw std::runtime_error("engine error");
    if (std::strcmp(path, "unknown") == 0) throw 42;
    if (std::strcmp(path, "null") == 0) return nullptr;
    ++live; return new int(1);
}
void delete_valhalla_actor(void *actor) { delete static_cast<int *>(actor); --live; }
std::string route(const char *request, void *) {
    if (std::strcmp(request, "throw") == 0) throw std::runtime_error("bad route");
    if (std::strcmp(request, "unknown") == 0) throw 42;
    if (std::strcmp(request, "large") == 0) return std::string(4 * 1024 * 1024 + 1, 'x');
    if (std::strcmp(request, "limit") == 0) return std::string(4 * 1024 * 1024, 'x');
    if (std::strcmp(request, "empty") == 0) return "";
    return std::string("a\0b", 3);
}
int main() {
    void *actor = reinterpret_cast<void *>(1);
    assert(tm_router_create(nullptr, &actor) != 0 && actor == nullptr);
    assert(tm_router_create("config", nullptr) != 0);
    for (auto path : {"throw", "unknown", "null"})
        assert(tm_router_create(path, &actor) != 0 && actor == nullptr);
    assert(tm_router_create("config", &actor) == 0 && actor && live == 1);
    uint8_t *bytes = reinterpret_cast<uint8_t *>(1); size_t length = 99;
    assert(tm_router_route(nullptr, "ok", &bytes, &length) != 0 && !bytes && length == 0);
    for (auto request : {"throw", "unknown", "large", "empty"}) {
        bytes = reinterpret_cast<uint8_t *>(1); length = 99;
        assert(tm_router_route(actor, request, &bytes, &length) != 0 && !bytes && length == 0);
    }
    assert(tm_router_route(actor, "ok", &bytes, &length) == 0 && length == 3);
    assert(bytes[0] == 'a' && bytes[1] == 0 && bytes[2] == 'b'); tm_router_free(bytes);
    assert(tm_router_route(actor, "limit", &bytes, &length) == 0 && length == 4 * 1024 * 1024);
    tm_router_free(bytes); tm_router_free(nullptr);
    assert(tm_router_destroy(actor) == 0 && live == 0);
    assert(tm_router_destroy(nullptr) == 0);
}
''')
            executable = work / ("bridge-test.exe" if __import__("os").name == "nt" else "bridge-test")
            subprocess.run([compiler, "-std=c++20", "-I" + str(work),
                            "-I" + str(ROOT / "apps/ios/NativeRouting/Bridge/include"),
                            str(ROOT / "apps/ios/NativeRouting/Bridge/router.cpp"),
                            str(work / "test.cpp"), "-o", str(executable)], check=True, capture_output=True)
            subprocess.run([str(executable)], check=True, capture_output=True)

if __name__ == "__main__":
    unittest.main()
