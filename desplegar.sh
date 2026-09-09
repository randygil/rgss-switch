#!/bin/bash
# desplegar.sh <slug> [origen] — copia a la tarjeta y COMPRUEBA que ha llegado.
#
#   SD=/f ./desplegar.sh pokemon-anil out/sdcard/switch/pokemon-anil
#
# El slug decide la carpeta de destino: SD:/switch/<slug>/. El origen, si no
# se da, es la carpeta del mismo nombre que deje Empaquetar.ps1 en out/. Antes
# los dos estaban escritos aqui dentro, que con un motor generico solo sirve
# para desplegar siempre el mismo juego encima del que se queria probar.
#
# Existe por un fallo concreto. La comprobacion que traia el despliegue a mano
# era esta:
#
#     md5sum "$PKG/x" "$SD/x" | awk '{print $1}' | sort -u
#
# y da UNA linea tanto si los dos hashes coinciden como si el fichero de destino
# no existe: md5sum manda el error a stderr, sigue, e imprime un solo hash. Vi
# una linea, la di por buena, y el usuario intento arrancar un NRO que no estaba
# en la tarjeta. Peor: lo que habia fallado no era la copia, era el sistema de
# ficheros, y la comprobacion tampoco lo habria visto.
#
# La regla es que una verificacion tiene que poder FALLAR. Si no distingue el
# caso bueno del malo, no es una verificacion, es un adorno. Aqui se cuenta:
# tantos ficheros pedidos, tantos verificados, y si no cuadra se sale con error.
set -u

RAIZ=$(cd "$(dirname "$0")" && pwd)
SLUG=${1:-}
if [ -z "$SLUG" ]; then
    echo "uso: [SD=/f] ./desplegar.sh <slug> [carpeta de origen]"
    exit 1
fi
SD=${SD:-/f}
JUEGO="$SD/switch/$SLUG"
PKG=${2:-$RAIZ/out/sdcard/switch/$SLUG}
if [ ! -d "$PKG" ]; then
    printf %s\n "no existe la carpeta de origen: $PKG"
    printf %s\n "  (la deja Empaquetar.ps1; o pasala como segundo argumento)"
    exit 1
fi
pedidos=0
buenos=0

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }

# Copia un fichero y comprueba que el destino existe y tiene el mismo hash.
copia() {
    local origen=$1 destino=$2
    pedidos=$((pedidos + 1))

    if [ ! -f "$origen" ]; then
        rojo "FALTA EN ORIGEN: $origen"
        return
    fi
    if ! cp "$origen" "$destino" 2>/dev/null; then
        rojo "NO SE PUDO COPIAR: $origen -> $destino"
        return
    fi
    if [ ! -f "$destino" ]; then
        rojo "NO LLEGO: $destino"
        return
    fi

    local a b
    a=$(md5sum < "$origen" | cut -d' ' -f1)
    b=$(md5sum < "$destino" | cut -d' ' -f1)   # < y no argumento: si no se
                                               # puede leer, md5sum falla y b
                                               # queda vacio, que no casa nunca
    if [ -n "$a" ] && [ "$a" = "$b" ]; then
        buenos=$((buenos + 1))
    else
        rojo "HASH DISTINTO: $destino ($a != $b)"
    fi
}

# La tarjeta tiene que estar montada Y ser escribible antes de empezar.
if [ ! -d "$SD/switch" ]; then
    rojo "no veo $SD/switch: la tarjeta no esta puesta"
    exit 1
fi
if ! touch "$SD/.rgss-prueba" 2>/dev/null; then
    rojo "$SD no admite escritura"
    exit 1
fi
rm -f "$SD/.rgss-prueba"

mkdir -p "$JUEGO/lib"

echo "--- binario y configuracion ---"
copia "$PKG/$SLUG.nro" "$JUEGO/$SLUG.nro"
copia "$PKG/mkxp.json" "$JUEGO/mkxp.json"
# preload.rb y Game.ini son del juego y puede que no los traiga: se copian si
# estan y no se cuentan como falta si no.
for f in preload.rb Game.ini; do
    [ -f "$PKG/$f" ] && copia "$PKG/$f" "$JUEGO/$f"
done

echo "--- sondas de Ruby ---"
for f in "$PKG"/lib/nx-*.rb; do
    copia "$f" "$JUEGO/lib/$(basename "$f")"
done

# El NSP, si Empaquetar.ps1 lo hizo (necesita prod.keys). Va junto a la
# carpeta switch/ de la salida, no dentro.
if [ "${NSP:-1}" = "1" ] && [ -f "$PKG/../../$SLUG.nsp" ]; then
    echo "--- NSP ---"
    copia "$PKG/../../$SLUG.nsp" "$SD/$SLUG.nsp"
    [ -d "$SD/NSP" ] && copia "$PKG/../../$SLUG.nsp" "$SD/NSP/$SLUG.nsp"
fi

echo
if [ "$buenos" -eq "$pedidos" ]; then
    echo "OK: $buenos/$pedidos ficheros verificados en $SD"
else
    rojo "FALLO: solo $buenos de $pedidos ficheros verificados"
    exit 1
fi
