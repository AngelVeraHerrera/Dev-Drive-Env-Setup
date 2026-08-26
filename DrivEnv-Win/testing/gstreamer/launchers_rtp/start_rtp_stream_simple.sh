#!/bin/bash

# Nombre identificativo para el proceso
PIPELINE_NAME="rtp_stream_simple"
PID_FILE="/tmp/${PIPELINE_NAME}.pid"

# --------------------------------------------------------------------
# Configuración. El destino por defecto es el receptor de esta
# instalación: cámbialo por el tuyo, o pásalo sin editar el fichero:
#
#   DEST_HOST=10.0.0.5 DEST_PORT=6000 ./start_rtp_stream_simple.sh
#
# Esta tubería no necesita fichero de vídeo: genera la señal con
# videotestsrc, así que sirve para comprobar el camino de red y el
# codificador por separado del demuxado de un fichero real.
# --------------------------------------------------------------------
DEST_HOST="${DEST_HOST:-192.168.8.70}"
DEST_PORT="${DEST_PORT:-5500}"

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
  udpsink port="$DEST_PORT" host="$DEST_HOST" \
  > /tmp/${PIPELINE_NAME}.log 2>&1 &

# Guarda el PID en archivo temporal
echo $! > "$PID_FILE"
echo "Stream started with PID $!"
echo "Sending to ${DEST_HOST}:${DEST_PORT}"
echo "Log: /tmp/${PIPELINE_NAME}.log"
