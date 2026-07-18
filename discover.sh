#!/usr/bin/env bash
# discover.sh — find top packages from PyPI/Maven/npm, resolve GitHub URLs, add to manifest
#
# Usage:
#   ./discover.sh --python --manifest manifest.tsv
#   ./discover.sh --java   --manifest manifest.tsv
#   ./discover.sh --node   --manifest manifest.tsv
#   ./discover.sh --all    --manifest manifest.tsv
#
# Java sources (Sonatype browse API is dead / 404; do not rely on it):
#   1. Maven Central via search.maven.org + POM → GitHub
#   2. GitHub Search (language:Java) — works offline from Maven, needs token
#   3. Curated seed list (last resort)
#
# For large Java corpora (thousands of repos), prefer the resume-safe scaler:
#   ./scale-java.sh --target 10000
#   ./scale-java.sh status
#
# Env: GITHUB_TOKEN (required for GitHub API)
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="manifest.tsv"
CACHE_DIR=".discover-cache"
LIMIT=1000
declare -a ECOSYSTEMS=()
# Browser-like UA — some corporate/Mac networks filter bare curl
CURL_UA="${CURL_UA:-Mozilla/5.0 (compatible; corpus-discover/1.0; +https://github.com/ictx-ai/corpus)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python)   ECOSYSTEMS+=("python"); shift ;;
    --java)     ECOSYSTEMS+=("java");   shift ;;
    --node)     ECOSYSTEMS+=("node");   shift ;;
    --all)      ECOSYSTEMS+=("python" "java" "node"); shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --limit)    LIMIT="$2";    shift 2 ;;
    --cache)    CACHE_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ ${#ECOSYSTEMS[@]} -eq 0 ]] && { echo "Specify --python, --java, --node, or --all" >&2; exit 1; }
[[ -z "${GITHUB_TOKEN:-}" ]] && { echo "ERROR: GITHUB_TOKEN not set" >&2; exit 1; }

mkdir -p "$CACHE_DIR"

# curl wrapper: always send UA; never use -f so callers can inspect status
http_get() {
  local url="$1" out="$2"
  local code
  code=$(curl -sS -L --max-time 20 \
    -A "$CURL_UA" \
    -H "Accept: application/json, text/plain, */*" \
    -o "$out" \
    -w "%{http_code}" \
    "$url" 2>/dev/null || echo "000")
  printf '%s' "$code"
}

# Init manifest
[[ ! -f "$MANIFEST" ]] && printf '# url\tcategory\tdir-name\ttag\tstatus\n' > "$MANIFEST"

# Load seen slugs into temp file for dedup
SEEN=$(mktemp)
trap "rm -f $SEEN" EXIT
grep -v '^#' "$MANIFEST" | awk -F'\t' '{print $1}' \
  | sed 's|https://github.com/||; s|\.git$||' > "$SEEN" 2>/dev/null || true
echo "▶ existing: $(wc -l < "$SEEN" | tr -d ' ') repos" >&2

# GitHub API call
gh() {
  curl -fsSL --max-time 15 \
    -A "$CURL_UA" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

# Write a validated repo to the manifest.
# Usage:
#   emit <slug> <eco>                     # REST metadata + optional release tag
#   emit <slug> <eco> <stars> <pushed> 1  # prevalidated (Search hit; no REST)
# Returns 0 if a NEW row was written, 1 otherwise.
emit() {
  local slug="$1" eco="$2"
  local stars_in="${3:-}" pushed_in="${4:-}" prevalidated="${5:-0}"
  [[ -z "$slug" ]] && return 1
  grep -qxF "$slug" "$SEEN" && return 1

  local stars=0 pushed="" tag=""

  if [[ "$prevalidated" == "1" ]]; then
    stars=$((stars_in + 0))
    pushed="${pushed_in:-}"
    [[ $stars -lt 50 ]] && return 1
    [[ -n "$pushed" && "$pushed" < "2022-01-01" ]] && return 1
  else
    local meta
    meta=$(gh "https://api.github.com/repos/${slug}" 2>/dev/null) || {
      # REST blocked/rate-limited — still accept known popular slugs without tag
      echo "  ⚠ REST unavailable for $slug — writing pending without tag" >&2
      stars=50
      pushed="2024-01-01"
      meta=""
    }
    if [[ -n "$meta" ]]; then
      local archived fork
      archived=$(echo "$meta" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('archived',False))" 2>/dev/null || echo "True")
      fork=$(echo "$meta"     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fork',False))"     2>/dev/null || echo "True")
      stars=$(echo "$meta"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stargazers_count',0))" 2>/dev/null || echo "0")
      pushed=$(echo "$meta"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('pushed_at','')[:10])"  2>/dev/null || echo "")
      [[ "$archived" == "True" ]] && return 1
      [[ "$fork"     == "True" ]] && return 1
      [[ $((stars+0)) -lt 50   ]] && return 1
      [[ -n "$pushed" && "$pushed" < "2022-01-01" ]] && return 1

      tag=$(gh "https://api.github.com/repos/${slug}/releases/latest" 2>/dev/null \
        | python3 -c "
import sys,json,re
try:
    t=(json.load(sys.stdin).get('tag_name') or '')
    if t and re.search(r'[0-9]+\.[0-9]+', t): print(t)
except: pass
" 2>/dev/null || true)
    fi
  fi

  # Only mark seen after we commit to writing
  echo "$slug" >> "$SEEN"

  local owner repo name
  owner=$(echo "$slug" | cut -d/ -f1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
  repo=$(echo "$slug"  | cut -d/ -f2 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
  # owner-repo avoids dir collisions across ecosystems/orgs
  name="${owner}-${repo}"

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "https://github.com/${slug}.git" "$eco" "$name" "${tag:-}" "pending" >> "$MANIFEST"

  echo "  + $slug${tag:+ @ $tag}" >&2
  return 0
}

# ── Python: top PyPI packages by download count ───────────────────────────────
discover_python() {
  echo "── Python: top PyPI packages ──" >&2
  local cache="$CACHE_DIR/pypi-top.json"

  [[ ! -f "$cache" ]] && \
    curl -fsSL --max-time 30 \
      "https://hugovk.github.io/top-pypi-packages/top-pypi-packages-30-days.min.json" \
      > "$cache" 2>/dev/null

  local count=0
  while IFS=$'\t' read -r pkg _downloads; do
    [[ $count -ge $LIMIT ]] && break

    # PyPI metadata → GitHub URL
    local pypi_cache="$CACHE_DIR/pypi-${pkg}.json"
    [[ ! -f "$pypi_cache" ]] && {
      curl -fsSL --max-time 10 "https://pypi.org/pypi/${pkg}/json" \
        > "$pypi_cache" 2>/dev/null || echo '{}' > "$pypi_cache"
      sleep 0.1
    }

    local slug
    slug=$(python3 - "$pypi_cache" <<'PYEOF'
import sys, json, re

def gh(url):
    if not url: return ""
    m = re.search(r'github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git|[/#\s]|$)', url)
    return m.group(1).rstrip('/.') if m else ""

try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    info = d.get("info", {})
    for url in (info.get("project_urls") or {}).values():
        s = gh(url)
        if s and s.count('/') == 1: print(s); break
    else:
        s = gh(info.get("home_page","")) or gh(info.get("bugtrack_url",""))
        if s: print(s)
except: pass
PYEOF
    ) || true

    [[ -z "$slug" ]] && continue
    emit "$slug" "python"
    count=$((count + 1))

  done < <(python3 -c "
import json
with open('$cache') as f: d=json.load(f)
for r in d.get('rows',[]):
    print(r['project'] + '\t' + str(r['download_count']))
")

  echo "▶ python: $count repos added" >&2
}

# ── Java discovery ────────────────────────────────────────────────────────────
# Sonatype central.sonatype.com/api/v1/browse is gone (HTTP 404). Sources:
#   A) search.maven.org (Solr) + repo1 POMs → GitHub URLs
#   B) GitHub Search API (language:Java) — primary path when Maven is blocked
#   C) curated seed list (last resort)
#
# For 10k-scale growth use: ./scale-java.sh --target 10000

# Extract GitHub owner/repo from a local POM file
_pom_github_slug() {
  python3 - "$1" <<'PYEOF'
import sys, re
try:
    pom = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except Exception:
    sys.exit(0)
# scm / url / developerConnection / issues
for pat in (
    r'github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git|[/#\s"<]|$)',
    r'scm:git:git@github\.com:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?',
):
    m = re.search(pat, pom, re.I)
    if m:
        print(m.group(1).rstrip('/.'))
        break
PYEOF
}

# Fetch Maven artifact list for a groupId via search.maven.org; emit g\ta\tv lines
_maven_group_artifacts() {
  local group="$1" rows="${2:-100}"
  local cache safe q enc code
  safe=$(echo "$group" | tr './:' '___')
  cache="$CACHE_DIR/maven-solr-${safe}-r${rows}.json"

  # Refresh empty / HTML / non-JSON caches (stale failures from blocked runs)
  if [[ -f "$cache" ]]; then
    if ! python3 -c "import json; json.load(open('$cache'))" 2>/dev/null; then
      rm -f "$cache"
    elif python3 -c "
import json
d=json.load(open('$cache'))
raise SystemExit(0 if (d.get('response') or {}).get('docs') is not None else 1)
" 2>/dev/null; then
      :
    else
      rm -f "$cache"
    fi
  fi

  if [[ ! -f "$cache" ]]; then
    # q=g:"org.springframework"  — quote group for exact match
    q="g:\"${group}\""
    enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$q")
    code=$(http_get "https://search.maven.org/solrsearch/select?q=${enc}&rows=${rows}&wt=json" "$cache")
    if [[ "$code" != "200" ]]; then
      echo "  ⚠ search.maven.org HTTP $code for g=$group" >&2
      rm -f "$cache"
      echo '{"response":{"docs":[]}}' > "$cache"
    fi
    sleep 0.25
  fi

  python3 -c "
import json
try:
    d=json.load(open('$cache'))
except Exception:
    d={}
for doc in (d.get('response') or {}).get('docs') or []:
    g=doc.get('g') or ''
    a=doc.get('a') or ''
    v=doc.get('latestVersion') or ''
    if g and a and v:
        print(g + '\t' + a + '\t' + v)
"
}

# Resolve one Maven GAV → GitHub and emit()
_java_from_gav() {
  local g="$1" a="$2" v="$3"
  local g_path pom_cache code slug
  g_path="${g//.//}"
  # sanitize cache path
  pom_cache="$CACHE_DIR/pom-$(echo "${g}-${a}-${v}" | tr '/:' '__').xml"

  if [[ -f "$pom_cache" ]] && [[ ! -s "$pom_cache" ]]; then
    rm -f "$pom_cache"   # drop empty failures so we can retry
  fi

  if [[ ! -f "$pom_cache" ]]; then
    code=$(http_get "https://repo1.maven.org/maven2/${g_path}/${a}/${v}/${a}-${v}.pom" "$pom_cache")
    if [[ "$code" != "200" ]]; then
      rm -f "$pom_cache"
      : > "$pom_cache"
    fi
    sleep 0.05
  fi

  slug=$(_pom_github_slug "$pom_cache" || true)
  [[ -z "$slug" ]] && return 1
  emit "$slug" "java"
}

discover_java_maven() {
  echo "  [maven] Maven Central via search.maven.org" >&2
  local count=0
  local group g a v

  # Popular / high-signal groupIds (search.maven.org has no global popularity sort)
  # NOTE: do not name this GROUPS — some environments reserve/export that name.
  local -a MAVEN_GROUP_IDS=(
    org.springframework org.springframework.boot org.springframework.security
    org.springframework.cloud org.springframework.data
    com.fasterxml.jackson.core com.fasterxml.jackson.datatype
    org.apache.commons org.apache.httpcomponents org.apache.httpcomponents.client5
    org.apache.logging.log4j org.apache.maven org.apache.tomcat
    org.apache.kafka org.apache.flink org.apache.beam org.apache.avro
    org.apache.lucene org.apache.poi org.apache.pdfbox org.apache.camel
    org.hibernate.orm org.hibernate.validator org.mybatis
    org.junit.jupiter org.mockito org.assertj org.testcontainers
    io.netty io.projectreactor io.quarkus io.micronaut io.grpc
    io.micrometer io.opentelemetry io.zipkin.reporter2
    com.google.guava com.google.code.gson com.google.dagger com.google.errorprone
    com.squareup.okhttp3 com.squareup.retrofit2
    redis.clients org.redisson io.lettuce
    org.mongodb org.postgresql com.mysql com.h2database
    org.flywaydb org.liquibase com.zaxxer
    org.keycloak org.jboss.resteasy org.eclipse.jetty
    io.vertx org.glassfish.jersey.core
    com.alibaba com.alibaba.cloud com.baomidou
    org.elasticsearch.client org.neo4j.driver
    software.amazon.awssdk com.amazonaws
    io.kubernetes org.bouncycastle
  )

  for group in "${MAVEN_GROUP_IDS[@]}"; do
    [[ $count -ge $LIMIT ]] && break
    echo "    · group $group" >&2
    while IFS=$'\t' read -r g a v; do
      [[ $count -ge $LIMIT ]] && break
      [[ -z "$g" || -z "$a" || -z "$v" ]] && continue
      if _java_from_gav "$g" "$a" "$v"; then
        count=$(( count + 1 ))
      fi
    done < <(_maven_group_artifacts "$group" 80)
  done

  echo "  maven path added=$count (toward limit $LIMIT)" >&2
  printf '%s' "$count"
}

discover_java_github() {
  # Top-star Java repos via Search API (no Maven dependency). Good when Maven is blocked.
  echo "  [github] GitHub Search language:Java (stars≥50)" >&2
  local count=0 page enc body nitems slug stars
  local q="language:Java fork:false archived:false stars:>=50"
  enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$q")

  for page in $(seq 1 10); do  # max 1000 results per query
    [[ $count -ge $LIMIT ]] && break
    local cache="$CACHE_DIR/gh-java-search-p${page}.json"
    local code

    if [[ -f "$cache" ]] && ! python3 -c "import json; d=json.load(open('$cache')); assert 'items' in d" 2>/dev/null; then
      rm -f "$cache"
    fi

    if [[ ! -f "$cache" ]]; then
      code=$(curl -sS -L --max-time 30 \
        -A "$CURL_UA" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -o "$cache" -w "%{http_code}" \
        "https://api.github.com/search/repositories?q=${enc}&sort=stars&order=desc&per_page=100&page=${page}" \
        2>/dev/null || echo "000")
      if [[ "$code" == "403" || "$code" == "429" ]]; then
        echo "  ⏳ GitHub Search HTTP $code — sleeping 60s" >&2
        sleep 60
        code=$(curl -sS -L --max-time 30 \
          -A "$CURL_UA" \
          -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -o "$cache" -w "%{http_code}" \
          "https://api.github.com/search/repositories?q=${enc}&sort=stars&order=desc&per_page=100&page=${page}" \
          2>/dev/null || echo "000")
      fi
      if [[ "$code" != "200" ]]; then
        echo "  ⚠ GitHub Search HTTP $code page=$page" >&2
        rm -f "$cache"
        break
      fi
      sleep 2   # stay under ~30 search/min
    fi

    nitems=$(python3 -c "
import json
try:
    print(len(json.load(open('$cache')).get('items') or []))
except Exception:
    print(0)
")
    [[ "$((nitems + 0))" -eq 0 ]] && break

    while IFS=$'\t' read -r slug stars pushed; do
      [[ $count -ge $LIMIT ]] && break
      [[ -z "$slug" ]] && continue
      # prevalidated=1 → no REST (works when REST rate-limit is exhausted)
      if emit "$slug" "java" "$stars" "$pushed" 1; then
        count=$(( count + 1 ))
      fi
    done < <(python3 -c "
import json
try:
    d=json.load(open('$cache'))
except Exception:
    raise SystemExit
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

  echo "  github path added=$count" >&2
  printf '%s' "$count"
}

discover_java_seed() {
  echo "  [seed] curated seed list (last resort)" >&2
  local count=0
  while IFS= read -r slug; do
    [[ $count -ge $LIMIT ]] && break
    [[ -z "$slug" || "$slug" == "#"* ]] && continue
    if emit "$slug" "java"; then
      count=$(( count + 1 ))
    fi
  done <<'SLUGS'
spring-projects/spring-boot
spring-projects/spring-framework
spring-projects/spring-security
spring-projects/spring-batch
apache/kafka
apache/flink
apache/spark
apache/cassandra
elastic/elasticsearch
netty/netty
google/guava
grpc/grpc-java
FasterXML/jackson-core
hibernate/hibernate-orm
junit-team/junit5
mockito/mockito
quarkusio/quarkus
micronaut-projects/micronaut-core
keycloak/keycloak
alibaba/nacos
alibaba/Sentinel
square/okhttp
square/retrofit
brettwooldridge/HikariCP
redis/jedis
testcontainers/testcontainers-java
checkstyle/checkstyle
pmd/pmd
spotbugs/spotbugs
projectlombok/lombok
gradle/gradle
trinodb/trino
dropwizard/dropwizard
qos-ch/slf4j
qos-ch/logback
WebGoat/WebGoat
zaproxy/zaproxy
SLUGS
  echo "  seed path added=$count" >&2
  printf '%s' "$count"
}

discover_java() {
  echo "── Java discovery (GitHub Search → Maven → seed) ──" >&2
  echo "  note: Sonatype browse API is discontinued (404); not used." >&2

  local total=0 n=0
  local saved_limit=$LIMIT

  # GitHub Search first: works without Maven, needs no REST budget for writes,
  # and is what scale-java.sh uses for 10k-scale growth.
  set +e
  n=$(discover_java_github)
  set -e
  total=$(( total + ${n:-0} ))

  if [[ $total -lt $saved_limit ]]; then
    LIMIT=$(( saved_limit - total ))
    (( LIMIT < 1 )) && LIMIT=1
    set +e
    n=$(discover_java_maven)
    set -e
    total=$(( total + ${n:-0} ))
    LIMIT=$saved_limit
  fi

  if [[ $total -eq 0 ]]; then
    set +e
    n=$(discover_java_seed)
    set -e
    total=$(( total + ${n:-0} ))
  fi

  if [[ $total -eq 0 ]]; then
    echo "  ✗ no new java repos added." >&2
    echo "  Tips: check GITHUB_TOKEN; api.github.com Search must be reachable." >&2
    echo "  For large corpora: ./scale-java.sh --target 10000" >&2
  elif [[ -x "${SCRIPT_DIR}/scale-java.sh" ]]; then
    echo "  tip: for 10k-scale growth run ./scale-java.sh --target 10000" >&2
  fi

  echo "▶ java: $total repos added this run" >&2
}

# ── Node: top npm packages ────────────────────────────────────────────────────
discover_node() {
  echo "── Node: top npm packages ──" >&2

  local count=0
  for page in $(seq 0 3); do  # npm search returns 250/page
    [[ $count -ge $LIMIT ]] && break
    local cache="$CACHE_DIR/npm-p${page}.json"

    [[ ! -f "$cache" ]] && {
      curl -fsSL --max-time 20 \
        "https://registry.npmjs.org/-/v1/search?text=not:unstable&popularity=1.0&quality=0.0&maintenance=0.0&size=250&from=$((page*250))" \
        > "$cache" 2>/dev/null || echo '{"objects":[]}' > "$cache"
      sleep 0.5
    }

    local found
    found=$(python3 -c "
import json
try:
    with open('$cache') as f: d=json.load(f)
    print(len(d.get('objects',[])))
except: print(0)
")
    [[ $((found+0)) -eq 0 ]] && break

    while IFS=$'\t' read -r pkg; do
      [[ $count -ge $LIMIT ]] && break
      [[ -z "$pkg" ]] && continue

      local pkg_cache="$CACHE_DIR/npm-pkg-$(echo "$pkg" | tr '/@' '--').json"
      [[ ! -f "$pkg_cache" ]] && {
        local enc
        enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$pkg")
        curl -fsSL --max-time 10 \
          "https://registry.npmjs.org/${enc}/latest" \
          > "$pkg_cache" 2>/dev/null || echo '{}' > "$pkg_cache"
        sleep 0.1
      }

      local slug
      slug=$(python3 - "$pkg_cache" <<'PYEOF'
import sys, json, re

def gh(url):
    if not url: return ""
    url = re.sub(r'^git\+|\.git$','',url)
    url = re.sub(r'^github:','https://github.com/',url)
    m = re.search(r'github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git|[/#\s]|$)', url)
    return m.group(1).rstrip('/.') if m else ""

try:
    with open(sys.argv[1]) as f: d=json.load(f)
    repo = d.get('repository','')
    if isinstance(repo, dict): repo = repo.get('url','')
    s = gh(str(repo))
    if not s: s = gh(d.get('homepage',''))
    if s: print(s)
except: pass
PYEOF
      ) || true

      [[ -z "$slug" ]] && continue
      emit "$slug" "node"
      count=$((count + 1))

    done < <(python3 -c "
import json
with open('$cache') as f: d=json.load(f)
for o in d.get('objects',[]):
    print(o.get('package',{}).get('name',''))
")
  done

  # Fallback if npm API blocked
  if [[ $count -eq 0 ]]; then
    echo "  npm API blocked — using known top Node/TS repos" >&2
    while IFS= read -r slug; do
      [[ $count -ge $LIMIT ]] && break
      [[ -z "$slug" || "$slug" == "#"* ]] && continue
      emit "$slug" "node"
      count=$((count + 1))
    done <<'SLUGS'
nodejs/node
expressjs/express
nestjs/nest
facebook/react
vuejs/core
angular/angular
microsoft/TypeScript
vercel/next.js
nuxt/nuxt
sveltejs/svelte
vitejs/vite
webpack/webpack
evanw/esbuild
rollup/rollup
babel/babel
eslint/eslint
prettier/prettier
jestjs/jest
vitest-dev/vitest
mochajs/mocha
denoland/deno
socketio/socket.io
axios/axios
lodash/lodash
fastify/fastify
koajs/koa
hapijs/hapi
remix-run/remix
gatsbyjs/gatsby
withastro/astro
solidjs/solid
preactjs/preact
alpinejs/alpine
reduxjs/redux
pmndrs/zustand
pmndrs/jotai
mobxjs/mobx
immerjs/immer
colinhacks/zod
TanStack/query
TanStack/table
trpc/trpc
graphql/graphql-js
apollographql/apollo-server
prisma/prisma
typeorm/typeorm
sequelize/sequelize
mikro-orm/mikro-orm
strapi/strapi
payloadcms/payload
directus/directus
keystonejs/keystone
hasura/graphql-engine
date-fns/date-fns
iamkun/dayjs
moment/moment
TypeStrong/ts-node
microsoft/rushstack
vercel/turbo
pnpm/pnpm
yarnpkg/yarn
npm/cli
sindresorhus/got
node-fetch/node-fetch
axios/axios
websockets/ws
uWebSockets/uWebSockets.js
auth0/node-jsonwebtoken
panva/jose
jaredhanson/passport
kelektiv/node.bcrypt.js
helmetjs/helmet
expressjs/cors
expressjs/session
chalk/chalk
tj/commander.js
yargs/yargs
SBoudrias/Inquirer.js
sinonjs/sinon
chaijs/chai
karma-runner/karma
cypress-io/cypress
microsoft/playwright
puppeteer/puppeteer
webpack/webpack-dev-server
vitejs/vite-plugin-react
sveltejs/kit
remix-run/react-router
react-hook-form/react-hook-form
jquense/yup
validatorjs/validator.js
winstonjs/winston
pinojs/pino
motdotla/dotenv
isaacs/node-glob
jprichardson/node-fs-extra
shelljs/shelljs
tj/co
caolan/async
lodash/lodash
ramda/ramda
rxjs/rxjs
ReactiveX/rxjs
davidmarkclements/fast-safe-stringify
nicolo-ribaudo/jest-light-runner
avajs/ava
substack/tape
istanbuljs/nyc
bcoe/c8
brianc/node-postgres
sidorares/node-mysql2
mongodb/node-mongodb-native
redis/node-redis
luin/ioredis
dexie/Dexie.js
knex/knex
mikro-orm/mikro-orm
OWASP/NodeGoat
juice-shop/juice-shop
snyk-labs/nodejs-goof
OWASP/DVNA
SLUGS
  fi

  echo "▶ node: $count repos added" >&2
}

# ── Run ───────────────────────────────────────────────────────────────────────
echo "▶ discover.sh — limit: $LIMIT per ecosystem"
echo "▶ manifest: $MANIFEST"
echo

for eco in "${ECOSYSTEMS[@]}"; do
  case "$eco" in
    python) discover_python ;;
    java)   discover_java   ;;
    node)   discover_node   ;;
  esac
done

echo
echo "▶ done. manifest: $MANIFEST"
echo "▶ next: ./master.sh clone --all --manifest $MANIFEST --jobs 8 --depth 1"
