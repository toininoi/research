# opencode-native 판독 결과 (정본)

## Summary (EN)

Question: on an agent that reads AGENTS.md natively (OpenCode), does the
delivery path (CLAUDE.md fallback vs native AGENTS.md) change speed or task
outcomes? Two byte-identical payload conditions, two local models via
Ollama, four low-variance Kubernetes incident scenarios, five repetitions
with conditions alternating inside each repetition: 80 runs, all rc=0.

| Model | AO slower (of 20 pairs) | Mean pair diff | Solved CO/AO (of 20) |
|---|---|---|---|
| gemma4:12b | 7 | -4.0 s (sd 134.4) | 13 / 15 |
| qwen3.8:27b | 12 | +17.6 s (sd 256.3) | 15 / 18 |

No consistent difference in either speed or outcomes; run-to-run spread
dwarfs the condition effect. Load checks confirmed on both models that the
CLAUDE.md fallback loads when AGENTS.md is absent and that AGENTS.md wins
when both are present. A first campaign was invalidated and re-run: the
load canary must require the right codeword with zero tool calls, because a
model can find the file with grep and answer without it ever entering
context. Details below are in Korean; the parent README carries the English
summary section.


재측정 2026-08-24 16:21 ~ 08-25 01:22(두 모델 연속), 판독 2026-08-26.
원자료는 회차별 timing/meta/이벤트 로그로 보존하며 이 저장소에는 포함하지
않는다(태그 g1~g5 = gemma4:12b, q1~q5 = qwen3.8:27b).

1차 측정(태그 r1~r5)은 조건 결함으로 무효다. 경위는 아래 "무효 처리" 절.

## 연구 질문

AGENTS.md를 네이티브로 읽는 에이전트(OpenCode)에서, 컨텍스트 파일을
CLAUDE.md(폴백 경로)로 주는 것과 AGENTS.md(기본 경로)로 주는 것이 속도와
품질 차이를 만드는가. Claude Code에서 A/B/C 저하 없음을 확인한 본
연구(2026-07-02)의 에이전트 교체 확장이다.

## 측정 조건

| 항목 | 값 |
|---|---|
| 호스트 | M4 (MacBook Pro, M4 Pro 48GB), AC 전원 |
| 클러스터 | agents-md-migration (v1.36.2, 2노드, 런마다 스냅샷 리셋) |
| 에이전트 | opencode 1.18.19, `opencode run --format json`, permission allow |
| 모델 | gemma4:12b, qwen3.8:27b (ollama 0.32.15) |
| 컨텍스트 | 서버 env `OLLAMA_CONTEXT_LENGTH=16384` 고정 |
| 조건 | CO = CLAUDE.md 단독(폴백) / AO = AGENTS.md 단독(네이티브). 페이로드 바이트 동일 |
| 격리 | 빈 가짜 홈으로 `HOME` 교체 + `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`. KUBECONFIG는 실경로 명시 |
| 규모 | 모델 2종 x 저변동 4시나리오 x 2조건 x 5회 = 80런 + 파일럿 4런 |
| 배치 | 회차 안에서 CO/AO 교대 |

전 런 rc=0, 러너 실패 0건, 절전 오염 0건.

## 착수 게이트 (두 모델 모두 통과)

카나리 프로브가 코드워드를 답하되 **도구 호출 0건**이어야 통과다(도구를
쓰면 모델이 디스크에서 파일을 찾아 읽은 것이라 컨텍스트 주입의 증거가
아니다. 1차 측정이 이걸로 허위 통과했다).

| 프로브 | gemma4:12b | qwen3.8:27b |
|---|---|---|
| AGENTS.md 단독 | `FROM_AGENTS_MD`, 도구 0건 | `FROM_AGENTS_MD`, 도구 0건 |
| CLAUDE.md 단독 | `FROM_CLAUDE_MD`, 도구 0건 | `FROM_CLAUDE_MD`, 도구 0건 |
| 동시 배치 | `FROM_AGENTS_MD`, 도구 0건 | `FROM_AGENTS_MD`, 도구 0건 |

두 단독 조건이 각자 자기 파일을 컨텍스트로 받아 CO/AO 설계가 성립한다.
동시 배치에서 문서의 "AGENTS.md 우선, CLAUDE.md는 폴백" 규칙이 두 모델에서
실측으로 확인됐다.

## 결과 1. 속도: 두 모델 모두 조건 간 일관된 차이 없음

wall_time(초), 시나리오별 N=5 중앙값.

**gemma4:12b**

| 시나리오 | CO | AO | 차이 |
|---|---|---|---|
| 001-crashloop | 252.1 | 121.6 | -130.5 |
| 002-service | 122.5 | 110.6 | -11.9 |
| 003-oom | 129.5 | 157.1 | +27.6 |
| 004-readiness | 243.9 | 200.0 | -43.9 |
| 전체 | 157.9 | 126.6 | |

평균 CO 184.5초(sd 76.4), AO 180.4초(sd 112.6).

**qwen3.8:27b**

| 시나리오 | CO | AO | 차이 |
|---|---|---|---|
| 001-crashloop | 239.6 | 258.7 | +19.1 |
| 002-service | 136.8 | 131.7 | -5.1 |
| 003-oom | 444.4 | 436.4 | -8.0 |
| 004-readiness | 354.5 | 271.7 | -82.8 |
| 전체 | 277.1 | 268.9 | |

평균 CO 306.6초(sd 177.2), AO 324.2초(sd 189.7).

같은 회차, 같은 시나리오의 CO/AO 짝을 직접 빼면(짝 20개씩):

| 모델 | AO가 느린 짝 | 차이 중앙값 | 차이 평균 (sd) |
|---|---|---|---|
| gemma4:12b | 20개 중 7개 | -9.9초 | -4.0초 (134.4) |
| qwen3.8:27b | 20개 중 12개 | +1.8초 | +17.6초 (256.3) |

두 모델 모두 짝 차이가 부호로도 갈리고(7 대 13, 12 대 8) 평균 차이가
자기 표준편차 대비 3%(gemma4:12b)와 7%(qwen3.8:27b)에 그친다. 같은 조건 안의 회차 간 편차(gemma 91~480초,
qwen 114~873초)가 조건 간 차이보다 훨씬 크다. 결론: 전달 경로(폴백 대
네이티브)에 따른 속도 차이는 두 모델 어디서도 검출되지 않았다. Claude
Code에서의 결론(A/B/C 저하 없음)과 같은 방향이고 이번에는 계열이 다른
두 로컬 모델에서 재현됐다.

## 결과 2. 품질: 조건 간 차이 없음, 방향은 오히려 AO가 소폭 우세

휴리스틱 채점: 올바른 대상에 수정 행위(patch/apply 등)가 있고 수정 후
검증 출력에 건강 상태(1/1 Running, 엔드포인트 IP)가 보이면 "해결".

| 모델 | 조건 | 해결 | 미검증 | 미수정 |
|---|---|---|---|---|
| gemma4:12b | CO | 13 | 1 | 6 |
| gemma4:12b | AO | 15 | 1 | 4 |
| qwen3.8:27b | CO | 15 | 1 | 4 |
| qwen3.8:27b | AO | 18 | 0 | 2 |

- 각 셀 20런 기준이다. 두 모델 모두 AO가 2~3건 앞서지만 20런에서 2~3건
  차이는 회차 편차 안이라 조건 효과로 주장할 수 없다. 방향이 두 모델에서
  같다는 점만 관찰로 남긴다(더 큰 표본에서 확인할 후속 질문).
- 체급 효과는 뚜렷하다. qwen3.8:27b가 33/40, gemma4:12b가 28/40으로 해결
  건수가 높다. 특히 004-readiness에서 gemma는 3/10(CO 2, AO 1)인데 qwen은
  9/10이다. 1차 측정에서 "작은 모델의 약점"으로 봤던 지점이 체급을 올리니
  대부분 해소됐다.
- 반대로 003-oom은 qwen이 더 약하다(4/10 대 gemma 9/10). 리셋 직후 이미지
  풀 대기가 길어 검증 출력을 못 받은 사례가 섞여 있어 인프라 아티팩트가
  일부 포함된다(1차 측정에서 확인한 것과 같은 현상).

## 결과 3. 문서 밖 실측 확인 2건

- CLAUDE.md 폴백 경로가 실제로 동작한다(AGENTS.md 부재 시 컨텍스트로 로드).
- 두 파일이 모두 있으면 AGENTS.md가 이긴다(두 모델 일치).

## 무효 처리 (1차 측정 r1~r5)

1차 캠페인(2026-08-24 오전, gemma 40런)은 전량 무효다.

- 원인: 전역 오염 차단용으로 쓴 `OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1`이
  **프로젝트 CLAUDE.md 폴백 로드까지 차단**한다(opencode 1.18.19에서 관측).
  변수 분리 실험으로 확정했다(이 변수 단독으로 미로드, `..._SKILLS=1`
  단독은 정상 로드, HOME 격리도 정상 로드).
- 영향: CO 조건이 "폴백 경로"가 아니라 "컨텍스트 미주입"으로 돌았다.
  CO 대 AO 비교가 의도한 질문(전달 경로 차이)이 아니라 "페이로드 유무"
  비교였다.
- 게이트가 못 잡은 이유: gemma가 `grep` 도구로 디스크의 CLAUDE.md를 찾아
  읽고 코드워드를 답했다(canary-co.json에 도구 호출 1건, AO는 0건).
  발견 계기는 qwen 캠페인이 같은 게이트에서 멈춘 것이다. qwen은 파일을
  찾지 않고 "그런 것 없다"고 답했다.
- 수정: 격리를 HOME 가짜 홈으로 교체(`run_one_oc.sh`), 게이트에 도구 호출
  0건 요구 추가(`run_redo.sh`). 원자료 r1~r5는 무효 표기로 보존한다.

교훈으로 남길 것 하나. 카나리가 "정답을 말했다"만 보면 모델이 다른 경로로
정답에 도달한 경우를 통과시킨다. 무엇을 통해 알았는지(도구 사용 여부)까지
확인해야 게이트가 제 역할을 한다.

## 한계

- 품질 채점은 휴리스틱이다(AIOps의 결정론 safety 채점이나 score.yaml 채점이
  아님). "미검증" 분류는 성공과 실패를 단정하지 않는다.
- 회차 간 편차가 커서(같은 셀에서 최대 5배) 미세한 조건 차이에 대한
  검출력은 여전히 낮다. "차이 없음"은 이 표본에서 검출되지 않았다는 뜻이다.
- 003-oom의 검증 실패에 이미지 풀 대기라는 인프라 아티팩트가 섞여 있다.
  베이스라인 스냅샷에 이미지를 프리풀하면 제거된다.
- 로컬 모델 2종만 봤다. 상용 API 모델에서의 재현은 하지 않았다.

## 다음

- 베이스라인 스냅샷에 시나리오 이미지 프리풀 적용(003 아티팩트 제거).
- 원자료(runs/)와 측정 페이로드(variants/)는 이 저장소에 포함하지 않는다.
  페이로드는 내부 운영 문서 원문이고 구조와 분량은 상위 README의 조건 표에
  문서화돼 있다. 발행 수치는 이 문서와 상위 README의 표가 전부 담는다.
