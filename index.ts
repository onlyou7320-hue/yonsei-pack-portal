// 부문 업무포털(통합포털) 사번·비밀번호로 포장팀 사이트에 로그인 (연동 로그인)
// Supabase → Edge Functions → Deploy a new function → Via Editor → 이름: portal-login → 이 내용을 붙여 넣고 Deploy
// 올린 뒤 함수 Details(설정)에서 「Verify JWT with legacy secret」(Enforce JWT verification)을 꺼 주세요.
//   (로그인하기 전이라 포장팀 사이트 토큰이 아직 없기 때문. 대신 이 함수가 부문 업무포털 토큰을 직접 검사합니다)
// SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY 는 Supabase가 자동으로 넣어 줍니다. 따로 넣을 Secret 없음.
//
// 동작
//  1. 화면이 부문 업무포털에 로그인해 받은 토큰을 보냄
//  2. 부문 업무포털 서버에 그 토큰이 진짜인지 물어봄 (가짜·만료 토큰은 거절)
//  3. 부문 업무포털 회원 명단에서 사번 · 이름 · 팀 · 상태를 읽음 (승인된 회원만)
//  4. 포장팀 사이트에 같은 사번 계정이 있으면 그 계정으로, 없으면 새로 만들어 로그인 표를 돌려줌
//     부문 업무포털에서 「포장팀」으로 승인된 사람은 자동 승인, 다른 팀은 포장팀 관리자 승인 대기
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const PORTAL_URL = Deno.env.get("PORTAL_URL") ?? "https://vogcnzfxntaorxnkpznl.supabase.co";
const PORTAL_KEY = Deno.env.get("PORTAL_KEY") ?? "sb_publishable_9GJBXcv4PgXUxwYY17gttw_PE15ILpK";
const EMAIL_PATTERN = Deno.env.get("PACK_EMAIL_PATTERN") ?? "{emp}@yonsei-pack.com";
const AUTO_TEAM = Deno.env.get("PACK_AUTO_TEAM") ?? "포장팀";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const low = (x: unknown) => String(x ?? "").trim().toLowerCase();

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { token } = await req.json().catch(() => ({}));
    if (!token) return json({ error: "부문 업무포털 로그인 정보가 없습니다" }, 400);

    // 2) 토큰 검사 — 부문 업무포털 인증 서버가 직접 확인
    const ur = await fetch(`${PORTAL_URL}/auth/v1/user`, { headers: { apikey: PORTAL_KEY, Authorization: `Bearer ${token}` } });
    if (!ur.ok) return json({ error: "부문 업무포털 로그인이 확인되지 않습니다. 다시 로그인해 주세요." }, 401);
    const pu = await ur.json();
    const pEmail = low(pu.email);

    // 3) 회원 명단 (본인 토큰으로 읽음 — 부문 업무포털 규칙을 그대로 따름)
    const sr = await fetch(`${PORTAL_URL}/rest/v1/app_state?id=eq.1&select=users:data->users`, { headers: { apikey: PORTAL_KEY, Authorization: `Bearer ${token}` } });
    if (!sr.ok) return json({ error: `부문 업무포털 회원 정보를 읽지 못했습니다 (${sr.status})` }, 502);
    const users: Record<string, unknown>[] = ((await sr.json())[0]?.users) ?? [];
    const me = users.find((u) => low(u.authEmail) === pEmail || low(u.email) === pEmail);
    if (!me) return json({ error: "부문 업무포털 회원 명단에서 본인을 찾지 못했습니다" }, 403);
    const st = low(me.status);
    if (st && st !== "active" && st !== "approved") return json({ error: "부문 업무포털에서 아직 승인되지 않은 계정입니다" }, 403);
    const emp = low(me.empNo);
    if (!/^[a-z0-9._-]+$/.test(emp)) return json({ error: "부문 업무포털 사번 형식을 읽지 못했습니다" }, 400);
    const name = String(me.name ?? "").trim() || emp;
    const team = String(me.team ?? "");
    const auto = !!AUTO_TEAM && team.indexOf(AUTO_TEAM) >= 0;

    // 4) 포장팀 사이트 계정 찾기 / 만들기
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: prof } = await admin.from("profiles").select("id,approved,name").eq("emp_no", emp).maybeSingle();
    let email = "";
    let created = false;
    if (prof) {
      const { data: g, error } = await admin.auth.admin.getUserById(prof.id);
      if (error || !g?.user?.email) return json({ error: "포장팀 사이트 계정을 읽지 못했습니다" }, 500);
      email = g.user.email;
      if (auto && !prof.approved) await admin.from("profiles").update({ approved: true }).eq("id", prof.id);
    } else {
      email = EMAIL_PATTERN.replace("{emp}", emp);
      const pw = crypto.randomUUID() + crypto.randomUUID(); // 쓰지 않는 임의 비밀번호 (로그인은 항상 이 연동으로)
      const { data: c, error } = await admin.auth.admin.createUser({ email, password: pw, email_confirm: true, user_metadata: { name, emp_no: emp, via: "portal" } });
      if (error) return json({ error: `포장팀 사이트 계정을 만들지 못했습니다: ${error.message}` }, 500);
      created = true;
      if (auto && c.user) await admin.from("profiles").update({ approved: true }).eq("id", c.user.id).eq("approved", false);
    }

    // 로그인 표 (메일은 보내지 않음, 화면이 바로 사용)
    const { data: link, error: le } = await admin.auth.admin.generateLink({ type: "magiclink", email });
    if (le || !link?.properties?.hashed_token) return json({ error: `로그인 표를 만들지 못했습니다: ${le?.message ?? ""}` }, 500);
    return json({ token_hash: link.properties.hashed_token, emp, name, team, created, auto });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
