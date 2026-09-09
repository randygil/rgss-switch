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
