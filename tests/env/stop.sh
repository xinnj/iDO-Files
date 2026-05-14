#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SCRIPT_DIR/logs/nginx.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping OpenResty (pid=$PID)..."
        kill "$PID"
        sleep 1
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
        echo "Stopped"
    else
        echo "No running nginx process for pid=$PID"
    fi
    rm -f "$PID_FILE"
else
    echo "No PID file found. Killing any nginx on port 8080..."
    lsof -ti:8080 | xargs kill 2>/dev/null || true
    echo "Done"
fi
