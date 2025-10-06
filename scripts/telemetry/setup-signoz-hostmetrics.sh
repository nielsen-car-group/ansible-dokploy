#!/usr/bin/env bash
#
# SigNoz Host Agent Installer (Metrics + Docker Logs)
# ---------------------------------------------------
# Installs OpenTelemetry Collector (contrib) as a systemd service
# that sends host metrics + ALL Docker container logs to SigNoz.
#
# Docs: https://signoz.io/docs/userguide/hostmetrics/
#
# Usage examples:
#   sudo ./install-signoz-host.sh
#   sudo SIGNOZ_HOST="127.0.0.1" ./install-signoz-host.sh
#   sudo SIGNOZ_HOST="metrics.example.com" SIGNOZ_USE_GRPC=false SIGNOZ_INSECURE=false ./install-signoz-host.sh
#
set -euo pipefail

#############################################
#                  DEFAULTS                 #
# (Edit here or override via environment)   #
#############################################

DEFAULT_SIGNOZ_HOST="127.0.0.1"             # Use 127.0.0.1 on the SigNoz box itself, or FQDN/IP of the SigNoz host
DEFAULT_SIGNOZ_GRPC_PORT="4317"             # OTLP gRPC
DEFAULT_SIGNOZ_HTTP_PORT="4318"             # OTLP HTTP
DEFAULT_SIGNOZ_USE_GRPC="true"              # true=gRPC(4317), false=HTTP(4318)
DEFAULT_SIGNOZ_INSECURE="true"              # true=plaintext/no TLS; set false if using TLS/https to SigNoz
DEFAULT_SIGNOZ_ENV="prod"                   # deployment.environment tag
DEFAULT_SERVICE_NAMESPACE="host"            # service.namespace tag
DEFAULT_COLLECTION_INTERVAL="30s"           # hostmetrics scrape interval
DEFAULT_OTEL_VERSION="0.128.0"              # otelcol-contrib release to install
DEFAULT_SERVICE_NAME="otelcol-host"         # systemd unit name
DEFAULT_START_AT_END="true"                 # for filelog: start at end to avoid backfilling old logs
DEFAULT_ENABLE_JOURNALD="false"             # we default to docker logs only

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
SERVICE_NAME="${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"
START_AT_END="${START_AT_END:-$DEFAULT_START_AT_END}"
ENABLE_JOURNALD="${ENABLE_JOURNALD:-$DEFAULT_ENABLE_JOURNALD}"

# Derived/advanced overrides
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

# choose exporter based on SIGNOZ_USE_GRPC
shopt -s nocasematch
if [[ "$SIGNOZ_USE_GRPC" == "true" || "$SIGNOZ_USE_GRPC" == "yes" || "$SIGNOZ_USE_GRPC" == "1" ]]; then
  EXPORTER_KIND="otlp"
  OTLP_ENDPOINT="$SIGNOZ_OTLP_GRPC_ENDPOINT"     # e.g. 127.0.0.1:4317 (no scheme)
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

HOSTNAME_VAL="$(hostname -f 2>/dev/null || hostname)"

BIN_DIR="/usr/local/bin"
INSTALL_DIR="/opt/otelcol"
CONF_DIR="/etc/otelcol"
DATA_DIR="/var/lib/otelcol"

echo "==> SigNoz Host Agent Installer"
echo "    Host:                 $SIGNOZ_HOST"
echo "    OTLP via gRPC:        $SIGNOZ_USE_GRPC"
echo "    OTLP endpoint:        $OTLP_ENDPOINT"
echo "    Insecure TLS:         $SIGNOZ_INSECURE"
echo "    Env tag:              $SIGNOZ_ENV"
echo "    Service namespace:    $SERVICE_NAMESPACE"
echo "    Interval:             $COLLECTION_INTERVAL"
echo "    otelcol-contrib ver:  $OTEL_VERSION"
echo "    Docker logs:          ENABLED (reads /var/lib/docker/containers/*/*-json.log)"
echo "    journald logs:        $ENABLE_JOURNALD"
echo

#############################################
#         PREREQS & INSTALL BITS            #
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

mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$DATA_DIR"

TARBALL="otelcol-contrib_${OTEL_VERSION}_linux_${TARCH}.tar.gz"
URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${TARBALL}"

echo "==> Downloading ${URL}"
curl -fsSL "$URL" -o "/tmp/${TARBALL}"
tar -xzf "/tmp/${TARBALL}" -C "$INSTALL_DIR"
install -m 0755 "$INSTALL_DIR/otelcol-contrib" "$BIN_DIR/otelcol-contrib"

#############################################
#           GENERATE CONFIG (YAML)          #
#############################################

START_AT_END_VAL="true"
shopt -s nocasematch
if [[ "$START_AT_END" == "false" || "$START_AT_END" == "no" || "$START_AT_END" == "0" ]]; then
  START_AT_END_VAL="false"
fi
shopt -u nocasematch

JOURNALD_BLOCK=""
PIPELINE_LOG_RECEIVERS="filelog"
if [[ "$ENABLE_JOURNALD" =~ ^(true|yes|1)$ ]]; then
  JOURNALD_BLOCK=$(cat <<'JEND'
  journald:
    directory: /var/log/journal
    # Example filters to reduce noise (uncomment to use):
    # units: ["docker.service","ssh.service","traefik.service"]
    # priority: [warning, err, crit, alert, emerg]
JEND
)
  PIPELINE_LOG_RECEIVERS="journald, filelog"
fi

cat > "${CONF_DIR}/host.yaml" <<EOF
receivers:
  # -------- Host metrics --------
  hostmetrics:
    collection_interval: ${COLLECTION_INTERVAL}
    scrapers:
      cpu: {}
      disk: {}
      filesystem: {}
      load: {}
      memory: {}
      network: {}
      paging: {}
      processes: {}

  # -------- Docker container logs --------
  filelog:
    include:
      - /var/lib/docker/containers/*/*-json.log
    start_at: ${START_AT_END_VAL}
    include_file_path: true
    fingerprint_size: 1kb
    max_log_size: 1MiB
    operators:
      # Docker JSON log contains fields: "time", "log", "stream"
      - type: json_parser
        parse_from: body
        parse_to: attributes
        on_error: send
      - type: move
        from: attributes.log
        to: body
      - type: add
        field: resource["service.namespace"]
        value: "docker"
      - type: add
        field: resource["host.name"]
        value: "${HOSTNAME_VAL}"
${JOURNALD_BLOCK:+
# -------- journald (optional) --------
}${JOURNALD_BLOCK}

processors:
  batch: {}
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
  otlp:
    endpoint: "${SIGNOZ_OTLP_GRPC_ENDPOINT}"
    tls:
      insecure: ${SIGNOZ_INSECURE}
  otlphttp:
    endpoint: "${SIGNOZ_OTLP_HTTP_ENDPOINT}"
    tls:
      insecure: ${SIGNOZ_INSECURE}
  # logging: { verbosity: detailed }   # <- uncomment for debug

service:
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [resourcedetection, resource, batch]
      exporters: [${EXPORTER_KIND}]
    logs:
      receivers: [${PIPELINE_LOG_RECEIVERS}]
      processors: [resourcedetection, resource, batch]
      exporters: [${EXPORTER_KIND}]
EOF

#############################################
#              systemd SERVICE              #
#############################################

# We must run as root to read Docker container logs safely.
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=OpenTelemetry Collector (Host metrics + Docker logs -> SigNoz)
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=root
Group=root
ExecStart=${BIN_DIR}/otelcol-contrib --config=${CONF_DIR}/host.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
Environment=GODEBUG=netdns=go
WorkingDirectory=${DATA_DIR}

# Hardening (keep reasonable while reading docker logs)
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo
echo "✅ Installed & started ${SERVICE_NAME}"
echo "   Config : ${CONF_DIR}/host.yaml"
echo "   Logs   : journalctl -u ${SERVICE_NAME} -f"
echo "   Binary : $(command -v otelcol-contrib)"
echo
echo "Tip: In SigNoz UI, check Logs and filter by service.namespace=\"docker\" or host.name=\"${HOSTNAME_VAL}\"."

