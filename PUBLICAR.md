# Publicar una versión

1. Sube el número en `VERSION` (por ejemplo `1.0.1`) y confirma el cambio junto
   con lo demás.
2. `./construir.sh` — compila el `.nro`, el `.nsp` si tienes `prod.keys`, y deja
   `release/anil-switch-1.0.1.zip`. Comprueba en la salida que el sello es el
   que esperas.
3. `./publicar.sh` — verifica que el zip es de esa versión (lee su `VERSION.txt`
   y el sello del `.nro`), crea la etiqueta `v1.0.1`, la empuja y:
   - con `gh` instalado, crea la release y adjunta el zip;
   - sin `gh`, la acción `release.yml` crea un **borrador** con las notas; entra
     en GitHub → Releases, adjunta el zip y publica.

Lo que publica es sólo el motor: `.nro`, `.nsp`, `mkxp.json`, `lib/`, el
empaquetador y la guía. El juego no va ni puede ir.

`gh` se instala con `winget install GitHub.cli` y se autentica con `gh auth login`.
