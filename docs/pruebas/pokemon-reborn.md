# Pokémon Reborn 19.5.0 en el emulador — 9 de septiembre de 2026

Primera vez que este juego se enciende. Medido sobre Ryujinx
(`C:\Games\publish\Ryujinx.exe`), tarjeta virtual en `%APPDATA%\Ryujinx\sdcard`,
motor de HEAD.

## Que se empaqueto y como

```
./construir.sh
powershell -NoProfile -ExecutionPolicy Bypass -File Empaquetar.ps1 -SinInterfaz `
  -Juego "C:\Users\Usuario\Downloads\RPG MAKERS POKEMONS FANS\Reborn-19.5.0-windows" `
  -Salida "C:\Users\Usuario\AppData\Roaming\Ryujinx\sdcard" -Contenedor zip `
  -Entrega "C:\rgss-switch\release\rgss-switch-0.1.0"
```

11.262 ficheros y 675 MB en `datos.zip`; `Scripts/`, `stdlib/`, `gems/` y
`patch/` sueltas; 5 ficheros de la raiz (`cacert.pem`, `Game.ini`,
`Modding.txt`, `Readme.txt`, `rebornmap.png`); 717 MB en 1.474 ficheros. El
empaquetador copio los tres shims del perfil y compuso el `mkxp.json` con
`patches: ["patch"]`, `inputRepeatStart: 0.3` e `inputRepeatDelay: 0.05`.

## Vuelta 0 — el `.nro` del empaquetador no arranca en Ryujinx

**Sintoma.** Con el `pokemon-reborn.nro` que sale de `Empaquetar.ps1`, el
emulador se queda en

```
Application LoadGuestApplication: Loading content archive from '...pokemon-reborn.nro'.
Application LoadGuestApplication: Loading as homebrew.
```

y no escribe una sola linea mas. Ni `mkxp-boot.log`, ni `mkxp-debug.log`, ni
nada en `sdmc:/`. En una de las dos veces que se probo, dos minutos despues,
salto ademas

```
Unhandled exception caught: The HLE Process map did not have a process with ID 0.
  at ProcessLoader.get_ActiveApplication()
  at DiscordIntegrationModule.Use(...)
  at ProcessLoader.LoadNxo(...)
```

o sea que `LoadNxo` no llego a registrar ningun proceso: el `.nro` no se carga.

**Lo raro es que el fichero esta bien.** `comprobar-nro.py` lo lee entero: ASET
v0, icono de 12.993 bytes, NACP de 16.384, romfs de 632 bytes con
`/juego.txt -> 'sdmc:/switch/pokemon-reborn\n'`, los cuatro title id correctos y
la version `0.1.0`. Lo unico que se sabe es que **el mismo `.elf`, pasado por
`elf2nro` con un romfs equivalente, arranca a la primera**:

```
[   201] [nro] (sin ruta: lanzado sin argumentos)
[   278] [juego] carpeta: sdmc:/switch/pokemon-reborn
```

**NO SE ARREGLA AQUI** (`Empaquetar.ps1` es de otro agente). Queda anotado con
todo lo que se sabe: el ASET rehecho a mano por el empaquetador produce un
`.nro` que Ryujinx no carga, y el de `elf2nro` si. Todas las pruebas de abajo
se hicieron con el `.nro` de `elf2nro`, igual que las de Vanguard.

## Arranque: los tiempos

| ms | linea |
|---|---|
| 278 | `[juego] carpeta: sdmc:/switch/pokemon-reborn` |
| 3.182 | `[boot] 8 initGL OK, hilo RGSS vivo` |
| 4.351 | `[boot] 10a- parche montado: patch` |
| 4.410 | `[boot] 10a+ contenedor datos.zip montado` |
| 4.629 | `[boot] 10c pathCache construido` (12.999 entradas, 255 directorios, ~220 ms) |
| 4.739 | `[boot] 11 SharedState OK, arrancando el interprete Ruby` |

**El motor esta listo en 4,7 s.** Los 193 scripts y sus 317.428 lineas tardan
unos 85 s mas: el primer mapa, `51 Intro`, aparece a los **90,8 s**.

Nota buena: `[boot] 10a- parche montado: patch`. La clave `patches` del
`mkxp.json` de Reborn —que el censo daba por no soportada— **si la entiende este
motor**. La carpeta viene vacia, asi que hoy no cambia nada, pero los mods del
jugador tienen por donde entrar.

## Las vueltas, en orden

Cada una es un `LoadError` o un `NameError` que mata el arranque entero, porque
el cargador de Reborn (`Scripts/ScriptLoader.rb:86`) rescata `StandardError` y
tanto `LoadError` como `ScriptError` se le escapan.

### 1. `Dir is not a module`

```
Error cargando lib/nx-compat.rb -> Dir is not a module
:: previous definition of Dir was here ( TypeError )
```

Un fallo mio del arreglo de `Dir.pwd` de Vanguard: `Dir` es una **clase**, y
reabrirla con `module` levanta un `TypeError` que se lleva por delante el resto
de `nx-compat.rb` —`$LOAD_PATH`, `Marshal.neverload`, el reportero de mapa— sin
mas rastro que un `mkxp-ruby.log` cortado a la mitad. Arreglado en
`runtime/lib/nx-compat.rb` (`class Dir`).

### 2. `require 'discord'` y `require 'poke-api-v2'`

Previstos por el censo. `gems/discord.so` es una extension nativa de Windows y
en Horizon no se puede cargar. Postizos en `juegos/pokemon-reborn/lib/`:
`discord.rb` (los cinco metodos que los scripts usan: `connect`, `connected?`,
`disconnect`, `update`, `update_activity`, todos vacios) y `poke-api-v2.rb`
(`PokeApi.get` eleva `NotImplementedError`; el validador es una herramienta de
escritorio que consulta pokeapi.co).

### 3. `System.file_exist?` no existe en mkxp-z 2.4.2

`ScriptLoader.rb:27` define `fileExists?` sobre `System.file_exist?`, que es del
mkxp-z de Splendide Imaginarius. Y `fileExists?` es lo que usa `RTP.rb` para
resolver **cada** imagen y cada sonido y `Cache.rb` para decidir si recompila
`Data/mons.dat` y otros diez. Postizo en `nx-reborn.rb`:
`System.file_exist?` → `FileTest.exist?`, que en este motor ya contesta tambien
por el contenedor.

### 4. `rubygems`: `rbconfig` y `monitor.so`

```
stdlib/rubygems.rb:8:in `require': cannot load such file -- rbconfig (LoadError)
stdlib/monitor.rb:90:in `require': cannot load such file -- monitor.so (LoadError)
```

`gem 'rubygems'` sale en `Updater.rb:38` y en `RebornScripts.rb:2352`. Reborn
solo trae `stdlib/x64-mingw32/rbconfig.rb` y su `ScriptLoader` mete esa carpeta
en la ruta **solo si `System.platform` dice Windows**; aqui dice `Linux`, porque
mkxp-z 2.4.2 contesta eso en todo lo que no sea macOS ni Windows. Y `monitor` es
una extension nativa: este interprete se compilo con
`--with-static-linked-ext` y solo lleva tres dentro (`patches/extinit.c`).

Se probo primero a meter `stdlib/x64-mingw32` en `rubyLoadpath` —funciona para
`rbconfig` y descubre el segundo fallo— y al final se hizo lo que de verdad
corresponde: **un `rubygems.rb` postizo** en `juegos/pokemon-reborn/lib/` con
solo `Gem::Version`, que es lo unico que el juego usa de RubyGems (comparar la
version del servidor y la de la partida guardada). `lib/` va antes que `stdlib/`
en `rubyLoadpath`, asi que gana el postizo y no se arranca un gestor de paquetes
entero en una consola donde no hay gemas que instalar. `rubyLoadpath` se dejo
como estaba.

### 5. `Input::E`

```
System:88:in `update': uninitialized constant Input::E (NameError)
  EventScene:705 -> Scene_Intro:19 -> Main:38
```

El `mkxp.json` de Reborn declara **once** botones (`d`, `e`, `f` ademas de los
ocho) porque su motor los tiene. mkxp-z 2.4.2 conoce ocho. Los tres sitios que
los usan son el turbo, el silencio y correr con el gatillo: accesorios.

Se definen en `nx-reborn.rb` como 50, 51 y 52, **fuera** del mapa de botones:
`getStateCheck` (`input.cpp:796`) recorta cualquier codigo fuera de rango al
estado 0, que nunca esta pulsado, asi que contestan `false` siempre y no pueden
salirse de ningun array. Reutilizar un boton real dispararia el turbo solo.

### 6. `TilemapUtils.updateAutoTiles`

```
Scene_Map:45:in `updateSpritesets': uninitialized constant Scene_Map::TilemapUtils
```

Otra del fork, y se llama en cada fotograma del mapa: sin ella no se ve un solo
mapa. En mkxp-z 2.4.2 la animacion de los autotiles la lleva el propio `Tilemap`
por dentro, asi que el postizo es un metodo vacio. (Si algun dia se ve el agua
quieta en este juego, mirar aqui.)

### 7. `Audio.se_play_position`

```
Audio:522:in `internal_se_play': undefined method `se_play_position' for Audio:Module
  Game_System:255 -> pbSEPlay -> pbMessageDisplay
```

**Todo** efecto de sonido del juego pasa por ahi (`Scripts/Audio.rb:521`), asi
que el primer pitido de un cuadro de texto se llevaba la partida. Los tres
ultimos argumentos son la posicion de lo que suena, para repartirlo entre los
altavoces; mkxp-z 2.4.2 solo tiene el `se_play` de RGSS. El postizo tira la
posicion y reproduce el sonido.

### 8. El teclado, y aqui el shim generico no vale

Reborn es Essentials v19 y **no tiene dos clases de entrada de texto**: tiene
una sola, `Scripts/TextEntry.rb:813`, que decide dentro con
`$Settings.useKeyboard?`. El shim generico `runtime/lib/nx-teclado.rb` pregunta
por `PokemonEntryScene2`, que aqui no existe, y se calla.

`useKeyboard?` es `$Settings.keyboard == 0` y `Options.rb:286` pone ese ajuste a
0 de fabrica ("0 is on"), o sea que Reborn arranca pidiendo teclado. Se cambia
el **metodo** y no el numero, porque `$Settings` sale de una partida guardada
(`ClientData.rb:40` lo lee con `Marshal.load`) y tocar el numero solo valdria
para las partidas nuevas. Instalado tarde, enganchado a `Graphics.update`, que
es el patron de `nx-teclado.rb`.

## Como se conduce este juego, para el que venga detras

- **Aceptar** es `Input::USE` = tecla Z. **El menu de pausa es la tecla X**
  (`Input::B`, y su `bindingNames` lo dice: `"b": "Back / Menu"`), al reves que
  Vanguard, que lo abre con `Input::ACTION`.
- La rejilla del nombre es la de Essentials v19: el cursor empieza en la `A`,
  **ABAJO x4 lleva a la ultima fila y DERECHA x2 al `OK`**, y Z confirma.
- **Cuidado con el menu de informacion de la introduccion.** Despues del nombre
  el juego pregunta "Do you wish to view any information about the game?" con
  cuatro opciones —Keyboard Controls, Gamepad Controls, Discord Activity,
  Continue— y la primera esta seleccionada. Pulsar Z sin mas ensena la pagina de
  controles y **vuelve al mismo menu**: es un bucle infinito, y por el se
  perdieron dos sesiones enteras creyendo que el juego se habia colgado. Hay que
  bajar tres veces hasta `Continue`.
- Los mapas por los que pasa la introduccion, con los milisegundos del registro:

  ```
  [ 90.6 s] [donde] mapa  51 Intro en (10,10)
  [344.6 s] [donde] mapa 689 Tourmaline Desert en (15,24)
  [354.8 s] [donde] mapa 667 Intro Train en (11,5)
  [515.4 s] [donde] mapa  37 Lower Peridot Ward en (23,68)
  ```

  `37 Lower Peridot Ward` es donde el jugador toma el control: **8,6 minutos**
  de introduccion pasada a botonazos.
- En el menu de pausa, con la partida recien empezada, las entradas son `Bag`,
  el nombre del jugador, `Save`, `Options`, `Controls` y `Quit Game`: **`Save`
  esta a dos ABAJO**.

## Hitos

| # | Hito | Captura |
|---|---|---|
| 1 | Pantalla de titulo | `pokemon-reborn-hito-1-titulo.png` |
| 2 | Partida nueva | la introduccion arranca sola desde el titulo |
| 3 | Nombre del jugador en la rejilla | `pokemon-reborn-hito-3-rejilla.png` |
| 4 | Primer mapa con el jugador (37 Lower Peridot Ward) | `pokemon-reborn-hito-4-mapa.png` |
| 5 | Menu de pausa | `pokemon-reborn-hito-5-menu.png` |
| 6 | Guardar | `pokemon-reborn-hito-6-guardar.png`, y en la carpeta del juego queda `Game.rxdata` (377 KB) junto a `Game.dat` y `Settings.dat`, que el juego ya escribia solo |
| 7 | Combate | no se llego en el tiempo de la prueba |

## Lo que queda

- El `.nro` del empaquetador (vuelta 0), que no es de este agente.
- La superposicion de `patch/`: el motor la monta, pero `System.file_exist?` es
  postizo y contesta por `FileTest.exist?`, que **no** mira la superposicion. Con
  `patch/` vacia da igual; con mods del jugador dentro, no.
- Sonido sin panoramica (vuelta 7).
- Turbo, silencio y correr con gatillo, apagados (vuelta 5).
