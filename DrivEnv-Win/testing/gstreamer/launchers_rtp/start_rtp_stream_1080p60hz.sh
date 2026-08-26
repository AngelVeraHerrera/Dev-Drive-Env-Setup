#!/bin/bash

# Nombre identificativo para el proceso
PIPELINE_NAME="rtp_stream_1080p60hz"
PID_FILE="/tmp/${PIPELINE_NAME}.pid"

# --------------------------------------------------------------------
# Configuración. Todo lo que hay que cambiar está aquí arriba, y se puede
# sobrescribir sin editar el fichero:
#
#   DEST_HOST=10.0.0.5 DEST_PORT=6000 ./start_rtp_stream_1080p60hz.sh
#
# El destino por defecto es el receptor de esta instalación: cámbialo por
# el tuyo.
#
# El vídeo es el que trae el propio repositorio, resuelto desde la
# ubicación de este script para que funcione desde donde se haya copiado
# el árbol de testing. Antes había aquí una ruta absoluta de Linux
# (/home/visualizer/Videos/...) de la máquina donde se escribió esto, que
# no existe en el entorno que genera este repositorio: el lanzador no
# podía funcionar tal como se publicaba.
#
# gst-launch-1.0 es un binario de Windows y no entiende una ruta de MSYS
# del tipo /x/testing/..., así que se convierte con cygpath.
# --------------------------------------------------------------------
DEST_HOST="${DEST_HOST:-192.168.8.70}"
DEST_PORT="${DEST_PORT:-5500}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIDEO_DEFAULT="${SCRIPT_DIR}/../videos/FPS_test_1080p60_L4.2.mkv"
if command -v cygpath > /dev/null 2>&1; then
    VIDEO_DEFAULT="$(cygpath -m "$VIDEO_DEFAULT")"
fi
VIDEO="${VIDEO:-$VIDEO_DEFAULT}"

if [ ! -f "$VIDEO" ]; then
    echo "Video not found: $VIDEO"
    echo "Set VIDEO to an existing file, or check that testing/gstreamer/videos/ was copied to the drive."
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
  filesrc location="$VIDEO" ! \
  matroskademux name=demux demux.video_0 ! queue ! \
  h264parse ! rtph264pay config-interval=1 pt=96 ! \
  udpsink host="$DEST_HOST" port="$DEST_PORT" \
  > /tmp/${PIPELINE_NAME}.log 2>&1 &

echo $! > "$PID_FILE"
echo "Stream started with PID $!"
echo "Sending ${VIDEO} to ${DEST_HOST}:${DEST_PORT}"
echo "Log: /tmp/${PIPELINE_NAME}.log"
