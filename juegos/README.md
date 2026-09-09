# `juegos/` — un perfil por juego

Un perfil es lo que este motor sabe de un juego concreto: cómo reconocerlo, cómo
se llama en la tarjeta, qué carpetas suyas no pueden ir dentro del contenedor y
qué claves de `mkxp.json` necesita. Todo lo demás —el motor, los shims, la base
de `mkxp.json`— es común a todos.

El empaquetador lee estos ficheros; el motor no. Si un juego no tiene perfil,
cae en `generico/perfil.json` y se empaqueta igual, con el slug que salga de su
`Title=`.

## El esquema

```json
{
  "slug": "pokemon-reborn",
  "nombre": "Pokémon Reborn",
  "autor": "Reborn Team",
  "titleid": null,
  "detectar": { "titulo": "^Pokemon Reborn$", "ficheros": ["Scripts/ScriptLoader.rb"] },
  "motor": "ruby31",
  "estado": "sin-probar",
  "mkxp": { "SESourceCount": 12 },
  "preload": ["nx-ejemplo.rb"],
  "sueltos": ["Scripts", "patch", "stdlib", "gems"],
  "excluir": [],
  "rubyLoadpath": ["stdlib", "gems"],
  "notas": "Lo que hay que saber de este juego, en una o dos frases."
}
```

| Clave | Qué es |
|---|---|
| `slug` | Nombre de la carpeta en la tarjeta y del `.nro`. Fija el que salga del `Title=` sólo si hay motivo (Añil fija `pokemon-anil` para no mover las instalaciones que ya existen). |
| `nombre` | El nombre bonito, con acentos. Va al NACP: es lo que se lee en el menú HOME. |
| `autor` | Segunda línea del NACP. Sin él, «Port a Nintendo Switch». |
| `titleid` | 16 hexadecimales. Sin él se calcula: `05` + los 14 primeros de `SHA1(slug)`. |
| `detectar.titulo` | Expresión regular contra el `Title=` del `.ini`. Así se elige el perfil. |
| `detectar.ficheros` | Rutas que tienen que existir en la carpeta del juego. Se comprueban además del título, o en su lugar si no hay título. |
| `motor` | `ruby31`, `ruby18` o `rgss1`. Ver abajo. |
| `estado` | `jugable`, `arranca`, `no-arranca`, `sin-probar`. Lo cambia quien lo prueba, con la fecha en `notas`. |
| `mkxp` | Claves que se meten en el `mkxp.json` compuesto por encima de las del juego. |
| `preload` | Shims de `juegos/<slug>/lib/` que se cargan antes de los scripts, en este orden. |
| `sueltos` | Carpetas que NO pueden ir dentro del contenedor porque el juego las lee con `Dir`/`File`, que no ven dentro de PhysFS. |
| `excluir` | Carpetas que no se copian. Se añaden a las de por omisión (`PBS`, `dist`, `Credits`, `DataBackup`, `DataExport`). |
| `rubyLoadpath` | Carpetas que se añaden a `["lib"]` para `require`. |
| `notas` | Prosa. Lo que hay que saber antes de tocar este juego. |

Todo es opcional menos `slug` y `nombre`.

## `motor`: qué intérprete traía el juego

Este port lleva **CRuby 3.1.7**. Un juego escrito para Ruby 1.8.7 —lo que
llevaba mkxp-z antiguo y lo que lleva el RPG Maker XP original— no tiene por qué
arrancar: `Fixnum`, `String#to_a`, los hashes sin orden y la sintaxis de bloques
cambiaron por el camino. El empaquetador **lo dice y empaqueta igual**, porque
saber si arranca cuesta menos que suponerlo.

- `ruby31` — mkxp-z con Ruby 3.x (`x64-msvcrt-ruby310.dll` al lado, o un
  `Game.exe` grande con la cadena `mkxp-z.exe` y sin `/lib/ruby/1.8`).
- `ruby18` — mkxp-z con Ruby 1.8.7 embebido: `Game.exe` grande con la cadena
  `/lib/ruby/1.8` dentro.
- `rgss1` — RPG Maker XP original: `Game.exe` pequeño (menos de 1 MB) con un
  `RGSS10xE.dll` al lado.

## Añadir un perfil

1. `Empaquetar.ps1 -Juego "<carpeta>" -SoloDetectar` dice el slug, el título, la
   familia de motor y qué carpetas encontró.
2. Crea `juegos/<slug>/perfil.json` con al menos `slug`, `nombre` y
   `detectar.titulo`.
3. Si el juego lee alguna carpeta suya con `Dir` o `File.read` —cargadores de
   scripts, parches, `stdlib`, `gems`— ponla en `sueltos`, o irá dentro del
   contenedor y el juego no la verá.
4. Opcional: `juegos/<slug>/icono.jpg` (JPEG 256×256 baseline) para el menú
   HOME, y `juegos/<slug>/lib/*.rb` con lo que ese juego necesite parchear.
5. Vuelve a empaquetar, pruébalo, y escribe en `estado` y `notas` lo que pasó.
