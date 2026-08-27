#!/usr/bin/env bash
# OpenCode 확장(agents-md-opencode 후보)의 한 회차 실행.
# run_one.sh(Claude Code용)의 절차를 그대로 승계하고 에이전트 호출만 바꿨다.
#
# 조건: CO = CLAUDE.md 단독(폴백 경로) / AO = AGENTS.md 단독(기본 경로).
#   OpenCode 문서상 CLAUDE.md는 AGENTS.md 부재 시에만 읽히므로 파일을 하나씩만 둔다.
#   페이로드는 기존 A 변형과 바이트 동일(md5 확인됨).
#   주의: variants/(측정 페이로드)는 내부 운영 문서 원문이라 공개 저장소에
#   포함되지 않는다. 구조와 분량은 상위 README의 조건 표에 문서화돼 있다.
#
# Usage: ./run_one_oc.sh <CO|AO> <scenario-slug> <rep-tag>
# Env: OC_MODEL(기본 ollama/gemma4:12b), TIMEOUT(기본 3600), SKIP_RESET=1(개발용)
set -uo pipefail

COND="${1:?Usage: $0 <CO|AO> <scenario> <tag>}"
SCENARIO="${2:?}"
TAG="${3:?}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY="$(cd "$HERE/../agents-md-import-speed" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLUSTER_DIR="$ROOT/test-cluster"
CTX="agents-md-migration"
MODEL="${OC_MODEL:-ollama/gemma4:12b}"
TIMEOUT="${TIMEOUT:-3600}"

case "$COND" in
  CO) VARIANTS="$HERE/variants/claude-only" ;;
  AO) VARIANTS="$HERE/variants/agents-only" ;;
  *) echo "Error: cond must be CO|AO" >&2; exit 1 ;;
esac

ITER="oc-${COND}-${SCENARIO}-${TAG}"
OUT_DIR="$HERE/runs/$ITER"
WORK="/tmp/oc-$ITER"
mkdir -p "$OUT_DIR"
echo "[$ITER] === start $(date +%T) (model=$MODEL timeout=${TIMEOUT}s) ==="

# 1) 클러스터 리셋 (baseline 스냅샷 복원, 기존 절차 그대로)
if [[ "${SKIP_RESET:-0}" != "1" ]]; then
  echo "[$ITER] reset: restoring baseline snapshot..."
  bash "$CLUSTER_DIR/reset.sh" >/dev/null 2>&1
  _t=0
  until [ -z "$(kubectl --context $CTX get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed')" ] \
        && kubectl --context $CTX get nodes --no-headers 2>/dev/null | grep -q Ready; do
    sleep 10; _t=$((_t+10))
    if [ "$_t" -ge 600 ]; then echo "[$ITER] ERROR: cluster not healthy after 600s" >&2; exit 1; fi
  done
  echo "[$ITER] cluster healthy (t+${_t}s)"
fi

# 2) 시나리오 적응 + 고장 주입 (기존 스크립트 재사용)
bash "$LEGACY/adapt_scenario.sh" "$SCENARIO" "$OUT_DIR/scenario"
bash "$OUT_DIR/scenario/setup.sh" > "$OUT_DIR/setup.log" 2>&1
echo "[$ITER] setup done."

# 3) 작업 디렉토리 시딩 (콜드 스타트)
rm -rf "$WORK"; mkdir -p "$WORK"
cp -a "$VARIANTS/." "$WORK/"

# 4) 에이전트 실행 (OpenCode 비대화형).
#    전역 오염 차단은 HOME 격리로 한다(빈 가짜 홈). DISABLE_CLAUDE_CODE_PROMPT는
#    프로젝트 CLAUDE.md 폴백까지 죽이는 것이 실측으로 확인돼(2026-08-24) 쓰지
#    않는다. SKILLS 차단은 폴백에 무해함을 확인했다.
PROMPT="$(cat "$OUT_DIR/scenario/PROMPT.md")"
FAKEHOME="/tmp/oc-home-$ITER"
rm -rf "$FAKEHOME"; mkdir -p "$FAKEHOME"
echo "[$ITER] agent: running opencode..."
AGENT_START_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_NS=$(gdate +%s%N 2>/dev/null || date +%s%N)
(cd "$WORK" && env \
  HOME="$FAKEHOME" \
  KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" \
  OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 \
  gtimeout "$TIMEOUT" \
  opencode run "$PROMPT" -m "$MODEL" --format json) \
  > "$OUT_DIR/raw.json" \
  2> "$OUT_DIR/transcript.log"
AGENT_RC=$?
END_NS=$(gdate +%s%N 2>/dev/null || date +%s%N)
AGENT_END_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WALL_MS=$(( (END_NS - START_NS) / 1000000 ))

# 5) 기록 (collect.py 호환 timing + 조건 메타)
echo "{\"wall_time_ms\": $WALL_MS, \"start_iso\": \"$AGENT_START_ISO\", \"end_iso\": \"$AGENT_END_ISO\"}" > "$OUT_DIR/timing.json"
_OC_V=$(opencode --version 2>/dev/null | head -1)
_OL_V=$(ollama --version 2>/dev/null | head -1 | awk '{print $NF}')
echo "{\"cond\": \"$COND\", \"scenario\": \"$SCENARIO\", \"tag\": \"$TAG\", \"model\": \"$MODEL\", \"agent_rc\": $AGENT_RC, \"opencode_version\": \"$_OC_V\", \"ollama_version\": \"$_OL_V\", \"context\": \"$CTX\"}" > "$OUT_DIR/meta.json"

# 6) audit 슬라이스 (기존 shim 재사용, 비치명적)
bash "$ROOT/scripts/capture_audit.sh" "$OUT_DIR" "$AGENT_START_ISO" "$AGENT_END_ISO" >/dev/null 2>&1 || true

echo "[$ITER] === done rc=$AGENT_RC wall=$((WALL_MS/1000))s ==="
