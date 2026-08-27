# 축 3 최소 guardrail 정책 서버 (ExtMcp gRPC).
# 규칙 하나만 강제한다: tools/call의 get-sum은 arguments.a == 1일 때만 허용.
# 그 외 메서드와 도구는 전부 통과. 결정마다 stdout에 로그를 남긴다(증거용).
#
# 스텁 재생성: grpcio-tools로 ext_mcp.proto에서 생성
#   python -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. ext_mcp.proto
# 프로토 출처: agentgateway v1.4.1 crates/protos/proto/ext_mcp.proto (main과 동일 확인)
import json
import sys
from concurrent import futures

import grpc

import ext_mcp_pb2 as pb
import ext_mcp_pb2_grpc as pbg


def log(*args):
    print(*args, flush=True)


class Policy(pbg.ExtMcpServicer):
    def CheckRequest(self, request, context):
        method = request.method
        if method != "tools/call":
            log(f"PASS   method={method} (관여 안 함)")
            return pb.McpRequestResult(**{"pass": pb.Pass()})

        name, args = "", {}
        if request.HasField("mcp_request"):
            try:
                params = json.loads(request.mcp_request)
                name = params.get("name", "")
                args = params.get("arguments") or {}
            except Exception as e:
                log(f"DENY   method={method} params 파싱 실패: {e}")
                return pb.McpRequestResult(error=pb.AuthorizationError(
                    code=pb.AuthorizationError.INVALID, reason="unparseable params"))

        if name.endswith("get-sum"):
            if args.get("a") == 1:
                log(f"PASS   tool={name} a={args.get('a')} (조건 충족)")
                return pb.McpRequestResult(**{"pass": pb.Pass()})
            log(f"DENY   tool={name} a={args.get('a')} (a == 1 아님)")
            return pb.McpRequestResult(error=pb.AuthorizationError(
                code=pb.AuthorizationError.PERMISSION_DENIED,
                reason="get-sum is allowed only with a == 1"))

        log(f"PASS   tool={name} (규칙 무관 도구)")
        return pb.McpRequestResult(**{"pass": pb.Pass()})

    def CheckResponse(self, request, context):
        log(f"RESP   method={request.method} bytes={len(request.mcp_response)} (응답 페이즈 수신)")
        return pb.McpResponseResult(**{"pass": pb.Pass()})


def main():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    pbg.add_ExtMcpServicer_to_server(Policy(), server)
    server.add_insecure_port("0.0.0.0:50051")
    server.start()
    log("guardrail 정책 서버 시작 :50051 (규칙: get-sum은 a == 1일 때만 허용)")
    server.wait_for_termination()


if __name__ == "__main__":
    sys.exit(main())
