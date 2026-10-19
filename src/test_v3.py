"""Offline browser test for v3: real page, mocked network (local d3, fake atlas + province files, in-memory RPC with chairs/rally/XP)."""
import json, pathlib, uuid, math, datetime as dt
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).parent.parent
PAGE = (ROOT / "index.html").as_uri()
D3 = pathlib.Path("/opt/npm-tools/node_modules/d3/dist/d3.min.js").read_text()
OUT = ROOT / "shots3"
OUT.mkdir(exist_ok=True)

def rect(l0, l1, a0, a1):
    return [[l0, a0], [l0, a1], [l1, a1], [l1, a0], [l0, a0]]

shapes = [("792", "Turkey", [rect(26, 45, 36, 42)]), ("276", "Germany", [rect(6.5, 15, 47, 55)]),
          ("392", "Japan", [rect(130, 142, 31, 41)]), ("840", "United States of America", [rect(-125, -67, 25, 49), rect(-165, -141, 55, 70)]),
          ("076", "Brazil", [rect(-74, -35, -33, 5)]), (None, "N. Cyprus", [rect(33, 34.5, 35.1, 35.6)])]
Q = 10000; kx, ky = 360 / (Q - 1), 180 / (Q - 1)
arcs, geoms = [], []
for gid, name, rings in shapes:
    idxs = []
    for r in rings:
        pts = [[round((lon + 180) / kx), round((lat + 90) / ky)] for lon, lat in r]
        d, px, py = [], 0, 0
        for x, y in pts: d.append([x - px, y - py]); px, py = x, y
        arcs.append(d); idxs.append([len(arcs) - 1])
    g = {"properties": {"name": name}}
    if gid: g["id"] = gid
    g.update(type="Polygon", arcs=idxs) if len(idxs) == 1 else g.update(type="MultiPolygon", arcs=[[i] for i in idxs])
    geoms.append(g)
TOPO = {"type": "Topology", "transform": {"scale": [kx, ky], "translate": [-180, -90]},
        "objects": {"countries": {"type": "GeometryCollection", "geometries": geoms}}, "arcs": arcs}

def fc(cc, items):
    return {"type": "FeatureCollection", "country": cc, "features": [
        {"type": "Feature", "id": i, "properties": {"n": n}, "geometry": {"type": "Polygon", "coordinates": [r]}} for i, n, r in items]}
FILES = {
    "TR": fc("TR", [("TR-34", "İstanbul", rect(26, 30, 36, 42)), ("TR-06", "Ankara", rect(30, 36, 36, 42)), ("TR-60", "Tokat", rect(36, 45, 36, 42))]),
    "JP": fc("JP", [("JP-13", "Tokyo", rect(138, 142, 31, 41)), ("JP-27", "Osaka", rect(130, 138, 31, 41))]),
    "DE": {"type": "FeatureCollection", "country": "DE", "features": []},
}
PROV = {"TR-34": ("TR", "İstanbul"), "TR-06": ("TR", "Ankara"), "TR-60": ("TR", "Tokat"),
        "JP-13": ("JP", "Tokyo"), "JP-27": ("JP", "Osaka"), "DE": ("DE", None)}

now = lambda: dt.datetime.now(dt.timezone.utc)
iso_ = lambda d: d.isoformat() if d else None
players, teams, votes, purchases, events, seats = {}, {}, [], {}, [], {}
BASE, STEP, SEATXP, RALLY = 100, 100, 20, 10

def mk_player(secret, nick):
    players[secret] = {"id": str(uuid.uuid4()), "nickname": nick, "team": None, "joined": None, "last": None, "rally": None, "bank": 0, "created": now() - dt.timedelta(days=3)}
    return players[secret]
def mk_team(name, color, owner):
    tid = str(uuid.uuid4())
    teams[tid] = {"id": tid, "name": name, "color": color, "owner": owner["id"], "founder": owner["id"], "sales": 0}
    owner["team"], owner["joined"] = tid, now() - dt.timedelta(days=2)
    events.append({"k": "created", "n": owner["nickname"], "t": tid, "i": None, "a": None, "at": now() - dt.timedelta(hours=30)})
    return tid
ali, ayse, veli = mk_player("a" * 64, "Ali"), mk_player("b" * 64, "Ayse"), mk_player("c" * 64, "Veli")
TA = mk_team("Kırmızı Kartallar", "#e8323c", ali)
TB = mk_team("Mavi Kuşlar", "#3d6fe3", ayse)
veli["team"], veli["joined"] = TA, now() - dt.timedelta(days=1)
def add_vote(p, target, h, w=1):
    votes.append({"pid": p["id"], "n": p["nickname"], "t": p["team"], "i": target, "at": now() - dt.timedelta(hours=h), "w": w})
for p, tg, h in [(ali, "TR-60", 3), (veli, "TR-60", 4), (ayse, "TR-60", 2), (ayse, "TR-06", 5), (ayse, "TR-06", 9), (ayse, "TR-06", 12), (ali, "JP-13", 7)]:
    add_vote(p, tg, h)
add_vote(veli, "TR-34", 6, RALLY)
seats[("TR-06", TB)] = {"holder": ayse["id"], "price": 300, "k": 3, "since": now() - dt.timedelta(hours=5)}
events.append({"k": "seat", "n": "Ayse", "t": TB, "i": "TR-06", "a": 300, "at": now() - dt.timedelta(hours=5)})

def by_id(pid): return next(p for p in players.values() if p["id"] == pid)
def hours_xp(since): return math.floor((now() - since).total_seconds() / 3600) * SEATXP
def xp(p):
    return sum(v["w"] for v in votes if v["pid"] == p["id"]) + p["bank"] + sum(hours_xp(s["since"]) for s in seats.values() if s["holder"] == p["id"])
def me_json(p):
    hr = now().replace(minute=0, second=0, microsecond=0)
    tm = teams.get(p["team"])
    return {"nickname": p["nickname"],
            "team": {"id": tm["id"], "name": tm["name"], "color": tm["color"], "owner": tm["owner"] == p["id"]} if tm else None,
            "owns": [t["id"] for t in teams.values() if t["owner"] == p["id"]],
            "can_vote": p["last"] is None or p["last"] < hr, "next_vote_at": iso_(hr + dt.timedelta(hours=1)),
            "can_rally": p["rally"] is None or p["rally"] <= now() - dt.timedelta(hours=24),
            "rally_at": iso_(p["rally"] + dt.timedelta(hours=24)) if p["rally"] else None,
            "switch_at": iso_(p["joined"] + dt.timedelta(hours=24)) if p["joined"] else None,
            "votes": sum(1 for v in votes if v["pid"] == p["id"]), "xp": xp(p),
            "seats": sum(1 for s in seats.values() if s["holder"] == p["id"]), "joined": iso_(p["created"]), "now": iso_(now())}
def standings():
    agg = {}
    for v in votes:
        a = agg.setdefault(v["i"], {}).setdefault(v["t"], [0, v["at"]])
        a[0] += v["w"]; a[1] = min(a[1], v["at"])
    rows = []
    for i, m in agg.items():
        lst = sorted(m.items(), key=lambda x: (-x[1][0], x[1][1]))
        top = lst[0]
        g = {}
        for v in votes:
            if v["i"] == i and v["t"] == top[0]: g[v["n"]] = g.get(v["n"], 0) + v["w"]
        gn = max(g.items(), key=lambda x: x[1])
        ch = seats.get((i, top[0]))
        chn = by_id(ch["holder"])["nickname"] if ch and ch["holder"] else None
        rows.append({"i": i, "c": PROV[i][0], "nm": PROV[i][1], "t": top[0], "p": top[1][0], "n": sum(x[1][0] for x in lst),
                     "s": lst[1][0] if len(lst) > 1 else None, "sp": lst[1][1][0] if len(lst) > 1 else None,
                     "g": chn or gn[0], "gc": bool(chn), "gp": gn[1], "gs": ch["price"] if chn else None})
    return rows
def team_row(tm):
    m = standings()
    return {"id": tm["id"], "name": tm["name"], "color": tm["color"], "owner": by_id(tm["owner"])["nickname"] if tm["owner"] else None,
            "members": sum(1 for p in players.values() if p["team"] == tm["id"]), "held": sum(1 for r in m if r["t"] == tm["id"]), "sales": tm["sales"],
            "pts": sum(v["w"] for v in votes if v["t"] == tm["id"]), "v24": sum(v["w"] for v in votes if v["t"] == tm["id"] and v["at"] > now() - dt.timedelta(days=1)),
            "seats": sum(1 for (i, t), s in seats.items() if t == tm["id"] and s["holder"])}
def state():
    feed = [{"k": "v", "n": v["n"], "t": v["t"], "i": v["i"], "pn": PROV[v["i"]][1], "c": PROV[v["i"]][0], "a": v["w"], "at": iso_(v["at"])} for v in votes]
    feed += [{"k": e["k"], "n": e["n"], "t": e["t"], "i": e["i"], "pn": PROV[e["i"]][1] if e["i"] else None, "c": PROV[e["i"]][0] if e["i"] else None, "a": e["a"], "at": iso_(e["at"])} for e in events]
    feed.sort(key=lambda f: f["at"], reverse=True)
    top = {}
    for v in votes:
        p = by_id(v["pid"]); k = (p["nickname"], p["team"], p["id"]); top[k] = top.get(k, 0) + v["w"]
    chairs = [{"n": e["n"], "t": e["t"], "i": e["i"], "pn": PROV[e["i"]][1], "c": PROV[e["i"]][0], "a": e["a"], "at": iso_(e["at"])} for e in sorted(events, key=lambda e: e["at"], reverse=True) if e["k"] == "seat"]
    return {"now": iso_(now()), "window_hours": 168, "price_cents": 200, "unit_cents": 100, "seat_base": BASE, "seat_step": STEP, "seat_xp": SEATXP, "rally": RALLY,
            "checkout": True, "contact": "", "map": standings(), "teams": [team_row(t) for t in teams.values()], "feed": feed[:45],
            "top": [{"n": n, "t": tm, "p": p, "x": xp(by_id(pid))} for (n, tm, pid), p in sorted(top.items(), key=lambda x: -x[1])],
            "chairs": chairs, "players": len(players), "teams_total": len(teams),
            "votes24": sum(v["w"] for v in votes if v["at"] > now() - dt.timedelta(days=1)),
            "votes_hour": sum(1 for v in votes if v["at"] >= now().replace(minute=0, second=0, microsecond=0)),
            "seats_total": sum(1 for s in seats.values() if s["holder"]), "provinces_total": len(PROV)}
def seat_price(i, t):
    s = seats.get((i, t))
    return s["price"] + STEP if s and s["holder"] else BASE
class E(Exception): pass
def need(secret):
    p = players.get(secret)
    if not p: raise E("not_joined")
    return p
def profile(nick):
    p = next((x for x in players.values() if x["nickname"].lower() == nick.lower()), None)
    if not p: return None
    tm = teams.get(p["team"])
    fav = {}
    for v in votes:
        if v["pid"] == p["id"]: fav[v["i"]] = fav.get(v["i"], 0) + v["w"]
    return {"nickname": p["nickname"], "joined": iso_(p["created"]),
            "team": {"id": tm["id"], "name": tm["name"], "color": tm["color"]} if tm else None, "xp": xp(p),
            "votes": sum(1 for v in votes if v["pid"] == p["id"] and v["w"] == 1), "rallies": sum(1 for v in votes if v["pid"] == p["id"] and v["w"] > 1),
            "points": sum(v["w"] for v in votes if v["pid"] == p["id"]), "countries": len({PROV[v["i"]][0] for v in votes if v["pid"] == p["id"]}),
            "seats": [{"i": i, "pn": PROV[i][1], "c": PROV[i][0], "t": t, "price": s["price"], "since": iso_(s["since"])} for (i, t), s in seats.items() if s["holder"] == p["id"]],
            "owns": [{"id": t["id"], "name": t["name"], "color": t["color"]} for t in teams.values() if t["owner"] == p["id"]],
            "fav": [{"i": i, "pn": PROV[i][1], "c": PROV[i][0], "p": n} for i, n in sorted(fav.items(), key=lambda x: -x[1])[:5]]}
def rpc(name, b):
    if name == "pw_meta": return {"pc": {"TR": 3, "JP": 2, "DE": 1}, "price_cents": 200, "seat_base": BASE, "seat_step": STEP, "checkout": True}
    if name == "pw_state": return state()
    if name == "pw_me":
        p = players.get(b["p_secret"]); return me_json(p) if p else None
    if name == "pw_player":
        if b["p_secret"] in players: return me_json(players[b["p_secret"]])
        if any(p["nickname"].lower() == b["p_nickname"].lower() for p in players.values()): raise E("nickname_taken")
        p = mk_player(b["p_secret"], b["p_nickname"]); p["created"] = now(); return me_json(p)
    if name == "pw_teams":
        q = (b.get("p_q") or "").lower()
        return [{"id": t["id"], "name": t["name"], "color": t["color"], "members": team_row(t)["members"]} for t in teams.values() if q in t["name"].lower()]
    if name == "pw_team_create":
        p = need(b["p_secret"])
        if any(t["name"].lower() == b["p_name"].lower() for t in teams.values()): raise E("team_name_taken")
        tid = str(uuid.uuid4())
        teams[tid] = {"id": tid, "name": b["p_name"], "color": b["p_color"], "owner": p["id"], "founder": p["id"], "sales": 0}
        p["team"], p["joined"] = tid, now()
        events.append({"k": "created", "n": p["nickname"], "t": tid, "i": None, "a": None, "at": now()})
        return me_json(p)
    if name == "pw_team_join":
        p = need(b["p_secret"])
        if p["team"] and teams[p["team"]]["owner"] == p["id"]: raise E("owner_cannot_leave")
        if p["joined"] and p["joined"] > now() - dt.timedelta(hours=24): raise E("switch_cooldown")
        p["team"], p["joined"] = b["p_team"], now(); return me_json(p)
    if name == "pw_team_update":
        p = need(b["p_secret"]); tm = teams[b["p_team"]]
        if tm["owner"] != p["id"]: raise E("not_owner")
        tm["name"] = b.get("p_name") or tm["name"]; tm["color"] = b.get("p_color") or tm["color"]; return me_json(p)
    if name == "pw_team":
        tm = teams[b["p_team"]]; r = team_row(tm)
        topm = {}
        for p in players.values():
            if p["team"] == tm["id"]: topm[p["nickname"]] = sum(v["w"] for v in votes if v["pid"] == p["id"] and v["t"] == tm["id"])
        return {**r, "founder": by_id(tm["founder"])["nickname"], "created_at": iso_(now()),
                "top": [{"n": n, "p": c} for n, c in sorted(topm.items(), key=lambda x: -x[1])],
                "seats": [{"i": i, "pn": PROV[i][1], "c": PROV[i][0], "n": by_id(s["holder"])["nickname"], "price": s["price"]} for (i, t), s in seats.items() if t == tm["id"] and s["holder"]],
                "price_cents": 200, "checkout": True}
    if name in ("pw_vote", "pw_rally"):
        p = need(b["p_secret"])
        if not p["team"]: raise E("no_team")
        if b["p_target"] not in PROV: raise E("bad_target")
        if name == "pw_vote":
            hr = now().replace(minute=0, second=0, microsecond=0)
            if p["last"] and p["last"] >= hr: raise E("cooldown")
            add_vote(p, b["p_target"], 0); p["last"] = now()
        else:
            if p["rally"] and p["rally"] > now() - dt.timedelta(hours=24): raise E("rally_cooldown")
            add_vote(p, b["p_target"], 0, RALLY); p["rally"] = now()
        return me_json(p)
    if name == "pw_province":
        i = b["p_id"]
        if i not in PROV: return None
        ts, vs = {}, {}
        for v in votes:
            if v["i"] != i: continue
            ts.setdefault(v["t"], [0, set()]); ts[v["t"]][0] += v["w"]; ts[v["t"]][1].add(v["n"])
            vs[(v["n"], v["t"])] = vs.get((v["n"], v["t"]), 0) + v["w"]
        return {"id": i, "name": PROV[i][1], "country": PROV[i][0],
                "teams": [{"t": k, "name": teams[k]["name"], "color": teams[k]["color"], "p": x[0], "v": len(x[1])} for k, x in sorted(ts.items(), key=lambda x: -x[1][0])],
                "voters": [{"n": n, "t": tk, "tn": teams[tk]["name"], "tc": teams[tk]["color"], "p": c} for (n, tk), c in sorted(vs.items(), key=lambda x: -x[1])],
                "seats": [{"t": t, "name": teams[t]["name"], "color": teams[t]["color"], "n": by_id(s["holder"])["nickname"], "price": s["price"], "k": s["k"], "since": iso_(s["since"])}
                          for (pi, t), s in sorted(seats.items(), key=lambda x: -x[1]["price"]) if pi == i and s["holder"]],
                "recent": [{"n": v["n"], "t": v["t"], "a": v["w"], "at": iso_(v["at"])} for v in sorted(votes, key=lambda v: v["at"], reverse=True) if v["i"] == i][:8],
                "base": BASE, "step": STEP}
    if name == "pw_search":
        q = b["p_q"].lower()
        return [{"id": i, "name": n, "country": c} for i, (c, n) in PROV.items() if n and q in n.lower()]
    if name == "pw_purchase_start":
        p = need(b["p_secret"]); tm = teams[b["p_team"]]
        if tm["owner"] == p["id"]: raise E("already_owner")
        pid = str(uuid.uuid4()); purchases[pid] = {"player": p, "team": tm, "status": "pending", "kind": "team"}
        return {"id": pid, "price_cents": 200, "url": f"https://pay.test/checkout/buy/x?quantity=2&checkout[custom][purchase_id]={pid}"}
    if name == "pw_seat_start":
        p = need(b["p_secret"])
        if not p["team"]: raise E("no_team")
        s = seats.get((b["p_province"], p["team"]))
        if s and s["holder"] == p["id"]: raise E("already_chair")
        price = seat_price(b["p_province"], p["team"])
        pid = str(uuid.uuid4()); purchases[pid] = {"player": p, "team": teams[p["team"]], "status": "pending", "kind": "seat", "province": b["p_province"], "price": price}
        return {"id": pid, "price_cents": price, "url": f"https://pay.test/checkout/buy/x?quantity={price // 100}&checkout[custom][purchase_id]={pid}"}
    if name == "pw_purchase_status":
        pu = purchases.get(b["p_purchase"])
        if not pu or players.get(b["p_secret"]) is not pu["player"]: return None
        i = pu.get("province")
        return {"status": pu["status"], "kind": pu["kind"], "team_id": pu["team"]["id"], "team": pu["team"]["name"],
                "province": i, "pname": PROV[i][1] if i else None, "country": PROV[i][0] if i else None, "problem": None}
    if name == "pw_chairs":
        lst = [{"i": i, "pn": PROV[i][1], "c": PROV[i][0], "t": t, "n": by_id(s["holder"])["nickname"], "price": s["price"], "k": s["k"], "since": iso_(s["since"])}
               for (i, t), s in sorted(seats.items(), key=lambda x: -x[1]["price"]) if s["holder"]]
        hold = {}
        for x in lst: hold.setdefault(x["n"], [0, 0, x["t"]]); hold[x["n"]][0] += 1; hold[x["n"]][1] += x["price"]
        return {"list": lst, "holders": [{"n": n, "t": v[2], "c": v[0], "s": v[1]} for n, v in sorted(hold.items(), key=lambda x: -x[1][0])], "total": len(lst)}
    if name == "pw_profile": return profile(b["p_nick"])
    raise E("unknown " + name)

def complete(pid):  # what the webhook + SQL do
    pu = purchases[pid]; pu["status"] = "paid"; p = pu["player"]
    if pu["kind"] == "seat":
        key = (pu["province"], pu["team"]["id"]); old = seats.get(key)
        if old and old["holder"]: by_id(old["holder"])["bank"] += hours_xp(old["since"])
        seats[key] = {"holder": p["id"], "price": pu["price"], "k": (old["k"] + 1) if old else 1, "since": now()}
        events.append({"k": "seat", "n": p["nickname"], "t": pu["team"]["id"], "i": pu["province"], "a": pu["price"], "at": now()})
        return
    pu["team"]["owner"] = p["id"]; pu["team"]["sales"] += 1
    p["team"], p["joined"] = pu["team"]["id"], now()
    events.append({"k": "sold", "n": p["nickname"], "t": pu["team"]["id"], "i": None, "a": 200, "at": now()})

CORS = {"Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "apikey, content-type", "Access-Control-Allow-Methods": "POST, GET, OPTIONS"}
def route(r):
    url = r.request.url
    if url.startswith("file://"): return r.continue_()
    if r.request.method == "OPTIONS": return r.fulfill(status=204, headers=CORS)
    if "cdnjs.cloudflare.com/ajax/libs/d3/7.9.0" in url: return r.fulfill(status=200, content_type="application/javascript", body=D3)
    if "fonts.g" in url: return r.fulfill(status=200, content_type="text/css", body="")
    if "world-atlas" in url: return r.fulfill(status=200, content_type="application/json", headers=CORS, body=json.dumps(TOPO))
    if "/storage/v1/object/public/maps/adm1/" in url:
        cc = url.rsplit("/", 1)[1].split(".")[0]
        if cc in FILES: return r.fulfill(status=200, content_type="application/json", headers=CORS, body=json.dumps(FILES[cc]))
        return r.fulfill(status=400, headers=CORS, body='{"error":"not found"}')
    if "/rest/v1/rpc/" in url:
        name = url.rsplit("/", 1)[1]
        body = json.loads(r.request.post_data or "{}")
        try: st, data = 200, rpc(name, body)
        except E as e: st, data = 400, {"message": str(e)}
        return r.fulfill(status=st, content_type="application/json", headers=CORS, body=json.dumps(data))
    if "pay.test" in url:
        return r.fulfill(status=200, content_type="text/html", body="<h1>Mock checkout</h1>")
    return r.abort()

def click_path(page, sel, key, val):
    page.evaluate("""([sel, key, val]) => {
      const p = [...document.querySelectorAll(sel)].find(e => e.__data__ && e.__data__[key] === val);
      if (!p) throw new Error('no path ' + val);
      p.dispatchEvent(new MouseEvent('click', {bubbles: true}));
    }""", [sel, key, val])

errors = []
def watch(page, tag):
    page.on("pageerror", lambda e: errors.append(f"{tag} pageerror: {e}"))
    page.on("console", lambda m: errors.append(f"{tag} console.{m.type}: {m.text}") if m.type == "error" and "400" not in m.text else None)
def overflow(page):
    return page.evaluate("() => document.documentElement.scrollWidth > innerWidth + 1")
def txt(page, sel):
    return (page.text_content(sel) or "").strip()
def pid_from(url):
    return url.split("purchase_id]=")[1].split("&")[0] if "purchase_id]=" in url else url.split("purchase_id%5D=")[1].split("&")[0]

with sync_playwright() as pw:
    b = pw.chromium.launch()
    ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2, locale="tr-TR", is_mobile=True, has_touch=True)
    ctx.grant_permissions(["clipboard-read", "clipboard-write"])
    ctx.route("**/*", route)
    page = ctx.new_page(); watch(page, "phone")
    page.goto(PAGE)
    page.wait_for_selector("#map path.land"); page.wait_for_timeout(700)
    print("1 start:", {"cta": txt(page, "#cta"), "clock": txt(page, "#clockBtn"), "overflow": overflow(page),
                       "ticker": page.eval_on_selector_all("#tickerTrack > span", "e => e.slice(0,3).map(x => x.textContent)"),
                       "wbar": txt(page, "#wbar")[:90], "home": page.eval_on_selector_all("#provBody h3", "e => e.map(x => x.textContent)")})
    page.screenshot(path=str(OUT / "01_start.png"))
    page.screenshot(path=str(OUT / "01b_start_full.png"), full_page=True)
    page.click("#cta"); page.wait_for_selector("#joinDlg[open]")
    page.fill("#nickInput", "Ali"); page.click("#joinGo"); page.wait_for_timeout(200)
    print("2 taken:", txt(page, "#joinErr"))
    page.fill("#nickInput", "Burak"); page.click("#joinGo"); page.wait_for_selector("#teamDlg[open]"); page.wait_for_timeout(300)
    page.click("#segNew"); page.fill("#teamName", "Tokat Aslanları"); page.click("#palette button:nth-child(4)"); page.click("#teamGo"); page.wait_for_timeout(400)
    print("2 created dock:", txt(page, "#dockWho"), "|", txt(page, "#dockState"), "| clock:", txt(page, "#clockBtn"))
    click_path(page, "#map path.land", "code", "TR"); page.wait_for_timeout(900)
    print("3 country view:", txt(page, "#provBody h2"), "|", txt(page, "#provBody .c-sub"), "| rows:", page.eval_on_selector_all("#provBody ul.list li", "e => e.map(x => x.textContent)"))
    page.screenshot(path=str(OUT / "03_country.png"), full_page=True)
    click_path(page, "#map path.prov", "id", "TR-60"); page.wait_for_timeout(500)
    print("4 tokat:", txt(page, "#provBody h2"), "| seat btn:", page.eval_on_selector_all("#provBody .seatbox button", "e => e.map(x => x.textContent)"),
          "| actions:", page.eval_on_selector_all("#provBody .actions button", "e => e.map(x => x.textContent)"), "| cta:", txt(page, "#cta"))
    page.screenshot(path=str(OUT / "04_tokat.png"), full_page=True)
    page.click("#cta"); page.wait_for_timeout(600)
    print("4 vote toast:", txt(page, "#toast"), "| dock:", txt(page, "#dockState"), "| clock:", txt(page, "#clockBtn"))
    page.click("#provBody .actions button >> nth=0"); page.wait_for_timeout(150)
    print("4 rally armed:", page.eval_on_selector_all("#provBody .actions button", "e => e.map(x => x.textContent)"))
    page.click("#provBody .actions button >> nth=0"); page.wait_for_timeout(700)
    print("4 rally:", txt(page, "#toast"), "| bars:", page.eval_on_selector_all("#provBody .bar", "e => e.map(x => x.textContent)"),
          "| actions:", page.eval_on_selector_all("#provBody .actions button", "e => e.map(x => x.textContent)"))
    # chair purchase on Tokat
    page.click("#provBody .seatbox button.cta"); page.wait_for_selector("#seatDlg[open]")
    print("5 seat dlg:", txt(page, "#seatPrice"), "|", txt(page, "#seatNow"), "|", page.eval_on_selector_all("#seatPerks li", "e => e.map(x => x.textContent)"))
    page.screenshot(path=str(OUT / "05_seatdlg.png"))
    page.click("#seatGo"); page.wait_for_url("**pay.test**")
    pid = pid_from(page.url); print("5 checkout url:", page.url[:70]); complete(pid)
    page.goto(PAGE + "#p=TR-60"); page.wait_for_selector("#map path.land"); page.wait_for_timeout(2500)
    print("5 back:", txt(page, "#toast"), "| h2:", txt(page, "#provBody h2"), "| seat:", txt(page, "#provBody .seatbox")[:120], "| gov:", txt(page, "#provBody .card"))
    page.screenshot(path=str(OUT / "05b_chair.png"), full_page=True)
    # Ankara: someone else's team chair
    goto = page.evaluate("() => location.hash")
    page.fill("#findInput", "ank"); page.wait_for_timeout(500); page.click("#findList .opt >> nth=0"); page.wait_for_timeout(700)
    print("6 ankara:", txt(page, "#provBody h2"), "| gov:", txt(page, "#provBody .card"), "| other chairs:", page.eval_on_selector_all("#provBody .seatbox ~ .eyebrow + ul li", "e => e.map(x => x.textContent)"), "| hash", goto)
    page.fill("#findInput", "tok"); page.wait_for_timeout(500)
    print("6 search:", page.eval_on_selector_all("#findList .opt", "els => els.map(e => e.textContent)"))
    page.click("#findList .opt:nth-child(2)"); page.wait_for_timeout(1200)
    print("6 tokyo:", txt(page, "#provBody h2"))
    # teams tab
    page.click("#tabTeams"); page.wait_for_timeout(200)
    page.fill("#teamsBody input[type=search]", "ma"); page.wait_for_timeout(150)
    print("7 filter focus kept:", page.evaluate("() => document.activeElement && document.activeElement.type === 'search'"), page.eval_on_selector_all("#teamsBody ul.list li", "e => e.map(x => x.textContent)"))
    page.fill("#teamsBody input[type=search]", ""); page.wait_for_timeout(100)
    page.click("#teamsBody ul.list li.click >> nth=0"); page.wait_for_timeout(500)
    print("7 team:", txt(page, "#teamsBody h2"), "| stats:", page.eval_on_selector_all("#teamsBody .stat", "e => e.map(x => x.textContent)"),
          "| actions:", page.eval_on_selector_all("#teamsBody .actions button", "e => e.map(x => x.textContent)"))
    page.screenshot(path=str(OUT / "07_team.png"), full_page=True)
    buy = page.locator("#teamsBody .actions button", has_text="satın al")
    if buy.count():
        buy.first.click(); page.wait_for_selector("#buyDlg[open]"); page.click("#buyGo"); page.wait_for_url("**pay.test**")
        complete(pid_from(page.url)); page.goto(PAGE); page.wait_for_selector("#map path.land"); page.wait_for_timeout(2500)
        print("8 bought:", txt(page, "#toast"), "| dock:", txt(page, "#dockWho"))
    # rankings
    page.click("#tabRank"); page.wait_for_timeout(200)
    for i, mode in enumerate(["teams", "players", "chairs", "countries"]):
        page.click(f"#rankBody .seg button >> nth={i}"); page.wait_for_timeout(300)
        print(f"9 rank {mode}:", page.eval_on_selector_all("#rankBody ul.list li", "e => e.slice(0,3).map(x => x.textContent)"))
        page.screenshot(path=str(OUT / f"09_rank_{mode}.png"), full_page=True)
    page.click("#tabLive"); page.wait_for_timeout(200)
    print("10 live:", page.eval_on_selector_all("#liveBody ul.feed li", "e => e.slice(0,4).map(x => x.textContent)"))
    page.screenshot(path=str(OUT / "10_live.png"), full_page=True)
    page.click("#tabMe"); page.wait_for_timeout(500)
    print("11 me:", txt(page, "#meBody h2"), "|", txt(page, "#meBody .c-sub"), "|", txt(page, "#meBody .xp small"), "| stats:", page.eval_on_selector_all("#meBody .stat", "e => e.map(x => x.textContent)"),
          "| seats:", page.eval_on_selector_all("#meBody ul.list li", "e => e.map(x => x.textContent)"))
    page.screenshot(path=str(OUT / "11_me.png"), full_page=True)
    page.click("#meBody .acct .actions button >> nth=0"); page.wait_for_timeout(100)
    code = txt(page, "#codeBox").replace(" ", "")
    print("11 code shown ok:", code == players_secret if (players_secret := next(s for s, p in players.items() if p["nickname"] == "Burak")) else None)
    page.click("#meBody .acct .actions button >> nth=3"); page.wait_for_selector("#logoutDlg[open]"); page.click("#logoutGo"); page.wait_for_timeout(300)
    print("12 signed out:", txt(page, "#toast"), "| dock:", txt(page, "#dockWho"), "| me:", txt(page, "#meBody")[:60])
    page.click("#meBody .actions button >> nth=1"); page.wait_for_selector("#restoreDlg[open]")
    page.fill("#codeInput", "deadbeef" * 8); page.click("#restoreGo"); page.wait_for_timeout(200)
    print("12 bad code:", txt(page, "#restoreErr"))
    page.fill("#codeInput", " ".join(code[i:i + 8] for i in range(0, 64, 8))); page.click("#restoreGo"); page.wait_for_timeout(600)
    print("12 restored:", txt(page, "#toast"), "| dock:", txt(page, "#dockWho"))
    # other profile via link
    page.goto(PAGE + "#u=Ayse"); page.wait_for_selector("#map path.land"); page.wait_for_timeout(1200)
    print("13 profile route:", txt(page, "#meBody h2"), "|", page.eval_on_selector_all("#meBody ul.list li", "e => e.map(x => x.textContent)"))
    page.screenshot(path=str(OUT / "13_profile_other.png"), full_page=True)
    page.click("#helpBtn"); page.wait_for_selector("#docDlg[open]"); page.wait_for_timeout(100)
    print("14 help:", txt(page, "#docBody")[:160])
    page.screenshot(path=str(OUT / "14_help.png"))
    page.click("#docSeg button >> nth=1"); page.wait_for_timeout(100)
    print("14 terms:", txt(page, "#docBody")[:100], "| overflow:", overflow(page))
    page.click("#docDlg .row .cta")
    ctx.close()

    ctx = b.new_context(viewport={"width": 1440, "height": 900}, locale="en-US")
    ctx.route("**/*", route)
    page = ctx.new_page(); watch(page, "desktop")
    page.goto(PAGE + "#p=TR-06"); page.wait_for_selector("#map path.land"); page.wait_for_timeout(1800)
    print("15 desktop route:", txt(page, "#provBody h2"), "| hstats:", txt(page, "#hstats"))
    page.screenshot(path=str(OUT / "15_desktop.png"))
    page.mouse.wheel(0, 900)
    page.click("#tabRank"); page.click("#rankBody .seg button >> nth=2"); page.wait_for_timeout(300)
    page.screenshot(path=str(OUT / "16_desktop_rank.png"))
    page.click("#brandBtn"); page.wait_for_timeout(500)
    page.screenshot(path=str(OUT / "17_desktop_home.png"))
    ctx.close()

    ctx = b.new_context(viewport={"width": 360, "height": 740}, device_scale_factor=2, locale="en-US", is_mobile=True, has_touch=True)
    ctx.route("**/*", route)
    page = ctx.new_page(); watch(page, "small")
    page.goto(PAGE + "#c=JP"); page.wait_for_selector("#map path.land"); page.wait_for_timeout(1500)
    print("18 small:", txt(page, "#provBody h2"), "| overflow:", overflow(page), "| tabs scroll:", page.evaluate("() => { const t = document.querySelector('.tabs'); return [t.scrollWidth, t.clientWidth]; }"))
    page.screenshot(path=str(OUT / "18_small.png"), full_page=True)
    ctx.close(); b.close()
print("ERRORS:", errors or "none")
