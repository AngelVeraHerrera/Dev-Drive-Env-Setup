#!/bin/bash

# Nombre identificativo para el proceso
PIPELINE_NAME="rtp_stream_simple"
PID_FILE="/tmp/${PIPELINE_NAME}.pid"

# ----------------------------------------------------------------------
# CONFIGURACIÓN
#
# Se toman del ENTORNO si están definidas, y si no caen a un valor por
# defecto. Lo normal es definirlas una vez para todo el disco, en
# environment.custom_variables del fichero de configuración:
#
#   "GSTREAMER_TEST_HOST_IP": "192.168.8.70",
#   "GSTREAMER_TEST_PORT":    "5500"
#
# O sobrescribirlas en la llamada, para una prueba suelta:
#
#   GSTREAMER_TEST_HOST_IP=10.0.0.5 GSTREAMER_TEST_PORT=6000 \
#       ./start_rtp_stream_simple.sh
#
# Esta tubería no necesita fichero de vídeo: genera la señal con
# videotestsrc, así que sirve para comprobar el camino de red y el
# codificador por separado del demuxado de un fichero real.
# ----------------------------------------------------------------------

DEFAULT_HOST_IP="192.168.8.70"
DEFAULT_PORT="5500"

GST_HOST_IP="${GSTREAMER_TEST_HOST_IP:-$DEFAULT_HOST_IP}"
GST_PORT="${GSTREAMER_TEST_PORT:-$DEFAULT_PORT}"

origin() { if [ -n "$1" ]; then echo "entorno"; else echo "por defecto"; fi; }

echo "Configuración en uso:"
echo "  GSTREAMER_TEST_HOST_IP  ${GST_HOST_IP}   ($(origin "$GSTREAMER_TEST_HOST_IP"))"
echo "  GSTREAMER_TEST_PORT     ${GST_PORT}   ($(origin "$GSTREAMER_TEST_PORT"))"

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
  udpsink port="$GST_PORT" host="$GST_HOST_IP" \
  > /tmp/${PIPELINE_NAME}.log 2>&1 &

# Guarda el PID en archivo temporal
echo $! > "$PID_FILE"
echo "Stream started with PID $!"
echo "Enviando a ${GST_HOST_IP}:${GST_PORT}"
echo "Log: /tmp/${PIPELINE_NAME}.log"
