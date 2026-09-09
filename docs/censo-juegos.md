# Censo de juegos: qué tan lejos está cada fan game del motor

Siete juegos descargados más Añil, que es el que ya corre. Lo que sigue es lo
que se midió, no lo que se supone. Cada cifra sale de un comando; los datos
crudos —listados, salidas del comprobador de sintaxis, greps, `censo.json`—
están en `tmp/censo/<slug>/`, que no entra en el repositorio.

La pregunta del censo es una sola: **si mañana se empaqueta este juego con el
perfil genérico y se enciende la consola, ¿dónde se para?** Añil sirve de
patrón porque de él se sabe la respuesta.

## Resumen

| Juego | Familia | Essentials | Scripts | Errores de sintaxis | Recursos | Veredicto |
|---|---|---|---|---|---|---|
| **Pokémon Añil 4.0** (`pokemon-anil`) | ruby31 | v21.1 | 450 / 162.794 líneas | **0 de 450** | 0,64 GB / 22.142 fich. | corre; es el patrón |
| **Project Vanguard 4.0.3** (`pokemon-vanguard`) | ruby31 | v20.1 | 432 / 176.701 líneas | **0 de 432** | 1,51 GB útiles / 1,77 GB en disco | debería arrancar con el perfil genérico |
| **Pokémon Reborn 19.5.0** (`pokemon-reborn`) | ruby31 | v19 (base) | 193 / 317.428 líneas | **0 de 193** | 0,68 GB / 12.619 fich. | necesita perfil: `stdlib`, `gems`, `patch` y tres claves de mkxp.json que este motor no tiene |
| **Pokémon Ópalo 2.11** (`pokemon-opalo`) | ruby18 | clásico (v16) | 214 / 136.170 líneas | 3 de 214 → 25 líneas | 0,62 GB / 16.591 fich. | necesita perfil ruby18: 25 líneas de sintaxis + 13 `Win32API` de nivel superior |
| **Pokémon Z 2.13** (`pokemon-z`) | ruby18 | clásico (v16) | 235 / 160.766 líneas | 3 de 235 → 25 líneas | 0,84 GB / 19.055 fich. | igual que Ópalo, y además `MKXP.zinflate` en su `preload.rb` |
| **Pokémon Iberia 2.10** (`pokemon-iberia`) | ruby18 | clásico (v15/v16) | 168 / 119.682 líneas | 4 de 168 → 28 líneas | 0,46 GB / 13.921 fich. | igual que Ópalo, y depende de `KleinBitmap.dll` para el mapa |
| **Pokémon Titán 2.10** (`pokemon-titan`) | ruby18 | clásico (v15/v16) | 167 / 118.848 líneas | 4 de 167 → 28 líneas | 0,40 GB / 14.572 fich. | idéntico a Iberia |
| **Pokémon Uranium 1.3.2** (`pokemon-uranium`) | rgss1 | clásico (v16/v17) | 260 / 144.580 líneas | 2 de 260 → 2 líneas | 0,30 GB / 6.266 fich. | necesita perfil rgss1: audio entero por FmodEx (DLL nativa) y datos dentro de `Uranium.rgssad` |

Los slugs salen del `Title=` de `Game.ini` por la regla de §1 de
`CONVENCIONES.md`. `Pokemon  Vanguard` (con dos espacios) colapsa a
`pokemon-vanguard`.

## Cómo se midió

**Familia.** `md5sum` de cada ejecutable y `strings` sobre él, más las DLL de
la raíz y el `Library=` de `Game.ini`.

**Sintaxis.** Los scripts se extraen a `.rb` con `dump-scripts.py` (Marshal +
zlib) y se pasan por el Ruby 3.1.4 del PC, la misma serie que el 3.1.7 de la
consola. **No** con `ruby -c`: con
`RubyVM::InstructionSequence.compile`, que es lo que de verdad hace mkxp-z al
evaluar cada sección. La diferencia importa: `ruby -c` da *Syntax OK* sobre
`0075_PokeBattle_MoveEffects.rb` de Iberia y ese fichero no compila —`break`
en el cuerpo de un método es un error de compilación, no de análisis. Se
comprueba también el fuente releído como CP1252, para separar "esto es
Latin-1" de "esto es Ruby 1.8"; no hizo falta, ver abajo.

**Todo lo demás** son greps con recuento sobre el corpus extraído
(`tmp/censo/<slug>/greps.txt`), tamaños del sistema de ficheros y las cabeceras
IHDR de los PNG leídas sin decodificar la imagen.

## Lo que Añil calibra

Un censo sin patrón es una lista de sospechas. Añil corre, así que todo lo que
aparece en Añil con el mismo peso que en otro juego **no es un problema**, y
tres de los indicadores que uno escribiría de memoria se caen enteros:

- `.nitems` — 7 usos en Añil, 7 en cada uno de los otros. No es `Array#nitems`
  de Ruby 1.8: es un método que los propios juegos definen en
  `PokemonStorage` (`def nitems`). Descartado.
- `.type`, `.id`, `.index(`, `.to_s` — Añil tiene 90, 689, 48 y 186; los demás,
  menos. Son `pokemon.type`, `species.id`, `Array#index`... En un juego de
  Pokémon estos greps miden la palabra "tipo", no `Object#type`. **No
  discriminan y no se usan para nada en este informe.**
- PNG de más de 4096 píxeles — Añil tiene **3.395 de 17.814** y corre: los
  tilesets altos entran por el camino de *mega surface* de mkxp-z y se quedan
  en RAM (README 5.70). Es un coste conocido de carga, no un impedimento.
  Ningún juego del censo supera esa cifra salvo Z (3.281), que está en el
  mismo orden.

Lo que sí discrimina, medido: `Win32API` (0 en Añil, 134–166 en la familia
ruby18 y en Uranium), la sintaxis de 1.8 (0 en Añil), y las DLL nativas.

## Pokémon Añil 4.0 — `pokemon-anil` (el patrón)

Se mide sobre `C:\anilswitch\out\sdcard\switch\pokemon-anil`, que es lo que
está en la tarjeta.

- **Motor**: ruby31. `mkxp.json` propio con `preloadScript` de seis shims más
  el `preload.rb` del juego, `rubyLoadpath: ["lib"]`, `rgssVersion: 1`,
  `SESourceCount: 12`.
- **Essentials**: `VERSION = "21.1"`, con restos de v20 y v21 en los
  comentarios. `GAME_VERSION = "4.1.1"`, `MKXPZ_VERSION = "2.4.2/d13f35c"`.
- **Scripts**: `Data/Scripts.rxdata`, 450 secciones, 162.794 líneas. **450 de
  450 compilan.** Ninguna sección tiene bytes que no sean UTF-8 válido.
- **Plataforma**: 0 `Win32API`. 391 usos de `System.` (la API de mkxp-z) en 81
  ficheros; 4 de `HTTPLite`; 1 `require_relative 'Ruby Library 3.3.0/json'`;
  60 de `Encoding` en 8 ficheros; 34 `Dir.glob/foreach/entries`, de los que 1
  cae sobre `Data|Graphics|Audio`.
- **Recursos**: Data 267 fich./47 MB, Graphics 17.824/282 MB, Audio 3.934/322
  MB (2.188 wav, 1.702 ogg, 44 mp3), Fonts 10. PNG mayor:
  `Graphics/Tilesets/Exterior1.png`, 256 × 23.370.
- El `preload.rb` del juego llama a `MKXP.puts` en su primera línea —la API de
  JoiPlay, no la de mkxp-z— y por eso el motor carga `lib/nx-compat.rb`
  **antes**. Ese detalle vuelve a aparecer en Z.

## Project Vanguard 4.0.3 — `pokemon-vanguard`

- **Motor**: ruby31, y es el caso más limpio. `Game.exe` de 16,3 MB
  (`bd65c652b9bbb01478f47ecb9e3e637e`) con las rutas de compilación
  `C:/msys64/home/bryce/mkxp-z/...` dentro, y `x64-msvcrt-ruby310.dll` de 8,7
  MB al lado. `Game.ini` declara `Library=RGSS104E.dll`.
- **Essentials**: `VERSION = "20.1"`, `GAME_VERSION = "1.0.0"`.
- **Scripts**: en dos sitios. `Data/Scripts.rxdata` son 583 bytes y contiene
  únicamente el cargador de Essentials v20+ (`Dir.foreach` + `File.open` +
  `eval` sobre `Data/Scripts`, recursivo por subcarpetas). Los scripts reales
  son **304 ficheros sueltos** en `Data/Scripts/` (24 subcarpetas numeradas),
  135.228 líneas, más **128 secciones** en `Data/PluginScripts.rxdata`
  (41.041 líneas), que son la forma compilada de los 128 `.rb` de `Plugins/`
  (33 plugins: Deluxe Battle Kit, Voltseon's Pause Menu, Gen 8/9 Packs...).
  Total 432 ficheros y 176.701 líneas.
- **Sintaxis**: **432 de 432 compilan.** Cero errores.
- **Plataforma**: 0 `Win32API`. 41 `System.` en 19 ficheros; 2 `HTTPLite`
  (`003_HTTP_Utilities.rb`, envuelto en `rescue ""`); 38
  `Dir.glob/foreach/entries` en 9 ficheros, uno de ellos sobre `Data/`
  (`Dir.glob(mapData)` del compilador de mapas). Ningún `require`.
- **Lo que hay que vigilar**: `005_PluginManager.rb:616` hace
  `File.open("Data/PluginScripts.rxdata", "wb")` — reescribe el contenedor de
  plugins cuando detecta que `Plugins/` cambió. Con `Data/` dentro de
  `datos.zip` eso no se puede hacer, y el cargador de `Data/Scripts/` usa
  `Dir.foreach` + `File.open`, que tampoco ve dentro de PhysFS. Ambas cosas
  ya están previstas en §2 de `CONVENCIONES.md`: `Data/Scripts/` va suelta.
  Falta decidir si `Data/PluginScripts.rxdata` va suelta también.
- **Recursos**: Data 655/40 MB, Graphics 18.614/319 MB, Audio 5.006/1.190 MB
  (3.368 wav, 1.586 ogg, 50 mp3), Fonts 8 (la familia *power clear*, la misma
  que Añil). PNG mayor: `Graphics/Tilesets/magiscarf2.png` 6.656 × 5.504 —el
  único del censo ancho *y* alto a la vez, 63 pasan de 4096 en algún lado.
- **Carpetas fuera de las cinco**: `Plugins/` 162 fich./1,5 MB (fuente de los
  plugins, va suelta), `PBS/` 91/11,5 MB, `Mods/` con un solo `console.rb`,
  `Credits/`, `DataBackup/` 117/1,9 MB, `DataExport/` 317/25,8 MB y
  **`dist/` 3.499 fich./222,3 MB** (una copia de trabajo con `PokeRover`
  dentro). `PBS`, `DataBackup`, `DataExport`, `dist` y `Credits` ya están en
  la lista de exclusión por omisión de §2: se quedan fuera y ahorran 261 MB.
- **`mkxp.json`**: `defScreenW/H` 512×384, `subImageFix: true`,
  `enableBlitting: false`, `bindingNames`, y `midiSoundFont: "soundfont.sf2"`
  — **un fichero que no existe en el juego**, y no hay ningún `.sf2` en toda
  la carpeta. Como tampoco hay ningún `.mid` (5.006 ficheros de audio, ni uno
  MIDI), la clave se puede ignorar sin consecuencias.
- **Veredicto**: debería arrancar con el perfil genérico. Lo único a componer
  es `sueltos: ["Data/Scripts", "Plugins"]` y las exclusiones, que ya son las
  de por omisión.

## Pokémon Reborn 19.5.0 — `pokemon-reborn`

- **Motor**: ruby31, pero **no es mkxp-z 2.4.2 de serie**. `Game.exe` de 19,3
  MB (`abcb0669b027f09dd55d4ee0a5ffc57e`) lleva dentro
  `// mkxp-z modifications Copyright 2022-2023 Splendide Imaginarius.` y rutas
  de compilación `D:/a/mkxp-z/mkxp-z/...`. Trae `x64-msvcrt-ruby310.dll` de
  10,6 MB, `libssl-3-x64.dll`, `libcrypto-3-x64.dll`, `cacert.pem`,
  `discord_game_sdk.dll`, `libTolk.dll` y `nvdaControllerClient.dll` (lector
  de pantalla).
- **Essentials**: base v19 (`Essentials v19` en los comentarios);
  `GAMEVERSION = '19.5.0'` es la versión del juego, no la de Essentials.
- **Scripts**: `Data/Scripts.rxdata` son 107 bytes y hacen exactamente esto:
  ```ruby
  $boottime = Time.now
  eval(File.read("Scripts/Reborn/Bootstrap.rb"))
  eval(File.read("Scripts/ScriptLoader.rb"))
  ```
  Los scripts reales son **193 ficheros** en `Scripts/` en la raíz (10,2 MB),
  con subcarpetas `Reborn/`, `Online/` y `Randomizer/`. **317.428 líneas: el
  corpus más grande del censo**, casi el doble que Añil en la mitad de
  ficheros.
- **Sintaxis**: **193 de 193 compilan.** Cero errores.
- **Plataforma**, y aquí está el trabajo:
  - 4 `require`: `zlib`, `socket`, `discord`, `poke-api-v2`. Los dos últimos
    salen de `gems/` (que trae **`discord.so`, una extensión nativa de
    Windows**) y el `socket` de `Scripts/Online/Network.rb:1`, con
    `TCPSocket.new(NETWORK_HOST, NETWORK_PORT)` en la línea 39. Añil ya tiene
    un `runtime/lib/socket.rb` postizo para justamente esto.
  - 58 referencias a Discord en 5 ficheros; 5 a `Net::HTTP` en 2
    (`Updater.rb`, que se conecta al arrancar), 6 a `HTTPLite`, 15 a
    `$stdout`/`$stderr` en 4.
  - 14 `Win32API` en 4 ficheros; los de `Messages.rb:935-936` cargan
    `libTolk.dll` para el lector de pantalla, y el de
    `Event YEET professional SP2.rb` va protegido con `defined?`.
  - 3 `MKXP.` en `ScriptLoader.rb`, todos bajo `if $joiplay` o comentados.
  - 34 `System.` (API de mkxp-z, ésa sí la hay).
- **`mkxp.json`**: `defScreenW/H`, `pathCache`, `bindingNames` con **once**
  botones (`d`, `e`, `f` además de los ocho) y tres claves que **no existen en
  `src/mkxp-z/src/config.cpp` de 2.4.2**: `patches: ["patch"]`,
  `inputRepeatStart: 0.3`, `inputRepeatDelay: 0.05`. `patches` es la
  superposición de ficheros que documenta `Modding.txt` ("los ficheros de
  `patch/` sustituyen a los del juego base en Audio, Graphics, Fonts y Data").
  En este juego `patch/` viene **vacía**, así que ignorar la clave no rompe
  nada hoy; los mods del jugador sí dejarían de funcionar.
- **Carpetas fuera de las cinco**: `Scripts/` 193/10,2 MB, `stdlib/` 1.010
  fich./6,5 MB (la biblioteca estándar de Ruby 3.1 en fuente, incluido
  `bundler`), `gems/` 154/0,4 MB, `patch/` vacía. Las cuatro van sueltas y en
  `rubyLoadpath`.
- **Recursos**: Data 932/73 MB, Graphics 7.684/48 MB, Audio 2.637/554 MB
  **todo en ogg, sin una sola excepción** —el único juego del censo con un
  solo formato de audio—, Fonts 9. PNG mayor:
  `Graphics/Animations/PRAS- Multi Attack.png` 960 × 7.296.
- **Veredicto**: necesita perfil. `sueltos: ["Scripts", "patch", "stdlib",
  "gems"]`, `rubyLoadpath: ["stdlib", "gems"]`, un `socket.rb` postizo como el
  de Añil y algo que haga inofensivos `discord` y `poke-api-v2`. El código
  compila entero: la distancia es de plataforma, no de lenguaje.

## Ópalo, Iberia, Titán y Z — la familia `ruby18`

Los cuatro comparten **el mismo `Game.exe`**, byte a byte:
`23d5865cd64e4c3ec58314fa8ce2d484`, 11.722.254 bytes. `strings` sobre él da
`mkxp-z`, `mkxp-z.exe`, `/lib/ruby/1.8` y `/lib/ruby/1.8/i386-mingw32`: es
mkxp-z con **Ruby 1.8.7 embebido**, la variante que se distribuye para correr
juegos de Essentials clásico sin tocarles los scripts. Los cuatro declaran
`Library=RGSS104E.dll` y traen las tres DLL de RGSS de adorno.

Versión de Essentials: **no se puede fijar con exactitud**. Ninguno define
`ESSENTIALSVERSION` —y Z incluye `LukaUtilities.rb`, cuyo
`def isVersion17?; return defined?(ESSENTIALSVERSION); end` lo daría por
anterior a v17—. Por los nombres de sección: Ópalo y Z usan el esquema
`PScreen_`/`PSystem_`/`PField_` (44 secciones), Iberia y Titán todavía usan
`PokemonLoad`/`PokemonUtilities` (3). Ninguno tiene `module Settings`: las
constantes son globales en mayúsculas (`MAXIMUMLEVEL`, `DEFAULTSCREENWIDTH`).
Es Essentials clásico, alrededor de v16; Iberia y Titán, un poco más viejos.

### Sintaxis: mucha menos de la que el nombre "Ruby 1.8" sugiere

| | Ópalo | Iberia | Titán | Z | Uranium |
|---|---|---|---|---|---|
| Scripts | 214 | 168 | 167 | 235 | 260 |
| No compilan con 3.1 | **3** | **4** | **4** | **3** | **2** |
| `when X:` | 23 (1 fich.) | 23 (1 fich.) | 23 (1 fich.) | 23 (1 fich.) | 0 |
| `break` en cuerpo de método | 0 | 3 | 3 | 0 | 0 |
| `retry` fuera de `rescue` | 1 | 1 | 1 | 1 | 0 |
| regex con `\xNN` sin `/n` | 1 | 1 | 1 | 1 | 2 |
| Bytes que no son UTF-8 válido | 0 fich. | 1 fich. | 1 fich. | 0 fich. | 1 fich. |

Y esto se probó, no se estimó (`tmp/censo/arreglos-sintaxis.txt`). Cuatro
reglas de sustitución, aplicadas y recompiladas hasta que el fichero pasa:

1. `/^(\s*when\b.*[^:\s]):(\s*(#.*)?)$/` → `\1 then\2`
2. `break` en cuerpo de método → `return`
3. `retry` dentro de un bucle → `redo`
4. literal de expresión regular con `\xNN` → añadirle el modificador `/n`

Resultado: **28 líneas en 4 ficheros** (Iberia, Titán), **25 en 3** (Ópalo, Z),
**2 en 2** (Uranium) — y después de eso **compilan todos los scripts de los
cinco juegos**. Sobre corpus de 118.000 a 160.000 líneas, eso es entre el
0,002 % y el 0,02 % del fuente.

Los 23 `when X:` están, en los cuatro juegos, en el mismo fichero
(`AudioUtilities.rb`, líneas 919–964, los tonos del teléfono). El `retry` está
en el mismo fichero y casi en la misma línea en los cuatro
(`PokemonLoad`/`PScreen_Load`, línea 508 o 544): es la pantalla de carga
reintentando tras borrar una partida.

**Ni un solo fichero está en Latin-1.** Se comprobó releyendo en CP1252 todo lo
que fallaba: los tres ficheros con bytes fuera de UTF-8 los tienen dentro de
literales de expresión regular (`\x8D`, `\x8F`), no en texto, y el arreglo es
el mismo `/n` del punto 4. El apartado que este censo tenía reservado para
"fuentes en Latin-1 sin comentario de codificación" queda vacío.

### El problema de verdad: `Win32API`

| | Ópalo | Iberia | Titán | Z | Uranium | Añil |
|---|---|---|---|---|---|---|
| Referencias a `Win32API` | 164 | 145 | 134 | 165 | 166 | **0** |
| Ficheros afectados | 23 | 21 | 20 | 25 | 29 | 0 |
| `Win32API.new` en el nivel superior de un script | **13** | **13** | **12** | **14** | **13** |0|

El motor de la Switch **no tiene `Win32API`**. En mkxp-z lo aporta
`binding/miniffi-binding.cpp`, que hace `rb_define_const(rb_cObject,
"Win32API", cMiniFFI)` sobre `SDL_LoadObject`, y el `Makefile` de
`mkxp-z-nx` lo excluye a propósito de la lista de fuentes ("un glob de
`binding/` arrastraría cusl-binding, miniffi-binding y miniffi"). Aunque se
compilara, en Horizon no hay `user32.dll` que cargar.

Las trece o catorce instancias de nivel superior son las que matan el arranque:
son asignaciones a constantes que se evalúan al cargar el script, no dentro de
un método. `NameError: uninitialized constant Win32API` en la sección 21 de
168, y el juego no llega ni a la pantalla de título.

Qué se pide por ahí, contado en Iberia: 6 × `kernel32!RtlMoveMemory`, 3 ×
`winmm!mciSendString`, 9 llamadas de `winmm` para reproducir wave a mano, todo
el juego de `user32` para mover la ventana, leer el ratón y el teclado
(`GetKeyboardState`, `ToUnicode`, `GetCursorPos`, `SetWindowPos`), 2 ×
`rubyscreen.dll!TakeScreenshot`, `gdi32!AddFontResource`,
`advapi32!GetUserName`, `kernel32!GetSystemPowerStatus` (¡el nivel de batería!)
y `Get/WritePrivateProfileString` para el `.ini`.

Un `Win32API` postizo que devuelva un objeto cuyo `call` no haga nada y
devuelva 0 desbloquea el arranque y desactiva de paso el editor de
animaciones, la captura de pantalla y el segundo sistema de audio. Es un shim
de treinta líneas. Lo que **no** arregla:

- **`KleinBitmap.dll`** (1,2 MB), en Ópalo, Iberia, Titán, Z y Uranium. Es una
  biblioteca nativa que hace operaciones de bitmap desde Ruby
  (`klein_dll("save_pallete", ...)` sobre `self.__id__`, o sea pasándole el
  puntero del `Bitmap` de RGSS). Iberia y Titán además traen un
  `Map - Klein.rb`. Con el shim mudo esas llamadas devuelven 0 y hay que ver
  qué pasa con el mapa; sin medirlo en pantalla no se puede decir más.
- **`gif.dll`** (6 usos en los cinco), para convertir GIF a PNG en memoria.
  Va protegido con `if safeExists?("gif.dll")`, así que si el fichero no viaja
  a la tarjeta el juego ni lo intenta. Es el único de la lista que se desactiva
  solo.
- Los 12 usos de `Sockets` en un fichero (`0030_Sockets.rb`), que en estos
  juegos van montados sobre `Win32API` de `ws2_32`, no sobre la extensión de
  Ruby.

### ¿Transformar el fuente o portar Ruby 1.8.7?

Con las cifras delante: **transformar el fuente**, sin duda razonable. La
sintaxis son 25–28 líneas por juego y está probado que después compila todo. Lo
caro no es el lenguaje, es la plataforma —`Win32API` en 20–29 ficheros—, y eso
lo pagarías igual con Ruby 1.8.7 portado, porque en Horizon tampoco hay DLL.

La honestidad exige decir qué **no** mide este censo: compilar no es correr.
Los métodos que 1.8 tenía y 3.1 no, y las semánticas que cambiaron —
`String#[]` con un entero devolvía un `Integer` y ahora devuelve un `String`,
`[1,2].to_s` daba `"12"` y ahora `"[1, 2]"`, `Hash#index` se llama ahora
`Hash#key`— **no se ven con un compilador**, y los greps que las buscarían
(`.to_s`, `.index(`, `.type`) están saturados de falsos positivos, como
demuestra que Añil, que corre, tenga más que ninguno. La única forma de saber
cuántos hay es arrancar el juego con el shim de `Win32API` puesto e ir leyendo
`mkxp-ruby.log`. Ese es el siguiente experimento, no una cifra que se pueda
sacar de aquí.

Un dato a favor de que sean pocos: los cuatro juegos son Essentials v16, y
Essentials v16 se distribuía ya con `RGSS2Compatibility.rb` y con la intención
de correr sobre RGSS1 y RGSS2; el código que se escribió para 1.8.7 en 2016 es
mucho más conservador que el de 2007.

### Ficha por juego

**Pokémon Ópalo 2.11** — 214 scripts / 136.170 líneas. Data 517/36 MB,
Graphics 13.553/121 MB, Audio 2.480/476 MB (1.837 wav, 387 ogg, 255 mp3 y **un
`.exe` dentro de `Audio/`**), Fonts 8, PBS 33/1,6 MB. PNG mayor
`Exterior5.png` 256 × 42.036; 14 por encima de 4096. Su `mkxp.json` son 9,3 KB
de comentarios y **un objeto vacío**: no aporta ni una clave. Trae
`fluidsynth.dll` pero **ningún `.mid`** en 2.480 ficheros de audio. En la raíz,
dos PDF de guía y `LastSave.dat`.

**Pokémon Z 2.13** — 235 scripts / 160.766 líneas; el corpus más grande de la
familia. Data 562/57 MB, Graphics 15.789/275 MB, Audio 2.668/530 MB (1.353 ogg,
1.147 wav, 167 mp3), Fonts 8, PBS 28/1,7 MB. **3.281 PNG de más de 4096**, en
el orden de Añil. Dos particularidades:

- Su `preload.rb` redefine `Zlib::Inflate.inflate` y `Zlib::Deflate.deflate`
  para llamar a `MKXP.zinflate`/`MKXP.zdeflate` — **la API de JoiPlay**, que en
  mkxp-z no existe. Este `preload.rb` viaja a la tarjeta por §2 y se ejecuta al
  final del `preloadScript`, así que rompería el `Zlib` bueno. El perfil tiene
  que neutralizarlo, igual que Añil neutraliza el `MKXP.puts` del suyo con
  `nx-compat.rb`.
- Tiene un `Scripts.rxdata` de 576 bytes **en la raíz**, además del de
  `Data/`. Se extrajo: es el cargador de Essentials v20+
  (`load_scripts_from_folder("Data/Scripts")`), y `Data/Scripts/` no existe en
  este juego. Es un resto de haber copiado ficheros de otro proyecto; no lo
  lee nadie, porque `Game.ini` dice `Scripts=Data\Scripts.rxdata`.

Su `mkxp.json` sí trae claves: `vsync: false`, `syncToRefreshrate: false`,
`subImageFix: false`, `enableBlitting: true`, `windowTitle`. Las dos primeras
las pisa la capa 1 del empaquetador; las otras dos están en la lista blanca de
§5. En la raíz, cuatro PDF/TXT de ayuda para JoiPlay, un `.nomedia` (Android),
`configuration.json` con `{"cheats": false}` y `showdown.txt`.

**Pokémon Iberia 2.10** y **Pokémon Titán 2.10** — prácticamente el mismo
juego para este censo: 168 y 167 scripts, 119.682 y 118.848 líneas, los mismos
cuatro ficheros rotos en las mismas líneas, la misma carpeta `Animations/`
(1.296 fich./45,8 MB, fuera de las cinco de recursos, y `animmaker.exe` en la
raíz para editarla), las mismas nueve fuentes. Iberia: Graphics 11.150/73 MB,
Audio 1.135/338 MB (745 wav, 347 mp3, 39 ogg, **4 mid**). Titán: Graphics
11.466/60 MB, Audio 1.152/286 MB (739 wav, 371 mp3, 39 ogg, **3 mid**).
Ninguno trae `mkxp.json` ni `preload.rb`, y ninguno trae `soundfont.sf2`: los
MIDI sonarán a nada mientras no se le dé uno a `midiSoundFont`.

## Pokémon Uranium 1.3.2 — `pokemon-uranium` (`rgss1`)

El único que no es mkxp-z. `Uranium.exe` son 110.592 bytes
(`5cef0ea225e816781397784f5ea3f601`) y dentro está
`<description>RGSS Player</description>`, `Enterbrain.RGSS.Game` y los
`RGSSInitialize`/`RGSSGameMain`/`RGSSEval` que exporta `RGSS102E.dll`: es el
reproductor original de RPG Maker XP.

**Los datos están cifrados** en `Uranium.rgssad` (33,9 MB). Para mirar dentro
se escribió `dump-rgssad.py`, reproduciendo en Python el formato que implementa
`src/mkxp-z/src/crypto/rgssad.cpp`: clave inicial `0xDEADCAFE`, que avanza
`key = key*7+3` una vez por cada u32 leído y una vez por cada **byte** del
nombre. El archivo tiene **254 entradas, 33.852.950 bytes, y todas son
`Data/`**: Graphics y Audio van sueltos. Dentro hay lo esperado más
`intl_1337.dat`, `intl_chinese.dat`, `intl_dutch.dat`... (2 MB cada uno: el
juego está traducido a media docena de idiomas).

`Data/Scripts.rxdata` son 952.947 bytes descifrados → **260 secciones,
144.580 líneas**. Essentials clásico con menciones a v16 y v17 en los
comentarios; `CURRENTVERSION = "1.3.2"` es la versión del juego.

- **Sintaxis**: 2 ficheros de 260 fallan, y los dos por lo mismo (regex con
  `\xNN` sin `/n`). **Dos líneas.** Es el juego con el fuente más limpio del
  grupo no-ruby31, lo cual tiene su gracia siendo el único que corre sobre RGSS
  de verdad.
- **Plataforma**: 166 `Win32API` en 29 ficheros, 13 de nivel superior. Y lo que
  lo separa de los otros cuatro: **el audio entero pasa por FmodEx**.
  `0249_RGSS Linker.rb` carga `RGSS Linker.dll` con
  `Win32API.new("RGSS Linker.dll","RGSSLinker_Initialize","p","i")` y
  `raise LoadError` si falla; `0250_F-mod main script.rb` hace
  `Kernel.load_module("RGSS FmodEx.dll","Init_FmodEx")`. 31 referencias a fmod
  en ese fichero. No es un adorno opcional: es la clase `Audio` del juego.
  También hay 8 `require 'benchmark'`.
- **Recursos** (fuera del archivo): Graphics 5.527/58 MB, Audio 713/227 MB
  (378 ogg, 272 wav, 55 mp3, **4 mid** y un `.sfk`, un `.reapeaks` y un `.ini`
  que se colaron del editor), Fonts 12 y **24,1 MB** —lleva
  `NotoSansCJKsc-Medium.otf` y dos VL-Gothic para el japonés y el chino—.
  **224 PNG pasan de 4096**, entre ellos `Graphics/Battlers/034b.png` de
  12.480 × 160: tiras horizontales, no verticales como los tilesets.
- **Raíz**: `Patcher.exe`, `patchergrf.grf`, `neoncube/` y `neoncube.file`
  (el actualizador NeonCube), `Server.txt` con `http://pokemonuranium.org`,
  `NoDeactivate.dll`, dos README. Nada de eso sirve en una consola.
- **Veredicto**: necesita perfil `rgss1` y es el más lejano. El
  `Game.rgssad` de §1 no hace falta —ya trae un contenedor RGSSAD de verdad,
  y el motor lo lee—, pero hay que reescribir la capa de audio contra la clase
  `Audio` de mkxp-z, no solo callar `Win32API`.

## Lo que esto decide

**1. Vanguard primero.** Es el único que sale a cero en todo lo que se ha
medido: 432 scripts compilan, ni un `Win32API`, ni un `require`, mkxp-z con
Ruby 3.1 igual que el motor, y lo que necesita —`Data/Scripts/` y `Plugins/`
sueltas, `dist/` y `PBS/` excluidas— ya está escrito en §2 de
`CONVENCIONES.md`. Si el perfil genérico no lo arranca, el fallo es del
empaquetador o del motor, no del juego, y eso lo convierte en la mejor prueba
que hay de que la generalización funciona. Sus 1,5 GB de recursos son también
el caso grande que conviene medir pronto.

**2. Reborn después, porque paga por adelantado el trabajo de los demás.**
No compila mal: le falta `stdlib`/`gems` en `rubyLoadpath`, un `socket.rb`
postizo (que Añil ya tiene, en `runtime/lib/socket.rb`) y decidir qué hacer con
`discord.so`. Resolverlo deja hecha la parte de "juego que trae su propia
biblioteca estándar suelta", que es la forma en que se distribuyen los
Essentials modernos. Su `patches` sin equivalente en mkxp-z 2.4.2 hay que
apuntarlo como deuda: hoy la carpeta viene vacía y no molesta.

**3. La familia ruby18, los cuatro de una vez, y no por la sintaxis.** Comparten
`Game.exe` byte a byte y comparten los ficheros rotos: los mismos 23 `when X:`
en el mismo `AudioUtilities.rb`, el mismo `retry` en la misma línea. Una
transformación de fuente de cuatro reglas —probada aquí— arregla 25–28 líneas
por juego y deja los ~200 scripts de cada uno compilando. El trabajo real es un
`Win32API` postizo, porque son 12–14 asignaciones de nivel superior las que
impiden llegar a la pantalla de título, y luego averiguar por registro qué
métodos de 1.8 faltan, que es algo que **no se puede contar sin encender la
consola**. Empezar por Ópalo o Z: son los de nombres de sección más modernos y
los únicos con `mkxp.json`, y Z además obliga a resolver lo del `preload.rb`
con `MKXP.zinflate`, que es el mismo patrón que Añil ya resolvió.

**Uranium queda el último.** No porque tenga los scripts peor —tiene los
mejores del grupo: dos líneas— sino porque su clase `Audio` es una DLL nativa
y eso hay que reescribirlo, no taparlo. Todo lo demás (el archivo cifrado, los
254 ficheros de `Data/`) ya se sabe leer: `dump-rgssad.py` está en el
repositorio.

Y una cosa que este censo **no** dice: ninguno de los siete se ha arrancado.
Todo lo de arriba es lo que se ve sin ejecutar una línea. El primero que se
encienda cambiará estas prioridades, y para eso está escrito.
