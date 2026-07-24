# lambda-proxy

AWS Lambda (`ap-northeast-2`) 에 **`api` ~ `api-N`** TLS 프록시 함수를 배포·동기화하는 도구입니다.

런타임:
- **node** — `nodejs24.x` + `index.handler`
- **bun** — `provided.al2023` + bun layer + `index.fetch`

HTTP 클라이언트: **`@alice-doctor/wreq-js`** (브라우저 TLS 위장)

## 요구 사항

- AWS CLI 로그인 (`aws sts get-caller-identity`)
- `npm`, `python3`, `curl`, `zip`, `unzip`
- 대상 arch 용 native: `wreq-js.linux-arm64-gnu.node` 또는 `linux-x64-gnu`  
  (`LAMBDA_WREQ_NATIVE` 또는 `out/native/<ver>/` / CI 다운로드)

## 사용

```bash
./run.sh node                 # 기존 node 계정 동기화
./run.sh bun                  # bun (layer 없으면 publish)
./run.sh bun --create-role    # 빈 계정: role + layer + 함수 생성
./run.sh node --max 5
./run.sh node --dry-run
```

| 옵션 | 설명 |
|------|------|
| `--create-role` | IAM role 없으면 생성 |
| `--skip-layer-create` | bun layer 자동 publish 안 함 |
| `--update-layer` | bun layer 강제 재 publish |
| `--force` | runtime/flavor 불일치 강제 |
| `--skip-build` | 기존 `out/function-*.zip` 재사용 |
| `--ensure-only` / `--deploy-only` | 생성·URL 만 / 코드만 |
| `--max N` / `--prefix NAME` | 대상 범위 |

## 동작 요약

1. AWS 로그인 확인  
2. **bun**: layer 없으면 publish (이미지 불필요)  
3. 없는 함수 생성 (zip 1회 빌드)  
4. 함수마다 `code → wait → config → wait`  
5. Function URL + `out/function-urls.json`  
6. 실패 시 `out/deploy-results.jsonl` 기준 exit 1  

## 환경 변수

`config.sh` 참고. 자주 쓰는 것:

| 변수 | 기본 |
|------|------|
| `AWS_REGION` | `ap-northeast-2` |
| `LAMBDA_WREQ_MAX` | `100` |
| `LAMBDA_WREQ_ARCH` | 기존 함수에서 자동 감지 (`arm64` / `x86_64`) |
| `LAMBDA_WREQ_ROLE` | 기존 함수 role 또는 `--create-role` |
| `LAMBDA_WREQ_BUN_LAYER` | 기존 layer ARN |
| `LAMBDA_WREQ_NPM_VER` | `2.3.3` |
| `LAMBDA_WREQ_NATIVE` | linux-*.node 경로 |

## 구조

```
run.sh
config.sh
lib/common.sh
lib/bun-layer/bootstrap
package/node/index.mjs
package/bun/index.ts
out/   # 로컬 산출물 (gitignore)
```

## 핸들러 API

- `GET /health` — 상태·프로필 수
- `GET /profiles` — 지원 프로필 목록
- `POST /` — body: `url`, `method`, `headers`, `data`, `browser`, `os`, `proxy`, `emulation`/`tls`, …

## 라이선스

Private / internal use.
