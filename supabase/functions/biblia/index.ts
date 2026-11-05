// Ner · función "biblia": trae el texto de NTV y NBLA desde API.Bible sin exponer la llave.
// Supabase → Edge Functions → Deploy a new function → Via Editor → nombre: biblia → pegar → Deploy.
// Luego: Edge Functions → Secrets → Add new secret → nombre API_BIBLE_KEY, valor: tu llave de API.Bible.
// (Opcional) BIBLE_ID_NTV y BIBLE_ID_NBLA si la búsqueda automática no encuentra la versión.
//
// Reglas de API.Bible que cumple: el texto guardado se renueva cada 14 días (tabla bible_cache, SQL 27),
// se guardan menos de 500 versículos seguidos, y cada respuesta trae el copyright y el fumsToken
// para que la app reporte cada vez que muestra el texto (FUMS).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const API = "https://rest.api.bible/v1";
const KEY = Deno.env.get("API_BIBLE_KEY") ?? "";
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const VERSIONS: Record<string, { abbr: string; env: string; name: RegExp }> = {
  ntv: { abbr: "NTV", env: "BIBLE_ID_NTV", name: /nueva traducci[oó]n viviente/i },
  nbla: { abbr: "NBLA", env: "BIBLE_ID_NBLA", name: /nueva biblia de las am[eé]ricas/i },
};
const FRESH_MS = 14 * 24 * 3600 * 1000;

async function api(path: string) {
  const r = await fetch(API + path, { headers: { "api-key": KEY } });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(`API.Bible ${r.status}`), { status: r.status, body });
  return body;
}
let idCache: Record<string, string> = {};
async function bibleId(v: string) {
  const conf = VERSIONS[v]; if (!conf) throw new Error("version_desconocida");
  if (Deno.env.get(conf.env)) return Deno.env.get(conf.env)!;
  if (idCache[v]) return idCache[v];
  const { data } = await api(`/bibles?language=spa&include-full-details=false`);
  const list = (data || []) as Array<{ id: string; abbreviation?: string; abbreviationLocal?: string; name?: string; nameLocal?: string }>;
  const hit = list.find(b => [b.abbreviation, b.abbreviationLocal].some(a => (a || "").toUpperCase() === conf.abbr))
           || list.find(b => conf.name.test(`${b.name} ${b.nameLocal}`));
  if (!hit) throw Object.assign(new Error("version_no_disponible"), { status: 404 });
  idCache[v] = hit.id; return hit.id;
}
const clean = (t: string) => String(t || "").replace(/\s+/g, " ").replace(/^\s*¶\s*/, "").trim();

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!KEY) return json({ error: "falta_api_key" }, 500);
  try {
    const body = await req.json().catch(() => ({}));
    // Lista de Biblias en español disponibles para tu llave (para revisar los nombres y los id)
    if (body.action === "list") {
      const { data } = await api(`/bibles?language=spa`);
      return json({ bibles: (data || []).map((b: any) => ({ id: b.id, abbr: b.abbreviationLocal || b.abbreviation, name: b.nameLocal || b.name })) });
    }
    const v = String(body.version || ""); const items = Array.isArray(body.items) ? body.items.slice(0, 200) : [];
    if (!VERSIONS[v]) return json({ error: "version_desconocida" }, 400);
    const ids = items.map((x: any) => String(x.id));
    const { data: cached } = await sb.from("bible_cache").select("verse_id,text,copyright,fums,fetched_at").eq("version", v).in("verse_id", ids);
    const have = new Map((cached || []).filter((r: any) => Date.now() - new Date(r.fetched_at).getTime() < FRESH_MS).map((r: any) => [r.verse_id, r]));
    const need = items.filter((x: any) => !have.has(String(x.id)) && /^[1-3]?[A-Z]{2,3}\.\d+\.\d+(-[1-3]?[A-Z]{2,3}\.\d+\.\d+)?$/.test(String(x.passage)));
    let bid = "";
    if (need.length) bid = await bibleId(v);
    const fresh: any[] = []; let i = 0;
    const worker = async () => { while (i < need.length) { const x = need[i++];
      try {
        const q = "content-type=text&include-notes=false&include-titles=false&include-chapter-numbers=false&include-verse-numbers=false&include-verse-spans=false";
        const r = await api(`/bibles/${bid}/passages/${encodeURIComponent(x.passage)}?${q}`);
        fresh.push({ version: v, verse_id: String(x.id), passage: x.passage, text: clean(r.data?.content), copyright: clean(r.data?.copyright), fums: r.meta?.fumsToken || null, fetched_at: new Date().toISOString() });
      } catch (_e) { /* si un versículo falla, la app usa RVR1960 para ese */ }
    } };
    await Promise.all(Array.from({ length: Math.min(6, need.length) }, worker));
    if (fresh.length) await sb.from("bible_cache").upsert(fresh, { onConflict: "version,verse_id" });
    const out: Record<string, { text: string; copyright: string; fums: string | null }> = {};
    for (const r of [...have.values(), ...fresh]) if (r.text) out[r.verse_id] = { text: r.text, copyright: r.copyright, fums: r.fums };
    return json({ version: v, verses: out });
  } catch (e: any) {
    return json({ error: String(e?.message || e), status: e?.status || 500 }, e?.status === 403 ? 403 : e?.status === 404 ? 404 : 500);
  }
});
