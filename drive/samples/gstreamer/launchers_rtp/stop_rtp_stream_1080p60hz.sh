#!/bin/bash

PIPELINE_NAME="rtp_stream_1080p60hz"
PID_FILE="/tmp/${PIPELINE_NAME}.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    echo "Stopping stream with PID $PID..."
    kill "$PID" && rm "$PID_FILE"
else
    echo "No running stream found."
fi
