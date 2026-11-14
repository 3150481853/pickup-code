import pathlib
import re

base = pathlib.Path(r"G:\取件码小程序")

p = base / "ios" / "project.yml"
t = p.read_text(encoding="utf-8")
t2 = re.sub(r'MARKETING_VERSION: "[^"]*"', 'MARKETING_VERSION: "0.15.0"', t)
t2 = re.sub(r'CURRENT_PROJECT_VERSION: "[^"]*"', 'CURRENT_PROJECT_VERSION: "24"', t2)
p.write_text(t2, encoding="utf-8")
print("ios:", [l.strip() for l in t2.splitlines() if "VERSION" in l])

g = base / "android" / "app" / "build.gradle"
s = g.read_text(encoding="utf-8")
s2 = re.sub(r"versionCode\s+\d+", "versionCode 24", s)
s2 = re.sub(r'versionName\s+"[^"]*"', 'versionName "0.15.0"', s2)
g.write_text(s2, encoding="utf-8")
print("android:", [l.strip() for l in s2.splitlines() if "version" in l.lower()][:6])
