#!/bin/bash
# Ciclo de depuracion del motor: compilar -> copiar el .nro -> ejecutar en
# Ryujinx -> leer trazas.
#
# Las trazas NO se leen de la salida estandar del emulador (ese canal no llega,
# ver README 5.31); se leen de los ficheros que el propio juego escribe en la SD
# virtual.
#
#   ./iterate.sh <slug> [segundos] [--sin-compilar]
#
# El slug es obligatorio y decide todo: la carpeta de la tarjeta virtual es
# switch/<slug>/ y el binario que se lanza es switch/<slug>/<slug>.nro. Antes
# habia una sola carpeta escrita aqui dentro; con un motor generico eso solo
# sirve para probar siempre el mismo juego sin darse cuenta.
#
# Lo que este guion NO hace desde que hay empaquetador: sincronizar mkxp.json y
# lib/. Eso lo compone Empaquetar.ps1 por capas (CONVENCIONES 5) y copiarlo a
# mano desde runtime/ producia una instalacion que no se parece a la del
# jugador, que es justo lo que se pretende probar.
set -u

RAIZ=$(cd "$(dirname "$0")" && pwd)
MK="$RAIZ/mkxp-z-nx"

SLUG=${1:-}
if [ -z "$SLUG" ]; then
    echo "uso: ./iterate.sh <slug> [segundos] [--sin-compilar]"
    echo "     (el slug es la carpeta de SD:/switch/<slug>/)"
    exit 1
fi
SECS=${2:-60}
COMPILAR=1
for a in "$@"; do [ "$a" = "--sin-compilar" ] && COMPILAR=0; done

SD="C:/Users/Usuario/AppData/Roaming/Ryujinx/sdcard/switch/$SLUG"
if [ ! -d "$SD" ]; then
    echo "no existe $SD: despliega el juego ahi antes de iterar"
    exit 1
fi

mkdir -p "$RAIZ/docs"
if [ "$COMPILAR" = "1" ]; then
    cd "$MK" || exit 1
    if ! make -j6 > "$RAIZ/docs/build-$SLUG.log" 2>&1; then
        echo "FALLO DE COMPILACION"; tail -30 "$RAIZ/docs/build-$SLUG.log"; exit 1
    fi
    echo "compilado: $(ls -l "$MK/rgss-switch.nro" | awk '{print $5}') bytes"
fi

# El .nro del juego es una copia del motor: en la entrega el empaquetador le
# rehace la seccion ASET con el icono y el nombre del juego, y aqui no hace
# falta porque lo que se esta probando es el cuerpo del binario.
cp "$MK/rgss-switch.nro" "$SD/$SLUG.nro" || exit 1
rm -f "$SD/mkxp-boot.log" "$SD/mkxp-debug.log" "$SD/mkxp-ruby.log" "$SD/errorlog.txt"
echo "desplegado en $SD"

cd C:/Games/publish || exit 1
OBJETIVO="$SD/$SLUG.nro"
echo "lanzando $OBJETIVO durante $SECS s"
timeout "$SECS" ./Ryujinx.exe --fullscreen "$OBJETIVO" \
    > "$RAIZ/docs/ryujinx-$SLUG.log" 2>&1
echo "salida del emulador: $?"

echo "=== mkxp-boot.log ==="
cat "$SD/mkxp-boot.log" 2>/dev/null || echo "(no existe)"
echo "=== mkxp-debug.log ==="
cat "$SD/mkxp-debug.log" 2>/dev/null || echo "(no existe)"
echo "=== mkxp-ruby.log ==="
cat "$SD/mkxp-ruby.log" 2>/dev/null || echo "(no existe)"
if [ -f "$SD/errorlog.txt" ]; then echo "=== errorlog.txt (del juego) ==="; cat "$SD/errorlog.txt"; fi
