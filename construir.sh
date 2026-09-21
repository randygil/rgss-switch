#!/bin/bash
# construir.sh — de fuentes a entrega, en un solo paso, para quien tenga la
# cadena de herramientas puesta (devkitPro con devkitA64, shell MSYS2).
#
# Lo que hace, en orden:
#   1. Comprueba que estan las herramientas y las bibliotecas ya portadas
#      (libruby-static y las dependencias en out/nx/). Si no estan, dice que
#      guion las construye: eso son horas y no se hace aqui por accidente.
#   2. Regenera los shaders (gen-xxd.sh) si falta generated/.
#   3. Compila el motor (make en mkxp-z-nx/): sale rgss-switch.nro y .elf.
#   4. Monta release/rgss-switch-<VERSION>/ con el layout de CONVENCIONES 7 -mas
#      mkxp.diagnostico.json y diagnostico/, que usa Empaquetar.ps1
#      -Diagnostico- y lo comprime.
#   5. Archiva los simbolos de ESTA compilacion en release/simbolos/, que es lo
#      que permite leer la pila de un volcado de un jugador (README 5.65).
#
# LO QUE YA NO HACE: el .nsp. Hasta la 1.1.1 se empaquetaba aqui, con las
# prod.keys de quien compilaba y para un juego concreto. Con un motor generico
# eso no tiene sentido: el NSP lleva el title id, el nombre y el icono DEL
# JUEGO, y el juego solo lo tiene el jugador. Asi que el NSP -y el NRO con el
# icono de cada juego- los hace Empaquetar.ps1 en la maquina del jugador, con
# las herramientas que van en tools/. Aqui se entrega el motor pelado.
#
# El juego no entra en la entrega, nunca.
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
aviso() { printf 'AVISO: %s\n' "$*"; }

paso "1. Herramientas y bibliotecas"
for h in aarch64-none-elf-g++ elf2nro elf2nso nacptool npdmtool; do
  command -v "$h" >/dev/null || { echo "falta $h: instala devkitPro con devkitA64 y switch-tools (https://devkitpro.org/wiki/Getting_Started)"; exit 1; }
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

paso "3. rgss-switch.nro"
make -C mkxp-z-nx -j"$(nproc 2>/dev/null || echo 4)" 2>&1 | grep -vE "valid for C\+\+" | grep -E "error|NACP|NRO" || true
[ -f mkxp-z-nx/rgss-switch.nro ] || { echo "no salio el .nro"; exit 1; }
[ -f mkxp-z-nx/rgss-switch.elf ] || { echo "no salio el .elf"; exit 1; }

paso "4. Entrega"
ENT="release/rgss-switch-$VERSION"
# Se vacia la carpeta, no se borra. Windows deja handles abiertos sobre
# directorios (el indexador, el antivirus, un Explorer que paso por ahi) y
# entonces `rm -rf "$ENT"` falla con "Device or resource busy" y tumba la
# entrega entera por algo que no tiene nada que ver con compilar. Vaciarla
# consigue lo mismo y no depende de que nadie la tenga mirando.
rm -rf "$ENT"/* "$ENT"/.[!.]* 2>/dev/null || true
mkdir -p "$ENT/motor" "$ENT/lib/io" "$ENT/tools"

# --- motor/ -------------------------------------------------------------
# Las dos formas del mismo binario. El .nro lo lanza el menu homebrew; el NSO
# es lo que mete dentro de un NSP hacbrewpack, porque una aplicacion instalada
# no arranca un NRO. Se sacan del MISMO .elf, asi que el sello de compilacion y
# el codigo son identicos y un volcado de cualquiera de los dos se resuelve con
# el mismo .elf archivado abajo.
cp mkxp-z-nx/rgss-switch.nro "$ENT/motor/"
elf2nso mkxp-z-nx/rgss-switch.elf "$ENT/motor/main"
cp nsp/icono.jpg "$ENT/motor/icono.jpg"
# El title id que va en la plantilla es un relleno valido y NO el de ningun
# juego: Empaquetar.ps1 lo reescribe con el que toque -05 seguido de los 14
# primeros hexadecimales de SHA1(slug), CONVENCIONES 4- antes de llamar a
# npdmtool, y tiene que coincidir con el del NACP. Se dice aqui porque el JSON
# no admite comentarios y dentro del fichero no hay donde escribirlo.
cp nsp/npdm.json "$ENT/motor/npdm.json"

# --- lib/ ---------------------------------------------------------------
cp runtime/lib/*.rb "$ENT/lib/"; cp runtime/lib/io/*.rb "$ENT/lib/io/"
# La stdlib de Ruby 3.1.7 que un juego necesita: los .rb de escritorio (3.3) no
# valen, porque el interprete de la consola es el 3.1.7 y una stdlib de otra
# version falla en sitios que no se parecen a la causa.
n=0
while read -r f; do
  case "$f" in ''|'#'*) continue ;; esac
  mkdir -p "$ENT/lib/$(dirname "$f")"; cp "src/ruby-3.1.7/lib/$f" "$ENT/lib/$f"; n=$((n+1))
done < runtime/lib-stdlib.txt
echo "lib/: $(ls runtime/lib/*.rb | wc -l) shims + $n de la stdlib"

# --- mkxp.base.json y juegos/ -------------------------------------------
# La capa 1 de mkxp.json (CONVENCIONES 5): lo que la Switch necesita siempre,
# sobre lo que el empaquetador va poniendo lo del juego y lo del perfil.
if [ -f runtime/mkxp.base.json ]; then
  cp runtime/mkxp.base.json "$ENT/mkxp.base.json"
elif [ -f runtime/mkxp.json ]; then
  aviso "no hay runtime/mkxp.base.json; se copia runtime/mkxp.json en su sitio."
  aviso "  Es el mkxp.json completo de un juego concreto, no una base: revisalo."
  cp runtime/mkxp.json "$ENT/mkxp.base.json"
else
  aviso "no hay runtime/mkxp.base.json ni runtime/mkxp.json: la entrega sale SIN capa base"
fi

if [ -d juegos ]; then
  cp -r juegos "$ENT/juegos"
  echo "juegos/: $(ls -1d "$ENT"/juegos/*/ 2>/dev/null | wc -l) perfiles"
else
  aviso "no hay juegos/: la entrega sale sin perfiles y todo juego caera en el generico"
fi

# --- tools/ -------------------------------------------------------------
# Las cuatro que Empaquetar.ps1 necesita en la maquina del jugador, que no
# tiene devkitPro. Comprobado que las cuatro arrancan con solo system32 en el
# PATH -solo enlazan KERNEL32 y msvcrt-: no arrastran DLL de msys2 y se copian
# tal cual.
cp "$DKP_POSIX/tools/bin/nacptool.exe" "$ENT/tools/"
cp "$DKP_POSIX/tools/bin/npdmtool.exe" "$ENT/tools/"
# build_romfs es el que hace que el .nro de cada juego SEPA cual es su juego:
# Ryujinx lanza los .nro con argc = 0, asi que la via de argv[0] no contesta
# nunca ahi, y sin un romfs con juego.txt dentro el binario llega a la pantalla
# de aviso. Es el mismo codigo que usa elf2nro --romfsdir (comprobado: las dos
# imagenes salen identicas byte a byte).
cp "$DKP_POSIX/tools/bin/build_romfs.exe" "$ENT/tools/"
if [ -f tools/hacbrewpack/hacbrewpack.exe ]; then
  cp tools/hacbrewpack/hacbrewpack.exe "$ENT/tools/"
else
  aviso "no esta tools/hacbrewpack/hacbrewpack.exe: la entrega no podra hacer NSP (solo .nro)"
fi

# --- la biblioteca de shims --------------------------------------------
# Los parches de Ruby que antes vivian sueltos en juegos/<slug>/lib/ o
# cableados en Empaquetar.ps1. Ahora son una biblioteca con catalogo y cada
# perfil elige por nombre lo que necesita. Si esto no viaja en la entrega, el
# empaquetador cae a la lista cableada de reserva: funciona igual que antes,
# pero ningun perfil puede pedir un shim nuevo.
if [ -d runtime/shims ]; then
  mkdir -p "$ENT/shims"
  cp runtime/shims/* "$ENT/shims/"
  echo "shims/: $(ls -1 runtime/shims/*.rb | wc -l) shims + catalogo.json"
else
  aviso "no hay runtime/shims/: los perfiles que pidan shims se empaquetaran sin ellos"
fi

# --- el modo diagnostico ------------------------------------------------
# Lo monta Empaquetar.ps1 -Diagnostico: otra configuracion (registro linea a
# linea, autopruebas del arranque) y unos shims de Ruby que solo sirven para
# depurar. No se empaquetan en una instalacion normal, pero tienen que VIAJAR
# en la entrega: quien se encuentra un fallo raro esta lejos de este arbol y
# lo unico que tiene es el zip.
if [ -f runtime/mkxp.diagnostico.json ]; then
  cp runtime/mkxp.diagnostico.json "$ENT/mkxp.diagnostico.json"
else
  aviso "no hay runtime/mkxp.diagnostico.json: Empaquetar.ps1 -Diagnostico no tendra configuracion"
fi
if ls runtime/diagnostico/*.rb >/dev/null 2>&1; then
  mkdir -p "$ENT/diagnostico"
  cp runtime/diagnostico/*.rb "$ENT/diagnostico/"
  echo "diagnostico/: $(ls -1 "$ENT"/diagnostico/*.rb | wc -l) shims"
else
  aviso "no hay runtime/diagnostico/*.rb: Empaquetar.ps1 -Diagnostico no tendra shims"
fi

cp Empaquetar.ps1 Empaquetar.cmd GUIA.md LICENSE LICENCIAS.md "$ENT/"
echo "$VERSION $(date '+%Y-%m-%d')" > "$ENT/VERSION.txt"
( cd release && rm -f "rgss-switch-$VERSION.zip" && ( command -v zip >/dev/null && zip -qr "rgss-switch-$VERSION.zip" "rgss-switch-$VERSION" || 7z a -bso0 "rgss-switch-$VERSION.zip" "rgss-switch-$VERSION" >/dev/null ) )

paso "5. Simbolos"
# Sin el .elf SIN DESNUDAR de la compilacion exacta, un volcado de excepcion de
# un jugador es una direccion relativa y nada mas: `+0x7abd30` no dice ninguna
# funcion. La 1.0.0 se publico sin archivarlo y hubo que desensamblar el .nro en
# crudo y comparar firmas de instrucciones contra una compilacion posterior para
# ponerle nombre a la pila (README 5.65, docs/consola/20260905-pidgey/). Eso
# funciono por suerte —la funcion no habia cambiado— y la suerte no se planifica.
#
# Asi que cada compilacion deja aqui su .elf, su .nro y un SELLO.txt con los
# hashes: el .nro archivado es byte a byte el que se entrega, de modo que el
# hash empareja sin dudas un registro de jugador con su compilacion.
SELLO_NRO=$(strings -a "$ENT/motor/rgss-switch.nro" | grep -m1 '^\[build\] ' | sed 's/^\[build\] //')
BNUM=$(printf '%s\n' "$SELLO_NRO" | awk '{print $2}')
if [ -z "$BNUM" ]; then
  echo "AVISO: el .nro no lleva sello legible; no se archivan simbolos"
else
  SIM="release/simbolos/$VERSION-$BNUM"
  mkdir -p "$SIM"
  cp mkxp-z-nx/rgss-switch.elf     "$SIM/rgss-switch.elf"
  cp "$ENT/motor/rgss-switch.nro"  "$SIM/rgss-switch.nro"
  {
    echo "version:  $VERSION"
    echo "sello:    $SELLO_NRO"
    echo "fecha:    $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "commit:   $(git rev-parse HEAD 2>/dev/null || echo 'sin git')$([ -n "$(git status --short 2>/dev/null)" ] && echo ' (con cambios sin confirmar)')"
    echo "nro:      $(sha256sum "$SIM/rgss-switch.nro" | awk '{print $1}')  $(stat -c %s "$SIM/rgss-switch.nro") bytes"
    echo "elf:      $(sha256sum "$SIM/rgss-switch.elf" | awk '{print $1}')  $(stat -c %s "$SIM/rgss-switch.elf") bytes"
    echo "publicada: no"
  } > "$SIM/SELLO.txt"
  echo "$SIM  ($(du -sh "$SIM" | cut -f1))"

  # Poda. Un .elf son noventa megas y aqui se compila muchas veces al dia; lo
  # que interesa guardar para siempre es la compilacion que se PUBLICO, no las
  # veinte de ese mismo dia. De cada version se conservan enteras las tres mas
  # recientes y todas las que publicar.sh haya marcado; de las demas queda el
  # SELLO.txt, que pesa nada y deja el rastro por si alguna vez aparece un
  # registro de una compilacion intermedia que se probo en la consola.
  ls -1dt release/simbolos/"$VERSION"-b* 2>/dev/null | tail -n +4 | while read -r v; do
    grep -qE '^(publicada|conservar): si' "$v/SELLO.txt" 2>/dev/null && continue
    [ -f "$v/rgss-switch.elf" ] || continue
    rm -f "$v/rgss-switch.elf" "$v/rgss-switch.nro"
    echo "  podado (queda el SELLO.txt): $v"
  done
fi

echo
echo "Entrega: $ENT  ($(du -sh "$ENT" | cut -f1))  y release/rgss-switch-$VERSION.zip"
echo "Comprobacion: $(ls "$ENT" | wc -l) entradas en la raiz de la entrega:"; ls "$ENT"
