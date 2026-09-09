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
| 4 | Primer mapa | `1 Intro` en el registro; sin captura del jugador andando |
| 5 | Menú | no se llegó |
| 6 | Guardar | no se llegó |
| 7 | Combate | no se llegó |

## Lo que queda

- Pasar la introducción hasta el mapa jugable, el menú y guardar. No hay ningún
  error que lo impida: es tiempo de sesión.
- Los cuatro `.mid` de este juego no suenan: no trae soundfont y
  `midiSoundFont` no apunta a ninguno (`Failed to load libfluidsynth.so` en
  `mkxp-debug.log`).
- El agua y las cascadas: son lo que `KleinBitmap.dll` animaba desplazando el
  bitmap. Hay que mirarlas cuando alguien llegue a un mapa con agua.
