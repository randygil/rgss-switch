# Diagnóstico (no va en la tarjeta)

Sondas de Ruby que sirvieron para encontrar los tirones. Ninguna aporta nada al
juego y algunas cuestan: `nx-metodos.rb` envuelve cientos de métodos.

| Fichero | Qué mide |
|---|---|
| `nx-gc.rb` | Recolector de basura, objetos por fotograma, pila del bucle lento, tramos del fotograma, coste por sprite |
| `nx-metodos.rb` | Tiempo y objetos por método en las pantallas de datos, mochila, equipo y combate; quién hace los `blt` |
| `nx-perfil.rb` | Muestreador de pila (desactivado: sesgado, ver el comentario dentro) |
| `nx-trazas.rb` | Trazas del arranque de Ruby |
| `nx-guardado.rb`, `nx-combate-ya.rb`, `nx-guardar-ya.rb`, `nx-me-ya.rb` | Atajos para provocar una escena concreta sin jugar hasta ella |
| `nx-fondo-desborde.rb` | Desborda el contador del fondo de texturas a proposito y termina en el encuentro con el Pidgey de la ruta 1: la reproduccion de 5.64. Necesita el motor compilado con `NX_FONDO_MAQUETA` y `diagnostico.txt` puesto |
| `nx-sonda-viewport.rb` | Por qué la imagen sale en un rincón: dice la pantalla lógica del MOTOR frente a la que el juego cree tener (`Graphics.width` de Essentials), `haveresizescreen`, `$ResizeFactor`/`$ResizeOffsetX/Y`, `screensize`/`border` y quién es `pbSetResizeFactor` a esas alturas; y registra cada `Graphics.resize_screen` que el juego pida, que el juego se los traga con un `rescue` pelado. Es la que midió el undécimo arreglo de la familia ruby18 |
| `nx-mega-ya.rb` | Monta el equipo del caso (Pikachu con Pikachuita + Charizard 59), lanza el combate contra el Ladrón Matías de la Mansión Quemada y juega el turno sola: cambio y megaevolución, sin tocar el mando |
| `nx-banco-menus.rb` | Banco de los menús de Añil sin mando: carga una partida, recorre Pokédex (lista, entrada, página Datos y su menú), equipo, resumen y mochila con una entrada de mentira, y escribe `banco-menus.log` con el peor fotograma de cada paso y los métodos que se lo comieron. Corre en el PC sobre una copia del juego y en la consola; cómo, en su cabecera y en la bitácora §5.72. Sale del juego al terminar, sin guardar |
| `nx-mapa.rb` | El fotograma NORMAL del mapa, no el malo: cada 300 fotogramas en Scene_Map, la media por fotograma del intérprete, el jugador, los eventos, los spritesets, el TilemapRenderer, el tinte y cada manejador de `:on_frame_update`, más el recolector, los objetos creados, cuántos eventos se actualizan frente a cuántos se ven y cuántos sprites hay que dibujar. Con `nx-mapa-bot.txt` (partida, segundos, "mapa x y") carga la partida sin pasar por el título, anda en cuadrado y se cierra sola; con `nx-mapa-detalle.txt` (una clase por línea) envuelve todos sus métodos. Bitácora §5.74 |
| `nx-lote-ab.rb` | El lote de sprites (§5.74) contra el camino de siempre, **en el mismo fotograma**: cada 15 fotogramas dos `Graphics.snap_to_bitmap`, una con `RGSS_SIN_LOTE` puesta y otra sin ella, y compara los bytes; si difieren guarda las dos en crudo y lista los sprites de la zona. Con el mapa parado, una tanda de montajes sintéticos (espejo, zoom, giro, tonos, mezclas, destello, arbusto, onda, viewports con efectos, Plane en medio). Y en el mapa, 30 s sin lote y 30 s con él, sin fotos, para comparar las `[ritmo]`. Necesita `diagnostico.txt`. Lee las fotos a tiras porque `raw_data` en Ryujinx trunca los anchos múltiplos de 16. Bitácora §5.74-bis |
| `nx-banco-dibujo.rb` | El dibujo en `Bitmap` sin mando, en un arranque: `draw_text` por el atlas de cadenas y por el alijo de cajas (fallo y acierto, y que los dos dan los mismos bytes con estrujado, transparencia y fondo), `set_pixel` en ráfaga tras `clear` con la copia a ceros y leyendo la GPU (y el hexágono del resumen si el juego lo trae), `GC.stat` al llegar al título y lo que tarda `PokeUpdater.check_for_updates`. Necesita `diagnostico.txt` para conmutar los caminos (`RGSS_SIN_ATLAS`, `RGSS_SIN_CEROS`); escribe `banco-dibujo.log` y sale. Bitácora §5.75 |
| `nx-red.rb` (+ `nx-red-servidor.js`) | `HTTPLite` por HTTP y HTTPS y lo que un plugin de guardado en la nube hace con sus ficheros: cabeceras, binario, 3 MB en espejo, redirecciones, errores, `Dir.mkdir`, `File.rename`. Cómo montarla en `docs/red-httplite.md` |

Son del **primer juego** que se portó (Añil), y se nota: `nx-sonido.rb` pide un
efecto de sonido suyo y `nx-guardar-ya.rb` conoce su plugin de guardado. Las que
miden —`nx-gc.rb`, `nx-metodos.rb`, `nx-trazas.rb`— sirven para cualquier juego;
las que provocan una escena concreta hay que retocarlas para el juego que sea.

Para usarlas: `Empaquetar.ps1 -Diagnostico` las copia todas a
`SD:/switch/<slug>/lib/`, carga las que mide `runtime/mkxp.diagnostico.json` y
crea el `diagnostico.txt` que enciende también las sondas del lado C++. Para
añadir una de las otras, ponla a mano en `preloadScript` del `mkxp.json` que
quedó en la tarjeta.

Escriben en `mkxp-ruby.log`, en la misma carpeta del juego. Las líneas `[gc]`,
`[pila]`, `[metodos]` y `[sprites]` emparejan una a una con las `[tiron]` de
`mkxp-boot.log`, que las escribe el lado C++ y sí va siempre.
