# La familia `ruby18` en el emulador — 9 de septiembre de 2026

Ópalo 2.11, Z 2.13, Iberia 2.10 y Titán 2.10 comparten el mismo `Game.exe`
byte a byte —mkxp-z con Ruby 1.8.7 embebido— y comparten, se ha comprobado,
casi todo lo que les pasa encima de un motor con Ruby 3.1.7. Este fichero es lo
común; cada juego tiene el suyo con sus vueltas y sus capturas.

La pregunta que el censo dejó abierta era ésta:

> «compilar no es correr. Los métodos que 1.8 tenía y 3.1 no, y las semánticas
> que cambiaron, **no se ven con un compilador**. La única forma de saber
> cuántos hay es arrancar el juego con el shim de `Win32API` puesto e ir leyendo
> `mkxp-ruby.log`.»

Son **nueve**, y ninguno de los tres que el censo había apuntado como probables
(`String#[]`, `Array#to_s`, `methods` devolviendo Strings) apareció por donde se
esperaba.

## Lo que el censo acertó

- **La sintaxis no es el problema.** `NXFuente.transforma` arregla, solo,
  exactamente lo que el censo midió a mano: 25 líneas en 3 secciones (Ópalo,
  Z), 28 en 4 (Iberia, Titán), y después compilan las 167–235 secciones de cada
  juego. Cuesta entre 1,8 y 2,2 segundos por juego, una vez, al arrancar.

  ```
  [fuente] TOTAL: 235 secciones, 3 tocadas, 25 arreglos, 2195.4 ms   (Z)
  [fuente] TOTAL: 168 secciones, 4 tocadas, 28 arreglos, 1925.9 ms   (Iberia)
  [fuente] TOTAL: 167 secciones, 4 tocadas, 28 arreglos, 1806.5 ms   (Titán)
  ```

- **El `Win32API` postizo llega.** En los cuatro juegos, entre 28 y 38 funciones
  distintas se piden por su nombre y **ni una sola cayó en el `else`**: no hay
  una sola línea `[win32api] ... sin semantica` en ningún registro. La tabla que
  se escribió a ciegas leyendo el corpus cubre lo que los juegos piden de
  verdad.

## Los nueve de 1.8 que solo se ven ejecutando

Por orden de aparición, con la línea del registro que los delató.

| # | Qué | Dónde se rompía |
|---|---|---|
| 1 | `StringInput#each_byte` entregaba cadenas de un carácter | `fgetb` → `growthrate` → `pbGetStartExperience`: `comparison of String with 6 failed` |
| 2 | `StringInput#getbyte` no existía | `Marshal.load(f)` no acepta el puerto y el juego lo rescata devolviéndolo |
| 3 | `String#getbyte/setbyte/bytesize` aliasados por el juego | el mismo `fgetb` daba 65 en la sección 69 y `"A"` en la 211 |
| 4 | `Object#id` (el `object_id` de 1.8; `nil.id` valía 4) | las sombras de los eventos, al entrar en el primer mapa |
| 5 | `String#each` | `StringInput#each` delega en `@string.each` |
| 6 | `getOggPage` / `oggfiletime` leen bytes con `[0]` | `getPlayTime` → pantalla de título animada de Z |
| 7 | `ENV["TEMP"]` es nil en Horizon | `Dir.chdir(ENV["TEMP"])` en `pbGetAutotile`, primer mapa |
| 8 | El módulo `Input`, reescrito entero sobre `GetAsyncKeyState` | el juego arranca, dibuja y **no responde a nada** |
| 9 | `LargePlane < Plane` cuyo `initialize` no llama a `super` | `No instance data for variable` al cerrar la pantalla de título |

Los nueve están arreglados en `runtime/lib/nx-ruby18.rb`, cada uno con el
comentario que cuenta el fallo que lo motivó. Los seis primeros son de
lenguaje; los tres últimos son de plataforma y son, con diferencia, los que más
caro salen si no se ven.

### 8 merece un párrafo aparte

`PSystem_Controls.rb` (Ópalo 169, Z 151, Iberia y Titán 134) hace `module Input`
y vuelve a definir `update`, `press?`, `trigger?`, `repeat?`, `release?`,
`count`, `dir4` y `dir8` **en Ruby**, leyendo el teclado de Windows:

```ruby
@GetKeyState = Win32API.new("user32", "GetAsyncKeyState", "i", "i")
def self.getstate(key)
  return (@GetKeyState.call(key)&0x8000)>0
end
```

Con el postizo mudo eso contesta 0 siempre. El juego arranca perfectamente, se
ve la pantalla de título, y no hay ninguna tecla que la pase: un juego mudo sin
un solo error en el registro. Y no es un script raro de un juego raro: lo traen
los cuatro, y encima reabren `Input` tres o cuatro secciones más (la captura de
pantalla de KGC, la pantalla de «configura los controles», la tarjeta de
entrenador, el turbo).

El arreglo repone los métodos del motor entre sección y sección —porque cada
reapertura los vuelve a pisar— y traduce los `*ex?`, que el juego llama con
códigos de tecla de Windows, con la tabla `buttonToKey` de los propios juegos
leída al revés.

### Y uno que se probó y NO se hace: `String#[]`

En 1.8 `"abc"[0]` valía 97 y desde 1.9 vale `"a"`. Se probó a emularlo acotado
a lo que parecía seguro —devolver el byte solo si la cadena es `ASCII-8BIT`, o
sea si viene de leer un fichero en binario, y dejar el `[]` de 3.1 para el texto
UTF-8—. **Arreglaba lo suyo y rompía `$~`**, que es peor: cualquier envoltorio
de `[]` escrito en Ruby tiene su propio marco, y el resultado de una expresión
regular se guarda en el marco del que llama.

```
while text[FORMATREGEXP]
  textchunks.push($~.pre_match)     # DrawText.rb:498
Section044:498:in `getFormattedText': undefined method `pre_match' for nil:NilClass
```

O sea, todo el texto del juego. Queda escrito en `nx-ruby18.rb` para que nadie
lo vuelva a intentar.

## El motor: el recolector se llevaba el nombre de la sección

No es de 1.8: es un fallo que el propio gancho de `NXFuente` destapó.
`binding-mri.cpp` crea dos objetos de Ruby —el fuente de la sección y su
nombre— en sendas variables locales de C y los pasa a `eval`. Sin el gancho eso
no da problema, porque entre crearlos y evaluarlos no corre una sola línea de
Ruby y el recolector no llega a correr. `NXFuente.transforma` **compila la
sección entera**, o sea que reserva.

Ópalo moría con un acceso a la dirección 0 dentro del `StringValue(vfile)` de
`rb_f_eval`, y **en una sección distinta cada vez** —la 47 la primera vuelta, la
25 la segunda—: la lotería es la firma de un objeto liberado y reutilizado. Los
dos objetos se guardan ahora en un array registrado con
`rb_gc_register_address` hasta que la sección se ha evaluado
(`patches/mkxpz-binding-mri.cpp.patch`).

## Cuánto tarda esto en arrancar

Sorpresa agradable, y va contra lo que se esperaba después de Vanguard (102 s
hasta el título) y Reborn (85 s de scripts): **estos cuatro juegos cargan en
diez segundos**.

| | motor listo | scripts pasan por NXFuente | primer `[monton]`, ya jugando |
|---|---|---|---|
| Ópalo | 8,0 s | 8,4 s | (no llega) |
| Z | 4,6 s | 5,5 s | 9,1 s |
| Iberia | 5,0 s | 5,8 s | 9,5 s |
| Titán | 5,2 s | 6,1 s | 9,7 s |

Son 118.000–160.000 líneas en 167–235 secciones: la mitad que Reborn y en
secciones mucho más pequeñas. **Las esperas de 170–190 s de estas pruebas
sobran**: quien venga detrás puede lanzar con `-Espera 30`.

## Lo que se pierde, dicho para que nadie lo busque

- La pantalla de «configura los controles» queda decorativa: no hay teclado que
  remapear.
- El turbo con ALT y las teclas de depuración (F7, F8, K) no se pueden pulsar.
- La tarjeta de entrenador de Ópalo se hojea con Q W E R T Y U I: esas páginas
  se quedan sin atajo.
- El exportador de mapas a PNG de KleinStudio (Control+P) deja de funcionar,
  porque se le devuelven a Ruby los `getbyte`/`setbyte`/`bytesize` de verdad.
- `RtlMoveMemory` no copia nada —los `__id__` de 3.1 no son punteros—, así que
  los bitmaps que el juego construye escribiendo memoria a mano salen a ceros.
  Se ve en la introducción de Titán: hay un sprite hecho de ruido junto a la
  profesora (`docs/capturas/pokemon-titan-intro-profesora.png`).
- `KleinBitmap.dll` no está: en Iberia y Titán el registro dice
  `[win32api] kleinbitmap!version llamado`, así que el juego pregunta por ella
  de verdad. Los efectos de bitmap (paleta, desplazamiento, `to_retro`,
  contorno) salen sin aplicar.

## Cómo se conducen estos cuatro, para el que venga detrás

- La rejilla del nombre es la de Essentials clásico: **Z** mete la letra bajo el
  cursor, **C** salta el cursor a `FIN`, y otra **Z** confirma. Es el mismo
  patrón Z-C-Z de Vanguard. La leyenda que sale en pantalla («TECLA X =
  BORRAR, TECLA Z = FIN») es la del teclado del PC y no la del mando: no hay que
  hacerle caso.
- `USEKEYBOARDTEXTENTRY` sale a `false` sola; en el registro tiene que salir
  `[teclado] USEKEYBOARDTEXTENTRY = false`.
- Z pregunta el idioma **antes** del título, con `English` arriba y `Spanish`
  debajo: una ABAJO y una Z.
- Ópalo, Iberia y Titán van directos al título.
- **`-Espera 40` basta**, y desde esta sesión el emulador se lanza en ventana y
  en silencio: estas pruebas corren en la misma máquina en la que hay alguien
  trabajando, y a pantalla completa la dejan inservible durante los diez o
  quince minutos que dura un guion.

Con eso, Iberia llegó a `17 Casa` con el jugador andando y al menú de pausa
(tecla X, `Input::B`) sin una sola excepción: es el punto más lejano de la
familia hasta ahora.

---

## El décimo: `Kernel#proc` (9 de septiembre de 2026, tarde)

Los nueve de arriba son los que se ven **al arrancar**. Éste no: aparece al
**cambiar de mapa**, o sea en cualquier momento de una partida, y por eso es el
más caro de los diez.

Lo destapó Titán al transferir al primer mapa jugable:

```
Section116:95:in `block in <main>': unexpected return (LocalJumpError)
	from Section040:54:in `block in trigger'      (PBEvent#trigger)
	from Section088:622:in `setMapChanged'
	from Section019:230:in `transfer_player'
```

La línea es `Events.onMapChange+=proc {|sender,e| return if !$PokemonGlobal ...`
de `PokemonRoaming.rb`. **En 1.8 `Kernel#proc` era un alias de `lambda`**, así
que ese `return` salía del proc y era legal; en 1.9 `proc` pasó a ser
`Proc.new`, el `return` intenta volver a un método que ya no existe —el bloque
se escribió en el nivel superior de una sección— y sale `LocalJumpError`. El
cargador de Essentials **no** lo rescata: el hilo RGSS muere, la pantalla se
queda negra a 0 FPS y no hay `errorlog.txt`.

Contados con las llaves emparejadas, no con un grep de tres líneas:

| Juego | `proc {...}` | con `return` dentro | ficheros |
|---|---|---|---|
| Ópalo | 845 | **74** | 10 |
| Z | 1.341 | **74** | 10 |
| Iberia | 703 | **72** | 9 |
| Titán | 674 | **72** | 9 |
| Uranium | 669 | **78** | 10 |
| Añil (v21.1, Ruby 3.1) | 2.060 | **0** | 0 |

Los mismos nueve o diez ficheros en los cinco: `ItemHandlers::UseInField`, los MO
de campo, el Pokémon errante, el Poké Radar, el Chatter, los Pokémon oscuros. Y
**cero en Añil**, que es la versión moderna de Essentials: eso es lo que
demuestra que es una diferencia de 1.8 y no una manía de estos juegos.

El arreglo **no convierte el bloque en lambda**: no se puede sin `define_method`,
y eso le cambia el `self`, que es justo lo que estos manejadores necesitan
conservar. Lo que se hace es envolverlo en otro `Proc` que llama al de dentro y
recoge el `LocalJumpError`, devolviendo su `exit_value` —el valor que el juego
quería devolver—. Desde el que llama el efecto es el de 1.8, y además se conserva
la tolerancia de arity de los `Proc`, que es *más* permisiva que la del `lambda`
de 1.8 y por tanto no puede romper nada que antes funcionara. El `arity` se
repone a mano sobre el envoltorio porque `PBEvent#trigger` lo mira
(`if callback.arity>2`).

## Leer la introducción antes de encender

`leer-mapa.rb` abre un `MapNNN.rxdata` con el Ruby 3.1 del PC y escupe los
comandos de evento: cuántas cajas de diálogo hay, qué menús de elección salen, en
qué orden están sus opciones y a qué mapa transfiere al final. `Marshal` no pasa
por `const_missing`, así que las nueve clases de `RPG::` que aparecen en un mapa
van declaradas a mano, y `Table`/`Color`/`Tone` con su `_load`.

Esto cambia cómo se conducen estos juegos. Antes se pulsaba a ciegas y cada
desincronización costaba una vuelta de emulador entera; ahora se sabe de
antemano:

- **Iberia y Titán**: todas las elecciones tienen en el índice 0 lo que interesa
  (Chico, Sí, Modo Normal, no randomizar, dificultad Normal, Iniciales
  Oficiales), así que un chorro de `Z` con una `C` intercalada las cruza solo. La
  `C` no hace nada sobre una caja de texto y es la que salta a `FIN` en la
  rejilla, con lo que da igual en qué bloque caiga la rejilla.
- **Z**: al revés. En `168 Auxiliary Intro` el `¿ENTENDIDO?` tiene `["No","Sí"]`
  **en ese orden** y `No` salta a la etiqueta y vuelve a empezar el aviso; el
  `¿Saltar la intro del juego?` de detrás, igual. Ahí hay que **bajar**, y con
  **parejas `ABAJO Z`**: un bloque de cuatro teclas se sincroniza con las tres
  cajas del aviso y se queda dando vueltas para siempre (pasó, doce bloques
  enteros).
- Las cajas largas necesitan **dos** pulsaciones —una completa el texto, la otra
  pasa—, así que hay que contar el doble de las cajas que diga el volcado.

## El menú de pausa, por juego

Con el jugador recién salido de la introducción (sin Pokédex ni equipo):

| Juego | Menú | Para «Guardar» |
|---|---|---|
| Iberia, Titán | `Mochila / <nombre> / Guardar / Opciones / Controles / Salir` | X, **dos ABAJO**, Z |
| Ópalo | `Logros / …` por delante (no se ha llegado) | — |
| Z | menú propio con iconos: `Bag / Craft / Feats / Save / Options` | X, **tres ABAJO**, Z |

Y después, `¿Quieres guardar la partida?` con `Sí` arriba (Z) y el aviso de
guardado (Z). La partida sale como `Game.rxdata` en la carpeta del juego de la
tarjeta.

## Dónde está cada uno al cerrar esta sesión

| Juego | Estado | Partida |
|---|---|---|
| Z | **jugable** | `Game.rxdata` 85.701 B, mapa 66 `Carriage` |
| Iberia | **jugable** | `Game.rxdata` 65.609 B, mapa 17 `Casa` |
| Titán | **jugable** | `Game.rxdata` 56.737 B, mapa 12 `Casa` |
| Ópalo | `no-arranca` | el que se muere es Ryujinx: `0xC0000005` (ver `pokemon-opalo.md`) |

---

## El undécimo: la pantalla lógica se quedaba en 640×480 (9 de septiembre de 2026, noche)

Randy, con Ópalo en su Switch de verdad y con el emulador delante: «no está nada
centrado el viewport, se ve super curseado». Le pasaba en la consola **y** en
Ryujinx, y en los cuatro juegos de esta familia y en Uranium.

### La medida

Ryujinx en ventana, con 1600×895 de área de cliente para la consola. Añil, que
es el patrón de «bien centrado», ocupa **1200×895 empezando en x = 200**: el 4:3
centrado que se espera. Pokémon Z, en la misma ventana, ocupaba **960×720
pegado a la esquina de arriba a la izquierda** de ese mismo rectángulo
(`pokemon-z-viewport-antes-titulo.png` frente a
`pokemon-anil-viewport-patron-titulo.png`).

960/1200 = 720/895 = **0,8 justo**, y 0,8 es 512/640 y 384/480. O sea: la
pantalla lógica del motor era **640×480** y Essentials clásico dibujaba sus
**512×384** en un rincón de ella. El motor centraba y escalaba perfectamente…
los 640×480.

Con una sonda de preload (`runtime/diagnostico/nx-sonda-viewport.rb`), en el
emulador:

```
[viewport] update 1: motor 640x480 | juego 512x384 | haveresizescreen true |
           factor 1.0 offset 0,0 | screensize 1 border 0 | Graphics.fullscreen true
[viewport] arity de pbSetResizeFactor = 1   (el de Sprite_Resizer es -1)
[viewport] la sonda pidio 512x384: motor 512x384
```

Tres cosas en tres líneas: (1) la pantalla del motor y la que el juego cree que
tiene **no son la misma**; (2) el juego **sabe** que puede redimensionar
—`haveresizescreen` es `true`, o sea que el `alias oldresizescreen resize_screen`
funcionó— y no lo pide nunca: envolviendo `Graphics.resize_screen` para que
registre cada llamada, no salió ni una; y (3) el motor sí sabe hacerlo: la sonda
lo pidió a mano y la imagen salió centrada y llenando la pantalla.

### La causa, con la línea

`Sprite_Resizer` trae `pbSetResizeFactor`, que acaba en `Graphics.resize_screen`.
Pero **doce secciones más adelante**, `PSystem_System` (Ópalo e Iberia/Titán
`PokemonSystem`, Z `PSystem_System`) hace:

```ruby
if !Kernel.respond_to?("pbSetResizeFactor")
  def pbSetResizeFactor(dummy); end
```

`Kernel.respond_to?` sobre un método de nivel superior contesta **false** —los
`def` del nivel superior son privados en `Object`, y `respond_to?` no cuenta los
privados—, así que el sello vacío **pisa al de verdad**. Por eso `arity` es 1 y
no −1. No es cosa de 1.8 ni de la consola: en el PC pasa lo mismo, sólo que allí
la ventana es de 640×480 y el hueco negro se confunde con el marco.

Se cierra el círculo con el registro de la consola de Randy: en
`mkxp-ruby.log` de Ópalo sale `[win32api] user32!GetSystemMetrics pedido por el
script` y **nunca** `llamado`. `GetSystemMetrics` sólo se llama desde
`Win32API.fillScreen` y `Win32API.restoreScreen`, que cuelgan de
`pbConfigureFullScreen`/`pbConfigureWindowedScreen`, que cuelgan del
`pbSetResizeFactor` que está sellado.

### El arreglo

`NX18Tarde.pantalla`, en `runtime/lib/nx-ruby18.rb`, entre sección y sección
—o sea en cuanto `Sprite_Resizer` se ha evaluado y mucho antes del primer
fotograma—: se le pregunta al juego de qué tamaño es su pantalla
(`Graphics.width`/`height`, que a esas alturas ya son su `DEFAULTSCREENWIDTH`) y
se le da esa pantalla con el `resize_screen` del motor, guardado antes de que el
juego lo tape.

```
[1.8] pantalla logica 640x480 -> 512x384: Essentials dibuja 512x384 y su
      pbSetResizeFactor lo pisa un `def pbSetResizeFactor(dummy); end`,
      asi que nunca lo pide
```

Y **no** se pone `defScreenW/H: 512x384` en `mkxp.base.json`: allí valdría para
estos cinco y rompería cualquier juego de RPG Maker XP que dibuje de verdad a
640×480. Aquí se pregunta, y si el juego no reescribe `Graphics.width` los dos
números coinciden y esto no hace nada.

Los cinco lo dicen igual en su registro y los cuatro que arrancan en el emulador
salen centrados y llenando la pantalla:
`pokemon-z-viewport-despues-{titulo,mapa}.png`,
`pokemon-iberia-viewport-despues-titulo.png`,
`pokemon-titan-viewport-despues-titulo.png` y
`pokemon-uranium-viewport-despues-titulo.png`. Los cinco declaran
`DEFAULTSCREENWIDTH = 512` / `DEFAULTSCREENHEIGHT = 384` en su `Settings`, y los
cinco traen el sello de `pbSetResizeFactor`.

Y de paso queda dicho por qué Añil nunca se vio así: su perfil trae
`defScreenW/H` a 512×384 (y Vanguard y Reborn los traen en su propio
`mkxp.json`), así que su pantalla lógica ya nacía del tamaño correcto. Los
cuatro de Ruby 1.8 y Uranium no los traen, y el valor por omisión de mkxp-z para
RGSS1 es 640×480 (`src/config.cpp`).

---

## 20 de octubre de 2026 — recorrido de los cinco con `guion.ps1`

Partida nueva que empieza en la casa del jugador (el guion cambia el mapa de
inicio de `Data/System` por `MetadataHome`) y recorrido del menú de pausa REAL
con `elige`: equipo y resumen, Pokédex, mochila, ficha, opciones, controles,
guardar, PC, tienda y dos combates (huir; luchar hasta ganar). Con la sonda de
excepciones de `nx-guion.rb` apuntando todo lo que se lanza aunque se rescate.

| Juego | Resultado |
|---|---|
| Iberia | Completo, sin cierres (ver `pokemon-iberia.md`). Salieron y se arreglaron `Hash#index` (Controles), `Audio.bgm_position` y las constantes con tildes (`PBTrainers::Sofía1`) |
| Titán | Completo desde la casa del mapa 12. En exteriores con agua animada **Ryujinx se cae** (ver `pokemon-titan.md`) |
| Z | Completo, con su menú propio (`DP_PauseMenu`): Craft, Feats, opciones, guardar (167.405 bytes), PC, combates |
| Ópalo | **No arranca en Ryujinx** desde septiembre; en la consola sí (`pokemon-opalo.md`) |
| Uranium | Ahora arranca en Ryujinx (en septiembre no). Pasa la pantalla de idioma y llega al mapa; el recorrido quedó a medias (el guion daba Pikachu, que Uranium no tiene, y la máquina se quedó sin memoria) |

### El fallo de Ryujinx, con nombre

`break` (y `raise`/`rescue`) que sale de un bloque llamado desde C es un
`longjmp`. ARMeilleure traduce cada llamada del juego a una llamada nativa del
PC, y un `longjmp` del juego deja esos marcos en la pila del PC: unos **407**
dentro de la misma llamada la agotan y `Ryujinx.exe` muere con `0xc0000005`.
Reproducido sin datos del juego (tres líneas en `pokemon-titan.md`). Explica a
la vez Ópalo (la carga de scripts es una sola llamada, y la sección 212 hace
cientos), el pueblo de Titán y lo que se vio de Uranium en septiembre.

### Lo que cambió en `nx-ruby18.rb`

- `HandlerHash#fromSymbol` pregunta con `const_defined?` en vez de rescatar un
  `NameError`: unas 350 excepciones menos en cada arranque (en la consola cada
  una cuesta), y en Ryujinx es lo que deja arrancar a Uranium.
- `FontInstaller.install` se tapa en el momento en que el juego lo define: en
  Uranium se definía y se llamaba en la misma sección y los avisos salían igual.
- `SpriteWrapper#width/height` preguntan a su `@sprite`: mkxp-z añade
  `Sprite#width`, el RGSS de Enterbrain no, y el ratón de Uranium se lo
  preguntaba al Sprite nativo vacío de los paneles de la pantalla de carga
  (`MKXPError: No instance data for variable`).

### Lo que cambió en la sonda

`nx-guion.rb`: `mapa`, `elige` (listas de Essentials y `DP_PauseMenu`), el
recuento de excepciones cada 50, la foto con el `snap_to_bitmap` del motor, y
el corte del lazo cuando un juego hace `alias` de `Input.update` después de la
sonda (Z: `update_KGC_ScreenCapture`). `guion.ps1 -Visible` muestra la ventana
sin activarla.
