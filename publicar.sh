#!/bin/bash
# publicar.sh — etiqueta la version y deja la entrega lista para GitHub Releases.
#
# El .nro se compila en esta maquina (construir.sh); la CI no lo hace todavia.
# Asi que publicar es: comprobar que la entrega que hay en release/ es de la
# version que dice VERSION, etiquetar, empujar la etiqueta y subir el zip.
#
#   ./publicar.sh            usa la version de VERSION
#   ./publicar.sh 1.0.1      cambia VERSION, y hay que haber compilado antes
#   ./publicar.sh --sin-empujar [version]   solo la mitad local
#
# Con `gh` instalado (winget install GitHub.cli) crea la release y adjunta el
# zip. Sin gh, empuja la etiqueta —.github/workflows/release.yml crea un
# BORRADOR con las notas generadas— y te dice donde arrastrar el zip.
#
# --sin-empujar hace todo lo de esta maquina —comprobar la entrega, marcar los
# simbolos como publicados, escribir las notas y poner la etiqueta local— y no
# toca el remoto. Existe porque las dos mitades tienen dueno distinto: la local
# se puede rehacer y deshacer, y la de fuera, una vez que un jugador se ha
# bajado el zip, ya no. Poder preparar una entrega entera y mirarla antes de
# soltarla es la diferencia entre publicar y publicar a ciegas.
set -eu
RAIZ=$(cd "$(dirname "$0")" && pwd); cd "$RAIZ"

SIN_EMPUJAR=""
if [ "${1:-}" = "--sin-empujar" ]; then SIN_EMPUJAR=1; shift; fi

if [ -n "${1:-}" ]; then echo "$1" > VERSION; fi
VERSION=$(cat VERSION)
ZIP="release/anil-switch-$VERSION.zip"
ENT="release/anil-switch-$VERSION"
TAG="v$VERSION"

echo "=== comprobaciones ==="
[ -z "$(git status --short)" ] || { echo "hay cambios sin confirmar; confirma primero"; git status --short; exit 1; }
[ -f "$ZIP" ] || { echo "no existe $ZIP: ejecuta ./construir.sh"; exit 1; }
# El zip tiene que ser de ESTA version: un zip viejo con un VERSION nuevo es el
# error clasico, y se detecta leyendo lo que el propio zip dice de si mismo.
SELLO=$(unzip -p "$ZIP" "anil-switch-$VERSION/VERSION.txt" 2>/dev/null | awk '{print $1}')
[ "$SELLO" = "$VERSION" ] || { echo "el zip dice '$SELLO' y VERSION dice '$VERSION': recompila con ./construir.sh"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "la etiqueta $TAG ya existe; sube VERSION"; exit 1; }
strings -a "$ENT/pokemon-anil.nro" | grep -q "\[build\] $VERSION " || { echo "el .nro de la entrega no lleva el sello $VERSION"; exit 1; }
echo "ok: $ZIP ($(du -h "$ZIP" | cut -f1)) es la $VERSION"

echo "=== simbolos ==="
# Publicar sin archivar el .elf es publicar a ciegas: el dia que un jugador
# mande un volcado, `+0x7abd30` no sera ningun nombre de funcion y habra que
# desensamblar el .nro en crudo y adivinar (README 5.65). Asi que aqui se
# comprueba que construir.sh dejo los simbolos de ESTA compilacion —mismo hash
# de .nro, no solo mismo sello— y se marcan como publicados para que la poda de
# construir.sh no los toque nunca mas.
SELLO_NRO=$(strings -a "$ENT/pokemon-anil.nro" | grep -m1 '^\[build\] ' | sed 's/^\[build\] //')
BNUM=$(printf '%s\n' "$SELLO_NRO" | awk '{print $2}')
SIM="release/simbolos/$VERSION-$BNUM"
[ -f "$SIM/pokemon-anil.elf" ] || { echo "no hay .elf archivado en $SIM: recompila con ./construir.sh (no se publica sin simbolos)"; exit 1; }
HNRO_ENT=$(sha256sum "$ENT/pokemon-anil.nro" | awk '{print $1}')
HNRO_SIM=$(sha256sum "$SIM/pokemon-anil.nro" | awk '{print $1}')
[ "$HNRO_ENT" = "$HNRO_SIM" ] || { echo "el .nro archivado en $SIM no es el de la entrega; recompila con ./construir.sh"; exit 1; }
sed -i 's/^publicada: .*/publicada: si/' "$SIM/SELLO.txt"
grep -q '^publicada: si' "$SIM/SELLO.txt" || echo "publicada: si" >> "$SIM/SELLO.txt"
printf '%-16s %-28s %s\n' "$VERSION-$BNUM" "$SELLO_NRO" "$HNRO_ENT" >> release/simbolos/INDICE.txt
echo "ok: $SIM marcado como publicado (.elf $(du -h "$SIM/pokemon-anil.elf" | cut -f1))"
echo "    para leer una pila:  python resolver-pila.py --sello '$SELLO_NRO' mkxp-boot.log"

echo "=== notas ==="
ULTIMA=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
NOTAS="release/NOTAS-$VERSION.md"
{
  echo "## Pokémon Añil 4.0 para Switch — port $VERSION"
  echo
  echo "Descarga \`anil-switch-$VERSION.zip\`, descomprime, doble clic en \`Empaquetar.cmd\` y elige tu carpeta de Añil 4.0. Guía completa: GUIA.md dentro del zip."
  echo
  echo "### Cambios"
  if [ -n "$ULTIMA" ]; then git log --format='- %s' "$ULTIMA..HEAD"; else git log --format='- %s'; fi
  echo
  echo "El juego no está incluido: hace falta tu propia copia de Pokémon Añil 4.0 para PC."
} > "$NOTAS"
cat "$NOTAS"

echo "=== etiqueta ==="
git tag -a "$TAG" -m "Port $VERSION"

if [ -n "$SIN_EMPUJAR" ]; then
  echo "etiqueta $TAG puesta SOLO en local (--sin-empujar)."
  echo
  echo "La entrega esta lista y nadie de fuera la ha visto todavia:"
  echo "    $RAIZ/$ZIP"
  echo "    $RAIZ/$NOTAS"
  echo
  echo "Cuando quieras soltarla:"
  echo "    git push origin $TAG"
  echo "    gh release create $TAG '$ZIP' --title 'Port $VERSION' --notes-file '$NOTAS'"
  echo
  echo "Y si te arrepientes antes de eso:  git tag -d $TAG"
  exit 0
fi

git push origin "$TAG"

if command -v gh >/dev/null; then
  echo "=== release con gh ==="
  gh release create "$TAG" "$ZIP" --title "Port $VERSION" --notes-file "$NOTAS"
else
  echo
  echo "Sin gh. La etiqueta ya esta en GitHub y la CI habra creado un BORRADOR de release con notas."
  echo "Entra, adjunta este fichero y publica:"
  echo "    $RAIZ/$ZIP"
  echo "    https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')/releases"
fi
