#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "Deploying standalone Sweepstakes package..."
"$SCRIPT_DIR/deploy-standalone-ext.sh" "${1:-}" "sweepstakes_ext" "sweepstakes_package.json" "sweepstakes_ext"

echo ""
echo "Sweepstakes deployment finished."
echo "Published module target:"
echo "  <sweepstakesPackageId>::sweepstakes::SweepstakesAuth"
echo "Publish output file:"
echo "  deployments/\${SUI_NETWORK:-${1:-localnet}}/sweepstakes_package.json"
