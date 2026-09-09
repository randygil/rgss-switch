# Pokémon Titán 2.10 en el emulador — 9 de septiembre de 2026

Primera vez que este juego se enciende. Ryujinx, tarjeta virtual en
`%APPDATA%\Ryujinx\sdcard`, motor de HEAD. Lo común está en
[`familia-ruby18.md`](familia-ruby18.md).

**Estado: `arranca`.** Como Iberia, **a la primera y sin una sola vuelta de
arreglo**, y un poco más lejos que él: título, menú de carga, partida nueva y la
introducción con la profesora hablando. Ni una excepción, ni `errorlog.txt`.

## Qué se empaquetó y cómo

```
powershell -NoProfile -ExecutionPolicy Bypass -File Empaquetar.ps1 -SinInterfaz `
  -Juego "C:\Users\Usuario\Downloads\RPG MAKERS POKEMONS FANS\POKEMON TITAN V2.10" `
  -Salida "C:\Users\Usuario\AppData\Roaming\Ryujinx\sdcard" -Contenedor zip `
  -Entrega "C:\rgss-switch\release\rgss-switch-0.1.0"
```

431 MB en 1.407 ficheros, con `Animations/` suelta y `PBS` excluida: el mismo
reparto que Iberia, como el censo decía. Tampoco trae `mkxp.json` ni
`preload.rb`.

## Vueltas: ninguna

Los mismos nueve arreglos de la familia se disparan en el mismo orden. La única
diferencia con Iberia en el registro es que Titán **no** pide
`user32!GetDC`/`gdi32!BitBlt` (no trae el `Map - Klein.rb` con su
`Graphics.snap_to_bitmap` de gdi32), aunque sí pide `kleinbitmap!version`.

## Los tiempos

| ms | línea |
|---|---|
| 365 | `[juego] carpeta: sdmc:/switch/pokemon-titan` |
| 3.662 | `[boot] 8 initGL OK, hilo RGSS vivo` |
| 4.844 | `[boot] 10a+ contenedor datos.zip montado` |
| 5.124 | `[boot] 10c pathCache construido` |
| 5.224 | `[boot] 11 SharedState OK, arrancando el intérprete Ruby` |
| 6.137 | `[boot] scripts pasan por NXFuente.transforma` |
| 9.665 | primer `[monton]`: el juego ya está dibujando |

`[fuente] TOTAL: 167 secciones, 4 tocadas, 28 arreglos, 1806.5 ms`, otra vez
clavado con el censo.

`[223890] [donde] mapa 1 Intro en (9,7)`, y un `[tiron]` de 2.722 ms al entrar,
con `io 1772193x 95 ms`.

## Lo único feo que se ha visto en esta familia

`docs/capturas/pokemon-titan-intro-profesora.png`: la profesora habla, el cuadro
de diálogo está bien, la fuente está bien... y a su lado hay **un sprite hecho
de ruido**, una columna de píxeles blancos y naranjas sin forma.

Es el `RtlMoveMemory` postizo. El juego construye ese bitmap escribiendo memoria
a mano, pasando `bitmap.__id__*2+16` como si el `object_id` fuera la dirección
del objeto —cierto en el Ruby 1.8 de 32 bits, falso en cualquier Ruby moderno—.
El postizo devuelve 0 y no toca memoria, que es lo único que se puede hacer:
escribir ahí sería corromper el montón. El bitmap sale sin inicializar.

Es el primer sitio donde se ve en pantalla lo que el comentario de
`nx-ruby18.rb` anunciaba, y merece la pena tenerlo apuntado: en esta familia,
un gráfico roto y aislado en medio de una escena que por lo demás está bien es
casi seguro `RtlMoveMemory`, no un recurso que falte.

## Win32API: 28 pedidas, ninguna sin semántica

Llamadas de verdad: `advapi32!RegOpenKeyExA`, `kernel32!GetCurrentProcess`,
`kernel32!GetPrivateProfileString` (esa sí se implementa: lee el `Game.ini` de
la tarjeta), `kernel32!SetPriorityClass`, `kleinbitmap!version`,
`ole32!CoTaskMemFree` y `shell32!SHGetKnownFolderPath`.

## Hitos

| # | Hito | Captura |
|---|---|---|
| 1 | Pantalla de título | `pokemon-titan-hito-1-titulo.png` |
| 2 | Partida nueva | `pokemon-titan-hito-2-partida-nueva.png` |
| 3 | Nombre del jugador en la rejilla | se atravesó con el patrón Z-C-Z; la captura que sí está es la de la introducción, `pokemon-titan-intro-profesora.png` |
| 4 | Primer mapa | `1 Intro` en el registro |
| 5 | Menú | no se llegó |
| 6 | Guardar | no se llegó |
| 7 | Combate | no se llegó |

## Lo que queda

- Lo mismo que Iberia: introducción, mapa jugable, menú y guardar. No hay error
  que lo impida.
- El sprite de `RtlMoveMemory`: averiguar qué script lo construye y si vale la
  pena reescribirlo contra `Bitmap` de mkxp-z en un shim del perfil.
- Los tres `.mid` no suenan, por lo mismo que en Iberia.
