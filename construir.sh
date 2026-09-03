#!/bin/bash
# construir.sh — de fuentes a entrega, en un solo paso, para quien tenga la
# cadena de herramientas puesta (devkitPro con devkitA64, shell MSYS2).
#
# Lo que hace, en orden:
#   1. Comprueba que estan las herramientas y las bibliotecas ya portadas
#      (libruby-static y las dependencias en out/nx/). Si no estan, dice que
#      guion las construye: eso son horas y no se hace aqui por accidente.
#   2. Regenera los shaders (gen-xxd.sh) si falta generated/.
#   3. Compila el .nro (make en mkxp-z-nx/).
#   4. Si hay prod.keys y hacbrewpack, empaqueta el .nsp.
#   5. Monta release/anil-switch-<VERSION>/ con TODO lo que necesita un jugador
#      que ya tiene el juego: .nro, .nsp, mkxp.json, lib/ (shims + stdlib),
#      el empaquetador con interfaz y la guia. Y lo comprime.
#
# El juego no entra en la entrega. Lo pone cada uno con Empaquetar.cmd.
set -eu
RAIZ=$(cd "$(dirname "$0")" && pwd)
cd "$RAIZ"
VERSION=$(cat VERSION)
export DEVKITPRO=${DEVKITPRO:-C:/devkitPro}
[ -d "$DEVKITPRO/devkitA64" ] || DEVKITPRO=C:/devkitPro
# El Makefile quiere DEVKITPRO en forma Windows (C:/...) porque GCC lo expande
# el mismo (README 5.15); pero el PATH de la shell quiere forma POSIX (/c/...).
# Son dos variables distintas por una buena razon, no por descuido.
DKP_POSIX=$DEVKITPRO
command -v cygpath >/dev/null && DKP_POSIX=$(cygpath -u "$DEVKITPRO") || DKP_POSIX=$(echo "$DEVKITPRO" | sed -E 's#^([A-Za-z]):#/\L\1#')
export PATH="$DKP_POSIX/devkitA64/bin:$DKP_POSIX/tools/bin:$PATH"

paso() { printf '\n=== %s ===\n' "$*"; }

paso "1. Herramientas y bibliotecas"
for h in aarch64-none-elf-g++ elf2nro nacptool; do
  command -v "$h" >/dev/null || { echo "falta $h: instala devkitPro con devkitA64 (https://devkitpro.org/wiki/Getting_Started)"; exit 1; }
done
if [ ! -f out/nx/lib/libruby-static.a ]; then
  echo "falta out/nx/lib/libruby-static.a: el interprete todavia no esta portado en esta maquina."
  echo "  ./build-deps.sh && ./build-deps2.sh    (dependencias de mkxp-z)"
  echo "  ./build-ruby-switch.sh && ./finalize-ruby.sh   (CRuby 3.1.7 -> libnx)"
  echo "El README, seccion 4 y 5, cuenta cada problema que te vas a encontrar y su arreglo."
  exit 1
fi
echo "ok"

paso "2. Shaders"
[ -d mkxp-z-nx/generated ] && echo "generated/ ya esta" || ./gen-xxd.sh

paso "3. pokemon-anil.nro"
make -C mkxp-z-nx -j"$(nproc 2>/dev/null || echo 4)" 2>&1 | grep -vE "valid for C\+\+" | grep -E "error|NACP|NRO" || true
[ -f mkxp-z-nx/pokemon-anil.nro ] || { echo "no salio el .nro"; exit 1; }

paso "4. pokemon-anil.nsp"
CLAVES=${CLAVES:-$HOME/.switch/prod.keys}
if [ -f "$CLAVES" ] && [ -f "${HBP:-tools/hacbrewpack/hacbrewpack.exe}" ]; then
  CLAVES="$CLAVES" ./empaquetar-nsp.sh | tail -2
else
  echo "sin prod.keys o sin hacbrewpack: se entrega solo el .nro (el .nsp es opcional)"
fi

paso "5. Entrega"
ENT="release/anil-switch-$VERSION"
# Se vacia la carpeta, no se borra. Windows deja handles abiertos sobre
# directorios (el indexador, el antivirus, un Explorer que paso por ahi) y
# entonces `rm -rf "$ENT"` falla con "Device or resource busy" y tumba la
# entrega entera por algo que no tiene nada que ver con compilar. Vaciarla
# consigue lo mismo y no depende de que nadie la tenga mirando.
rm -rf "$ENT"/* "$ENT"/.[!.]* 2>/dev/null || true
mkdir -p "$ENT/lib/io"
cp mkxp-z-nx/pokemon-anil.nro "$ENT/"
[ -f out/pokemon-anil.nsp ] && cp out/pokemon-anil.nsp "$ENT/"
cp runtime/mkxp.json "$ENT/"
cp runtime/lib/*.rb "$ENT/lib/"; cp runtime/lib/io/*.rb "$ENT/lib/io/"
# La stdlib de Ruby 3.1.7 que el juego necesita: los .rb de escritorio (3.3) no valen.
n=0
while read -r f; do
  case "$f" in ''|'#'*) continue ;; esac
  mkdir -p "$ENT/lib/$(dirname "$f")"; cp "src/ruby-3.1.7/lib/$f" "$ENT/lib/$f"; n=$((n+1))
done < runtime/lib-stdlib.txt
echo "lib/: $(ls runtime/lib/*.rb | wc -l) shims + $n de la stdlib"
cp Empaquetar.ps1 Empaquetar.cmd GUIA.md LICENSE LICENCIAS.md "$ENT/"
echo "$VERSION $(date '+%Y-%m-%d')" > "$ENT/VERSION.txt"
( cd release && rm -f "anil-switch-$VERSION.zip" && ( command -v zip >/dev/null && zip -qr "anil-switch-$VERSION.zip" "anil-switch-$VERSION" || 7z a -bso0 "anil-switch-$VERSION.zip" "anil-switch-$VERSION" >/dev/null ) )
echo
echo "Entrega: $ENT  ($(du -sh "$ENT" | cut -f1))  y release/anil-switch-$VERSION.zip"
echo "Comprobacion: $(ls "$ENT" | wc -l) entradas en la raiz de la entrega:"; ls "$ENT"
