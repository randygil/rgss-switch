#!/bin/bash
# H5 — empaquetado de Pokemon Anil 4.0 para tarjeta SD de Nintendo Switch
#
# Monta en out/sdcard/ la carpeta que se copia tal cual a la SD. Junta tres
# origenes distintos, y conviene no confundirlos:
#
#   1. Los assets del juego            <- tu copia, fuera de este repo
#   2. Los shims de Ruby del port      <- runtime/lib/, versionados aqui
#   3. Un subconjunto de la stdlib     <- src/ruby-3.1.7/lib, segun manifiesto
#
# El juego NO viaja en el repositorio. Apunta JUEGO a tu propia copia:
#
#   JUEGO="/c/ruta/a/Pokemon Anil" ./pack-anil.sh
#
set -u
RAIZ=${RAIZ:-/c/anilswitch}
SRC=${JUEGO:-"/c/Users/Usuario/Downloads/POKEMON_ANIL (1)/Pokemon Anil"}
DST=${DST:-"$RAIZ/out/sdcard/switch/pokemon-anil"}
RUBY=${RUBY_SRC:-"$RAIZ/src/ruby-3.1.7/lib"}

if [ ! -d "$SRC" ]; then
  echo "No encuentro el juego en: $SRC"
  echo "Define JUEGO con la ruta a tu copia de Pokemon Anil 4.0."
  exit 1
fi
mkdir -p "$DST"

echo "=== 1. Assets del juego ==="
for d in Data Graphics Audio Fonts; do
  printf '  %-10s ' "$d"
  rm -rf "$DST/$d"
  cp -r "$SRC/$d" "$DST/$d" && echo "copiado" || echo "FALLO"
done

echo "=== 2. Purga de restos de escritorio dentro de los assets ==="
find "$DST" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname 'Thumbs.db' -o -iname '.nomedia' \) -print -delete

echo "=== 3. Ficheros sueltos que si hacen falta ==="
for f in Game.ini preload.rb knownpoint.bmp selpoint.bmp; do
  cp "$SRC/$f" "$DST/$f" && echo "  + $f"
done

# El mkxp.json del juego es el de escritorio y no sirve: el del port fija la
# resolucion de la Switch, el pathCache y la lista de preloadScript. Se copia
# despues de los assets a proposito, para pisarlo si venia en la carpeta.
echo "=== 4. Configuracion y shims de Ruby del port (runtime/) ==="
cp "$RAIZ/runtime/mkxp.json" "$DST/mkxp.json" && echo "  + mkxp.json"
mkdir -p "$DST/lib/io"
cp "$RAIZ"/runtime/lib/*.rb     "$DST/lib/"    && echo "  + lib/*.rb          ($(ls "$RAIZ"/runtime/lib/*.rb | wc -l) ficheros)"
cp "$RAIZ"/runtime/lib/io/*.rb  "$DST/lib/io/" && echo "  + lib/io/*.rb"

# La stdlib tiene que ser la 3.1.7 con la que se compilo el interprete, no la
# 3.3.0 de MinGW que traia el juego: los .rb de una version no valen para otra.
echo "=== 5. Subconjunto de la stdlib de Ruby 3.1.7 ==="
if [ ! -d "$RUBY" ]; then
  echo "  AVISO: no esta $RUBY — el juego no arrancara sin la stdlib."
else
  n=0
  while read -r f; do
    case "$f" in ''|'#'*) continue ;; esac
    mkdir -p "$DST/lib/$(dirname "$f")"
    cp "$RUBY/$f" "$DST/lib/$f" && n=$((n+1))
  done < "$RAIZ/runtime/lib-stdlib.txt"
  echo "  + $n ficheros desde $RUBY"
fi

echo "=== 6. Tamano ==="
du -sh "$DST"
du -sh "$DST"/*/
