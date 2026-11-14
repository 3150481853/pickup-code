import pathlib
import re

base = pathlib.Path(r"G:\取件码小程序")

for f in ["ios/PickupCode/PickupCodeApp.swift", "ios/PickupCode/PickupStore.swift", "ios/PickupCode/Cainiao.swift"]:
    p = base / f
    t = p.read_text(encoding="utf-8")
    # strip string literals crudely for brace counting
    s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', t)
    s = re.sub(r'//[^\n]*', '', s)
    print(f, "braces", s.count("{"), s.count("}"), "parens", s.count("("), s.count(")"))

app = (base / "ios/PickupCode/PickupCodeApp.swift").read_text(encoding="utf-8")
for name in ["struct ArchiveView", "@State private var picking", "@State private var showArchive",
             "func archivePicked", "closeSwipe", "AsyncImage"]:
    print(name, "->", app.count(name))

store = (base / "ios/PickupCode/PickupStore.swift").read_text(encoding="utf-8")
for name in ["func reconcile", "func archiveNow", "func archivePicked", "func restore",
             "func saveArchive", "func loadArchive", "var picked", "var archived",
             "var missingSince", "пусто"]:
    print("store", name, "->", store.count(name))
