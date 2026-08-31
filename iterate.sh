#!/bin/bash
# Ciclo de depuracion de H4: compilar -> desplegar -> ejecutar en Ryujinx -> leer trazas.
# Las trazas NO se leen de la salida estandar del emulador (ese canal no llega, ver
# README §5.31); se leen de los ficheros que el propio juego escribe en la SD virtual.
set -u
MK=C:/anilswitch/mkxp-z-nx
SD=C:/Users/Usuario/AppData/Roaming/Ryujinx/sdcard/switch/pokemon-anil
PKG=C:/anilswitch/out/sdcard/switch/pokemon-anil
RUN=${1:-x}
SECS=${2:-60}
# NSP=1 arranca el juego como aplicacion instalada en vez de como homebrew.
# Es el mismo binario: cambia el envoltorio, y con el la memoria disponible y
# el hecho de que argv venga vacio. empaquetar-nsp.sh se ejecuta solo.
COMO_NSP=${NSP:-0}

cd "$MK" || exit 1
if ! make -j6 > "C:/anilswitch/docs/h4-build-$RUN.log" 2>&1; then
    echo "FALLO DE COMPILACION"; tail -30 "C:/anilswitch/docs/h4-build-$RUN.log"; exit 1
fi
echo "compilado: $(ls -l $MK/pokemon-anil.nro | awk '{print $5}') bytes"

cp "$MK/pokemon-anil.nro" "$SD/pokemon-anil.nro" || exit 1
cp "$MK/pokemon-anil.nro" "$PKG/pokemon-anil.nro"
# runtime/ es la fuente de mkxp.json y de los shims de Ruby; out/sdcard es solo
# el paquete que se monta para la SD. Se sincroniza en cada vuelta para que
# editar runtime/ baste, sin volver a pasar por pack-anil.sh y sus 702 MB.
cp C:/anilswitch/runtime/mkxp.json "$PKG/mkxp.json"
cp C:/anilswitch/runtime/lib/*.rb "$PKG/lib/" 2>/dev/null
cp C:/anilswitch/runtime/lib/io/*.rb "$PKG/lib/io/" 2>/dev/null

cp "$PKG/mkxp.json" "$PKG/preload.rb" "$SD/" 2>/dev/null
cp -r "$PKG/lib" "$SD/" 2>/dev/null
rm -f "$SD/mkxp-boot.log" "$SD/mkxp-debug.log" "$SD/mkxp-ruby.log" "$SD/errorlog.txt"
echo "desplegado"

cd C:/Games/publish || exit 1
if [ "$COMO_NSP" = "1" ]; then
    C:/anilswitch/empaquetar-nsp.sh > "C:/anilswitch/docs/h4-nsp-$RUN.log" 2>&1 \
        || { echo "FALLO AL EMPAQUETAR"; tail -20 "C:/anilswitch/docs/h4-nsp-$RUN.log"; exit 1; }
    OBJETIVO=C:/anilswitch/out/pokemon-anil.nsp
else
    OBJETIVO=$SD/pokemon-anil.nro
fi
echo "lanzando $OBJETIVO"
timeout "$SECS" ./Ryujinx.exe --fullscreen "$OBJETIVO" \
    > "C:/anilswitch/docs/h4-ryujinx-$RUN.log" 2>&1
echo "salida del emulador: $?"

echo "=== mkxp-boot.log ==="
cat "$SD/mkxp-boot.log" 2>/dev/null || echo "(no existe)"
echo "=== mkxp-debug.log ==="
cat "$SD/mkxp-debug.log" 2>/dev/null || echo "(no existe)"
echo "=== mkxp-ruby.log ==="
cat "$SD/mkxp-ruby.log" 2>/dev/null || echo "(no existe)"
if [ -f "$SD/errorlog.txt" ]; then echo "=== errorlog.txt (del juego) ==="; cat "$SD/errorlog.txt"; fi
