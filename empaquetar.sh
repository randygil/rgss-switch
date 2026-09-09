#!/bin/bash
#===============================================================================
# empaquetar.sh — el empaquetador desde la shell, para los flujos de desarrollo.
#
# No duplica nada: llama a Empaquetar.ps1 con -SinInterfaz. Todo lo que sabe del
# formato de la tarjeta está en el .ps1, que es el que viaja en la entrega y el
# que tiene que funcionar en un Windows limpio sin nada instalado. Esto es sólo
# la puerta de al lado, la que usan iterate.sh y las manos de quien está en la
# shell de devkitPro y no quiere abrir una ventana.
#
#   ./empaquetar.sh "<carpeta del juego>" "<carpeta de salida>" [zip|carpetas|--solo-motor]
#
#   ./empaquetar.sh "/c/juegos/Pokemon Opalo" /c/rgss-switch/out
#   ./empaquetar.sh "/c/juegos/Pokemon Opalo" /d/ carpetas
#   ./empaquetar.sh "/c/juegos/Pokemon Opalo" /d/ --solo-motor
#
# --solo-motor rehace solo el .nro, el mkxp.json y lib/ de una instalación que
# ya está en la tarjeta. No copia un solo mega del juego: es lo que hace falta
# para actualizar el motor, o para probar un shim veinte veces en una tarde.
#
# Variables de entorno, todas opcionales:
#   ENTREGA=<carpeta>   la entrega a usar (por omisión, la raíz de este repo)
#   CLAVES=<fichero>    prod.keys, si no están donde el .ps1 las busca
#   DIAGNOSTICO=1       añade las sondas de runtime/diagnostico y diagnostico.txt
#   DETECTAR=1          no copia nada: sólo dice qué juego es y qué perfil le toca
#   SOLOMOTOR=1         lo mismo que el tercer argumento --solo-motor
#===============================================================================
set -u

RAIZ=${RAIZ:-$(cd "$(dirname "$0")" && pwd)}
JUEGO=${1:-}
SALIDA=${2:-}
MODO=${3:-zip}
ENTREGA=${ENTREGA:-$RAIZ}

if [ -z "$JUEGO" ]; then
  echo "uso: ./empaquetar.sh \"<carpeta del juego>\" \"<carpeta de salida>\" [zip|carpetas|--solo-motor]"
  echo "     DETECTAR=1 ./empaquetar.sh \"<carpeta del juego>\"    (sólo detecta)"
  exit 1
fi
[ -d "$JUEGO" ] || { echo "no existe la carpeta del juego: $JUEGO"; exit 1; }

# PowerShell no entiende /c/... de MSYS2. Sí entiende C:/..., así que se
# convierte con cygpath cuando está y a mano cuando no (§5.15 del README: la
# forma de la ruta ha costado más de una tarde en este proyecto).
aWindows() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"
  else echo "$1" | sed -E 's#^/([a-zA-Z])/#\1:/#'
  fi
}

ARGS=(-NoProfile -ExecutionPolicy Bypass -File "$(aWindows "$RAIZ/Empaquetar.ps1")"
      -Juego "$(aWindows "$JUEGO")" -Entrega "$(aWindows "$ENTREGA")" -SinInterfaz)

# El tercer argumento hace dos cosas por comodidad: elegir el modo de
# contenedor o pedir --solo-motor. No se confunden porque el .ps1 valida el modo.
case "$MODO" in --solo-motor|solo-motor) SOLOMOTOR=1 ;; esac

if [ "${DETECTAR:-0}" = "1" ]; then
  ARGS+=(-SoloDetectar)
elif [ "${SOLOMOTOR:-0}" = "1" ]; then
  # Aqui NO se hace mkdir: -SoloMotor actualiza una instalacion que ya esta, y
  # crear la carpeta a ciegas convertiria una ruta mal escrita en un .nro
  # solitario en medio de la nada en vez de en un error.
  [ -n "$SALIDA" ] || { echo "falta la carpeta de salida"; exit 1; }
  ARGS+=(-Salida "$(aWindows "$SALIDA")" -SoloMotor)
else
  [ -n "$SALIDA" ] || { echo "falta la carpeta de salida"; exit 1; }
  mkdir -p "$SALIDA"
  ARGS+=(-Salida "$(aWindows "$SALIDA")" -Contenedor "$MODO")
fi
[ -n "${CLAVES:-}" ] && ARGS+=(-Claves "$(aWindows "$CLAVES")")
[ "${DIAGNOSTICO:-0}" = "1" ] && ARGS+=(-Diagnostico)

powershell "${ARGS[@]}"
