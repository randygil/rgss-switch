#!/bin/bash
# Ciclo de depuracion del motor: compilar -> copiar el .nro -> ejecutar en
# Ryujinx -> leer trazas.
#
# Las trazas NO se leen de la salida estandar del emulador (ese canal no llega,
# ver bitacora §5.31); se leen de los ficheros que el propio juego escribe en la SD
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

# El .nro del juego NO puede ser una copia del motor, y esto costo una tarde.
#
# El rgss-switch.nro que sale de make lleva un romfs VACIO: tiene que llevarlo,
# porque pedir un romfs que el binario no tiene mata a Ryujinx en
# VirtualFileSystem.GetRomFs (6128ea3). Pero vacio quiere decir SIN juego.txt, y
# en el emulador ese fichero es la unica pista que le queda al motor para
# encontrar su juego: Ryujinx lanza los .nro con argc = 0 -medido-, asi que el
# paso (a) de CONVENCIONES 3, el directorio de argv[0], no contesta nada.
# Copiando el .nro tal cual, lo unico que se probaba una y otra vez era la
# pantalla de aviso de nx_aviso.c.
#
# Asi que el .nro del slug se rehace aqui con un romfs de un solo fichero, que
# es lo mismo que el empaquetador mete en el romfs del NSP: una linea
# "sdmc:/switch/<slug>" en UTF-8 SIN BOM y con salto de linea al final. El motor
# se salta el BOM desde b11, pero el acuerdo dice sin el y no hay por que
# gastarle esa tolerancia.
#
# Las rutas van relativas y con un cd delante a proposito: elf2nro es un
# programa de Windows y las rutas /c/... de esta shell no significan nada para
# el. $SD ya es "C:/...", que si entiende.
ROMFS="romfs-$SLUG"
(
    cd "$MK" || exit 1
    rm -rf "$ROMFS" && mkdir -p "$ROMFS" || exit 1
    printf 'sdmc:/switch/%s\n' "$SLUG" > "$ROMFS/juego.txt"
    C:/devkitPro/tools/bin/elf2nro.exe rgss-switch.elf "$SD/$SLUG.nro" \
        --icon=../nsp/icono.jpg --nacp=rgss-switch.nacp --romfsdir="$ROMFS" \
        > /dev/null || exit 1
    rm -rf "$ROMFS"
) || { echo "FALLO al construir $SD/$SLUG.nro con elf2nro"; exit 1; }
echo "romfs:/juego.txt dice sdmc:/switch/$SLUG"
rm -f "$SD/mkxp-boot.log" "$SD/mkxp-debug.log" "$SD/mkxp-ruby.log" "$SD/errorlog.txt"
echo "desplegado en $SD"

cd C:/Games/publish || exit 1
OBJETIVO="$SD/$SLUG.nro"
echo "lanzando $OBJETIVO durante $SECS s"
# En ventana y no a pantalla completa: esto corre en la misma maquina en la que
# hay alguien trabajando, y un emulador que se come la pantalla durante los
# minutos que dura la prueba la deja inservible. El volumen esta a 0 en la
# configuracion del emulador, por el mismo motivo.
timeout "$SECS" ./Ryujinx.exe "$OBJETIVO" \
    > "$RAIZ/docs/ryujinx-$SLUG.log" 2>&1
echo "salida del emulador: $?"

echo "=== mkxp-boot.log ==="
cat "$SD/mkxp-boot.log" 2>/dev/null || echo "(no existe)"
echo "=== mkxp-debug.log ==="
cat "$SD/mkxp-debug.log" 2>/dev/null || echo "(no existe)"
echo "=== mkxp-ruby.log ==="
cat "$SD/mkxp-ruby.log" 2>/dev/null || echo "(no existe)"
if [ -f "$SD/errorlog.txt" ]; then echo "=== errorlog.txt (del juego) ==="; cat "$SD/errorlog.txt"; fi
