#!/bin/bash

# Nombre identificativo para el proceso
PIPELINE_NAME="rtp_stream_1080p60hz"
PID_FILE="/tmp/${PIPELINE_NAME}.pid"

# Verifica si ya está corriendo
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "Video stream already running with PID $OLD_PID."
        exit 1
    else
        echo "Stale PID file found. Cleaning up..."
        rm "$PID_FILE"
    fi
fi

# Ejecuta el pipeline en segundo plano
gst-launch-1.0 -v \
  filesrc location="/home/visualizer/Videos/FPS_test_1080p60_L4.2.mkv" ! \
  matroskademux name=demux demux.video_0 ! queue ! \
  h264parse ! rtph264pay config-interval=1 pt=96 ! \
  udpsink host="192.168.8.70" port=5500 \
  > /tmp/${PIPELINE_NAME}.log 2>&1 &

echo $! > "$PID_FILE"
echo "Stream started with PID $!"
