#!/usr/bin/env bash
# scale-java.sh — grow the Java OSS corpus to N unique GitHub repos
#
# Uses the GitHub Search API with star/date sharding to work around the
# 1_000-result cap per query. Fully resume-safe and rate-limit aware so you
# can run it overnight or across many sessions.
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#
#   export GITHUB_TOKEN=ghp_xxx          # required (5000 REST/hr, 30 search/min)
#
#   # Grow unique java rows toward 10k (fast — no per-repo tag resolve)
#   ./scale-java.sh --target 10000
#
#   # Resume after interrupt / rate limit (same command is always resume-safe)
#   ./scale-java.sh --target 10000
#
#   # Status only
#   ./scale-java.sh status
#
#   # Optional: fill empty tags for pending java rows (slow, REST API)
#   ./scale-java.sh fill-tags [--limit 500]
#
# Options:
#   --target N        Stop when unique java URLs ≥ N          (default: 10000)
#   --manifest FILE   Manifest path                          (default: manifest.tsv)
#   --min-stars N     Minimum stars                          (default: 50)
#   --min-pushed D    Require pushed_at ≥ date (YYYY-MM-DD)  (default: 2020-01-01)
#                     Use --min-pushed "" to disable
#   --cache DIR       Checkpoint / cache dir                 (default: .discover-cache)
#   --resolve-tags    Resolve latest release tag while discovering (slow)
#   --limit N         Max NEW repos to add this run (0=until target)
#   fill-tags         Subcommand: fill missing tags on existing java rows
#   status            Subcommand: print progress toward target
#   -h|--help
#
# Env:
#   GITHUB_TOKEN      Required
#   RL_SEARCH_RPM     Search bucket size/min (default 25)
#   RL_REST_RPH       REST bucket size/hr    (default 4500)
#
# Checkpoints (safe to delete to re-scan ranges; dedup still via manifest):
#   .discover-cache/java-scale-done.txt   completed search shards
#
# Manifest columns (same as master.sh):
#   url <TAB> category <TAB> dir-name <TAB> tag <TAB> status
#
# After discovery, clone with:
#   ./master.sh clone --java --manifest manifest.tsv --jobs 8 --depth 1
#   # If tags are empty, either run: ./scale-java.sh fill-tags
#   # or: ./master.sh clone --java --no-release-only ...
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh needs these for clone helpers; we only use gh_api / rl_tick
export ROOT="${OSS_CORPUS_ROOT:-${ROOT:-$HOME/oss/corpus}}"
export DEPTH="${OSS_CLONE_DEPTH:-1}"
export UPDATE="${UPDATE:-0}"
export RELEASE_ONLY="${RELEASE_ONLY:-1}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── defaults ─────────────────────────────────────────────────────────────────
MANIFEST="${MANIFEST:-manifest.tsv}"
CACHE_DIR="${CACHE_DIR:-.discover-cache}"
TARGET=10000
MIN_STARS=50
MIN_PUSHED="2020-01-01"
RESOLVE_TAGS=0
RUN_LIMIT=0          # 0 = no per-run cap on newly added
COMMAND="discover"   # discover | fill-tags | status
FILL_LIMIT=0

usage() {
  sed -n '3,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    status)         COMMAND="status"; shift ;;
    fill-tags)      COMMAND="fill-tags"; shift ;;
    discover)       COMMAND="discover"; shift ;;
    --target)       TARGET="$2"; shift 2 ;;
    --manifest)     MANIFEST="$2"; shift 2 ;;
    --min-stars)    MIN_STARS="$2"; shift 2 ;;
    --min-pushed)   MIN_PUSHED="$2"; shift 2 ;;
    --cache)        CACHE_DIR="$2"; shift 2 ;;
    --resolve-tags) RESOLVE_TAGS=1; shift ;;
    --limit)        RUN_LIMIT="$2"; FILL_LIMIT="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) echo "ERROR: unknown option: $1" >&2; usage ;;
  esac
done

[[ -z "${GITHUB_TOKEN:-}" ]] && {
  echo "ERROR: GITHUB_TOKEN not set (needed for GitHub Search + REST)" >&2
  exit 1
}

mkdir -p "$CACHE_DIR"
DONE_FILE="${CACHE_DIR}/java-scale-done.txt"
touch "$DONE_FILE"

# ── helpers ──────────────────────────────────────────────────────────────────

count_java_unique() {
  local f="${1:-$MANIFEST}"
  [[ -f "$f" ]] || { echo 0; return; }
  awk -F'\t' '
    !/^#/ && NF >= 2 && $2 == "java" {
      u = $1
      sub(/\.git$/, "", u)
      print u
    }
  ' "$f" | sort -u | wc -l | tr -d ' '
}

# SEEN set: owner/repo (lowercase path form) for dedup
SEEN_FILE=$(mktemp)
ADDED_THIS_RUN=0
INTERRUPTED=0

load_seen() {
  : > "$SEEN_FILE"
  [[ -f "$MANIFEST" ]] || return 0
  awk -F'\t' '
    !/^#/ && NF >= 1 {
      u = $1
      sub(/^https:\/\/github\.com\//, "", u)
      sub(/\.git$/, "", u)
      if (u != "") print u
    }
  ' "$MANIFEST" | sort -u > "$SEEN_FILE"
}

seen_has() {
  grep -qxF "$1" "$SEEN_FILE" 2>/dev/null
}

mark_seen() {
  echo "$1" >> "$SEEN_FILE"
}

shard_done() {
  grep -qxF "$1" "$DONE_FILE" 2>/dev/null
}

mark_shard_done() {
  local key="$1"
  shard_done "$key" && return 0
  echo "$key" >> "$DONE_FILE"
}

cleanup() {
  local code=$?
  rm -f "$SEEN_FILE"
  if [[ "$COMMAND" == "discover" ]]; then
    local n
    n=$(count_java_unique)
    echo >&2
    echo "──────────────────────────────────────────────────" >&2
    echo "scale-java snapshot:" >&2
    echo "  unique java:  $n / $TARGET" >&2
    echo "  added run:    $ADDED_THIS_RUN" >&2
    echo "  manifest:     $MANIFEST" >&2
    echo "  checkpoints:  $DONE_FILE" >&2
    if [[ "$INTERRUPTED" -eq 1 ]]; then
      echo "  (interrupted — re-run the same command to resume)" >&2
    elif [[ "$n" -ge "$TARGET" ]]; then
      echo "  ✓ target reached" >&2
    else
      echo "  … re-run to continue toward $TARGET" >&2
    fi
    echo "──────────────────────────────────────────────────" >&2
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'INTERRUPTED=1; exit 130' INT TERM

urlencode() {
  # minimal encode for GitHub search q= (space → +)
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=":+-.<>=/@"))' "$1"
}

# latest release tag for a slug (optional path)
resolve_tag() {
  local slug="$1"
  local rel_json tag=""
  rel_json=$(gh_api "https://api.github.com/repos/${slug}/releases/latest" rest 2>/dev/null || echo '{}')
  tag=$(echo "$rel_json" | python3 -c "
import sys,json,re
try:
    t=(json.load(sys.stdin).get('tag_name') or '').strip()
    if t and re.search(r'[0-9]+\\.[0-9]+', t): print(t)
except: pass
" 2>/dev/null || true)
  printf '%s' "${tag//[$'\r\n\t']/}"
}

# Append one repo from a search item (or bare slug)
# args: slug stars pushed_at
emit_java() {
  local slug="$1"
  local stars="${2:-0}"
  local pushed="${3:-}"

  [[ -z "$slug" ]] && return 0
  # normalize
  slug=$(printf '%s' "$slug" | sed 's|^github.com/||; s|\.git$||; s|^https://||; s|^http://||')
  [[ "$slug" != */* ]] && return 0
  [[ "$slug" == */*/* ]] && return 0   # only owner/repo

  if seen_has "$slug"; then
    return 0
  fi

  # quality gates (search usually already filters fork/archived; keep stars/pushed)
  if (( stars + 0 < MIN_STARS )); then
    return 0
  fi
  if [[ -n "$MIN_PUSHED" && -n "$pushed" && "${pushed:0:10}" < "$MIN_PUSHED" ]]; then
    return 0
  fi

  mark_seen "$slug"

  local tag=""
  if [[ "$RESOLVE_TAGS" -eq 1 ]]; then
    tag=$(resolve_tag "$slug" || true)
  fi

  # Unique dir-name: owner-repo (avoids collisions like multiple "apollo")
  local owner repo name
  owner=$(echo "$slug" | cut -d/ -f1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
  repo=$(echo "$slug"  | cut -d/ -f2 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
  name="${owner}-${repo}"

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "https://github.com/${slug}.git" "java" "$name" "${tag:-}" "pending" >> "$MANIFEST"

  ADDED_THIS_RUN=$(( ADDED_THIS_RUN + 1 ))
  local n
  n=$(count_java_unique)
  echo "  + [$n/$TARGET] (+$ADDED_THIS_RUN) $slug${tag:+ @ $tag}  ★$stars" >&2

  # stop conditions
  if [[ "$n" -ge "$TARGET" ]]; then
    return 2
  fi
  if [[ "$RUN_LIMIT" -gt 0 && "$ADDED_THIS_RUN" -ge "$RUN_LIMIT" ]]; then
    return 2
  fi
  return 0
}

# Build search query string (unencoded)
build_q() {
  local stars_lo="$1" stars_hi="$2" date_lo="$3" date_hi="$4"
  local q="language:Java fork:false archived:false"

  if [[ -n "$stars_hi" ]]; then
    q+=" stars:${stars_lo}..${stars_hi}"
  else
    q+=" stars:>=${stars_lo}"
  fi

  if [[ -n "$date_lo" && -n "$date_hi" ]]; then
    q+=" pushed:${date_lo}..${date_hi}"
  elif [[ -n "$date_lo" ]]; then
    q+=" pushed:>=${date_lo}"
  elif [[ -n "$MIN_PUSHED" ]]; then
    q+=" pushed:>=${MIN_PUSHED}"
  fi

  printf '%s' "$q"
}

shard_key() {
  local stars_lo="$1" stars_hi="$2" date_lo="$3" date_hi="$4"
  printf 's:%s-%s|p:%s-%s' \
    "$stars_lo" "${stars_hi:-inf}" \
    "${date_lo:-*}" "${date_hi:-*}"
}

# Return total_count for a query (0 on failure)
search_total() {
  local q="$1"
  local enc body
  enc=$(urlencode "$q")
  body=$(gh_api "https://api.github.com/search/repositories?q=${enc}&per_page=1" search 2>/dev/null || echo '{}')
  echo "$body" | python3 -c "
import sys,json
try:
    print(int(json.load(sys.stdin).get('total_count') or 0))
except Exception:
    print(0)
"
}

# Paginate a query that is known to have total_count ≤ 1000
# Returns 0 ok, 2 if target reached
ingest_query_pages() {
  local q="$1"
  local enc page body rc
  enc=$(urlencode "$q")

  for page in $(seq 1 10); do
    body=$(gh_api "https://api.github.com/search/repositories?q=${enc}&sort=stars&order=desc&per_page=100&page=${page}" search 2>/dev/null || echo '{}')

    local nitems
    nitems=$(echo "$body" | python3 -c "
import sys,json
try:
    print(len(json.load(sys.stdin).get('items') or []))
except Exception:
    print(0)
")
    [[ "$((nitems + 0))" -eq 0 ]] && break

    # stream items: slug \t stars \t pushed
    while IFS=$'\t' read -r slug stars pushed; do
      [[ -z "$slug" ]] && continue
      set +e
      emit_java "$slug" "$stars" "$pushed"
      rc=$?
      set -e
      [[ "$rc" -eq 2 ]] && return 2
    done < <(echo "$body" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in d.get('items') or []:
    if it.get('fork') or it.get('archived'):
        continue
    slug=it.get('full_name') or ''
    stars=it.get('stargazers_count') or 0
    pushed=(it.get('pushed_at') or '')[:10]
    if slug:
        print(f'{slug}\t{stars}\t{pushed}')
")
  done
  return 0
}

# Mid-date between two YYYY-MM-DD (python)
date_mid() {
  python3 -c "
from datetime import datetime, timedelta
a=datetime.strptime('$1','%Y-%m-%d')
b=datetime.strptime('$2','%Y-%m-%d')
mid=a+(b-a)//2
print(mid.strftime('%Y-%m-%d'))
"
}

date_next() {
  python3 -c "
from datetime import datetime, timedelta
print((datetime.strptime('$1','%Y-%m-%d')+timedelta(days=1)).strftime('%Y-%m-%d'))
"
}

today() {
  date -u +%Y-%m-%d
}

# Recursive shard processor
# args: stars_lo stars_hi date_lo date_hi
# stars_hi / date_* may be empty
process_shard() {
  local stars_lo="$1" stars_hi="${2:-}" date_lo="${3:-}" date_hi="${4:-}"
  local key q total rc

  # global stop?
  local n
  n=$(count_java_unique)
  if [[ "$n" -ge "$TARGET" ]]; then
    return 2
  fi
  if [[ "$RUN_LIMIT" -gt 0 && "$ADDED_THIS_RUN" -ge "$RUN_LIMIT" ]]; then
    return 2
  fi

  key=$(shard_key "$stars_lo" "$stars_hi" "$date_lo" "$date_hi")
  if shard_done "$key"; then
    return 0
  fi

  q=$(build_q "$stars_lo" "$stars_hi" "$date_lo" "$date_hi")
  total=$(search_total "$q")
  echo "  ▸ shard $key  total≈$total" >&2

  if [[ "$((total + 0))" -eq 0 ]]; then
    mark_shard_done "$key"
    return 0
  fi

  if [[ "$((total + 0))" -gt 1000 ]]; then
    # Prefer splitting star range when both bounds exist and span > 0
    if [[ -n "$stars_hi" && "$((stars_hi))" -gt "$((stars_lo))" ]]; then
      local mid=$(( (stars_lo + stars_hi) / 2 ))
      if [[ "$mid" -ge "$stars_lo" && "$mid" -lt "$stars_hi" ]]; then
        set +e
        process_shard "$stars_lo" "$mid" "$date_lo" "$date_hi"
        rc=$?
        set -e
        [[ "$rc" -eq 2 ]] && return 2
        set +e
        process_shard "$((mid + 1))" "$stars_hi" "$date_lo" "$date_hi"
        rc=$?
        set -e
        [[ "$rc" -eq 2 ]] && return 2
        mark_shard_done "$key"
        return 0
      fi
    fi

    # Unbounded high stars: split into [lo, 2*lo-1] and [2*lo, inf) when lo>0
    if [[ -z "$stars_hi" && "$((stars_lo))" -gt 0 ]]; then
      # If lo is already huge, fall through to date split
      if [[ "$((stars_lo))" -lt 1000000 ]]; then
        # binary lift: search lo..2lo-1 then >=2lo
        local hi2=$(( stars_lo * 2 - 1 ))
        if [[ "$hi2" -ge "$stars_lo" ]]; then
          set +e
          process_shard "$stars_lo" "$hi2" "$date_lo" "$date_hi"
          rc=$?
          set -e
          [[ "$rc" -eq 2 ]] && return 2
          set +e
          process_shard "$((hi2 + 1))" "" "$date_lo" "$date_hi"
          rc=$?
          set -e
          [[ "$rc" -eq 2 ]] && return 2
          mark_shard_done "$key"
          return 0
        fi
      fi
    fi

    # Date split (pushed)
    local d0 d1
    d0="${date_lo:-$MIN_PUSHED}"
    d1="${date_hi:-$(today)}"
    [[ -z "$d0" ]] && d0="2015-01-01"
    if [[ "$d0" < "$d1" ]]; then
      local mid
      mid=$(date_mid "$d0" "$d1")
      if [[ "$mid" != "$d0" && "$mid" != "$d1" ]]; then
        set +e
        process_shard "$stars_lo" "$stars_hi" "$d0" "$mid"
        rc=$?
        set -e
        [[ "$rc" -eq 2 ]] && return 2
        set +e
        process_shard "$stars_lo" "$stars_hi" "$(date_next "$mid")" "$d1"
        rc=$?
        set -e
        [[ "$rc" -eq 2 ]] && return 2
        mark_shard_done "$key"
        return 0
      fi
    fi

    # Cannot split further — take first 1000 and warn
    echo "  ⚠ cannot split $key further (total=$total) — ingesting first 1000" >&2
  fi

  set +e
  ingest_query_pages "$q"
  rc=$?
  set -e
  if [[ "$rc" -eq 2 ]]; then
    # Only seal the shard if we truly hit the global target (not a per-run --limit).
    n=$(count_java_unique)
    if [[ "$n" -ge "$TARGET" ]]; then
      mark_shard_done "$key"
    fi
    return 2
  fi
  mark_shard_done "$key"
  return 0
}

# ── commands ─────────────────────────────────────────────────────────────────

cmd_status() {
  local n
  n=$(count_java_unique)
  local pending cloned notag failed
  pending=$(awk -F'\t' '!/^#/ && $2=="java" && $5=="pending"{c++} END{print c+0}' "$MANIFEST" 2>/dev/null || echo 0)
  cloned=$(awk -F'\t' '!/^#/ && $2=="java" && $5=="cloned"{c++} END{print c+0}' "$MANIFEST" 2>/dev/null || echo 0)
  notag=$(awk -F'\t' '!/^#/ && $2=="java" && $5=="no-tag"{c++} END{print c+0}' "$MANIFEST" 2>/dev/null || echo 0)
  failed=$(awk -F'\t' '!/^#/ && $2=="java" && $5=="failed"{c++} END{print c+0}' "$MANIFEST" 2>/dev/null || echo 0)
  local shards
  shards=$(grep -cve '^\s*$' "$DONE_FILE" 2>/dev/null || true)
  shards=${shards:-0}

  echo "scale-java status"
  echo "  unique java:   $n / $TARGET  ($(( n * 100 / TARGET ))%)"
  echo "  rows pending:  $pending"
  echo "  rows cloned:   $cloned"
  echo "  rows no-tag:   $notag"
  echo "  rows failed:   $failed"
  echo "  shards done:   $shards"
  echo "  manifest:      $MANIFEST"
  echo "  min-stars:     $MIN_STARS"
  echo "  min-pushed:    ${MIN_PUSHED:-(none)}"
  if [[ "$n" -ge "$TARGET" ]]; then
    echo "  state:         TARGET REACHED"
  else
    echo "  state:         need $(( TARGET - n )) more unique java repos"
  fi
}

cmd_discover() {
  common_env_banner "scale-java.sh discover"

  [[ -f "$MANIFEST" ]] || {
    printf '# scale-java manifest — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MANIFEST"
    printf '# url\tcategory\tdir-name\ttag\tstatus\n' >> "$MANIFEST"
  }

  load_seen
  local start
  start=$(count_java_unique)

  echo "▶ target:        $TARGET unique java"
  echo "▶ current:       $start"
  echo "▶ min-stars:     $MIN_STARS"
  echo "▶ min-pushed:    ${MIN_PUSHED:-(none)}"
  echo "▶ resolve-tags:  $RESOLVE_TAGS"
  echo "▶ run-limit:     ${RUN_LIMIT} (0=until target)"
  echo "▶ manifest:      $MANIFEST"
  echo "▶ checkpoints:   $DONE_FILE"
  echo

  if [[ "$start" -ge "$TARGET" ]]; then
    echo "Already at/above target ($start ≥ $TARGET). Nothing to do."
    return 0
  fi

  # Walk high-star buckets first so the corpus is quality-ordered.
  # Each call is resume-safe via DONE_FILE + manifest SEEN.
  local -a BUCKETS=(
    "5000:"
    "2000:4999"
    "1000:1999"
    "500:999"
    "200:499"
    "100:199"
    "75:99"
    "50:74"
  )

  # If MIN_STARS is not 50, adjust last bucket floor
  local lo hi rc=0
  for b in "${BUCKETS[@]}"; do
    lo="${b%%:*}"
    hi="${b#*:}"
    # skip buckets entirely below min-stars
    if [[ -n "$hi" && "$((hi))" -lt "$((MIN_STARS))" ]]; then
      continue
    fi
    if [[ "$((lo))" -lt "$((MIN_STARS))" ]]; then
      lo="$MIN_STARS"
    fi
    # if unbounded bucket and lo < MIN_STARS, lift
    if [[ -z "$hi" && "$((lo))" -lt "$((MIN_STARS))" ]]; then
      lo="$MIN_STARS"
    fi

    echo "── stars ${lo}${hi:+..$hi} ──" >&2
    set +e
    process_shard "$lo" "$hi" "" ""
    rc=$?
    set -e
    [[ "$rc" -eq 2 ]] && break

    n=$(count_java_unique)
    echo "  progress: $n / $TARGET (added this run: $ADDED_THIS_RUN)" >&2
    [[ "$n" -ge "$TARGET" ]] && break
  done

  # If still short and MIN_STARS < 50, user can re-run with lower --min-stars.
  n=$(count_java_unique)
  if [[ "$n" -lt "$TARGET" && "$MIN_STARS" -gt 10 ]]; then
    echo >&2
    echo "Note: $n/$TARGET with min-stars=$MIN_STARS." >&2
    echo "Re-run with e.g. --min-stars 20 if you need more headroom." >&2
  fi
}

cmd_fill_tags() {
  common_env_banner "scale-java.sh fill-tags"
  [[ -f "$MANIFEST" ]] || { echo "ERROR: no manifest $MANIFEST" >&2; exit 1; }

  local tmp filled=0
  tmp=$(mktemp)
  echo "▶ filling empty tags for java rows (limit=${FILL_LIMIT:-0}, 0=all)" >&2

  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    if [[ "$line" == "#"* || -z "$line" ]]; then
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi
    # Preserve empty tag column (bash IFS=$'\t' collapses consecutive tabs)
    read_manifest_row "$line"
    local url="$M_URL" cat="$M_CAT" name="$M_NAME" tag="$M_TAG" status="$M_STATUS"
    # Only resolve pending java rows with empty tags (skip cloned/no-tag/failed)
    if [[ "$cat" != "java" || -n "${tag:-}" || "$status" != "pending" ]]; then
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi
    if [[ "$FILL_LIMIT" -gt 0 && "$filled" -ge "$FILL_LIMIT" ]]; then
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi

    local slug newtag="" st
    slug=$(echo "$url" | sed -E 's|.*github\.com/||; s|\.git$||')
    echo "  ↻ tag $slug …" >&2
    newtag=$(resolve_tag "$slug" || true)
    if [[ -n "$newtag" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$url" "$cat" "$name" "$newtag" "pending" >> "$tmp"
      echo "    ✓ $newtag" >&2
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$url" "$cat" "$name" "" "no-tag" >> "$tmp"
      echo "    ⊘ no release tag" >&2
    fi
    filled=$(( filled + 1 ))
  done < "$MANIFEST"

  mv "$tmp" "$MANIFEST"
  echo "fill-tags done: processed $filled java rows with empty tags" >&2
}

# ── dispatch ─────────────────────────────────────────────────────────────────
case "$COMMAND" in
  status)    cmd_status ;;
  discover)  cmd_discover ;;
  fill-tags) cmd_fill_tags ;;
  *) echo "ERROR: unknown command $COMMAND" >&2; exit 1 ;;
esac
