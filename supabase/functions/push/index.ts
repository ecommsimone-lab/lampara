// Lámpara Bíblica · función "push": envía los avisos al celular (Web Push).
// Supabase → Edge Functions → Deploy a new function → Via Editor → nombre: push → pegar → Deploy.
// No necesita configurar llaves: la primera vez crea sus propias llaves VAPID
// y las guarda en la tabla privada push_config (nadie más puede leer la privada).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

type Config = { vapid_public: string | null; vapid_private: string | null; subject: string };

async function config(): Promise<Config> {
  const read = async () => {
    const { data, error } = await sb.from("push_config").select("vapid_public,vapid_private,subject").eq("id", 1).single();
    if (error) throw error;
    return data as Config;
  };
  let c = await read();
  if (!c.vapid_public || !c.vapid_private) {
    const k = webpush.generateVAPIDKeys();
    await sb.from("push_config").update({ vapid_public: k.publicKey, vapid_private: k.privateKey }).eq("id", 1).is("vapid_public", null);
    c = await read();
  }
  return c;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const c = await config();
    if (body.init) return json({ publicKey: c.vapid_public });
    if (!body.id) return json({ error: "falta id" }, 400);

    // Cada aviso se envía una sola vez
    const { data: n } = await sb.from("notifications")
      .update({ pushed_at: new Date().toISOString() })
      .eq("id", body.id).is("pushed_at", null)
      .select("id,user_id,type,data").maybeSingle();
    if (!n) return json({ skipped: true });

    const { data: subs } = await sb.from("push_subs").select("endpoint,p256dh,auth").eq("user_id", n.user_id);
    if (!subs || !subs.length) return json({ sent: 0 });

    webpush.setVapidDetails(c.subject, c.vapid_public!, c.vapid_private!);
    const payload = JSON.stringify({
      title: n.data?.title || "Lámpara",
      body: n.data?.body || "",
      tag: n.type,
      url: "./?ir=avisos",
    });
    let sent = 0;
    for (const s of subs) {
      try {
        const d = webpush.generateRequestDetails(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          payload,
          { TTL: 60 * 60 * 24, urgency: "normal" },
        );
        const headers: Record<string, string> = {};
        for (const [k, v] of Object.entries(d.headers)) if (k.toLowerCase() !== "content-length") headers[k] = String(v);
        const r = await fetch(d.endpoint, { method: "POST", headers, body: d.body as Uint8Array });
        if (r.status === 404 || r.status === 410) await sb.from("push_subs").delete().eq("endpoint", s.endpoint);
        else if (r.ok) sent++;
        await r.body?.cancel();
      } catch (_e) { /* un celular con error no detiene a los demás */ }
    }
    return json({ sent });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
