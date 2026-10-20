# Pokémon Iberia 2.10 en el emulador — 9 de septiembre de 2026

Primera vez que este juego se enciende. Ryujinx, tarjeta virtual en
`%APPDATA%\Ryujinx\sdcard`, motor de HEAD. Lo común está en
[`familia-ruby18.md`](familia-ruby18.md).

**Estado: `arranca`.** Y arrancó **a la primera**, sin una sola vuelta de
arreglo: los nueve que salieron de Ópalo y de Z ya estaban puestos y valen tal
cual. Título, menú de carga, partida nueva, la introducción y la rejilla del
nombre, con `errorlog.txt` sin crearse y `mkxp-debug.log` sin una excepción.

## Qué se empaquetó y cómo

```
powershell -NoProfile -ExecutionPolicy Bypass -File Empaquetar.ps1 -SinInterfaz `
  -Juego "C:\Users\Usuario\Downloads\RPG MAKERS POKEMONS FANS\Pokemon Iberia V2.10" `
  -Salida "C:\Users\Usuario\AppData\Roaming\Ryujinx\sdcard" -Contenedor zip `
  -Entrega "C:\rgss-switch\release\rgss-switch-0.1.0"
```

`Animations/` sale suelta —1.296 ficheros que no son de las cinco carpetas de
recursos—, `PBS` excluida, `animmaker.exe` descartado por ser `.exe`: 489 MB en
1.409 ficheros. El perfil ya lo decía y no hubo que tocarlo. La advertencia
sobre el `Editor.ini` engañoso tampoco hizo falta: el detector cogió `Game.ini`.

Este juego no trae `mkxp.json` ni `preload.rb`, así que la capa 2 del compuesto
está vacía y el `preloadScript` son los cuatro shims de la familia y nada más.

## Vueltas: ninguna

No hay síntoma que contar. En el registro salen, en este orden, los nueve
arreglos de la familia disparándose:

```
[1.8] ENV["TEMP"] = "/switch/pokemon-iberia" (Horizon no trae entorno)
[1.8] String#each = String#each_line
[1.8] Graphics.snap_to_bitmap vuelve a ser el del motor
[1.8] StringInput: each_byte entrega bytes y getbyte existe
[1.8] pbRgssOpen memoriza los Data/*.dat
[1.8] LargePlane construye el Plane nativo que su initialize se saltaba
[1.8] getOggPage y oggfiletime leen bytes con getbyte
[1.8] Input vuelve a ser el del motor
[1.8] String#getbyte/setbyte/bytesize repuestos
[teclado] USEKEYBOARDTEXTENTRY = false: el nombre se escribe en la rejilla
[teclado] PokemonEntryScene -> la rejilla con cursor
```

Los dos de `[teclado]` valen la pena por separado: el genérico
(`nx-teclado.rb`, que cambia la clase) y el de la familia (`nx-ruby18.rb`, que
pone la constante `USEKEYBOARDTEXTENTRY` a `false`) hacen lo mismo por dos
caminos distintos, y aquí se ve que los dos hacían falta escribirse porque este
juego usa la constante y no el ajuste.

## Los tiempos

| ms | línea |
|---|---|
| 355 | `[juego] carpeta: sdmc:/switch/pokemon-iberia` |
| 3.317 | `[boot] 8 initGL OK, hilo RGSS vivo` |
| 4.520 | `[boot] 10a+ contenedor datos.zip montado` |
| 4.852 | `[boot] 10c pathCache construido` |
| 4.951 | `[boot] 11 SharedState OK, arrancando el intérprete Ruby` |
| 5.839 | `[boot] scripts pasan por NXFuente.transforma` |
| 9.521 | primer `[monton]`: el juego ya está dibujando |

`[fuente] TOTAL: 168 secciones, 4 tocadas, 28 arreglos, 1925.9 ms` — las 28
líneas exactas que el censo había contado a mano, incluidos los tres `break` en
cuerpo de método que Ópalo y Z no tienen.

`[224166] [donde] mapa 1 Intro en (9,7)`.

Un `[tiron]` de 2.085 ms al entrar en el mapa, con `io 1221662x 64 ms`: 1,2
millones de operaciones de fichero contadas en un solo fotograma. Es la primera
vez que se ven los recursos de este juego y `pathCache` está frío; conviene
mirarlo si alguien lo lleva más lejos.

## Win32API: 38 pedidas, ninguna sin semántica

Y una que **sí se llama** y que los otros dos no piden:

```
[win32api] kleinbitmap!version llamado (solo se avisa la 1a vez)
```

O sea que Iberia pregunta de verdad por `KleinBitmap.dll`, que no viaja a la
tarjeta. Los efectos de bitmap (paleta, desplazamiento, `to_retro`, contorno)
salen sin aplicar. También se llama `advapi32!RegOpenKeyExA` —el registro de
Windows, buscando la ruta del RTP—, que contesta `ERROR_FILE_NOT_FOUND`, que es
la verdad.

## Hitos

| # | Hito | Captura |
|---|---|---|
| 1 | Pantalla de título | `pokemon-iberia-hito-1-titulo.png` |
| 2 | Partida nueva | `pokemon-iberia-hito-2-partida-nueva.png` |
| 3 | Nombre del jugador en la rejilla | `pokemon-iberia-hito-3-rejilla.png` |
| 4 | Primer mapa con el jugador andando | `[314254] [donde] mapa 17 Casa en (7,8)` en el registro. **Sin captura**: las que se tomaron salieron con el escritorio de la máquina dentro y hubo que borrarlas (ver el commit del arnés) |
| 5 | Menú | se pulsó, sin captura utilizable |
| 6 | Guardar | no se llegó |
| 7 | Combate | no se llegó |

## Hasta dónde llegó de verdad

Con `-Espera 40` —que es lo que hay que usar en esta familia, no 170— y la
introducción pasada a botonazos con el patrón Z-C-Z, el jugador **toma el
control dentro de una casa**:

```
[ 89976] [donde] mapa  1 Intro en (9,7)
[314254] [donde] mapa 17 Casa en (7,8)
```

Se dieron cuatro pasos y se abrió el menú de pausa con la tecla X
(`Input::B`), sin una sola excepción en `mkxp-debug.log` y sin `errorlog.txt`.
Las capturas de ese tramo **no se conservan**: salieron con el escritorio de la
máquina dentro —el emulador se había puesto a pantalla completa y la reserva de
«copiar la pantalla» hizo lo que no debía— y se borraron. El arnés ya no lo
puede volver a hacer.

## Lo que queda

- Repetir ese tramo con el arnés arreglado y guardar partida, que es lo único
  que falta para `jugable`. No hay ningún error que lo impida: es tiempo de
  sesión.
- Los cuatro `.mid` de este juego no suenan: no trae soundfont y
  `midiSoundFont` no apunta a ninguno (`Failed to load libfluidsynth.so` en
  `mkxp-debug.log`).
- El agua y las cascadas: son lo que `KleinBitmap.dll` animaba desplazando el
  bitmap. Hay que mirarlas cuando alguien llegue a un mapa con agua.

---

## Segunda vuelta — 9 de septiembre de 2026, tarde: **jugable**

**Estado: `jugable`.** Cuatro pasos dentro de `17 Casa`, menú de pausa y
**partida guardada**: `Game.rxdata`, 65.609 bytes, en la carpeta del juego de la
tarjeta. Ni una excepción, ni `errorlog.txt`. Dos vueltas de emulador, y la
primera falló sólo por quedarse corta de pulsaciones.

### La introducción se contó antes de encender

`leer-mapa.rb` lee un `MapNNN.rxdata` con el Ruby 3.1 del PC —`Marshal` con
las nueve clases de `RPG::` puestas a mano, porque `Marshal` no pasa por
`const_missing`— y escupe los comandos de evento. Con eso, la introducción de
este juego deja de ser una adivinanza: `Map001`, evento 2 «Intro», 211 comandos.

- tres cajas del **Profesor Félix**, una caja más y una elección
  (`Cuéntame más` / `No me des más el tostón`);
- `¿eres chico o chica?` (tres opciones);
- la rejilla del nombre y el `¿Así que te llamas X?`;
- tres cajas, el **modo de juego** (Normal / Nuzlocke / Seminuzlocke / Infórmame),
  el **randomizador** y las seis cajas del parte del tiempo;
- y `201 0, 17, 7, 8` — la transferencia a `17 Casa` en (7,8).

**En todas las elecciones el índice 0 es lo que interesa** (Chico, Sí, Modo
Normal, no randomizar), así que la cruza sola un chorro de `Z` con una `C`
intercalada: la `C` no hace nada sobre una caja de texto y es la que salta a
`FIN` en la rejilla, con lo que da igual en qué bloque caiga la rejilla. Dieciséis
bloques de `Z Z Z Z C Z` bastan; con doce se llegaba justo al parte del tiempo y
no al mapa (vuelta 1).

### El menú y el guardado

El menú de pausa de este juego, con el jugador recién salido de la introducción,
es exactamente el que dice `PokemonPauseMenu.rb` cuando no hay Pokédex ni equipo:

```
Mochila / <nombre del jugador> / Guardar / Opciones / Controles / Salir
```

O sea **X, dos ABAJO y Z**; luego `¿Quieres guardar la partida?` con `Sí` arriba
(otra Z) y el aviso de guardado (otra Z). El cuadro de la izquierda dice
`Casa · Jugador A · Tiempo 00:02 · Medallas 0 · Archivo 1`.

| ms | dónde |
|---|---|
| 52.119 | `[donde] mapa 1 Intro en (9,7)` |
| 124.554 | `[donde] mapa 17 Casa en (7,8)` |
| ~150.000 | `Game.rxdata` escrito |

### Las capturas volvieron a salir con el escritorio dentro, y por qué

La vuelta 1 guardó nueve capturas con medio escritorio de Randy dentro **con el
recorte al área de cliente puesto y funcionando**. La causa no era el recorte:
`jugar.ps1` llamaba a `SetProcessDPIAware()`, que sólo entera al proceso del DPI
**del sistema**, y esta máquina tiene dos monitores con escalas distintas
(`GetDpiForWindow` sobre la ventana del emulador devuelve 120). Con eso Windows
virtualiza las coordenadas y `GetClientRect`/`ClientToScreen` contestan en un
sistema mientras `CopyFromScreen` copia en otro. Se cambió a
`SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` y se añadió una
comprobación que **omite la foto** si el área calculada no cabe dentro del marco
de la ventana. Las nueve se borraron.

### Hitos

| # | Hito | Captura |
|---|---|---|
| 4 | Primer mapa con el jugador andando | `pokemon-iberia-hito-4-mapa.png`, `-5-andando.png` |
| 5 | Menú de pausa | `pokemon-iberia-hito-6-menu.png`, `-7-menu-guardar.png` |
| 6 | **Guardar** | `pokemon-iberia-hito-8-confirmar.png`, `-9-guardado.png` |
| 7 | Combate | no se llegó |

### Lo que queda

- El primer combate. Hay que salir de la casa y buscar hierba.
- El agua y las cascadas de `KleinBitmap.dll`, y los cuatro `.mid` sin soundfont:
  igual que estaban.

---

## Tercera vuelta — 20 de octubre de 2026: salir de la casa

Un jugador lo probó en su consola con la entrega 0.2.0 y mandó dos cosas: «es
salir de la casa y se crashea» y «no aparece la imagen en el menú principal».
Con su partida (`Game.rxdata`, 65.668 bytes: Pablo, mapa 17, sin equipo) las dos
se reprodujeron en Ryujinx. Eran tres fallos, no dos.

### 1. El cierre al salir: un tileset que no cabe en una textura

```
Section036:371:in `bitmap=': Operation not supported for mega surfaces (MKXPError)
  from Section036:371:in `getRegularTile'
  ... Spriteset_Map#initialize <- Scene_Map#transfer_player
```

Los tilesets de exteriores de Iberia miden **256x40026** (los once de
`Graphics/Tilesets/` salvo `Interior.png`, de 256x15123, y dos pequeños). La GPU
de la Switch no pasa de 16384 de lado y mkxp-z guarda un Bitmap así en RAM como
*mega surface*. El Tilemap del motor sabe dibujarlo; un Sprite no. Y este juego
no usa el Tilemap del motor: `MAPVIEWMODE = 1` (sección 0) hace que
`TilemapLoader` elija `CustomTilemap`, el de Ruby, que pinta cada tile con
`sprite.bitmap = @tileset`. La casa funcionaba porque su tileset cabe.

Arreglo en `nx-ruby18.rb` (`NX18Tarde.tilemap`): con un tileset mega, el sprite
recibe un Bitmap del tamaño de un tile recortado del tileset.

### 2. Rectángulos negros en el pueblo: blt desde mega pisa

Ya sin el cierre, Albacete salía con rectángulos negros alrededor de la casa.
`CustomTilemap` compone en un solo Bitmap los tiles de prioridad 0 de las tres
capas, el suelo primero y la casa encima, y las dos ramas de `stretchBlt` para un
origen mega COPIAN en vez de mezclar (lo dice mkxp-z: «Don't do transparent blits
for now»). Lo transparente de la casa borraba el suelo.

Arreglo en el mismo shim (`NX18Tarde.blt_mega`): `blt` y `stretch_blt` desde un
Bitmap mega recortan antes el trozo a un Bitmap normal, guardado en el propio
tileset, y copian desde ahí por el camino que mezcla.

### 3. La pantalla de carga sin fondo: glBlitFramebuffer desde una imagen sin leer

La «imagen del menú principal» es `loadbg.png`, la Poké Ball de fondo de la
pantalla de Continuar. Salía negro. `pbResolveBitmap` la encontraba, el plano se
creaba y era visible, pero el Bitmap donde `LargePlane` la copia con `blt`
estaba vacío. Una matriz de `blt` leída por el sombreador (`raw_data` y
`get_pixel` no son de fiar en Ryujinx con anchos múltiplos de 16) dio la regla:
el `blt` rápido (`glBlitFramebuffer`) desde una imagen recién cargada de fichero
que la GPU no ha leído nunca, hacia un destino de su tamaño y copiándola casi
entera, no escribe nada. Detalle en `patches/mkxpz-blt-recien-cargada.patch`.

Arreglo en el motor (b57): esas imágenes van por el sombreador hasta que la GPU
las ha leído una vez.

### Cómo se condujo: sin quitarle el foco a nadie

La primera vuelta fue con `jugar.ps1` y sus pulsaciones se pelearon con la
máquina en uso. Desde aquí, todo con `guion.ps1` y la sonda
`runtime/diagnostico/nx-guion.rb`: el juego se conduce desde dentro (contesta a
`Input` y saca las fotos con `Graphics.snap_to_bitmap`) y el emulador se queda
minimizado. `Z hasta` cruza título, avisos, pantalla de carga y la escena de la
madre sin contar cajas.

Recorrido: Continuar → escalera (13,4) del mapa 17 → escena de la madre en el 16
→ puerta (32,13) → Albacete (17,30) → diez pasos al este y doce al oeste. Sin una
excepción, 50–55 fps.

| # | Hito | Captura |
|---|---|---|
| 11 | Pantalla de carga con su fondo | `pokemon-iberia-hito-11-carga-con-fondo.png` |
| 12 | Albacete, recién salido de casa | `pokemon-iberia-hito-12-albacete.png` |
| 13 | Albacete, al este, con el mapa ya desplazado | `pokemon-iberia-hito-13-albacete-este.png` |

### Lo que queda

- El primer combate, igual que antes.
- ~~Tres avisos en inglés en cada arranque~~ («One or more fonts used in this game
  do not exist on the system…»). Eran `FontInstaller.install` (sección 105), que
  busca las fuentes en la carpeta de fuentes de Windows. Quitados en
  `nx-ruby18.rb` (`NX18Tarde.fuentes`) para los cinco juegos de la familia: el
  motor ya carga las de `Fonts/` y lo dice en el registro (`el motor ve las 6
  fuentes del juego`).
- Lo de `KleinBitmap.dll` y los `.mid`, como estaba.

### Después de publicar la 0.2.1: la pantalla de Controles

Randy, jugando a mano, abrió Menú → Controles y el juego se cerró:

```
Section134:187:in `getKeyName': undefined method `index' for {"Backspace"=>8, ...}:Hash
  from Section134:218:in `keyName' ... pbStartPokemonMenu
```

`CONTROLSLIST.index(keyCode)`: en 1.8 `Hash#index` daba la clave de un valor; en
3.x es `Hash#key` y `index` ya no existe. El censo de la familia lo había dado
por no usado. Está en las pantallas de Controles de Iberia, Z y Titán. Repuesto
en `nx-ruby18.rb`. Con `guion.ps1`: menú, Controles, bajar por la lista y salir,
sin un error.

### Recorrido de pantallas con la sonda de excepciones

`nx-guion.rb` apunta ahora cada excepción que se LANZA mientras corre un guion,
aunque el juego la rescate, y al salir el recuento. Recorrido con la partida del
jugador más dos Pokémon, Pokédex, objetos y dinero dados por el guion: menú de
pausa, equipo, resumen (tres páginas), Pokédex y una entrada, mochila y sus
bolsillos, ficha, opciones (cambiando una), controles, guardar (escribe
`Game.rxdata`), PC, tienda (comprar) y combates salvajes en la casa, en Albacete
(`Pradera`) y con el fondo `Otoño`. Ni un cierre.

Lo que dijo la sonda:

| Veces | Excepción | Qué es |
|---|---|---|
| 345 | `NameError` `PBMoves` en `fromSymbol` | el juego registra manejadores antes de cargar sus constantes y lo rescata; igual en el PC |
| 117 | `Errno::ENOENT` en `pbGetFileChar` | `pbResolveBitmap` probando extensiones |
| 16 | `RangeError` "recycled object" en su `WeakRef` | caché de bitmaps; rescatado |
| 11 | `SyntaxError` en `nx-ruby18.rb` | `NXFuente` probando y arreglando secciones |
| 1 | `Errno::ENOENT` `Data/Constants.rxdata` | `pbSafeLoad` intenta BORRAR el fichero suelto si hay `Game.rgssad`; en el contenedor no hay suelto. Ojo con `-Contenedor carpetas` |
| 1 | `NoMethodError` `Audio.bgm_position` | **de 1.8**: rescatado con `rescue 0`, pero la música del mapa volvía a empezar tras cada combate. Repuesto en `nx-ruby18.rb` (`bgm_pos`) |

El combate en la casa sale sin fondo: el mapa 17 no tiene `MetadataBattleBack` y
el juego busca `battlebgIndoorA`, que Iberia no trae. Igual en el PC. En
exteriores y con nombres con `ñ` el fondo y las bases salen bien
(`pokemon-iberia-hito-14-combate-pradera.png`, `-15-combate-otono.png`).
