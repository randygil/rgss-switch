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

## Dónde se llegó

| Hito | Captura |
|---|---|
| Selección de idioma, 60 FPS | `pokemon-uranium-hito-1-idioma.png` |
| Menú principal (New Game / Options / Exit) | `pokemon-uranium-hito-2-menu-principal.png` |
| Partida nueva: la introducción del profesor | `pokemon-uranium-hito-3-intro.png` |

`[donde] mapa 51 en (0,0)` en `mkxp-boot.log`: el juego ha cargado su primer
mapa. **Ni una sola excepción** en el camino: no hay `errorlog.txt`.

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
