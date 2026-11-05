# 상온포장팀 포털

포장기 OEE 입력·집계, 휴무 체크, 통합포털 일지 작성 바로가기를 담은 상온포장팀 전용 사이트입니다.
GitHub Pages(화면) + Supabase(데이터)로 동작합니다.

## 파일

| 파일 | 내용 |
|---|---|
| `index.html` | 사이트 전체 화면 |
| `config.js` | Supabase 주소·공개 키, 통합포털 주소 |
| `schema.sql` | Supabase 테이블과 접근 규칙 (처음 한 번 실행) |

## 처음 설정 (한 번만)

### 1. Supabase 프로젝트 만들기
1. supabase.com 로그인 → **New project** → 이름 `yonsei-pack-portal`, 지역 **Northeast Asia (Seoul)**.
2. 왼쪽 **SQL Editor** → **New query** → `schema.sql` 내용을 전부 붙여 넣고 **Run**.
3. 왼쪽 **Authentication → Sign In / Providers → Email** 에서 **Confirm email** 을 끕니다.
   (사번으로 가입하는 방식이라 실제 메일을 보내지 않습니다.)
4. **Project Settings → API** 에서 **Project URL** 과 **anon public**(또는 publishable) 키를 복사합니다.
   service_role 키는 절대 쓰지 마세요.

### 2. config.js 수정
```js
window.PACK_CFG = {
  url: 'https://xxxx.supabase.co',
  key: '복사한 anon public 키',
  portal: 'https://ysmcavoy0104-hash.github.io/yonsei-dairy-portal/'
};
```

### 3. GitHub에 올리기
1. 저장소 `yonsei-pack-portal` → **Add file → Upload files** → 세 파일(`index.html`, `config.js`, `schema.sql`)과 이 README를 올리고 **Commit changes**.
2. **Settings → Pages** → Source **Deploy from a branch**, Branch **main / (root)** → **Save**.
3. 1~2분 뒤 `https://<계정명>.github.io/yonsei-pack-portal/` 에서 열립니다.

### 4. 첫 로그인과 자료 가져오기
1. 사이트에서 **가입 신청** — **맨 처음 가입한 사람이 자동으로 관리자**가 됩니다. 관리자 계정을 먼저 만드세요.
2. **관리** 탭 → **엑셀 가져오기**
   - OEE 일일 기록 양식(.xlsx) → 일일입력·정지기록을 그대로 가져옵니다.
   - 휴무표(.xlsx) → 「N월 휴무표」 시트의 명단(1조·2조)과 휴무 표시를 가져옵니다.
3. 팀원이 가입 신청하면 **관리 → 가입 승인**에서 승인합니다.
   휴무 체크는 **가입 때 적은 이름이 휴무 명단의 이름과 같아야** 본인 줄을 고칠 수 있습니다.

## OEE 자료 출처 (자동 연결)
- 생산 기록 사이트(https://jaehyun3163-blip.github.io/yonsei/)의 **종료한 생산(runs_log)** 과 **정지 기록(stops_log)** 을 읽기 전용으로 가져옵니다.
  생산 시작·종료·품목·생산량·생산지시량·정격 속도·정지(시각·설비·문제점)가 자동으로 들어옵니다. 지금 생산 중인 건은 종료 후 반영됩니다.
- 생산 기록에 없는 값 — **SIP 시작 · CIP 종료 · 용량 · 멸균기 적산량** — 은 OEE 현황에서 행을 눌러 「보완 입력」에 채웁니다.
  SIP · CIP가 비어 있으면 생산 시작 전 70분(F 100분) · 생산 종료 후 120분(F 150분)으로 추정하고 `*` 표시를 합니다.
- 정지 사유 코드는 내용으로 자동 분류하고(10분 이상 = 고장), 행을 열어 바꿀 수 있습니다. 선물포장기 정지는 제외합니다.

## 업데이트 SQL (이미 schema.sql을 실행한 경우 한 번 더)
```sql
alter table public.oee_daily add column if not exists codes jsonb;
```

## 계산 기준 (OEE 일일 기록 양식과 동일)
- 시간가동률 = 순생산 시간 ÷ 점유시간(SIP 시작 ~ CIP 종료)
- 순생산 시간 = 생산 시작 ~ 종료 − 정지시간 합
- 성능가동률 = 포장 생산량 ÷ (포장 CAPA × 순생산 시간)
- 양품률 = 포장 생산량(L) ÷ 멸균기 적산량(L), 포장 생산량(L) = 개수 × 용량(ml) ÷ 1,000
- OEE = 시간가동률 × 성능가동률 × 양품률, 생산 달성률 = 포장 생산량 ÷ 생산지시량
- MTBF = 순생산 시간 ÷ 고장 횟수, MTTR = 고장 정지시간 ÷ 고장 횟수
- CAPA: A·B·D·E 24,000 / C 6,000 / F 40,000 개/h, D호기는 2026-10-30부터 26,500 (`index.html`의 `CAPA`, `CAPA_CHG`)

## 보안
- 화면 코드(공개)에는 팀 자료가 들어 있지 않습니다. 모든 자료는 Supabase에 있고, **관리자가 승인한 사람만** 읽고 쓸 수 있습니다.
- 휴무 칸은 **본인 이름 줄만** 고칠 수 있고, 관리자는 전체를 고칠 수 있습니다 (Supabase 규칙으로 막혀 있음).
- `config.js`를 비워 두면 데모 모드로 열리며, 그 브라우저에만 저장됩니다.
