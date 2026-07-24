#!/usr/bin/env bash
# run.sh — api ~ api-N 에 @alice-doctor/wreq-js 프록시 배포
#
#   ./run.sh node
#   ./run.sh bun
#   ./run.sh bun --create-role --max 2
#   ./run.sh node --force --skip-build
#
set -euo pipefail

_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_ROOT/lib/common.sh"

FLAVOR=""
DRY_RUN=false
ENSURE_ONLY=false
DEPLOY_ONLY=false
SKIP_BUILD=false
CREATE_ROLE=false
SKIP_LAYER_CREATE=false
UPDATE_LAYER=false
FORCE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") <node|bun> [options]

  ap-northeast-2 의 ${LAMBDA_WREQ_PREFIX} … ${LAMBDA_WREQ_PREFIX}-N 동기화
  패키지: ${LAMBDA_WREQ_NPM_PKG}@${LAMBDA_WREQ_NPM_VER}

  node   nodejs24.x / index.handler
  bun    provided.al2023 + bun layer / index.fetch
         (layer 없으면 publish, 함수 없으면 생성)

Options:
  --ensure-only       함수·URL 만 (코드 배포 생략; 생성 시 zip 필요)
  --deploy-only       코드 배포만 (없는 함수 생성 안 함)
  --skip-build        out/function-{node,bun}.zip 재사용
  --create-role       IAM role 없으면 생성 (기본: env/기존 함수 role)
  --skip-layer-create bun layer 없으면 실패 (자동 publish 안 함)
  --update-layer      bun layer 강제 재 publish
  --force             기존 runtime 과 flavor 불일치 허용
  --dry-run           변경 없이 상태·URL 스냅샷
  --max N             대상 개수 (api + api-2 …)
  --prefix NAME       기본 api
  -h, --help

출력: out/function-urls.json, out/deploy-results.jsonl
환경: config.sh (LAMBDA_WREQ_ROLE, LAMBDA_WREQ_BUN_LAYER, LAMBDA_WREQ_NATIVE …)
EOF
}

if [[ $# -lt 1 ]]; then usage; exit 1; fi
case "$1" in
  node|bun) FLAVOR="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
  *) err "첫 인자: node | bun"; usage; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ensure-only) ENSURE_ONLY=true; shift ;;
    --deploy-only) DEPLOY_ONLY=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --create-role) CREATE_ROLE=true; shift ;;
    --skip-layer-create) SKIP_LAYER_CREATE=true; shift ;;
    --update-layer) UPDATE_LAYER=true; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --max)
      [[ $# -ge 2 ]] || die "--max 값 필요"
      LAMBDA_WREQ_MAX="$2"; shift 2
      ;;
    --prefix)
      [[ $# -ge 2 ]] || die "--prefix 값 필요"
      LAMBDA_WREQ_PREFIX="$2"; shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

apply_flavor "$FLAVOR"

NAMES=()
while IFS= read -r _n; do
  [[ -n "$_n" ]] && NAMES+=("$_n")
done < <(function_names)
TOTAL="${#NAMES[@]}"
[[ "$TOTAL" -ge 1 ]] || die "대상 함수 0개"
LAST_IDX=$((TOTAL - 1))

log ""
log "════════════════════════════════════════"
log " lambda-wreq  flavor=${FLAVOR}  n=${TOTAL}"
log " ${NAMES[0]} … ${NAMES[$LAST_IDX]}"
log " ${LAMBDA_WREQ_NPM_PKG}@${LAMBDA_WREQ_NPM_VER}"
log "════════════════════════════════════════"
log ""

require_aws_login
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
: >"$RESULTS_FILE"

# 기존 함수 arch 감지 (x86_64 / arm64)
if detect_arch_from_function "$LAMBDA_WREQ_PREFIX" 2>/dev/null; then
  :
else
  info "arch default: ${LAMBDA_WREQ_ARCH:-arm64}"
fi

if ! $DRY_RUN; then
  guard_flavor_mismatch "$FORCE"
fi

# role + layer (생성 전)
ROLE=""
if ! $DRY_RUN && ! $DEPLOY_ONLY; then
  if [[ "$FLAVOR" == "bun" ]]; then
    ensure_bun_layer "$UPDATE_LAYER" "$SKIP_LAYER_CREATE"
  fi
  # create 가 필요할 수 있으면 role 확보
fi

# ── 1) 존재 스캔 ──────────────────────────────────────
info "1/4  존재 확인…"
EXISTING=()
MISSING=()
for name in "${NAMES[@]}"; do
  if function_exists "$name"; then
    EXISTING+=("$name")
  else
    MISSING+=("$name")
  fi
done
MISS_COUNT=${#MISSING[@]}
ok "존재 ${#EXISTING[@]}/${TOTAL}  없음 ${MISS_COUNT}"

# ── zip 1회 ───────────────────────────────────────────
ZIP=""
need_zip=false
if ! $DRY_RUN; then
  if [[ "$MISS_COUNT" -gt 0 ]] && ! $DEPLOY_ONLY; then need_zip=true; fi
  if ! $ENSURE_ONLY; then need_zip=true; fi
fi
if $need_zip; then
  if $SKIP_BUILD && [[ -f "$OUT_DIR/$ZIP_NAME" ]]; then
    ZIP="$OUT_DIR/$ZIP_NAME"
    ok "기존 zip: $ZIP"
  else
    ZIP="$(build_zip "$FLAVOR")"
    ZIP="${ZIP//$'\r'/}"
    ZIP="$(printf '%s' "$ZIP" | tail -n1)"
  fi
  [[ -f "$ZIP" ]] || die "zip 없음: [$ZIP]"
fi

# ── 2) 생성 ───────────────────────────────────────────
CREATED=0
if [[ "$MISS_COUNT" -gt 0 ]]; then
  if $DEPLOY_ONLY; then
    warn "--deploy-only: 생성 스킵 (${MISS_COUNT})"
  elif $DRY_RUN; then
    warn "[dry-run] 생성 예정 ${MISS_COUNT}"
  else
    info "2/4  함수 생성…"
    if [[ "$FLAVOR" == "bun" && -z "${RESOLVED_BUN_LAYER:-}" ]]; then
      ensure_bun_layer "$UPDATE_LAYER" "$SKIP_LAYER_CREATE"
    fi
    ROLE="$(ensure_iam_role "$CREATE_ROLE")"
    [[ -n "$ZIP" ]] || die "생성용 zip 없음"
    for name in "${MISSING[@]}"; do
      create_function "$name" "$ZIP" "$ROLE"
      CREATED=$((CREATED + 1))
    done
    ok "생성 ${CREATED}"
  fi
else
  ok "2/4  생성 없음"
fi

# bun 배포 시 layer 확보 (기존 함수만 있어도 config 용)
if ! $DRY_RUN && [[ "$FLAVOR" == "bun" ]]; then
  if [[ -z "${RESOLVED_BUN_LAYER:-}" ]]; then
    ensure_bun_layer "$UPDATE_LAYER" "$SKIP_LAYER_CREATE"
  fi
fi

# ── 3) 배포 ───────────────────────────────────────────
if $ENSURE_ONLY; then
  info "3/4  --ensure-only → 배포 스킵"
elif $DRY_RUN; then
  info "3/4  [dry-run] 배포 스킵"
else
  info "3/4  배포 (${FLAVOR})…"
  [[ -n "$ZIP" && -f "$ZIP" ]] || die "배포 zip 없음"
  export ZIP AWS_REGION OUT_DIR RESULTS_FILE
  export LAMBDA_WREQ_FLAVOR LAMBDA_WREQ_RUNTIME LAMBDA_WREQ_HANDLER
  export LAMBDA_WREQ_MEMORY LAMBDA_WREQ_TIMEOUT RESOLVED_BUN_LAYER
  # deploy_one 은 common 에 있음 — 서브쉘에서 source
  printf '%s\n' "${NAMES[@]}" | xargs -P "${LAMBDA_WREQ_PARALLEL}" -I{} \
    /bin/bash -c '
      set -euo pipefail
      source "'"${_ROOT}"'/lib/common.sh"
      # 부모 export 재적용
      OUT_DIR="'"${OUT_DIR}"'"
      RESULTS_FILE="'"${RESULTS_FILE}"'"
      LAMBDA_WREQ_FLAVOR="'"${LAMBDA_WREQ_FLAVOR}"'"
      LAMBDA_WREQ_RUNTIME="'"${LAMBDA_WREQ_RUNTIME}"'"
      LAMBDA_WREQ_HANDLER="'"${LAMBDA_WREQ_HANDLER}"'"
      LAMBDA_WREQ_MEMORY="'"${LAMBDA_WREQ_MEMORY}"'"
      LAMBDA_WREQ_TIMEOUT="'"${LAMBDA_WREQ_TIMEOUT}"'"
      RESOLVED_BUN_LAYER="'"${RESOLVED_BUN_LAYER:-}"'"
      AWS_REGION="'"${AWS_REGION}"'"
      deploy_one "$1" "'"${ZIP}"'"
    ' _ {}
  ok "배포 루프 종료"
fi

# ── 4) URL ────────────────────────────────────────────
info "4/4  Function URL…"
TMP_JSONL="$OUT_DIR/.urls.jsonl"
: >"$TMP_JSONL"
ENSURED_URLS=0
for name in "${NAMES[@]}"; do
  if ! function_exists "$name"; then
    python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"url":None,"exists":False,"urlStatus":"missing-function"},ensure_ascii=False))' \
      "$name" >>"$TMP_JSONL"
    continue
  fi
  if $DRY_RUN; then
    url="$(aws lambda get-function-url-config --function-name "$name" --region "$AWS_REGION" --query FunctionUrl --output text 2>/dev/null || true)"
    if [[ -z "$url" || "$url" == "None" ]]; then
      python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"url":None,"exists":True,"urlStatus":"would-create"},ensure_ascii=False))' \
        "$name" >>"$TMP_JSONL"
    else
      python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"url":sys.argv[2],"exists":True,"urlStatus":"exists"},ensure_ascii=False))' \
        "$name" "$url" >>"$TMP_JSONL"
      ENSURED_URLS=$((ENSURED_URLS + 1))
    fi
    continue
  fi
  url="$(ensure_function_url "$name")"
  ENSURED_URLS=$((ENSURED_URLS + 1))
  python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"url":sys.argv[2],"exists":True,"urlStatus":"ok"},ensure_ascii=False))' \
    "$name" "$url" >>"$TMP_JSONL"
done

OUT_JSON="$OUT_DIR/function-urls.json"
OUT_TXT="$OUT_DIR/function-urls.txt"
OUT_JSON_ACCT="$OUT_DIR/function-urls-${ACCOUNT}.json"
save_urls_json "$TMP_JSONL" "$OUT_JSON" "$OUT_TXT"
cp -f "$OUT_JSON" "$OUT_JSON_ACCT"
rm -f "$TMP_JSONL"

log ""
log "────────────────────────────────────────"
ok "완료 account=${ACCOUNT} flavor=${FLAVOR}"
log "  존재 ${#EXISTING[@]}/${TOTAL}  생성 ${CREATED}  URL ${ENSURED_URLS}"
log "  JSON ${OUT_JSON}"
log "  results ${RESULTS_FILE}"
log "────────────────────────────────────────"

# 배포 결과 집계 (ensure-only/dry-run 은 fail 없으면 0)
if ! $DRY_RUN && ! $ENSURE_ONLY; then
  if ! summarize_deploy_results; then
    err "배포 실패 항목 있음 — ${RESULTS_FILE}"
    exit 1
  fi
fi
exit 0
