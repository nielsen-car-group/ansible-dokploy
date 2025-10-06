#!/usr/bin/env bash
set -euo pipefail

# ======= Easy defaults (override via env or edit below) =======
SIG_HOST="${SIG_HOST:-127.0.0.1}"
SIG_PORT="${SIG_PORT:-4317}"              # 4317 (gRPC) or 4318 (HTTP)
SIG_PROTOCOL="${SIG_PROTOCOL:-grpc}"      # grpc|http
SIG_INSECURE="${SIG_INSECURE:-true}"      # true|false
SIG_ENV="${SIG_ENV:-prod}"

SIG_NS_HOST="${SIG_NS_HOST:-host}"        # namespace for host metrics
SIG_NS_DOCKER="${SIG_NS_DOCKER:-docker}"  # namespace for docker logs
COLLECTION_INTERVAL="${COLLECTION_INTERVAL:-30s}"

OTEL_VERSION="${OTEL_VERSION:-0.128.0}"

ENABLE_DOCKER_LOGS="${ENABLE_DOCKER_LOGS:-true}"
ENABLE_JOURNALD_LOGS="${ENABLE_JOURNALD_LOGS:-false}"
ENABLE_NOISE_FILTERS="${ENABLE_NOISE_FILTERS:-true}"

DOCKER_EXCLUDE_CONTAINERS_REGEX="${DOCKER_EXCLUDE_CONTAINERS_REGEX:-}"
DOCKER_INCLUDE_CONTAINERS_REGEX="${DOCKER_INCLUDE_CONTAINERS_REGEX:-}"

CONF_DIR="/etc/otelcol"
CONF_FILE="${CONF_DIR}/host.yaml"
BIN_PATH="/usr/local/bin/otelcol-contrib"
SVC_NAME="otelcol-host"

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo."; exit 1
fi

HOSTNAME_VAL="$(hostname)"

echo "==> SigNoz Host Agent Installer
    Host:                 ${SIG_HOST}
    OTLP protocol:        ${SIG_PROTOCOL}
    OTLP endpoint:        ${SIG_HOST}:${SIG_PORT}
    Insecure TLS:         ${SIG_INSECURE}
    Env tag:              ${SIG_ENV}
    Service ns (host):    ${SIG_NS_HOST}
    Service ns (docker):  ${SIG_NS_DOCKER}
    Interval:             ${COLLECTION_INTERVAL}
    otelcol-contrib ver:  ${OTEL_VERSION}
    Docker logs:          ${ENABLE_DOCKER_LOGS}
    journald logs:        ${ENABLE_JOURNALD_LOGS}
"

mkdir -p "${CONF_DIR}" /opt/otelcol

# ---- Install otelcol-contrib ----
TARBALL="otelcol-contrib_${OTEL_VERSION}_linux_amd64.tar.gz"
URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${TARBALL}"
echo "==> Downloading ${URL}"
curl -fsSL "${URL}" -o "/opt/otelcol/${TARBALL}"
tar -C /opt/otelcol -xzf "/opt/otelcol/${TARBALL}" otelcol-contrib
install -m0755 /opt/otelcol/otelcol-contrib "${BIN_PATH}"

# ---- Build config ----
: > "${CONF_FILE}"

# Receivers
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

if [[ "${ENABLE_DOCKER_LOGS}" == "true" ]]; then
  [[ -S /var/run/docker.sock ]] || echo "WARNING: /var/run/docker.sock not found."
  cat >> "${CONF_FILE}" <<EOF

  docker:
    endpoint: unix:///var/run/docker.sock
    start_at: end
    operators:
      - type: json_parser
        parse_from: body
        on_error: send
      - type: move
        from: attributes.log
        to: body
      - type: add
        field: resource["service.namespace"]
        value: "${SIG_NS_DOCKER}"
      - type: add
        field: resource["host.name"]
        value: "${HOSTNAME_VAL}"
      - type: add
        field: resource["deployment.environment"]
        value: "${SIG_ENV}"
EOF

  if [[ -n "${DOCKER_INCLUDE_CONTAINERS_REGEX}" ]]; then
    cat >> "${CONF_FILE}" <<EOF
    include_containers:
      name_regex: "${DOCKER_INCLUDE_CONTAINERS_REGEX}"
EOF
  fi

  if [[ -n "${DOCKER_EXCLUDE_CONTAINERS_REGEX}" ]]; then
    cat >> "${CONF_FILE}" <<EOF
    exclude_containers:
      name_regex: "${DOCKER_EXCLUDE_CONTAINERS_REGEX}"
EOF
  fi
fi

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

# Processors
if [[ "${ENABLE_NOISE_FILTERS}" == "true" ]]; then
  cat >> "${CONF_FILE}" <<'EOF'

processors:
  filter/docker_noise:
    logs:
      exclude:
        match_type: regexp
        bodies:
          - 'GET /(health|healthz|readyz|livez)(\?| |$)'
          - 'GET /metrics'
          - '^DEBUG\b'
          - '^{"level":"debug"'
  memory_limiter:
    check_interval: 5s
    limit_mib: 512
    spike_limit_mib: 256
  batch:
    send_batch_size: 1024
    timeout: 5s
EOF
else
  cat >> "${CONF_FILE}" <<'EOF'

processors:
  memory_limiter:
    check_interval: 5s
    limit_mib: 512
    spike_limit_mib: 256
  batch:
    send_batch_size: 1024
    timeout: 5s
EOF
fi

# Exporters
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

# Service
cat >> "${CONF_FILE}" <<EOF

service:
  pipelines:
    metrics/host:
      receivers: [hostmetrics]
      processors: [memory_limiter, batch]
      exporters: [${METRICS_EXPORTER}]
EOF

if [[ "${ENABLE_DOCKER_LOGS}" == "true" ]]; then
  if [[ "${ENABLE_NOISE_FILTERS}" == "true" ]]; then
    cat >> "${CONF_FILE}" <<EOF
    logs/docker:
      receivers: [docker]
      processors: [filter/docker_noise, memory_limiter, batch]
      exporters: [${LOGS_EXPORTER}]
EOF
  else
    cat >> "${CONF_FILE}" <<EOF
    logs/docker:
      receivers: [docker]
      processors: [memory_limiter, batch]
      exporters: [${LOGS_EXPORTER}]
EOF
  fi
fi

if [[ "${ENABLE_JOURNALD_LOGS}" == "true" ]]; then
  cat >> "${CONF_FILE}" <<EOF
    logs/journald:
      receivers: [journald]
      processors: [memory_limiter, batch]
      exporters: [${LOGS_EXPORTER}]
EOF
fi

cat >> "${CONF_FILE}" <<'EOF'
  telemetry:
    logs:
      level: warn
EOF

# ---- systemd unit ----
cat > "/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=OpenTelemetry Collector (Host metrics + Docker logs -> SigNoz)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=${BIN_PATH} --config=${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
# Access to docker.sock (this directive may be ignored on older systemd)
BindPaths=/var/run/docker.sock
LimitNOFILE=131072

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SVC_NAME}"
systemctl restart "${SVC_NAME}"

echo "
✅ Installed & started ${SVC_NAME}
   Config : ${CONF_FILE}
   Logs   : journalctl -u ${SVC_NAME} -f
   Binary : ${BIN_PATH}

Tips:
- In SigNoz Logs, filter by resource.service.namespace=\"${SIG_NS_DOCKER}\"
  and facet on resource.container.name to find a container quickly.
"

