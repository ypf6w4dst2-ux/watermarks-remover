#!/usr/bin/env bash
set -euo pipefail

# Reproducible, user-space setup for a published Codex Cloud environment.
# Downloaded assets stay in the repository cache. Codex stores plugin metadata
# in its configured CODEX_HOME; existing skill installations are preserved.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_ROOT="${WATERMARKS_CLOUD_CACHE_DIR:-${REPO_ROOT}/.codex-cloud}"
DOWNLOAD_DIR="${CACHE_ROOT}/downloads"
TOOLS_DIR="${CACHE_ROOT}/tools"
MODEL_DIR="${CACHE_ROOT}/models"
LLAMA_ROOT="${CACHE_ROOT}/llama"

LLAMA_TAG="b12469"
LLAMA_ARCHIVE="llama-${LLAMA_TAG}-bin-ubuntu-x64.tar.gz"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/${LLAMA_ARCHIVE}"
LLAMA_SHA256="7d33678c3c63544f5586e60b23a815634d633ed27d1e80c801751e201efa63e1"

MODEL_NAME="qwen2.5-1.5b-instruct-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/${MODEL_NAME}"
MODEL_SHA256="6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"

C2PA_VERSION="0.27.15"
C2PA_ARCHIVE="c2patool-v${C2PA_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
C2PA_URL="https://github.com/contentauth/c2pa-rs/releases/download/c2patool-v${C2PA_VERSION}/${C2PA_ARCHIVE}"
C2PA_SHA256="7a035b727a6cdda8ad08d98fe94b3c20febee4aea4e7c1de02571b295730faf0"

PLUGIN_SOURCE="guillaumemeyer/watermarks-remover"
PLUGIN_REF="5a62be6338d2812372b1da440e55c82922f97d53"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

download_checked() {
  local url="$1" dest="$2" expected="$3" actual part
  if [[ -f "$dest" ]]; then
    actual="$(sha256_of "$dest")"
    [[ "$actual" == "$expected" ]] || die "checksum mismatch for existing $dest (preserved)"
    printf 'verified %s\n' "$dest"
    return
  fi
  part="${dest}.part"
  printf 'downloading %s\n' "$url"
  curl --fail --location --retry 5 --retry-all-errors --continue-at - \
    --output "$part" "$url"
  actual="$(sha256_of "$part")"
  [[ "$actual" == "$expected" ]] || die "checksum mismatch for $part (preserved for inspection)"
  mv "$part" "$dest"
  printf 'verified %s\n' "$dest"
}

install_skill_link() {
  local name="$1" target rel
  target="${REPO_ROOT}/.agents/skills/${name}"
  rel="../../skills/${name}"
  [[ -f "${REPO_ROOT}/skills/${name}/SKILL.md" ]] || die "missing source skill: $name"
  if [[ -L "$target" ]]; then
    [[ "$(readlink "$target")" == "$rel" ]] || \
      die "existing skill symlink points elsewhere: $target (preserved)"
    printf 'skill link already present: %s\n' "$name"
  elif [[ -e "$target" ]]; then
    [[ -f "$target/SKILL.md" ]] || die "existing non-skill path: $target (preserved)"
    printf 'existing skill installation preserved: %s\n' "$target"
  else
    ln -s "$rel" "$target"
    printf 'installed project skill link: %s\n' "$name"
  fi
}

install_codex_plugin() {
  command -v codex >/dev/null || return 1
  # The Git marketplace is pinned so later upstream changes cannot silently
  # alter a published environment. No remove operation is issued; Codex may
  # normalize a same-name temporary local source to this pinned Git source.
  if ! codex plugin marketplace add "$PLUGIN_SOURCE" --ref "$PLUGIN_REF" --json; then
    printf 'warning: preserving an existing watermarks-remover marketplace source\n' >&2
  fi
  codex plugin add watermarks-remover@watermarks-remover --json
}

[[ "$(uname -m)" == "x86_64" ]] || die "this pinned Cloud setup currently supports x86_64 only"
command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"
command -v python3 >/dev/null || die "Python 3 is required"

mkdir -p "$DOWNLOAD_DIR" "$TOOLS_DIR" "$MODEL_DIR" "$LLAMA_ROOT" \
  "${REPO_ROOT}/.agents/skills"

if install_codex_plugin; then
  printf 'installed namespaced Codex plugin: watermarks-remover\n'
  # Do not create duplicate project entries, but preserve and validate any
  # project installations that were already present.
  for SKILL_NAME in clean-user-facing-text remove-ai-marks; do
    if [[ -e "${REPO_ROOT}/.agents/skills/${SKILL_NAME}" || \
          -L "${REPO_ROOT}/.agents/skills/${SKILL_NAME}" ]]; then
      install_skill_link "$SKILL_NAME"
    fi
  done
else
  printf 'warning: Codex plugin installation unavailable; using project-skill fallback\n' >&2
  install_skill_link clean-user-facing-text
  install_skill_link remove-ai-marks
fi

LLAMA_DIR="${LLAMA_ROOT}/${LLAMA_TAG}"
LLAMA_SERVER="${LLAMA_DIR}/llama-server"
if [[ ! -x "$LLAMA_SERVER" ]]; then
  [[ ! -e "$LLAMA_DIR" ]] || die "incomplete llama.cpp directory: $LLAMA_DIR (preserved)"
  download_checked "$LLAMA_URL" "${DOWNLOAD_DIR}/${LLAMA_ARCHIVE}" "$LLAMA_SHA256"
  EXTRACT_DIR="$(mktemp -d "${LLAMA_ROOT}/.extract.XXXXXX")"
  trap 'rm -rf -- "$EXTRACT_DIR"' EXIT
  tar -xzf "${DOWNLOAD_DIR}/${LLAMA_ARCHIVE}" -C "$EXTRACT_DIR"
  FOUND_SERVER="$(find "$EXTRACT_DIR" -type f -name llama-server -print -quit)"
  [[ -n "$FOUND_SERVER" ]] || die "llama-server missing from pinned archive"
  FOUND_ROOT="$(dirname "$FOUND_SERVER")"
  mv "$FOUND_ROOT" "$LLAMA_DIR"
  chmod +x "$LLAMA_SERVER"
  trap - EXIT
  rm -rf -- "$EXTRACT_DIR"
fi

download_checked "$MODEL_URL" "${MODEL_DIR}/${MODEL_NAME}" "$MODEL_SHA256"

C2PA_BIN="${TOOLS_DIR}/c2patool-v${C2PA_VERSION}"
if [[ ! -x "$C2PA_BIN" ]]; then
  download_checked "$C2PA_URL" "${DOWNLOAD_DIR}/${C2PA_ARCHIVE}" "$C2PA_SHA256"
  C2PA_TMP="$(mktemp -d "${CACHE_ROOT}/.c2pa.XXXXXX")"
  trap 'rm -rf -- "$C2PA_TMP"' EXIT
  tar -xzf "${DOWNLOAD_DIR}/${C2PA_ARCHIVE}" -C "$C2PA_TMP"
  FOUND_C2PA="$(find "$C2PA_TMP" -type f -name c2patool -print -quit)"
  [[ -n "$FOUND_C2PA" ]] || die "c2patool missing from pinned archive"
  cp "$FOUND_C2PA" "$C2PA_BIN"
  chmod +x "$C2PA_BIN"
  trap - EXIT
  rm -rf -- "$C2PA_TMP"
fi
if [[ ! -e "${TOOLS_DIR}/c2patool" ]]; then
  ln -s "$(basename "$C2PA_BIN")" "${TOOLS_DIR}/c2patool"
elif [[ ! -x "${TOOLS_DIR}/c2patool" ]]; then
  die "existing ${TOOLS_DIR}/c2patool is not executable (preserved)"
fi

printf '\nCodex Cloud assets are ready.\n'
printf '  Codex plugin: watermarks-remover@watermarks-remover\n'
printf '  project-skill fallback: %s\n' "${REPO_ROOT}/.agents/skills"
printf '  llama-server: %s\n' "$LLAMA_SERVER"
printf '  model: %s\n' "${MODEL_DIR}/${MODEL_NAME}"
printf '  c2patool: %s\n' "${TOOLS_DIR}/c2patool"
printf 'Next: bash service/scripts/codex_cloud_start.sh\n'
