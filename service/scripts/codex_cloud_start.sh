#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_ROOT="${WATERMARKS_CLOUD_CACHE_DIR:-${REPO_ROOT}/.codex-cloud}"
RUN_DIR="${CACHE_ROOT}/run"
TOOLS_DIR="${CACHE_ROOT}/tools"
LLAMA_TAG="b12469"
MODEL_ALIAS="qwen2.5-1.5b-instruct"
MODEL_FILE="${CACHE_ROOT}/models/qwen2.5-1.5b-instruct-q4_k_m.gguf"
LLAMA_SERVER="${CACHE_ROOT}/llama/${LLAMA_TAG}/llama-server"
LLAMA_URL="http://127.0.0.1:11434"
SERVICE_URL="http://127.0.0.1:8765"
LOCAL_API_KEY="local-watermarks"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

pid_is_live() {
  local pid_file="$1" pid state
  [[ -f "$pid_file" ]] || return 1
  read -r pid < "$pid_file"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
  [[ -n "$state" && "$state" != Z* ]]
}

wait_http() {
  local label="$1" url="$2" auth="$3" log_file="$4" attempts="${5:-120}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if [[ -n "$auth" ]]; then
      if curl -fsS --max-time 2 -H "Authorization: Bearer $auth" "$url" >/dev/null; then
        return 0
      fi
    elif curl -fsS --max-time 2 "$url" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  printf '%s did not become ready; last log lines:\n' "$label" >&2
  tail -n 40 "$log_file" >&2 || true
  return 1
}

port_is_open() {
  local port="$1"
  (exec 9<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
}

[[ -x "$LLAMA_SERVER" ]] || die "run service/scripts/codex_cloud_install.sh first"
[[ -f "$MODEL_FILE" ]] || die "model missing; run codex_cloud_install.sh first"
mkdir -p "$RUN_DIR"

LLAMA_PID_FILE="${RUN_DIR}/llama-server.pid"
LLAMA_LOG="${RUN_DIR}/llama-server.log"
if pid_is_live "$LLAMA_PID_FILE"; then
  wait_http llama-server "${LLAMA_URL}/v1/models" "$LOCAL_API_KEY" "$LLAMA_LOG" 10 || \
    die "recorded llama-server process is alive but unhealthy"
  printf 'llama-server already ready\n'
else
  if port_is_open 11434; then
    die "port 11434 is occupied by an unmanaged service; it was not replaced"
  fi
  nohup "$LLAMA_SERVER" \
    --model "$MODEL_FILE" \
    --alias "$MODEL_ALIAS" \
    --host 127.0.0.1 \
    --port 11434 \
    --api-key "$LOCAL_API_KEY" \
    --ctx-size 4096 \
    --threads -1 \
    --parallel 1 \
    --n-gpu-layers 0 \
    --n-predict 512 \
    >"$LLAMA_LOG" 2>&1 &
  printf '%s\n' "$!" > "$LLAMA_PID_FILE"
  wait_http llama-server "${LLAMA_URL}/v1/models" "$LOCAL_API_KEY" "$LLAMA_LOG" 180 || \
    die "llama-server startup failed"
  printf 'llama-server ready\n'
fi

SERVICE_PID_FILE="${RUN_DIR}/watermarks-service.pid"
SERVICE_LOG="${RUN_DIR}/watermarks-service.log"
if pid_is_live "$SERVICE_PID_FILE"; then
  wait_http watermarks-service "${SERVICE_URL}/health" "" "$SERVICE_LOG" 10 || \
    die "recorded watermarks service is alive but unhealthy"
  printf 'watermarks-remover service already ready\n'
else
  if port_is_open 8765; then
    die "port 8765 is occupied by an unmanaged service; it was not replaced"
  fi
  nohup env \
    "PATH=${TOOLS_DIR}:${PATH}" \
    WATERMARKS_REWRITE_BACKEND=openai-compatible \
    "WATERMARKS_REWRITE_MODEL=${MODEL_ALIAS}" \
    "WATERMARKS_REWRITE_BASE_URL=${LLAMA_URL}" \
    "WATERMARKS_REWRITE_API_KEY=${LOCAL_API_KEY}" \
    WATERMARKS_REWRITE_REASONING_EFFORT=off \
    "WATERMARKS_CLEAN_STRATEGY_FILE=${REPO_ROOT}/config/clean_strategy.codex-cloud.json" \
    python3 "${REPO_ROOT}/service/scripts/server.py" --host 127.0.0.1 --port 8765 \
    >"$SERVICE_LOG" 2>&1 &
  printf '%s\n' "$!" > "$SERVICE_PID_FILE"
  wait_http watermarks-service "${SERVICE_URL}/health" "" "$SERVICE_LOG" 60 || \
    die "watermarks-remover startup failed"
  printf 'watermarks-remover service ready\n'
fi

printf '\nWATERMARKS_SERVICE_URL=%s\n' "$SERVICE_URL"
curl -fsS "${SERVICE_URL}/capabilities"
printf '\n'
