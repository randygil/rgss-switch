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
#   PERFIL=diagnostico ./pack-anil.sh   mete ademas las sondas de runtime/diagnostico
#   CONTENEDOR=zip     ./pack-anil.sh   los assets en un solo anil-datos.zip
#
# CONTENEDOR=zip deja Data/, Graphics/, Audio/ y Fonts/ dentro de un unico
# anil-datos.zip ALMACENADO (zip -0), que es lo que el .nro monta con PhysFS al
# arrancar (sharedstate.cpp). Un fichero en vez de 22.000: la copia a la tarjeta
# —o el envio por FTP— deja de estar limitada por la cuenta de ficheros. Sin
# comprimir a proposito: los PNG y los OGG ya lo estan, y una entrada comprimida
# obliga a PhysFS a inflar en cada lectura y a rebobinar en cada busqueda.
#
set -u
RAIZ=${RAIZ:-$(cd "$(dirname "$0")" && pwd)}
SRC=${JUEGO:-${1:-}}
DST=${DST:-"$RAIZ/out/sdcard/switch/pokemon-anil"}
RUBY=${RUBY_SRC:-"$RAIZ/src/ruby-3.1.7/lib"}
PERFIL=${PERFIL:-produccion}
CONTENEDOR=${CONTENEDOR:-carpetas}

if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
  echo "No encuentro el juego en: '${SRC}'"
  echo "Uso:  JUEGO=\"/ruta/a/Pokemon Anil\" ./pack-anil.sh     (o pasala como primer argumento)"
  exit 1
fi
for imprescindible in Data/Scripts.rxdata Graphics Audio; do
  [ -e "$SRC/$imprescindible" ] || { echo "Esa carpeta no parece Pokemon Anil: falta $imprescindible"; exit 1; }
done

# Origen y destino no pueden ser lo mismo. Este guion empieza borrando las
# cuatro carpetas de recursos del destino, asi que apuntar JUEGO al propio
# out/sdcard —que ya parece la carpeta de Anil y pasa todas las comprobaciones
# de arriba— se lleva por delante los 668 MB antes de copiarlos. Con contenedor
# es mas facil de pisar todavia, porque el destino ni siquiera tiene que
# parecerse al origen para que la tentacion aparezca.
SRC_REAL=$(cd "$SRC" && pwd -P)
DST_REAL=$(mkdir -p "$DST" && cd "$DST" && pwd -P)
if [ "$SRC_REAL" = "$DST_REAL" ]; then
  echo "JUEGO y DST son la misma carpeta ($SRC_REAL)."
  echo "Este guion borra Data/, Graphics/, Audio/ y Fonts/ del destino antes de escribir:"
  echo "apunta JUEGO a tu copia original del juego, no a la salida."
  exit 1
fi
mkdir -p "$DST"

if [ "$CONTENEDOR" = "zip" ]; then
  echo "=== 1. Assets del juego -> anil-datos.zip (almacenado) ==="
  command -v zip >/dev/null || { echo "falta zip: pacman -S zip en la shell de devkitPro"; exit 1; }
  for d in Data Graphics Audio Fonts; do rm -rf "$DST/$d"; done
  rm -f "$DST/anil-datos.zip" "$DST/anil-datos.zip.parcial"
  # -0 almacenar, -r recursivo, -X sin campos extra del sistema, -q callado.
  # Se comprime desde $SRC para que las rutas dentro del zip empiecen en Data/.
  ( cd "$SRC" && zip -0 -r -X -q "$DST/anil-datos.zip.parcial" Data Graphics Audio Fonts \
      -x '*.exe' '*.dll' 'Thumbs.db' '.nomedia' ) || { echo "FALLO al empaquetar"; exit 1; }
  # Se renombra al final: un zip a medias no puede parecerse a uno acabado.
  mv "$DST/anil-datos.zip.parcial" "$DST/anil-datos.zip"
  echo "  + anil-datos.zip  $(du -h "$DST/anil-datos.zip" | cut -f1), $(unzip -l "$DST/anil-datos.zip" | tail -1 | awk '{print $2}') entradas"
  unzip -tq "$DST/anil-datos.zip" >/dev/null || { echo "FALLO: el zip no pasa unzip -t"; exit 1; }
  # La llave del contenedor: ocho bytes, la cabecera de un RGSSAD vacio.
  # Essentials solo pregunta por load_data —y por tanto por PhysFS, que es quien
  # ve dentro del contenedor— cuando hay un Game.rgssad al lado; sin el pregunta
  # al sistema de ficheros y el juego muere con "No se establecio una posicion
  # de inicio en el editor de mapas". Ver README 5.58.
  if [ -f "$SRC/Game.rgssad" ]; then
    cp "$SRC/Game.rgssad" "$DST/Game.rgssad" && echo "  + Game.rgssad (el del juego, tal cual)"
  else
    printf 'RGSSAD\000\001' > "$DST/Game.rgssad" && echo "  + Game.rgssad (8 bytes: la llave del contenedor)"
  fi
else
  echo "=== 1. Assets del juego ==="
  for d in Data Graphics Audio Fonts; do
    printf '  %-10s ' "$d"
    rm -rf "$DST/$d"
    cp -r "$SRC/$d" "$DST/$d" && echo "copiado" || echo "FALLO"
  done

  echo "=== 2. Purga de restos de escritorio dentro de los assets ==="
  find "$DST" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname 'Thumbs.db' -o -iname '.nomedia' \) -print -delete
  # El contenedor manda sobre las carpetas sueltas (el .nro lo monta primero),
  # asi que uno viejo aqui haria jugar con los datos de antes.
  [ -f "$DST/anil-datos.zip" ] && echo "  AVISO: hay un anil-datos.zip de otra tanda y el juego lo montara ANTES que estas carpetas. Borralo."
  # La llave sin contenedor no abre nada y ademas estorba: con ella presente el
  # juego pregunta por sus ficheros a traves de load_data en vez de al sistema,
  # que es el camino largo y el que menos se ha recorrido. Solo se retira la
  # nuestra -ocho bytes-; si el juego trajera un .rgssad de verdad, ni tocarlo.
  if [ -f "$DST/Game.rgssad" ] && [ "$(stat -c%s "$DST/Game.rgssad" 2>/dev/null)" = "8" ]; then
    rm -f "$DST/Game.rgssad" && echo "  - Game.rgssad (la llave del contenedor; aqui no hay contenedor)"
  fi
fi

echo "=== 3. Ficheros sueltos que si hacen falta ==="
for f in Game.ini preload.rb knownpoint.bmp selpoint.bmp; do
  cp "$SRC/$f" "$DST/$f" && echo "  + $f"
done

# El mkxp.json del juego es el de escritorio y no sirve: el del port fija la
# resolucion de la Switch, el pathCache y la lista de preloadScript. Se copia
# despues de los assets a proposito, para pisarlo si venia en la carpeta.
echo "=== 4. Configuracion y shims de Ruby del port (runtime/, perfil: $PERFIL) ==="
if [ "$PERFIL" = "diagnostico" ]; then
  cp "$RAIZ/runtime/mkxp.diagnostico.json" "$DST/mkxp.json" && echo "  + mkxp.json (diagnostico)"
else
  cp "$RAIZ/runtime/mkxp.json" "$DST/mkxp.json" && echo "  + mkxp.json"
fi
mkdir -p "$DST/lib/io"
rm -f "$DST"/lib/nx-*.rb
cp "$RAIZ"/runtime/lib/*.rb     "$DST/lib/"    && echo "  + lib/*.rb          ($(ls "$RAIZ"/runtime/lib/*.rb | wc -l) ficheros)"
cp "$RAIZ"/runtime/lib/io/*.rb  "$DST/lib/io/" && echo "  + lib/io/*.rb"
if [ "$PERFIL" = "diagnostico" ]; then
  cp "$RAIZ"/runtime/diagnostico/*.rb "$DST/lib/" && echo "  + lib/nx-*.rb de diagnostico ($(ls "$RAIZ"/runtime/diagnostico/*.rb | wc -l) ficheros)"
fi
# El binario, si ya esta compilado, para que la carpeta quede lista tal cual.
[ -f "$RAIZ/mkxp-z-nx/pokemon-anil.nro" ] && cp "$RAIZ/mkxp-z-nx/pokemon-anil.nro" "$DST/pokemon-anil.nro" && echo "  + pokemon-anil.nro"

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
echo "  $(find "$DST" -type f | wc -l) ficheros en total"
du -sh "$DST"/*/ 2>/dev/null || true
