#!/usr/bin/env bash
set -euo pipefail

############################
# Easy-to-tweak defaults  ##
############################
# You can override any of these by exporting the var before running the script:
#   SIG_HOST=10.0.0.5 SIG_PROTOCOL=grpc sudo ./setup-signoz-host.sh

# Where your SigNoz OTLP endpoint lives (collector service, not the UI)
SIG_HOST="${SIG_HOST:-127.0.0.1}"
SIG_PORT="${SIG_PORT:-4317}"             # 4317 for gRPC, 4318 for HTTP
SIG_PROTOCOL="${SIG_PROTOCOL:-grpc}"     # grpc | http
SIG_INSECURE="${SIG_INSECURE:-true}"     # true | false (TLS)
SIG_ENV="${SIG_ENV:-prod}"               # deployment.environment tag
SIG_NS_HOST="${SIG_NS_HOST:-host}"       # service.namespace for host metrics
SIG_NS_DOCKER="${SIG_NS_DOCKER:-docker}" # service.namespace for docker logs
COLLECTION_INTERVAL="${COLLECTION_INTERVAL:-30s}"

# otelcol-contrib binary version to install
OTEL_VERSION="${OTEL_VERSION:-0.128.0}"

# Logging choices
ENABLE_DOCKER_LOGS="${ENABLE_DOCKER_LOGS:-true}"     # Collect all Docker container logs via Docker API
ENABLE_JOURNALD_LOGS="${ENABLE_JOURNALD_LOGS:-false}"# System logs (journald)
ENABLE_NOISE_FILTERS="${ENABLE_NOISE_FILTERS:-true}" # Drop common health/metrics/debug noise
# Optional: drop entire containers by name (regex). Empty = drop none.
DOCKER_EXCLUDE_CONTAINERS_REGEX="${DOCKER_EXCLUDE_CONTAINERS_REGEX:-}"
# Optional: include only containers by name (regex). Empty = include all.
DOCKER_INCLUDE_CONTAINERS_REGEX="${DOCKER_INCLUDE_CONTAINERS_REGEX:-}"

# Where to put files
CONF_DIR="/etc/otelcol"
BIN_PATH="/usr/local/bin/otelcol-contrib"
SVC_NAME="otelcol-host"
CONF_FILE="${CONF_DIR}/host.yaml"

############################
# Pre-flight               ##
############################
if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo (this script needs root privileges). ❌"
  exit 1
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

mkdir -p "${CONF_DIR}"
mkdir -p /opt/otelcol

############################
# Install otelcol-contrib  ##
############################
TARBALL="otelcol-contrib_${OTEL_VERSION}_linux_amd64.tar.gz"
URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${TARBALL}"

echo "==> Downloading ${URL}"
curl -fsSL "${URL}" -o "/opt/otelcol/${TARBALL}"
tar -C /opt/otelcol -xzf "/opt/otelcol/${TARBALL}" otelcol-contrib
install -m 0755 /opt/otelcol/otelcol-contrib "${BIN_PATH}"

############################
# Build exporter block     ##
############################
if [[ "${SIG_PROTOCOL}" == "grpc" ]]; then
  EXPORTER_BLOCK=$(cat <<EOF
exporters:
  otlp:
    endpoint: ${SIG_HOST}:${SIG_PORT}
    tls:
      insecure: ${SIG_INSECURE}
EOF
)
  LOGS_EXPORTER_NAME="otlp"
  METRICS_EXPORTER_NAME="otlp"
else
  # http
  EXPORTER_BLOCK=$(cat <<EOF
exporters:
  otlphttp:
    endpoint: http://${SIG_HOST}:${SIG_PORT}
    tls:
      insecure: ${SIG_INSECURE}
EOF
)
  LOGS_EXPORTER_NAME="otlphttp"
  METRICS_EXPORTER_NAME="otlphttp"
fi

############################
# Receivers: host + docker ##
############################
# Host metrics receiver
HOSTMETRICS_BLOCK=$(cat <<EOF
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
)

# Docker logs receiver via Docker Engine API (adds container.name, image, labels)
DOCKER_BLOCK=""
if [[ "${ENABLE_DOCKER_LOGS}" == "true" ]]; then
  if [[ ! -S /var/run/docker.sock ]]; then
    echo "WARNING: /var/run/docker.sock not found. Docker logs receiver will fail. (Is Docker installed on this host?)"
  fi

  # Optional include/exclude by name
  DOCKER_FILTERS=""
  if [[ -n "${DOCKER_INCLUDE_CONTAINERS_REGEX}" ]]; then
    DOCKER_FILTERS+="\n      include_containers:\n        name_regex: \"${DOCKER_INCLUDE_CONTAINERS_REGEX}\""
  fi
  if [[ -n "${DOCKER_EXCLUDE_CONTAINERS_REGEX}" ]]; then
    DOCKER_FILTERS+="\n      exclude_containers:\n        name_regex: \"${DOCKER_EXCLUDE_CONTAINERS_REGEX}\""
  fi

  DOCKER_BLOCK=$(cat <<EOF
  docker:
    endpoint: unix:///var/run/docker.sock
    start_at: end
    operators:
      # Docker log line is typically raw text or JSON. Try to parse JSON, fall back to text.
      - type: json_parser
        parse_from: body
        on_error: send
      - type: move
        from: attributes.log
        to: body
      # Mark logs as docker + attach host/resource tags
      - type: add
        field: resource["service.namespace"]
        value: "${SIG_NS_DOCKER}"
      - type: add
        field: resource["host.name"]
        value: "${HOSTNAME_VAL}"
      - type: add
        field: resource["deployment.environment"]
        value: "${SIG_ENV}"${DOCKER_FILTERS}
EOF
)
fi

# journald logs (disabled by default)
JOURNALD_BLOCK=""
if [[ "${ENABLE_JOURNALD_LOGS}" == "true" ]]; then
  JOURNALD_BLOCK=$(cat <<'EOF'
  journald:
    directory: /var/log/journal
    units:
      - docker.service
      - containerd.service
    start_at: end
EOF
)
fi

############################
# Processors (noise, batch)##
############################
FILTER_BLOCK=""
if [[ "${ENABLE_NOISE_FILTERS}" == "true" ]]; then
  # These are safe defaults – adjust as you like
  FILTER_BLOCK=$(cat <<'EOF'
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
)
else
  FILTER_BLOCK=$(cat <<'EOF'
processors:
  memory_limiter:
    check_interval: 5s
    limit_mib: 512
    spike_limit_mib: 256
  batch:
    send_batch_size: 1024
    timeout: 5s
EOF
)
fi

############################
# Final config YAML        ##
############################
cat > "${CONF_FILE}" <<EOF
# Generated by setup-signoz-host.sh
${HOSTMETRICS_BLOCK}
${DOCKER_BLOCK:+receivers:
${DOCKER_BLOCK#receivers:}
}
${JOURNALD_BLOCK:+receivers:
${JOURNALD_BLOCK#receivers:}
}
${FILTER_BLOCK}
${EXPORTER_BLOCK}

service:
  pipelines:
    metrics/host:
      receivers: [hostmetrics]
      processors: [memory_limiter, batch]
      exporters: [${METRICS_EXPORTER_NAME}]
$( if [[ "${ENABLE_DOCKER_LOGS}" == "true" ]]; then
cat <<PIPE
    logs/docker:
      receivers: [docker]
      processors: [$( [[ "${ENABLE_NOISE_FILTERS}" == "true" ]] && echo "filter/docker_noise," ) memory_limiter, batch]
      exporters: [${LOGS_EXPORTER_NAME}]
PIPE
fi )
$( if [[ "${ENABLE_JOURNALD_LOGS}" == "true" ]]; then
cat <<PIPE
    logs/journald:
      receivers: [journald]
      processors: [memory_limiter, batch]
      exporters: [${LOGS_EXPORTER_NAME}]
PIPE
fi )
  telemetry:
    logs:
      level: warn
EOF

############################
# Systemd service          ##
############################
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
# Access to docker.sock
BindPaths=/var/run/docker.sock
# Reasonable limits
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
- In SigNoz » Logs, filter by resource.service.namespace=\"${SIG_NS_DOCKER}\"
  and facet on resource.container.name to pick a specific container quickly.
- To tune noise filters, edit processors.filter/docker_noise in ${CONF_FILE} and:
    sudo systemctl restart ${SVC_NAME}
"

