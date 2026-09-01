#!/bin/bash
# publicar.sh — etiqueta la version y deja la entrega lista para GitHub Releases.
#
# El .nro se compila en esta maquina (construir.sh); la CI no lo hace todavia.
# Asi que publicar es: comprobar que la entrega que hay en release/ es de la
# version que dice VERSION, etiquetar, empujar la etiqueta y subir el zip.
#
#   ./publicar.sh            usa la version de VERSION
#   ./publicar.sh 1.0.1      cambia VERSION, y hay que haber compilado antes
#
# Con `gh` instalado (winget install GitHub.cli) crea la release y adjunta el
# zip. Sin gh, empuja la etiqueta —.github/workflows/release.yml crea un
# BORRADOR con las notas generadas— y te dice donde arrastrar el zip.
set -eu
RAIZ=$(cd "$(dirname "$0")" && pwd); cd "$RAIZ"

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
