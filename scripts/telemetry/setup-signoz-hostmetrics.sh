#!/usr/bin/env bash
set -euo pipefail

# ========= Easy defaults (override via env or edit here) =========
SIG_HOST="${SIG_HOST:-127.0.0.1}"          # SigNoz OTLP receiver host (your signoz-otel-collector)
SIG_PORT="${SIG_PORT:-4317}"               # 4317 (gRPC) or 4318 (HTTP)
SIG_PROTOCOL="${SIG_PROTOCOL:-grpc}"       # grpc | http
SIG_INSECURE="${SIG_INSECURE:-true}"       # true | false
SIG_ENV="${SIG_ENV:-prod}"                 # deployment.environment tag

SIG_NS_HOST="${SIG_NS_HOST:-host}"         # service.namespace for host metrics
SIG_NS_DOCKER="${SIG_NS_DOCKER:-docker}"   # service.namespace for docker logs
COLLECTION_INTERVAL="${COLLECTION_INTERVAL:-30s}"

# otelcol-contrib version and arch
OTEL_VERSION="${OTEL_VERSION:-0.128.0}"

# Noise controls
ENABLE_DOCKER_LOGS="${ENABLE_DOCKER_LOGS:-true}"     # keep docker logs (low-noise)
ENABLE_JOURNALD_LOGS="${ENABLE_JOURNALD_LOGS:-false}"
ENABLE_NOISE_FILTERS="${ENABLE_NOISE_FILTERS:-true}"

# Optional container name filters (regex on filename path not supported; these are for future journald/other receivers)
DOCKER_INCLUDE_CONTAINERS_REGEX="${DOCKER_INCLUDE_CONTAINERS_REGEX:-}"
DOCKER_EXCLUDE_CONTAINERS_REGEX="${DOCKER_EXCLUDE_CONTAINERS_REGEX:-}"

# ========= Paths / names =========
CONF_DIR="/etc/otelcol"
CONF_FILE="${CONF_DIR}/host.yaml"
BIN_PATH="/usr/local/bin/otelcol-contrib"
SVC_NAME="otelcol-host"

# ========= Require sudo/root =========
if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo (this script writes to /usr/local/bin and systemd)."
  exit 1
fi

HOSTNAME_VAL="$(hostname)"

# ========= Detect arch for the right tarball =========
ARCH_RAW="$(uname -m)"
case "${ARCH_RAW}" in
  x86_64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: ${ARCH_RAW}"
    exit 1
    ;;
esac

cat <<INFO
==> SigNoz Host Agent Installer
    Host:                 ${SIG_HOST}
    OTLP protocol:        ${SIG_PROTOCOL}
    OTLP endpoint:        ${SIG_HOST}:${SIG_PORT}
    Insecure TLS:         ${SIG_INSECURE}
    Env tag:              ${SIG_ENV}
    Service ns (host):    ${SIG_NS_HOST}
    Service ns (docker):  ${SIG_NS_DOCKER}
    Interval:             ${COLLECTION_INTERVAL}
    otelcol-contrib ver:  ${OTEL_VERSION} (${ARCH})
    Docker logs:          ${ENABLE_DOCKER_LOGS}
    journald logs:        ${ENABLE_JOURNALD_LOGS}
INFO

# ========= Install otelcol-contrib =========
mkdir -p "${CONF_DIR}" /opt/otelcol
TARBALL="otelcol-contrib_${OTEL_VERSION}_linux_${ARCH}.tar.gz"
URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${TARBALL}"

echo "==> Downloading ${URL}"
curl -fsSL "${URL}" -o "/opt/otelcol/${TARBALL}"
tar -C /opt/otelcol -xzf "/opt/otelcol/${TARBALL}" otelcol-contrib
install -m0755 /opt/otelcol/otelcol-contrib "${BIN_PATH}"

# ========= Build config =========
: > "${CONF_FILE}"

# --- Receivers: hostmetrics always on
cat >> "${CONF_FILE}" <<EOF
receivers:
  hostmetrics:
    collection_interval: ${COLLECTION_INTERVAL}
    scrapers:
      cpu: {}
      memory: {}
      load: {}
      filesystem: {}
      network: {}
      disk: {}
      processes: {}
EOF

# --- Optional: Docker logs via filelog (json-file driver)
if [[ "${ENABLE_DOCKER_LOGS}" == "true" ]]; then
  if [[ ! -S /var/run/docker.sock ]]; then
    echo "WARNING: /var/run/docker.sock not found. Docker logs may be empty on this host."
  fi

  cat >> "${CONF_FILE}" <<'EOF'

  filelog/docker:
    include: [ /var/lib/docker/containers/*/*-json.log ]
    start_at: end
    include_file_path: true
    poll_interval: 1s
    operators:
      # Docker json-file format: {"log":"line","stream":"stdout|stderr","time":"..."}
      - type: json_parser
        parse_from: body
        on_error: send
      - type: move
        from: attributes.log
        to: body
      - type: timestamp
        parse_from: attributes.time
        layout: RFC3339Nano
      - type: remove
        field: attributes.time
      # container.id from file path
      - type: regex_parser
        parse_from: attributes["log.file.path"]
        regex: '^.*/(?P<container_id>[0-9a-f]{64})-json\.log$'
EOF
fi

# --- Optional: journald (usually not needed if using Docker json-file)
if [[ "${ENABLE_JOURNALD_LOGS}" == "true" ]]; then
  cat >> "${CONF_FILE}" <<'EOF'

  journald:
    directory: /var/log/journal
    units:
      - docker.service
      - containerd.service
    start_at: end
EOF
fi

# --- Processors
cat >> "${CONF_FILE}" <<EOF

processors:
  # Attach host info first
  resourcedetection/system:
    detectors: [system]
    system:
      hostname_sources: [os]

  # Tag docker logs & promote container.id into resource attrs
  resource/docker:
    attributes:
      - action: upsert
        key: service.namespace
        value: "${SIG_NS_DOCKER}"
      - action: upsert
        key: host.name
        value: "${HOSTNAME_VAL}"
      - action: upsert
        key: deployment.environment
        value: "${SIG_ENV}"
      - action: upsert
        key: container.id
        from_attribute: container_id
EOF

if [[ "${ENABLE_NOISE_FILTERS}" == "true" ]]; then
  # Keep only error-ish lines OR stderr, then drop common noise
  cat >> "${CONF_FILE}" <<'EOF'

  filter/docker_keep:
    logs:
      include:
        match_type: expr
        expressions:
          - 'IsMatch(body, "(?i)(error|warn|exception|traceback)") or attributes["stream"] == "stderr"'

  filter/docker_drop_noise:
    logs:
      exclude:
        match_type: regexp
        bodies:
          - 'GET /(health|healthz|readyz|livez)(\?| |$)'
          - 'GET /metrics'
          - '^DEBUG\b'
          - '^{"level":"debug"'
EOF
fi

# Memory/batch common
cat >> "${CONF_FILE}" <<'EOF'

  memory_limiter:
    check_interval: 5s
    limit_mib: 512
    spike_limit_mib: 256

  batch:
    send_batch_size: 1024
    timeout: 5s
EOF

# --- Exporters
if [[ "${SIG_PROTOCOL}" == "grpc" ]]; then
  cat >> "${CONF_FILE}" <<EOF

exporters:
  otlp:
    endpoint: ${SIG_HOST}:${SIG_PORT}
    tls:
      insecure: ${SIG_INSECURE}
EOF
  LOGS_EXPORTER="otlp"
  METRICS_EXPORTER="otlp"
else
  cat >> "${CONF_FILE}" <<EOF

exporters:
  otlphttp:
    endpoint: http://${SIG_HOST}:${SIG_PORT}
    tls:
      insecure: ${SIG_INSECURE}
EOF
  LOGS_EXPORTER="otlphttp"
  METRICS_EXPORTER="otlphttp"
fi

# --- Service (pipelines)
cat >> "${CONF_FILE}" <<EOF

service:
  pipelines:
    metrics/host:
      receivers: [hostmetrics]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [${METRICS_EXPORTER}]
EOF

if [[ "${ENABLE_DOCKER_LOGS}" == "true" ]]; then
  if [[ "${ENABLE_NOISE_FILTERS}" == "true" ]]; then
    cat >> "${CONF_FILE}" <<EOF
    logs/docker:
      receivers: [filelog/docker]
      processors: [resourcedetection/system, resource/docker, filter/docker_keep, filter/docker_drop_noise, memory_limiter, batch]
      exporters: [${LOGS_EXPORTER}]
EOF
  else
    cat >> "${CONF_FILE}" <<EOF
    logs/docker:
      receivers: [filelog/docker]
      processors: [resourcedetection/system, resource/docker, memory_limiter, batch]
      exporters: [${LOGS_EXPORTER}]
EOF
  fi
fi

if [[ "${ENABLE_JOURNALD_LOGS}" == "true" ]]; then
  cat >> "${CONF_FILE}" <<EOF
    logs/journald:
      receivers: [journald]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [${LOGS_EXPORTER}]
EOF
fi

cat >> "${CONF_FILE}" <<'EOF'
  telemetry:
    logs:
      level: warn
EOF

# ========= Systemd unit =========
cat > "/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=OpenTelemetry Collector (Host metrics + Docker logs -> SigNoz)
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=${BIN_PATH} --config=${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
# Increase file handles for log tailing
LimitNOFILE=262144

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SVC_NAME}"
systemctl restart "${SVC_NAME}"

echo "
✅ Installed & started ${SVC_NAME}
   Config : ${CONF_FILE}
   Logs   : journalctl -u ${SVC_NAME} -n 80 --no-pager
   Binary : ${BIN_PATH}

Search tips in SigNoz (Logs):
- Filter: service.namespace=\"${SIG_NS_DOCKER}\"
- Facets: container.id (you can pin it), host.name, deployment.environment
"

