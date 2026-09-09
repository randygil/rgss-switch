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
| `nx-mega-ya.rb` | Monta el equipo del caso (Pikachu con Pikachuita + Charizard 59), lanza el combate contra el Ladrón Matías de la Mansión Quemada y juega el turno sola: cambio y megaevolución, sin tocar el mando |

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
