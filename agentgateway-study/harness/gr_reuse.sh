#!/usr/bin/env bash
# guardrail 오버헤드 x reuse 모드 (비용 매트릭스 빈 칸, 2026-08-25 무인).
# 주말 1부와 같은 자원 통제(게이트웨이+guardrail 상주, 정책 유무만 차이),
# 연결 방식만 close 대신 reuse. 사용: ./gr_reuse.sh <OUT_BASE>
set -uo pipefail

BASE="$1"; CTX="mcp-migration"; NS="mcp-pilot"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUDY="$(cd "$DIR/.." && pwd)"
REPO="$(cd "$STUDY/.." && pwd)"
MCPSTUDY="$(cd "$REPO/mcp-migration/studies/stateless-scaleout" && pwd)"
GWDIR="$MCPSTUDY/k8s/agentgateway"
GRDIR="$STUDY/k8s/guardrail"
LOADGEN="$MCPSTUDY/harness/loadgen.py"
PY=/tmp/mcpvenv/bin/python
COOLDOWN=180
mkdir -p "$STUDY/$BASE"; OUT="$STUDY/$BASE"
log() { echo "[$(date '+%m-%d %H:%M')] $*"; }
note() { echo "$*" >> "$OUT/FINDINGS.md"; }
# push_progress: 내부 진행 기록용(무인 실행 중 원격 백업). 클론해서 재현할
# 때는 이 함수 본문을 비우고 실행할 것. 그대로 두면 자기 저장소 main에
# 커밋과 푸시를 시도한다.
push_progress() {
  ( cd "$REPO" && git add agentgateway-study/runs >/dev/null 2>&1 \
    && git commit -q -m "guardrail reuse 측정: $1" >/dev/null 2>&1 \
    && git pull --rebase --autostash -q origin main >/dev/null 2>&1 \
    && git push -q origin main >/dev/null 2>&1 ) || true
}

# 전제 검사: /tmp/mcpvenv는 재부팅으로 사라진다. 없으면 20셀이 조용히 빈
# 값으로 돌아간다(2026-08-24 사고). 여기서 먼저 죽인다.
"$PY" -c "import httpx" 2>/dev/null || {
  echo "[중단] $PY 에 httpx 없음(loadgen 의존성). venv 재구성 필요:"
  echo "  /opt/homebrew/bin/python3.13 -m venv /tmp/mcpvenv && /tmp/mcpvenv/bin/pip install httpx"
  exit 1
}

echo "# guardrail 오버헤드 x reuse (자동 생성)" > "$OUT/FINDINGS.md"
note ""
note "시작 $(date '+%Y-%m-%d %H:%M'). 주말 1부와 동일 통제, 연결만 reuse."
note ""

log "게이트웨이 설치"
AGW_VER=v1.4.1 bash "$GWDIR/install.sh" >> "$OUT/install.log" 2>&1
sleep 30
kubectl --context $CTX apply -f "$GWDIR/gateway.yaml" >> "$OUT/install.log" 2>&1
sleep 15
GW=$(kubectl --context $CTX -n agentgateway-system get gateway agentgateway-proxy -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
[ -z "$GW" ] && { note "**중단**: 게이트웨이 주소 없음"; push_progress "중단"; exit 1; }
GW="http://$GW"
kubectl --context $CTX -n $NS scale deploy/mcp-a --replicas=1 >/dev/null 2>&1
kubectl --context $CTX -n $NS scale deploy/mcp-b --replicas=1 >/dev/null 2>&1

log "guardrail 배포"
kubectl --context $CTX -n $NS delete configmap guardrail-code >/dev/null 2>&1
kubectl --context $CTX -n $NS create configmap guardrail-code \
  --from-file="$GRDIR/server.py" --from-file="$GRDIR/ext_mcp_pb2.py" \
  --from-file="$GRDIR/ext_mcp_pb2_grpc.py" >> "$OUT/install.log" 2>&1
kubectl --context $CTX apply -f "$GRDIR/guardrail.yaml" >> "$OUT/install.log" 2>&1
kubectl --context $CTX -n $NS rollout status deploy/guardrail --timeout=300s >> "$OUT/install.log" 2>&1
# 엔드포인트 준비 확인 (resp-0824 교훈)
for i in $(seq 1 30); do
  EP=$(kubectl --context $CTX -n $NS get endpoints guardrail -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
  [ -n "$EP" ] && break; sleep 2
done
note "- guardrail 엔드포인트: ${EP:-없음}"

note ""
note "## guardrail x reuse (echo, 쿨다운 ${COOLDOWN}초)"
note ""
for arm in off on; do
  if [ "$arm" = on ]; then
    cat <<YAML | kubectl --context $CTX apply -f - >> "$OUT/install.log" 2>&1
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: grr-guardrail
  namespace: mcp-pilot
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-b-stateless
  backend:
    mcp:
      guardrails:
        processors:
          - methods:
              tools/call: Request
            remote:
              backendRef:
                kind: Service
                name: guardrail
                namespace: mcp-pilot
                port: 50051
              failureMode: FailClosed
YAML
    sleep 12
  fi
  for rps in 100 200; do
    conc=8; [ "$rps" = 200 ] && conc=16
    note "- guardrail=$arm ${rps}rps:"
    for n in 1 2 3 4 5; do
      "$PY" "$LOADGEN" --url "$GW/b" --dialect b --tool echo \
        --concurrency "$conc" --duration 30 --conn-mode reuse --rps "$rps" \
        --out "$OUT/grr-${arm}-rps${rps}-n${n}.json" >> "$OUT/loadgen.log" 2>&1
      # 셀 단위 가드: JSON이 안 생겼으면 빈 런으로 끝까지 돌지 말고 즉시 중단
      # (grr-0825 사고: loadgen이 조용히 죽고 20셀이 빈 값으로 완주)
      if [ ! -s "$OUT/grr-${arm}-rps${rps}-n${n}.json" ]; then
        note "  - n$n: **실패, JSON 미생성 (loadgen.log 참조). 측정 중단**"
        push_progress "중단(셀 산출물 미생성)"
        exit 1
      fi
      R=$("$PY" -c "
import json
d=json.load(open('$OUT/grr-${arm}-rps${rps}-n${n}.json'))
err=d.get('gateway_error',0)+d.get('other_fail',0)+d.get('session_loss',0)
print(f\"achieved={d['achieved_rps']:.1f} p50={d['latency_ms']['p50']:.1f} p99={d['latency_ms']['p99']:.1f} err={err}\")")
      note "  - n$n: $R"
      sleep $COOLDOWN
    done
  done
done

log "정리: guardrail과 게이트웨이 제거"
kubectl --context $CTX -n $NS delete agentgatewaypolicy grr-guardrail >/dev/null 2>&1
kubectl --context $CTX delete -f "$GRDIR/guardrail.yaml" >/dev/null 2>&1
kubectl --context $CTX -n $NS delete configmap guardrail-code >/dev/null 2>&1
bash "$GWDIR/uninstall.sh" >> "$OUT/install.log" 2>&1
note ""
note "---"
note "종료 $(date '+%Y-%m-%d %H:%M'). 격리 복원됨."
push_progress "guardrail x reuse 20셀 완료"
log "=== gr_reuse 완료 ==="
