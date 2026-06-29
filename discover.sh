#!/usr/bin/env bash
# discover.sh — find top packages from PyPI/Maven/npm, resolve GitHub URLs, add to manifest
#
# Usage:
#   ./discover.sh --python --manifest manifest.tsv
#   ./discover.sh --java   --manifest manifest.tsv
#   ./discover.sh --node   --manifest manifest.tsv
#   ./discover.sh --all    --manifest manifest.tsv
#
# Env: GITHUB_TOKEN (required for GitHub API)
set -euo pipefail

MANIFEST="manifest.tsv"
CACHE_DIR=".discover-cache"
LIMIT=1000
declare -a ECOSYSTEMS=()

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
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$@"
}

# Resolve a GitHub slug → validate → write to manifest
emit() {
  local slug="$1" eco="$2"
  [[ -z "$slug" ]] && return 0
  # Dedup
  grep -qxF "$slug" "$SEEN" && return 0
  echo "$slug" >> "$SEEN"

  # Get repo metadata
  local meta
  meta=$(gh "https://api.github.com/repos/${slug}" 2>/dev/null) || return 0

  # Quality checks
  local archived fork stars pushed
  archived=$(echo "$meta" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('archived',False))" 2>/dev/null || echo "True")
  fork=$(echo "$meta"     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fork',False))"     2>/dev/null || echo "True")
  stars=$(echo "$meta"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stargazers_count',0))" 2>/dev/null || echo "0")
  pushed=$(echo "$meta"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('pushed_at','')[:10])"  2>/dev/null || echo "")

  [[ "$archived" == "True" ]] && return 0
  [[ "$fork"     == "True" ]] && return 0
  [[ $((stars+0)) -lt 50   ]] && return 0
  [[ -n "$pushed" && "$pushed" < "2022-01-01" ]] && return 0

  # Get latest tag
  local tag=""
  tag=$(gh "https://api.github.com/repos/${slug}/releases/latest" 2>/dev/null \
    | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    t=d.get('tag_name','')
    import re
    if t and re.search(r'[0-9]+\.[0-9]+',t): print(t)
except: pass
" 2>/dev/null || true)

  local name
  name=$(echo "$slug" | cut -d/ -f2 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "https://github.com/${slug}.git" "$eco" "$name" "${tag:-}" "pending" >> "$MANIFEST"

  echo "  + $slug${tag:+ @ $tag}" >&2
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

# ── Java: top Maven packages ──────────────────────────────────────────────────
discover_java() {
  echo "── Java: top Maven packages ──" >&2

  local count=0
  for page in $(seq 0 19); do  # 20 pages × 50 = 1000
    [[ $count -ge $LIMIT ]] && break
    local cache="$CACHE_DIR/sonatype-p${page}.json"

    [[ ! -f "$cache" ]] && {
      curl -fsSL --max-time 15 \
        -H "Accept: application/json" \
        "https://central.sonatype.com/api/v1/browse?size=50&page=${page}&sortField=normalizedPopularity&sortDirection=DESC" \
        > "$cache" 2>/dev/null || echo '{"components":[]}' > "$cache"
      sleep 0.3
    }

    local found
    found=$(python3 -c "
import json, sys
try:
    with open('$cache') as f: d=json.load(f)
    print(len(d.get('components',[])))
except: print(0)
")
    [[ $((found+0)) -eq 0 ]] && break

    while IFS=$'\t' read -r g a v; do
      [[ $count -ge $LIMIT ]] && break
      [[ -z "$g" || -z "$a" || -z "$v" ]] && continue

      # Fetch POM → extract GitHub URL
      local g_path="${g//./\/}"
      local pom_cache="$CACHE_DIR/pom-${g}-${a}-${v}.xml"
      [[ ! -f "$pom_cache" ]] && {
        curl -fsSL --max-time 10 \
          "https://repo1.maven.org/maven2/${g_path}/${a}/${v}/${a}-${v}.pom" \
          > "$pom_cache" 2>/dev/null || echo "" > "$pom_cache"
        sleep 0.1
      }

      local slug
      slug=$(python3 - "$pom_cache" <<'PYEOF'
import sys, re
try:
    pom = open(sys.argv[1]).read()
    m = re.search(r'github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git|[/#\s]|$)', pom)
    if m: print(m.group(1).rstrip('/.'))
except: pass
PYEOF
      ) || true

      [[ -z "$slug" ]] && continue
      emit "$slug" "java"
      count=$((count + 1))

    done < <(python3 -c "
import json
with open('$cache') as f: d=json.load(f)
for c in d.get('components',[]):
    print(c.get('namespace','') + '\t' + c.get('name','') + '\t' + c.get('version',''))
")
  done

  # Fallback if Sonatype blocked: use hardcoded top groupIds
  if [[ $count -eq 0 ]]; then
    echo "  Sonatype blocked — using known top Java repos" >&2
    while IFS=$'\t' read -r slug; do
      [[ $count -ge $LIMIT ]] && break
      emit "$slug" "java"
      count=$((count + 1))
    done <<'SLUGS'
spring-projects/spring-boot
spring-projects/spring-framework
spring-projects/spring-security
spring-projects/spring-data-commons
spring-projects/spring-batch
spring-projects/spring-integration
spring-projects/spring-authorization-server
spring-cloud/spring-cloud-gateway
spring-cloud/spring-cloud-config
spring-cloud/spring-cloud-openfeign
spring-petclinic/spring-petclinic-microservices
apache/kafka
apache/flink
apache/spark
apache/hadoop
apache/cassandra
apache/hbase
apache/hive
apache/zookeeper
apache/camel
apache/dubbo
apache/rocketmq
apache/shardingsphere
apache/skywalking
apache/druid
apache/pulsar
apache/beam
apache/solr
apache/nifi
apache/lucene
apache/tika
apache/poi
apache/pdfbox
apache/avro
apache/parquet-mr
apache/arrow
apache/calcite
apache/activemq
apache/activemq-artemis
apache/maven
apache/tomcat
apache/groovy
apache/ignite
apache/shiro
apache/commons-lang
apache/commons-io
apache/commons-collections
apache/commons-codec
apache/commons-compress
apache/httpcomponents-client
apache/logging-log4j2
apache/pinot
elastic/elasticsearch
opensearch-project/OpenSearch
netty/netty
google/guava
google/guice
google/gson
google/auto
google/error-prone
google/truth
google/tink
google/dagger
grpc/grpc-java
protocolbuffers/protobuf
eclipse-vertx/vert.x
eclipse/jetty.project
eclipse-ee4j/jersey
eclipse/eclipse-collections
FasterXML/jackson-core
FasterXML/jackson-databind
FasterXML/jackson-dataformats-binary
hibernate/hibernate-orm
hibernate/hibernate-validator
mybatis/mybatis-3
mybatis/spring-boot-starter
baomidou/mybatis-plus
jOOQ/jOOQ
flyway/flyway
liquibase/liquibase
brettwooldridge/HikariCP
pgjdbc/pgjdbc
mysql/mysql-connector-j
h2database/h2database
mariadb/mariadb-connector-j
mongodb/mongo-java-driver
datastax/java-driver
redis/jedis
square/okhttp
square/retrofit
square/javapoet
square/picasso
square/leakcanary
ReactiveX/RxJava
ReactiveX/RxAndroid
resilience4j/resilience4j
ben-manes/caffeine
lettuce-io/lettuce-core
redisson/redisson
Netflix/eureka
Netflix/Hystrix
Netflix/ribbon
Netflix/zuul
OpenFeign/feign
quarkusio/quarkus
micronaut-projects/micronaut-core
helidon-io/helidon
undertow-io/undertow
open-telemetry/opentelemetry-java
open-telemetry/opentelemetry-java-instrumentation
micrometer-metrics/micrometer
openzipkin/brave
openzipkin/zipkin
keycloak/keycloak
apereo/cas
pac4j/pac4j
auth0/java-jwt
jwtk/jjwt
bcgit/bc-java
connect2id/nimbus-jose-jwt
junit-team/junit5
mockito/mockito
assertj/assertj-core
testcontainers/testcontainers-java
jacoco/jacoco
checkstyle/checkstyle
pmd/pmd
spotbugs/spotbugs
raphw/byte-buddy
asm-lab/asm
jboss-javassist/javassist
rzwitserloot/lombok
mapstruct/mapstruct
immutables/immutables
hcoles/pitest
TNG/ArchUnit
diffplug/spotless
gradle/gradle
trinodb/trino
prestodb/presto
neo4j/neo4j
hazelcast/hazelcast
questdb/questdb
orientechnologies/orientdb
h2database/h2database
dropwizard/dropwizard
graphql-java/graphql-java
swagger-api/swagger-core
springdoc/springdoc-openapi
springfox/springfox
alibaba/nacos
alibaba/spring-cloud-alibaba
alibaba/Sentinel
alibaba/fastjson
apolloconfig/apollo
seata/seata
pagehelper/Mybatis-PageHelper
dromara/Sa-Token
halo-dev/halo
macrozheng/mall
jeecgboot/JeecgBoot
pig-mesh/pig
zaproxy/zaproxy
WebGoat/WebGoat
OWASP-Benchmark/BenchmarkJava
JoyChou93/java-sec-code
bumptech/glide
airbnb/lottie-android
facebook/fresco
facebook/rocksdb
LMAX-Exchange/disruptor
jhy/jsoup
thymeleaf/thymeleaf
itext/itext7
java-native-access/jna
oracle/graal
scala/scala
JetBrains/kotlin
akka/akka
playframework/playframework
ktorio/ktor
vavr-io/vavr
EsotericSoftware/kryo
msgpack/msgpack-java
qos-ch/slf4j
qos-ch/logback
aws/aws-sdk-java-v2
fabric8io/kubernetes-client
minio/minio-java
alibaba/ARouter
greenrobot/EventBus
greenrobot/greenDAO
JakeWharton/butterknife
permissions-dispatcher/PermissionsDispatcher
jankotek/mapdb
srikanth-lingala/zip4j
vsch/flexmark-java
apache/freemarker
apache/velocity-engine
SLUGS
  fi

  echo "▶ java: $count repos added" >&2
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
