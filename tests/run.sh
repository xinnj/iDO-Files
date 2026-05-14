#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BROWSER="${1:-all}"

echo "=== iDO-Files E2E Tests ==="

# Start test server
echo "Starting test server..."
bash env/start.sh

# Run tests
if [ "$BROWSER" = "all" ]; then
  echo "Running all tests (chromium + edge + webkit)..."
  npx playwright test
elif [ "$BROWSER" = "headed" ]; then
  echo "Running tests in headed mode..."
  npx playwright test --headed
elif [ "$BROWSER" = "ui" ]; then
  echo "Opening Playwright UI..."
  npx playwright test --ui
else
  echo "Running tests on $BROWSER only..."
  npx playwright test --project="$BROWSER"
fi

echo ""
echo "=== Tests complete ==="
echo "Report: npx playwright show-report"
echo ""
echo "Server still running on http://localhost:8080"
echo "Stop it with: bash env/stop.sh"
