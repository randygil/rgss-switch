#!/bin/bash
# desplegar.sh — copia a la tarjeta y COMPRUEBA que ha llegado.
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

SD=${SD:-/f}
JUEGO="$SD/switch/pokemon-anil"
PKG=/c/anilswitch/out/sdcard/switch/pokemon-anil
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
if ! touch "$SD/.anil-prueba" 2>/dev/null; then
    rojo "$SD no admite escritura"
    exit 1
fi
rm -f "$SD/.anil-prueba"

mkdir -p "$JUEGO/lib"

echo "--- binario y configuracion ---"
copia "$PKG/pokemon-anil.nro" "$JUEGO/pokemon-anil.nro"
copia "$PKG/mkxp.json"        "$JUEGO/mkxp.json"
copia "$PKG/preload.rb"       "$JUEGO/preload.rb"
copia "$PKG/Game.ini"         "$JUEGO/Game.ini"

echo "--- sondas de Ruby ---"
for f in "$PKG"/lib/nx-*.rb; do
    copia "$f" "$JUEGO/lib/$(basename "$f")"
done

if [ "${NSP:-1}" = "1" ]; then
    echo "--- NSP ---"
    copia /c/anilswitch/out/pokemon-anil.nsp "$SD/pokemon-anil.nsp"
    [ -d "$SD/NSP" ] && copia /c/anilswitch/out/pokemon-anil.nsp "$SD/NSP/pokemon-anil.nsp"
fi

echo
if [ "$buenos" -eq "$pedidos" ]; then
    echo "OK: $buenos/$pedidos ficheros verificados en $SD"
else
    rojo "FALLO: solo $buenos de $pedidos ficheros verificados"
    exit 1
fi
