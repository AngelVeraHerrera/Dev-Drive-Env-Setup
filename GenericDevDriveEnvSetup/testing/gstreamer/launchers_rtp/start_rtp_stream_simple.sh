#!/bin/bash

# Nombre identificativo para el proceso
PIPELINE_NAME="rtp_stream_simple"
PID_FILE="/tmp/${PIPELINE_NAME}.pid"

# Verifica si el PID ya existe y corresponde a un proceso activo
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "Stream already running with PID $OLD_PID."
        exit 1
    else
        echo "Found stale PID file. Removing..."
        rm "$PID_FILE"
    fi
fi

# Ejecuta el pipeline en segundo plano, redirigiendo salida y guardando el PID
gst-launch-1.0 -v rtpbin name=rtpbin rtp-profile=avpf \
  videotestsrc ! \
  x264enc tune=zerolatency bitrate=500 speed-preset=superfast ! \
  video/x-h264,profile=high ! \
  rtph264pay config-interval=1 ! \
  udpsink port=5500 host="192.168.8.70" \
  > /tmp/${PIPELINE_NAME}.log 2>&1 &

# Guarda el PID en archivo temporal
echo $! > /tmp/${PIPELINE_NAME}.pid
echo "Stream started with PID $!"
