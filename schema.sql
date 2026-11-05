-- 포장팀 포털 데이터베이스 (Supabase → SQL Editor 에 통째로 붙여 넣고 Run)
-- 여러 번 실행해도 안전하도록 if not exists / or replace 로 작성했습니다.

-- 1) 사용자 프로필 ------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  emp_no     text unique,
  name       text not null,
  role       text not null default 'member',   -- member | admin
  approved   boolean not null default false,    -- 관리자가 승인해야 입력 가능
  created_at timestamptz not null default now()
);

-- 가입하면 프로필 자동 생성. 맨 처음 가입한 사람은 관리자 + 승인 상태로 만듭니다.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare first boolean;
begin
  select not exists(select 1 from public.profiles) into first;
  insert into public.profiles(id, emp_no, name, role, approved)
  values (new.id,
          new.raw_user_meta_data->>'emp_no',
          coalesce(new.raw_user_meta_data->>'name', '이름 없음'),
          case when first then 'admin' else 'member' end,
          first);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select approved from public.profiles where id = auth.uid()), false) $$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' and approved from public.profiles where id = auth.uid()), false) $$;
create or replace function public.my_name() returns text
language sql stable security definer set search_path = public as $$
  select name from public.profiles where id = auth.uid() $$;

-- 2) OEE 일일 입력 (엑셀 「일일입력」 시트와 같은 칸) ------------------------
create table if not exists public.oee_daily (
  d          date not null,
  line       text not null,            -- A~F
  ster       text,                     -- 연결 멸균호기
  item       text,                     -- 품목
  ml         numeric,                  -- 용량(ml)
  order_qty  numeric,                  -- 생산지시량(개)
  sip        text,                     -- SIP 시작 (HH:MM)
  ps         text,                     -- 생산 시작
  pe         text,                     -- 생산 종료
  cip        text,                     -- CIP 종료
  qty        numeric,                  -- 포장 생산량(개)
  ster_l     numeric,                  -- 멸균기 적산량(L)
  note       text,
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (d, line)
);

-- 3) 정지 기록 (엑셀 「정지기록」 시트) ----------------------------------------
create table if not exists public.oee_stops (
  id         bigserial primary key,
  d          date not null,
  line       text not null,
  t_start    text,
  t_end      text,
  code       int,                      -- 1 계획정지 2 고장 3 준비교체 4 자재 대기 5 순간정지 6 기타 7 상류(유액) 대기 8 중간 CIP
  brk        text,                     -- 고장 여부 Y/N
  content    text,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists oee_stops_dl on public.oee_stops(d, line);

-- 4) 휴무 체크 -----------------------------------------------------------------
create table if not exists public.roster (
  name text primary key,
  grp  int  not null default 1,        -- 1조 / 2조
  ord  int  not null default 0
);
create table if not exists public.off_cells (
  ym         text not null,            -- 2026-11
  name       text not null,
  day        int  not null,
  val        text not null,            -- 숫자(휴무 순번) · v · △ · ○ · * · 교
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (ym, name, day)
);

-- 5) 접근 규칙 (RLS) -----------------------------------------------------------
alter table public.profiles  enable row level security;
alter table public.oee_daily enable row level security;
alter table public.oee_stops enable row level security;
alter table public.roster    enable row level security;
alter table public.off_cells enable row level security;

drop policy if exists p_read  on public.profiles;
drop policy if exists p_admin on public.profiles;
create policy p_read  on public.profiles for select to authenticated using (true);
create policy p_admin on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists d_read  on public.oee_daily;
drop policy if exists d_write on public.oee_daily;
create policy d_read  on public.oee_daily for select to authenticated using (public.is_approved());
create policy d_write on public.oee_daily for all    to authenticated using (public.is_approved()) with check (public.is_approved());

drop policy if exists s_read  on public.oee_stops;
drop policy if exists s_write on public.oee_stops;
create policy s_read  on public.oee_stops for select to authenticated using (public.is_approved());
create policy s_write on public.oee_stops for all    to authenticated using (public.is_approved()) with check (public.is_approved());

drop policy if exists r_read  on public.roster;
drop policy if exists r_write on public.roster;
create policy r_read  on public.roster for select to authenticated using (public.is_approved());
create policy r_write on public.roster for all    to authenticated using (public.is_admin()) with check (public.is_admin());

-- 휴무: 승인된 사람은 모두 볼 수 있고, 본인 이름 줄만 고칠 수 있음 (관리자는 전체)
drop policy if exists o_read  on public.off_cells;
drop policy if exists o_write on public.off_cells;
create policy o_read  on public.off_cells for select to authenticated using (public.is_approved());
create policy o_write on public.off_cells for all    to authenticated
  using (public.is_admin() or (public.is_approved() and name = public.my_name()))
  with check (public.is_admin() or (public.is_approved() and name = public.my_name()));

-- 6) 업데이트 (2026-11-05): 생산 기록 자동 연결용 — 정지 사유 코드 수정값 저장 칸
alter table public.oee_daily add column if not exists codes jsonb;

-- 7) 업데이트 (2026-11-05): 멸균팀 업무포털 자료 연계 (읽기 전용으로 받아 와 보관)
create table if not exists public.ster_journal (
  d     date not null,           -- 날짜
  unit  int,                     -- 멸균 호기 (1~5)
  idx   int  not null,           -- 같은 날 순번
  rec   jsonb not null,          -- 멸균팀 업무일지 한 줄 (품목 · 배치 · 멸균/생산/CIP 시각 · 생산량 L …)
  primary key (d, idx)
);
create table if not exists public.ster_kpi (
  month      text not null,      -- 2026-10
  unit       text not null,      -- 1~5 · 전체
  rec        jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (month, unit)
);
create table if not exists public.sync_log (
  k    text primary key,         -- ster
  at   timestamptz,
  info jsonb
);
alter table public.ster_journal enable row level security;
alter table public.ster_kpi     enable row level security;
alter table public.sync_log     enable row level security;
-- 승인된 팀원은 읽기만 가능. 쓰기는 Edge Function(ster-sync)만 함
drop policy if exists sj_read on public.ster_journal;
drop policy if exists sk_read on public.ster_kpi;
drop policy if exists sl_read on public.sync_log;
create policy sj_read on public.ster_journal for select to authenticated using (public.is_approved());
create policy sk_read on public.ster_kpi     for select to authenticated using (public.is_approved());
create policy sl_read on public.sync_log     for select to authenticated using (public.is_approved());
