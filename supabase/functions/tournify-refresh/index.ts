// Laat de kapitein Tournify verversen vanuit de app: start de GitHub-workflow tournify.yml.
// Nodig: secret GITHUB_TOKEN (fine-grained token met Actions: Read and write op slaappiraten/slaappiraten.github.io).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const auth = req.headers.get("Authorization") ?? "";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return json({ error: "Niet ingelogd" }, 401);
  const { data: prof } = await sb.from("profiles").select("is_admin").eq("id", user.id).single();
  if (!prof?.is_admin) return json({ error: "Alleen de kapitein kan verversen" }, 403);
  const token = Deno.env.get("GITHUB_TOKEN");
  if (!token) return json({ error: "GITHUB_TOKEN ontbreekt" }, 500);
  const r = await fetch("https://api.github.com/repos/slaappiraten/slaappiraten.github.io/actions/workflows/tournify.yml/dispatches", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "User-Agent": "slaappiraten-app", "X-GitHub-Api-Version": "2022-11-28" },
    body: JSON.stringify({ ref: "main" }),
  });
  if (!r.ok) return json({ error: `GitHub ${r.status}: ${await r.text()}` }, 502);
  return json({ ok: true, startedAt: new Date().toISOString() });
});
