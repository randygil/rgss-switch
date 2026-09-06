# Publicar una versión

1. Sube el número en `VERSION` (por ejemplo `1.0.1`) y confirma el cambio junto
   con lo demás.
2. `./construir.sh` — compila el `.nro`, el `.nsp` si tienes `prod.keys`, y deja
   `release/anil-switch-1.0.1.zip`. Comprueba en la salida que el sello es el
   que esperas.
3. Comprueba que `construir.sh` archivó los símbolos: tiene que haber
   `release/simbolos/1.0.1-bNN/` con el `.elf`, el `.nro` y el `SELLO.txt`.
   `python resolver-pila.py --listar` lo enseña de un vistazo. Sin eso no se
   publica: el día que llegue el volcado de un jugador, su `+0x7abd30` no será
   ningún nombre de función y habrá que desensamblar el `.nro` en crudo y
   adivinar, que es lo que pasó con la 1.0.0 (README §5.65).
4. `./publicar.sh` — verifica que el zip es de esa versión (lee su `VERSION.txt`
   y el sello del `.nro`), comprueba que el `.elf` archivado corresponde a esa
   compilación exacta —compara el sha256 del `.nro`, no sólo el sello—, marca
   esa carpeta de símbolos como publicada para que no se pode nunca, crea la
   etiqueta `v1.0.1`, la empuja y:
   - con `gh` instalado, crea la release y adjunta el zip;
   - sin `gh`, la acción `release.yml` crea un **borrador** con las notas; entra
     en GitHub → Releases, adjunta el zip y publica.

## Preparar la entrega sin soltarla

`./publicar.sh --sin-empujar` hace todo lo de los pasos 3 y 4 que ocurre en esta
máquina —comprobar la entrega, marcar los símbolos, escribir las notas, poner la
etiqueta local— y no toca el remoto. Al terminar te dice las dos órdenes que
faltan para soltarla, y la que la deshace.

Las dos mitades tienen dueño distinto y conviene no mezclarlas: la local se
rehace y se borra cuando quieras; la de fuera, una vez que un jugador se ha
bajado el zip, ya no. Poder mirar la entrega entera antes de soltarla es la
diferencia entre publicar y publicar a ciegas.

## Cuando un jugador manda un volcado

El registro trae la línea `[build] 1.0.1 bNN ...` y una o varias líneas `[exc]`
con direcciones relativas. Con el `.elf` archivado, la pila se lee entera en un
minuto y sin adivinar:

```
python resolver-pila.py docs/consola/<fecha>/mkxp-boot.log
```

La compilación la deduce del propio registro; si el registro no la trae, se le
dice con `--sello "1.0.1 b57"`. Con `--dis 3` enseña además las instrucciones de
alrededor, que es lo que dice si el fallo fue leer de un puntero nulo. Si de esa
compilación no se guardó el `.elf` —las publicaciones anteriores al 5 de
septiembre de 2026—, la herramienta cae sola al desensamblado en crudo del
`.nro` publicado y lo avisa: lo que salga son candidatos, no certezas.

Los símbolos viven en `release/simbolos/`, que **no está en git** a propósito:
un `.elf` sin desnudar son noventa megas. Están en el disco de quien compila. Si
alguna vez se publica desde otra máquina, esa carpeta tiene que viajar con la
publicación.

Lo que publica es sólo el motor: `.nro`, `.nsp`, `mkxp.json`, `lib/`, el
empaquetador y la guía. El juego no va ni puede ir.

`gh` se instala con `winget install GitHub.cli` y se autentica con `gh auth login`.
