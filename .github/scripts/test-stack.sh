#!/usr/bin/env bash
# Smoke tests for the ECK-deployed Elastic stack.
#
# Verifies Elasticsearch, Kibana, Fleet Server, and the local EPR are up.
# Uses `kubectl exec` / `kubectl port-forward` so it works in any
# Kubernetes context (kind, Docker Desktop, remote), without /etc/hosts
# changes.
#
# Usage:  bash .github/scripts/test-stack.sh all

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NS="${ELASTIC_NS:-elastic}"
CLUSTER="${CLUSTER_NAME:-ci-cluster}"

PASS=0
FAIL=0

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()      { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS+1)); }
log_fail()    { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL+1)); }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

get_elastic_password() {
  kubectl -n "$NS" get secret "${CLUSTER}-es-elastic-user" \
    -o go-template='{{.data.elastic | base64decode}}'
}

test_elasticsearch() {
  log_info "Test: Elasticsearch cluster health is green"
  local pw status
  pw=$(get_elastic_password)
  status=$(kubectl -n "$NS" exec "${CLUSTER}-es-default-0" -c elasticsearch -- \
    curl -sSk -u "elastic:${pw}" https://localhost:9200/_cluster/health \
    | jq -r '.status')
  if [[ "$status" == "green" ]]; then
    log_ok "Elasticsearch is green"
  else
    log_fail "Elasticsearch status: ${status:-unknown}"
  fi
}

test_kibana() {
  log_info "Test: Kibana reports overall available status"
  local pod
  pod=$(kubectl -n "$NS" get pod -l "kibana.k8s.elastic.co/name=kibana" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$pod" ]]; then
    log_fail "No Kibana pod found"
    return
  fi
  local status
  status=$(kubectl -n "$NS" exec "$pod" -- \
    curl -sSk -u "elastic:$(get_elastic_password)" \
      https://localhost:5601/api/status \
    | jq -r '.status.overall.level // .status.overall.state // "unknown"')
  if [[ "$status" == "available" ]]; then
    log_ok "Kibana is available"
  else
    log_fail "Kibana status: $status"
  fi
}

test_fleet() {
  log_info "Test: Fleet Server agent is healthy"
  local ready
  ready=$(kubectl -n "$NS" get agent fleet-server \
    -o jsonpath='{.status.health}' 2>/dev/null || echo "unknown")
  if [[ "$ready" == "green" ]]; then
    log_ok "Fleet Server is green"
  else
    log_warn "Fleet Server status: $ready (may still be enrolling)"
  fi
}

test_epr() {
  log_info "Test: Elastic Package Registry service responds"
  local svc
  svc=$(kubectl -n "$NS" get svc package-registry \
    -o jsonpath='{.metadata.name}' 2>/dev/null || true)
  if [[ -z "$svc" ]]; then
    log_warn "package-registry service not present (skipped)"
    return
  fi
  # Run a small client pod against the service.
  if kubectl -n "$NS" run epr-probe --rm -i --restart=Never \
       --image=curlimages/curl:8.10.1 --quiet -- \
       -sSf "http://package-registry:8080/health" >/dev/null; then
    log_ok "EPR /health returns 2xx"
  else
    log_fail "EPR /health did not respond"
  fi
}

test_geoip_disabled() {
  log_info "Test: GeoIP auto-download is disabled"
  local pw val
  pw=$(get_elastic_password)
  val=$(kubectl -n "$NS" exec "${CLUSTER}-es-default-0" -c elasticsearch -- \
    curl -sSk -u "elastic:${pw}" \
      'https://localhost:9200/_cluster/settings?include_defaults=true&filter_path=**.ingest.geoip.downloader.enabled' \
    | jq -r '.. | .enabled? // empty' | head -1)
  if [[ "$val" == "false" ]]; then
    log_ok "ingest.geoip.downloader.enabled=false"
  else
    log_fail "ingest.geoip.downloader.enabled=${val:-unset} (expected false)"
  fi
}

suite() {
  case "${1:-all}" in
    elasticsearch) test_elasticsearch ;;
    kibana)        test_kibana ;;
    fleet)         test_fleet ;;
    epr)           test_epr ;;
    geoip)         test_geoip_disabled ;;
    all)
      test_elasticsearch
      test_kibana
      test_fleet
      test_epr
      test_geoip_disabled
      ;;
    *)
      echo "Unknown suite: $1"
      exit 2
      ;;
  esac
}

suite "${1:-all}"

echo
echo "──────────────────────────────────────"
echo -e "  ${GREEN}Passed:${NC} $PASS    ${RED}Failed:${NC} $FAIL"
echo "──────────────────────────────────────"

(( FAIL == 0 ))
