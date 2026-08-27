#!/usr/bin/env bash
# 재측정 체인 (2026-08-24 오후. CO 조건 결함 수정 후 두 모델 전체 재실행).
#
# 배경: 구 env(OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1)가 프로젝트 CLAUDE.md
# 폴백을 죽여 gemma 캠페인(r1~r5)의 CO 조건이 "컨텍스트 미주입"으로 돌았고,
# 아침 게이트는 모델이 grep으로 파일을 읽어 허위 통과했다. 격리는 HOME
# 가짜 홈으로 바꿨고(run_one_oc.sh), 게이트는 도구 호출 0건을 함께 요구한다.
#
#   모델 1. gemma4:12b  태그 gp0, g1~g5 (r1~r5 대체)
#   모델 2. qwen3.8:27b 태그 qp0, q1~q5
#   각 모델: 게이트(CO/AO/동시, 도구 0건 강제) -> 파일럿 -> 40런
#
# 사용: caffeinate -i nohup ./run_redo.sh <OUT_TAG> &   (예: redo-0824)
set -uo pipefail

TAG="${1:?OUT_TAG 필요}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
CLUSTER_DIR="$ROOT/test-cluster"
CTX="agents-md-migration"
SCENARIOS=(001-crashloop 002-service 003-oom 004-readiness)
OUT="$HERE/runs/_$TAG"
mkdir -p "$OUT"
log() { echo "[$(date '+%m-%d %H:%M')] $*"; }
note() { echo "$*" >> "$OUT/FINDINGS.md"; }
# push_progress: 내부 진행 기록용(무인 실행 중 원격 백업). 클론해서 재현할
# 때는 이 함수 본문을 비우고 실행할 것. 그대로 두면 자기 저장소 main에
# 커밋과 푸시를 시도한다.
push_progress() {
  ( cd "$REPO" && git add agents-md-migration/studies/opencode-native >/dev/null 2>&1 \
    && git commit -q -m "opencode 재측정: $1" >/dev/null 2>&1 \
    && git pull --rebase --autostash -q origin main >/dev/null 2>&1 \
    && git push -q origin main >/dev/null 2>&1 ) || true
}
abort() {
  log "[중단] $1"; note ""; note "**중단**: $1 ($(date '+%m-%d %H:%M'))"
  pkill -f "ollama serve" >/dev/null 2>&1 || true
  push_progress "중단($1)"
  exit 1
}

echo "# 재측정 체인 (자동 생성)" > "$OUT/FINDINGS.md"
note ""
note "시작 $(date '+%Y-%m-%d %H:%M'). CO 조건 결함(구 env가 CLAUDE.md 폴백 차단)"
note "수정 후 두 모델 전체 재실행. 격리 = HOME 가짜 홈 + SKILLS 차단."
note "- 전원 상태: $(pmset -g batt | head -1 | sed 's/Now drawing from //')"
note ""

pkill -f "ollama serve" >/dev/null 2>&1 || true; sleep 3
env OLLAMA_CONTEXT_LENGTH=16384 OLLAMA_KEEP_ALIVE=60m nohup ollama serve > "$OUT/ollama.log" 2>&1 &
sleep 8
ollama list >/dev/null 2>&1 || abort "ollama 기동 실패"
note "- ollama $(ollama --version 2>/dev/null | tail -1 | awk '{print $NF}') / opencode $(opencode --version 2>/dev/null | head -1)"

log "agents-md 클러스터 기동"
( cd "$CLUSTER_DIR" && vagrant up ) > "$OUT/vagrant-up.log" 2>&1
_t=0
until kubectl --context $CTX get nodes --no-headers 2>/dev/null | grep -q ' Ready'; do
  sleep 15; _t=$((_t+15))
  [ "$_t" -ge 1200 ] && abort "클러스터 기동 실패"
done
log "클러스터 Ready (t+${_t}s)"

# oc_probe <label> <model> <prompt>: 새 격리 env로 카나리 실행
oc_probe() {
  local label="$1" model="$2" prompt="$3" d="/tmp/oc-canary-$1"
  local fh="/tmp/oc-home-canary-$label"; rm -rf "$fh"; mkdir -p "$fh"
  cp "$HERE/variants/opencode.json" "$d/"
  ( cd "$d" && env HOME="$fh" OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 \
    gtimeout 900 opencode run "$prompt" -m "$model" --format json ) \
    > "$OUT/canary-$label.json" 2> "$OUT/canary-$label.log"
}
# cw_check <label>: "코드워드|도구수" 출력 (도구 0건이어야 진짜 컨텍스트 로드)
cw_check() {
  python3 - "$OUT/canary-$1.json" <<'PYEOF'
import json, sys, re
cw, tools = "", 0
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except Exception: continue
    p = e.get('part', {})
    if p.get('type') == 'tool': tools += 1
    if p.get('type') == 'text':
        m = re.search(r'FROM_(CLAUDE|AGENTS)_MD', p.get('text', ''))
        if m and not cw: cw = m.group(0)
print(f"{cw or '없음'}|{tools}")
PYEOF
}

campaign() { # campaign <model> <ptag> <rprefix> <이름>
  local model="$1" ptag="$2" rp="$3" name="$4"
  note ""
  note "## $name 게이트 (도구 0건 요구)"
  note ""
  local CW='What is the codeword? Answer with only the codeword and nothing else.'
  local d
  d=/tmp/oc-canary-${rp}ao; rm -rf "$d"; mkdir -p "$d"
  printf '# Project rules\nWhen asked for the codeword, answer exactly: FROM_AGENTS_MD\n' > "$d/AGENTS.md"
  oc_probe "${rp}ao" "$model" "$CW"
  d=/tmp/oc-canary-${rp}co; rm -rf "$d"; mkdir -p "$d"
  printf '# Project rules\nWhen asked for the codeword, answer exactly: FROM_CLAUDE_MD\n' > "$d/CLAUDE.md"
  oc_probe "${rp}co" "$model" "$CW"
  d=/tmp/oc-canary-${rp}both; rm -rf "$d"; mkdir -p "$d"
  printf '# Project rules\nWhen asked for the codeword, answer exactly: FROM_AGENTS_MD\n' > "$d/AGENTS.md"
  printf '# Project rules\nWhen asked for the codeword, answer exactly: FROM_CLAUDE_MD\n' > "$d/CLAUDE.md"
  oc_probe "${rp}both" "$model" "$CW"
  local AO CO BOTH
  AO=$(cw_check "${rp}ao"); CO=$(cw_check "${rp}co"); BOTH=$(cw_check "${rp}both")
  note "- AGENTS 단독: \`$AO\` / CLAUDE 단독: \`$CO\` / 동시: \`$BOTH\` (코드워드|도구수)"
  [ "$AO" = "FROM_AGENTS_MD|0" ] || abort "$name G-iii AO 실패($AO)"
  [ "$CO" = "FROM_CLAUDE_MD|0" ] || abort "$name G-iii CO 실패($CO)"
  note "- 동시 배치 결과는 기록용(도구 0건에 AGENTS면 우선순위 실증)"
  push_progress "$name 게이트 통과"

  note ""
  note "## $name 파일럿 ($ptag)"
  note ""
  local cond m
  for cond in CO AO; do
    log "$name 파일럿 $cond"
    OC_MODEL="$model" bash "$HERE/run_one_oc.sh" "$cond" 001-crashloop "$ptag" >> "$OUT/main.log" 2>&1 || true
    m="$HERE/runs/oc-$cond-001-crashloop-$ptag/meta.json"
    [ -f "$m" ] && note "- $cond: $(cat "$m")" || note "- $cond: 실행 실패"
  done
  [ -f "$HERE/runs/oc-CO-001-crashloop-$ptag/meta.json" ] || [ -f "$HERE/runs/oc-AO-001-crashloop-$ptag/meta.json" ] \
    || abort "$name 파일럿 양 조건 실패"
  push_progress "$name 파일럿 완료"

  note ""
  note "## $name 본측정 (${rp}1~${rp}5)"
  note ""
  local FAILS=0 rep scen rc wall
  for rep in 1 2 3 4 5; do
    for scen in "${SCENARIOS[@]}"; do
      for cond in CO AO; do
        log "$name 본측정 ${rp}$rep $scen $cond"
        if OC_MODEL="$model" bash "$HERE/run_one_oc.sh" "$cond" "$scen" "${rp}$rep" >> "$OUT/main.log" 2>&1; then
          FAILS=0
          rc=$(grep -o '"agent_rc": [0-9-]*' "$HERE/runs/oc-$cond-$scen-${rp}$rep/meta.json" 2>/dev/null | awk '{print $2}')
          wall=$(grep -o '"wall_time_ms": [0-9]*' "$HERE/runs/oc-$cond-$scen-${rp}$rep/timing.json" 2>/dev/null | awk '{print int($2/1000)}')
          note "- ${rp}$rep $scen $cond: rc=${rc:-?} wall=${wall:-?}s"
        else
          FAILS=$((FAILS+1))
          note "- ${rp}$rep $scen $cond: **러너 실패**"
          [ "$FAILS" -ge 3 ] && abort "$name 러너 3연속 실패"
        fi
      done
    done
    push_progress "$name 본측정 ${rp}$rep 완료"
  done
}

campaign "ollama/gemma4:12b" gp0 g "gemma4:12b(재측정)"
campaign "ollama/qwen3.8:27b" qp0 q "qwen3.8:27b"

log "정리: 클러스터 halt, ollama 종료"
( cd "$CLUSTER_DIR" && vagrant halt ) > "$OUT/vagrant-halt.log" 2>&1
pkill -f "ollama serve" >/dev/null 2>&1 || true
note ""
note "---"
note "재측정 체인 종료 $(date '+%Y-%m-%d %H:%M'). 정본 재판독은 g*/q* 원자료로."
push_progress "재측정 체인 전체 종료"
log "=== 재측정 체인 완료 ==="
