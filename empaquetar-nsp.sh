#!/bin/bash
#===============================================================================
# empaquetar-nsp.sh — convierte el juego en un NSP instalable.
#
# El .nro se lanza desde el menu homebrew, y eso tiene dos inconvenientes que no
# son de comodidad sino de fondo:
#
#   1. Abierto desde el icono del album, el menu homebrew corre como APPLET, y
#      un applet tiene un presupuesto de memoria muy inferior al de una
#      aplicacion. Un juego de 700 MB de recursos con CRuby dentro no cabe ahi.
#   2. No sale en el menu HOME. Hay que entrar al album, esperar al menu
#      homebrew y buscarlo en una lista.
#
# Instalado como NSP el juego es una aplicacion mas: icono propio en el menu
# HOME, arranque directo y el presupuesto de memoria entero.
#
# Los 702 MB de datos NO van dentro del NSP. Se quedan en la SD, en
# /switch/pokemon-anil, por tres razones: el romfs de un NCA es de solo lectura
# —y ahi dentro no se podria guardar la partida—, reinstalar 700 MB en cada
# iteracion es inviable, y actualizar el juego se convierte en copiar ficheros.
# El NSP lleva solo el binario: 5 MB. Del directorio de trabajo ya se encarga
# nxSetupWorkdir(), que al no recibir argv[0] —una aplicacion no lo tiene— cae
# en la ruta convenida de la SD.
#
# Requiere las claves de la consola (prod.keys), que solo salen de tu propia
# Switch con Lockpick_RCM. No se copian a ningun sitio: se leen donde esten.
#===============================================================================
set -e

RAIZ=${RAIZ:-$(cd "$(dirname "$0")" && pwd)}
NSP=$RAIZ/nsp
# DEVKITPRO puede venir en forma POSIX (/opt/devkitpro) de un entorno que no
# es este; se acepta solo si las herramientas estan de verdad ahi.
DEVKITPRO=${DEVKITPRO:-C:/devkitPro}
[ -f "$DEVKITPRO/tools/bin/elf2nso.exe" ] || [ -f "$DEVKITPRO/tools/bin/elf2nso" ] || DEVKITPRO=C:/devkitPro
TOOLS=$DEVKITPRO/tools/bin
EXE=""; [ -f "$TOOLS/elf2nso$EXE" ] && EXE=.exe
# hacbrewpack no viaja en el repo (es de terceros): descargalo de
# https://github.com/The-4n/hacBrewPack/releases y dejalo en tools/hacbrewpack/
# o define HBP con su ruta.
HBP=${HBP:-$RAIZ/tools/hacbrewpack/hacbrewpack.exe}
ELF=$RAIZ/mkxp-z-nx/pokemon-anil.elf
[ -x "$HBP" ] || [ -f "$HBP" ] || { echo "no encuentro hacbrewpack en $HBP"; exit 1; }

CLAVES=${CLAVES:-$USERPROFILE/.switch/prod.keys}
[ -f "$CLAVES" ] || CLAVES="$APPDATA/Ryujinx/system/prod.keys"
[ -f "$CLAVES" ] || { echo "no encuentro prod.keys (ni en ~/.switch ni en Ryujinx). Sacalas de TU consola con Lockpick_RCM y define CLAVES=/ruta/prod.keys"; exit 1; }

# El nombre bueno lleva acentos, y nacptool no puede con ellos: recibe los
# argumentos en la pagina de codigos ANSI del shell. Se le da la version sin
# acentos y luego nacp-utf8.py reescribe las entradas de idioma como toca.
TITULO="Pokémon Añil 4.0"
TITULO_ASCII="Pokemon Anil 4.0"
AUTOR="Port a Nintendo Switch"
VERSION="$(cat "$RAIZ/VERSION" 2>/dev/null || echo 0.0.0)"
TITLEID=05414E494C000000     # 05 + "ANIL" + 000000; el rango 05.. no lo usa Nintendo

echo "=== 1/5  main (NSO) ==="
[ -f "$ELF" ] || { echo "no existe $ELF; compila primero"; exit 1; }
"$TOOLS/elf2nso$EXE" "$ELF" "$NSP/exefs/main"

echo "=== 2/5  main.npdm ==="
"$TOOLS/npdmtool$EXE" "$NSP/npdm.json" "$NSP/exefs/main.npdm"

echo "=== 3/5  control.nacp ==="
"$TOOLS/nacptool$EXE" --create "$TITULO_ASCII" "$AUTOR" "$VERSION" \
    "$NSP/control/control.nacp" --titleid="$TITLEID"
python "$NSP/nacp-utf8.py" "$NSP/control/control.nacp" "$TITULO" "$AUTOR"

echo "=== 4/5  iconos ==="
# El icono se elige por idioma de la consola; AmericanEnglish es el que Horizon
# usa de reserva cuando no encuentra el del idioma configurado.
for idioma in AmericanEnglish Spanish LatinAmericanSpanish; do
    cp "$NSP/icono.jpg" "$NSP/control/icon_$idioma.dat"
done

echo "=== 5/5  NSP ==="
rm -rf "$NSP/salida" "$NSP/nca" "$NSP/temp"
mkdir -p "$NSP/salida" "$NSP/nca" "$NSP/temp"
"$HBP" -k "$CLAVES" \
    --exefsdir  "$NSP/exefs"   \
    --controldir "$NSP/control" \
    --nspdir    "$NSP/salida"  \
    --ncadir    "$NSP/nca"     \
    --tempdir   "$NSP/temp"    \
    --noromfs --nologo 2>&1 | grep -v "Failed to match key"
# grep -v: hacbrewpack avisa de cada clave del fichero que no reconoce Y LA
# IMPRIME. Son claves de la consola; no deben acabar en ningun registro.

SALIDA=$(ls "$NSP/salida"/*.nsp | head -1)
FINAL=$RAIZ/out/pokemon-anil.nsp
mkdir -p "$RAIZ/out"
cp "$SALIDA" "$FINAL"
echo
echo "NSP: $FINAL  ($(du -h "$FINAL" | cut -f1))"
echo "Recuerda: los datos del juego siguen teniendo que estar en"
echo "  SD:/switch/pokemon-anil/"
