# shellcheck shell=bash
# lambda-wreq 공통 — macOS bash 3.2 호환

set -euo pipefail

_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.sh
source "$_ROOT/config.sh"

OUT_DIR="${LAMBDA_WREQ_OUT_DIR:-$_ROOT/out}"
mkdir -p "$OUT_DIR"
RESULTS_DIR="${OUT_DIR}/deploy-results"
RESULTS_FILE="${OUT_DIR}/deploy-results.jsonl"
mkdir -p "$RESULTS_DIR"

if [[ -t 2 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_RST=
fi

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%sℹ%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
ok()   { printf '%s✔%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s⚠%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s✖%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_aws_cli() {
  command -v aws >/dev/null 2>&1 || die "aws CLI 필요"
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  command -v npm >/dev/null 2>&1 || die "npm 필요"
  command -v curl >/dev/null 2>&1 || die "curl 필요"
  command -v zip >/dev/null 2>&1 || die "zip 필요"
  command -v unzip >/dev/null 2>&1 || die "unzip 필요"
}

print_login_guide() {
  cat <<EOF >&2

${C_YEL}AWS 로그인 필요${C_RST} (region=${AWS_REGION})
  aws sso login --profile <p> && export AWS_PROFILE=<p>
  또는 aws configure
  확인: aws sts get-caller-identity --region ${AWS_REGION}

EOF
}

require_aws_login() {
  require_aws_cli
  local out
  if ! out="$(aws sts get-caller-identity --region "$AWS_REGION" --output json 2>&1)"; then
    err "로그인 실패:"; printf '%s\n' "$out" | sed 's/^/  /' >&2
    print_login_guide
    exit 1
  fi
  ACCOUNT="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Account"])')"
  CALLER_ARN="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Arn"])')"
  ok "AWS OK account=${ACCOUNT}"
  export ACCOUNT CALLER_ARN
}

function_names() {
  local i
  printf '%s\n' "$LAMBDA_WREQ_PREFIX"
  i=2
  while [[ "$i" -le "$LAMBDA_WREQ_MAX" ]]; do
    printf '%s-%s\n' "$LAMBDA_WREQ_PREFIX" "$i"
    i=$((i + 1))
  done
}

function_exists() {
  aws lambda get-function --function-name "$1" --region "$AWS_REGION" \
    --query 'Configuration.FunctionName' --output text >/dev/null 2>&1
}

apply_flavor() {
  case "$1" in
    node)
      LAMBDA_WREQ_FLAVOR=node
      LAMBDA_WREQ_RUNTIME="$LAMBDA_WREQ_NODE_RUNTIME"
      LAMBDA_WREQ_HANDLER="$LAMBDA_WREQ_NODE_HANDLER"
      PKG_DIR="$_ROOT/package/node"
      ZIP_NAME="function-node.zip"
      ;;
    bun)
      LAMBDA_WREQ_FLAVOR=bun
      LAMBDA_WREQ_RUNTIME="$LAMBDA_WREQ_BUN_RUNTIME"
      LAMBDA_WREQ_HANDLER="$LAMBDA_WREQ_BUN_HANDLER"
      PKG_DIR="$_ROOT/package/bun"
      ZIP_NAME="function-bun.zip"
      ;;
    *) die "flavor 는 node|bun" ;;
  esac
  export LAMBDA_WREQ_FLAVOR LAMBDA_WREQ_RUNTIME LAMBDA_WREQ_HANDLER PKG_DIR ZIP_NAME
  info "flavor=${LAMBDA_WREQ_FLAVOR} runtime=${LAMBDA_WREQ_RUNTIME} handler=${LAMBDA_WREQ_HANDLER}"
}

# 기존 함수 runtime 과 flavor 불일치 시 die (--force 예외)
guard_flavor_mismatch() {
  local force="$1"
  function_exists "$LAMBDA_WREQ_PREFIX" || return 0
  local rt
  rt="$(aws lambda get-function-configuration \
    --function-name "$LAMBDA_WREQ_PREFIX" --region "$AWS_REGION" \
    --query 'Runtime' --output text 2>/dev/null || true)"
  [[ -z "$rt" || "$rt" == "None" ]] && return 0
  local ok_match=0
  if [[ "$LAMBDA_WREQ_FLAVOR" == "node" && "$rt" == nodejs* ]]; then ok_match=1; fi
  if [[ "$LAMBDA_WREQ_FLAVOR" == "bun" && "$rt" == provided* ]]; then ok_match=1; fi
  if [[ "$ok_match" -eq 1 ]]; then return 0; fi
  if [[ "$force" == "true" ]]; then
    warn "flavor 불일치 무시 (--force): 기존 runtime=${rt} → ${LAMBDA_WREQ_RUNTIME}"
    return 0
  fi
  die "기존 ${LAMBDA_WREQ_PREFIX} runtime=${rt} 과 flavor=${LAMBDA_WREQ_FLAVOR} 불일치. --force 로 강제 전환."
}

wait_function_updated() {
  local name="$1"
  aws lambda wait function-updated-v2 --function-name "$name" --region "$AWS_REGION" 2>/dev/null \
    || aws lambda wait function-updated --function-name "$name" --region "$AWS_REGION" 2>/dev/null \
    || true
}

wait_function_active() {
  local name="$1"
  local i=0
  while [[ "$i" -lt "$LAMBDA_WREQ_WAIT_RETRIES" ]]; do
    if aws lambda wait function-active-v2 --function-name "$name" --region "$AWS_REGION" 2>/dev/null \
      || aws lambda wait function-active --function-name "$name" --region "$AWS_REGION" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep $((i * 2))
  done
  return 1
}

record_result() {
  # name stage status msg — 함수별 파일 (병렬 안전) 후 집계 시 merge
  local name="$1" stage="$2" status="$3" msg="$4"
  mkdir -p "$RESULTS_DIR"
  python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"stage":sys.argv[2],"status":sys.argv[3],"msg":sys.argv[4]},ensure_ascii=False))' \
    "$name" "$stage" "$status" "$msg" >"$RESULTS_DIR/${name}.${status}.${stage}.json"
}

# ── Role ─────────────────────────────────────────────
resolve_role() {
  if [[ -n "${LAMBDA_WREQ_ROLE}" ]]; then
    printf '%s' "$LAMBDA_WREQ_ROLE"
    return 0
  fi
  local role=""
  if function_exists "$LAMBDA_WREQ_PREFIX"; then
    role="$(aws lambda get-function-configuration \
      --function-name "$LAMBDA_WREQ_PREFIX" --region "$AWS_REGION" \
      --query 'Role' --output text 2>/dev/null || true)"
  fi
  if [[ -n "$role" && "$role" != "None" ]]; then
    printf '%s' "$role"
    return 0
  fi
  # 이름 기반 get
  if role="$(aws iam get-role --role-name "$LAMBDA_WREQ_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)" \
    && [[ -n "$role" && "$role" != "None" ]]; then
    printf '%s' "$role"
    return 0
  fi
  return 1
}

ensure_iam_role() {
  local create_role="$1"
  local role
  if role="$(resolve_role)"; then
    ok "role: $role"
    printf '%s' "$role"
    return 0
  fi
  if [[ "$create_role" != "true" ]]; then
    die "IAM role 없음. LAMBDA_WREQ_ROLE=... 또는 --create-role"
  fi
  info "IAM role 생성: ${LAMBDA_WREQ_ROLE_NAME}"
  local trust
  trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  aws iam create-role \
    --role-name "$LAMBDA_WREQ_ROLE_NAME" \
    --assume-role-policy-document "$trust" \
    --description "lambda-wreq execution role" \
    --output text --query 'Role.Arn' >/dev/null
  aws iam attach-role-policy \
    --role-name "$LAMBDA_WREQ_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  local i=0
  while [[ "$i" -lt 12 ]]; do
    if role="$(aws iam get-role --role-name "$LAMBDA_WREQ_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)" \
      && [[ -n "$role" && "$role" != "None" ]]; then
      sleep 4
      ok "role 생성됨: $role"
      printf '%s' "$role"
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  die "role 생성 후 ARN 조회 실패"
}

# ── Bun layer ────────────────────────────────────────
# 전역 RESOLVED_BUN_LAYER
RESOLVED_BUN_LAYER=""

get_latest_layer_arn() {
  local name="$1"
  aws lambda list-layer-versions \
    --layer-name "$name" --region "$AWS_REGION" \
    --query 'max_by(LayerVersions, &Version).LayerVersionArn' \
    --output text 2>/dev/null || true
}

ensure_bun_layer() {
  local update_layer="$1"
  local skip_create="$2"

  if [[ -n "${LAMBDA_WREQ_BUN_LAYER}" ]]; then
    if aws lambda get-layer-version-by-arn --arn "$LAMBDA_WREQ_BUN_LAYER" --region "$AWS_REGION" >/dev/null 2>&1; then
      RESOLVED_BUN_LAYER="$LAMBDA_WREQ_BUN_LAYER"
      ok "bun layer (env): $RESOLVED_BUN_LAYER"
      return 0
    fi
    die "LAMBDA_WREQ_BUN_LAYER 검증 실패: $LAMBDA_WREQ_BUN_LAYER"
  fi

  # 기존 함수 layer 유지 (기본)
  if [[ "$update_layer" != "true" ]] && function_exists "$LAMBDA_WREQ_PREFIX"; then
    local fl
    fl="$(aws lambda get-function-configuration \
      --function-name "$LAMBDA_WREQ_PREFIX" --region "$AWS_REGION" \
      --query 'Layers[0].Arn' --output text 2>/dev/null || true)"
    if [[ -n "$fl" && "$fl" != "None" ]]; then
      RESOLVED_BUN_LAYER="$fl"
      ok "bun layer (기존 함수): $RESOLVED_BUN_LAYER"
      return 0
    fi
  fi

  local latest
  latest="$(get_latest_layer_arn "$LAMBDA_WREQ_BUN_LAYER_NAME")"
  if [[ -n "$latest" && "$latest" != "None" && "$update_layer" != "true" ]]; then
    RESOLVED_BUN_LAYER="$latest"
    ok "bun layer (계정 latest): $RESOLVED_BUN_LAYER"
    return 0
  fi

  if [[ "$skip_create" == "true" ]]; then
    die "bun layer 없음 (--skip-layer-create). LAMBDA_WREQ_BUN_LAYER 또는 layer publish 필요"
  fi

  info "bun layer 빌드·publish (bun@${LAMBDA_WREQ_BUN_VERSION}, arm64)…"
  local work="$OUT_DIR/bun-layer-build"
  rm -rf "$work"
  mkdir -p "$work"
  local url="https://github.com/oven-sh/bun/releases/download/bun-v${LAMBDA_WREQ_BUN_VERSION}/bun-linux-aarch64.zip"
  curl -fsSL "$url" -o "$work/bun.zip"
  unzip -qo "$work/bun.zip" -d "$work"
  local bunbin
  bunbin="$(find "$work" -type f -name bun | head -1)"
  [[ -n "$bunbin" && -f "$bunbin" ]] || die "bun 바이너리 추출 실패"
  mkdir -p "$work/layer-root"
  cp -f "$bunbin" "$work/layer-root/bun"
  cp -f "$_ROOT/lib/bun-layer/bootstrap" "$work/layer-root/bootstrap"
  chmod +x "$work/layer-root/bun" "$work/layer-root/bootstrap"
  local lzip="$OUT_DIR/bun-layer.zip"
  ( cd "$work/layer-root" && zip -qr "$lzip" bun bootstrap )
  RESOLVED_BUN_LAYER="$(aws lambda publish-layer-version \
    --layer-name "$LAMBDA_WREQ_BUN_LAYER_NAME" \
    --description "bun@${LAMBDA_WREQ_BUN_VERSION} arm64 lambda-wreq" \
    --zip-file "fileb://${lzip}" \
    --compatible-runtimes provided.al2023 \
    --compatible-architectures arm64 \
    --region "$AWS_REGION" \
    --query 'LayerVersionArn' --output text)"
  [[ -n "$RESOLVED_BUN_LAYER" && "$RESOLVED_BUN_LAYER" != "None" ]] || die "publish-layer-version 실패"
  ok "bun layer publish: $RESOLVED_BUN_LAYER"
}

# ── native / zip ─────────────────────────────────────
# LAMBDA_WREQ_ARCH: arm64 | x86_64 → napi triple
native_triple() {
  case "${LAMBDA_WREQ_ARCH:-arm64}" in
    arm64|aarch64) printf '%s' "linux-arm64-gnu" ;;
    x86_64|x64|amd64) printf '%s' "linux-x64-gnu" ;;
    *) die "unsupported LAMBDA_WREQ_ARCH=${LAMBDA_WREQ_ARCH}" ;;
  esac
}

detect_arch_from_function() {
  local name="${1:-$LAMBDA_WREQ_PREFIX}"
  function_exists "$name" || return 1
  local a
  a="$(aws lambda get-function-configuration \
    --function-name "$name" --region "$AWS_REGION" \
    --query 'Architectures[0]' --output text 2>/dev/null || true)"
  [[ -n "$a" && "$a" != "None" ]] || return 1
  LAMBDA_WREQ_ARCH="$a"
  export LAMBDA_WREQ_ARCH
  info "arch from ${name}: ${LAMBDA_WREQ_ARCH}"
}

ensure_native_binary() {
  local triple
  triple="$(native_triple)"
  local ver_dir="$OUT_DIR/native/${LAMBDA_WREQ_NPM_VER}"
  mkdir -p "$ver_dir"
  local dest="$ver_dir/wreq-js.${triple}.node"
  local asset="wreq-js.${triple}.node"

  if [[ -n "${LAMBDA_WREQ_NATIVE}" && -f "${LAMBDA_WREQ_NATIVE}" ]]; then
    cp -f "$LAMBDA_WREQ_NATIVE" "$dest"
    printf '%s' "$dest"
    return 0
  fi
  if [[ -f "$dest" ]]; then
    printf '%s' "$dest"
    return 0
  fi
  for cand in \
    "$OUT_DIR/$asset" \
    "$OUT_DIR/native/${LAMBDA_WREQ_NPM_VER}/$asset" \
    /tmp/wreq-native-fresh/"$asset" \
    /tmp/wreq-x64/"$asset"
  do
    if [[ -f "$cand" ]]; then
      cp -f "$cand" "$dest"
      ok "native 캐시: $cand"
      printf '%s' "$dest"
      return 0
    fi
  done
  if command -v gh >/dev/null 2>&1; then
    local tmpd; tmpd="$(mktemp -d)"
    local okdl=0
    if [[ "$triple" == "linux-arm64-gnu" ]]; then
      gh run download -R alice-wreq/wreq-js -n node-linux-arm64-gnu -D "$tmpd" 2>/dev/null && okdl=1
      gh run download -R alice-wreq/wreq-js -n bindings-aarch64-unknown-linux-gnu -D "$tmpd" 2>/dev/null && okdl=1
    else
      gh run download -R alice-wreq/wreq-js -n node-linux-x64-gnu -D "$tmpd" 2>/dev/null && okdl=1
      gh run download -R alice-wreq/wreq-js -n bindings-x86_64-unknown-linux-gnu -D "$tmpd" 2>/dev/null && okdl=1
    fi
    if [[ "$okdl" -eq 1 ]]; then
      local f; f="$(find "$tmpd" -name "*${triple}*.node" -o -name '*.node' | head -1)"
      if [[ -n "$f" ]]; then
        cp -f "$f" "$dest"
        rm -rf "$tmpd"
        ok "native gh: $dest"
        printf '%s' "$dest"
        return 0
      fi
    fi
    rm -rf "$tmpd"
  fi
  local tag="v${LAMBDA_WREQ_NPM_VER}"
  if curl -fsSL "https://github.com/alice-wreq/wreq-js/releases/download/${tag}/${asset}" -o "$dest" 2>/dev/null \
    && [[ -s "$dest" ]]; then
    chmod +x "$dest"
    printf '%s' "$dest"
    return 0
  fi
  if curl -fsSL "https://github.com/alice-wreq/wreq-js/releases/latest/download/${asset}" -o "$dest" 2>/dev/null \
    && [[ -s "$dest" ]]; then
    warn "native: latest ${asset}"
    chmod +x "$dest"
    printf '%s' "$dest"
    return 0
  fi
  rm -f "$dest"
  die "${triple} native 없음. LAMBDA_WREQ_NATIVE=... 또는 out/native/${LAMBDA_WREQ_NPM_VER}/${asset}"
}

build_zip() {
  local flavor="${1:-$LAMBDA_WREQ_FLAVOR}"
  apply_flavor "$flavor"

  local build_dir="$OUT_DIR/build-$flavor"
  local zip_path="$OUT_DIR/$ZIP_NAME"
  local native
  native="$(ensure_native_binary)"

  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  if [[ "$flavor" == "node" ]]; then
    cp "$PKG_DIR/index.mjs" "$build_dir/index.mjs"
  else
    cp "$PKG_DIR/index.ts" "$build_dir/index.ts"
  fi

  # package.json 을 config 기준으로 생성 (단일 소스)
  python3 - "$build_dir/package.json" "$flavor" "$LAMBDA_WREQ_NPM_PKG" "$LAMBDA_WREQ_NPM_VER" <<'PY'
import json, sys
path, flavor, pkg, ver = sys.argv[1:5]
name = "api-wreq-node" if flavor == "node" else "api-wreq-bun"
doc = {
  "name": name,
  "version": "1.1.0",
  "type": "module",
  "private": True,
  "dependencies": {
    "wreq-js": f"npm:{pkg}@{ver}",
  },
}
open(path, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
PY

  info "npm install ${LAMBDA_WREQ_NPM_PKG}@${LAMBDA_WREQ_NPM_VER}"
  if ! (
    cd "$build_dir"
    WREQ_JS_SKIP_POSTINSTALL=1 npm install --omit=dev --no-fund --no-audit
  ) >&2; then
    die "npm install 실패"
  fi
  [[ -d "$build_dir/node_modules/wreq-js" ]] || die "node_modules/wreq-js 없음"

  mkdir -p "$build_dir/node_modules/wreq-js/rust"
  rm -f "$build_dir/node_modules/wreq-js/rust/"*.node
  local triple
  triple="$(native_triple)"
  cp -f "$native" "$build_dir/node_modules/wreq-js/rust/wreq-js.${triple}.node"
  info "native: wreq-js.${triple}.node (arch=${LAMBDA_WREQ_ARCH})"

  rm -f "$zip_path"
  ( cd "$build_dir" && zip -qr "$zip_path" . -x "*.map" -x "*darwin*" )
  [[ -f "$zip_path" ]] || die "zip 실패"
  ok "zip: $zip_path ($(du -h "$zip_path" | awk '{print $1}'))"
  printf '%s\n' "$zip_path"
}

create_function() {
  local name="$1" zip="$2" role="$3"
  info "create $name"
  local args=(
    lambda create-function
    --function-name "$name"
    --region "$AWS_REGION"
    --runtime "$LAMBDA_WREQ_RUNTIME"
    --role "$role"
    --handler "$LAMBDA_WREQ_HANDLER"
    --architectures "$LAMBDA_WREQ_ARCH"
    --memory-size "$LAMBDA_WREQ_MEMORY"
    --timeout "$LAMBDA_WREQ_TIMEOUT"
    --ephemeral-storage "Size=$LAMBDA_WREQ_EPHEMERAL"
    --zip-file "fileb://${zip}"
    --description "wreq-js ${LAMBDA_WREQ_FLAVOR} (${LAMBDA_WREQ_NPM_PKG}@${LAMBDA_WREQ_NPM_VER})"
  )
  if [[ "$LAMBDA_WREQ_FLAVOR" == "bun" ]]; then
    [[ -n "$RESOLVED_BUN_LAYER" ]] || die "bun layer 미해결"
    args+=(--layers "$RESOLVED_BUN_LAYER")
  fi
  local i=0
  while [[ "$i" -lt "$LAMBDA_WREQ_WAIT_RETRIES" ]]; do
    if aws "${args[@]}" --output text --query 'FunctionArn' >/dev/null 2>"$OUT_DIR/.create-err"; then
      break
    fi
    if grep -qi 'cannot be assumed' "$OUT_DIR/.create-err" 2>/dev/null; then
      warn "role 전파 대기… ($i)"
      sleep $((3 + i * 2))
      i=$((i + 1))
      continue
    fi
    cat "$OUT_DIR/.create-err" >&2
    die "create-function 실패: $name"
  done
  wait_function_active "$name" || die "function-active 대기 실패: $name"
  record_result "$name" "create" "ok" ""
  ok "created $name"
}

# config 정렬 (node: layers 미변경 / bun: layers 설정)
update_function_config() {
  local name="$1"
  if [[ "$LAMBDA_WREQ_FLAVOR" == "bun" ]]; then
    [[ -n "$RESOLVED_BUN_LAYER" ]] || die "bun layer 미해결 (config)"
    aws lambda update-function-configuration \
      --function-name "$name" --region "$AWS_REGION" \
      --runtime "$LAMBDA_WREQ_RUNTIME" \
      --handler "$LAMBDA_WREQ_HANDLER" \
      --memory-size "$LAMBDA_WREQ_MEMORY" \
      --timeout "$LAMBDA_WREQ_TIMEOUT" \
      --layers "$RESOLVED_BUN_LAYER" \
      --output text --query 'LastUpdateStatus' >/dev/null
  else
    aws lambda update-function-configuration \
      --function-name "$name" --region "$AWS_REGION" \
      --runtime "$LAMBDA_WREQ_RUNTIME" \
      --handler "$LAMBDA_WREQ_HANDLER" \
      --memory-size "$LAMBDA_WREQ_MEMORY" \
      --timeout "$LAMBDA_WREQ_TIMEOUT" \
      --output text --query 'LastUpdateStatus' >/dev/null
  fi
}

# 단일 함수: code → wait → config → wait
deploy_one() {
  local name="$1" zip="$2"
  if ! function_exists "$name"; then
    record_result "$name" "deploy" "skip" "missing"
    echo "SKIP $name"
    return 0
  fi
  if ! aws lambda update-function-code \
      --function-name "$name" --region "$AWS_REGION" \
      --zip-file "fileb://${zip}" \
      --query 'CodeSize' --output text >/dev/null 2>"$OUT_DIR/.dep-err-$name"; then
    local msg
    msg="$(tr '\n' ' ' <"$OUT_DIR/.dep-err-$name" | head -c 200)"
    record_result "$name" "code" "fail" "$msg"
    echo "FAIL $name code: $msg"
    return 0
  fi
  wait_function_updated "$name"
  if ! update_function_config "$name" 2>"$OUT_DIR/.cfg-err-$name"; then
    local msg
    msg="$(tr '\n' ' ' <"$OUT_DIR/.cfg-err-$name" | head -c 200)"
    # conflict 재시도
    sleep 2
    wait_function_updated "$name"
    if ! update_function_config "$name" 2>"$OUT_DIR/.cfg-err-$name"; then
      msg="$(tr '\n' ' ' <"$OUT_DIR/.cfg-err-$name" | head -c 200)"
      record_result "$name" "config" "fail" "$msg"
      echo "FAIL $name config: $msg"
      return 0
    fi
  fi
  wait_function_updated "$name"
  record_result "$name" "deploy" "ok" ""
  echo "OK $name"
  return 0
}

ensure_function_url() {
  local name="$1"
  local url=""
  if url="$(aws lambda get-function-url-config \
      --function-name "$name" --region "$AWS_REGION" \
      --query 'FunctionUrl' --output text 2>/dev/null)" \
    && [[ -n "$url" && "$url" != "None" ]]; then
    printf '%s' "$url"
    return 0
  fi
  info "Function URL: $name"
  if [[ "${LAMBDA_WREQ_URL_CORS}" == "true" ]]; then
    url="$(aws lambda create-function-url-config \
      --function-name "$name" --region "$AWS_REGION" \
      --auth-type "$LAMBDA_WREQ_URL_AUTH" \
      --cors "AllowOrigins=*,AllowMethods=*,AllowHeaders=*" \
      --query 'FunctionUrl' --output text)"
  else
    url="$(aws lambda create-function-url-config \
      --function-name "$name" --region "$AWS_REGION" \
      --auth-type "$LAMBDA_WREQ_URL_AUTH" \
      --query 'FunctionUrl' --output text)"
  fi
  if [[ "$LAMBDA_WREQ_URL_AUTH" == "NONE" ]]; then
    aws lambda add-permission --function-name "$name" --region "$AWS_REGION" \
      --statement-id FunctionURLAllowPublicAccess \
      --action lambda:InvokeFunctionUrl --principal '*' \
      --function-url-auth-type NONE --output text >/dev/null 2>&1 || true
    aws lambda add-permission --function-name "$name" --region "$AWS_REGION" \
      --statement-id FunctionURLAllowInvokeAction \
      --action lambda:InvokeFunction --principal '*' \
      --output text >/dev/null 2>&1 || true
  fi
  printf '%s' "$url"
}

save_urls_json() {
  local jsonl="$1" out_json="$2" out_txt="$3"
  python3 - "$jsonl" "$out_json" "$out_txt" "$AWS_REGION" "$ACCOUNT" "${LAMBDA_WREQ_FLAVOR:-}" "${LAMBDA_WREQ_PREFIX}" <<'PY'
import json, sys, datetime
from pathlib import Path
jsonl, out_json, out_txt, region, account, flavor, prefix = sys.argv[1:8]
items = []
with open(jsonl, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            items.append(json.loads(line))

def sort_key(it):
    n = it["name"]
    if n == prefix:
        return (0, 0)
    p = prefix + "-"
    if n.startswith(p):
        try:
            return (1, int(n[len(p):]))
        except ValueError:
            return (2, n)
    return (3, n)

items.sort(key=sort_key)
functions = {it["name"]: it for it in items}
urls = [it["url"] for it in items if it.get("url")]
doc = {
    "region": region,
    "account": account,
    "flavor": flavor or None,
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "count": len(items),
    "urlCount": len(urls),
    "functions": functions,
    "urls": urls,
}
Path(out_json).write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
with open(out_txt, "w", encoding="utf-8") as f:
    for it in items:
        f.write("%s=%s\n" % (it["name"], it.get("url") or ""))
print("wrote %s (%d urls)" % (out_json, len(urls)), file=sys.stderr)
PY
}

summarize_deploy_results() {
  python3 - "$RESULTS_DIR" "$RESULTS_FILE" <<'PY'
import json, sys
from collections import Counter
from pathlib import Path
rdir, out = Path(sys.argv[1]), Path(sys.argv[2])
# 함수별 최종 상태: fail 우선, 없으면 ok, 없으면 skip
by_name = {}
for p in sorted(rdir.glob("*.json")):
    try:
        o = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        continue
    n = o.get("name")
    st = o.get("status")
    if n not in by_name:
        by_name[n] = o
        continue
    # fail 이 있으면 유지
    if by_name[n].get("status") != "fail" and st == "fail":
        by_name[n] = o
    elif by_name[n].get("status") == "skip" and st == "ok":
        by_name[n] = o
c = Counter()
fails = []
lines = []
for n, o in sorted(by_name.items()):
    st = o.get("status")
    c[st] += 1
    lines.append(json.dumps(o, ensure_ascii=False))
    if st == "fail":
        fails.append("%s [%s] %s" % (n, o.get("stage"), (o.get("msg") or "")[:80]))
out.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
print("ok=%d fail=%d skip=%d" % (c.get("ok", 0), c.get("fail", 0), c.get("skip", 0)))
for x in fails[:30]:
    print("  FAIL", x)
if c.get("fail", 0):
    sys.exit(1)
PY
}
