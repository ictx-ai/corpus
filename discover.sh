#!/usr/bin/env bash
# discover.sh — bulk GitHub repo discovery for Java, Python, and Node/TypeScript
#
# Writes directly into a master.sh-compatible manifest TSV so that
# `master.sh clone` can consume it immediately after this runs.
#
# Target: 10 000+ unique repos per ecosystem run.
#
# ─── Discovery sources ────────────────────────────────────────────────────────
#
#  1. GitHub Search API  — language:X tiled by (star-band × pushed-date-window)
#                          Star bands + date windows = disjoint tiles that
#                          together cover the full repo space past the 1000-cap.
#
#  2. GitHub Org crawl   — enumerate repos from ~80 high-signal orgs
#                          (apache, google, spring-projects, Netflix, …)
#
#  3. deps.dev API       — Google Open Source Insights (no auth, no rate limit)
#                          Top 5000 packages by dependent count for each
#                          ecosystem → resolve SCM URL → GitHub slug
#
#  4. Libraries.io API   — (optional, needs LIBRARIES_IO_KEY)
#                          Top packages by SourceRank, gives GitHub URLs directly
#
# ─── Rate-limit strategy ──────────────────────────────────────────────────────
#
#  GitHub Search  : hard 30 req/min → we use 25/min (RL_SEARCH_RPM)
#  GitHub REST    : hard 5000 req/hr → we use 4500/hr (RL_REST_RPH)
#  deps.dev       : no published limit; we add 200ms courtesy sleep
#  Libraries.io   : 60 req/min; we use 50/min
#
#  The tiling strategy (date windows) is critical:
#    - Each query returns ≤1000 results (GitHub hard cap)
#    - Queries within a star band are tiled by pushed: date windows
#    - Date windows are disjoint → no duplicates from tiling itself
#    - We dedup by full_name slug across all sources
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#
#   ./discover.sh [--java] [--python] [--node] [--all] [options]
#
# Ecosystem flags (at least one required):
#   --java       Discover Java / Maven repos
#   --python     Discover Python / PyPI repos
#   --node       Discover Node / npm repos
#   --all        All three
#
# Options:
#   --manifest FILE     Output manifest path (default: manifest.tsv)
#                       Appends to existing manifest; skips already-seen slugs.
#   --cache DIR         Cache dir for raw API responses (default: .discover-cache)
#   --min-stars N       Minimum star count (default: 10)
#   --max-repos N       Stop after N unique repos per ecosystem (default: 15000)
#   --sources LIST      Comma-separated: search,orgs,depsdev,librariesio
#                       (default: search,orgs,depsdev)
#   --no-tag-resolve    Don't resolve latest release tag during discovery.
#                       Leaves tag column empty; master.sh list will fill it.
#   --resume            Re-use cached API responses (skip already-fetched pages)
#   --dry-run           Print queries without calling APIs
#   -h|--help           This help
#
# Required env:
#   GITHUB_TOKEN        PAT — without it you hit 60 req/hr and will stall.
#
# Optional env:
#   LIBRARIES_IO_KEY    libraries.io API key (enables the librariesio source)
#   RL_SEARCH_RPM       Override search bucket (default 25)
#   RL_REST_RPH         Override REST bucket   (default 4500)
#
# Output:
#   Appends to --manifest in master.sh TSV format:
#     url <TAB> category <TAB> dir-name <TAB> tag <TAB> status
#   status is always "pending" (master.sh clone will update it).
#
# Typical pipeline:
#   export GITHUB_TOKEN=ghp_xxx
#   ./discover.sh --java --manifest manifest.tsv
#   ./master.sh clone --java --manifest manifest.tsv --jobs 8 --depth 1
#
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ── defaults ─────────────────────────────────────────────────────────────────
MANIFEST="manifest.tsv"
CACHE_DIR=".discover-cache"
MIN_STARS=10
MAX_REPOS=15000
SOURCES="search,orgs,depsdev"
NO_TAG_RESOLVE=0
RESUME=0
DRY_RUN=0
declare -a ECOSYSTEMS=()

# ── arg parsing ───────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && { sed -n '3,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --java)            ECOSYSTEMS+=("java");   shift ;;
    --python)          ECOSYSTEMS+=("python"); shift ;;
    --node)            ECOSYSTEMS+=("node");   shift ;;
    --all)             ECOSYSTEMS+=("java" "python" "node"); shift ;;
    --manifest)        MANIFEST="$2";          shift 2 ;;
    --cache)           CACHE_DIR="$2";         shift 2 ;;
    --min-stars)       MIN_STARS="$2";         shift 2 ;;
    --max-repos)       MAX_REPOS="$2";         shift 2 ;;
    --sources)         SOURCES="$2";           shift 2 ;;
    --no-tag-resolve)  NO_TAG_RESOLVE=1;       shift ;;
    --resume)          RESUME=1;               shift ;;
    --dry-run)         DRY_RUN=1;              shift ;;
    -h|--help)         sed -n '3,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ${#ECOSYSTEMS[@]} -eq 0 ]]; then
  echo "ERROR: specify at least one ecosystem flag" >&2; exit 1
fi
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "WARNING: GITHUB_TOKEN not set — limited to 60 req/hr, will stall fast" >&2
fi

mkdir -p "$CACHE_DIR"
need() { command -v "$1" >/dev/null 2>&1 || { echo "✗ missing dep: $1" >&2; exit 1; }; }
need curl; need jq; need python3

# ── manifest setup ────────────────────────────────────────────────────────────
# Load existing slugs (owner/repo) from manifest to skip duplicates
declare -A SEEN_SLUGS=()

load_seen() {
  [[ ! -f "$MANIFEST" ]] && return
  while IFS=$'\t' read -r url _rest; do
    [[ "$url" == "#"* || -z "$url" ]] && return
    local slug
    slug=$(echo "$url" | sed -E 's|https://github\.com/||; s|\.git$||')
    SEEN_SLUGS["$slug"]=1
  done < "$MANIFEST"
  echo "▶ manifest: ${#SEEN_SLUGS[@]} existing slugs loaded" >&2
}

# Write manifest header if file doesn't exist
init_manifest() {
  if [[ ! -f "$MANIFEST" ]]; then
    printf '# discover.sh manifest — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MANIFEST"
    printf '# url\tcategory\tdir-name\ttag\tstatus\n' >> "$MANIFEST"
  fi
}

# ── per-ecosystem counters ────────────────────────────────────────────────────
declare -A ECO_COUNT=([java]=0 [python]=0 [node]=0)

# ── emit one repo to manifest ─────────────────────────────────────────────────
# emit <slug> <clone-url> <category> <dir-name> <ecosystem>
emit_repo() {
  local slug="$1" url="$2" cat="$3" name="$4" eco="$5"

  # Already seen?
  [[ -n "${SEEN_SLUGS[$slug]+_}" ]] && return 0
  SEEN_SLUGS["$slug"]=1

  # Per-ecosystem cap
  local count="${ECO_COUNT[$eco]:-0}"
  if (( count >= MAX_REPOS )); then
    return 0
  fi
  ECO_COUNT["$eco"]=$(( count + 1 ))

  # Optionally resolve latest tag (costs one REST API call)
  local tag=""
  if [[ "$NO_TAG_RESOLVE" -eq 0 ]]; then
    tag=$(latest_tag "$url" 2>/dev/null || true)
  fi

  local status="pending"
  printf '%s\t%s\t%s\t%s\t%s\n' "$url" "$cat" "$name" "${tag:-}" "$status" >> "$MANIFEST"
  echo "  + [$eco:${ECO_COUNT[$eco]}] $slug${tag:+ @ $tag}" >&2
}

# ── slug → safe dir name ──────────────────────────────────────────────────────
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# ── cached API page fetch ─────────────────────────────────────────────────────
# Wraps gh_api with a disk cache keyed by URL hash.
# On --resume, returns cached response without hitting API.
cached_gh_api() {
  local url="$1" bucket="${2:-rest}"
  local key
  key=$(printf '%s' "$url" | python3 -c 'import sys,hashlib; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest())')
  local cfile="${CACHE_DIR}/${key}"

  if [[ "$RESUME" -eq 1 && -f "$cfile" ]]; then
    cat "$cfile"; return 0
  fi

  [[ "$DRY_RUN" -eq 1 ]] && { echo '{"items":[],"total_count":0}'; return 0; }

  local body
  body=$(gh_api "$url" "$bucket")
  echo "$body" | tee "$cfile"
}

# ── process a GitHub Search / Repos API JSON object ─────────────────────────
# process_gh_repo <json-object> <ecosystem>
process_gh_repo() {
  local json="$1" eco="$2"

  local full_name
  full_name=$(echo "$json" | jq -r '.full_name // empty')
  [[ -z "$full_name" ]] && return 0

  # Skip forks
  local is_fork
  is_fork=$(echo "$json" | jq -r '.fork // false')
  [[ "$is_fork" == "true" ]] && return 0

  local stars
  stars=$(echo "$json" | jq -r '.stargazers_count // 0')
  (( stars < MIN_STARS )) && return 0

  local clone_url name desc topics
  clone_url=$(echo "$json" | jq -r '.clone_url // empty')
  name=$(echo "$json" | jq -r '.name // empty')
  desc=$(echo "$json" | jq -r '.description // ""')
  topics=$(echo "$json" | jq -r '[.topics // [] | .[]] | join(" ")')

  [[ -z "$clone_url" || -z "$name" ]] && return 0

  local cat dir_name
  cat=$(infer_category "$eco" "$name" "$desc" "$topics" "$stars")
  dir_name=$(slugify "$name")

  emit_repo "$full_name" "$clone_url" "$cat" "$dir_name" "$eco"
}

# ── category inference ────────────────────────────────────────────────────────
infer_category() {
  local eco="$1" name="$2" desc="$3" topics="$4" stars="$5"
  local combined
  combined=$(echo "$name $desc $topics" | tr '[:upper:]' '[:lower:]')

  _m() { echo "$combined" | grep -qiE "$1"; }

  case "$eco" in
  java)
    _m 'vulnerable|webgoat|dvwa|benchmark.*java|javulna|goatlin|vulnado|juice.?shop' \
      && echo "java-sast" && return
    _m 'android|butterknife|lottie|arouter|tinker|fresco|glide|picasso' \
      && echo "java-android" && return
    _m 'spring.?cloud|microservice|gateway|eureka|ribbon|feign|nacos|sentinel' \
      && echo "spring-cloud" && return
    _m 'spring.?boot|spring.?mvc|spring.?data|spring.?security|jhipster' \
      && { (( stars > 3000 )) && echo "spring-prod" || echo "spring-demo"; } && return
    _m 'kafka|elasticsearch|cassandra|hadoop|spark|flink|druid|pulsar|hive|hbase|trino|presto|zookeeper|jenkins|wildfly|tomcat|netty|dubbo|rocketmq' \
      && echo "java-large" && return
    _m 'jwt|oauth|crypto|tls|ssl|security|auth|keycloak|shiro|cas|saml|ldap' \
      && echo "java-security" && return
    _m 'mybatis|hibernate|jooq|jdbc|flyway|liquibase|jackson|gson|avro|parquet|lucene|h2|redis|cache' \
      && echo "java-data" && return
    _m 'quarkus|micronaut|helidon|undertow|activemq|resilience|circuit|grpc|vertx' \
      && echo "java-infra" && return
    _m 'checkstyle|pmd|spotbugs|jacoco|junit|mockito|assertj|testcontainer|lombok|gradle|maven|byte.?buddy|javassist|javaparser|annotation' \
      && echo "java-tools" && return
    (( stars >= 2000 )) && echo "java-large" || echo "java-medium"
    ;;
  python)
    _m 'vulnerable|vulpy|pygoat|dvwa|vulnpy|vampi' \
      && echo "python-sast" && return
    _m 'jwt|oauth|crypto|tls|ssl|security|auth|bcrypt|oauthlib|bleach|sanitiz' \
      && echo "python-security" && return
    _m 'pytorch|tensorflow|keras|sklearn|scikit|xgboost|lightgbm|mlflow|ray|dask|polars|duckdb|numpy|pandas|scipy|matplotlib|plotly' \
      && echo "python-data" && return
    _m 'django|flask|fastapi|starlette|tornado|aiohttp|uvicorn|gunicorn|falcon|pyramid|bottle|saleor|wagtail|zulip|netbox|posthog' \
      && echo "python-web" && return
    _m 'black|ruff|flake8|pylint|mypy|bandit|isort|pytest|tox|coverage|pre.?commit|setuptools|poetry|pip|hatch|typeshed' \
      && echo "python-tools" && return
    (( stars >= 5000 )) && echo "python-large" || echo "python-medium"
    ;;
  node)
    _m 'vulnerable|juice.?shop|nodegoat|dvna|goof|vulner' \
      && echo "node-sast" && return
    _m 'jwt|oauth|passport|bcrypt|helmet|cors|csp|security|auth|crypto|jose' \
      && echo "node-security" && return
    _m 'react|vue|angular|svelte|solid|next|nuxt|remix|gatsby|astro|vite|webpack|rollup|parcel|esbuild|babel' \
      && echo "node-large" && return
    _m 'express|fastify|koa|hapi|nest|trpc|graphql|apollo|prisma|sequelize|typeorm|mikro' \
      && echo "node-medium" && return
    _m 'eslint|prettier|typescript|jest|mocha|vitest|chalk|commander|yargs|winston|pino|debug|glob|dotenv' \
      && echo "node-tools" && return
    (( stars >= 5000 )) && echo "node-large" || echo "node-medium"
    ;;
  esac
  echo "${eco}-medium"
}

# ═════════════════════════════════════════════════════════════════════════════
# SOURCE 1: GitHub Search API — tiled by star-band × pushed-date-window
# ═════════════════════════════════════════════════════════════════════════════
#
# Tiling strategy:
#   Outer: star bands (disjoint ranges).  We stop pages early if results < 100.
#   Inner: pushed-date windows within dense bands (>1000 results per band).
#         Date windows are disjoint → no cross-tile duplication.
#   Language qualifier maps ecosystem → GitHub language name.
#
# Why date windows and not just topic tiles?
#   Topics are sparse — most repos don't set them.
#   Pushed dates cover 100% of repos and are truly disjoint,
#   so each window contributes unique repos.

source_search() {
  local eco="$1"
  local lang
  case "$eco" in
    java)   lang="Java" ;;
    python) lang="Python" ;;
    node)   lang="TypeScript JavaScript" ;;   # search twice
  esac

  echo "── search:$eco ──" >&2

  # Star bands — ordered highest-value first
  local -a BANDS=(
    "stars:>50000"
    "stars:20000..50000"
    "stars:10000..19999"
    "stars:5000..9999"
    "stars:2000..4999"
    "stars:1000..1999"
    "stars:500..999"
    "stars:200..499"
    "stars:100..199"
    "stars:50..99"
    "stars:25..49"
    "stars:${MIN_STARS}..24"
  )

  # Pushed-date windows — used to tile within dense bands (>1000 results).
  # 6-month windows from 2015 → now.  Disjoint, full coverage.
  # We generate them inline with python3.
  local -a DATE_WINDOWS
  mapfile -t DATE_WINDOWS < <(python3 - "$MIN_STARS" <<'PYEOF'
import sys
from datetime import date, timedelta

# 6-month (roughly) windows from Jan 2015 to today
starts = []
d = date(2015, 1, 1)
today = date.today()
while d < today:
    starts.append(d)
    # advance ~6 months
    m = d.month + 6
    y = d.year + (m - 1) // 12
    m = ((m - 1) % 12) + 1
    d = date(y, m, 1)

for i, s in enumerate(starts):
    e = starts[i+1] - timedelta(days=1) if i+1 < len(starts) else today
    print(f"pushed:{s.isoformat()}..{e.isoformat()}")
PYEOF
  )

  # For node we search TypeScript and JavaScript separately
  local -a LANGS=("$lang")
  [[ "$eco" == "node" ]] && LANGS=("TypeScript" "JavaScript")

  for search_lang in "${LANGS[@]}"; do
    for band in "${BANDS[@]}"; do

      (( ECO_COUNT["$eco"] >= MAX_REPOS )) && return 0

      # Quick first page to check total_count
      local q="language:${search_lang}+${band}+fork:false"
      q="${q// /+}"
      local base_url="https://api.github.com/search/repositories?q=${q}&sort=stars&order=desc&per_page=100"

      local first_page
      first_page=$(cached_gh_api "${base_url}&page=1" "search")
      local total
      total=$(echo "$first_page" | jq -r '.total_count // 0')

      echo "    search lang=$search_lang $band → total=$total" >&2

      if (( total == 0 )); then continue; fi

      if (( total <= 1000 )); then
        # ── Simple case: fits within GitHub's 1000-result cap ─────────────
        # Process page 1 we already fetched, then get remaining pages
        while IFS= read -r repo_json; do
          process_gh_repo "$repo_json" "$eco"
        done < <(echo "$first_page" | jq -c '.items[]? // empty')

        local max_page=$(( (total + 99) / 100 ))
        (( max_page > 10 )) && max_page=10

        for page in $(seq 2 "$max_page"); do
          (( ECO_COUNT["$eco"] >= MAX_REPOS )) && break
          local resp
          resp=$(cached_gh_api "${base_url}&page=${page}" "search")
          local cnt
          cnt=$(echo "$resp" | jq '.items | length')
          (( cnt == 0 )) && break
          while IFS= read -r repo_json; do
            process_gh_repo "$repo_json" "$eco"
          done < <(echo "$resp" | jq -c '.items[]? // empty')
        done

      else
        # ── Dense band: tile by pushed-date windows ───────────────────────
        echo "    → dense ($total > 1000): tiling by pushed-date" >&2
        for window in "${DATE_WINDOWS[@]}"; do
          (( ECO_COUNT["$eco"] >= MAX_REPOS )) && break

          local wq="${q}+${window}"
          local wurl="https://api.github.com/search/repositories?q=${wq}&sort=stars&order=desc&per_page=100"

          for page in 1 2 3 4 5 6 7 8 9 10; do
            (( ECO_COUNT["$eco"] >= MAX_REPOS )) && break
            local wresp
            wresp=$(cached_gh_api "${wurl}&page=${page}" "search")
            local wcnt
            wcnt=$(echo "$wresp" | jq '.items | length // 0')
            (( wcnt == 0 )) && break
            while IFS= read -r repo_json; do
              process_gh_repo "$repo_json" "$eco"
            done < <(echo "$wresp" | jq -c '.items[]? // empty')
            (( wcnt < 100 )) && break   # last page of this window
          done
        done
      fi

    done   # band
  done   # lang
}

# ═════════════════════════════════════════════════════════════════════════════
# SOURCE 2: GitHub Org crawl
# ═════════════════════════════════════════════════════════════════════════════
# Enumerate repos from high-signal orgs per ecosystem.
# Uses the /orgs/:org/repos endpoint — no search quota consumed.

declare -A ORG_SETS

ORG_SETS[java]="
  apache spring-projects spring-cloud spring-attic spring-petclinic
  netflix alibaba google square reactivex eclipse eclipse-vertx
  quarkusio micronaut-projects helidon-io undertow-io asynchttpclient
  fasterxml mybatis baomidou hibernate liquibase flyway resilience4j
  ben-manes lettuce-io redisson grpc netty jooq checkstyle pmd spotbugs
  jacoco junit-team mockito assertj testcontainers typetools javaparser
  raphw rzwitserloot mapstruct immutables openfeign pac4j auth0 keycloak
  conscrypt dromara macrozheng YunaiV pig-mesh halo-dev jeecgboot
  trinodb prestodb opensearch-project jenkinsci wildfly OpenAPITools
  dropwizard graphql-java zaproxy WebGoat OWASP OWASP-Benchmark
  bumptech dagger hazelcast apache-skywalking pinpoint-apm
  micrometer-metrics open-telemetry openzipkin questdb orientdb neo4j
"

ORG_SETS[python]="
  django pallets fastapi-users encode tiangolo pydantic
  numpy pandas-dev scipy matplotlib psf pypa astral-sh
  ansible apache celery redis redis-py sqlalchemy aio-libs
  huggingface scikit-learn pytest-dev python python-poetry
  scrapy getsentry apache streamlit
  saleor zulip readthedocs django-cms posthog netbox-community
  pytorch tensorflow google ray-project dask-array pola-rs duckdb
  PyCQA pyca pyupio trailofbits semgrep pre-commit
  pallets-eco jazzband pennersr cookiecutter
"

ORG_SETS[node]="
  nodejs expressjs nestjs facebook vuejs angular webpack vitejs
  eslint prettier axios socketio typescript-eslint mochajs jestjs
  vercel nuxt microsoft denoland evanw rollup parcel-bundler
  babel graphql apollographql trpc colinhacks fastify koajs
  hapijs remix-run gatsbyjs sveltejs reduxjs date-fns TypeStrong
  pmndrs TanStack payloadcms strapi sequelize prisma typeorm
  mikro-orm keystonejs directus hasura withastro solidjs preactjs
  alpinejs mobxjs immerjs auth0 panva jaredhanson kelektiv
  helmetjs expressjs jaredhanson websockets yargs winstonjs pinojs
  knex brianc tj sindresorhus pnpm
"

source_orgs() {
  local eco="$1"
  echo "── orgs:$eco ──" >&2

  # Read the org list, split on whitespace
  local orgs_raw="${ORG_SETS[$eco]}"
  local -a orgs=()
  read -ra orgs <<< "$orgs_raw"

  local lang_filter
  case "$eco" in
    java)   lang_filter="Java" ;;
    python) lang_filter="Python" ;;
    node)   lang_filter="" ;;   # accept JS + TS
  esac

  for org in "${orgs[@]}"; do
    [[ -z "$org" ]] && continue
    (( ECO_COUNT["$eco"] >= MAX_REPOS )) && return 0
    echo "  org: $org" >&2

    for page in 1 2 3 4 5; do
      (( ECO_COUNT["$eco"] >= MAX_REPOS )) && break
      local url="https://api.github.com/orgs/${org}/repos?type=public&sort=pushed&per_page=100&page=${page}"
      local resp
      resp=$(cached_gh_api "$url" "rest") || continue

      local cnt
      cnt=$(echo "$resp" | jq 'length // 0')
      (( cnt == 0 )) && break

      while IFS= read -r repo_json; do
        # Language filter
        if [[ -n "$lang_filter" ]]; then
          local rl
          rl=$(echo "$repo_json" | jq -r '.language // ""')
          [[ "$rl" != "$lang_filter" ]] && continue
        else
          # Node: accept JavaScript or TypeScript only
          local rl
          rl=$(echo "$repo_json" | jq -r '.language // ""')
          [[ "$rl" != "JavaScript" && "$rl" != "TypeScript" ]] && continue
        fi
        process_gh_repo "$repo_json" "$eco"
      done < <(echo "$resp" | jq -c '.[]? // empty')

      (( cnt < 100 )) && break
    done
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# SOURCE 3: deps.dev (Google Open Source Insights)
# ═════════════════════════════════════════════════════════════════════════════
# No authentication required. Returns dependency metadata including source repo URLs.
# API: https://api.deps.dev/v3alpha/systems/{system}/packages/{package}
#
# Strategy: query the "top packages" via the BigQuery-derived CSV snapshots
# that deps.dev publishes, then resolve each package's GitHub URL.
# We use the deps.dev package search endpoint which returns up to 1000 results
# per query for a given system (maven/pypi/npm).

source_depsdev() {
  local eco="$1"
  echo "── deps.dev:$eco ──" >&2

  local system
  case "$eco" in
    java)   system="maven" ;;
    python) system="pypi" ;;
    node)   system="npm" ;;
  esac

  # deps.dev search: GET /v3alpha/query?versionKey.system=MAVEN&query=...
  # We page through packages sorted by dependent count using a series of
  # prefix queries across the alphabet to get broad coverage.
  #
  # Better: use the deps.dev package page API with known popular prefixes.
  # For maven: group IDs.  For pypi/npm: name prefixes.

  local -a PREFIXES=()
  case "$eco" in
    java)
      # Maven groupId prefixes that cover most of the ecosystem
      PREFIXES=(
        "org.springframework" "org.apache" "com.google" "com.fasterxml"
        "io.netty" "io.grpc" "io.vertx" "io.micronaut" "io.quarkus"
        "org.hibernate" "org.mybatis" "com.baomidou" "org.flywaydb"
        "org.liquibase" "org.jooq" "com.zaxxer" "io.lettuce"
        "org.redisson" "io.github.resilience4j" "org.projectlombok"
        "org.mapstruct" "org.mockito" "org.junit" "org.assertj"
        "org.testcontainers" "net.bytebuddy" "org.ow2.asm" "org.javassist"
        "org.apache.maven" "com.squareup" "io.reactivex"
        "org.apache.kafka" "org.apache.flink" "org.apache.spark"
        "org.apache.hadoop" "org.apache.cassandra" "org.elasticsearch"
        "org.keycloak" "org.pac4j" "com.auth0" "io.jsonwebtoken"
        "org.bouncycastle" "com.nimbusds" "io.micrometer"
        "io.opentelemetry" "io.zipkin" "org.slf4j" "ch.qos.logback"
        "com.netflix" "org.eclipse" "org.apache.commons"
        "com.alibaba" "io.seata" "org.apache.dubbo"
      )
      ;;
    python)
      # PyPI name prefixes (A-Z + common frameworks)
      PREFIXES=(
        "django" "flask" "fastapi" "sqlalchemy" "celery" "pytest"
        "requests" "numpy" "pandas" "scipy" "matplotlib" "torch"
        "tensorflow" "keras" "sklearn" "transformers" "pydantic"
        "aiohttp" "starlette" "uvicorn" "gunicorn" "tornado"
        "cryptography" "paramiko" "boto" "google" "azure" "aws"
        "redis" "pymongo" "psycopg" "aiomysql" "asyncpg"
        "click" "typer" "rich" "loguru" "structlog"
        "black" "ruff" "flake8" "pylint" "mypy" "bandit"
        "poetry" "setuptools" "wheel" "pip" "hatch"
        "arrow" "pendulum" "dateutil" "pyyaml" "toml"
        "pillow" "opencv" "imageio" "scrapy" "httpx"
        "alembic" "migrate" "peewee" "tortoise" "piccolo"
      )
      ;;
    node)
      # npm package prefixes
      PREFIXES=(
        "react" "vue" "angular" "@angular" "svelte" "solid"
        "next" "nuxt" "gatsby" "astro" "remix" "vite"
        "express" "fastify" "koa" "hapi" "nest" "@nestjs"
        "webpack" "rollup" "esbuild" "parcel" "babel" "@babel"
        "eslint" "prettier" "typescript" "ts-" "jest" "mocha"
        "axios" "got" "node-fetch" "superagent" "ky"
        "lodash" "ramda" "underscore" "rxjs" "immer"
        "prisma" "@prisma" "sequelize" "typeorm" "mikro-orm"
        "socket.io" "ws" "uws" "mqtt"
        "redis" "ioredis" "mongoose" "mongodb" "pg"
        "passport" "jsonwebtoken" "bcrypt" "helmet" "cors"
        "chalk" "commander" "yargs" "inquirer" "ora"
        "winston" "pino" "debug" "morgan"
        "dotenv" "config" "convict" "nconf"
        "@types" "zod" "joi" "yup" "ajv"
        "graphql" "@apollo" "type-graphql" "pothos"
        "redux" "zustand" "jotai" "mobx" "recoil"
        "date-fns" "dayjs" "moment" "luxon"
        "uuid" "nanoid" "cuid" "ulid"
      )
      ;;
  esac

  for prefix in "${PREFIXES[@]}"; do
    (( ECO_COUNT["$eco"] >= MAX_REPOS )) && return 0

    [[ "$DRY_RUN" -eq 1 ]] && { echo "DRY-RUN deps.dev $system $prefix" >&2; continue; }

    local cache_key="${CACHE_DIR}/depsdev_${system}_$(echo "$prefix" | tr '/:@' '___')"

    local resp=""
    if [[ "$RESUME" -eq 1 && -f "$cache_key" ]]; then
      resp=$(cat "$cache_key")
    else
      # deps.dev query endpoint
      local enc_prefix
      enc_prefix=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$prefix")
      local durl="https://api.deps.dev/v3alpha/query?versionKey.system=$(echo "$system" | tr '[:lower:]' '[:upper:]')&query=${enc_prefix}"
      resp=$(curl -fsSL --max-time 15 "$durl" 2>/dev/null || echo '{}')
      echo "$resp" > "$cache_key"
      sleep 0.2   # courtesy delay — no published rate limit but be nice
    fi

    # deps.dev returns { results: [ { version: { versionKey: {...}, links: [{label,url}] } } ] }
    # Extract GitHub URLs from the links array
    local -a github_urls
    mapfile -t github_urls < <(echo "$resp" | python3 - <<'PYEOF'
import sys, json, re
try:
    data = json.load(sys.stdin)
    seen = set()
    for r in data.get('results', []):
        for link in r.get('version', {}).get('links', []):
            url = link.get('url', '')
            m = re.search(r'github\.com[:/]([^/\s]+/[^/\s.]+?)(?:\.git)?(?:\s|$|/|#)', url)
            if m:
                slug = m.group(1).rstrip('/')
                if slug not in seen:
                    seen.add(slug)
                    print(f'https://github.com/{slug}.git\t{slug}')
except Exception:
    pass
PYEOF
    )

    for line in "${github_urls[@]}"; do
      (( ECO_COUNT["$eco"] >= MAX_REPOS )) && break
      IFS=$'\t' read -r clone_url slug <<< "$line"
      [[ -z "$slug" ]] && continue
      [[ -n "${SEEN_SLUGS[$slug]+_}" ]] && continue

      # Fetch repo metadata to get stars, language, topics
      local meta
      meta=$(gh_api "https://api.github.com/repos/${slug}" "rest" 2>/dev/null || echo '{}')
      local stars lang_api
      stars=$(echo "$meta" | jq -r '.stargazers_count // 0')
      lang_api=$(echo "$meta" | jq -r '.language // ""')
      (( stars < MIN_STARS )) && continue

      # Language filter
      case "$eco" in
        java)   [[ "$lang_api" != "Java" && "$lang_api" != "Kotlin" ]] && continue ;;
        python) [[ "$lang_api" != "Python" ]] && continue ;;
        node)   [[ "$lang_api" != "JavaScript" && "$lang_api" != "TypeScript" ]] && continue ;;
      esac

      process_gh_repo "$meta" "$eco"
    done
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# SOURCE 4: Libraries.io (optional — requires LIBRARIES_IO_KEY)
# ═════════════════════════════════════════════════════════════════════════════
source_librariesio() {
  local eco="$1"
  [[ -z "${LIBRARIES_IO_KEY:-}" ]] && {
    echo "  skip librariesio: LIBRARIES_IO_KEY not set" >&2; return 0
  }
  echo "── libraries.io:$eco ──" >&2

  local platform
  case "$eco" in
    java)   platform="Maven" ;;
    python) platform="PyPI" ;;
    node)   platform="NPM" ;;
  esac

  # Libraries.io projects sorted by SourceRank — gives GitHub repo_url directly
  local -a LIO_RPM_BUCKET=(0)   # simple counter for 60/min rate limit
  local LIO_WINDOW_START
  LIO_WINDOW_START=$(date +%s)

  for page in $(seq 1 50); do
    (( ECO_COUNT["$eco"] >= MAX_REPOS )) && return 0

    # Rate limit: 50 req/min
    local now
    now=$(date +%s)
    local elapsed=$(( now - LIO_WINDOW_START ))
    if (( ${#LIO_RPM_BUCKET[@]} >= 50 && elapsed < 60 )); then
      local wsleep=$(( 61 - elapsed ))
      echo "  librariesio: rate-limit sleep ${wsleep}s" >&2
      sleep "$wsleep"
      LIO_WINDOW_START=$(date +%s)
      LIO_RPM_BUCKET=()
    fi
    LIO_RPM_BUCKET+=("$now")

    local cache_key="${CACHE_DIR}/lio_${platform}_${page}"
    local resp=""
    if [[ "$RESUME" -eq 1 && -f "$cache_key" ]]; then
      resp=$(cat "$cache_key")
    else
      [[ "$DRY_RUN" -eq 1 ]] && continue
      local lurl="https://libraries.io/api/search?platforms=${platform}&sort=rank&per_page=100&page=${page}&api_key=${LIBRARIES_IO_KEY}"
      resp=$(curl -fsSL --max-time 20 "$lurl" 2>/dev/null || echo '[]')
      echo "$resp" > "$cache_key"
    fi

    local count
    count=$(echo "$resp" | jq 'length // 0')
    (( count == 0 )) && break

    # Each result has a repository_url field
    while IFS= read -r item; do
      (( ECO_COUNT["$eco"] >= MAX_REPOS )) && break
      local repo_url
      repo_url=$(echo "$item" | jq -r '.repository_url // empty')
      [[ "$repo_url" != *github.com* ]] && continue

      local slug
      slug=$(echo "$repo_url" | sed -E 's|https?://github\.com/||; s|\.git$||; s|/$||')
      [[ -z "$slug" || "$slug" == *" "* ]] && continue
      [[ -n "${SEEN_SLUGS[$slug]+_}" ]] && continue

      local meta
      meta=$(gh_api "https://api.github.com/repos/${slug}" "rest" 2>/dev/null || echo '{}')
      local stars
      stars=$(echo "$meta" | jq -r '.stargazers_count // 0')
      (( stars < MIN_STARS )) && continue

      process_gh_repo "$meta" "$eco"
    done < <(echo "$resp" | jq -c '.[]? // empty')
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

# Split sources string into array
IFS=',' read -ra SOURCE_LIST <<< "$SOURCES"

init_manifest
load_seen

echo "▶ discover.sh"
echo "▶ ecosystems:    ${ECOSYSTEMS[*]}"
echo "▶ manifest:      $MANIFEST"
echo "▶ cache:         $CACHE_DIR"
echo "▶ min-stars:     $MIN_STARS"
echo "▶ max-repos:     $MAX_REPOS (per ecosystem)"
echo "▶ sources:       ${SOURCES}"
echo "▶ no-tag-resolve: $NO_TAG_RESOLVE"
echo "▶ resume:        $RESUME"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  echo "▶ github-token:  set (${#GITHUB_TOKEN} chars, starts ${GITHUB_TOKEN:0:8}…)"
else
  echo "▶ github-token:  NOT SET — limited to 60 req/hr"
fi
echo "▶ existing seen: ${#SEEN_SLUGS[@]}"
echo

for eco in "${ECOSYSTEMS[@]}"; do
  echo "════════════════════════════════════════"
  echo "▶ ecosystem: $eco"
  echo "════════════════════════════════════════"

  for src in "${SOURCE_LIST[@]}"; do
    (( ECO_COUNT["$eco"] >= MAX_REPOS )) && break
    case "$src" in
      search)       source_search      "$eco" ;;
      orgs)         source_orgs        "$eco" ;;
      depsdev)      source_depsdev     "$eco" ;;
      librariesio)  source_librariesio "$eco" ;;
      *) echo "WARNING: unknown source '$src'" >&2 ;;
    esac
    echo "  → $eco total so far: ${ECO_COUNT[$eco]}" >&2
  done

  echo "▶ $eco done: ${ECO_COUNT[$eco]} repos discovered"
  echo
done

echo "══════════════════════════════════════════════════"
echo "▶ discovery complete"
for eco in "${ECOSYSTEMS[@]}"; do
  echo "  $eco: ${ECO_COUNT[$eco]} repos"
done
local grand_total=0
for eco in "${ECOSYSTEMS[@]}"; do
  grand_total=$(( grand_total + ECO_COUNT["$eco"] ))
done
echo "  total: $grand_total"
echo "▶ manifest: $MANIFEST"
echo "══════════════════════════════════════════════════"
echo
echo "Next step:"
echo "  ./master.sh clone --all --manifest $MANIFEST --jobs 8 --depth 1"
