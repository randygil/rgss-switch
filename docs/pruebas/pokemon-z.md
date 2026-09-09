# Pokémon Z 2.13 en el emulador — 9 de septiembre de 2026

Primera vez que este juego se enciende. Ryujinx, tarjeta virtual en
`%APPDATA%\Ryujinx\sdcard`, motor de HEAD. Lo común con Ópalo, Iberia y Titán
está en [`familia-ruby18.md`](familia-ruby18.md).

**Estado: `arranca`.** Título, menú de carga en español, partida nueva, la
rejilla del nombre, la introducción entera con sus diálogos y un segundo mapa
(`168 Auxiliary Intro`), sin una sola excepción en el registro. No se llegó a
guardar partida ni al primer combate: se acabó el tiempo de la sesión, no el
juego.

## Qué se empaquetó y cómo

```
powershell -NoProfile -ExecutionPolicy Bypass -File Empaquetar.ps1 -SinInterfaz `
  -Juego "C:\Users\Usuario\Downloads\RPG MAKERS POKEMONS FANS\POKEMON Z V2.13" `
  -Salida "C:\Users\Usuario\AppData\Roaming\Ryujinx\sdcard" -Contenedor zip `
  -Entrega "C:\rgss-switch\release\rgss-switch-0.1.0"
```

19.055 ficheros y 823 MB en `datos.zip`; 871 MB en 118 ficheros. El
`preloadScript` compuesto acaba con el `preload.rb` del juego, que es el que
redefine `Zlib::Inflate.inflate` sobre `MKXP.zinflate`: **la sospecha del censo
no se cumplió**, `nx-compat.rb` va delante y la cadena no se rompe. Ni una línea
de zlib en el registro.

El `Scripts.rxdata` suelto de la raíz viaja a la tarjeta —§2 copia todos los
ficheros de la raíz— y, como el censo decía, no lo lee nadie.

## Las vueltas, en orden

Las tres primeras heredan los arreglos de Ópalo (recolector, `each_byte`,
`getbyte`/`setbyte`/`bytesize`), que ya estaban puestos. Éstas son las que este
juego destapó por su cuenta.

### 1. La pantalla de título se moría midiendo la música

```
Section040:1020:in `getOggPage': undefined method `times' for "\x01":String
	from Section040:1038:in `oggfiletime'
	from Section040:1146:in `block in getPlayTime2'
	from Section159:397:in `initialize'          (Titulo)
```

`hdrbodysize = (file.read(1)[0] rescue 0)` seguido de `hdrbodysize.times`: el
lector de cabeceras Ogg de Essentials clásico, con la semántica de 1.8. De
`getPlayTime` cuelga `@totalFrames = getPlayTime(str).to_i * Graphics.frame_rate`
**siete veces** en el `Titulo.rb` de este juego.

Se sustituyen `getOggPage` y `oggfiletime` por la misma cuenta escrita con
`getbyte`. Van los dos juntos porque `oggfiletime` vuelve a leer bytes sueltos
para el tipo de paquete y los canales, y con la semántica nueva devolvía `-1`
en silencio, que es una animación de título descuadrada.

### 2. Al cerrar el título: `No instance data for variable`

```
Section043:4373:in `dispose': No instance data for variable
                              (missing call to super?) (MKXPError)
	from Section043:4523:in `dispose'            (AnimatedPlane)
	from Section043:1152:in `pbDisposeSprite'
	from Section159:187:in `disposeTitle'
```

`LargePlane < Plane` y su `initialize` nunca llama a `super`. Se construye el
`Plane` que falta, que es lo que el propio mensaje pide.

### 3. El primer mapa: `Dir.chdir(nil)`

```
Section043:811:in `chdir': no implicit conversion of nil into String (TypeError)
	from Section043:811:in `initialize'          (BitmapWrapper)
	from Section043:259:in `pbGetAutotile'
	... Spriteset_Map
```

`Dir.chdir(ENV["TEMP"]){ ... }`, «since game might be on a CD-ROM», para
convertir GIF a PNG. En Horizon no hay entorno que heredar. Se apunta `TEMP`,
`TMP` y `TMPDIR` a la carpeta del juego. Dentro de ese bloque no se escribe
nada: `gif.dll` no viaja a la tarjeta.

### 4. Las sombras de los eventos: `nil.id`

```
Section163:75:in `update': undefined method `id' for nil:NilClass
	from Section163:42:in `initialize'           (Sombras.rb)
	... createSpritesets -> Scene_Map#main
```

`@sprite.visible = !(@event.bush_depth>0 or !(@map.id==$game_map.id) or ...)`.
En 1.8 `nil.id` valía 4, la comparación fallaba y la sombra se quedaba
invisible; nadie se enteraba. Definir `Object#id` devuelve **ese**
comportamiento. En el registro salen las diez primeras llamadas con su
llamante, y todas son ésta.

### 5. El primer cuadro de diálogo: `$~` es nil

```
Section044:498:in `getFormattedText': undefined method `pre_match' for nil:NilClass
```

Este no fue un fallo del juego: fue **mío**. Se había emulado `String#[]` con un
entero acotándolo a las cadenas binarias, y cualquier envoltorio de `[]` escrito
en Ruby se come el `$~` del que llama. Contado entero en `familia-ruby18.md`.
Se retiró.

### 6. Al confirmar el nombre: `Marshal.load` devolvía el puerto

```
Exception: NoMethodError
Message: undefined method `[]' for #<StringInput:closed,
         src="\x04\b[\x01\xC4[\x0Fi\x00\"\x1FPOKEMONTRAINER_Chic">
PSystem_Utilities NUEVO:547:in `block in pbGetTrainerTypeGender'
... pbTrainerName
```

Todo Essentials clásico lee sus `.dat` así:

```ruby
pbRgssOpen("Data/trainertypes.dat","rb"){|f| trainertypes = Marshal.load(f) }
```

`marshal.c` de 3.1 acepta una cadena, o un objeto que responda a `read` **y** a
`getbyte`; si no, `rb_io_check_io` y `TypeError: instance of IO needed`.
`StringInput` tiene `read` y no tiene `getbyte`. Lo peor es que el
`Marshal.load` que el propio juego redefine **rescata** esa excepción y
devuelve el puerto, así que el error sale mucho después y sin relación
aparente. Se comprobó con `Marshal.oldload` sobre una copia del mismo puerto:

```
[diag]   oldload sobre una copia FALLA: TypeError: instance of IO needed
```

Un `getbyte` de dos líneas en `StringInput` devuelve a marshal el camino de pato
que tenía en 1.8.

De paso se aprendió que **el memorizador de `.dat` no puede tocar la forma con
bloque**: el `pbRgssOpen` del juego mueve `Marshal.neverload` alrededor del
`load_data`, y saltarse ese camino deja el indicador en un estado que el bloque
no espera.

## Los tiempos

| ms | línea |
|---|---|
| 275 | `[juego] carpeta: sdmc:/switch/pokemon-z` |
| 3.039 | `[boot] 8 initGL OK, hilo RGSS vivo` |
| 4.262 | `[boot] 10a+ contenedor datos.zip montado` |
| 4.451 | `[boot] 10c pathCache construido` |
| 4.550 | `[boot] 11 SharedState OK, arrancando el intérprete Ruby` |
| 5.474 | `[boot] scripts pasan por NXFuente.transforma` |
| 9.068 | primer `[monton]`: el juego ya está dibujando |

`[fuente] TOTAL: 235 secciones, 3 tocadas, 25 arreglos, 2195.4 ms`.

**El juego entero carga en unos diez segundos**, contra los 102 s de Vanguard y
los 90 s de Reborn. Las esperas de 190 s de estas pruebas sobran de largo.

Los mapas, con el reloj del registro (incluye lo que tardan los botonazos del
guion, no el juego):

```
[212657] [donde] mapa   1 Intro en (10,7)
[318138] [donde] mapa 168 Auxiliary Intro en (9,6)
```

## Cómo se conduce

- **El idioma se pregunta antes del título**: `English` arriba, `Spanish`
  debajo. Una ABAJO y una Z.
- Título → menú `Nuevo juego / Otras partidas / Opciones / Idioma`.
- La rejilla del nombre: **Z** mete la letra, **C** salta el cursor a `FIN`,
  **Z** confirma (`pokemon-z-rejilla-fin.png` es la captura del cursor sobre
  `FIN`). La leyenda de la pantalla —«TECLA X = BORRAR, TECLA Z = FIN»— es la
  del teclado del PC, no la del mando.

## Hitos

| # | Hito | Captura |
|---|---|---|
| 1 | Pantalla de título | `pokemon-z-hito-1-titulo.png` |
| 2 | Menú de partida nueva | `pokemon-z-hito-2-partida-nueva.png` |
| 3 | Nombre del jugador en la rejilla | `pokemon-z-hito-3-rejilla.png` y `pokemon-z-rejilla-fin.png` |
| 4 | Primer mapa | `1 Intro` y `168 Auxiliary Intro` en el registro; sin captura del jugador andando |
| 5 | Menú | no se llegó |
| 6 | Guardar | no se llegó |
| 7 | Combate | no se llegó |

## Lo que queda

- Terminar la introducción hasta el mapa jugable, abrir el menú y guardar. El
  juego no da ningún error: es tiempo de sesión.
- `winmm!mciSendString` y `winmm!mciGetErrorString` se piden pero no se llaman:
  el segundo sistema de audio (los tonos del teléfono) no ha hecho falta.
- 36 funciones de `Win32API` pedidas, **ninguna sin semántica**.

---

## Segunda vuelta — 9 de septiembre de 2026, tarde: **jugable**

**Estado: `jugable`.** Introducción entera, mapa jugable, cuatro pasos, menú y
**partida guardada**: `Game.rxdata`, 85.701 bytes. Tres vueltas de emulador, y
las dos primeras se perdieron en la misma trampa.

### La trampa del mapa 168, y por qué contar teclas no vale

`leer-mapa.rb` sacó del `Map168.rxdata` lo que ninguna captura enseñaba:

```
118 "advertencia"                       <- etiqueta
101 "SI EL JUEGO TE VA MUY RÁPIDO, ..."
101 "SI EL JUEGO TE VA LENTO EN JOIPLAY ..."
101 "¿ENTENDIDO?"
102 ["No", "Sí"], 2
402 0, "No"  ->  119 "advertencia"      <- vuelve a empezar
402 1, "Sí"  ->  sigue
```

Las dos opciones están **al revés** de lo que uno espera, y `No` salta a la
etiqueta. La vuelta 1 usó bloques de cuatro teclas (`ABAJO Z Z Z`) y se quedó
dando vueltas los doce bloques enteros: el aviso son tres cajas, el bloque son
cuatro teclas, el `ABAJO` caía **siempre** sobre la primera caja —donde no hace
nada— y los tres `Z` avanzaban las tres cajas contestando `No`. Sincronizado
para fallar.

Con **parejas `ABAJO Z`** el `ABAJO` cae sobre una caja distinta cada vez y a la
tercera pareja toca el menú. La pregunta siguiente,
`¿Saltar la intro del juego?`, tiene `Sí` también abajo y lleva a
`65 Real intro` (las dieciséis cajas de la carta de la profesora Olivier) y de
ahí a `66 Carriage`. Las cajas son largas: hacen falta **dos** pulsaciones por
caja —una completa el texto, la otra pasa—, y sesenta parejas cubren el tramo
con margen (la vuelta 2, con veintiocho, se quedó en la caja trece de dieciséis).

### El menú de pausa de este juego no es el de Essentials

No es `PScreen_PauseMenu`: es uno propio, con iconos y borde naranja.

```
Bag / Craft / Feats / Save / Options
```

`Save` es la cuarta: **X, tres ABAJO y Z**.

| ms | dónde |
|---|---|
| 50.593 | `[donde] mapa 1 Intro en (10,7)` |
| 77.208 | `[donde] mapa 168 Auxiliary Intro en (9,6)` |
| 102.775 | `[donde] mapa 65 Real intro en (1,0)` |
| 173.927 | `[donde] mapa 66 Carriage en (8,7)` |

### Hitos

| # | Hito | Captura |
|---|---|---|
| 4 | Primer mapa jugable | `pokemon-z-hito-4-mapa.png`, `-5-andando.png` |
| 5 | Menú | `pokemon-z-hito-6-menu.png`, `-7-menu-guardar.png` |
| 6 | **Guardar** | `pokemon-z-hito-8-confirmar.png`, `-9-guardado.png` |
| 7 | Combate | no se llegó |

### Lo que queda

- El primer combate.
- La introducción larga (la que se salta con `No` en `¿Saltar la intro?`) no se
  ha visto: lleva al mapa 170 y no se ha probado.
