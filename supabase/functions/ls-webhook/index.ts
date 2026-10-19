// Lemon Squeezy webhook. One $1 product is sold in quantities: a team costs 2 units, a province chair 1+ units.
// On a paid order the purchase is completed in SQL (team ownership or chair transfer; the price check lives there too).
// Webhook signing secret lives in pw.settings (ls_signing_secret); the same value goes into Lemon Squeezy.

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

async function hmacHex(secret: string, data: string) {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data)));
  return [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sameText(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: true });
  try {
    const raw = await req.text();
    const cfg = await rpc("pw_admin_config", {});
    const sig = (req.headers.get("x-signature") || "").toLowerCase();
    if (!cfg.ls_secret || !sameText(await hmacHex(cfg.ls_secret, raw), sig)) {
      return json({ error: "bad signature" }, 401);
    }
    const body = JSON.parse(raw);
    const event = body?.meta?.event_name;
    if (event !== "order_created") return json({ ignored: event ?? null });
    const attrs = body?.data?.attributes ?? {};
    if (attrs.status !== "paid") return json({ ignored: `status ${attrs.status}` });
    const purchase = body?.meta?.custom_data?.purchase_id;
    if (!purchase) return json({ ignored: "no purchase_id" });
    // cents paid before tax (tax-inclusive stores: the sticker price the buyer paid)
    const total = Number(attrs.total_usd ?? attrs.total ?? 0);
    const tax = Number(attrs.tax_usd ?? attrs.tax ?? 0);
    const paid = Math.max(0, Math.round(attrs.tax_inclusive ? total : total - tax));
    const res = await rpc("pw_admin_complete_purchase", {
      p_purchase: String(purchase),
      p_order: String(body?.data?.id ?? attrs.identifier ?? ""),
      p_amount: paid,
    });
    return json(res);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
