#!/usr/bin/env bash
# master.sh — OSS corpus orchestrator for Java, Python, and Node/TypeScript
#
# Two-phase workflow:
#   Phase 1 — LIST:  resolve latest release tags, write a manifest TSV
#   Phase 2 — CLONE: read manifest, clone every repo at its pinned tag
#
# The separation matters: tag resolution hits the GitHub API (rate-limited);
# cloning is pure git traffic.  Run list once, clone as many times as you like.
#
# ─── Usage ────────────────────────────────────────────────────────────────────
#
#   ./master.sh list   [--java] [--python] [--node] [--all] [options]
#   ./master.sh clone  [--java] [--python] [--node] [--all] [options]
#   ./master.sh dump   [--java] [--python] [--node] [--all]
#
# Commands:
#   list    Resolve latest release tags → write manifest (default: manifest.tsv)
#           Does NOT clone.  Safe to re-run (skips already-resolved rows).
#
#   clone   Read manifest → clone / update repos under OSS_CORPUS_ROOT.
#           Tags come from the manifest (no extra API calls during clone).
#           Parallel workers controlled by --jobs.
#
#   dump    Print all repo URLs with their latest release tag to stdout.
#           One line per repo: <url>TAB<tag>  (empty tag = no release found)
#           Useful for piping into other tools or auditing the catalog.
#
# Ecosystem flags (required for list / clone / dump):
#   --java      Include Java repos
#   --python    Include Python repos
#   --node      Include Node / TypeScript repos
#   --all       All three ecosystems
#
# Options:
#   --manifest FILE   TSV manifest path           (default: manifest.tsv)
#   --root DIR        Clone destination root       (default: ~/oss/corpus)
#   --depth N         Shallow clone depth, 0=full  (default: 1)
#   --jobs N          Parallel clone workers        (default: 4)
#   --release-only    Skip repos with no release tag (default: on)
#   --no-release-only Clone default branch if no tag
#   --re-resolve      Re-resolve all tags (pick up newer releases)
#   --update          Re-clone repos at newer tags
#   --category CAT    Filter to one category (e.g. java-large, python-sast)
#   --limit N         Max repos to clone this run, 0=all (default: 0)
#   -h|--help         This help
#
# Env vars:
#   GITHUB_TOKEN      GitHub PAT — 5000 req/hr vs 60 anon.  STRONGLY recommended.
#   OSS_CORPUS_ROOT   Override --root
#   OSS_CLONE_DEPTH   Override --depth
#   RL_SEARCH_RPM     Search API bucket size/min (default 25)
#   RL_REST_RPH       REST API bucket size/hr    (default 4500)
#
# Manifest format (TSV, one repo per line):
#   url <TAB> category <TAB> dir-name <TAB> tag <TAB> status
#   status: pending | cloned | skipped | failed
#
# Examples:
#   # Resolve tags for all Java repos, then clone them with 8 workers
#   export GITHUB_TOKEN=ghp_xxx
#   ./master.sh list  --java --manifest java.tsv
#   ./master.sh clone --java --manifest java.tsv --jobs 8 --depth 1
#
#   # Dump all Python repo URLs + tags to stdout
#   ./master.sh dump --python
#
#   # Clone only the sast category, full history
#   ./master.sh clone --java --category java-sast --depth 0
#
#   # Everything, shallow, 4 workers
#   ./master.sh list  --all
#   ./master.sh clone --all --jobs 4 --depth 1
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail


SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── source shared library ────────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/common.sh"

# ── source catalogs ──────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/java.sh"
source "${SCRIPT_DIR}/python.sh"
source "${SCRIPT_DIR}/node.sh"

# ── defaults ─────────────────────────────────────────────────────────────────
MANIFEST="${MANIFEST:-manifest.tsv}"
ROOT="${OSS_CORPUS_ROOT:-$HOME/oss/corpus}"
DEPTH="${OSS_CLONE_DEPTH:-1}"
JOBS=4
RELEASE_ONLY=1
UPDATE=0
CATEGORY="all"
LIMIT=0   # 0 = no limit
declare -a ECOSYSTEMS=()
COMMAND=""

# ── usage ────────────────────────────────────────────────────────────────────
usage() {
  sed -n '3,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# ── argument parsing ─────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    list|clone|dump) COMMAND="$1"; shift ;;
    --java)          ECOSYSTEMS+=("java");   shift ;;
    --python)        ECOSYSTEMS+=("python"); shift ;;
    --node)          ECOSYSTEMS+=("node");   shift ;;
    --all)           ECOSYSTEMS+=("java" "python" "node"); shift ;;
    --manifest)      MANIFEST="$2";   shift 2 ;;
    --root)          ROOT="$2";       shift 2 ;;
    --depth)         DEPTH="$2";      shift 2 ;;
    --jobs)          JOBS="$2";       shift 2 ;;
    --category)      CATEGORY="$2";   shift 2 ;;
    --release-only)  RELEASE_ONLY=1;  shift ;;
    --no-release-only) RELEASE_ONLY=0; shift ;;
    --limit)         LIMIT="$2";      shift 2 ;;
    --re-resolve)    RE_RESOLVE=1;    shift ;;
    --update)        UPDATE=1;        shift ;;
    -h|--help)       usage ;;
    *) echo "ERROR: unknown option: $1" >&2; usage ;;
  esac
done

# Validate
if [[ -z "$COMMAND" ]]; then
  echo "ERROR: specify a command: list | clone | dump" >&2; usage
fi
if [[ ${#ECOSYSTEMS[@]} -eq 0 ]]; then
  echo "ERROR: specify at least one ecosystem: --java --python --node --all" >&2; usage
fi

# Export for common.sh functions
export ROOT DEPTH RELEASE_ONLY UPDATE

# ── build the active repo list ────────────────────────────────────────────────
# Collects entries from the selected ecosystem arrays, filtered by --category.
# Each element: "<url>  <category>  <dir-name>"
declare -a ACTIVE_REPOS=()

for eco in "${ECOSYSTEMS[@]}"; do
  case "$eco" in
    java)
      for entry in "${JAVA_REPOS[@]}"; do
        read -r url cat name <<< "$entry"
        [[ "$CATEGORY" == "all" || "$CATEGORY" == "$cat" ]] && ACTIVE_REPOS+=("$url	$cat	$name")
      done
      ;;
    python)
      for entry in "${PYTHON_REPOS[@]}"; do
        read -r url cat name <<< "$entry"
        [[ "$CATEGORY" == "all" || "$CATEGORY" == "$cat" ]] && ACTIVE_REPOS+=("$url	$cat	$name")
      done
      ;;
    node)
      for entry in "${NODE_REPOS[@]}"; do
        read -r url cat name <<< "$entry"
        [[ "$CATEGORY" == "all" || "$CATEGORY" == "$cat" ]] && ACTIVE_REPOS+=("$url	$cat	$name")
      done
      ;;
  esac
done

TOTAL_REPOS=${#ACTIVE_REPOS[@]}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: dump
# Print <url><TAB><tag> for every repo in the active set.
# Tag resolution hits the GitHub API — uses the rate limiter.
# ─────────────────────────────────────────────────────────────────────────────
cmd_dump() {
  common_env_banner "master.sh dump"
  echo "▶ repos:         $TOTAL_REPOS"
  echo "▶ ecosystems:    ${ECOSYSTEMS[*]}"
  echo "▶ category:      $CATEGORY"
  echo
  echo "# master.sh dump — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# url	tag"

  local i=0
  for entry in "${ACTIVE_REPOS[@]}"; do
    IFS=$'\t' read -r url cat name <<< "$entry"
    i=$(( i + 1 ))
    local tag
    tag=$(latest_tag "$url" 2>/dev/null || true)
    printf '%s\t%s\n' "$url" "${tag:-}"
    echo "  [$i/$TOTAL_REPOS] $url → ${tag:-(no tag)}" >&2
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: list
# Resolve latest release tag for each repo; write / update manifest.tsv.
# Skips rows already present in the manifest (resume-safe).
# ─────────────────────────────────────────────────────────────────────────────
cmd_list() {
  common_env_banner "master.sh list"
  echo "▶ repos:         $TOTAL_REPOS"
  echo "▶ ecosystems:    ${ECOSYSTEMS[*]}"
  echo "▶ category:      $CATEGORY"
  echo "▶ manifest:      $MANIFEST"
  echo

  # Load already-resolved URLs from existing manifest into a set
  local RESOLVED_FILE
  RESOLVED_FILE=$(mktemp)
  if [[ -f "$MANIFEST" ]]; then
    while IFS=$'\t' read -r url _rest; do
      [[ "$url" == "#"* || -z "$url" ]] && continue
      echo "$url" >> "$RESOLVED_FILE"
    done < "$MANIFEST"
    local _rc; _rc=$(wc -l < "$RESOLVED_FILE" | tr -d ' '); echo "▶ manifest exists: $_rc rows already resolved" >&2
  else
    # Write header
    printf '# master.sh manifest — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MANIFEST"
    printf '# url\tcategory\tdir-name\ttag\tstatus\n' >> "$MANIFEST"
  fi

  local resolved=0 skipped=0 no_tag=0
  local i=0

  for entry in "${ACTIVE_REPOS[@]}"; do
    IFS=$'\t' read -r url cat name <<< "$entry"
    i=$(( i + 1 ))

    # Already in manifest — skip unless --re-resolve
    if grep -qxF "$url" "$RESOLVED_FILE" 2>/dev/null; then
      skipped=$(( skipped + 1 ))
      [[ "${RE_RESOLVE:-0}" != "1" ]] && continue
      echo "  ↻ [$i/$TOTAL_REPOS] re-resolving tag: $name" >&2
    fi

    echo "  ↻ [$i/$TOTAL_REPOS] resolving $name …" >&2
    local tag=""
    tag=$(latest_tag "$url" 2>/dev/null || true)

    if [[ -z "$tag" ]]; then
      no_tag=$(( no_tag + 1 ))
      if [[ "$RELEASE_ONLY" -eq 1 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$url" "$cat" "$name" "" "no-tag" >> "$MANIFEST"
        echo "    ⊘ no release tag — marked no-tag" >&2
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$url" "$cat" "$name" "" "pending" >> "$MANIFEST"
        echo "    ⚠ no tag — will clone default branch" >&2
      fi
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$url" "$cat" "$name" "$tag" "pending" >> "$MANIFEST"
      echo "    ✓ tag: $tag" >&2
    fi

    resolved=$(( resolved + 1 ))
    echo "$url" >> "$RESOLVED_FILE"
  done

  echo
  echo "──────────────────────────────────────────────────"
  echo "list complete:"
  echo "  resolved:  $resolved"
  echo "  skipped:   $skipped (already in manifest)"
  echo "  no-tag:    $no_tag"
  echo "  manifest:  $MANIFEST"
  echo "──────────────────────────────────────────────────"
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND: clone
# Read manifest, clone each pending repo.  Parallel workers via xargs.
# Updates manifest status column after each clone (cloned / failed / skipped).
# ─────────────────────────────────────────────────────────────────────────────

# Worker function — called by xargs in a subshell.
# Args: <url> <category> <dir-name> <tag> <manifest-path> <line-number>
_clone_worker() {
  local url="$1" cat="$2" name="$3" tag="$4" manifest="$5" lineno="$6"

  local status="cloned"
  if clone_one "$url" "$cat" "$name" "$tag" 2>&1; then
    status="cloned"
  else
    status="failed"
  fi

  # Update status in manifest (atomic sed in-place)
  # We target the exact line by number to avoid URL collisions
  local tmpfile
  tmpfile=$(mktemp)
  awk -v n="$lineno" -v st="$status" \
    'NR==n { sub(/\t[^\t]*$/, "\t" st) } { print }' \
    "$manifest" > "$tmpfile" && mv "$tmpfile" "$manifest"
}
export -f _clone_worker clone_one inject_token latest_tag rl_tick gh_api common_env_banner

cmd_clone() {
  common_env_banner "master.sh clone"

  if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: manifest not found: $MANIFEST" >&2
    echo "Run './master.sh list ...' first to generate it." >&2
    exit 1
  fi

  mkdir -p "$ROOT"

  echo "▶ manifest:      $MANIFEST"
  echo "▶ root:          $ROOT"
  echo "▶ depth:         $DEPTH"
  echo "▶ jobs:          $JOBS"
  echo "▶ category:      $CATEGORY"
  echo "▶ limit:         ${LIMIT} (0=all)"
  echo "▶ update:        $UPDATE"
  echo

  # Count what we'll process
  local total_pending
  total_pending=$(grep -E $'\tpending$' "$MANIFEST" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  echo "▶ pending rows:  $total_pending"
  echo

  local cloned=0 failed_count=0 skipped_count=0
  declare -a FAILED_REPOS=()

  # Build work queue directly from manifest.
  # The manifest is the source of truth — no cross-reference with static catalogs.
  # Ecosystem flags (--java/--python/--node) filter by category prefix instead.
  local -a ECO_PREFIXES=()
  for eco in "${ECOSYSTEMS[@]}"; do
    ECO_PREFIXES+=("$eco")   # flat categories: java, python, node
  done

  # Temp file for parallel job args: one line per job
  local jobfile
  jobfile=$(mktemp)

  local lineno=0
  # Read whole lines then split with read_manifest_row — empty tags must not
  # shift the status column (bash IFS=$'\t' collapses consecutive tabs).
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    lineno=$(( lineno + 1 ))
    [[ "$line" == "#"* || -z "$line" ]] && continue
    read_manifest_row "$line"
    local url="$M_URL" cat="$M_CAT" name="$M_NAME" tag="$M_TAG" status="$M_STATUS"
    [[ -z "$url" ]] && continue
    [[ "$status" != "pending" ]] && [[ "$UPDATE" != "1" || "$status" != "cloned" ]] && continue
    [[ "$CATEGORY" != "all" && "$cat" != "$CATEGORY" ]] && continue
    [[ "$RELEASE_ONLY" -eq 1 && -z "$tag" ]] && continue

    # Filter by ecosystem via category prefix
    if [[ ${#ECO_PREFIXES[@]} -gt 0 ]]; then
      local matched=0
      for pfx in "${ECO_PREFIXES[@]}"; do
        [[ "$cat" == ${pfx}* ]] && { matched=1; break; }
      done
      [[ "$matched" -eq 0 ]] && continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$url" "$cat" "$name" "${tag:-}" "$MANIFEST" "$lineno" >> "$jobfile"
  done < "$MANIFEST"

  # Apply --limit: truncate jobfile to first N entries
  if (( LIMIT > 0 )); then
    local tmpjob
    tmpjob=$(mktemp)
    head -"$LIMIT" "$jobfile" > "$tmpjob" && mv "$tmpjob" "$jobfile"
    echo "▶ limit applied: capped at $LIMIT repos" >&2
  fi

  local job_count
  job_count=$(wc -l < "$jobfile" | tr -d ' ')
  echo "▶ queued:        $job_count repos"
  echo

  if [[ "$job_count" -eq 0 ]]; then
    echo "Nothing to clone. Run 'list' first or check --category filter."
    rm -f "$jobfile"
    return 0
  fi

  # Parallel clone semaphore: up to $JOBS concurrent git-clone processes.
  # Each worker updates the manifest status column when it finishes.
  local running=0
  local jline sep=$'\x1f' mapped
  while IFS= read -r jline || [[ -n "${jline:-}" ]]; do
    [[ -z "$jline" ]] && continue
    # Preserve empty tag column in jobfile rows
    mapped="${jline//$'\t'/$sep}"
    IFS="$sep" read -r url cat name tag manifest lineno _ <<< "$mapped" || true
    _clone_worker "$url" "$cat" "$name" "${tag:-}" "$manifest" "$lineno" &
    running=$(( running + 1 ))
    if (( running >= JOBS )); then
      wait -n 2>/dev/null || wait   # wait for any one child to finish
      running=$(( running - 1 ))
    fi
    sleep 0.3   # small stagger — avoids simultaneous TCP bursts to github.com
  done < "$jobfile"
  wait   # drain remaining workers

  rm -f "$jobfile"

  # Re-count final manifest states
  cloned=$(grep -E $'\tcloned$' "$MANIFEST" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  failed_count=$(grep -E $'\tfailed$' "$MANIFEST" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  skipped_count=$(grep -E $'\t(skipped|no-tag)$' "$MANIFEST" 2>/dev/null | wc -l | tr -d ' ' || echo 0)

  echo
  echo "──────────────────────────────────────────────────"
  echo "clone complete:"
  echo "  cloned:   $cloned"
  echo "  failed:   $failed_count"
  echo "  skipped:  $skipped_count"
  if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
    echo "  failed repos:"
    printf '    - %s\n' "${FAILED_REPOS[@]}"
  fi
  echo
  echo "disk usage:"
  du -sh "${ROOT}"/*/  2>/dev/null | sort -h || true
  echo "──────────────────────────────────────────────────"
}

# ─────────────────────────────────────────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────────────────────────────────────────
case "$COMMAND" in
  list)  cmd_list  ;;
  clone) cmd_clone ;;
  dump)  cmd_dump  ;;
  *) echo "ERROR: unknown command: $COMMAND" >&2; exit 1 ;;
esac
