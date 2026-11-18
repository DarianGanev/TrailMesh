from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class TilemakerTests(unittest.TestCase):
    def test_generated_lua_prioritizes_huts_and_shelters_on_mixed_tags(self):
        tools = Path(__file__).resolve().parent
        interpreter = shutil.which("lua5.4") or shutil.which("lua")
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run([sys.executable, tools / "prepare_tilemaker.py", tools / "upstream", directory], check=True)
            generated = (Path(directory) / "process.lua").read_text(encoding="utf-8")
            self.assertNotIn("for k,list in pairs(poiTags)", generated)
            self.assertIn("table.sort(poiTagOrder)", generated)
            if interpreter is None:
                self.skipTest("Lua interpreter unavailable")

            # Run the actual generated function and upstream classification
            # tables without Tilemaker's geometry APIs.
            tables = generated[generated.index("poiTags "):generated.index("poiClassRanks ")]
            ranks_start = generated.index("poiClassRanks   =")
            ranks = generated[ranks_start:generated.index("}", ranks_start) + 1]
            function = generated[generated.index("local poiTagOrder"):generated.index("function SetBuildingHeightAttributes")]
            script = Path(directory) / "check.lua"
            script.write_text('''
function Set(values)
    local result = {}
    for _, value in ipairs(values) do result[value] = true end
    return result
end
''' + tables + ranks + "\n" + function + '''
local function check(tags, expectedClass, expectedSubclass)
    local object = { Find = function(_, key) return tags[key] or "" end }
    local rank, class, subclass = GetPOIRank(object)
    assert(type(rank) == "number")
    assert(class == expectedClass)
    assert(subclass == expectedSubclass)
end
check({ tourism = "alpine_hut", amenity = "restaurant" }, "lodging", "alpine_hut")
check({ tourism = "wilderness_hut", amenity = "shelter" }, "lodging", "wilderness_hut")
check({ amenity = "shelter", tourism = "picnic_site" }, poiClasses.shelter or "amenity", "shelter")
check({ amenity = "cafe", tourism = "hotel" }, poiClasses.cafe or "amenity", "cafe")
''', encoding="utf-8")
            subprocess.run([interpreter, script], check=True)
