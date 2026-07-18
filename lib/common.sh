#!/usr/bin/env bash
# lib/common.sh — shared functions for master.sh / java.sh / python.sh / node.sh
#
# Source this file; do not execute directly.
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Provides:
#   gh_api <url>                  — rate-limited GitHub API GET, returns JSON body
#   latest_tag <clone-url>        — resolve latest stable release tag for a repo
#   clone_one <url> <cat> <name>  — clone/update one repo under $ROOT
#   inject_token <url>            — embed GITHUB_TOKEN in clone URL
#   rl_tick                       — call before every GitHub API request (token bucket)
#   common_env_banner             — print env summary
#
# Required caller env:
#   ROOT          destination root directory
#   DEPTH         shallow clone depth (0 = full)
#   UPDATE        1 = re-clone at latest tag even if dir exists
#   RELEASE_ONLY  1 = skip repos with no release tag
#   GITHUB_TOKEN  (optional but strongly recommended)
#
# Rate-limit strategy — token bucket:
#   GitHub Search:  30 req/min  → RL_SEARCH_RPM (default 25, conservative)
#   GitHub REST:  5000 req/hr   → RL_REST_RPH   (default 4500, conservative)
#   Both buckets tracked separately; rl_tick <bucket> called before each request.
#   On 429/403, parse x-ratelimit-reset and sleep exactly until reset + 2s buffer.
# ─────────────────────────────────────────────────────────────────────────────

# ── guard against double-sourcing ────────────────────────────────────────────
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

set -euo pipefail

# ── auth ─────────────────────────────────────────────────────────────────────
_AUTH_H=()
[[ -n "${GITHUB_TOKEN:-}" ]] && _AUTH_H=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

inject_token() {
  local url="$1"
  if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://github.com/* ]]; then
    echo "https://${GITHUB_TOKEN}@github.com/${url#https://github.com/}"
  else
    echo "$url"
  fi
}

# ── token bucket rate limiter ────────────────────────────────────────────────
# Two buckets: "rest" (5000/hr) and "search" (30/min).
# State kept in plain variables — works in single-process bash.

RL_SEARCH_RPM="${RL_SEARCH_RPM:-25}"   # conservative vs 30 hard limit
RL_REST_RPH="${RL_REST_RPH:-4500}"     # conservative vs 5000 hard limit

# Bucket state (epoch-seconds + count within window)
_RL_REST_WINDOW_START=0
_RL_REST_WINDOW_COUNT=0
_RL_SEARCH_WINDOW_START=0
_RL_SEARCH_WINDOW_COUNT=0

# rl_tick <bucket>  — call before every API request; sleeps if bucket is full
# bucket: "rest" | "search"
rl_tick() {
  local bucket="${1:-rest}"
  local now
  now=$(date +%s)

  if [[ "$bucket" == "search" ]]; then
    local window=60 limit="$RL_SEARCH_RPM"
    local ws="$_RL_SEARCH_WINDOW_START"
    local wc="$_RL_SEARCH_WINDOW_COUNT"
  else
    local window=3600 limit="$RL_REST_RPH"
    local ws="$_RL_REST_WINDOW_START"
    local wc="$_RL_REST_WINDOW_COUNT"
  fi

  # Reset window if expired
  if (( now - ws >= window )); then
    ws=$now
    wc=0
  fi

  # If bucket full, sleep until window resets
  if (( wc >= limit )); then
    local sleep_s=$(( ws + window - now + 1 ))
    (( sleep_s > 0 )) && {
      echo "  ⏳ rate-limit bucket=$bucket full ($wc/$limit) — sleeping ${sleep_s}s" >&2
      sleep "$sleep_s"
      ws=$(date +%s)
      wc=0
    }
  fi

  wc=$(( wc + 1 ))

  if [[ "$bucket" == "search" ]]; then
    _RL_SEARCH_WINDOW_START=$ws
    _RL_SEARCH_WINDOW_COUNT=$wc
  else
    _RL_REST_WINDOW_START=$ws
    _RL_REST_WINDOW_COUNT=$wc
  fi
}

# ── GitHub API fetch with retry-on-429 ───────────────────────────────────────
# gh_api <url> [search]
# Pass "search" as second arg to draw from the search bucket.
# Returns JSON body on stdout; empty on unrecoverable error.
gh_api() {
  local url="$1"
  local bucket="${2:-rest}"

  rl_tick "$bucket"

  local attempt=0 backoff=5
  while (( attempt < 5 )); do
    attempt=$(( attempt + 1 ))

    local tmpfile
    tmpfile=$(mktemp)

    local http_code
    http_code=$(curl -fsSL \
      "${_AUTH_H[@]}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -o "$tmpfile" \
      -w "%{http_code}" \
      "$url" 2>/dev/null || echo "000")

    case "$http_code" in
      200)
        cat "$tmpfile"; rm -f "$tmpfile"; return 0
        ;;
      422)
        # GitHub Search past 1000-result cap — expected, return empty items
        echo '{"items":[],"total_count":0}'; rm -f "$tmpfile"; return 0
        ;;
      403|429)
        rm -f "$tmpfile"
        # Try to read reset time from a headers-only fetch
        local reset
        reset=$(curl -fsI \
          "${_AUTH_H[@]}" \
          "$url" 2>/dev/null \
          | grep -i '^x-ratelimit-reset:' \
          | awk '{print $2}' | tr -d '\r' || echo "")
        local now sleep_s
        now=$(date +%s)
        if [[ -n "$reset" && "$reset" -gt "$now" ]]; then
          sleep_s=$(( reset - now + 2 ))
          echo "  ⏳ HTTP $http_code — reset in ${sleep_s}s (attempt $attempt)" >&2
        else
          sleep_s=$backoff
          echo "  ⏳ HTTP $http_code — backing off ${sleep_s}s (attempt $attempt)" >&2
          backoff=$(( backoff * 2 ))
          (( backoff > 120 )) && backoff=120
        fi
        sleep "$sleep_s"
        rl_tick "$bucket"   # re-acquire token after sleep
        ;;
      000|5*)
        rm -f "$tmpfile"
        echo "  ✗ HTTP $http_code for $url (attempt $attempt)" >&2
        sleep "$backoff"
        backoff=$(( backoff * 2 ))
        ;;
      *)
        rm -f "$tmpfile"
        echo "  ✗ unexpected HTTP $http_code for $url" >&2
        return 0
        ;;
    esac
  done

  echo '{}'; return 0
}

# ── resolve latest stable release tag ────────────────────────────────────────
# latest_tag <clone-url>
# Tries GitHub releases/latest API first, then falls back to ls-remote tag sort.
# Filters out rc/beta/alpha/preview/snapshot/milestone tags.
latest_tag() {
  local url="$1"
  local owner_repo
  owner_repo=$(echo "$url" \
    | sed -E 's|.*github\.com[:/]||; s|\.git$||')

  # 1. GitHub releases/latest API — what maintainers mark as latest
  local rel_json tag=""
  rel_json=$(gh_api "https://api.github.com/repos/${owner_repo}/releases/latest" rest 2>/dev/null || echo '{}')
  tag=$(echo "$rel_json" | python3 -c "
import sys,json
try:
    t=(json.load(sys.stdin).get('tag_name') or '').strip()
    if t and t!='null': print(t)
except: pass
" 2>/dev/null || true)
  tag=$(printf '%s' "${tag:-}" | tr -d '\r\n\t')
  if [[ -n "$tag" && "$tag" != "null" ]]; then echo "$tag"; return 0; fi

  # 2. GitHub tags API — semver sorted via python (handles 3.9.0 > 0.8.2.0)
  tag=$(
    for page in 1 2 3; do
      gh_api "https://api.github.com/repos/${owner_repo}/tags?per_page=100&page=${page}" rest 2>/dev/null || true
    done | python3 -c "
import sys,json,re
PRE=re.compile(r'(rc|alpha|beta|preview|snapshot|\.m[0-9]+|[._-]dev|nightly)',re.I)
VER=re.compile(r'[0-9]+\.[0-9]+')
def key(t): return [int(x) for x in re.findall(r'[0-9]+',t)] or [0]
tags=[]
for line in sys.stdin:
    line=line.strip()
    if not line or line in('[',']',''): continue
    try:
        obj=json.loads(line.rstrip(','))
        n=obj.get('name','') if isinstance(obj,dict) else ''
    except: continue
    if VER.search(n) and not PRE.search(n): tags.append(n)
if tags: print(sorted(tags,key=key)[-1])
" 2>/dev/null || true)
  tag=$(printf '%s' "${tag:-}" | tr -d '\r\n\t')
  if [[ -n "$tag" ]]; then echo "$tag"; return 0; fi

  # 3. git ls-remote — sort -V (version sort), tail -1 = highest version
  # Never use --sort=-v:refname: it sorts ref paths lexicographically,
  # making 0.8.2 beat 3.9.0 in repos without v-prefixed tags.
  tag=$(GIT_TERMINAL_PROMPT=0     git ls-remote --tags --refs     "$(inject_token "$url")" 2>/dev/null     | awk -F'refs/tags/' '/refs\/tags\// {print $2}'     | tr -d '\r'     | grep -E '[0-9]+\.[0-9]+'     | grep -viE '(rc|alpha|beta|preview|snapshot|\.m[0-9]+|[._-]dev|nightly)([._-]|$)'     | sort -V | tail -1 || true)
  printf '%s\n' "$(printf '%s' "${tag:-}" | tr -d '\r\n\t ')"
}

# ── clone / update one repo ───────────────────────────────────────────────────
# clone_one <url> <category> <dir-name> [tag]
# If tag is supplied (pre-resolved by list phase), skips the API call.
clone_one() {
  local url="$1" cat="$2" name="$3" tag="${4:-}"
  local dest="${ROOT}/${cat}/${name}"

  # Resolve tag if not pre-supplied
  if [[ -z "$tag" ]]; then
    tag=$(latest_tag "$url" || true)
  fi

  if [[ -z "$tag" ]]; then
    if [[ "${RELEASE_ONLY:-1}" == "1" ]]; then
      echo "⊘  skip $cat/$name (no release tag)" >&2; return 0
    fi
    echo "⚠  $cat/$name: no release tag — will clone default branch" >&2
  fi

  # ── already exists? ──────────────────────────────────────────────────────
  # Always check if the tag on disk matches the latest resolved tag.
  # Re-clone automatically if stale — no manual UPDATE flag needed.
  if [[ -d "$dest/.git" ]]; then
    if [[ -n "$tag" ]]; then
      local current=""
      current=$(git -C "$dest" describe --tags --exact-match 2>/dev/null || true)
      if [[ "$current" == "$tag" ]]; then
        echo "✓  skip $cat/$name @ $tag (up-to-date)" >&2; return 0
      fi
      # Tag mismatch — always re-clone at latest
      echo "↻  re-clone $cat/$name (${current:-unknown} → $tag)" >&2
      rm -rf "$dest"
    else
      echo "✓  skip $cat/$name (exists, no tag)" >&2; return 0
    fi
  fi

  mkdir -p "${ROOT}/${cat}"

  local -a branch_args=()
  local label="$cat/$name"
  if [[ -n "$tag" ]]; then
    branch_args=(--branch "$tag")
    label="$cat/$name @ $tag"
  fi

  local -a clone_args=()
  [[ "${DEPTH:-0}" -gt 0 ]] && clone_args+=(--depth "${DEPTH}")

  echo "▶  clone $label" >&2

  local errfile
  errfile=$(mktemp)

  if git clone "${clone_args[@]}" "${branch_args[@]}" \
       "$(inject_token "$url")" "$dest" --quiet 2>"$errfile"; then
    rm -f "$errfile"; return 0
  fi

  # Clone failed
  echo "  ✗ clone failed: $url" >&2
  [[ -s "$errfile" ]] && sed 's/^/    /' "$errfile" >&2
  rm -f "$errfile"

  # Retry on default branch if tag-based clone failed
  if [[ ${#branch_args[@]} -gt 0 ]]; then
    echo "  ↻  retry $cat/$name on default branch" >&2
    rm -rf "$dest"
    if git clone "${clone_args[@]}" \
         "$(inject_token "$url")" "$dest" --quiet 2>/dev/null; then
      echo "  ✓  recovered $cat/$name (default branch)" >&2
      return 0
    fi
  fi

  return 1
}

# ── TSV helpers ───────────────────────────────────────────────────────────────
# Bash `read` with IFS=$'\t' treats tab as IFS *whitespace* and therefore
# collapses consecutive tabs — empty columns (e.g. missing release tag) disappear
# and later fields shift left.  Map tabs to a non-whitespace separator first.
#
# read_manifest_row <line>
#   Sets: M_URL M_CAT M_NAME M_TAG M_STATUS
read_manifest_row() {
  local line="$1"
  local sep=$'\x1f'
  local mapped="${line//$'\t'/$sep}"
  # Clear so missing trailing fields don't leak from a previous call
  M_URL="" M_CAT="" M_NAME="" M_TAG="" M_STATUS=""
  IFS="$sep" read -r M_URL M_CAT M_NAME M_TAG M_STATUS _ <<< "${mapped}" || true
}

# ── environment summary ───────────────────────────────────────────────────────
common_env_banner() {
  local script="${1:-}"
  echo "▶ ${script}"
  echo "▶ root:          ${ROOT}"
  echo "▶ depth:         ${DEPTH} (0=full history)"
  echo "▶ release-only:  ${RELEASE_ONLY}"
  echo "▶ update:        ${UPDATE}"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  echo "▶ github-token:  set (${#GITHUB_TOKEN} chars, starts ${GITHUB_TOKEN:0:8}…)"
else
  echo "▶ github-token:  NOT SET — limited to 60 req/hr"
fi
  echo "▶ search-rpm:    ${RL_SEARCH_RPM} (hard limit: 30)"
  echo "▶ rest-rph:      ${RL_REST_RPH}  (hard limit: 5000)"
  echo
}
