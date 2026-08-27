#!/usr/bin/env python3
"""발행용 차트 2종 생성 (mcp-migration chart.py 선례).

1. cost:   경로 비용. 통제 쌍 4개(A/B close, A/B reuse, guardrail close,
           guardrail reuse)의 p50 막대와 p99 라벨. 원값 JSON에서 직접 계산.
2. reject: 거부 형태 3분류 도식 (인가 위장 / guardrail 사유 / FailClosed).

사용: python3 harness/chart.py <study_dir> <cost|reject> [en|ko] > out.svg

주의: 공개 저장소에는 측정 원자료(runs/)가 포함되지 않는다. cost 차트는
원자료가 있을 때만 재생성되고, 발행 수치는 README 표에 문서화돼 있다.
"""

import glob
import json
import os
import statistics
import sys


def med(study, rel_prefix):
    """셀 프리픽스(n1~n5)의 p50, p99 중앙값."""
    p50s, p99s = [], []
    for f in sorted(glob.glob(os.path.join(study, rel_prefix + "-n*.json"))):
        d = json.load(open(f))
        p50s.append(d["latency_ms"]["p50"])
        p99s.append(d["latency_ms"]["p99"])
    return statistics.median(p50s), statistics.median(p99s)


TEXT = {
    "ko": {
        "c_title": "무엇을 더하면 지연이 얼마나 느는가 (p50 중앙값의 차이, 각 5회)",
        "c_sub": "각 행 = 같은 날 잰 통제 쌍. 점 = 실측 p50 절대값, 오른쪽 = 중앙값 차이(본문 표의 증분은 짝 평균). 절대값 비교는 행 안에서만(측정일 상이). p99는 본문 표.",
        "q1": "질문 1. 게이트웨이를 거치면?", "q1sub": "직접 호출 대 게이트웨이 경유",
        "q2": "질문 2. guardrail 인자 검사를 켜면?", "q2sub": "호출마다 인자 검사 서버로 가는 gRPC 왕복이 추가된다",
        "close": "연결 매번 새로", "reuse": "연결 재사용", "arrow": "->",
        "b1": "직접", "a1": "게이트웨이 경유", "b2": "검사 없음", "a2": "검사 켬(+gRPC 왕복)",
        "take1": "홉 비용 +0.5~1.6ms. 연결을 재사용할수록 상대적으로 크게 보인다",
        "take2": "인자 검사 비용은 호출당 약 0.5ms로 측정 조건 전반에서 대체로 일정",
        "r_title": "요청이 거부될 때 클라이언트가 보는 세 가지 형태",
        "r_sub": "거부한 층에 따라 응답 모양이 갈린다. 모양이 곧 진단 단서다.",
        "p_client": "클라이언트", "p_gw": "게이트웨이", "p_authz": "인가 정책 (mcpAuthorization)",
        "p_gr": "guardrail 검사 서버", "p_srv": "MCP 서버", "p_grpc": "gRPC 왕복",
        "p_cap": "세 형태 모두 요청이 MCP 서버에 닿기 전에 멈춘다.",
        "r1h": "mcpAuthorization 거부", "r1b": "HTTP 400\n-32602 \"Unknown tool\"",
        "r1n": "도구 부재와 구분되지 않는 응답.\ntools/list에서도 숨겨진다",
        "r2h": "mcpGuardrails 거부", "r2b": "HTTP 200\n-32001 + 서버가 정한 사유",
        "r2n": "사유가 그대로 나간다\n(\"a == 1일 때만 허용\")",
        "r3h": "FailClosed (서버 다운)", "r3b": "HTTP 200\n-32603 내부 오류 문구",
        "r3n": "guardrail 죽으면 전부 차단.\n내부 상태가 노출된다",
    },
    "en": {
        "c_title": "What each addition costs in latency (difference of median p50, n=5 each)",
        "c_sub": "Each row = a same-day controlled pair. Dots = measured p50, right = difference of medians (tables report mean pair increments). Compare absolutes within a row only (days differ). p99 in the tables.",
        "q1": "Q1. Adding the gateway hop?", "q1sub": "direct call vs through the gateway",
        "q2": "Q2. Turning on guardrail argument checks?", "q2sub": "adds a per-call gRPC round trip to the check server",
        "close": "new conn per call", "reuse": "connection reuse", "arrow": "->",
        "b1": "direct", "a1": "via gateway", "b2": "no check", "a2": "check on (+gRPC round trip)",
        "take1": "Hop cost +0.5 to 1.6 ms; looms larger when clients reuse connections",
        "take2": "Argument checking costs about 0.5 ms per call, roughly constant across the measured conditions",
        "r_title": "Three rejection shapes the client sees",
        "r_sub": "The rejecting layer decides the shape, and the shape is the diagnostic clue.",
        "p_client": "client", "p_gw": "gateway", "p_authz": "authorization policy (mcpAuthorization)",
        "p_gr": "guardrail check server", "p_srv": "MCP server", "p_grpc": "gRPC round trip",
        "p_cap": "In all three shapes the request stops before reaching the MCP server.",
        "r1h": "mcpAuthorization deny", "r1b": "HTTP 400\n-32602 \"Unknown tool\"",
        "r1n": "Indistinguishable from no-such-tool;\nhidden from tools/list",
        "r2h": "mcpGuardrails deny", "r2b": "HTTP 200\n-32001 + server reason",
        "r2n": "The reason string passes through\n(\"allowed only with a == 1\")",
        "r3h": "FailClosed (server down)", "r3b": "HTTP 200\n-32603 internal error text",
        "r3n": "Guardrail down blocks all calls;\ninternal state leaks in the message",
    },
}


def svg_head(w, h):
    return [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
            f'font-family="Helvetica, Arial, sans-serif">',
            f'<rect width="{w}" height="{h}" fill="white"/>']


def cost(study, T):
    ab = os.path.join("runs", "ab-0819")
    wk = os.path.join("runs", "weekend-0820")
    gr = os.path.join("runs", "grm-0826")
    # 패널마다 질문 하나. 행 = (연결 방식, rps, 기준 프리픽스, 추가 프리픽스)
    panels = [
        (T["q1"], T["q1sub"], "#2e6f9e", T["b1"], T["a1"], [
            (T["close"], 100, os.path.join(ab, "ab-direct-rps{r}"), os.path.join(ab, "ab-gw-rps{r}")),
            (T["close"], 200, os.path.join(ab, "ab-direct-rps{r}"), os.path.join(ab, "ab-gw-rps{r}")),
            (T["reuse"], 100, os.path.join(wk, "abr-direct-rps{r}"), os.path.join(wk, "abr-gw-rps{r}")),
            (T["reuse"], 200, os.path.join(wk, "abr-direct-rps{r}"), os.path.join(wk, "abr-gw-rps{r}")),
        ]),
        (T["q2"], T["q2sub"], "#6a4b9e", T["b2"], T["a2"], [
            (T["close"], 100, os.path.join(gr, "grm-off-close-rps{r}"), os.path.join(gr, "grm-on-close-rps{r}")),
            (T["close"], 200, os.path.join(gr, "grm-off-close-rps{r}"), os.path.join(gr, "grm-on-close-rps{r}")),
            (T["reuse"], 100, os.path.join(gr, "grm-off-reuse-rps{r}"), os.path.join(gr, "grm-on-reuse-rps{r}")),
            (T["reuse"], 200, os.path.join(gr, "grm-off-reuse-rps{r}"), os.path.join(gr, "grm-on-reuse-rps{r}")),
        ]),
    ]
    W, H = 920, 470
    PANW = 400
    ROWH = 58
    TOP = 152
    XMAXMS = 8.0
    AXW = 240.0
    s = svg_head(W, H)
    s.append(f'<text x="{W/2}" y="30" font-size="14.5" fill="#111" '
             f'text-anchor="middle" font-weight="bold">{T["c_title"]}</text>')
    s.append(f'<text x="{W/2}" y="50" font-size="11" fill="#777" '
             f'text-anchor="middle">{T["c_sub"]}</text>')
    for pi, (q, qsub, color, blabel, alabel, rows) in enumerate(panels):
        px = 26 + pi * (PANW + 60)
        ax0 = px + 96
        def X(ms):
            return ax0 + ms / XMAXMS * AXW
        s.append(f'<text x="{px+PANW/2}" y="84" font-size="12.5" fill="#111" '
                 f'text-anchor="middle" font-weight="bold">{q}</text>')
        s.append(f'<text x="{px+PANW/2}" y="100" font-size="10.5" fill="#666" '
                 f'text-anchor="middle">{qsub}</text>')
        # 범례: 기준 점과 추가 점
        s.append(f'<circle cx="{px+40}" cy="122" r="5" fill="#8a8f98"/>')
        s.append(f'<text x="{px+50}" y="126" font-size="10.5" fill="#333">{blabel}</text>')
        s.append(f'<circle cx="{px+210}" cy="122" r="5" fill="{color}"/>')
        s.append(f'<text x="{px+220}" y="126" font-size="10.5" fill="#333">{alabel}</text>')
        # 축 (절대 ms)
        for t in range(0, 9, 2):
            s.append(f'<line x1="{X(t):.1f}" y1="{TOP-8}" x2="{X(t):.1f}" '
                     f'y2="{TOP+len(rows)*ROWH-20}" stroke="#eee"/>')
            s.append(f'<text x="{X(t):.1f}" y="{TOP+len(rows)*ROWH-6}" font-size="9.5" '
                     f'fill="#999" text-anchor="middle">{t}</text>')
        s.append(f'<text x="{X(4):.1f}" y="{TOP+len(rows)*ROWH+10}" font-size="10" '
                 f'fill="#777" text-anchor="middle">p50 (ms)</text>')
        for ri, (mode, rps, base_p, add_p) in enumerate(rows):
            y = TOP + ri * ROWH
            b50, _ = med(study, base_p.format(r=rps))
            a50, _ = med(study, add_p.format(r=rps))
            d = a50 - b50
            xb, xa = X(b50), X(a50)
            s.append(f'<text x="{px}" y="{y+2}" font-size="11" fill="#333">{mode}</text>')
            s.append(f'<text x="{px}" y="{y+16}" font-size="10" fill="#888">{rps} rps</text>')
            s.append(f'<line x1="{xb:.1f}" y1="{y}" x2="{xa:.1f}" y2="{y}" '
                     f'stroke="{color}" stroke-width="4" opacity="0.45"/>')
            s.append(f'<circle cx="{xb:.1f}" cy="{y}" r="5.5" fill="#8a8f98"/>')
            s.append(f'<circle cx="{xa:.1f}" cy="{y}" r="5.5" fill="{color}"/>')
            s.append(f'<text x="{xb:.1f}" y="{y+21}" font-size="9.5" fill="#777" '
                     f'text-anchor="middle">{b50:.1f}</text>')
            s.append(f'<text x="{xa:.1f}" y="{y-11}" font-size="9.5" fill="{color}" '
                     f'text-anchor="middle" font-weight="bold">{a50:.1f}</text>')
            s.append(f'<text x="{px+PANW-8}" y="{y+5}" font-size="12.5" fill="#222" '
                     f'text-anchor="end" font-weight="bold">{d:+.1f}ms</text>')
        s.append(f'<text x="{px}" y="{TOP+len(rows)*ROWH+30}" font-size="10.5" '
                 f'fill="#555">{T["take1"] if pi==0 else T["take2"]}</text>')
    s.append("</svg>")
    return "\n".join(s)


def reject(T):
    W, H = 760, 580
    s = svg_head(W, H)
    s.append(f'<text x="{W/2}" y="30" font-size="14" fill="#111" '
             f'text-anchor="middle" font-weight="bold">{T["r_title"]}</text>')
    s.append(f'<text x="{W/2}" y="48" font-size="11" fill="#777" '
             f'text-anchor="middle">{T["r_sub"]}</text>')

    C1, C2, C3 = "#c1442e", "#6a4b9e", "#8a6d1f"

    def box(x, y, w, h, label, sub=None, stroke="#999"):
        s.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" '
                 f'fill="#fafafa" stroke="{stroke}" stroke-width="1.5"/>')
        ly = y + (h / 2 + 4 if sub is None else h / 2 - 4)
        s.append(f'<text x="{x + w / 2}" y="{ly}" font-size="12" fill="#222" '
                 f'text-anchor="middle" font-weight="bold">{label}</text>')
        if sub:
            s.append(f'<text x="{x + w / 2}" y="{y + h / 2 + 14}" font-size="9.5" '
                     f'fill="#666" text-anchor="middle">{sub}</text>')

    def arrow(x1, y1, x2, y2):
        s.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" '
                 f'stroke="#555" stroke-width="1.8"/>')
        import math
        ang = math.atan2(y2 - y1, x2 - x1)
        for da in (2.6, -2.6):
            s.append(f'<line x1="{x2}" y1="{y2}" '
                     f'x2="{x2 + 9 * math.cos(ang + da):.1f}" '
                     f'y2="{y2 + 9 * math.sin(ang + da):.1f}" '
                     f'stroke="#555" stroke-width="1.8"/>')

    def marker(x, y, n, color):
        s.append(f'<circle cx="{x}" cy="{y}" r="11" fill="{color}"/>')
        s.append(f'<text x="{x}" y="{y + 4}" font-size="12" fill="white" '
                 f'text-anchor="middle" font-weight="bold">{n}</text>')

    # 경로 지형도
    box(40, 120, 110, 44, T["p_client"])
    box(280, 106, 170, 72, T["p_gw"], T["p_authz"])
    box(560, 120, 150, 44, T["p_srv"])
    arrow(150, 142, 278, 142)
    arrow(450, 142, 558, 142)
    # guardrail 서버와 gRPC 링크
    box(280, 252, 170, 44, T["p_gr"])
    s.append('<line x1="365" y1="178" x2="365" y2="250" stroke="#555" '
             'stroke-width="1.8" stroke-dasharray="4,3"/>')
    s.append(f'<text x="384" y="218" font-size="9.5" fill="#666">{T["p_grpc"]}</text>')
    # 거부 지점 마커
    s.append(f'<line x1="352" y1="228" x2="378" y2="200" stroke="{C3}" stroke-width="2.5"/>')
    marker(292, 118, "1", C1)      # 게이트웨이 안 인가 정책
    marker(292, 252, "2", C2)      # guardrail 서버의 거부 판정
    marker(365, 214, "3", C3)      # 링크 단절(서버 불달)
    s.append(f'<text x="{W / 2}" y="326" font-size="10.5" fill="#555" '
             f'text-anchor="middle">{T["p_cap"]}</text>')

    # 형태 카드 3장
    cols = [
        ("1", T["r1h"], T["r1b"], T["r1n"], C1),
        ("2", T["r2h"], T["r2b"], T["r2n"], C2),
        ("3", T["r3h"], T["r3b"], T["r3n"], C3),
    ]
    cw, cy = 224, 348
    for i, (num, head, body, note, color) in enumerate(cols):
        x = 24 + i * (cw + 20)
        s.append(f'<rect x="{x}" y="{cy}" width="{cw}" height="200" rx="8" '
                 f'fill="none" stroke="{color}" stroke-width="2"/>')
        s.append(f'<rect x="{x}" y="{cy}" width="{cw}" height="38" rx="8" fill="{color}"/>')
        s.append(f'<rect x="{x}" y="{cy + 24}" width="{cw}" height="14" fill="{color}"/>')
        s.append(f'<text x="{x + cw / 2}" y="{cy + 24}" font-size="12.5" fill="white" '
                 f'text-anchor="middle" font-weight="bold">{num}. {head}</text>')
        for li, line in enumerate(body.split("\n")):
            s.append(f'<text x="{x + cw / 2}" y="{cy + 70 + li * 20}" font-size="12.5" '
                     f'fill="#222" text-anchor="middle" '
                     f'font-family="Menlo, monospace">{line}</text>')
        for li, line in enumerate(note.split("\n")):
            s.append(f'<text x="{x + cw / 2}" y="{cy + 136 + li * 17}" font-size="11" '
                     f'fill="#555" text-anchor="middle">{line}</text>')
    s.append("</svg>")
    return "\n".join(s)


if __name__ == "__main__":
    study, kind = sys.argv[1], sys.argv[2]
    lang = sys.argv[3] if len(sys.argv) > 3 else "en"
    T = TEXT[lang]
    print(cost(study, T) if kind == "cost" else reject(T))
