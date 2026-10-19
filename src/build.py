import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from iso import iso

here = pathlib.Path(__file__).parent
shell = (here / "shell.html").read_text(encoding="utf-8")
app = (here / "app.js").read_text(encoding="utf-8")
num2a2 = json.dumps({n: a for a, n in sorted(iso.items(), key=lambda x: x[1])}, separators=(",", ":"))
assert "/*NUM2A2*/{}" in app and "/*APP*/" in shell
out = shell.replace("/*APP*/", app.replace("/*NUM2A2*/{}", num2a2))
dest = here.parent / "index.html"
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text(out, encoding="utf-8")
print(dest, len(out.encode()), "bytes")
