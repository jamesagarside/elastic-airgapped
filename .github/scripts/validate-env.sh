#!/usr/bin/env bash
# Validate .env.example completeness.
#
# Cross-checks three things:
#   1. Every variable listed in the Makefile's ENVSUBST_VARS exists in .env.example.
#   2. Every ${VAR} referenced in manifests/*.yaml is *either*
#      (a) in ENVSUBST_VARS (substituted at deploy time), or
#      (b) a documented runtime placeholder resolved by the pod itself
#          (e.g. Logstash's ELASTICSEARCH_USERNAME/PASSWORD come from a
#           secretKeyRef at container startup, not from envsubst).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ENV_EXAMPLE="$PROJECT_DIR/.env.example"
MAKEFILE="$PROJECT_DIR/Makefile"

[[ -f "$ENV_EXAMPLE" ]] || { echo -e "${RED}[FAIL]${NC} .env.example not found"; exit 1; }
[[ -f "$MAKEFILE"    ]] || { echo -e "${RED}[FAIL]${NC} Makefile not found"; exit 1; }

# Values in .env.example (KEY= lines, uncommented).
defined_vars=$(grep -E '^[A-Z_]+=' "$ENV_EXAMPLE" | cut -d= -f1 | sort -u)

# Variables the Makefile substitutes into manifests. Parsed from the
# ENVSUBST_VARS assignment (multi-line, joined on `\` continuations).
envsubst_vars=$(
  sed -n '/^ENVSUBST_VARS[[:space:]]*:=/,/[^\\]$/p' "$MAKEFILE" \
    | tr '\n' ' ' \
    | grep -oE '\$\$\{[A-Z_][A-Z0-9_]*\}' \
    | sed 's/\$\$//; s/[{}]//g' \
    | sort -u
)

# Runtime variables intentionally left for in-pod resolution (not substituted
# by envsubst). Extend this list as needed.
runtime_only="ELASTICSEARCH_USERNAME ELASTICSEARCH_PASSWORD"

# Variables referenced by any manifest.
referenced_vars=$(grep -rohE '\$\{[A-Z_][A-Z0-9_]*\}' \
  "$PROJECT_DIR"/manifests/*.yaml 2>/dev/null \
  | tr -d '${}' | sort -u)

# Derived variables built by the Makefile (not user-set in .env.example).
derived_vars="LLM_CONNECTOR_URL"

echo -e "${GREEN}[INFO]${NC} Validating .env.example"
echo "  defined in .env.example     : $(echo "$defined_vars"    | wc -l | tr -d ' ')"
echo "  in Makefile ENVSUBST_VARS   : $(echo "$envsubst_vars"   | wc -l | tr -d ' ')"
echo "  referenced by manifests     : $(echo "$referenced_vars" | wc -l | tr -d ' ')"
echo

fail=0

# 1. Every ENVSUBST_VAR must be either in .env.example or derived by Makefile.
missing_in_env=()
for v in $envsubst_vars; do
  echo "$derived_vars" | tr ' ' '\n' | grep -qx "$v" && continue
  echo "$defined_vars" | grep -qx "$v" || missing_in_env+=("$v")
done
if (( ${#missing_in_env[@]} > 0 )); then
  fail=1
  echo -e "${RED}[FAIL]${NC} In Makefile ENVSUBST_VARS but missing from .env.example:"
  printf '  - %s\n' "${missing_in_env[@]}"
  echo
fi

# 2. Every manifest reference must be in ENVSUBST_VARS or in runtime_only.
unclassified=()
for v in $referenced_vars; do
  echo "$envsubst_vars" | grep -qx "$v" && continue
  echo "$runtime_only"  | tr ' ' '\n' | grep -qx "$v" && continue
  unclassified+=("$v")
done
if (( ${#unclassified[@]} > 0 )); then
  fail=1
  echo -e "${RED}[FAIL]${NC} Referenced in manifests but neither in ENVSUBST_VARS nor runtime_only:"
  printf '  - %s\n' "${unclassified[@]}"
  echo
fi

# 3. Warn (don't fail) if .env.example defines keys no manifest references
#    and the Makefile does not use them either. These are still legitimate
#    config (hostnames, license settings, etc.) so a warning is enough.
unreferenced=()
for v in $defined_vars; do
  echo "$envsubst_vars"  | grep -qx "$v" && continue
  grep -qE "\\b$v\\b" "$MAKEFILE" && continue
  unreferenced+=("$v")
done
if (( ${#unreferenced[@]} > 0 )); then
  echo -e "${YELLOW}[WARN]${NC} Defined in .env.example but not used by manifests or Makefile:"
  printf '  - %s\n' "${unreferenced[@]}"
  echo
fi

if (( fail == 0 )); then
  echo -e "${GREEN}[OK]${NC} .env.example is consistent with Makefile ENVSUBST_VARS and manifests."
  exit 0
fi
exit 1
