#!/usr/bin/env bash
# Installs OpenTelemetry Collector (contrib) as a host agent that sends host metrics to SigNoz.
# Docs: https://signoz.io/docs/userguide/hostmetrics/
# Usage (example):
#   sudo SIGNOZ_OTLP_ENDPOINT="your.signoz.domain:4317" ./install-signoz-hostmetrics.sh
#   # or HTTP OTLP:
#   sudo SIGNOZ_OTLP_ENDPOINT="http://your.signoz.domain:4318" ./install-signoz-hostmetrics.sh

set -euo pipefail

# ---------- Configurable via env ----------
: "${SIGNOZ_OTLP_ENDPOINT:?Set SIGNOZ_OTLP_ENDPOINT to your SigNoz OTLP endpoint, e.g. 'your.domain:4317' or 'http://your.domain:4318'}"
SIGNOZ_USE_GRPC=${SIGNOZ_USE_GRPC:-"true"}         # "true" -> gRPC (4317); "false" -> HTTP (4318)
SIGNOZ_INSECURE=${SIGNOZ_INSECURE:-"true"}         # "true" if your 4317/4318 are not TLS-terminated
SIGNOZ_ENV=${SIGNOZ_ENV:-"prod"}                   # environment tag
SERVICE_NAMESPACE=${SERVICE_NAMESPACE:-"host"}     # resource.service.namespace
OTEL_USER=${OTEL_USER:-"otelcol"}                  # system user for the service

# ---------- Detect OS / Arch ----------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2; exit 1
fi

OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
OS_VERSION_ID=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
ARCH=$(uname -m)

case "$ARCH" in
  x86_64)  TARCH="amd64" ;;
  aarch64|arm64) TARCH="arm64" ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# ---------- Install prerequisites ----------
case "$OS_ID" in
  ubuntu|debian|raspbian)
    apt-get update -y >/dev/null
    apt-get install -y curl wget tar ca-certificates >/dev/null
    ;;
  centos|rhel|rocky|almalinux|ol|amzn|fedora)
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y curl wget tar ca-certificates >/dev/null
    else
      yum install -y curl wget tar ca-certificates >/dev/null
    fi
    ;;
  alpine)
    apk add --no-cache curl wget tar ca-certificates >/dev/null
    ;;
  arch|manjaro|archarm)
    pacman -Sy --noconfirm --needed curl wget tar ca-certificates >/dev/null
    ;;
  *)
    echo "Unsupported Linux distro: $OS_ID" >&2; exit 1
    ;;
esac

# ---------- Install otelcol-contrib ----------
OTEL_VERSION=${OTEL_VERSION:-"0.128.0"}  # keep in sync with SigNoz docs when you want
BIN_DIR="/usr/local/bin"
INSTALL_DIR="/opt/otelcol"
CONF_DIR="/etc/otelcol"
DATA_DIR="/var/lib/otelcol"
SVC_NAME="otelcol-hostmetrics"

mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$DATA_DIR"

# Download static tarball
TARBALL="otelcol-contrib_${OTEL_VERSION}_linux_${TARCH}.tar.gz"
URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${TARBALL}"

echo "Downloading $URL ..."
curl -fsSL "$URL" -o "/tmp/${TARBALL}"
tar -xzf "/tmp/${TARBALL}" -C "$INSTALL_DIR"
install -m 0755 "$INSTALL_DIR/otelcol-contrib" "$BIN_DIR/otelcol-contrib"

# Create user if not exists
if ! id -u "$OTEL_USER" >/dev/null 2>&1; then
  useradd --no-create-home --system --shell /usr/sbin/nologin "$OTEL_USER"
fi

chown -R "$OTEL_USER":"$OTEL_USER" "$INSTALL_DIR" "$CONF_DIR" "$DATA_DIR"

# ---------- Generate config ----------
HOSTNAME_VAL=$(hostname -f || hostname)

cat > "${CONF_DIR}/hostmetrics.yaml" <<EOF
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
      disk:
      filesystem:
      load:
      memory:
      network:
      paging:
      processes:

processors:
  batch:
  resourcedetection:
    detectors: [system]
    override: true
  resource:
    attributes:
      - key: service.name
        value: "${HOSTNAME_VAL}"
        action: upsert
      - key: service.namespace
        value: "${SERVICE_NAMESPACE}"
        action: upsert
      - key: deployment.environment
        value: "${SIGNOZ_ENV}"
        action: upsert

exporters:
  # gRPC (4317)
  otlp:
    endpoint: "${SIGNOZ_OTLP_ENDPOINT}"
    tls:
      insecure: ${SIGNOZ_INSECURE}
  # HTTP (4318)
  otlphttp:
    endpoint: "${SIGNOZ_OTLP_ENDPOINT}"
    tls:
      insecure: ${SIGNOZ_INSECURE}

service:
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [resourcedetection, resource, batch]
      exporters: [${SIGNOZ_USE_GRPC,,} == "true" ? "otlp" : "otlphttp"]
EOF

# sed trick to evaluate which exporter to keep
if [[ "${SIGNOZ_USE_GRPC,,}" == "true" ]]; then
  # keep otlp, remove otlphttp from the pipeline list
  sed -i 's/exporters: \[${SIGNOZ_USE_GRPC,,} == "true" ? "otlp" : "otlphttp"\]/exporters: \[otlp\]/' "${CONF_DIR}/hostmetrics.yaml"
else
  sed -i 's/exporters: \[${SIGNOZ_USE_GRPC,,} == "true" ? "otlp" : "otlphttp"\]/exporters: \[otlphttp\]/' "${CONF_DIR}/hostmetrics.yaml"
fi

# ---------- systemd unit ----------
cat > "/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=OpenTelemetry Collector (hostmetrics -> SigNoz)
After=network-online.target
Wants=network-online.target

[Service]
User=${OTEL_USER}
Group=${OTEL_USER}
ExecStart=${BIN_DIR}/otelcol-contrib --config=${CONF_DIR}/hostmetrics.yaml --mem-ballast-size-mib=0
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
Environment=GODEBUG=netdns=go
WorkingDirectory=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SVC_NAME}"

echo "otelcol-contrib installed and started ✅"
echo "Config: ${CONF_DIR}/hostmetrics.yaml"
echo "Logs:   journalctl -u ${SVC_NAME} -f"
