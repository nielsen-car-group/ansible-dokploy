#!/usr/bin/env bash
#
# SigNoz Host Metrics Installer
# -----------------------------
# Installs OpenTelemetry Collector (contrib) as a host agent that sends
# host/infra metrics to your central SigNoz collector.
#
# Docs: https://signoz.io/docs/userguide/hostmetrics/
#
# Usage examples:
#   sudo ./install-signoz-hostmetrics.sh
#   sudo SIGNOZ_HOST="127.0.0.1" ./install-signoz-hostmetrics.sh
#   sudo SIGNOZ_HOST="metrics.example.com" SIGNOZ_USE_GRPC=false SIGNOZ_INSECURE=false ./install-signoz-hostmetrics.sh
#
set -euo pipefail

#############################################
#                  DEFAULTS                 #
# (Edit here or override via environment)   #
#############################################

DEFAULT_SIGNOZ_HOST="signoz.example.com"    # set to your SigNoz host (or 127.0.0.1 on the SigNoz box)
DEFAULT_SIGNOZ_GRPC_PORT="4317"             # OTLP gRPC
DEFAULT_SIGNOZ_HTTP_PORT="4318"             # OTLP HTTP
DEFAULT_SIGNOZ_USE_GRPC="true"              # true=gRPC(4317), false=HTTP(4318)
DEFAULT_SIGNOZ_INSECURE="true"              # true=plaintext/no TLS; set false if using TLS on OTLP
DEFAULT_SIGNOZ_ENV="prod"                   # deployment.environment tag
DEFAULT_SERVICE_NAMESPACE="host"            # service.namespace tag
DEFAULT_COLLECTION_INTERVAL="30s"           # hostmetrics scrape interval
DEFAULT_OTEL_VERSION="0.128.0"              # otelcol-contrib release to install
DEFAULT_OTEL_USER="otelcol"                 # system user
DEFAULT_SERVICE_NAME="otelcol-hostmetrics"  # systemd unit name
DEFAULT_ENABLE_LOG_EXPORTER="false"         # true to also print metrics to logs (debug)

#############################################
#            ENV OVERRIDES (optional)       #
#############################################

SIGNOZ_HOST="${SIGNOZ_HOST:-$DEFAULT_SIGNOZ_HOST}"
SIGNOZ_GRPC_PORT="${SIGNOZ_GRPC_PORT:-$DEFAULT_SIGNOZ_GRPC_PORT}"
SIGNOZ_HTTP_PORT="${SIGNOZ_HTTP_PORT:-$DEFAULT_SIGNOZ_HTTP_PORT}"
SIGNOZ_USE_GRPC="${SIGNOZ_USE_GRPC:-$DEFAULT_SIGNOZ_USE_GRPC}"
SIGNOZ_INSECURE="${SIGNOZ_INSECURE:-$DEFAULT_SIGNOZ_INSECURE}"
SIGNOZ_ENV="${SIGNOZ_ENV:-$DEFAULT_SIGNOZ_ENV}"
SERVICE_NAMESPACE="${SERVICE_NAMESPACE:-$DEFAULT_SERVICE_NAMESPACE}"
COLLECTION_INTERVAL="${COLLECTION_INTERVAL:-$DEFAULT_COLLECTION_INTERVAL}"
OTEL_VERSION="${OTEL_VERSION:-$DEFAULT_OTEL_VERSION}"
OTEL_USER="${OTEL_USER:-$DEFAULT_OTEL_USER}"
SERVICE_NAME="${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"
ENABLE_LOG_EXPORTER="${ENABLE_LOG_EXPORTER:-$DEFAULT_ENABLE_LOG_EXPORTER}"

# Optional: direct endpoint overrides
SIGNOZ_OTLP_GRPC_ENDPOINT="${SIGNOZ_OTLP_GRPC_ENDPOINT:-"${SIGNOZ_HOST}:${SIGNOZ_GRPC_PORT}"}"
SIGNOZ_OTLP_HTTP_ENDPOINT="${SIGNOZ_OTLP_HTTP_ENDPOINT:-"http://${SIGNOZ_HOST}:${SIGNOZ_HTTP_PORT}"}"

#############################################
#           PRE-FLIGHT & DETECTION          #
#############################################

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

OS_ID="$(. /etc/os-release; echo "${ID}")"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  TARCH="amd64" ;;
  aarch64|arm64) TARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

shopt -s nocasematch
if [[ "$SIGNOZ_USE_GRPC" == "true" || "$SIGNOZ_USE_GRPC" == "yes" || "$SIGNOZ_USE_GRPC" == "1" ]]; then
  EXPORTER_KIND="otlp"
  OTLP_ENDPOINT="$SIGNOZ_OTLP_GRPC_ENDPOINT"     # e.g. 127.0.0.1:4317
else
  EXPORTER_KIND="otlphttp"
  # Ensure scheme on HTTP
  if [[ "$SIGNOZ_OTLP_HTTP_ENDPOINT" =~ ^https?:// ]]; then
    OTLP_ENDPOINT="$SIGNOZ_OTLP_HTTP_ENDPOINT"   # e.g. http://host:4318
  else
    OTLP_ENDPOINT="http://${SIGNOZ_OTLP_HTTP_ENDPOINT}"
  fi
fi
shopt -u nocasematch

echo "==> SigNoz Hostmetrics Installer"
echo "    Host:                 $SIGNOZ_HOST"
echo "    OTLP via gRPC:        $SIGNOZ_USE_GRPC"
echo "    OTLP endpoint:        $OTLP_ENDPOINT"
echo "    Insecure TLS:         $SIGNOZ_INSECURE"
echo "    Env tag:              $SIGNOZ_ENV"
echo "    Service namespace:    $SERVICE_NAMESPACE"
echo "    Interval:             $COLLECTION_INTERVAL"
echo "    otelcol-contrib ver:  $OTEL_VERSION"
echo "    Log exporter:         $ENABLE_LOG_EXPORTER"
echo

#############################################
#         PREREQS & INSTALL BITS           #
#############################################

install_pkgs() {
  case "$OS_ID" in
    ubuntu|debian|raspbian)
      apt-get update -y >/dev/null
      apt-get install -y curl wget tar ca-certificates >/dev/null
      ;;
    centos|rhel|rocky|almalinux|ol|amzn)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget tar ca-certificates >/dev/null
      else
        yum install -y curl wget tar ca-certificates >/dev/null
      fi
      ;;
    fedora)
      dnf install -y curl wget tar ca-certificates >/dev/null
      ;;
    alpine)
      apk add --no-cache curl wget tar ca-certificates >/dev/null
      ;;
    arch|manjaro|archarm)
      pacman -Sy --noconfirm --needed curl wget tar ca-certificates >/dev/null
      ;;
    *)
      echo "Unsupported Linux distro: $OS_ID" >&2
      exit 1
      ;;
  esac
}
install_pkgs

BIN_DIR="/usr/local/bin"
INSTALL_DIR="/opt/otelcol"
CONF_DIR="/etc/otelcol"
DATA_DIR="/var/lib/otelcol"

mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$DATA_DIR"

TARBALL="otelcol-contrib_${OTEL_VERSION}_linux_${TARCH}.tar.gz"
URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${TARBALL}"

echo "==> Downloading ${URL}"
curl -fsSL "$URL" -o "/tmp/${TARBALL}"
tar -xzf "/tmp/${TARBALL}" -C "$INSTALL_DIR"
install -m 0755 "$INSTALL_DIR/otelcol-contrib" "$BIN_DIR/otelcol-contrib"

# Create dedicated user if needed
if ! id -u "$OTEL_USER" >/dev/null 2>&1; then
  useradd --no-create-home --system --shell /usr/sbin/nologin "$OTEL_USER"
fi
chown -R "$OTEL_USER":"$OTEL_USER" "$INSTALL_DIR" "$CONF_DIR" "$DATA_DIR"

#############################################
#           GENERATE CONFIG (YAML)          #
#############################################

HOSTNAME_VAL="$(hostname -f 2>/dev/null || hostname)"

# optional logging exporter (debug)
LOGGING_EXPORTER_YAML=""
PIPELINE_EXPORTERS="$EXPORTER_KIND"
shopt -s nocasematch
if [[ "$ENABLE_LOG_EXPORTER" == "true" || "$ENABLE_LOG_EXPORTER" == "yes" || "$ENABLE_LOG_EXPORTER" == "1" ]]; then
  LOGGING_EXPORTER_YAML=$'  logging:\n    verbosity: detailed\n'
  PIPELINE_EXPORTERS="logging, ${EXPORTER_KIND}"
fi
shopt -u nocasematch

cat > "${CONF_DIR}/hostmetrics.yaml" <<EOF
receivers:
  hostmetrics:
    collection_interval: ${COLLECTION_INTERVAL}
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
${LOGGING_EXPORTER_YAML}  otlp:
    endpoint: "${SIGNOZ_OTLP_GRPC_ENDPOINT}"
    tls:
      insecure: ${SIGNOZ_INSECURE}
  otlphttp:
    endpoint: "${SIGNOZ_OTLP_HTTP_ENDPOINT}"
    tls:
      insecure: ${SIGNOZ_INSECURE}

service:
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [resourcedetection, resource, batch]
      exporters: [${PIPELINE_EXPORTERS}]
EOF

#############################################
#              systemd SERVICE              #
#############################################

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=OpenTelemetry Collector (hostmetrics -> SigNoz)
After=network-online.target
Wants=network-online.target

[Service]
User=${OTEL_USER}
Group=${OTEL_USER}
ExecStart=${BIN_DIR}/otelcol-contrib --config=${CONF_DIR}/hostmetrics.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
Environment=GODEBUG=netdns=go
WorkingDirectory=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo
echo "✅ Installed & started ${SERVICE_NAME}"
echo "   Config : ${CONF_DIR}/hostmetrics.yaml"
echo "   Logs   : journalctl -u ${SERVICE_NAME} -f"
echo "   Binary : $(command -v otelcol-contrib)"

