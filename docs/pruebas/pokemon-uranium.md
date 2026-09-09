# Pokémon Uranium 1.3.2 en el emulador — 9 de septiembre de 2026

El único juego del censo que **no** es mkxp-z: `Uranium.exe` son 110 KB con
`RGSS Player` dentro y `RGSS102E.dll` al lado, o sea el reproductor original de
RPG Maker XP con Ruby 1.8.1. Sus datos van cifrados en `Uranium.rgssad` (254
entradas, todas `Data/`); `Graphics/`, `Audio/` y `Fonts/` van sueltos y caben
en `datos.zip`.

Se prueba sobre `%APPDATA%\Ryujinx\sdcard\switch\pokemon-uranium`, empaquetado
con `-Contenedor zip` desde la entrega `release/rgss-switch-0.1.0`, y con el
emulador **en ventana, con el volumen a 0 y sin robar el foco salvo para mandar
una tecla** (§8 de `CONVENCIONES.md` y `jugar.ps1` desde el commit 47a4f8c).

Los cuatro arreglos genéricos de la familia `ruby18` (commit `0ec376f`) ya
estaban puestos y **funcionan igual de bien aquí**: Uranium trae el mismo
`PSystem_Controls` que reescribe `module Input` sobre `GetAsyncKeyState`, el
mismo `StringInput`, el mismo `getOggPage` y el mismo `ENV["TEMP"]`. En el
registro salen sus tres líneas y no hubo que tocar nada de eso.

## Las vueltas

### Vuelta 1 — `RegexpError` en `CJK Utilities`, sección 54 de 260

**Síntoma**: pantalla negra, el emulador se cierra solo a los pocos segundos.

**Registro** (`mkxp-debug.log`):

```
Section054:96:in `<module:WordRegexp>':
  encoding mismatch in dynamic regexp : UTF-8 and ASCII-8BIT (RegexpError)
	from Section054:69:in `<module:CJKUtils>'
```

**Causa**: `CJK Utilities` declara once expresiones regulares como secuencias de
bytes (`/(?:\xe4[\xb8-\xbf][\x80-\xbf]|...)/n`, las clases de caracteres chinos,
japoneses y coreanos) y otras cuatro con letras acentuadas y griegas escritas
tal cual; luego las **mezcla** en expresiones dinámicas:

```ruby
WesternLatinWord = /(?:#{LatinCharSet}|#{GreekCharSet}|#{FullWidthLatin}|
                     [0-9]|#{FullWidthNumber})+\-?/          # línea 96
```

En Ruby 1.8 eso era todo bytes y casaba. En 3.1 las de `\xNN` son `ASCII-8BIT`,
las de letras son `UTF-8`, y juntarlas es un error. Y es un error **de
ejecución**: por eso el censo, que compilaba las 260 secciones, no lo vio, y por
eso `NXFuente` tampoco puede verlo. El `/n` que `NXFuente` le añade a la línea 94
hace falta para *compilar* y no tiene nada que ver: la línea 93 ya traía el suyo.

**Arreglo**: `juegos/pokemon-uranium/lib/nx-uranium-audio.rb` — el shim ya
envolvía `NXFuente.transforma`, así que además de sustituir dos secciones ahora
**parchea** una tercera: reescribe el `module WordRegexp` entero con clases de
caracteres Unicode (`/[一-龥]/` en vez de los cuatro alternativos de bytes, etc.).

No se puede arreglar por el camino contrario —ponerle `/n` a las otras— porque
Ruby 3.1 **rechaza en compilación** un `/.../n` con caracteres no ASCII sin
escapar. Y no es una aproximación: los once rangos se comprobaron uno a uno
contra el literal original recorriendo `U+0020..U+FFFF` entero, y dan
exactamente el mismo resultado (`tmp/uranium-prueba.rb`, apartado 6). Encima
ahora casan caracteres y no bytes, que es lo que el módulo quería decir.

### Vuelta 2 — la pantalla de idiomas, y el aviso de las fuentes

Con eso el juego **arranca**: pantalla de selección de idioma a 60 FPS en 40
segundos (`docs/capturas/pokemon-uranium-hito-1-idioma.png`). El chino sale como
cuadros vacíos porque su fuente no está en el sistema; el resto se lee perfecto.

Detrás hay tres cuadros de diálogo que dicen «Tu sistema no posee una o más de
las fuentes de texto que usa este juego (...) la experiencia de juego será
subóptima». Es `gdi32!AddFontResource` devolviendo 0 en el `Win32API` postizo.
**Es una falsa alarma**: mkxp-z carga las fuentes de `Fonts/` por su cuenta y el
texto se dibuja bien, como se ve en las capturas. No se toca; son tres Z al
arrancar.

### Vuelta 3 — `undefined method 'fgetdw' for #<FileInt>`

**Síntoma**: el juego llega al menú principal y muere al empezar partida.

**Registro** (`errorlog.txt`):

```
Exception: NoMethodError
Message: undefined method `fgetdw' for #<FileInt:0x000000020df94818>
** Compiler:432:in `block in readItemList'
FileTests v17:369:in `pbRgssOpen'
```

**Causa**, y es del empaquetador, no del juego. `FileTests v17` decide **por el
nombre del fichero** si sus datos están en un archivo cifrado:

```ruby
def pbRgssOpen(file,mode=nil)
  if !safeExists?("./Uranium.rgssad") && !safeExists?("./Game.rgss2a")
    return File.open(file,mode)          # <- el camino equivocado
  ...
  return StringInput.open(load_data(file))
```

Y son **cinco** sitios los que preguntan por ese nombre exacto (`FileTests v17`
356, 367, 394 y 425; `PSystem_System` 5). El empaquetador copiaba el archivo
como `Game.rgssad` —lo que mkxp-z busca por omisión—, así que el juego concluía
que no había archivo y abría sus `.dat` con `File.open`. En Horizon eso devuelve
un `FileInt` (el `File.open` del motor cae a PhysFS, `filesystem-binding.cpp`),
y `FileInt` no es el `File` al que el juego le añadió `FileInputMixin`.

**Arreglo**: `"mkxp": { "execName": "Uranium" }` en el perfil. Con eso mkxp-z
abre `Uranium.ini` y monta `Uranium.rgssad`, el empaquetador ya no renombra
nada, y el juego vuelve a su propio camino —el que de verdad se ha probado
durante diez años en Windows—.

### Vuelta 4 — el motor exigía que el archivo se llamara `Game.rgssad`

**Síntoma**: pantalla roja de `nx_aviso`, «FALTA Game.rgssad, LA LLAVE DEL
CONTENEDOR», y no arranca.

**Causa**: `mkxp-z-nx/nx/nx_juego.h` define `NX_LLAVE "Game.rgssad"` y
`nx_aviso.c` lo exigía por ese nombre. Es correcto para todos los juegos que
llevan la llave de ocho bytes del empaquetador, y falso para el único que trae
un RGSSAD de verdad con otro nombre.

**Arreglo**: `mkxp-z-nx/nx/nx_aviso.c` — un `busca_archivo()` que prueba primero
`NX_LLAVE` y, si no está, recorre la carpeta buscando cualquier `.rgssad`,
`.rgss2a` o `.rgss3a`. La comprobación sigue siendo la misma —«¿hay archivo, sí
o no?»— pero deja de depender de un nombre fijo. En el registro:

```
[   355] [ OK  ] Uranium.rgssad (hace que el juego lea del contenedor)
```

### Vuelta 5 — `RegexpError` en `DrawText`, hija del arreglo de la vuelta 1

**Síntoma**: al abrir «Reconfigure Controls» en el diálogo del profesor, el juego
escribe `errorlog.txt` y se para.

**Registro**:

```
Exception: RegexpError
Message: /.../n has a non escaped non ASCII character in non ASCII-8BIT script
DrawText:921:in `getLineBrokenChunks'
SpriteWindow_text:1055:in `resizeToFitInternal'
... Control Binding:533:in `pbStartScene'
```

**Causa**: la línea 921 de `DrawText` es **la única de las 260 secciones que
interpola `WordRegexp` fuera de su propio módulo**, y lo hace con `/n`:

```ruby
while (c = textmsg.slice!(/(?:\n|[ \r\t\f]+|#{CJKUtils::WordRegexp::WordRegexp}[ \r\t\f]*)/n))
```

Con los literales de bytes originales todo era `ASCII-8BIT` y el `/n` cuadraba;
con el módulo reescrito en UTF-8 (vuelta 1) ya no. **No se puede resolver
escribiendo los rangos con `\uNNNN`**: Ruby normaliza el escape al construir la
expresión y `Regexp#source` devuelve el carácter, así que el `/n` lo vuelve a
ver igual. Probado.

**Arreglo**: un segundo parche en el mismo shim, `parche_drawtext`, que le quita
el `/n` a esa línea. Sin él la expresión es UTF-8 y `slice!` corta por
caracteres, que es exactamente lo que un partidor de líneas quiere hacer con un
texto UTF-8. `getLineBrokenChunks` no es un rincón: es el ajuste de línea de
todas las ventanas que se dimensionan solas.

Y este error **no se ve compilando**: es de ejecución, como el de la vuelta 1.
La prueba del PC lo comprueba construyendo la expresión de la línea 921 con el
módulo nuevo puesto (`tmp/uranium-prueba.rb`, apartado 7).

### Vuelta 6 — el muro: el proceso muere al acabar la introducción

**Síntoma**: se completa la introducción entera —idioma, menú, partida nueva,
las ~45 cajas de diálogo del profesor, el nombre en la rejilla, «Let's go!»— y
en el fundido a negro que lleva al primer mapa de verdad **el proceso invitado
desaparece**. Sin pantalla de error, sin `errorlog.txt`, sin excepción de Ruby y
sin excepción de C++.

Reproducido **cinco veces**. Lo que se sabe, medido:

- La última llamada de Ruby que se registra es siempre la misma:
  `Audio.bgm_fade(4000)`, **y devuelve** (`[audio<] bgm_fade -> nil`). Se
  instrumentó cada llamada al Audio nativo, antes y después: todas entran y
  salen. La capa de audio nueva no es.
- Una sonda de latido en `Graphics.update` deja de escribir a la vez
  (`[latido] 6780 escena=Scene_Map mapa=51`), pero eso **no** prueba que Ruby
  muera ahí: `Graphics.transition` tiene su propio bucle de fotogramas y no pasa
  por `Graphics.update`.
- El contador de fotogramas del motor (`[monton]`, cada 30 s) **sigue 17
  segundos más** y luego para. O sea: el hilo RGSS se queda dentro de una
  llamada nativa que no vuelve, y el proceso se cae después.
- No es la memoria: 397 MB de montón y 79 MB de texturas vivas, con 3.282 MB
  disponibles.
- **No es `Graphics.resize_screen`**, que era el sospechoso del informe de la
  fase 1. Se probó retirándolo del motor antes de que `Sprite_Resizer` lo aliase
  —con lo que `@@haveresizescreen` sale `false` y el juego no redimensiona
  nada— y el proceso murió exactamente igual.
- No es un tope de tiempo del emulador ni del guion: Añil corre 193 s en la
  misma máquina sin inmutarse, y Uranium ha llegado a 160 s vivo cuando el guion
  se desincronizaba y no alcanzaba la transición.

Queda por probar, para el que siga: el modo diagnóstico completo
(`Empaquetar.ps1 -Diagnostico`, con `nx-metodos.rb`, que envuelve cientos de
métodos y diría el último que se llamó), y leer el evento 2 del mapa 51, que es
el que hace la transferencia.

**Cómo se conduce esta introducción**, para no repetir el trabajo:

- La pantalla de idioma sale **antes** del título: una ABAJO para `Español`, Z,
  y sale un diálogo de confirmación con la ✗ marcada; hay que ir a la ✓ con
  DERECHA y otra Z.
- Detrás vienen tres avisos de fuentes (tres Z).
- **La trampa**: a las ~30 cajas el profesor pregunta «Want the low-down on what
  you'll be doing?» con un menú de cuatro —`Adventure`, `Controls`,
  `Reconfigure Controls`, `No Info Needed`— y `Adventure` **vuelve a empezar la
  explicación**. Un guion que sólo pulse Z se queda dando vueltas para siempre;
  costó cuatro vueltas verlo. Hay que bajar tres veces y elegir `No Info
  Needed`.
- La rejilla del nombre es la de Essentials clásico y responde al mismo patrón
  Z-C-Z que la familia `ruby18`: Z mete la letra, C salta a `OK`, Z confirma, y
  después una Z más para el `Yes` de «Your name is X?».
- Contar pulsaciones **no es fiable**: el mismo guion desincroniza entre
  ejecuciones según la cadencia. Lo que sí funciona es repetir bloques de
  `ABAJO ABAJO ABAJO Z Z Z Z Z Z` (las flechas no hacen nada sobre una caja de
  texto y eligen `No Info Needed` cuando aparece el menú) y rematar con parejas
  `C Z` (la C no hace nada sobre una caja de texto y es `OK` en la rejilla).

## Dónde se llegó

| Hito | Captura |
|---|---|
| Selección de idioma, 60 FPS | `pokemon-uranium-hito-1-idioma.png` |
| Menú principal (New Game / Options / Exit) | `pokemon-uranium-hito-2-menu-principal.png` |
| Partida nueva: la introducción del profesor | `pokemon-uranium-hito-3-intro.png` |
| El nombre del jugador, en la rejilla | `pokemon-uranium-hito-4-nombre-rejilla.png` |
| El final de la introducción: «Let’s go!» | `pokemon-uranium-hito-5-vamos-alla.png` |

`[donde] mapa 51 en (0,0)` en `mkxp-boot.log`: el mapa de la introducción, con
el profesor. **Ni una sola excepción** en todo ese camino: no hay
`errorlog.txt`.

Lo que **no** se ha alcanzado: el primer mapa jugable, andar, el menú de pausa,
guardar y el combate. El muro es el de la vuelta 6.

## Tiempos

| | |
|---|---|
| motor listo (`[boot] 11`) | 5,7 s |
| las 260 secciones por `NXFuente` | 1,9 s (258 pasan, 1 tocada, 1 arreglo) |
| pantalla de idioma jugable | ~10 s |
| índice de PhysFS (6.708 entradas) | 1,1 s |
| tirón al cargar el primer mapa | 434 ms (47 MB de imagen, 35 ficheros) |

El coste de descifrar el RGSSAD **no aparece**: los tirones grandes del arranque
(1,4–1,5 s) son de CPU (`resto 1499 ms`, `io 7x 4 ms`), o sea de los scripts, no
de leer el archivo.

## Lo que se ve y no se arregla

- Los tres avisos de fuentes al arrancar (`AddFontResource` postizo).
- El chino en la lista de idiomas sale como cuadros vacíos.
- Los tonos sintetizados de `AudioUtilities v17` (`Audio.sine` y compañía, 39
  usos) salen por `winmm` y no suenan: son el timbre del teléfono y los pitidos.
- Los 4 `.mid` de `Audio/` no tienen soundfont
  (`Failed to load libfluidsynth.so`).

---

## Vuelta 7 — 9 de septiembre de 2026, tarde: el muro es de Ryujinx, y es el mismo que el de Ópalo

La vuelta 6 dejó descartados el audio, `Graphics.resize_screen` y la memoria, y
dejó pendientes dos cosas: el modo diagnóstico y **leer el registro del
anfitrión**. Se hizo lo segundo, que era lo barato, y contestó.

Se reprodujo el cierre una vez más —introducción entera con los bloques que ya
estaban escritos, y el proceso desaparece en el fundido al primer mapa— y esta
vez se miró donde nadie había mirado:

- `C:\Games\publish\Logs\Ryujinx_1.3.3_*.log`: **no dice nada**. La última línea
  de invitado es de los 7,9 s (`Failed to load libfluidsynth.so`) y a partir de
  ahí sólo hay `ServicePcv GetClockRate: Stubbed`, tres por segundo, hasta que se
  corta. Ni excepción de .NET, ni instrucción indefinida, ni región de memoria
  inválida.
- El **visor de sucesos de Windows** (`Application Error`, id 1000), en el
  instante de la muerte:

```
Nombre de aplicación con errores: Ryujinx.exe, versión: 1.3.3.0
Nombre del módulo con errores:    Ryujinx.exe, versión: 1.3.3.0
Código de excepción:              0xc0000005
Desplazamiento con errores:       0x00000000001250ef
```

**Violación de acceso dentro del emulador.** Y Ópalo, el otro cierre mudo del
proyecto, muere con el mismo código de excepción en `0x1253fb`: **780 bytes de
distancia dentro del mismo binario**, o sea la misma zona de código de
Ryujinx 1.3.3. Los dos cierres mudos que quedaban son, hasta donde se ve desde
fuera, un único fallo del anfitrión y no dos fallos del motor.

Esto encaja con lo que ya se había medido y no se sabía interpretar: el contador
de fotogramas del motor seguía diecisiete segundos más después de que el hilo
RGSS se quedara dentro de una llamada nativa. Un anfitrión que se cae por una
violación de acceso no le da al invitado ocasión de escribir nada.

**Qué NO se hace**: esquivarlo. No se va a cambiar el motor para no pisar lo que
sea que Ryujinx no aguanta, porque no sabemos qué es y cada apaño taparía la
medición. Lo que hace falta es **una consola de verdad**, donde no hay anfitrión
que se caiga; si allí pasa el fundido, esto queda como un fallo del emulador y se
documenta, y si allí también muere, entonces habrá una traza de invitado de
Atmosphère (`recoger.ps1` la trae) que es justo lo que aquí no hay.

**Lo que sigue pendiente y no se ha hecho**: el modo diagnóstico completo con
`nx-metodos.rb` para saber el último método llamado, y leer el evento 2 del mapa
51 —el que hace la transferencia—, que ahora es más fácil que antes porque
`leer-mapa.rb` lee un `MapNNN.rxdata` con el Ruby del PC (el de Uranium hay
que sacarlo antes de `Uranium.rgssad` con `dump-rgssad.py`).
