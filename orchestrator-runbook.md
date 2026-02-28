# Orchestrator Runbook

Bu belge, multi-agent delivery modelinin tek sorumlu orchestrator tarafindan en az surtunme ile nasil yonetilecegini tanimlar.
Hedef: hizli ama guvenli ilerleme, dusuk cakisma, yuksek kalite kaniti.

Not: Bu runbook arac-agnostiktir. Ornekler Codex CLI ile verilir; baska bir agent runner kullaniyorsaniz komutlari esdegeriyle degistirin.

## 1) Ana Ilkeler

1. **Bridge-free orchestration:** Prompt dagitimi, takip, toplama, merge ve kapanis tek elde orchestrator'da olur.
2. **Dependency-first planning:** Paralellesme, yalnizca bagimsiz islerde kullanilir.
3. **Evidence before merge:** Test/lint/rapor kaniti olmayan hicbir is `done` olmaz.
4. **Single source of truth:** Backlog + live-board + memory-bank her merge sonrasinda senkron kalir.
5. **Reversible integration:** Her adim rollback dusunulerek atilir.

## 2) Roller ve Sorumluluk Sinirlari

- **Orchestrator:** Scope kirilimi, DAG (bagimlilik grafigi), merge queue, kalite kapisi, kapanis karari.
- **Domain Agent(lar)i:** Ozellik implementasyonu (uygulama, API, veri, AI/memory vb.).
- **Quality Agent(lar)i:** Regression, contract, consistency, CI kalite kapilari.
- **Ops Agent(lar)i:** Live board, queue, blocker, conflict watchlist takibi.

Not: release-note/changelog ve final memory/plan konsolidasyonu orchestrator sorumlulugundadir.

## 3) Codex CLI Operasyon Standardi

Bu runbook'ta agent oturumlari Codex CLI ile non-interactive yurutulur.
Ortama ozel (PATH, shell init, proxy, token) ayarlar bu belgeye degil, yerel kurulum notlarina yazilir.

### 3.1 CLI cagrisi (genel kural)

Varsayilan kullanim `codex` komutudur.

- Tavsiye: `CODEX_BIN="$(command -v codex)"` ile aktif binary bir kez tespit edilip otomasyonda bu degisken kullanilir.
- Kural: Dokumana hard-coded mutlak path yazilmaz; path ortama ozeldir.
- Fallback: Shell alias/function belirsizse `CODEX_BIN` ile cagri yapilir.

Pratik not:

- `codex` bir shell function/alias ise, orchestrator otomasyonunda dogrudan binary ile cagirmak daha deterministik olur.

### 3.2 Session lifecycle

Her ticket icin ayri session acilir ve ayni session devam ettirilir.

- **Baslat:** `codex exec "<kickoff prompt>" -C <worktree> --json`
- **Devam:** `codex exec resume <thread_id> "<follow-up prompt>" --json`
- **Kural:** Bir ticket kapanmadan yeni session acilmaz (exception: session corruption).

### 3.3 JSON event kaydi

Tavsiye edilen pratik:

- Tum `codex exec` ciktilari `.worktrees/<branch>/.logs/*.jsonl` altina yazilir.
- `thread.started` event'indeki `thread_id` live board'a not edilir.

### 3.4 Opsiyonel Smoke Test (exec + resume)

Amac: Codex CLI'nin (1) yeni session baslatma ve (2) ayni session'a resume ile devam etme kabiliyetini hizlica dogrulamak.

```bash
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-$(command -v codex)}"
OUT_DIR="${OUT_DIR:-/tmp/codex-orch-smoke}"
mkdir -p "$OUT_DIR"

# 1) Yeni session baslat (thread_id al)
"$CODEX_BIN" exec "Remember this exact token: SMOKE42. Reply only READY." \
  --json > "$OUT_DIR/ev1.jsonl"

THREAD_ID=$(jq -r 'select(.type=="thread.started")|.thread_id' "$OUT_DIR/ev1.jsonl" | head -n 1)

# 2) Ayni session'a resume ile devam et
"$CODEX_BIN" exec resume "$THREAD_ID" "What is the token? Reply only it." \
  --json > "$OUT_DIR/ev2.jsonl"

TOKEN=$(jq -r 'select(.type=="item.completed" and .item.type=="agent_message")|.item.text' "$OUT_DIR/ev2.jsonl" | tail -n 1)
test "$TOKEN" = "SMOKE42"

echo "OK: exec+resume works (thread_id=$THREAD_ID)"
```

### 3.5 Opsiyonel "Always-On" Bekleme (tmux)

Orchestrator'un "cevap verdikten sonra da" arka planda repo durumunu izlemesi isteniyorsa, en pratik yontem bir tmux loop'tur.

- Monitor-only (guvenli): sadece `fetch/status` ve branch SHA degisimlerini raporlar.
- Ornek: `orchd start <repo_dir> 30` (bkz. `~/.local/bin/orchd --help`)

En minimal alternatif (script yok, sadece tmux + `sleep`):

```bash
tmux new -d -s orch-monitor '
while true; do
  echo "== $(date -Is) =="
  git -C "<repo_dir>" fetch --all --prune >/dev/null 2>&1 || true
  git -C "<repo_dir>" status -sb || true
  sleep 60
done'
```

Not:

- Buradaki fikir `sleep` ile "bekle", sonra tekrar "kontrol et" dongusudur.
- Daha aktif bir orchestrator isteniyorsa, her dongude `codex exec resume <thread_id> ...` ile ilgili agent session'larina follow-up atilip, ardindan tekrar `sleep`e donulebilir.

## 4) Prompt Contract (Onerilen Minimum)

Her kickoff prompt su basligi icerir:

```text
AGENT: <agent-id-or-role>
TASK: <TASK-ID>
BRANCH: <branch>
WORKTREE: <path>
STATUS: <GO|PREP_ONLY|REVIEW|...>
```

Pratikte su 4 blokun bulunmasi tavsiye edilir:

1. **Goal** (ne bitecek?)
2. **Scope** (in/out)
3. **Acceptance** (komut + beklenen sonuc)
4. **Deliverables** (dosya path + task report)

## 5) Baslatma Sirasi (Referans Flow)

1. **Preflight:** scope + dependency + risk kontrolu
2. **Worktree/branch acilisi:** policy'ye uygun
3. **Kickoff dagitimi:** bagimsizlar paralel, bagimli olanlar gated
4. **Checkpoint review:** ara kanit topla
5. **Final review:** lint/test/contract/build dogrula
6. **Merge queue:** dependency sirasiyla entegre et
7. **Post-merge regression:** main uzerinde toplu test
8. **Sync:** backlog + board + memory + changelog guncelle

## 5.1 Ops Artifact'leri (Isimden Bagimsiz)

Runbook "backlog/board/memory/changelog" derken asagidaki 4 artefakti kasteder (isimler projeye gore degisir):

- **Backlog/plan:** ticket listesi, oncelik, bagimlilik
- **Live board:** canli durum, kanit, blocker, next action
- **Memory/decisions:** kararlar, pattern'ler, aktif riskler (kisa ve dogrulanabilir)
- **Release notes:** degisiklik gunlugu / kapanis notu

## 6) Paralellesme Karar Matrisi

### Paralel baslat (genelde evet)

- Dosya sahipligi ayrik
- Kontrat/arayuz sabit
- Birinin cikisi digerini degistirmiyor

### Gated baslat (genelde daha guvenli)

- Migration id/revision ayni alana dokunuyor
- Tuketici katman, saglayici cevabina siki bagli
- Politika/kontrat henuz net degil

## 7) Checkpoint Tasarimi (Uzun Gorevler)

Uzun gorevlerde iki checkpoint modeli faydalidir:

- **CP1 (structural):** temel mimari + ilk test
- **CP2 (final):** tam entegrasyon + dokuman + kanit

Varsayilan gecis kural:

- CP1 red ise CP2'ye gecis yok
- CP2'de kalite kapisi eksikse merge yok

## 8) Merge Queue Kurali

1. DAG'e gore topolojik siralama yap.
2. Ayni dosya grubuna dokunan branchleri ard arda merge et.
3. Her merge sonrasi en az hedef alan smoke test kos.
4. Tum queue sonunda tam regresyon kos.

## 9) Kalite Kapisi Minimumlari

Her ticket icin, baglama uygun en az su kanit seti tavsiye edilir:

- Lint veya esdeger statik kontrol PASS
- Ticket-ozel test/smoke PASS
- Task report tamam
- Risk/rollback notu var

Wave kapanisi icin, mumkun oldugunca su set tamamlanir:

- Sistem genelinde full suite PASS (stack'e gore)
- Contract suite PASS (varsa)
- UI/app analiz + test PASS (varsa)
- Live-board `done` + blocker `none`

## 10) Conflict ve Recovery Playbook

### 10.1 Cakisma tipleri

- **Schema/migration cakismasi** (en kritik)
- **Kontrat drift** (endpoint/event/payload)
- **UI state/API payload drift**
- **Shared doc churn** (release notes/live board)

### 10.2 Cozum stratejisi

1. Cakismayi teknik ve surec olarak ayir.
2. Kaynak branch'i degistirmeden once mevcut main'i referans al.
3. Migration'da tek-head zorunlulugunu koru.
4. Cozumden sonra ilgili test subsetini hemen kos.

## 11) Evidence Standardi

Ajan raporlarinda komut + sonuc satiri bulunmasi tavsiye edilir:

```text
EVIDENCE:
- CMD: <command>
  RESULT: PASS|FAIL
  OUTPUT: <kisa ozet>
```

Ops board satirlarinda en az:

- latest commit sha
- lint evidence
- test evidence
- blocker
- next action

## 11.1 Secret ve Yetki Hijyeni

- Prompt'lara API key, token, cookie, refresh token koymayin.
- Gerekli credential/secret degerlerini environment veya secret manager uzerinden verin.
- Agent'in urettigi log/raporlarda secret izine karsi hizli tarama yapin.

## 12) Handoff Protokolu (Sonraki Orchestrator icin)

Her wave sonunda orchestrator sunlari birakir:

1. Kapanis raporu (`<WAVE>-closeout-orchestrator.md` veya esdeger)
2. Guncel queue (done/in_progress/todo)
3. Aktif riskler ve acik teknik borclar
4. Baslatmaya hazir sonraki 3 ticket

Handoff ciktisi "tek bakista" okunabilir olmalidir.

## 13) Anti-Pattern Listesi

Asagidakilerden guclu sekilde kacinin:

- Kanitsiz `done` isaretlemek
- Bagimli ticketlari ayni anda full execute etmek
- Agent raporu gelmeden merge'e zorlamak
- Main uzerinde regressionsiz dalga kapatmak
- Cakismayi gecici hack ile gecistirmek

## 14) Pratik Komut Referansi

```bash
# Ticket baslat
"${CODEX_BIN:-codex}" exec "<kickoff prompt>" -C .worktrees/<branch> --json

# Ayni ticketi devam ettir
"${CODEX_BIN:-codex}" exec resume <thread_id> "<follow-up>" --json

# Genel kalite kapisi (proje stack'ine gore uyarlanir)
<lint-command>
<test-command>
<contract-command-optional>
<ui-analyze-and-test-optional>
```

## 15) Basari Kriteri

Orchestrator basarili sayilirsa:

- Lead time duser
- Rework orani azalir
- Merge conflict sayisi azalir
- Wave kapanislarinda regressionsiz teslim orani artar

## 16) Yargi Payi

Bu runbook bir kontrol listesi degil, karar destegi belgesidir.

- Orchestrator, proje gercegine gore adim atlarinin agirligini degistirebilir.
- Kritik durumda hiz icin degil, risk azaltimi icin karar verir.
- Standarttan sapma varsa sebebi kisa notla kayda gecer.

## 17) Web Kaynaklari (Okuma Listesi)

- Codex CLI repo/dokumantasyon: kurulum + CLI tabanli yerel agent akisi icin iyi referans. (https://github.com/openai/codex)
- LangGraph: orkestrasyonu graph/DAG olarak dusunme, durable execution ve human-in-the-loop gibi kavramlar icin referans. (https://github.com/langchain-ai/langgraph)
- AutoGen: event-driven multi-agent sistem yaklasimi, multi-agent uygulama ve runtime kavramlari icin referans. (https://microsoft.github.io/autogen/stable/)
- CrewAI: crew/flow/process kavramlari ve guardrails/observability odakli multi-agent pratikleri icin referans. (https://docs.crewai.com/)
