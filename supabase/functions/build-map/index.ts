// Builds one country's province (ADM1) map from geoBoundaries (CC BY 4.0),
// stores it in the public "maps" bucket and registers the provinces in the database.
// Body: { iso2: "TR", iso3: "TUR", token: "<build token>" }

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

type Pt = [number, number];
type Ring = Pt[];
type Poly = Ring[];

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });

async function rpc(name: string, body: unknown) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`rpc ${name} ${r.status} ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}

const round = (v: number) => Math.round(v * 1000) / 1000;

function area2(r: Ring) {
  let s = 0;
  for (let i = 0; i < r.length - 1; i++) s += r[i][0] * r[i + 1][1] - r[i + 1][0] * r[i][1];
  return s;
}

// Douglas-Peucker on a closed ring (first point == last point)
function simplify(pts: Ring, tol: number): Ring {
  const n = pts.length;
  if (n <= 5 || tol <= 0) return pts;
  const keep = new Uint8Array(n);
  keep[0] = keep[n - 1] = 1;
  let far = 1, fd = -1;
  for (let i = 1; i < n - 1; i++) {
    const d = (pts[i][0] - pts[0][0]) ** 2 + (pts[i][1] - pts[0][1]) ** 2;
    if (d > fd) { fd = d; far = i; }
  }
  keep[far] = 1;
  const t2 = tol * tol;
  const stack: Array<[number, number]> = [[0, far], [far, n - 1]];
  while (stack.length) {
    const [a, b] = stack.pop()!;
    const [ax, ay] = pts[a], [bx, by] = pts[b];
    const dx = bx - ax, dy = by - ay, L = dx * dx + dy * dy;
    let idx = -1, md = t2;
    for (let i = a + 1; i < b; i++) {
      const [px, py] = pts[i];
      let d: number;
      if (L === 0) d = (px - ax) ** 2 + (py - ay) ** 2;
      else {
        let t = ((px - ax) * dx + (py - ay) * dy) / L;
        t = Math.max(0, Math.min(1, t));
        d = (px - (ax + t * dx)) ** 2 + (py - (ay + t * dy)) ** 2;
      }
      if (d > md) { md = d; idx = i; }
    }
    if (idx >= 0) { keep[idx] = 1; stack.push([a, idx], [idx, b]); }
  }
  const out: Ring = [];
  for (let i = 0; i < n; i++) if (keep[i]) out.push(pts[i]);
  return out;
}

function cleanRing(r: Ring, tol: number, exterior: boolean): Ring | null {
  if (!Array.isArray(r) || r.length < 3) return null;
  let pts: Ring = [];
  for (const p of r) {
    const q: Pt = [round(+p[0]), round(+p[1])];
    const last = pts[pts.length - 1];
    if (!last || last[0] !== q[0] || last[1] !== q[1]) pts.push(q);
  }
  if (pts.length && (pts[0][0] !== pts[pts.length - 1][0] || pts[0][1] !== pts[pts.length - 1][1])) pts.push(pts[0]);
  pts = simplify(pts, tol);
  if (pts.length < 4) return null;
  const a = area2(pts);
  if (a === 0) return null;
  // d3-geo wants exterior rings clockwise and holes counter-clockwise
  if ((exterior && a > 0) || (!exterior && a < 0)) pts.reverse();
  return pts;
}

function cleanPoly(poly: Poly, tol: number): Poly | null {
  const ext = cleanRing(poly[0], tol, true);
  if (!ext) return null;
  const out: Poly = [ext];
  for (let k = 1; k < poly.length; k++) {
    const h = cleanRing(poly[k], tol, false);
    if (h) out.push(h);
  }
  return out;
}

function polysOf(g: any): Poly[] {
  if (!g) return [];
  if (g.type === "Polygon") return [g.coordinates];
  if (g.type === "MultiPolygon") return g.coordinates;
  if (g.type === "GeometryCollection") return (g.geometries || []).flatMap(polysOf);
  return [];
}

function bbox(features: any[]) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const f of features) for (const poly of polysOf(f.geometry)) for (const p of poly[0] || []) {
    if (p[0] < x0) x0 = p[0]; if (p[0] > x1) x1 = p[0];
    if (p[1] < y0) y0 = p[1]; if (p[1] > y1) y1 = p[1];
  }
  return [x0, y0, x1, y1];
}

async function fetchJson(url: string) {
  const r = await fetch(url, { headers: { "User-Agent": "paint-the-world-map-builder" } });
  if (!r.ok) throw new Error(`fetch ${r.status} ${url}`);
  return await r.json();
}

Deno.serve(async (req) => {
  try {
    const { iso2, iso3, token } = await req.json();
    const cfg = await rpc("pw_admin_config", {});
    if (!token || token !== cfg.build_token) return json({ error: "forbidden" }, 403);
    if (!/^[A-Z]{2}$/.test(iso2) || !/^[A-Z]{3}$/.test(iso3)) return json({ error: "bad code" }, 400);

    let src: any[] = [];
    let source = "none";
    const api = await fetch(`https://www.geoboundaries.org/api/current/gbOpen/${iso3}/ADM1/`);
    if (api.ok) {
      const text = await api.text();
      let meta: any = null;
      try { meta = JSON.parse(text); } catch { meta = null; }
      const m = Array.isArray(meta) ? meta[0] : meta;
      const url = m && (m.simplifiedGeometryGeoJSON || m.gjDownloadURL);
      if (url) {
        const gj = await fetchJson(url);
        src = gj.features || [];
        source = "geoBoundaries " + (m.boundaryYearRepresented || "") + " " + (m.boundaryID || "");
      }
    }

    const [x0, y0, x1, y1] = src.length ? bbox(src) : [0, 0, 0, 0];
    const diag = Math.hypot(x1 - x0, y1 - y0) || 1;
    const tol = Math.min(0.02, Math.max(0.002, diag / 4000));
    const minArea = (tol * 3) ** 2 * 2;

    // ids: ISO 3166-2 code when valid and unique, otherwise ISO2-n
    const isoCount = new Map<string, number>();
    for (const f of src) {
      const c = String(f.properties?.shapeISO || "").trim().toUpperCase();
      isoCount.set(c, (isoCount.get(c) || 0) + 1);
    }
    const sorted = [...src].sort((a, b) =>
      String(a.properties?.shapeName || "").localeCompare(String(b.properties?.shapeName || "")));
    const used = new Set<string>();
    let n = 0;
    const features: any[] = [];
    const rows: Array<{ id: string; name: string | null }> = [];
    for (const f of sorted) {
      n++;
      const name = String(f.properties?.shapeName || "").trim() || null;
      const iso = String(f.properties?.shapeISO || "").trim().toUpperCase();
      let id = (iso.startsWith(iso2 + "-") && /^[A-Z]{2}-[A-Z0-9]{1,4}$/.test(iso) && isoCount.get(iso) === 1) ? iso : `${iso2}-G${n}`;
      while (used.has(id)) id = `${iso2}-G${++n}`;
      const polys = polysOf(f.geometry).map((p) => ({ p, a: Math.abs(area2(p[0] || [])) }));
      polys.sort((a, b) => b.a - a.a);
      const kept: Poly[] = [];
      polys.forEach(({ p, a }, k) => {
        if (k > 0 && a < minArea) return;
        const c = cleanPoly(p, k === 0 ? Math.min(tol, Math.sqrt(a) / 10 || tol) : tol);
        if (c) kept.push(c);
      });
      if (!kept.length) continue;
      used.add(id);
      rows.push({ id, name });
      features.push({
        type: "Feature",
        id,
        properties: { n: name },
        geometry: kept.length === 1 ? { type: "Polygon", coordinates: kept[0] } : { type: "MultiPolygon", coordinates: kept },
      });
    }

    if (!rows.length) rows.push({ id: iso2, name: null }); // no subdivisions: the whole country is one province

    const out = JSON.stringify({ type: "FeatureCollection", country: iso2, source, features });
    const up = await fetch(`${SB_URL}/storage/v1/object/maps/adm1/${iso2}.json`, {
      method: "POST",
      headers: {
        apikey: SB_KEY,
        Authorization: `Bearer ${SB_KEY}`,
        "Content-Type": "application/json",
        "x-upsert": "true",
        "cache-control": "max-age=3600",
      },
      body: out,
    });
    if (!up.ok) throw new Error(`upload ${up.status} ${(await up.text()).slice(0, 200)}`);
    const inserted = await rpc("pw_admin_put_provinces", { p_country: iso2, p_rows: rows });
    return json({ iso2, provinces: rows.length, inserted, bytes: out.length, tol, source });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
