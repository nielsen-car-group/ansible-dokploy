#!/usr/bin/env bash
set -euo pipefail

# ======= Easy defaults (override via env or edit below) =======
SIG_HOST="${SIG_HOST:-127.0.0.1}"         # SigNoz collector host (use private IP for remote VPS)
SIG_PORT="${SIG_PORT:-4317}"              # 4317 (gRPC) or 4318 (HTTP)
SIG_PROTOCOL="${SIG_PROTOCOL:-grpc}"      # grpc|http
SIG_INSECURE="${SIG_INSECURE:-true}"      # true|false (set false if you terminate TLS at collector)
SIG_ENV="${SIG_ENV:-prod}"                # deployment.environment tag
SIG_NS_HOST="${SIG_NS_HOST:-host}"        # service.namespace for host metrics
COLLECTION_INTERVAL="${COLLECTION_INTERVAL:-30s}"
OTEL_VERSION="${OTEL_VERSION:-0.128.0}"   # otelcol-contrib release (no leading 'v')

CONF_DIR="/etc/otelcol"
CONF_FILE="${CONF_DIR}/host.yaml"
BIN_PATH="/usr/local/bin/otelcol-contrib"
SVC_NAME="otelcol-host"

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo."; exit 1
fi

# ---- arch detect (linux only) ----
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: ${ARCH_RAW}"; exit 1
    ;;
esac

HOSTNAME_VAL="$(hostname)"

echo "==> SigNoz Host Agent Installer
    Host:                 ${SIG_HOST}
    OTLP protocol:        ${SIG_PROTOCOL}
    OTLP endpoint:        ${SIG_HOST}:${SIG_PORT}
    Insecure TLS:         ${SIG_INSECURE}
    Env tag:              ${SIG_ENV}
    Service ns (host):    ${SIG_NS_HOST}
    Interval:             ${COLLECTION_INTERVAL}
    otelcol-contrib ver:  ${OTEL_VERSION}
"

# Create dirs
mkdir -p "${CONF_DIR}" /opt/otelcol

# Optional quick connectivity hint (doesn't fail install)
if command -v timeout >/dev/null 2>&1; then
  if timeout 2 bash -c ":</dev/tcp/${SIG_HOST}/${SIG_PORT}" 2>/dev/null; then
    echo "=> Connectivity check: ${SIG_HOST}:${SIG_PORT} reachable"
  else
    echo "=> WARNING: Cannot reach ${SIG_HOST}:${SIG_PORT} right now (continuing anyway)"
  fi
fi

# ---- Install otelcol-contrib ----
TARBALL="otelcol-contrib_${OTEL_VERSION}_linux_${ARCH}.tar.gz"
URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${TARBALL}"
echo "==> Downloading ${URL}"
curl -fsSL "${URL}" -o "/opt/otelcol/${TARBALL}"
tar -C /opt/otelcol -xzf "/opt/otelcol/${TARBALL}" otelcol-contrib
install -m0755 /opt/otelcol/otelcol-contrib "${BIN_PATH}"

# ---- Build config (metrics only) ----
cat > "${CONF_FILE}" <<EOF
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

processors:
  resourcedetection/system:
    detectors: [system]
    system:
      hostname_sources: [os]
  resource/default:
    attributes:
      - action: upsert
        key: service.namespace
        value: "${SIG_NS_HOST}"
      - action: upsert
        key: deployment.environment
        value: "${SIG_ENV}"
      - action: upsert
        key: host.name
        value: "${HOSTNAME_VAL}"
  memory_limiter:
    check_interval: 5s
    limit_mib: 512
    spike_limit_mib: 256
  batch:
    send_batch_size: 1024
    timeout: 5s
EOF

# Exporters
if [[ "${SIG_PROTOCOL}" == "grpc" ]]; then
  cat >> "${CONF_FILE}" <<EOF

exporters:
  otlp:
    endpoint: ${SIG_HOST}:${SIG_PORT}
    tls:
      insecure: ${SIG_INSECURE}
EOF
  METRICS_EXPORTER="otlp"
else
  cat >> "${CONF_FILE}" <<EOF

exporters:
  otlphttp:
    endpoint: http://${SIG_HOST}:${SIG_PORT}
    tls:
      insecure: ${SIG_INSECURE}
EOF
  METRICS_EXPORTER="otlphttp"
fi

# Service (metrics-only)
cat >> "${CONF_FILE}" <<EOF

service:
  pipelines:
    metrics/host:
      receivers: [hostmetrics]
      processors: [resourcedetection/system, resource/default, memory_limiter, batch]
      exporters: [${METRICS_EXPORTER}]

  telemetry:
    logs:
      level: warn
EOF

# ---- systemd unit ----
cat > "/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=OpenTelemetry Collector (Host metrics -> SigNoz)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=${BIN_PATH} --config=${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
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

Tip: In SigNoz UI (Infrastructure → Hosts), this machine should appear within ~1–2 minutes.
"

