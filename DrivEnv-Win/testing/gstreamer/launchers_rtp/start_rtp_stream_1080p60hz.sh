#!/bin/bash

# Nombre identificativo para el proceso
PIPELINE_NAME="rtp_stream_1080p60hz"
PID_FILE="/tmp/${PIPELINE_NAME}.pid"

# ----------------------------------------------------------------------
# CONFIGURACIÓN
#
# Las tres variables se toman del ENTORNO si están definidas, y si no
# caen a un valor por defecto. Eso permite definirlas una sola vez para
# todo el disco, en environment.custom_variables del fichero de
# configuración del generador, en lugar de editar cada lanzador:
#
#   "GSTREAMER_TEST_HOST_IP": "192.168.8.70",
#   "GSTREAMER_TEST_PORT":    "5500"
#
# Y siguen pudiendo sobrescribirse en la propia llamada, para una prueba
# suelta sin tocar nada:
#
#   GSTREAMER_TEST_HOST_IP=10.0.0.5 GSTREAMER_TEST_PORT=6000 \
#       ./start_rtp_stream_1080p60hz.sh
#
# Los nombres van con prefijo a propósito. Un DEST_HOST o un VIDEO a
# secas en el entorno de un disco de desarrollo colisiona con cualquier
# cosa; GSTREAMER_TEST_* dice de quién es y para qué.
# ----------------------------------------------------------------------

DEFAULT_HOST_IP="192.168.8.70"
DEFAULT_PORT="5500"

GST_HOST_IP="${GSTREAMER_TEST_HOST_IP:-$DEFAULT_HOST_IP}"
GST_PORT="${GSTREAMER_TEST_PORT:-$DEFAULT_PORT}"

# El vídeo es el que trae el propio repositorio, resuelto desde la
# ubicación de este script para que funcione desde donde se haya copiado
# el árbol de testing. gst-launch-1.0 es un binario de Windows y no
# entiende una ruta de MSYS del tipo /x/testing/..., así que se convierte
# con cygpath.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_VIDEO="${SCRIPT_DIR}/../videos/FPS_test_1080p60_L4.2.mkv"
if command -v cygpath > /dev/null 2>&1; then
    DEFAULT_VIDEO="$(cygpath -m "$DEFAULT_VIDEO")"
fi
GST_VIDEO="${GSTREAMER_TEST_VIDEO:-$DEFAULT_VIDEO}"

# De dónde salió cada valor. Se imprime porque la duda al usar estos
# lanzadores no era cómo arrancarlos, era a dónde estaban enviando.
origin() { if [ -n "$1" ]; then echo "entorno"; else echo "por defecto"; fi; }

echo "Configuración en uso:"
echo "  GSTREAMER_TEST_HOST_IP  ${GST_HOST_IP}   ($(origin "$GSTREAMER_TEST_HOST_IP"))"
echo "  GSTREAMER_TEST_PORT     ${GST_PORT}   ($(origin "$GSTREAMER_TEST_PORT"))"
echo "  GSTREAMER_TEST_VIDEO    ${GST_VIDEO}   ($(origin "$GSTREAMER_TEST_VIDEO"))"

if [ ! -f "$GST_VIDEO" ]; then
    echo "ERROR: no existe el vídeo: $GST_VIDEO"
    echo "       Define GSTREAMER_TEST_VIDEO con una ruta válida, o comprueba que"
    echo "       testing/gstreamer/videos/ se copió al disco."
    exit 1
fi

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
  filesrc location="$GST_VIDEO" ! \
  matroskademux name=demux demux.video_0 ! queue ! \
  h264parse ! rtph264pay config-interval=1 pt=96 ! \
  udpsink host="$GST_HOST_IP" port="$GST_PORT" \
  > /tmp/${PIPELINE_NAME}.log 2>&1 &

echo $! > "$PID_FILE"
echo "Stream started with PID $!"
echo "Enviando a ${GST_HOST_IP}:${GST_PORT}"
echo "Log: /tmp/${PIPELINE_NAME}.log"
