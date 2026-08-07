#!/usr/bin/env bash
#
# Single-node Elasticsearch + Kibana + Fluentd, with TLS everywhere,
# secrets in keystores, and provisioned credentials for Terraform (DaC)
# and Fluentd log shipping.
#
#   ./deploy.sh up          # full deploy (default)
#   ./deploy.sh provision   # re-run role/user/API-key provisioning only
#   ./deploy.sh status      # health + endpoints
#   ./deploy.sh creds       # print generated credentials
#   ./deploy.sh clean       # tear down and wipe certs/secrets/volumes
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CERTS_DIR="$SCRIPT_DIR/certs"
SECRETS_DIR="$SCRIPT_DIR/secrets"
OUT_DIR="$SCRIPT_DIR/out"
ENV_FILE="$SCRIPT_DIR/.env"

# ---------------------------------------------------------------- defaults --
DEF_STACK_VERSION="9.5.0"
DEF_FLUENTD_VERSION="v1.17-1"
DEF_CLUSTER_NAME="es-single"
DEF_ES_PORT="9200"
DEF_KIBANA_PORT="5601"
DEF_FLUENTD_PORT="24224"
DEF_ES_HEAP="2g"
DEF_ES_MEM_LIMIT="4g"
DEF_LICENSE="basic"

EXTRA_SANS=()
ROTATE_KEYS="no"
ASSUME_YES="no"

# ----------------------------------------------------------------- helpers --
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
step() { printf '\n%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
dim()  { printf '%s    %s%s\n' "$c_dim" "$*" "$c_off"; }

# Random alnum secret. Subshell so `head` closing the pipe can't trip pipefail.
gen_secret() (
  set +o pipefail
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-24}"
)

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# .env is sourced by bash *and* parsed by Compose, which also interpolates
# ${...} inside values. Rather than escape for two grammars, reject the five
# characters that break either one.
validate_secret() {
  local name="$1" value="$2"
  [[ -n "$value" ]] || die "$name is empty"
  (( ${#value} >= 8 )) || die "$name must be at least 8 characters"
  if [[ "$value" == *['"'\'\\\$\`]* ]]; then
    die "$name cannot contain \" ' \\ \$ or \` -- these break .env parsing.
    Everything else printable is fine, e.g. --password 'S0me-l0ng!p@ss#phrase'"
  fi
}

require_env() {
  [[ -f "$ENV_FILE" ]] || die "no .env found -- run './deploy.sh up' first"
}

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --password PASS         elastic superuser password        (default: generated)
  --version VER           Elastic Stack version             (default: 9.5.0)
  --cluster-name NAME     cluster.name                      (default: es-single)
  --es-port PORT          host port for Elasticsearch       (default: 9200)
  --kibana-port PORT      host port for Kibana              (default: 5601)
  --fluentd-port PORT     host port for Fluentd forward     (default: 24224)
  --heap SIZE             JVM heap, Xms=Xmx                 (default: 2g)
  --mem-limit SIZE        container memory limit            (default: 4g)
  --license TYPE          basic | trial                     (default: basic)
  --engine NAME           auto | docker | podman            (default: auto)
  --san NAME              extra DNS SAN on the certs (repeatable)
  --rotate-keys           re-issue the Terraform API key
  -y, --yes               don't prompt for confirmation
  -h, --help              this

Values already present in .env are reused; flags override them.
EOF
}

# ------------------------------------------------------------- arg parsing --
CMD="up"
case "${1:-}" in
  up|provision|status|creds|clean) CMD="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password)     OPT_ELASTIC_PASSWORD="$2"; shift 2 ;;
    --version)      OPT_STACK_VERSION="$2";    shift 2 ;;
    --cluster-name) OPT_CLUSTER_NAME="$2";     shift 2 ;;
    --es-port)      OPT_ES_PORT="$2";          shift 2 ;;
    --kibana-port)  OPT_KIBANA_PORT="$2";      shift 2 ;;
    --fluentd-port) OPT_FLUENTD_PORT="$2";     shift 2 ;;
    --heap)         OPT_ES_HEAP="$2";          shift 2 ;;
    --mem-limit)    OPT_ES_MEM_LIMIT="$2";     shift 2 ;;
    --license)      OPT_LICENSE="$2";          shift 2 ;;
    --engine)       OPT_ENGINE="$2";           shift 2 ;;
    --san)          EXTRA_SANS+=("$2");        shift 2 ;;
    --rotate-keys)  ROTATE_KEYS="yes";         shift ;;
    -y|--yes)       ASSUME_YES="yes";          shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# --------------------------------------------- 1. engine detection + checks --
# Populates RUNTIME, COMPOSE, ROOTLESS, SELINUX_LABEL and MEMORY_LOCK.
detect_engine() {
  local want="${OPT_ENGINE:-${CONTAINER_ENGINE:-auto}}"

  if [[ "$want" == "auto" ]]; then
    # The podman-docker package puts podman behind /usr/bin/docker, so ask
    # what it really is rather than trusting the name.
    if command -v docker >/dev/null 2>&1 && ! docker --version 2>/dev/null | grep -qi podman; then
      want="docker"
    elif command -v podman >/dev/null 2>&1; then
      want="podman"
    else
      die "neither docker nor podman found on PATH"
    fi
  fi

  case "$want" in
    docker)
      RUNTIME=(docker)
      docker compose version >/dev/null 2>&1 \
        || die "docker compose v2 plugin not available"
      COMPOSE=(docker compose)
      ;;
    podman)
      command -v podman >/dev/null 2>&1 || die "podman not found on PATH"
      RUNTIME=(podman)
      # Preference order: real compose v2 driving the podman socket (best
      # fidelity, notably for depends_on healthcheck conditions), then
      # podman's own wrapper, then podman-compose.
      if [[ -n "${DOCKER_HOST:-}" ]] && command -v docker >/dev/null 2>&1 \
         && docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
      elif podman compose version >/dev/null 2>&1; then
        COMPOSE=(podman compose)
      elif command -v podman-compose >/dev/null 2>&1; then
        COMPOSE=(podman-compose)
        warn "using podman-compose; its depends_on condition support is weak."
        dim "This script sequences services itself, so it should still work."
      else
        die "no compose implementation found. Install one of:
    sudo zypper install docker-compose   # then export DOCKER_HOST, see README
    sudo zypper install podman-compose"
      fi
      ;;
    *) die "--engine must be auto, docker or podman" ;;
  esac

  "${RUNTIME[@]}" info >/dev/null 2>&1 \
    || die "cannot talk to the ${RUNTIME[0]} service"

  log "engine: ${RUNTIME[*]}   compose: ${COMPOSE[*]}"
}

# Rootless podman cannot raise RLIMIT_MEMLOCK above the invoking user's hard
# limit, so bootstrap.memory_lock=true fails Elasticsearch's bootstrap check
# and the node exits. Detect it and turn memory locking off instead.
detect_rootless() {
  ROOTLESS="no"
  if [[ "${RUNTIME[0]}" == "podman" ]]; then
    [[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == "true" ]] \
      && ROOTLESS="yes"
  fi

  DETECTED_MEMORY_LOCK="true"
  MEMLOCK_BYTES=""
  if [[ "$ROOTLESS" == "yes" ]]; then
    local hard
    hard="$(ulimit -Hl 2>/dev/null || echo unlimited)"
    if [[ "$hard" == "unlimited" ]]; then
      log "rootless podman, but memlock is unlimited -- keeping memory_lock on"
    else
      DETECTED_MEMORY_LOCK="false"
      MEMLOCK_BYTES=$(( hard * 1024 ))
      warn "rootless podman: memlock hard limit is ${hard}KB, so"
      warn "bootstrap.memory_lock has been turned OFF for this deployment."
      dim "The heap may be swapped out. To lock memory instead, either run"
      dim "rootful (sudo ./deploy.sh) or raise the limit for your user:"
      dim "  sudo mkdir -p /etc/systemd/system/user@\$(id -u).service.d"
      dim "  printf '[Service]\\nLimitMEMLOCK=infinity\\n' | sudo tee \\"
      dim "    /etc/systemd/system/user@\$(id -u).service.d/memlock.conf"
      dim "  sudo systemctl daemon-reload && loginctl terminate-user \$(id -un)"
      dim "Disabling swap on the host achieves the same end."
    fi
  fi
}

# Rootless podman's cgroup v2 scope only gets controllers systemd delegates
# to user@<uid>.service. Most distros delegate just "pids" by default; the
# compose file's mem_limit: needs "memory" too, or runc fails deep inside
# `compose up` with a cryptic "no such file or directory" on memory.swap.max.
detect_cgroup_delegation() {
  DELEGATED_MEMORY="yes"
  [[ "$ROOTLESS" == "yes" ]] || return 0

  local rel controllers
  rel="$(awk -F: '$1==0{print $3}' /proc/self/cgroup 2>/dev/null)"
  [[ -n "$rel" && -r "/sys/fs/cgroup${rel}/cgroup.controllers" ]] || return 0
  controllers="$(cat "/sys/fs/cgroup${rel}/cgroup.controllers" 2>/dev/null)"

  if [[ " $controllers " != *" memory "* ]]; then
    DELEGATED_MEMORY="no"
    warn "rootless podman: the \"memory\" cgroup controller isn't delegated"
    warn "to your user session, so container memory limits (mem_limit: in"
    warn "docker-compose.yml) cannot be enforced -- 'compose up' will fail."
    dim "Fix by delegating it, then log out/in (or reboot):"
    dim "  sudo mkdir -p /etc/systemd/system/user@\$(id -u).service.d"
    dim "  printf '[Service]\\nDelegate=cpu cpuset io memory pids\\n' | sudo tee \\"
    dim "    /etc/systemd/system/user@\$(id -u).service.d/delegate.conf"
    dim "  sudo systemctl daemon-reload && loginctl terminate-user \$(id -un)"
  fi
}

# New Tumbleweed installs (snapshot 20250211 onward) default to SELinux
# enforcing; older ones kept AppArmor. Bind mounts need :z under the former.
# Read /sys/fs/selinux/enforce directly rather than relying on getenforce(1),
# which isn't installed by default on some systems even when SELinux is on.
detect_selinux() {
  DETECTED_SELINUX_LABEL=""
  MOUNT_OPT=""
  local enforcing="no"
  if [[ -r /sys/fs/selinux/enforce ]]; then
    [[ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" == "1" ]] && enforcing="yes"
  elif command -v getenforce >/dev/null 2>&1; then
    [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] && enforcing="yes"
  fi

  if [[ "$enforcing" == "yes" ]]; then
    DETECTED_SELINUX_LABEL=",z"
    MOUNT_OPT=":z"
    log "SELinux enforcing -- bind mounts will be relabelled (:z)"
  fi
}

# Written only when something needs overriding, and passed as an extra -f.
write_overrides() {
  local f="$SCRIPT_DIR/compose.override.yml"
  rm -f "$f"
  if [[ -n "$MEMLOCK_BYTES" ]]; then
    cat > "$f" <<EOF
# Generated by deploy.sh for rootless podman. ulimits is a mapping, so this
# replaces the memlock key cleanly rather than appending to it.
services:
  es01:
    ulimits:
      memlock:
        soft: ${MEMLOCK_BYTES}
        hard: ${MEMLOCK_BYTES}
EOF
    COMPOSE+=(-f docker-compose.yml -f compose.override.yml)
    log "wrote compose.override.yml (memlock clamped to ${MEMLOCK_BYTES} bytes)"
  fi
}

preflight() {
  detect_engine
  detect_rootless
  detect_cgroup_delegation
  detect_selinux

  if [[ "$(uname -s)" == "Linux" ]]; then
    local mmc
    mmc="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
    if (( mmc < 262144 )); then
      warn "vm.max_map_count is $mmc; Elasticsearch wants >= 262144."
      dim "sudo sysctl -w vm.max_map_count=262144"
      dim "echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf"
    fi
  fi
}

# ---------------------------------------------------------------- 2. config --
# Precedence: CLI flag > existing .env > default.
resolve() {
  local name="$1" default="$2" opt="OPT_$1"
  if [[ -n "${!opt:-}" ]]; then printf '%s' "${!opt}"
  elif [[ -n "${!name:-}" ]]; then printf '%s' "${!name}"
  else printf '%s' "$default"; fi
}

load_config() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE" || die "$ENV_FILE is not parseable -- fix or delete it"
    set +a
  fi

  STACK_VERSION="$(resolve STACK_VERSION   "$DEF_STACK_VERSION")"
  FLUENTD_VERSION="$(resolve FLUENTD_VERSION "$DEF_FLUENTD_VERSION")"
  CLUSTER_NAME="$(resolve CLUSTER_NAME     "$DEF_CLUSTER_NAME")"
  ES_PORT="$(resolve ES_PORT               "$DEF_ES_PORT")"
  KIBANA_PORT="$(resolve KIBANA_PORT       "$DEF_KIBANA_PORT")"
  FLUENTD_PORT="$(resolve FLUENTD_PORT     "$DEF_FLUENTD_PORT")"
  ES_HEAP="$(resolve ES_HEAP               "$DEF_ES_HEAP")"
  ES_MEM_LIMIT="$(resolve ES_MEM_LIMIT     "$DEF_ES_MEM_LIMIT")"
  LICENSE="$(resolve LICENSE               "$DEF_LICENSE")"

  ELASTIC_PASSWORD="$(resolve ELASTIC_PASSWORD "$(gen_secret 24)")"
  KIBANA_PASSWORD="$(resolve KIBANA_PASSWORD   "$(gen_secret 24)")"
  FLUENTD_PASSWORD="$(resolve FLUENTD_PASSWORD "$(gen_secret 24)")"
  TERRAFORM_PASSWORD="$(resolve TERRAFORM_PASSWORD "$(gen_secret 24)")"
  KBN_SO_KEY="$(resolve KBN_SO_KEY         "$(gen_secret 48)")"
  KBN_REPORT_KEY="$(resolve KBN_REPORT_KEY "$(gen_secret 48)")"
  KBN_SEC_KEY="$(resolve KBN_SEC_KEY       "$(gen_secret 48)")"

  # Engine-derived, so a stale .env must never win over fresh detection.
  MEMORY_LOCK="${DETECTED_MEMORY_LOCK:-true}"
  SELINUX_LABEL="${DETECTED_SELINUX_LABEL:-}"

  local n
  for n in ELASTIC_PASSWORD KIBANA_PASSWORD FLUENTD_PASSWORD TERRAFORM_PASSWORD \
           KBN_SO_KEY KBN_REPORT_KEY KBN_SEC_KEY; do
    validate_secret "$n" "${!n}"
  done

  ES_IMAGE="docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}"
  KB_IMAGE="docker.elastic.co/kibana/kibana:${STACK_VERSION}"
}

write_env() {
  # Subshell so the restrictive umask (avoids a world-readable window before
  # chmod below) doesn't leak into the rest of the script.
  (
  umask 077
  cat > "$ENV_FILE" <<EOF
# Generated by deploy.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Contains secrets.
STACK_VERSION="${STACK_VERSION}"
FLUENTD_VERSION="${FLUENTD_VERSION}"
CLUSTER_NAME="${CLUSTER_NAME}"
ES_PORT="${ES_PORT}"
KIBANA_PORT="${KIBANA_PORT}"
FLUENTD_PORT="${FLUENTD_PORT}"
ES_HEAP="${ES_HEAP}"
ES_MEM_LIMIT="${ES_MEM_LIMIT}"
LICENSE="${LICENSE}"
MEMORY_LOCK="${MEMORY_LOCK:-true}"
SELINUX_LABEL="${SELINUX_LABEL:-}"

ELASTIC_PASSWORD="${ELASTIC_PASSWORD}"
KIBANA_PASSWORD="${KIBANA_PASSWORD}"
FLUENTD_PASSWORD="${FLUENTD_PASSWORD}"
TERRAFORM_PASSWORD="${TERRAFORM_PASSWORD}"

KBN_SO_KEY="${KBN_SO_KEY}"
KBN_REPORT_KEY="${KBN_REPORT_KEY}"
KBN_SEC_KEY="${KBN_SEC_KEY}"
EOF
  )
  chmod 600 "$ENV_FILE"
  log "wrote $ENV_FILE (0600)"
}

# ------------------------------------------------------------------- 3. PKI --
gen_certs() {
  if [[ -f "$CERTS_DIR/ca/ca.crt" && -f "$CERTS_DIR/es01/es01.crt" ]]; then
    log "certificates already present, skipping"
    return
  fi

  mkdir -p "$CERTS_DIR"

  local es_dns='es01, localhost' kb_dns='kibana, localhost' san
  for san in "${EXTRA_SANS[@]:-}"; do
    [[ -z "$san" ]] && continue
    es_dns+=", $san"; kb_dns+=", $san"
  done

  cat > "$CERTS_DIR/instances.yml" <<EOF
instances:
  - name: es01
    dns: [${es_dns}]
    ip: [127.0.0.1]
  - name: kibana
    dns: [${kb_dns}]
    ip: [127.0.0.1]
EOF

  log "issuing CA + PEM certificates via elasticsearch-certutil"
  "${RUNTIME[@]}" run --rm -u 0 -v "$CERTS_DIR:/certs${MOUNT_OPT:-}" "$ES_IMAGE" bash -c '
    set -e
    if [ ! -f /certs/ca/ca.crt ]; then
      elasticsearch-certutil ca --silent --pem -out /certs/ca.zip
      unzip -q -o /certs/ca.zip -d /certs
    fi
    elasticsearch-certutil cert --silent --pem \
      -out /certs/certs.zip --in /certs/instances.yml \
      --ca-cert /certs/ca/ca.crt --ca-key /certs/ca/ca.key
    unzip -q -o /certs/certs.zip -d /certs
    rm -f /certs/ca.zip /certs/certs.zip
    chown -R 1000:0 /certs
    find /certs -type d -exec chmod 755 {} \;
    find /certs -type f -name "*.crt" -exec chmod 644 {} \;
    find /certs -type f -name "*.key" -exec chmod 640 {} \;
  '
  log "certificates in ./certs (CA: certs/ca/ca.crt)"
}

# ------------------------------------------------------------- 4. keystores --
gen_keystores() {
  mkdir -p "$SECRETS_DIR"

  if [[ ! -f "$SECRETS_DIR/elasticsearch.keystore" ]]; then
    log "creating elasticsearch.keystore (bootstrap.password)"
    "${RUNTIME[@]}" run --rm -u 0 -v "$SECRETS_DIR:/secrets${MOUNT_OPT:-}" \
      -e EP="$ELASTIC_PASSWORD" "$ES_IMAGE" bash -c '
        set -e
        cd /usr/share/elasticsearch
        rm -f config/elasticsearch.keystore
        bin/elasticsearch-keystore create >/dev/null
        printf "%s" "$EP" | bin/elasticsearch-keystore add -f -x bootstrap.password
        cp config/elasticsearch.keystore /secrets/elasticsearch.keystore
        chown 1000:0 /secrets/elasticsearch.keystore
        chmod 660 /secrets/elasticsearch.keystore
      '
  else
    log "elasticsearch.keystore already present, skipping"
  fi

  if [[ ! -f "$SECRETS_DIR/kibana.keystore" ]]; then
    log "creating kibana.keystore (es password + encryption keys)"
    "${RUNTIME[@]}" run --rm -u 0 -v "$SECRETS_DIR:/secrets${MOUNT_OPT:-}" \
      -e KP="$KIBANA_PASSWORD" \
      -e K_SO="$KBN_SO_KEY" -e K_REP="$KBN_REPORT_KEY" -e K_SEC="$KBN_SEC_KEY" \
      "$KB_IMAGE" bash -c '
        set -e
        cd /usr/share/kibana
        rm -f config/kibana.keystore
        bin/kibana-keystore create >/dev/null
        printf "%s" "$KP"   | bin/kibana-keystore add -f --stdin elasticsearch.password
        printf "%s" "$K_SO" | bin/kibana-keystore add -f --stdin xpack.encryptedSavedObjects.encryptionKey
        printf "%s" "$K_REP"| bin/kibana-keystore add -f --stdin xpack.reporting.encryptionKey
        printf "%s" "$K_SEC"| bin/kibana-keystore add -f --stdin xpack.security.encryptionKey
        cp config/kibana.keystore /secrets/kibana.keystore
        chown 1000:0 /secrets/kibana.keystore
        chmod 660 /secrets/kibana.keystore
      '
  else
    log "kibana.keystore already present, skipping"
  fi
}

# ------------------------------------------------------------- 5. bring-up --
wait_healthy() {
  local svc="$1" tries="${2:-90}" i status cid
  printf '    waiting for %s ' "$svc"
  for ((i=0; i<tries; i++)); do
    cid="$("${COMPOSE[@]}" ps -q "$svc" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      status="$("${RUNTIME[@]}" inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$cid" 2>/dev/null \
        || "${RUNTIME[@]}" inspect --format '{{.State.Healthcheck.Status}}' "$cid" 2>/dev/null \
        || echo starting)"
      case "$status" in
        healthy|running) printf ' %sok%s\n' "$c_grn" "$c_off"; return 0 ;;
        exited|dead) printf '\n'; "${COMPOSE[@]}" logs --tail 40 "$svc"; die "$svc exited" ;;
      esac
    fi
    printf '.'; sleep 2
  done
  printf '\n'; "${COMPOSE[@]}" logs --tail 60 "$svc"
  die "$svc did not become healthy in time"
}

# ---------------------------------------------------------- 6. provisioning --
# Calls the ES API from inside es01, so the CA and hostname always line up and
# the password never lands in the host's process table.
es_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    printf '%s' "$body" | "${COMPOSE[@]}" exec -T -e EP="$ELASTIC_PASSWORD" es01 sh -c \
      "curl -sS -X $method --cacert config/certs/ca/ca.crt -u \"elastic:\$EP\" \
       -H 'Content-Type: application/json' --data-binary @- 'https://localhost:9200$path'"
  else
    "${COMPOSE[@]}" exec -T -e EP="$ELASTIC_PASSWORD" es01 sh -c \
      "curl -sS -X $method --cacert config/certs/ca/ca.crt -u \"elastic:\$EP\" \
       'https://localhost:9200$path'"
  fi
}

check_response() {
  local what="$1" resp="$2"
  if printf '%s' "$resp" | grep -q '"error"'; then
    warn "$what failed:"
    dim "$resp"
    return 1
  fi
  log "$what ok"
}

provision() {
  step "Provisioning roles, users and API keys"

  local esc_kib esc_fl esc_tf
  esc_kib="$(json_escape "$KIBANA_PASSWORD")"
  esc_fl="$(json_escape "$FLUENTD_PASSWORD")"
  esc_tf="$(json_escape "$TERRAFORM_PASSWORD")"

  # -- kibana_system: must be set before Kibana starts ----------------------
  check_response "kibana_system password" \
    "$(es_api POST /_security/user/kibana_system/_password "{\"password\":\"${esc_kib}\"}")" || true

  # -- Fluentd writer -------------------------------------------------------
  # Terraform owns templates and ILM, so this role only gets auto_configure
  # plus write. It cannot manage index templates.
  check_response "role fluentd_writer" "$(es_api PUT /_security/role/fluentd_writer '{
    "cluster": ["monitor"],
    "indices": [{
      "names": ["fluentd-*", "logs-*"],
      "privileges": ["auto_configure","create_index","create_doc","write","view_index_metadata"]
    }]
  }')" || true

  check_response "user fluentd" "$(es_api PUT /_security/user/fluentd "{
    \"password\": \"${esc_fl}\",
    \"roles\": [\"fluentd_writer\"],
    \"full_name\": \"Fluentd log shipper\"
  }")" || true

  # -- Terraform / Detection-as-Code ---------------------------------------
  check_response "role dac_terraform" "$(es_api PUT /_security/role/dac_terraform '{
    "cluster": ["monitor","manage_index_templates","manage_ilm","manage_pipeline","manage_transform","manage_enrich"],
    "indices": [{
      "names": [".alerts-security*",".siem-signals-*",".lists-*",".items-*","logs-*","fluentd-*"],
      "privileges": ["all"]
    }],
    "applications": [{
      "application": "kibana-.kibana",
      "privileges": ["feature_siem.all","feature_savedObjectsManagement.all","feature_actions.all"],
      "resources": ["*"]
    }]
  }')" || true

  check_response "user terraform" "$(es_api PUT /_security/user/terraform "{
    \"password\": \"${esc_tf}\",
    \"roles\": [\"dac_terraform\"],
    \"full_name\": \"Terraform detection-as-code\"
  }")" || true

  provision_api_key
  write_outputs
}

provision_api_key() {
  local keyfile="$OUT_DIR/terraform/api_key"
  mkdir -p "$OUT_DIR/terraform"

  if [[ -f "$keyfile" && "$ROTATE_KEYS" != "yes" ]]; then
    TF_API_KEY="$(cat "$keyfile")"
    log "reusing existing Terraform API key (--rotate-keys to re-issue)"
    return
  fi

  if [[ "$ROTATE_KEYS" == "yes" ]]; then
    es_api DELETE /_security/api_key '{"name":"terraform-dac"}' >/dev/null || true
    log "invalidated previous terraform-dac keys"
  fi

  local resp
  resp="$(es_api POST /_security/api_key '{
    "name": "terraform-dac",
    "role_descriptors": {
      "dac_terraform": {
        "cluster": ["monitor","manage_index_templates","manage_ilm","manage_pipeline","manage_transform","manage_enrich"],
        "indices": [{
          "names": [".alerts-security*",".siem-signals-*",".lists-*",".items-*","logs-*","fluentd-*"],
          "privileges": ["all"]
        }]
      }
    },
    "metadata": {"managed_by":"deploy.sh","purpose":"detection-as-code"}
  }')"

  # "encoded" is the base64 id:api_key the Terraform provider expects.
  TF_API_KEY="$(printf '%s' "$resp" | sed -n 's/.*"encoded":"\([^"]*\)".*/\1/p')"
  if [[ -z "$TF_API_KEY" ]]; then
    warn "could not create Terraform API key:"
    dim "$resp"
    TF_API_KEY="<creation-failed>"
    return
  fi

  umask 077
  printf '%s' "$TF_API_KEY" > "$keyfile"
  chmod 600 "$keyfile"
  log "issued Terraform API key (shown once, saved to out/terraform/api_key)"
}

# --------------------------------------------------------------- 7. outputs --
write_outputs() {
  umask 077
  mkdir -p "$OUT_DIR/terraform" "$OUT_DIR/fluentd"

  cp "$CERTS_DIR/ca/ca.crt" "$OUT_DIR/fluentd/ca.crt"
  chmod 644 "$OUT_DIR/fluentd/ca.crt"

  cat > "$OUT_DIR/terraform/provider.tf" <<'EOF'
# Starting point for Detection-as-Code with the elastic/elasticstack provider.
# Values come from secrets.auto.tfvars, which deploy.sh regenerates.
#
# Note: the Kibana provider block is what drives detection rules, and it
# authenticates with username/password rather than an API key. The API key is
# used for the Elasticsearch block (index templates, ILM, ingest pipelines).

terraform {
  required_providers {
    elasticstack = {
      source  = "elastic/elasticstack"
      version = "~> 0.11"
    }
  }
}

variable "es_endpoint" { type = string }
variable "kibana_endpoint" { type = string }
variable "ca_file" { type = string }

variable "es_api_key" {
  type      = string
  sensitive = true
}

variable "kibana_username" { type = string }

variable "kibana_password" {
  type      = string
  sensitive = true
}

provider "elasticstack" {
  elasticsearch {
    endpoints = [var.es_endpoint]
    api_key   = var.es_api_key
    ca_file   = var.ca_file
  }

  kibana {
    endpoints = [var.kibana_endpoint]
    username  = var.kibana_username
    password  = var.kibana_password
    # The CA is self-signed. Either trust ca_file at the OS level, or set
    # insecure = true here for a lab deployment.
    # insecure = true
  }
}

# Example detection rule, delete once you have your own.
# resource "elasticstack_kibana_security_detection_rule" "example" {
#   name        = "Example - suspicious process"
#   type        = "query"
#   query       = "process.name : \"whoami\""
#   index       = ["logs-*", "fluentd-*"]
#   language    = "kuery"
#   enabled     = false
#   severity    = "low"
#   risk_score  = 21
#   description = "Managed by Terraform"
#   interval    = "5m"
#   from        = "now-6m"
# }
EOF
  chmod 644 "$OUT_DIR/terraform/provider.tf"

  cat > "$OUT_DIR/terraform/secrets.auto.tfvars" <<EOF
# Generated by deploy.sh. Contains secrets - do not commit.
es_endpoint     = "https://localhost:${ES_PORT}"
kibana_endpoint = "https://localhost:${KIBANA_PORT}"
ca_file         = "${CERTS_DIR}/ca/ca.crt"
es_api_key      = "${TF_API_KEY:-}"
kibana_username = "terraform"
kibana_password = "${TERRAFORM_PASSWORD}"
EOF
  chmod 600 "$OUT_DIR/terraform/secrets.auto.tfvars"

  cat > "$OUT_DIR/fluentd/forward-client.conf" <<EOF
# Drop this on any host that should ship logs into this stack.
# It forwards to the fluentd container, which does the TLS + auth to ES.
<match **>
  @type forward
  <server>
    host YOUR_DOCKER_HOST
    port ${FLUENTD_PORT}
  </server>
  <buffer>
    @type file
    path /var/log/fluent/forward-buffer
    flush_interval 5s
    retry_forever true
  </buffer>
</match>

# Alternatively, point a container's log driver straight at it:
#   "${RUNTIME[@]}" run --log-driver=fluentd \\
#     --log-opt fluentd-address=YOUR_DOCKER_HOST:${FLUENTD_PORT} \\
#     --log-opt tag=fluentd.myapp  myimage
EOF
  chmod 644 "$OUT_DIR/fluentd/forward-client.conf"

  cat > "$OUT_DIR/credentials.txt" <<EOF
Elastic single-node stack - generated $(date -u +%Y-%m-%dT%H:%M:%SZ)

Endpoints
  Elasticsearch   https://localhost:${ES_PORT}
  Kibana          https://localhost:${KIBANA_PORT}
  Fluentd forward tcp://localhost:${FLUENTD_PORT}
  CA certificate  ${CERTS_DIR}/ca/ca.crt

Accounts
  elastic         ${ELASTIC_PASSWORD}
  kibana_system   ${KIBANA_PASSWORD}
  terraform       ${TERRAFORM_PASSWORD}     (role: dac_terraform)
  fluentd         ${FLUENTD_PASSWORD}     (role: fluentd_writer)

Terraform API key (Elasticsearch provider block)
  ${TF_API_KEY:-<not issued>}

Quick check
  curl --cacert ${CERTS_DIR}/ca/ca.crt -u elastic:'${ELASTIC_PASSWORD}' \\
    https://localhost:${ES_PORT}/_cluster/health?pretty
EOF
  chmod 600 "$OUT_DIR/credentials.txt"
  log "wrote out/credentials.txt, out/terraform/, out/fluentd/"
}

# ------------------------------------------------------------- subcommands --
do_up() {
  preflight
  write_overrides
  load_config
  write_env

  step "Issuing certificates"
  gen_certs

  step "Building keystores"
  gen_keystores

  step "Starting Elasticsearch"
  "${COMPOSE[@]}" up -d es01
  wait_healthy es01 120

  provision

  step "Starting Kibana and Fluentd"
  "${COMPOSE[@]}" up -d kibana fluentd
  wait_healthy kibana 150

  step "Done"
  printf '  Kibana         %shttps://localhost:%s%s\n' "$c_grn" "$KIBANA_PORT" "$c_off"
  printf '  Elasticsearch  %shttps://localhost:%s%s\n' "$c_grn" "$ES_PORT" "$c_off"
  printf '  elastic / %s\n' "$ELASTIC_PASSWORD"
  dim "The CA is self-signed, so your browser will warn on first visit."
  dim "Full credentials: ./out/credentials.txt"
}

do_status() {
  load_config
  "${COMPOSE[@]}" ps
  printf '\n'
  if "${COMPOSE[@]}" exec -T -e EP="$ELASTIC_PASSWORD" es01 sh -c \
      "curl -sS --cacert config/certs/ca/ca.crt -u \"elastic:\$EP\" \
       'https://localhost:9200/_cluster/health?pretty'" 2>/dev/null; then :; else
    warn "Elasticsearch is not answering"
  fi
}

do_creds() {
  load_config
  [[ -f "$OUT_DIR/credentials.txt" ]] || die "no credentials yet, run: ./deploy.sh up"
  cat "$OUT_DIR/credentials.txt"
}

do_clean() {
  if [[ "$ASSUME_YES" != "yes" ]]; then
    warn "This destroys containers, volumes, certificates, keystores and all"
    warn "generated credentials, including the Terraform API key."
    read -r -p "Type 'destroy' to confirm: " reply
    [[ "$reply" == "destroy" ]] || die "aborted"
  fi
  "${COMPOSE[@]}" down -v --remove-orphans || true
  # Files chowned to uid 1000 inside a rootless container land on the host as
  # a subuid the invoking user cannot unlink, so unshare the namespace first.
  rm -f "$SCRIPT_DIR/compose.override.yml"
  if [[ "${RUNTIME[0]}" == "podman" ]] && podman unshare true 2>/dev/null; then
    podman unshare rm -rf "$CERTS_DIR" "$SECRETS_DIR" "$OUT_DIR" || true
  fi
  rm -rf "$CERTS_DIR" "$SECRETS_DIR" "$OUT_DIR" "$ENV_FILE" 2>/dev/null \
    || "${RUNTIME[@]}" run --rm -u 0 -v "$SCRIPT_DIR:/w${MOUNT_OPT:-}" alpine:3 \
       sh -c 'rm -rf /w/certs /w/secrets /w/out /w/.env'
  log "clean"
}

case "$CMD" in
  up)        do_up ;;
  provision) require_env; preflight; write_overrides; load_config; write_env; provision ;;
  status)    require_env; detect_engine; detect_rootless; write_overrides; do_status ;;
  creds)     require_env; do_creds ;;
  clean)     detect_engine; detect_selinux; do_clean ;;
esac
