# rgss-switch — un motor de RPG Maker XP para Nintendo Switch

**mkxp-z 2.4.2 + CRuby 3.1.7 compilados nativos para Horizon OS**: un solo
binario que corre cualquier juego de RPG Maker XP / Pokémon Essentials que ya
funcione sobre mkxp-z en el PC. Hace falta una Switch con CFW (Atmosphère), tu
propia copia del juego para PC y la entrega de este proyecto; nada más.
**¿Sólo quieres jugar?** Está todo en [`GUIA.md`](GUIA.md), que es la guía del
jugador y no repite lo de aquí abajo.

> **Aquí no hay ningún juego, ni lo habrá.** Este repositorio contiene el motor
> portado y las herramientas para empaquetar *tu* copia. Los juegos son de sus
> autores y Pokémon es de Nintendo.

El primer juego que corrió sobre esto fue Pokémon Añil 4.0, y de aquel porteo
sale todo lo demás: su bitácora de ingeniería —setenta y un problemas y su
arreglo— está entera en [`docs/bitacora-anil.md`](docs/bitacora-anil.md), y este
README la cita por número cuando hace falta.

---

## 1. Qué hay en este repositorio

```
mkxp-z-nx/          el motor: 21 fuentes en nx/ (registro, excepciones, hilos,
                    tuberías, memoria, texturas, la pantalla de aviso y la de
                    carga) y el Makefile que sustituye a meson
patches/            75 parches contra CRuby 3.1.7 y mkxp-z 2.4.2 —30 de mkxp-z
                    con su ORDEN.txt, 8 de Ruby y los 37 de syntax-transform,
                    que todavía no están aplicados—, más nxcompat.c y las
                    cabeceras shim: src/ no entra en git, así que esto es el
                    único ejemplar del trabajo
runtime/            lo que va a la tarjeta y es fuente: mkxp.base.json (la capa
                    1 de mkxp.json), lib/ con los shims de Ruby que van siempre,
                    shims/ con la biblioteca compartida y su catalogo.json,
                    lib-stdlib.txt con el recorte de la biblioteca estándar, y
                    diagnostico/ con las sondas de medición
juegos/            un perfil por juego (perfil.json + lib/*.rb + icono.jpg),
                    más generico/, que es donde cae lo que nadie reconoce
Empaquetar.ps1      el empaquetador: detecta el juego, compone su mkxp.json por
 + Empaquetar.cmd   capas, mete los recursos en datos.zip y fabrica su .nro y su
 + empaquetar.sh    .nsp. El .cmd es el doble clic; el .sh, el envoltorio POSIX
construir.sh        de fuentes a release/rgss-switch-<VERSION>/
hello-ruby-nx/      banco de pruebas del intérprete, aislado de SDL y del juego
docs/               el censo de juegos, las capturas y los registros que se citan
nsp/ tools/         el NPDM y el icono del motor; hacbrewpack, nacptool, npdmtool
```

Herramientas de desarrollo, todas por slug:

| Guión | Qué hace |
|---|---|
| `iterate.sh <slug> [seg] [--sin-compilar]` | compila, despliega en la SD virtual de Ryujinx y lanza |
| `jugar.ps1 -Juego <slug>` | lanza y conduce con el teclado (A=Z, B=X, X=C, Y=V, cruceta=flechas) |
| `captura.ps1 -Juego <slug>` | captura la ventana a `docs/capturas/<slug>-*` |
| `desplegar.sh` | copia lo compilado a una instalación ya existente |
| `recoger.ps1` | busca la SD de verdad y trae los cuatro registros, las partidas y los informes de Atmosphère |
| `subir-ftp.py` | lo mismo por FTP, con la consola encendida |
| `triaje.py` / `resolver-pila.py` | leen un registro o un volcado y dicen dónde estaba el hilo (`TRIAJE.md`, bitácora §5.65) |
| `dump-scripts.py`, `dump-rgssad.py`, `leer-mapa.rb`, `comprobar-nro.py`, `comprobar-ruby18.rb`, `reconstruir-src.py` | extraer scripts, abrir un `.rgssad` cifrado, leer un `MapNNN.rxdata` con el Ruby del PC —cuántas cajas y qué menús tiene una introducción, antes de conducirla a ciegas—, releer el NACP de un `.nro`, probar la capa de Ruby 1.8 en el PC, rehacer `src/` desde `patches/` |

### Lo que tienes que poner tú

**Si compilas el motor:**

| Qué | De dónde |
|---|---|
| **devkitPro** con devkitA64, libnx y los portlibs | [devkitpro.org](https://devkitpro.org/wiki/Getting_Started) |
| **CRuby 3.1.7** y **mkxp-z 2.4.2** | Tarballs upstream, a `src/`. Los parches van contra esas versiones exactas |
| **`prod.keys`** | Sólo para el NSP, y sólo salen de tu consola con Lockpick_RCM |

**Si sólo juegas:** tu copia del juego para PC, y ya. El empaquetador va en la
entrega con todo lo que necesita.

`C:/devkitPro` sigue siendo una ruta fija —es la instalación, no el
repositorio—, pero la raíz del árbol ya no: sale de dónde está el `Makefile`
(`$(CURDIR)/..` pasado por `cygpath -m`). La forma de cada ruta importa en un
cross-compile de devkitPro bajo Windows, y por qué está en la bitácora §5.15 y
§5.18.

---

## 2. Cómo funciona

El detalle vive en [`CONVENCIONES.md`](CONVENCIONES.md), que es el contrato
entre el motor, el empaquetador, los shims y los perfiles. Aquí van las cinco
ideas.

### (a) Un binario, una carpeta por juego

De compilar sale **un** `rgss-switch.nro`. El `.nro` que se instala para cada
juego es ese mismo binario con la sección ASET del final rehecha: el icono y el
NACP del juego. El cuerpo no se toca. Cada juego vive en
`SD:/switch/<slug>/`, con su `<slug>.nro`, su `mkxp.json` compuesto, su `lib/`
y sus recursos —dentro de `datos.zip`, o sueltos si se prefiere—, y ahí mismo
se guardan las partidas y los cuatro registros. El slug sale del `Title=` del
`.ini` (CONVENCIONES §1).

### (b) Cómo encuentra el motor su juego

Ninguna ruta a un juego concreto se escribe en el código del motor. Hasta hoy sí
se escribía: `sdmc:/switch/pokemon-anil` aparecía en seis ficheros y dos rutas
más de reserva, y con un motor genérico cada una de esas copias es un sitio
donde el binario escribe en la carpeta de otro juego. Ahora hay una sola
respuesta, `nx/nx_juego.c`, y el orden es:

1. el directorio de `argv[0]`, si tiene `mkxp.json` (lanzado como `.nro` desde
   hbmenu);
2. la ruta de `romfs:/juego.txt`, que es como lo dice un NSP, porque una
   aplicación instalada **no tiene `argv`**;
3. si no hay ninguna, la pantalla de aviso dice qué se probó y con qué valor, y
   no adivina.

El registro de arranque se acumula en memoria —32 KB, sin tocar el montón—
porque los 45 constructores estáticos escriben antes de que `main()` sepa dónde
está el juego, y se vuelca de golpe en cuanto la carpeta aparece.

**Y el motor lleva un romfs vacío a propósito** (commit `6128ea3`). Ryujinx
lanza un `.nro` con `argc = 0`, así que la vía (1) no contesta y hay que ir a
(2); pero `romfsInit` acaba en `fsOpenDataStorageByCurrentProcess` porque libnx
cree que somos una aplicación instalada, y en el emulador eso es una excepción
sin recoger que mata el proceso antes de escribir una línea de registro. No hay
forma de distinguirlo desde dentro, así que se quita el motivo: se compila
siempre con `--romfsdir`. Son unos cientos de bytes en 17 MB.

### (c) `mkxp.json` por capas

El empaquetador lo compone; nadie lo copia. Cuatro capas, la de abajo pisa a la
de arriba (CONVENCIONES §5):

1. `runtime/mkxp.base.json` — lo que la Switch necesita siempre: pantalla
   completa, aspecto fijo, escalado suave, `pathCache`, `rgssVersion: 1`,
   `rubyLoadpath: ["lib"]`.
2. Del `mkxp.json` **del juego**, sólo una **lista blanca**: `windowTitle`,
   `defScreenW/H`, `SESourceCount`, `BGMTrackCount`, `subImageFix`,
   `enableBlitting`, `bindingNames`, `inputRepeatStart/Delay`, `patches`… Lo de
   resolución de ventana, vsync y rutas del PC se ignora. Esos ficheros son
   JSON5 —comentarios y comas finales— y hay que limpiarlos con un analizador
   que sepa cuándo está dentro de una cadena: un `http://` en un literal sería
   un comentario para cualquier expresión regular.
3. La sección `mkxp` del perfil.
4. El `preloadScript` compuesto: shims genéricos de `runtime/lib/` → shims del
   perfil → el `preload.rb` del juego, si trae.

### (d) El perfil

Un perfil (`juegos/<slug>/perfil.json`) es **lo único que este proyecto sabe de
un juego concreto**: cómo reconocerlo, cómo se llama en la tarjeta, qué carpetas
suyas no pueden ir dentro del contenedor y qué claves de `mkxp.json` necesita.
El esquema, clave a clave, está en [`juegos/README.md`](juegos/README.md).

Lo que **no** decide: el motor no lee los perfiles, sólo el empaquetador. Y no
hay ninguna ruta ni ningún nombre de juego en el binario. Un juego sin perfil se
empaqueta igual, con el genérico, y el slug que salga de su `Title=`.

La clave está en `sueltos`. Va al contenedor lo que el motor lee por PhysFS
(`Data/`, `Graphics/`, `Audio/`, `Fonts/`, `Movies/`); va suelto lo que el juego
lee con `Dir` o `File.read`, porque **Ruby no ve dentro de PhysFS**:
`Data/Scripts/` de los cargadores de Essentials v20+, el `Scripts/` de Reborn,
`Plugins/`, `patch/`, `stdlib/`, `gems/`.

### (e) Las tres familias, y la capa de Ruby 1.8

Este motor lleva CRuby 3.1.7. El empaquetador mira las DLL y las cadenas del
ejecutable del juego y lo clasifica:

| Familia | Qué traía el juego | Qué significa para el motor |
|---|---|---|
| `ruby31` | mkxp-z con Ruby 3.x (`x64-msvcrt-ruby310.dll`) | el caso nativo: el mismo intérprete |
| `ruby18` | mkxp-z con Ruby 1.8.7 embebido (`/lib/ruby/1.8` dentro del `.exe`) | hace falta `lib/nx-ruby18.rb`, que se añade **por familia**, no por juego |
| `rgss1` | RPG Maker XP original, `RGSS10xE.dll` | lo mismo, y además su `Audio` puede ser una DLL nativa |

Con `ruby18` o `rgss1` **avisa y empaqueta igual**: saber si arranca cuesta una
prueba, y suponerlo no cuesta nada y no sirve de nada.

`runtime/lib/nx-ruby18.rb` es la capa de compatibilidad, y su forma sale de lo
que midió el censo, no de una impresión:

- **La sintaxis de 1.8 son 25–28 líneas por juego** en 3–4 ficheros, sobre
  corpus de 118.000 a 160.000 líneas: entre el 0,002 % y el 0,02 % del fuente.
  Las arregla `NXFuente.transforma`, un gancho que el motor llama antes de
  evaluar cada sección de `Scripts.rxdata`, **guiado por el compilador**: se
  compila con `RubyVM::InstructionSequence.compile` —que es lo que de verdad
  hace mkxp-z— y si compila se devuelve el fuente sin tocar un byte; sólo cuando
  el compilador señala una línea concreta se toca *esa* línea, y se recompila.
  Un `gsub` a ciegas sobre 136.000 líneas encuentra `when` dentro de cadenas,
  `?:` ternarios y `break` de bloques, que son legítimos, y romper uno cuesta un
  fallo en mitad de una batalla en vez de un error al cargar.
  Cuatro reglas: `when X:` → `when X then`, `break` en cuerpo de método →
  `return`, `retry` fuera de `rescue` → `redo`, y regex con `\xNN` → `/n`.
- **El muro es `Win32API`**: 134–166 referencias en 20–29 ficheros, de las que
  **12–14 son asignaciones de nivel superior** que se evalúan al cargar el
  script y revientan con `NameError` en la sección 21 de 168, antes de que se
  dibuje un píxel. En Horizon no hay ninguna DLL de Windows que cargar. Así que
  hay un `Win32API` postizo, y es una **clase** de verdad porque los juegos la
  reabren (Ópalo trae un `0005_Win32API.rb` que le añade métodos). Casi todo
  devuelve el neutro del tipo declarado; **con semántica donde importa**:
  `Get/WritePrivateProfileString` contra el `Game.ini` de verdad,
  `GetSystemPowerStatus` como una máquina enchufada, `GetWindowRect` con la
  resolución real, `GetUserName` → `"Switch"`, y los sockets de `ws2_32`
  contestando `-1` y `WSAENETDOWN` —devolver 0 sería un descriptor **válido** y
  el juego se quedaría esperando—.

Portar Ruby 1.8.7 pagaría `Win32API` igual y además el intérprete. Por eso se
transforma el fuente. `comprobar-ruby18.rb` prueba la capa entera en el PC con
el Ruby 3.1.4 y su tabla cuadra con el censo línea por línea; los 1.077 scripts
de los tres juegos de Ruby 3.1 salen intactos, que es el otro criterio.

---

## 3. Estado por juego

Ocho juegos medidos sin encenderlos: [`docs/censo-juegos.md`](docs/censo-juegos.md)
tiene las cifras, cómo se obtuvieron y el veredicto razonado de cada uno.

| Juego | Slug | Familia | Essentials | Estado | Qué falta |
|---|---|---|---|---|---|
| Pokémon Añil 4.0 | `pokemon-anil` | ruby31 | v21.1 | **jugable** | nada; es el patrón |
| Project Vanguard 4.0.3 | `pokemon-vanguard` | ruby31 | v20.1 | **jugable** | título, introducción, nombre, primer mapa, menú y partida guardada en el emulador (`1e35fed`). El combate no se probó |
| Pokémon Reborn 19.5.0 | `pokemon-reborn` | ruby31 | v19 (base) | **jugable** | hasta guardar partida en Lower Peridot Ward. Lleva postizos de `discord`, `poke-api-v2`, `rubygems` y de seis métodos que su mkxp-z propio añadía (`1e35fed`). Los mods en `patch/` sin probar |
| Pokémon Ópalo 2.11 | `pokemon-opalo` | ruby18 | clásico (~v16) | **jugable** | probado en la **consola de verdad** (2026-09-09): introducción, estadio, `2 Pueblo Brisa`, centro Pokémon y `6 Ruta 1` en siete minutos, sin una excepción, arrancado por `argv[0]` desde hbmenu. En Ryujinx sigue muriendo **el proceso del emulador** con `0xC0000005` en el `Mesón Batalla`: era el anfitrión. El combate y ese mesón, sin probar en hardware |
| Pokémon Z 2.13 | `pokemon-z` | ruby18 | clásico (~v16) | **jugable** | introducción, mapa `66 Carriage`, menú propio (`Bag/Craft/Feats/Save`) y partida guardada. La trampa es el `¿ENTENDIDO?` del mapa 168, con `No` primero y volviendo a empezar. El combate no se probó |
| Pokémon Iberia 2.10 | `pokemon-iberia` | ruby18 | clásico (v15/v16) | **jugable** | introducción, `17 Casa`, cuatro pasos, menú y partida guardada. El agua y las cascadas siguen sin el efecto de `KleinBitmap.dll`. El combate no se probó |
| Pokémon Titán 2.10 | `pokemon-titan` | ruby18 | clásico (v15/v16) | **jugable** | introducción, `12 Casa`, menú y partida guardada, después de arreglar `Kernel#proc` (en 1.8 era `lambda`: `return` dentro de un `proc` mataba el cambio de mapa). Sigue el sprite de ruido de `RtlMoveMemory` |
| Pokémon Uranium 1.3.2 | `pokemon-uranium` | rgss1 | clásico (v16/v17) | `arranca` | idioma, menú, introducción entera y el nombre; en el fundido al primer mapa muere el proceso **de Ryujinx** con `0xC0000005` en `0x1250ef`, a 780 bytes del de Ópalo: el mismo fallo del anfitrión. Su `Audio` de FmodEx ya está reescrita sobre la de mkxp-z |

El estado sale de `juegos/<slug>/perfil.json` y lo cambia quien lo prueba, con
la fecha en `notas`.

### Cómo se prueba un juego

Ryujinx (`C:\Games\publish\Ryujinx.exe`) es un sustituto validado del hardware
para iterar: en H2 dio un resultado **idéntico línea por línea** al de la
consola real. Su tarjeta virtual es `%APPDATA%\Ryujinx\sdcard\`, así que el
juego se deja en `…\sdcard\switch\<slug>\` y se lanza con
`Ryujinx.exe <ruta al .nro>`: en ventana, con el volumen del emulador a cero y
con las capturas recortadas a su área de cliente, que es como lo dejan
`iterate.sh` y `jugar.ps1` desde `47a4f8c`. **Sólo puede correr un Ryujinx a la
vez.** Y lanza los `.nro` sin `argv`: en el emulador el juego se encuentra
siempre por `romfs:/juego.txt`, nunca por la vía de hbmenu.

```sh
./iterate.sh <slug> 60        # compila, despliega y lanza sesenta segundos
```

`iterate.sh` ya no sincroniza `mkxp.json` ni `lib/` desde `runtime/`: eso lo
compone el empaquetador por capas, y copiarlo a mano produce una instalación que
no se parece a la del jugador, que es justo lo que se pretende probar. Para
conducir sin mando, `jugar.ps1 -Juego <slug>`.

Los cuatro registros están todos en la carpeta del juego, y esto es lo que dice
cada uno: **`mkxp-boot.log`** es el arranque del motor —qué versión, qué carpeta
encontró y por qué vía, si montó el contenedor, y `[boot] 11 SharedState OK` es
la línea que significa que Ruby va a empezar—; **`mkxp-ruby.log`** trae lo que
el juego imprimió y los errores de Ruby, y es donde salen los shims cargados y
los métodos de 1.8 que falten; **`errorlog.txt`** es el error que el juego
escribió él mismo, y si hay algo ahí el problema es de Essentials, no del motor;
**`mkxp-debug.log`** es lo que mkxp-z tenga que decir, incluido cualquier fallo
de la transformación de fuente. En la consola, `recoger.ps1` los trae de la SD
junto con los informes de `atmosphere/crash_reports`, que cubren el hueco de
antes de que nuestro manejador de excepciones esté puesto.

---

## 4. Cómo añadir un juego

1. **Empaquétalo con el perfil genérico y mira qué reconoce.**
   ```powershell
   powershell -File Empaquetar.ps1 -Juego "C:\...\Mi Juego" -SoloDetectar
   ```
   Dice el slug, el título, el perfil que le toca, la familia de motor y qué
   carpetas encontró. Luego empaquétalo de verdad con `-Salida <ruta>`.
2. **Enciéndelo y lee los registros** (§3). Casi todo lo que hay que saber sale
   de la primera pantalla negra.
3. **Escribe `juegos/<slug>/perfil.json`** con el esquema de CONVENCIONES §6.
   Lo mínimo es `slug`, `nombre` y `detectar.titulo`. Si el juego lee alguna
   carpeta suya con `Dir` o `File.read`, ponla en `sueltos` o el juego no la
   verá; si hace `require` sobre ella, añádela también a `rubyLoadpath`.
4. **Mira primero el catálogo** (`runtime/shims/catalogo.json`): si el arreglo
   que necesitas ya está escrito, se enciende por su nombre en la clave `shims`
   del perfil y no se copia nada. Si no está y sirve para más de un juego, se
   escribe ahí. **Shims en `juegos/<slug>/lib/`** y su nombre en `preload`, sólo
   para lo que sea de ese juego y de ningún otro. Lo que valga para todos va a
   `runtime/lib/`; lo que valga para una familia entera se añade por familia,
   como `nx-ruby18.rb`. Un `icono.jpg` (JPEG 256×256 baseline) para el menú HOME es
   opcional.
5. **Rellena `estado` y `notas`** con lo que pasó y la fecha. Las notas son
   prosa: lo que hay que saber antes de volver a tocar ese juego.

---

## 5. Compilar y publicar

```sh
# Desde la shell MSYS2 de devkitPro, la primera vez en esta máquina:
./build-deps.sh && ./build-deps2.sh          # pixman, SDL_sound, iconv, uchardet
./build-ruby-switch.sh                       # configure + make de CRuby 3.1.7
./finalize-ruby.sh                           # dmyext.o e insertar las extensiones

# Y después, siempre:
./construir.sh                               # -> release/rgss-switch-<VERSION>/
```

`construir.sh` comprueba las herramientas, regenera los shaders, compila el
`.nro` y el `.elf`, monta la entrega con el layout de CONVENCIONES §7 y la
comprime. **Lo que ya no hace es el `.nsp`**: el NSP lleva el title id, el
nombre y el icono *del juego*, y el juego sólo lo tiene el jugador. Así que el
NSP —y el `.nro` con el icono de cada juego— los hace `Empaquetar.ps1` en la
máquina del jugador, con las herramientas de `tools/`. Aquí se entrega el motor
pelado. El juego no entra en la entrega, nunca.

Y **archiva los símbolos de esa compilación** en `release/simbolos/`. No es
opcional: sin el `.elf` de la compilación exacta, el `+0x7abd30` del volcado de
un jugador no es ningún nombre de función y hay que desensamblar el `.nro` en
crudo y adivinar, que es lo que pasó con la 1.0.0 (bitácora §5.65).
`publicar.sh` lo verifica antes de etiquetar; los pasos están en
[`PUBLICAR.md`](PUBLICAR.md).

Lo que cuesta la cadena de compilación no se cuenta aquí porque ya está contado.
En [`docs/bitacora-anil.md`](docs/bitacora-anil.md): §5.15 (`DEVKITPRO` tiene
que ir en forma Windows y no POSIX), §5.18 (`mkmf.rb` lanza sus conftest sin
traducir las rutas de MSYS2), §5.21 (mkxp-z no usa el Ruby oficial: 21 líneas
que lo cambian todo), §5.26 (por qué este port no usa meson), §5.11 y §5.19 (las
extensiones que no se enlazaban y el `Init_ext()` vacío que las anulaba), §5.28
(las cinco ramas de plataforma que le faltaban a mkxp-z) y §5.71 →
commit `3642d06` (`patches/` es el único ejemplar del trabajo, y hasta hoy no
restauraba `src/` entero).

---

## 6. De dónde viene

**El porteo de Añil (agosto–septiembre de 2026).** Pokémon Añil 4.0 no usa el
motor propietario de RPG Maker XP: viene ya empaquetado sobre mkxp-z, una
reimplementación libre del runtime RGSS en C++ sobre SDL2 y OpenGL. Portarlo no
era reescribir el juego, era recompilar un motor de código abierto para
aarch64-Horizon; y el bloqueo estaba en el intérprete, porque Horizon no tiene
`fork`, ni `dlopen`, ni `mmap`, ni `ucontext`. Salió: `libruby-static.a` de
44 MB, hasta donde se ha podido verificar **la primera compilación de CRuby para
homebrew de Nintendo Switch**, y detrás de eso 71 problemas más —el arranque que
tardaba 56 segundos preguntando 22.318 veces algo que ya sabía, la música que
volvía muda, la textura sin memoria que mataba el proceso sin decir nada, los
22.148 ficheros que pasaron a ser uno—. Todo eso está en
[`docs/bitacora-anil.md`](docs/bitacora-anil.md), sin editar. Se publicó hasta
la `v1.1.1`.

**El 9 de septiembre de 2026: la generalización, en un día.** Con Pokémon Ópalo
delante se vio que el empaquetador exigía ficheros de Añil, y tirando de ahí
salió todo lo que estaba pegado al primer juego. En orden, y cada cosa con el
fallo que la motivó:

- **El `Makefile` vivía en `C:/anilswitch`.** Cinco rutas fijas hacían que un
  clon en otro sitio compilara con las fuentes y las bibliotecas del clon de al
  lado, sin decir nada (`833101c`).
- **La carpeta del juego estaba escrita en siete ficheros.** Con un motor
  genérico, cada copia es un sitio donde el binario escribe en la carpeta de
  otro juego, o arranca el juego de al lado sin decirlo. Ahora hay una sola
  respuesta y el registro se acumula en memoria hasta que se sabe cuál es
  (`3cb6ef4`).
- **Pedir un romfs que no existe mata a Ryujinx.** El `.nro` nuevo no llegaba a
  escribir ni una línea: el emulador moría en `VirtualFileSystem.GetRomFs`. Se
  quita el motivo: el motor lleva un romfs vacío (`6128ea3`).
- **El nombre de la sección llega en binario**, tal cual sale de un
  `Scripts.rxdata` que escribió RPG Maker XP con Ruby 1.8, y construir una
  `Regexp` con él y casarla contra un mensaje con tilde daba
  `Encoding::CompatibilityError` que el propio `rescue` se tragaba (`4ab32e8`).
- **`runtime/` se parte en dos**: `mkxp.json` tenía dentro la resolución de la
  consola, el título de la ventana de Añil y los shims de sus plugins. Copiarle
  ese fichero a Ópalo le ponía `windowTitle` «Pokemon Añil 4.0» (`bd218ea`).
- **El empaquetador deja de ser el de Añil**: aprende a detectar el juego, a
  elegir su `.ini` —Iberia y Titán traen un `Editor.ini` que también dice
  `[Game]` y `Title=Pokemon Essentials`, con lo que los dos juegos se
  instalarían uno encima del otro— y a componer su `mkxp.json` por capas
  (`44f81e9`).
- **Nueve ficheros de JSON en vez de nueve empaquetadores** (`562845b`); la
  entrega pasa a ser el motor pelado y el NSP lo hace quien tiene el juego
  (`44ad679`); y las herramientas de desarrollo van por slug (`604427f`).
- **La versión del NACP son quince letras** y `VERSION.txt` traía dieciséis
  (`5c1492a`); el retardo de repetición de los botones estaba fijo en
  `input.cpp` aunque el juego lo declarase, y `romfs:/juego.txt` no se saltaba
  el BOM que le pone el Bloc de notas (`6457f1b`).

La regresión de cada paso se hizo con Añil desplegado en Ryujinx, y la última
llega a `[boot] 11`, corre setenta y siete segundos y enseña la pantalla de
título: `docs/capturas/pokemon-anil-regresion-motor-generico.png`. En los
registros no aparece ninguna ruta de `pokemon-anil` escrita por el código: sólo
la que sale del `juego.txt`.

**La tarde del mismo día: encender.** Con el motor genérico y el empaquetador
en su sitio, los siete juegos se empaquetaron y se lanzaron en Ryujinx, uno tras
otro, y esto es lo que sólo se ve corriendo:

- **Vanguard y Reborn llegan a guardar partida** (`1e35fed`). Por el camino: el
  ajuste `textinput` del teclado significa lo contrario en Essentials v20.1 que
  en v21.1, y el shim pedía justo la pantalla imposible (`4dcc689`);
  `File.file?` también tenía que ver dentro del contenedor (`48dab76`); y un
  `LoadError` de nivel superior no lo rescata el cargador de Essentials, así que
  cada `require` de Reborn necesitó su postizo.
- **La familia de Ruby 1.8 arranca, y nada de lo que el censo apuntaba fue lo
  que falló.** Nueve cosas aparecieron en ejecución (`0ec376f`):
  `StringInput#each_byte` y `#getbyte` —por ahí lee el juego *todos* sus datos—,
  `String#getbyte/setbyte/bytesize` que `Map - Klein.rb` aliasa a `[]` y
  destruye para todo lo posterior, `Object#id`, `String#each`, los dos lectores
  de cabecera Ogg, `ENV["TEMP"]` vacío, `LargePlane` sin `super`; y la cara:
  **los cuatro juegos reescriben el módulo `Input` entero sobre
  `GetAsyncKeyState`**, con lo que el juego arranca, dibuja y no responde a
  nada, sin un solo error en el registro. Emular `String#[]` con entero se
  probó y se deshizo: un envoltorio en Ruby se come el `$~` del que llama y se
  lleva por delante todo el texto del juego.
- **El gancho destapó un fallo del motor**: el recolector se llevaba el nombre
  de la sección entre crearlo y evaluarlo, porque `NXFuente.transforma` compila
  y por tanto reserva; Ópalo moría en una sección distinta cada vez.
  `rb_gc_register_address` (`0ec376f`).
- **El `.nro` del empaquetador no arrancaba en Ryujinx** y el de `elf2nro` sí,
  con el mismo cuerpo, el mismo icono y el mismo romfs. Cuatro campos del NACP
  distintos, y el que manda es `SaveDataOwnerId` (0x3078): en un homebrew el
  emulador saca de ahí el id del proceso, y un id del rango `05..` no es nada
  que conozca. En el `.nro` ese campo va a cero; el title id sólo vive en el
  NSP, que es donde `nacptool` lo pone (`962bf92`). `comprobar-nro.py` avisa
  desde entonces si no es cero, y con `--comparar` dice en qué campo difieren
  dos `.nro`.
- Y una regla nueva de la casa, que pidió Randy al ver las capturas: **el
  emulador va en ventana, con el volumen a cero, y ninguna captura puede
  contener el escritorio** (`47a4f8c`).

**Qué queda por hacer**, sin adornos:

- **El primer combate no se ha probado en ninguno de los seis jugables.** Todos
  llegan a guardar partida; el combate es el código más denso de Essentials y el
  siguiente hito, sobre todo en los cuatro de Ruby 1.8.
- **El viewport no estaba centrado, y lo vio Randy en su consola.** La pantalla
  lógica del motor se quedaba en 640×480 —el valor por omisión de mkxp-z para
  RGSS1— y Essentials clásico dibujaba sus 512×384 en la esquina de arriba a la
  izquierda: medido en el emulador, 960×720 de los 1200×895 que ocupa la
  consola, o sea 0,8 justo, que es 512/640. El juego trae `pbSetResizeFactor`
  para arreglarlo solo y **doce secciones más adelante se lo pisa él mismo** con
  un `def pbSetResizeFactor(dummy); end` protegido por un `Kernel.respond_to?`
  que contesta false. Lo pide ahora `NX18Tarde.pantalla`, en
  `runtime/lib/nx-ruby18.rb`, y vale para los cinco juegos de las dos familias
  viejas: docs/pruebas/familia-ruby18.md, «El undécimo».
- **Ópalo y Uranium mueren por el anfitrión, no por el motor**, y con Ópalo ya
  está demostrado: en la consola de Randy jugó hasta `6 Ruta 1` sin una
  excepción (`docs/pruebas/pokemon-opalo.md`). Los dos cierres
  mudos son el mismo: una violación de acceso `0xC0000005` dentro de
  `Ryujinx.exe` 1.3.3, a 780 bytes una de otra (visor de sucesos de Windows; los
  `Logs/` de Ryujinx no dicen nada), igual con `HostMappedUnsafe` que con
  `SoftwarePageTable`, y la pila del hilo RGSS aguanta 11.910 marcos, así que no
  es desbordamiento. En Ópalo el trabajo que la dispara crece con lo que cuesta
  cada construcción del `Mesón Batalla` (679 Pokémon al cargar); en Uranium es
  el fundido al primer mapa. **Lo que toca es la consola real**: si allí pasan,
  es un fallo del emulador; si mueren, habrá informe de Atmosphère, que es justo
  lo que aquí falta. Para Uranium quedan además `-Diagnostico` con
  `nx-metodos.rb` y leer el evento 2 del mapa 51 (`leer-mapa.rb` +
  `dump-rgssad.py`).
- **Lo que `Win32API` no puede devolver**: `KleinBitmap.dll` (agua y cascadas
  sin efecto en Iberia y Titán), `RtlMoveMemory` (un sprite hecho de ruido junto
  a la profesora de Titán, porque `__id__` ya no es un puntero), y los `.mid` de
  Iberia, Titán y Uranium, que suenan a nada sin un `midiSoundFont`.
- ~~La vía `argv[0]` no se ha probado en hardware.~~ **Probada**: el
  `mkxp-debug.log` de Ópalo en la consola de Randy abre con `argc = 1
  argv[0] = sdmc:/switch/pokemon-opalo/pokemon-opalo.nro` y el motor encuentra
  su juego por ahí. En Ryujinx esa vía no se ejercita nunca, porque el emulador
  lanza los `.nro` con `argc = 0`.
- **`KleinBitmap.dll`** (Ópalo, Iberia, Titán, Z, Uranium) y qué le pasa al mapa
  cuando esas llamadas devuelven 0. Sin verlo en pantalla no se puede decir más.
- **Los mods de Reborn en `patch/`**: la clave `patches` existe en el motor y la
  carpeta se monta, pero viene vacía y nadie ha probado un mod dentro.
- **La coroutine arm64** del hito H6, que sigue pendiente desde el porteo.

---

## 7. Mantener esto

El contrato entre el motor, el empaquetador, los shims y los perfiles está en
[`CONVENCIONES.md`](CONVENCIONES.md), y es lo primero que hay que leer: los
nombres, la carpeta de cada juego en la tarjeta, cómo encuentra el motor su
juego, cómo se compone `mkxp.json` por capas, qué es un perfil y las reglas de
la casa. Nada de lo que hay aquí se entiende sin eso.

Por dónde empezar, según lo que quieras hacer:

| Quiero… | Empieza por |
|---|---|
| Añadir un juego | §4 de aquí, `docs/censo-juegos.md` y `juegos/README.md` |
| Arreglar un juego que no arranca | sus cuatro registros (§3), `TRIAJE.md` y `triaje.py` |
| Tocar el motor | `mkxp-z-nx/nx/`, `patches/` y `docs/bitacora-anil.md` §5 |
| Publicar una versión | [`PUBLICAR.md`](PUBLICAR.md) |

Lo que conviene saber antes del primer commit:

- **`.gitignore` es una lista blanca.** El directorio de trabajo comparte sitio
  con gigabytes que no pueden publicarse —los recursos del juego, los scripts
  extraídos, los árboles de fuentes de terceros, los objetos compilados—, así
  que se ignora todo y sólo entra lo que se nombra. Un fichero nuevo no está en
  el commit hasta que aparece ahí: comprobar con `git status --short`.
- **`src/` no está en git, y `patches/` es el único ejemplar del trabajo.**
  `reconstruir-src.py` rehace el árbol entero desde los parches; si tocas
  `src/`, el cambio se guarda como parche o se pierde.
- **Los símbolos no son opcionales.** `construir.sh` archiva el `.elf` de cada
  compilación en `release/simbolos/`, y `publicar.sh` se niega a etiquetar sin
  él. Es lo que convierte el `+0x7abd30` del volcado de un jugador en un nombre
  de función.
- **Comentarios y mensajes en español**, en el tono del historial: se explica el
  fallo que motivó cada cosa, no sólo qué hace. Un comentario que repite el
  código sobra; el que cuenta por qué el código es así, no.
- **Ningún juego entra en el repositorio ni en la entrega.** Nunca.

---

## 8. Licencias

Tres bloques con condiciones distintas —el código propio de este porteo (GPLv2 o
posterior), mkxp-z y CRuby con las suyas, y las herramientas de `tools/`—, cada
pieza con la suya en [`LICENCIAS.md`](LICENCIAS.md).
