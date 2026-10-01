# Bitácora del porteo de Pokémon Añil (agosto-septiembre de 2026)

Esto es el `README.md` que tuvo este repositorio mientras fue una sola cosa: el
porteo de **Pokémon Añil 4.0** a homebrew nativo de Nintendo Switch, desde el
primer `configure` de CRuby hasta la versión `v1.1.1`. Son 71 problemas con su
diagnóstico y su arreglo (§5.1–§5.71), más la arquitectura, la matriz de
dependencias, los hitos y cómo reproducirlo.

**Se conserva sin editar.** Es la historia de cómo se llegó hasta aquí, y lo que
cuenta sigue siendo verdad del motor aunque hoy el motor sea genérico
([`rgss-switch`](../README.md)) y Añil sea un perfil más. Lo único que cambió son
los nombres: donde esto dice una cosa, hoy se llama otra.

| Aquí se llama | Hoy se llama |
|---|---|
| `pokemon-anil.nro` | `mkxp-z-nx/rgss-switch.nro` al compilar; `<slug>.nro` en la tarjeta |
| `anil-datos.zip` | `datos.zip` (`NX_CONTENEDOR` en `nx/nx_juego.h`) |
| `pack-anil.sh` y el `Empaquetar.ps1` de Añil | `Empaquetar.ps1`, que detecta el juego y compone su `mkxp.json` por capas |
| `empaquetar-nsp.sh` | lo hace `Empaquetar.ps1`, en la máquina del jugador y por juego |
| `runtime/mkxp.json` | `runtime/mkxp.base.json` + la capa del juego + el perfil (CONVENCIONES §5) |
| `C:\anilswitch` | la raíz de este repositorio, que el `Makefile` deduce de dónde está |
| `anilftp.py` | `subir-ftp.py` |
| `out/sdcard/switch/pokemon-anil/` | `SD:/switch/<slug>/` |

Las secciones que se citan desde el README de hoy son las de la cadena de
compilación (§5.11, §5.15, §5.18, §5.19, §5.21, §5.26, §5.28), el archivo de
símbolos (§5.65) y `patches/` (§5.71).

---

# Pokémon Añil → Nintendo Switch (homebrew nativo)

> **¿Sólo quieres jugar?** Lee [`GUIA.md`](GUIA.md): descargar la entrega, doble clic
> en `Empaquetar.cmd`, elegir tu carpeta de Añil 4.0, copiar a la SD. Lo de aquí
> abajo es la bitácora de ingeniería del port, para quien quiera entender o
> modificar el motor.

Porteo de **Pokémon Añil 4.0** (RPG Maker XP + Pokémon Essentials v21) a
homebrew nativo de Nintendo Switch, ejecutable como `.nro` desde el hbmenu
sobre Atmosphère. Sin Android, sin Linux, sin capas de emulación.

---

## 0. Qué hay en este repositorio

Está el **porteo**. No está el juego.

Lo que se publica aquí son 86 KB de código escrito para esta máquina —trece
shims de Horizon, veinticuatro parches, el sistema de compilación y los
sustitutos de la biblioteca estándar de Ruby— más la bitácora de §5, que es
donde está el trabajo de verdad. Todo lo demás es reproducible o no es
distribuible.

```
mkxp-z-nx/nx/       13 shims de Horizon: tuberías, excepciones, hilos, memoria
mkxp-z-nx/Makefile  el build que sustituye a meson
patches/            24 parches (Ruby y mkxp-z) + nxcompat.c + las cabeceras shim
runtime/            lo que va a la SD y es fuente: mkxp.json y los shims de Ruby
hello-ruby-nx/      banco de pruebas del intérprete, aislado de SDL y del juego
*.sh *.py *.ps1     compilar, empaquetar, desplegar y depurar
docs/               los registros que cita la bitácora
```

### Lo que tienes que poner tú

| Qué | De dónde |
|---|---|
| **Pokémon Añil 4.0** | Tu propia copia. `JUEGO=/ruta ./pack-anil.sh` |
| **devkitPro** con `switch-dev` y los portlibs de §3 | [devkitpro.org](https://devkitpro.org/wiki/Getting_Started) |
| **CRuby 3.1.7** y **mkxp-z 2.4.2** | Tarballs upstream, a `src/` (los parches van contra esas versiones exactas) |
| **`prod.keys`** | Solo si quieres el NSP. De tu consola, con Lockpick_RCM |
| **hacbrewpack** | Compilado a `tools/hacbrewpack/`, solo para el NSP |

Las rutas están fijadas a `C:\anilswitch` y `C:\devkitPro` en casi todos los
guiones, y no por descuido: §5.15 y §5.18 explican por qué en un cross-compile
de devkitPro bajo Windows la forma de cada ruta importa. Si clonas en otro
sitio, eso es lo primero que hay que tocar.

Cómo compilarlo, paso a paso, en **§7**. Qué licencia lleva cada pieza, en
[`LICENCIAS.md`](LICENCIAS.md).

---

## 1. Por qué esto es posible

El juego **no usa el motor propietario de RPG Maker XP**. Ya viene empaquetado
sobre **mkxp-z**, una reimplementación libre (GPLv2+) del runtime RGSS escrita
en C++ sobre SDL2 + OpenGL/GLES.

Evidencia encontrada en la carpeta del juego:

| Archivo | Qué demuestra |
|---|---|
| `mkxp.json` | Config nativa de mkxp-z (opciones `integerScaling*` → mkxp-z ≥ 2.4) |
| `preload.rb` | Shim de compatibilidad Ruby 3.x |
| `soundfont.sf2` | Ruta de MIDI vía fluidsynth |
| `x64-msvcrt-ruby310.dll` | **Ruby 3.1.x** como intérprete |
| `settings.json` | Config de **JoiPlay** → el juego YA corrió en Android/ARM64 |

El último punto es clave: existe prueba de que este juego concreto funciona en
ARM64. El porteo no es reescribir el juego, es **recompilar un motor de código
abierto para aarch64-Horizon**.

---

## 2. Arquitectura objetivo

```
Nintendo Switch (Atmosphère CFW)
└── hbmenu
    └── anil.nro
        ├── mkxp-z (C++)          ← motor RGSS
        ├── CRuby 3.1.7 estático  ← intérprete  [EL BLOQUEO]
        ├── SDL2 2.28.5           ← ventana/input/audio
        ├── Mesa 20.1 + nouveau   ← OpenGL ES 3 sobre Tegra X1
        ├── OpenAL-soft           ← audio
        └── romfs / sdmc          ← 814 MB de assets del juego
```

---

## 3. Matriz de dependencias

| Componente | Estado | Notas |
|---|---|---|
| SDL2 | ✅ `switch-sdl2` | 2.28.5 |
| SDL2_image / SDL2_ttf | ✅ instalados | |
| OpenGL ES 3 / EGL | ✅ `switch-mesa` | vía `libdrm_nouveau` |
| OpenAL | ✅ `switch-openal-soft` | |
| libvorbis / libogg / libtheora | ✅ instalados | audio + vídeo |
| PhysFS | ✅ `switch-physfs` | sistema de archivos virtual |
| FreeType / HarfBuzz | ✅ instalados | |
| zlib / bzip2 / libpng / webp | ✅ instalados | |
| libmodplug / mpg123 | ✅ instalados | |
| **CRuby (MRI)** | ✅ **portado** | 45 MB · **primer CRuby en homebrew de Switch** |
| pixman | ✅ portado | 7,1 MB |
| SDL_sound | ✅ portado | 2,5 MB |
| iconv | ✅ portado | 1,9 MB — newlib trae la cabecera pero no la implementación |
| uchardet | ✅ portado | 782 KB |
| ~~sigc++~~ | ❌ innecesario | asunción errónea: mkxp-z no lo usa |
| fluidsynth | ❌ innecesario | 1 solo MIDI en 814 MB (ver §8) |

**Todas las dependencias de mkxp-z están disponibles para Nintendo Switch.**

**11 de 11 dependencias de sistema ya resueltas.** El único componente sin
precedente es el intérprete de Ruby.

---

## 4. El problema de CRuby en Horizon

Horizon OS (vía newlib + libnx) **no tiene**:

- `fork` / `exec` — no hay modelo de procesos
- `dlopen` / `dlfcn.h` — no hay enlace dinámico
- `mmap` / `sys/mman.h` — no hay memoria mapeada POSIX
- `ucontext.h` — no hay corrutinas del SO

Ninguno es fatal, y hay precedente: **ruby.wasm** demostró que MRI puede
compilarse para una plataforma sin `fork`, sin `dlopen` y sin hilos POSIX
completos. Las soluciones aplicadas aquí:

| Falta | Solución |
|---|---|
| `dlopen` | `--with-static-linked-ext` (todas las extensiones enlazadas estáticamente) |
| `fork`/`exec` | `ac_cv_func_fork=no` etc.; Essentials no los usa |
| `mmap` | El GC de Ruby cae a `posix_memalign` / `malloc` |
| `ucontext` | `coroutine/arm64/Context.S` — ensamblador aarch64 puro, sin SO |
| hilos | libnx **sí** provee `pthread.h` ✅ |

---

## 5. Bitácora de problemas resueltos

### 5.1 GCC 16 compila en C23 por defecto
`__STDC_VERSION__ = 202311L`. Rompía Ruby 3.1.7 en dos frentes:

- **`typedef unsigned char _Bool` inválido.** El test de autoconf
  "stdbool.h that conforms to C99" comprueba `__bool_true_false_are_defined`,
  macro que C23 elimina → `ac_cv_header_stdbool_h=no` → Ruby activaba su
  shim de `_Bool`, que colisiona con la palabra clave.
- **`char *getenv();` en `dln.c`.** En C23 `()` significa `(void)`, chocando
  con `getenv(const char *)` de newlib.

**Solución:** `-std=gnu11` en `CFLAGS`. Corrige ambos.
No era un problema de Switch — era código de 2025 contra compilador de 2026.

### 5.2 Rutas con espacios
La carpeta original (`POKEMON_ANIL (1)/Pokemon Anil`) contiene espacios y
paréntesis, que autotools no tolera. El workspace vive en `C:\anilswitch`.

### 5.3 Nombres de paquete
`switch-libmpg123` no existe; es `switch-mpg123`. Un nombre erróneo aborta
la transacción entera de pacman.

### 5.4 Horizon no tiene memoria mapeada POSIX
`cont.c` (Fibers/continuaciones) incluye `<sys/mman.h>` sin protección y usa
`mmap` para el pool de pilas de Fiber, con páginas de guarda vía `mprotect`.
Siete archivos de Ruby incluyen esa cabecera.

**Solución:** shim `patches/include/sys/mman.h` (83 líneas) que respalda `mmap`
con `memalign(4096, len)`, `munmap` con `free()`, y convierte `mprotect`/
`madvise` en no-ops. Deliberadamente **no** define las macros `MADV_*`, de modo
que `cont.c` no tome ninguna rama de `madvise` — exactamente como hace la rama
`__wasi__` que Ruby ya trae.

*Concesión aceptada:* se pierde la detección por hardware del desbordamiento de
pila en Fibers. Es la misma renuncia que hace el port oficial a WASI.

`ac_cv_header_sys_mman_h=no` se mantiene forzado a propósito: el shim está en el
include path para `cont.c` (que lo incluye sin condición), pero `gc.c` sí
protege con `#ifdef HAVE_SYS_MMAN_H`, y así evita las rutas de `mmap` y usa
`posix_memalign`, más eficiente que un `mmap` respaldado por `malloc`.

### 5.5 newlib declara `sysconf()` pero no la implementa
`cont.c` hace `pagesize = sysconf(_SC_PAGESIZE)`. La macro `_SC_PAGESIZE` está
definida en `sys/unistd.h`, pero **ni `libc.a` de newlib ni `libnx.a` exportan
el símbolo `sysconf`**. Habría fallado en el enlazado, o —peor— dejado
`RB_PAGE_SIZE` en −1.

**Solución:** `patches/nxcompat.c` → `libnxcompat.a`, con `sysconf()` y
`getpagesize()` devolviendo valores reales del Tegra X1 (página de 4 KiB,
3 núcleos disponibles para homebrew de los 4 físicos, 4 GiB de RAM).
Se enlaza vía `LIBS="-lnxcompat -lnx"`.

### 5.6 newlib define `dev_t` como `short` con signo
El `configure` de Ruby genera `DEVT2NUM(v) → SHORT2NUM(v)`, pero **`SHORT2NUM`
no existe en Ruby**. Solo hay `USHORT2NUM` (sin signo). El propio código lo
reconoce en un comentario: *"Shyouhei wonders: why there is no SHORT2NUM…"*.
Ninguna plataforma convencional llega a ese caso: en Linux `dev_t` es
`unsigned long`; en macOS, `int32`.

**Solución:** `patches/0001-add-SHORT2NUM-for-newlib-signed-dev_t.patch`.
Define `SHORT2NUM` como `RB_INT2FIX` — un `short` siempre cabe en un Fixnum,
el mismo razonamiento que ya justifica `USHORT2NUM == RB_INT2FIX`.

### 5.7 El read barrier de la compactación del GC necesita señales
`gc.c` instala manejadores de `SIGSEGV`/`SIGBUS` con `sa_sigaction`,
`SA_SIGINFO`, `SA_ONSTACK` y `siginfo_t::si_addr`. newlib no provee ninguno.
Y como nuestro `mprotect` es un no-op, la compactación **no podría funcionar
igualmente**.

**Solución:** `patches/0002-gc-disable-compaction-on-horizon.patch`, que añade
una rama `#elif defined(__SWITCH__)` con stubs vacíos.

Detalle importante de seguridad: `GC.auto_compact = true` **ya se autobloquea**,
porque Ruby comprueba `USE_MMAP_ALIGNED_ALLOC` (que vale 0 en nuestro build) y
lanza `NotImplementedError`. El propio comentario de Ruby lo explica: *"we
cannot use mprotect for the read barrier, so we must disable automatic
compaction"*. El parche cierra además el `GC.compact` explícito, que era la
única vía que quedaba para corromper el heap en silencio.

### 5.8 `O_BINARY` definida sin `setmode()`
newlib define `O_BINARY` como `_FBINARY`. `io.c` protege sus llamadas con
`#ifdef O_BINARY`, dando por hecho que toda plataforma con esa macro es de tipo
DOS y trae `setmode()`. No es el caso.

**Solución:** `setmode()` en `nxcompat.c` devolviendo `O_BINARY` (Horizon abre
en binario nativamente, no hay traducción de fin de línea que conmutar), más
`patches/include/nxshim.h` inyectada con `-include` para declararla — GCC 14+
trata la declaración implícita como error.

### 5.9 `process.c` exige `waitpid` con `#error`
No basta con omitirla. **Solución:** `waitpid()` en `nxcompat.c` devolviendo −1
con `ECHILD`, y `ac_cv_func_waitpid=yes`. Semánticamente correcto: en Horizon
nunca hay procesos hijos, y `Process.wait` lanza `Errno::ECHILD`, que es
exactamente lo que debe ocurrir.

### 5.10 `posix_signal()` llamada sin protección
`thread_pthread.c:662` llama a `posix_signal(SIGVTALRM, null_func)`, pero esa
función solo se define dentro de `#ifdef POSIX_SIGNAL` — macro que configure
activa únicamente si existen `sigaction` **y** `sigprocmask`. newlib no tiene
ninguna de las dos.

**Solución:** `patches/0003-guard-posix_signal-without-sigaction.patch`.

### 5.11 Las extensiones no se enlazaban: `ld` interno de GNU Make
Toda la fase `build-ext` moría con `ld: No such file or directory` (Error 127).

`rbconfig.rb` tiene el enlazador correcto (`CONFIG["LD"] = "aarch64-none-elf-ld"`)
y define `CONFIG["LDSHARED"] = "$(LD)"`. Pero los Makefiles de extensión que
genera `extmk.rb` escriben `LDSHARED = $(LD)` **sin definir `LD` en ese
Makefile**. Y GNU Make trae una variable interna por defecto: `LD = ld`. En un
cross-compile eso invoca el enlazador del anfitrión, que en Windows no existe.

**Solución:** pasar `LD` por línea de órdenes — `make LD=aarch64-none-elf-ld` —
lo que anula la variable interna y se propaga automáticamente a los sub-makes.

### 5.12 Las 54 extensiones `-test-` abortaban la compilación
`ext/-test-/` contiene 54 extensiones que solo usa la suite de tests de Ruby.
Al ordenarse alfabéticamente por delante de todo, fallaban primero y tumbaban
la fase antes de llegar a `zlib` — **la extensión crítica**, ya que los
`.rxdata` de RPG Maker están comprimidos con zlib.

`--with-out-ext=…,-test-` no las excluye (el patrón no cubre los subdirectorios
anidados). **Solución:** eliminar `ext/-test-` del árbol de fuentes y borrar
`exts.mk` para que se regenere.

### 5.13 Gemas empaquetadas: `.so` enlazado con `ld` crudo
Tras corregir 5.11, la fase moría en la gema `debug` con:

```
aarch64-none-elf-ld: unrecognised emulation mode: tp=soft
```

`-mtp=soft` es un flag de **GCC**, no de `ld`; el enlazador lo lee como
`-m tp=soft`. La causa de fondo: las extensiones de gemas empaquetadas se
construyen **siempre** como objeto compartido, incluso en un build estático.
Dos gemas traen extensión nativa: `debug` y `rbs`.

**Solución:** vaciar `gems/bundled_gems`. Ninguna gema empaquetada hace falta
para embeber Ruby en mkxp-z, y en Horizon no existe el enlace dinámico, así que
ningún `.so` tiene sentido. Las extensiones **del núcleo** sí enlazan
correctamente en estático (`libenc.a`, `libtrans.a`, `json.a`, `digest.a`,
`ripper.a`, `objspace.a`…).

### 5.14 17 símbolos POSIX referenciados sin protección
El enlazado final reclamó:

```
chown, endpwent, execl, execle, execv, getegid, geteuid, getgid,
getppid, getpwnam, getrusage, getuid, pclose, pipe, popen,
pthread_kill, umask
```

Lo revelador: **ninguna** de sus macros `HAVE_*` está definida en `config.h`.
Ruby sabe que no existen, pero `file.c` y `process.c` las llaman igualmente —
la suposición implícita de que «todo lo que no es Windows es POSIX completo».

**Solución:** implementadas en `nxcompat.c` con valores honestos:

| Grupo | Comportamiento |
|---|---|
| `getuid`/`geteuid`/`getgid`/`getegid` | `0` — un solo usuario, sin separación de privilegios |
| `getppid` | `0` — no hay proceso padre |
| `umask` | `0` — Horizon no tiene bits de modo POSIX |
| `chown`, `exec*`, `pipe`, `popen`/`pclose` | `-1` + `ENOSYS` → Ruby lanza `Errno::ENOSYS` |
| `getpwnam` | `NULL` + `ENOENT` — no hay base de usuarios |
| `getrusage` | ceros y `0`, **no** `-1`, para no romper `Process.times` ni el perfilador del GC |
| `pthread_kill` | `0` — no hay señales que entregar. Verificado que Ruby 3.1.7 llama sin comprobar el retorno (`thread_pthread.c:1363` y `:2280`) |

### 5.15 `DEVKITPRO` debe estar en forma Windows, no POSIX
Con todos los símbolos ya resueltos, el enlazado del ejecutable fallaba con:

```
ld: section .tls.align LMA [0x0,0x7] overlaps section .text LMA [0x0,0x264537]
```

Un solapamiento de secciones es señal de que **no se aplicó el linker script**.
La causa está en `libnx/switch.specs`:

```
*link:
+ -T %:getenv(DEVKITPRO /libnx/switch.ld) -pie --no-dynamic-linker ...
```

GCC expande ese `getenv` **internamente**, después de que MSYS2 haya hecho su
traducción de rutas en los argumentos. Como los binarios de devkitA64 son
ejecutables **nativos de Windows**, no pueden resolver un punto de montaje
POSIX. Sin `switch.ld`, `ld` usa su script por defecto y las secciones chocan.

Comprobado con un enlazado mínimo contra libnx:

| `DEVKITPRO` | Resultado |
|---|---|
| `/opt/devkitpro` | ❌ `cannot open linker script file C:/Program Files/Git/opt/devkitpro/libnx/switch.ld` |
| `C:/devkitPro` | ✅ enlaza — ELF de 2,9 MB |

Nótese el mensaje del primer caso: Git Bash resolvió `/opt/devkitpro` contra
**su propia raíz** de instalación.

**Solución:** exportar `DEVKITPRO=C:/devkitPro` (forma Windows) y sustituir
`/opt/devkitpro` → `C:/devkitPro` en todos los artefactos ya generados —
`Makefile`, `rbconfig.rb` y los Makefiles de extensiones, ya que `extmk.rb` los
genera a partir de `rbconfig.rb`. El `PATH` sí debe seguir en forma POSIX,
porque lo consume el shell y no GCC.

**Lección general:** en cross-compiles de devkitPro bajo Windows, todo lo que
acabe *dentro* de un binario nativo debe ir en rutas Windows; solo lo que
consume el shell va en rutas POSIX.

### 5.16 El ejecutable `ruby` no enlaza — y no importa
El target `ruby` del build de Ruby sigue fallando con el solapamiento
`.tls.align` / `.text`, incluso con las rutas ya corregidas. Curiosamente
**nuestro propio NRO enlaza sin problema** con la misma `libruby-static.a`,
y coloca las secciones TLS correctamente.

La diferencia está en que el Makefile de devkitPro aplica el conjunto completo
de reglas de enlazado de homebrew, mientras que el de Ruby construye un ELF
genérico. Aislé los flags uno a uno (`-ffunction-sections`, `-fstack-protector`,
`-Wl,-rpath`, librerías duplicadas, `-lnx` repetido tres veces) y **ninguno lo
reproduce**: un programa trivial enlaza bien con todos ellos.

**No merece la pena perseguirlo.** El ejecutable `ruby` es un binario de
Horizon que no puede ejecutarse ni en el PC ni en la consola (haría falta
convertirlo a `.nro`). Lo único que necesitamos son `libruby-static.a` y los
`.a` de las extensiones. **Solución:** `make -k`, que continúa pese a ese fallo
concreto.

### 5.17 `ext/extinit.c` vacío y `zlib` sin detectar
Dos consecuencias del fallo anterior:

- **`Init_ext()` se generó vacío.** Con `--with-static-linked-ext`, las
  extensiones deben registrarse ahí; sin eso, ni `json` ni `digest` ni `ripper`
  estarían disponibles en tiempo de ejecución pese a compilar.
- **`zlib` no se detectó.** Su `mkmf.log` muestra que el `have_library('z')`
  se ejecutó con rutas POSIX (`-specs=/opt/devkitpro/…`), anteriores a la
  corrección de 5.15. Ese test de enlazado fallaba por el linker script, así
  que `extconf.rb` concluyó que libz no existía.

  **Esto era crítico:** los `.rxdata` de RPG Maker están comprimidos con zlib.
  Sin esa extensión, Pokémon Añil no puede ni leer sus propios scripts.

**Solución:** purgar `ext/zlib`, `ext/stringio`, `ext/strscan`, `ext/extinit.c`
y `exts.mk` para que se regeneren con las rutas ya corregidas.

### 5.18 `mkmf.rb` lanza sus conftest sin traducción de rutas de MSYS2
Tras purgar y regenerar, el `extconf` de zlib volvió a fallar, pero con otro
mensaje:

```
ld.exe: cannot find -lnxcompat
```

Es la misma clase de error que 5.15, aplicada esta vez a **nuestras propias
rutas**. El conftest enlaza con `-L/c/anilswitch/out/lib`. Cuando `make` invoca
GCC, MSYS2 convierte ese argumento `/c/…` a `C:/…` automáticamente. Pero
`mkmf.rb` **no se ejecuta bajo MSYS2**: `extconf.rb` corre en el Ruby anfitrión
de Windows (`rubyinstaller`), que lanza GCC directamente. Sin conversión, GCC
interpreta `/c/anilswitch/...` como una ruta relativa a la raíz de la unidad
actual y busca en `C:\c\anilswitch\...`.

Esto explica por qué el enlazado principal sí resolvía `-lnxcompat` mientras
los conftest de extensiones no: recorren caminos distintos.

**Solución:** rutas Windows en todo lo que ve el compilador. El script ahora
distingue dos variables:

```bash
ROOT=/c/anilswitch      # forma POSIX: shell (cd, test, redirecciones)
ROOT_W=C:/anilswitch    # forma Windows: GCC y el Ruby anfitrión
```

**Regla general del proyecto** (vale para 5.15 y 5.18): *si el valor acaba
dentro de un proceso nativo de Windows, va en ruta Windows; si lo consume el
shell, va en ruta POSIX.* Los cross-compiles de devkitPro bajo Windows cruzan
esa frontera constantemente, y los fallos que provoca son opacos: un linker
script silenciosamente ignorado, o una librería «inexistente» que sí está ahí.

### 5.19 `dmyext.o`: el `Init_ext()` vacío que anulaba las extensiones
Con `zlib`, `stringio` y `strscan` ya compiladas y un `extinit.c` propio, el NRO
enlazaba sin errores… pero `Init_zlib` **no aparecía en el binario**, y el
recuento de símbolos era idéntico al de antes: `libruby-ext.a` no aportaba nada.

La causa: `libruby-static.a` contiene `dmyext.o`, que define un `Init_ext()`
**vacío** como marcador para cuando no hay extensiones estáticas. El enlazador
lo resolvía primero y jamás llegaba al nuestro. **Sin ningún error** — las
extensiones simplemente no existirían en tiempo de ejecución.

Reordenar las librerías no sirve: nada referencia `Init_ext` hasta que se
procesa `libruby-static.a`, momento en que `dmyext.o` ya lo satisface.

**Solución** (`finalize-ruby.sh`), que es lo que hace el build normal de Ruby:

```bash
ar d libruby-static.a dmyext.o          # retirar el marcador vacio
ar r libruby-static.a extobj/*.o        # insertar extinit + extensiones
ar s libruby-static.a                   # reindexar
```

Este es el fallo más peligroso de todos los encontrados: silencioso, sin aviso
del compilador ni del enlazador, y solo se habría manifestado como un
`LoadError` en la consola al hacer `require 'zlib'` — es decir, al intentar
cargar el primer `.rxdata` del juego.

### 5.20 Secuencia de arranque incompleta: faltaban builtins y extensiones
Primera ejecución real (Ryujinx, firmware 20.5.0): **8 pruebas OK y 5 fallos**.
El intérprete arrancaba y evaluaba código —aritmética, cadenas, bloques,
hashes, `Struct`, excepciones— pero fallaban `Marshal`, `GC.*` y todos los
`require`. Los mensajes de error salían vacíos, lo que llevó a una hipótesis
inicial equivocada: «el GC daña la VM».

Al reordenar las pruebas y capturar la clase de la excepción, el cuadro real:

```
Marshal.load   → NoMethodError: private method `load' called for Marshal:Module
GC.start       → NoMethodError: undefined method `start' for GC:Module
require 'zlib' → LoadError: cannot load such file -- zlib
alloc (5000)   → OK      <- el GC funcionaba perfectamente
post-GC        → OK
```

`alloc` asigna 5000 cadenas, lo que dispara el GC internamente, y pasaba.
El GC nunca fue el problema.

**Causa real:** `GC.start`, `GC.count`, `GC.stat` y `Marshal.load` **no están
definidos en C**. Ruby 3.x los define en `gc.rb` y `marshal.rb`, código Ruby
precompilado que carga el *prelude*. Y ese prelude vive en `ruby_opt_init()`
(`ruby.c:1636`):

```c
Init_ext();              /* extensiones enlazadas estaticamente */
rb_call_builtin_inits();
ruby_init_prelude();     /* gc.rb, marshal.rb, io.rb... */
```

`ruby_opt_init` es **`static`**: solo se alcanza por la cadena
`ruby_options()` → `ruby_process_options()` → `process_options()`. El patrón
de embebido «básico» (`ruby_init()` + `ruby_init_loadpath()`) se la salta
entera — suficiente para el núcleo del lenguaje, inútil para todo lo demás.

**Solución:** replicar lo que hace el `main.c` del propio Ruby — `ruby_init()`
**y después** `ruby_options()`:

```c
static char *rargv[] = { "ruby", "--disable-gems", "-e", "" };
void *node = ruby_options(4, rargv);
if (ruby_executable_node(node, &state)) ruby_exec_node(node);
```

`--disable-gems` evita que el prelude intente cargar RubyGems desde disco:
en la consola no hay stdlib en la SD.

**Resultado: 19/19.**

### 5.21 mkxp-z no usa Ruby oficial: 21 líneas que lo cambian todo
`linux/Makefile` de mkxp-z revela que compila **su propio fork**:
`mkxp-z/ruby`, rama `mkxp-z-3.1.3`. De sus 25 commits, **solo uno** es un
parche propio («apply mkxp-z patches»); el resto son backports de upstream.
Ese commit son **+30 −8 líneas en 8 archivos**, y la mitad son de Windows.

Los cambios reales, todos hacks de compatibilidad con RGSS/Ruby 1.8:

| Archivo | Qué hace |
|---|---|
| `class.c` | Desactiva el error *superclass mismatch* en `rb_define_class` |
| `vm_insnhelper.c` | Ídem en `vm_check_if_class`, + `goto call_anyway` en el despacho |
| `vm_eval.c` | **Desactiva la visibilidad private/protected**: todo método es público |
| `sprintf.c` | Silencia *"too many arguments for format string"* |

Los scripts de RPG Maker XP reabren clases cambiando la superclase y llaman a
métodos privados sin reparo — cosas que Ruby 1.8 toleraba y 3.x rechaza.

**Conexión importante:** el `private method 'load' called for Marshal:Module`
que apareció en la primera ejecución real es exactamente la clase de fallo que
el parche de `vm_eval.c` existe para evitar. Sin estos parches, Pokémon
Essentials no arranca — y el fallo habría aparecido en H4, tras días de trabajo
sobre una base equivocada.

Aplicados a Ruby 3.1.7 en `patches/0005-mkxpz-*.patch` y **verificados en
ejecución**:

```
[ OK ] privado     accesible     <- metodo private llamado desde fuera
[ OK ] protegido   ok            <- metodo protected llamado desde fuera
[ OK ] superclase  permitido     <- clase reabierta con otra superclase
[ OK ] sprintf     1             <- formato con argumentos de mas
```

Las cuatro fallan en un Ruby 3.x sin parchear. **23/23 en total.**

### 5.22 Tres sabores distintos del mismo problema de rutas
El porteo de las dependencias de H3 volvió a tropezar con la frontera
Windows/POSIX, pero **cada herramienta la cruza de forma distinta**:

| Herramienta | Qué forma quiere | Por qué |
|---|---|---|
| GCC / `switch.specs` | **Windows** (`C:/devkitPro`) | binario nativo; expande `%:getenv` sin traducción de MSYS2 |
| `mkmf.rb` (conftest) | **Windows** | lo lanza el Ruby anfitrión de Windows, fuera de MSYS2 |
| `cmake` de devkitPro | **POSIX** (`/c/devkitPro`) | es un binario MSYS2: `C:/…` no le parece absoluta y la concatena |

El síntoma de CMake era desconcertante:

```
include could not find requested file:
    /c/anilswitch/build/uchardet/C:/devkitPro/cmake/Switch.cmake
```

Se añade además `-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY`, para que CMake
no intente enlazar un ejecutable de prueba al detectar el compilador — lo
correcto al cruzar hacia un target sin sistema operativo completo.

### 5.23 GCC 16 y C23, otra vez (libiconv)
`libiconv-1.16` falló exactamente igual que Ruby:

```
loop_wchar.h:39: error: conflicting types for 'mbrtowc'; have 'size_t(void)'
   extern size_t mbrtowc ();
```

Declaración K&R con lista de parámetros vacía, que en C23 significa `(void)`.
Mismo remedio: `-std=gnu11`. **Es el fallo más recurrente de todo el porteo**:
código anterior a 2023 compilado con un GCC que por defecto usa C23.

### 5.24 CMake 4.x rechaza `cmake_minimum_required` antiguos
`uchardet` y `SDL_sound` declaran mínimos < 3.5, que CMake 4.0.2 ya no acepta.
Se resuelve con `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`, tal y como sugiere el
propio mensaje de error.

---

### 5.25 `require 'socket'` en Cable Club: un `LoadError` que mata el arranque

Descubierto al analizar los assets para H5, no compilando. El juego lleva 52
plugins dentro de `Data/PluginScripts.rxdata`; el llamado **Cable Club**
(intercambio y combate en línea) empieza su archivo #4 así:

```ruby
require 'socket'
require 'io/wait'

class Connection
```

Está en el **nivel superior**, sin `begin`/`rescue`. Essentials evalúa los
plugins en cadena al arrancar, así que un `LoadError` ahí no desactiva el
plugin: **aborta el juego entero antes del título**. Y nuestro CRuby se compiló
con `--with-out-ext=…,socket`, de modo que ninguna de las dos extensiones
existe.

Para encontrarlo hubo que descomprimir los scripts, porque los `.rxdata` son
Marshal + zlib y `grep` no ve nada. De 770 secciones y 10,02 MB de código Ruby
sólo hay **tres** `require` en todo el juego, y dos son estos.

**Solución elegida: sustitutos en Ruby puro** en `lib/socket.rb` y
`lib/io/wait.rb`, declarados vía `"rubyLoadpath": ["lib"]`. La superficie real
que Cable Club usa es mínima —una sola puerta de entrada:

```
 11| socket = TCPSocket.open(host, port)
 29| recvd = @socket.recv(4096)
 55| return !IO.select(nil, [@socket],nil).nil?
 64| @socket.write_nonblock(writer.line!)
 73| @socket.close
```

`IO.select` y `write_nonblock` ya están en el núcleo de Ruby. Basta con definir
la jerarquía de clases y hacer que `TCPSocket.open` eleve `SocketError` con un
mensaje claro. El juego arranca; el Cable Club sólo falla si el jugador entra
en él, que sin servidor fallaría igualmente.

**Verificado de verdad, no sólo la sintaxis:** se cargan los sustitutos, se
descomprime el archivo #4 real del plugin y se evalúa:

```
[ OK ] Cable Club archivo#4 evaluado sin errores
Connection definida:      si
TCPSocket definida:       si
IO#wait_readable:         si
TCPSocket.open:           eleva SocketError -> Cable Club no esta disponible...
=== RESULTADO: 1 OK, 0 fallos ===
```

**Lo interesante es que esto se puede arreglar de verdad en H6**: libnx exporta
`socket`, `connect`, `bind`, `listen`, `accept`, `send`, `recv`, `select` y
`getaddrinfo` como símbolos `T` reales en `libnx.a`, y devkitA64 trae
`sys/socket.h`, `netinet/in.h`, `netdb.h` y `arpa/inet.h`. La extensión nativa
de Ruby es construible, y con ella el Cable Club funcionaría por WiFi entre dos
Switch. Queda fuera de H5 por alcance, no por imposibilidad.

### 5.26 Por qué el port de mkxp-z no usa meson

mkxp-z se compila con meson, y la reacción natural es escribir un fichero
*cross* para `aarch64-none-elf`. Lo descarté tras mirar tres cosas:

1. **El único codegen de meson es `xxd -i`.** `shader/meson.build` y
   `assets/meson.build` no hacen nada más que empotrar 29 ficheros como arrays
   de C. `gen-xxd.sh` lo reproduce en 20 líneas.

2. **Los `.pc` de portlibs llevan rutas envenenadas.** `physfs.pc` empieza con
   `prefix=/opt/devkitpro/portlibs/switch`. pkg-config emitiría
   `-L/opt/devkitpro/...`, que bajo nuestro GCC de Windows no existe: es
   exactamente el problema §5.15, que ya costó una sesión entera de depuración.
   Con un Makefile las rutas se escriben una vez, en forma Windows, y se acabó.

3. **El Makefile de devkitPro ya funcionaba.** Produjo `hello-ruby-nx.nro` en
   H2 sin pelea.

Un detalle que sí hay que respetar: **`xxd` construye el nombre del array a
partir de la ruta que se le pasa**, no del contenido. meson lo invoca desde su
directorio de compilación con `../shader/common.h`, lo que da
`___shader_common_h`, y `shader.cpp` espera ese nombre exacto. Generar los
`.xxd` desde otro sitio produce símbolos que no casan y el enlace falla con
errores que no apuntan a la causa. Por eso `gen-xxd.sh` hace `cd` a un
directorio hermano de `shader/` antes de nada.

### 5.27 GCC no podía escribir sus ficheros temporales

```
Cannot create temporary file in C:\WINDOWS\: Permission denied
```

en las 70 fuentes a la vez. GCC pide un temporal con `GetTempPath()`, que
consulta `TMP` y `TEMP` y, si no valen, cae al directorio de Windows. En este
entorno `TMP` llega con contrabarras y al cruzar MSYS2 hacia el proceso nativo
se corrompe.

Exportarlas desde el shell **no bastó**: se pierden igual. La solución es
fijarlas dentro del propio Makefile, que además hace la compilación
independiente del entorno de quien la lance:

```make
export TMPDIR := C:/anilswitch/tmp
export TMP    := C:/anilswitch/tmp
export TEMP   := C:/anilswitch/tmp
```

Es el mismo patrón de §5.15: **forma Windows con barras normales**.

### 5.28 Las cinco ramas de plataforma que le faltaban a mkxp-z

mkxp-z conoce Windows, macOS y Linux. Horizon no es ninguna, y el código lo
dice a gritos con `#error`. Cinco puntos:

| Fichero | Problema | Solución |
|---|---|---|
| `src/system/system.h` | `#error "Can't identify platform."` | Cuarta constante `MKXPZ_PLATFORM_SWITCH` |
| `src/system/systemImpl.cpp` | `std::locale("")` — newlib solo tiene la localización `"C"` y eso **lanza una excepción** | Idioma real vía `setGetSystemLanguage()` de libnx, con las etiquetas de Horizon |
| `src/audio/fluid-fun.cpp` | `#error "platform not recognized"` | Rama `__SWITCH__`. `SDL_LoadObject` fallará (no hay `dlopen`) y el código **ya degrada solo** a «Midi playback is disabled», que es justo lo que queremos: el juego no lleva MIDI (§8) |
| `src/filesystem/ghc/filesystem.hpp` | `#error "Operating system currently not supported!"` | `GHC_OS_LINUX`: libsysbase da `stat`/`opendir`/`readdir`/`realpath`, que es todo lo que usa la ruta POSIX de ghc |
| `src/net/httplib.h` | `#include <ifaddrs.h>` — Horizon no lo tiene | Se excluye el include y se deja `USE_IF2IP` sin definir. `if2ip()` solo sirve para atar la conexión a una interfaz concreta |

Cuidado con `SetLanguage_ESES`: en libnx el español europeo es
**`SetLanguage_ES`**, y el latinoamericano `SetLanguage_ES419`.

**Un aviso sobre los parches.** El primer intento los escribió con Python
usando `io.open(p,"w")`, que en Windows traduce el salto de línea a CRLF. Eso
reescribió el final de **todas** las líneas de cada fichero: los `.patch`
salieron de 11.386 y 14.153 líneas en vez de 13 y 23. No rompía la compilación
—a C++ le da igual—, pero dejaba los parches inservibles como documentación.
Hay que abrir con `newline=''` tanto para leer como para escribir, y detectar
si el original era CRLF para convertir el texto buscado.

### 5.29 bzip2: mi comprobación estaba mal planteada

Al inventariar las 19 dependencias de `src/meson.build`, bzip2 salió como la
única ausente. Comprobé que PhysFS 3.2.0 de portlibs tiene **0** referencias a
`BZ2_*` y que mkxp-z no menciona bzlib en su código, y concluí que era una
«dependencia fantasma» heredada de compilaciones de escritorio.

**Las dos observaciones eran ciertas y la conclusión falsa.** Al enlazar
aparecieron `BZ2_bzDecompressInit`, `BZ2_bzDecompress` y `BZ2_bzDecompressEnd`.
Quien las pide es **`libfreetype.a`**, compilada con soporte de fuentes PCF
comprimidas. Y `libbz2.a` **sí está** en portlibs: lo que no tiene es fichero
`.pc`, y mi comprobación se basaba en los `.pc`.

La lección es sobre el método, no sobre bzip2: **buscar por el índice de
paquetes no equivale a buscar por los símbolos.** Un `nm -u` sobre todas las
`.a` habría dado la respuesta correcta a la primera. Se arregla con `-lbz2`.

### 5.30 iconv: la cabecera decide el nombre del símbolo

Últimos tres símbolos sin resolver: `iconv`, `iconv_open`, `iconv_close`, desde
`src/util/encoding.h`. Pero `libiconv.a` sí los tiene… con otro nombre:

```
T libiconv        T libiconv_open        T libiconv_close
```

GNU libiconv exporta los símbolos con prefijo `lib` y su propia cabecera hace
el puente:

```c
#define iconv_open libiconv_open
```

Al compilar libiconv nunca instalé `iconv.h` en `out/nx/include`, así que el
compilador encontró la de **newlib**
(`devkitA64/aarch64-none-elf/include/iconv.h`), que declara `iconv_open` a
secas y no remapea nada. El código quedó pidiendo símbolos que no existen.

Copiar `build/libiconv/include/iconv.h` al prefijo lo resuelve — pero **hay que
borrar los `.o` afectados**: `make` no los recompila solo, porque el fichero de
dependencias apunta a la cabecera de newlib, que sigue existiendo y sin cambios.

### 5.31 El canal de diagnóstico: por qué casi diagnostico mal el arranque

Con el NRO ya enlazado, la primera ejecución en Ryujinx terminó los 75 segundos
del temporizador sin estrellarse **y sin una sola línea de salida**. El registro
del emulador se cortaba en `Loading as homebrew.`

`Debug()`, la clase de trazas de mkxp-z, escribe a `std::cerr`, que en Horizon
no va a ninguna parte. Le añadí una rama `__SWITCH__` con
`svcOutputDebugString`, que es lo que había funcionado en H2. Volví a ejecutar:
otra vez nada. Y otra vez con sondas puestas en la primerísima línea de
`main()`.

La conclusión hacia la que iba —«algo muere antes de `main()`, seguramente en
los constructores estáticos»— era razonable y **habría sido falsa**. Antes de
darla por buena lancé el control obvio: el `hello-ruby-nx.nro` de H2, del que
consta que da 23/23, con exactamente la misma invocación.

**Se comportó igual: ni una línea.** Pero al mirar la tarjeta SD virtual estaba
`ruby-test-results.txt`, recién escrito. La aplicación se había ejecutado
perfectamente.

Lo que falla es el arnés, no el binario: al capturar la salida de Ryujinx con
`timeout … > log 2>&1`, el registro Guest no llega al fichero. En H2 nunca
dependí de eso — los resultados salían por un fichero en la SD, y por eso
funcionó.

**La regla que sale de aquí: en Horizon, el diagnóstico se escribe a un fichero
de la tarjeta.** `Debug()` ahora hace las dos cosas, y abre y cierra el fichero
en cada línea para que lo escrito sobreviva a un cierre brusco:

```c
FILE *f = fopen("sdmc:/switch/pokemon-anil/mkxp-debug.log", "a");
if (!f) f = fopen("mkxp-debug.log", "a");
if (f) { fputs(s.c_str(), f); fputc(0x0A, f); fclose(f); }
```

`fputc(0x0A, f)` y no `fputc('\n', f)` por una razón práctica: la barra
invertida no sobrevive intacta a las capas de shell y heredoc que hay entre el
editor y el fichero, y una secuencia de escape rota dentro de un literal de
carácter produce un error de compilación que no se parece en nada a su causa.

### 5.32 El NRO se cargaba a medias por faltarle el icono

Este fue el muro de H4, y la causa no se parecía en nada al síntoma.

**Síntoma.** Ryujinx aceptaba el NRO (`Loading as homebrew.`), el proceso no se
estrellaba, no había `svcBreak` ni excepción, y **ninguna** de las trazas
aparecía: ni la del primer constructor estático, ni la de `main()`.

**Falsa pista.** Con las sondas en la primera instrucción de `main()` y en un
`__attribute__((constructor(101)))` mudas, la lectura natural es que el fallo
está entre la entrada del NRO y `__libc_init_array` — el montón, `__appInit`, o
alguno de los 45 constructores estáticos. Estuve a punto de ponerme a bisecar
constructores.

**Lo que lo destapó** fue comparar el registro del emulador con el del control
de H2, línea a línea, después de `Loading as homebrew.`:

```
control (funciona)          nuestro NRO
--------------------------  -----------------
Loader GetNpdm: ...         (nada)
Ptc Initialize: ...
Loader LoadNsos: Loading image 0 at 0x8500000...
```

**Ryujinx nunca llegaba a `LoadNsos`.** No es que muriera código nuestro: es que
no se cargaba ninguna imagen. El fallo estaba por encima de todo lo que yo
estaba instrumentando.

**La causa.** Comparando las dos cabeceras NRO campo a campo apareció una única
diferencia estructural, y era en el sitio menos sospechoso:

| campo | hello-ruby-nx (carga) | pokemon-anil (no cargaba) |
|---|---|---|
| tamaño del fichero | 3.520.709 | 17.182.720 |
| `size` en la cabecera | 3.497.984 | 17.182.720 |
| diferencia | **22.725 bytes** | **0** |

En el que funciona, `size` es **menor** que el fichero. Esos 22.725 bytes de
más son la sección **`ASET`**: icono JPEG (6.285 B) y NACP (16.384 B) que
`elf2nro` añade detrás del NRO cuando se le pasan `--icon` y `--nacp`. El
Makefile de plantilla de devkitPro lo hace solo; el mío, escrito a mano, no.

```make
APP_ICON := $(LIBNX)/default_icon.jpg

$(TARGET).nacp:
	nacptool --create "$(APP_TITLE)" "$(APP_AUTHOR)" "$(APP_VERSION)" $@

$(TARGET).nro: $(TARGET).elf $(TARGET).nacp
	elf2nro $< $@ --icon=$(APP_ICON) --nacp=$(TARGET).nacp
```

Con eso, la misma ejecución pasó de silencio absoluto a:

```
Loader LoadNsos: Loading image 0 at 0x0000000008500000...
Application Loaded: Firmware Application Pokemon Anil 4.0 v4.0 [64-bit]
Hid SetupNpad: Connected Controller ProController to Player1
[boot] 1/3 primer constructor estatico — heap y __appInit sobrevividos
[boot] 2/3 ultimo constructor estatico — los 45 pasaron
[boot] 3/3 main() alcanzado
[nx] getcwd -> sdmc:/switch/pokemon-anil
[nx] mkxp.json accesible: true
[nx] Data/Scripts.rxdata accesible: true
```

**Las dos lecciones.** La primera: un NRO sin `ASET` es un binario perfectamente
válido —magic correcto, segmentos correctos, `.init_array` intacto— que
sencillamente no se carga. Ninguna comprobación estática del binario lo habría
detectado, porque no hay nada malo en él.

La segunda es de método: cuando la instrumentación no dice nada, **la
posibilidad de que el fallo esté por encima de donde estás mirando** merece
comprobarse antes de bisecar hacia abajo. La comparación con un control que
funciona, línea a línea, costó dos minutos y señaló el sitio exacto.

### 5.33 ARMv9 en un binario para ARMv8: el traductor se cae antes de ejecutar

La primera excepción de C++ que lanzaba el programa lo mataba. El registro de
Ryujinx daba el motivo:

```
System.NotImplementedException: Unknown MRS 0xD53B2521 at 0x0000000008F9DB78
   at ARMeilleure.Instructions.InstEmit.Mrs(...)
   at ARMeilleure.Translation.Translator.EmitAndGetCFG(...)
```

`0xD53B2521` es `mrs x1, gcspr_el0`, el puntero de la Guarded Control Stack
(FEAT_GCS, ARMv9.4). Está dentro de `_Unwind_RaiseException_Phase2`, en la
libgcc de GCC 16, con el idioma habitual:

```
mov  x16, #1
chkfeat x16          ; HINT #40: NOP en una CPU sin GCS, deja x16 = 1
cbnz x16, sin_gcs    ; y por tanto salta
...
mrs  x1, gcspr_el0   ; nunca se ejecuta en un Cortex-A57
```

El Cortex-A57 de la Switch es ARMv8.0-A: `chkfeat` cae en el espacio HINT no
asignado, se comporta como NOP y la rama de GCS queda muerta. Sustituir
`chkfeat` por un NOP explícito **no arregló nada**, y ahí está lo interesante:
mirando la traza otra vez, el fallo es en `EmitAndGetCFG`, es decir **en
traducción, no en ejecución**. ARMeilleure recorre el grafo de flujo del bloque
entero antes de ejecutar nada, así que una instrucción en una rama muerta lo
tumba igual que si se ejecutara.

Hay que quitar las instrucciones, no la condición. `fixup-arm64.py` recorre los
segmentos ejecutables del ELF tras enlazar y neutraliza 15 instrucciones: 5
`chkfeat`, 3 `gcspopm`, 2 `mrs gcspr_el0`, 2 `mrs tpidr2_el0`, 1
`msr tpidr2_el0` y 2 `smstop` (estas últimas de SME, en las rutinas
`__arm_za_disable` y `__arm_tpidr2_save`). Todas están tras comprobaciones que
en hardware real dan negativo, así que el parche es neutro en la consola y
sólo restaura la respuesta correcta en el emulador.

Detalle que costó un ciclo: el parche no tocaba nada porque el `.nro` no se
regeneraba. `elf2nro` toma el *build-id* de `.note.gnu.build-id`, que un parche
de bytes no altera, así que conviene comprobar el binario desplegado y no sólo
el intermedio.

### 5.34 `require` no encontraba ficheros que `open` sí abría

Con las excepciones funcionando, el gestor de plugins mataba el juego:

```
Error en el Plugin: [Cable Club]
Excepción: LoadError
Mensaje: cannot load such file -- socket
```

`lib/socket.rb` existía, `File.exist?` decía que sí, `File.read` lo leía entero
y `IO.sysopen` devolvía un descriptor —con `O_NONBLOCK` y `O_CLOEXEC`
incluidos—. Sólo fallaba `require`. Envolver `open` con `-Wl,--wrap=open` y
registrar cada `.rb` dio la respuesta de una vez:

```
[open] sdmc:/switch/pokemon-anil/sdmc:/switch/pokemon-anil/lib/set.rb -> -1
```

La ruta está duplicada. `rb_is_absolute_path` es literalmente `*p == '/'` en
las compilaciones POSIX, y el directorio de trabajo en Horizon es
`sdmc:/switch/pokemon-anil`, que no empieza por `/`. Ruby lo trata como
relativo y le antepone el directorio actual **dos veces**: una al construir la
ruta de búsqueda y otra al buscar el fichero.

Poner la ruta absoluta a mano en `$LOAD_PATH` no sirve, y ese fue el segundo
descubrimiento: `rb_construct_expanded_load_path` pasa cada entrada por
`realpath()`, y newlib devuelve la forma canónica **con** el dispositivo,
volviendo a meter el `sdmc:`.

La solución es `-Wl,--wrap=realpath` (`nx/nx_realpath.c`): se quita el prefijo
de dispositivo del resultado. No se pierde nada, porque newlib resuelve las
rutas sin dispositivo contra el dispositivo por omisión, que en homebrew es la
propia SD; se comprobó midiendo que `open("/switch/pokemon-anil/lib/socket.rb")`
devuelve un descriptor válido. Con eso, `set`, `tsort`, `socket` e `io/wait`
cargan.

### 5.35 `fcntl` pertenece a los sockets en libnx

Durante la caza anterior apareció un problema independiente. Medido sobre un
fichero real de la SD:

```
open("lib/socket.rb", O_RDONLY) -> 3        correcto
fstat(3)  -> modo 0100666, S_ISREG          correcto
fcntl(3, F_GETFD) -> 95                     basura
fcntl(3, F_GETFL) -> -1, errno 108          ENOTSOCK
```

libnx implementa `fcntl` dentro de su capa de sockets, para poder poner un
socket en modo no bloqueante; para cualquier otro descriptor la respuesta no
vale. Ruby lo nota en `open_load_file`, que abre con `O_NONBLOCK` y luego llama
a `fcntl(F_GETFL)` para quitarlo: al fallar aborta con
`LoadError: Socket operation on non-socket`.

`nx/nx_fcntl.c` lo envuelve con `-Wl,--wrap=fcntl`. El criterio de reparto es
`fstat`: si el descriptor es un fichero de verdad se atiende ahí, y si no se
delega en libnx, que es quien sabe de sockets. Las respuestas son las que daría
cualquier POSIX sobre un fichero regular; en Horizon no hay `exec`, así que
`FD_CLOEXEC` no significa nada, y los ficheros no bloquean, así que `O_NONBLOCK`
tampoco.

### 5.36 Las constantes de `Encoding` no existían

El propio script de compatibilidad del juego se paraba en su línea 22:

```
Section009:22: uninitialized constant Encoding::UTF_8 (NameError)
```

Y sin embargo `Encoding.find("UTF-8")` devolvía el objeto correcto,
`Encoding.name_list` tenía 16 entradas y `"a".encoding.name` era `"UTF-8"`. Lo
que faltaba eran las **constantes**: `Encoding.constants` sólo tenía las cinco
clases de error.

Quien las crea es `rb_encdb_declare`, desde `enc/encdb.o`. Nuestro
`libruby-static.a` lleva en su lugar `dmyenc.o`, el `Init_enc` vacío que usa
`miniruby`. Las codificaciones integradas —`ascii.o`, `us_ascii.o`,
`unicode.o`, `utf_8.o`— sí están enlazadas y funcionan; sólo falta el registro
de nombres.

Antes de decidir el tamaño del arreglo conté el uso real en los 770 scripts del
juego: 17 `Encoding::UTF_8`, 23 `force_encoding("UTF-8")`, **ninguna otra
codificación y ninguna conversión entre juegos de caracteres**. Así que el
arreglo correcto no es reconstruir Ruby con toda la base de datos de
codificaciones, sino recrear las constantes desde `Encoding.name_list` en
`lib/nx-compat.rb`, con la misma regla de nombres que usa `set_encoding_const`
en `encoding.c`. Quedan 12 definidas.

### 5.37 El juego llamaba a la API de JoiPlay

`preload.rb` —que viene con el juego— llama en su tercera línea a `MKXP.puts`.
En mkxp-z esa constante no existe: hay un módulo `System` y una variable global
`$MKXP`. `MKXP` es la API de **JoiPlay**, el intérprete de Android; el juego se
distribuye también por ahí y sus scripts la usan en dos sitios (el otro,
`MKXP.launch`, lleva el comentario `# Joiplay` al lado).

En vez de tocar `preload.rb` —que conviene dejar idéntico al original para que
una actualización del juego encaje sin fricción— se añade un script anterior:
`"preloadScript": ["lib/nx-compat.rb", "preload.rb"]`. Ahí se define `MKXP` con
`puts` (al registro) y `launch` (no hay navegador al que delegar en Horizon).

### 5.38 Un preload roto fallaba en silencio

`runCustomScript` en `binding-mri.cpp` pasaba `NULL` como estado a
`rb_protect`, es decir, descartaba el resultado. Un preload con un error de
sintaxis fallaba sin decir nada y el síntoma aparecía mucho después y en otro
fichero: pasé un ciclo entero creyendo que mi shim se había cargado cuando no
había llegado ni a compilar. En una consola, donde no hay terminal a la que
mirar, eso es intolerable.

Ahora se recoge el estado y se registra la excepción. El primer arranque tras
el cambio devolvió tres diagnósticos de golpe, dos de ellos —§5.36 y el
`$stdout` de abajo— que no se habrían visto de otra forma.

Relacionado: `$stdout` se redirige en `nx-compat.rb` a un objeto propio que
escribe al registro, con lo que todo el `puts` del juego pasa a ser visible.
Ruby comprueba que el objeto responda a `write` **en el momento de la
asignación**, así que la clase tiene que estar completa antes; crear el objeto
y añadirle métodos después da
`TypeError: $stdout must have write method, Object given`.

Y una lección de fontanería: al principio el registro de Ruby y el de C++ eran
el mismo fichero. No sale bien. El descriptor de Ruby conserva su
desplazamiento en caché y pisa lo que el lado C++ acaba de añadir, de modo que
desaparecen justo las líneas de error que uno quiere leer. Dos ficheros.

### 5.39 Ruby no podía crear hilos

El primer `Thread.new` del juego —uno de nivel superior en el plugin
BoxIntegration— mataba el proceso con un acceso a la dirección 0. La cadena de
símbolos, resuelta con `addr2line` sobre el ELF con símbolos:

```
_EntryWrap -> __thread_entry -> thread_start_func_1 -> rb_raise
           -> rb_class_new_instance -> rb_current_execution_context
```

Leyendo la cadena de texto que `rb_raise` recibía como argumento apareció el
motivo literal: **`ruby engine can initialize only in the main thread`**. Es
`thread_pthread.c:1028`, la rama que se compila cuando `STACKADDR_AVAILABLE`
no está definido. Ruby necesita conocer los límites de la pila de cada hilo
para que el recolector sepa hasta dónde escanear, y lo averigua con
`pthread_getattr_np`, que devkitA64 no trae. Sin ella, cualquier hilo que no
sea el que inicializó el intérprete lanza esa excepción — y la lanza antes de
que el contexto de ejecución del hilo esté montado, por lo que en vez de una
excepción sale un puntero nulo.

Antes de decidir comprobé que no fuera un problema general: una sonda en C creó
un `pthread` desde el hilo principal y otro desde el hilo RGSS, y en ambos
`tpidrro_el0` y las variables `__thread` funcionaban. El problema era sólo la
extensión que falta.

devkitA64 sí trae toda la familia `pthread_attr_*`, incluida
`pthread_attr_setstack`, así que `nx/nx_pthread_np.c` implementa
`pthread_getattr_np` sobre `threadGetSelf()` de libnx, que conoce `stack_mem` y
`stack_sz`. Se rellena el `attr` con la API pública para no depender de la
estructura interna. Ruby sólo la llama con `pthread_self()`, así que no hace
falta resolver un hilo arbitrario.

Queda recompilar `thread.c` con `-DHAVE_PTHREAD_GETATTR_NP=1` y sustituir el
objeto dentro de `libruby-static.a` (`ar r`), sin rehacer Ruby entero. El
guion está en `tmp/rethread.mk`; los `TMPDIR` van dentro del makefile y el
`PATH` en forma POSIX, por §5.27 y §5.22 respectivamente.

### 5.40 …y cuando pudo, se salía de la pila

Con eso, el hilo arrancaba y se caía justo debajo de su propio puntero de pila.
Medido: los hilos que da devkitA64 tienen **127 KiB**, y Ruby reserva 1 MiB con
`alloca` nada más entrar para su pila de máquina virtual.

Ruby sí pide tamaño… pero sólo si `PTHREAD_STACK_MIN` existe:

```c
# ifdef PTHREAD_STACK_MIN
	CHECK_ERR(pthread_attr_setstacksize(&attr, stack_size));
# endif
```

devkitA64 no define esa constante en ningún cabecero, así que Ruby se saltaba
la llamada entera. Comprobé que la petición sí se respeta cuando se hace —pedí
1 MiB y el hilo salió con 1023 KiB— de modo que basta con definirla al
recompilar `thread.c`. Es preferible a bajar los tamaños de Ruby por variable
de entorno: así el intérprete se comporta como en cualquier otra plataforma.

### 5.41 `pipe()` no existe, y Ruby lo dice él mismo

Resueltos los dos anteriores, `Thread.new` ya no se estrella: se **cuelga**. El
hilo arranca, y el intérprete no vuelve a ejecutar nada.

Una sonda en C separó los dos mecanismos de los que depende el planificador de
Ruby:

```
[sinc] pipe() -> -1 (errno 88 = ENOSYS)
[sinc] condattr_setclock(MONOTONIC) -> 0
[sinc] cond_timedwait 50ms -> 116 (ETIMEDOUT)
```

Las variables de condición funcionan perfectamente. Las tuberías no existen. Y
Ruby lo tiene previsto, con estas palabras exactas
(`setup_communication_pipe_internal`):

```c
rb_warn("pipe creation failed for timer: %s, scheduling broken", ...);
```

*scheduling broken*. Sin tubería no hay hilo temporizador, y sin él no hay
quien devuelva el control. **Este es el muro actual.**

El camino es implementar `pipe()` sobre un dispositivo devoptab en memoria
—newlib admite añadir dispositivos con `AddDevice`— con un búfer circular
protegido por mutex y variable de condición, que es justo lo que sí funciona
aquí. Habrá que envolver también `poll`, porque el hilo temporizador de Ruby
espera sobre el extremo de lectura y `poll` en libnx pertenece, otra vez, a la
capa de sockets.

### 5.42 `pipe()` sobre un dispositivo devoptab

La solución al muro anterior no necesita nada del núcleo. Una tubería son cuatro
cosas: un búfer circular, un cerrojo, una variable de condición y dos
descriptores de fichero. Las tres primeras funcionan en Horizon —está medido en
§5.41— y la cuarta la da newlib: `AddDevice()` registra una tabla de operaciones
y `__alloc_handle()` reserva un descriptor que apunta a ella. A partir de ahí
`read()`, `write()`, `close()` y `fstat()` llegan solos, porque `libsysbase` los
despacha por esa misma tabla. Es el mismo mecanismo con el que libnx cuelga sus
sockets, así que no se está inventando nada: se está usando la puerta que ya
estaba.

`nx/nx_pipe.c` la implementa entera. Tres decisiones que no son obvias:

**Un cerrojo global para todas las tuberías, no uno por tubería.** Con cerrojos
individuales, `poll()` sobre varios descriptores obliga a esperar en varias
condiciones a la vez, y eso significa o un hilo por descriptor o una lista de
espera compartida —que es reinventar peor lo que ya se tiene—. Con un cerrojo
global, `poll()` es un bucle trivial: tomar el mutex, mirar todas, dormir en una
sola condición. El precio sería la contención, pero aquí hay tres tuberías en
toda la vida del proceso.

**`fcntl` tiene que distinguir bloqueante de no bloqueante de verdad.** El
`__wrap_fcntl` de §5.35 respondía a `F_SETFL` con un 0 educado que no hacía nada.
Para un fichero de la SD da igual; para una tubería es fatal:
`consume_communication_pipe` de Ruby lee en bucle hasta recibir `EAGAIN`, así que
con `O_NONBLOCK` ignorado se quedaría esperando para siempre en la segunda
lectura. El reparto de `fcntl` pregunta ahora primero si el descriptor es una
tubería, y solo después cae en el criterio por `fstat`.

**`fstat` sobre la tubería no es decorativo.** `rb_update_max_fd`, que Ruby llama
sobre cada extremo recién creado, hace `rb_bug()` si `fstat` contesta `EBADF`. El
dispositivo devuelve `S_IFIFO | 0600`.

También hay que envolver `poll` y `select`, porque en libnx pertenecen —otra
vez— a la capa de sockets. El criterio es el de §5.35: si en la lista no hay ni
una tubería, se delega en libnx sin tocar nada.

Las cuatro propiedades de las que depende Ruby, medidas en la consola:

```
[sinc] pipe() -> 0 (fds 3,4)
[tub]  F_SETFL -> 0 ; read vacia -> -1 errno 11 (EAGAIN=11)
[tub]  poll con datos -> 1 revents 0x1
[tub]  poll vacia 60ms -> 0 en 60 ms
[tub]  poll despertada por otro hilo -> 1 en 41 ms
```

La última es la importante: `poll()` bloqueado despierta cuando otro hilo
escribe. Eso es lo que reparte el GVL. Sin ello el juego avanzaría un fotograma
por cada plazo de espera.

Con las tuberías puestas, `Thread.new` devuelve y el intérprete planifica.

### 5.43 La ventana no se puede redimensionar, y averiguarlo costó un manejador de excepciones

Resuelto lo anterior, el juego dejó de colgarse y empezó a **morir**. Ryujinx
anotaba esto y nada más:

```
ResultCode: 2345-0007    FatalPolicy: ErrorReportAndErrorScreen
Guest CPU registers:  X[00]..X[28] = 0, PC = 0, SP = 0x49ea60a000
```

Los registros son los del proceso `fatal` del sistema, no los nuestros. Salen a
cero porque el emulador imprime el contexto de quien atiende la llamada, no el de
quien la hace. Inservible.

`2345` es `2000 + 345`, y `Module_Libnx = 345`; el `0007` es
`LibnxError_AlreadyInitialized`. Eso acota, pero no señala.

**Primer intento, fallido.** libnx tiene el gancho: en `exception.s`,
`__libnx_exception_entry` carga `__libnx_exception_handler` —símbolo débil sin
definir— y, si vale cero, se va a `__libnx_exception_entry_abort`. Definirlo
debería darnos el volcado. Se definió (`nx/nx_excepcion.c`), con dos
precauciones que no son opcionales: nada de `printf` —el manejador corre sobre
una pila propia y pequeña, y si lo que ha reventado es el montón, la sonda muere
sin decir nada; se formatea a mano, que para hexadecimal son diez líneas— y
`__nx_exception_ignoredebug = 1`, porque si no libnx renuncia al manejador en
cuanto cree que hay un depurador conectado.

No apareció nada. Desensamblando nuestro propio binario se ve por qué: el aborto
de `__libnx_exception_entry` usa el resultado `0xf801`, no `0xf59`. **No era una
excepción de CPU.** Alguien llamaba a la pantalla de error a propósito.

**Segundo intento, también fallido.** Envolver `diagAbortWithResult`. Silencio
otra vez.

**Tercero, el bueno.** Buscar en el desensamblado del binario entero quién llama
a `fatalThrow`. Tres sitios, y los tres en el mismo sitio:

```
switch_swap_buffers
switch_st_framebuffer_validate
switch_create_window_surface
```

Son de Mesa. **El fallo era de gráficos, no de Ruby.** Con `-Wl,--wrap=fatalThrow`
y una traza de pila que recorre la cadena de `x29` restando la base de carga, la
respuesta llegó entera:

```
[exc] fatalThrow res=0xf59 modulo=345 desc=7 desde +0x669068
[exc]   #0  +0x669068   switch_create_window_surface
[exc]   #1  +0x65e3fc   _eglCreateWindowSurfaceCommon
[exc]   #2  +0x3cb8d0   SDL_EGL_CreateSurface
[exc]   #3  +0x351340   SWITCH_SetWindowSize
[exc]   #4  +0x341950   SDL_SetWindowSize
```

`SDL_SetWindowSize`. En Horizon la ventana **es** la pantalla: no se mueve, no
cambia de tamaño, y pedirlo no devuelve un error sino que mata el proceso, porque
el winsys de Mesa para Switch responde a los fallos llamando a `fatalThrow`.
`nwindowSetDimensions` contesta `AlreadyInitialized` sobre una ventana que ya
tiene sus búferes, y ahí se acaba todo.

Y no es un caso raro: Pokémon Essentials pide un cambio de resolución nada más
arrancar, con `Graphics.resize_screen`.

El parche ignora las tres peticiones —redimensionar, mover, centrar— bajo
`__SWITCH__`, pero **mantiene el apretón de manos**: `rqWindowAdjust` lo pone
`requestWindowResize` y hay quien lo espera con `wait()`; sin el `clear()`, el
hilo RGSS se colgaría para siempre. Y publica el tamaño actual en
`windowSizeMsg`, porque quien pide el cambio es `Graphics::resizeScreen`, que ya
ha cambiado la resolución interna y cuenta con que el evento de redimensión acabe
llamando a `recalculateScreenSize`; sin ese aviso, el encaje se quedaría con las
cuentas de la resolución anterior.

La sonda de `--wrap=fatalThrow` y el manejador de excepciones se quedan en el
árbol. Cuestan cero en marcha y son la diferencia entre un código de cuatro
cifras y una traza de pila.

### 5.44 El argumento opcional que no admitía estar ausente

Pasada la pantalla de título, el juego se paró solo con esto en `errorlog.txt`:

```
Excepción: TypeError
Mensaje: Argument 4: Expected fixnum
Game_System:56:in `bgm_play'
[Pantalla de Título Animada] Main Class.rb:586:in `playBGM'
```

`Audio.bgm_play` de mkxp-z acepta cinco argumentos —fichero, volumen, tono,
posición y **pista**, para música multipista—. Pokémon Essentials declara la
pista como `track = nil` y la pasa tal cual:

```ruby
def bgm_play_internal2(name, volume, pitch, position, track = nil)
  Audio.bgm_play(name, vol, pitch, position, track)
```

El formato `"i"` de `rb_get_args` acepta Fixnum y Float, y rechaza `nil` con
`TypeError`. El juego funciona en Windows porque el mkxp-z que trae —2.4.2 en el
commit `d13f35c`, según su propio aviso de versión— lo tolera; el 2.4.2 de
etiqueta que compilamos, no.

Se leen esos argumentos como objeto y se traducen: `nil` significa «no dijo
nada», que es el mismo `-127` que ya usaba por defecto. Son seis métodos, y hay
que hacerlos todos de una vez: al arreglar `bgm_play` el juego avanzó hasta el
siguiente, `bgm_fade`, y murió igual.

Es el problema de fondo del port en una frase: **no basta con que el motor
funcione, tiene que funcionar como el motor concreto para el que se escribió el
juego.**

### 5.45 En un mando de Nintendo, la A no está donde SDL cree

Con la imagen en pantalla y el juego pidiendo «PULSA ENTER», la pregunta ya no
era si dibuja sino si responde. SDL ve el mando sin problemas:

```
[hid] joysticks: 8 | mando abierto: Switch Controller
```

Pero al pulsar el botón **A** de la consola llega el botón **1**, que en SDL es
`SDL_CONTROLLER_BUTTON_B`. No es un fallo: SDL nombra los botones por posición,
al estilo de Xbox —A abajo, B a la derecha, X a la izquierda, Y arriba— y en un
mando de Nintendo las letras están justo al revés.

El mapa de serie de mkxp-z lleva `SDL_CONTROLLER_BUTTON_A → Input::C`, que es
«aceptar». En una Switch eso pone el aceptar en el botón de abajo y el cancelar
en el de la derecha: al revés que cualquier otro juego de la consola. Se cruzan
las dos parejas bajo `__SWITCH__` y la A acepta, la B cancela, como debe ser.

La comprobación está guionizada en `jugar.ps1`, que arranca el emulador, manda
pulsaciones con `keybd_event` —y no con `SendKeys`, que suelta la tecla en el
mismo instante y un juego que lee el mando una vez por fotograma se pierde la
mitad— y toma capturas entre medias.

### 5.46 La captura de pantalla mentía

Con el juego ya dibujando, la primera captura salió descuadrada: la imagen
desplazada unos 300 píxeles a la derecha y cortada por la derecha y por abajo.
Parecía un fallo de encaje del viewport, y se fueron tres ciclos detrás de él:
`nwindowGetDimensions` dice 1920x1080, `appletGetDefaultDisplayResolution` dice
1920x1080, y el viewport que GL entrega recién creado el contexto —que es la
medida que no admite discusión, porque **es** el tamaño de la superficie EGL—
también dice 1920x1080. Las tres coincidían, y las cuentas de mkxp-z sobre ellas
eran correctas: 1440x1080 centrado en (240,0), un 4:3 perfecto con sus dos
franjas negras.

El fallo estaba en `captura.ps1`. `Screen.PrimaryScreen.Bounds` devuelve píxeles
**lógicos**, con el escalado de Windows ya aplicado, mientras que
`CopyFromScreen` copia píxeles **físicos**. Con la pantalla a 2560x1440 y el
escalado al 125%, el guion pedía una imagen de 2048x1152 y copiaba en ella la
esquina superior izquierda de 2048x1152 píxeles reales: no una imagen encogida,
sino **recortada**. Justo por la derecha y por abajo.

Una línea de `SetProcessDPIAware()` antes de leer `Bounds` y la imagen salió
entera y centrada.

La lección no es sobre DPI. Es que **el instrumento de medida también es
software y también puede estar roto**, y que cuando tres fuentes independientes
dicen que el sistema está bien conviene sospechar de quien dice que está mal.

### 5.47 De homebrew a aplicación: el NSP

Un `.nro` se lanza desde el menú homebrew, y eso tiene dos inconvenientes. Uno
es de comodidad: no aparece en el menú HOME, hay que entrar al álbum, esperar al
menú homebrew y buscarlo en una lista. El otro es de fondo: abierto desde el
icono del álbum, el menú homebrew corre como **applet**, y un applet comparte el
presupuesto de memoria con el juego que haya suspendido detrás. Para un juego de
702 MB de recursos con CRuby dentro, eso no es un detalle —y no es una
sospecha: el juego pide 716 MB y un applet recibe unos 448, medido en §5.53—.

Instalado como NSP el juego es una aplicación más: icono propio en el menú
HOME, arranque directo y el presupuesto entero. La primera línea que escribe
ahora es esta:

```
[mem] aplicacion (NSO) | total 3285 MB | usado 3282 MB | monton 3264 MB
```

3,2 GB de montón. `nx/nx_memoria.c` los lee con `svcGetInfo` y con los símbolos
`fake_heap_start`/`fake_heap_end` que `__libnx_initheap` deja en newlib —libnx
no publica el tamaño del montón por API, pero esos dos son los mismos que usa
`sbrk`, así que su diferencia es exactamente lo que `malloc` puede repartir—.

**Un NSP es un PFS0 con tres NCA dentro**: el programa (su ExeFS), el control
(el NACP y los iconos) y los metadatos (el CNMT, que enumera a los otros dos con
sus hashes). Cada NCA va cifrado y firmado con claves de consola, así que hacen
falta las `prod.keys` de tu propia Switch —salen de ella con Lockpick_RCM y de
ningún otro sitio— y, como la firma no es de Nintendo, en la consola hacen falta
sigpatches. Eso ya lo tiene cualquier instalación de Atmosphère que ejecute
homebrew.

**El binario no cambia.** `elf2nso` toma el mismo `pokemon-anil.elf` que
`elf2nro`; el `crt0` de libnx sirve para los dos formatos. Lo único que cambia
de verdad es que **una aplicación no tiene `argv`**, y el port ya estaba
preparado sin saberlo: `nxSetupWorkdir` deducía el directorio de trabajo de
`argv[0]` y caía en la ruta convenida de la SD cuando no lo había. El registro
de la primera ejecución instalada lo dice entero:

```
[nx] mkxp-z arrancando en Horizon OS; argc = 0 argv[0] = (vacio)
[nx] directorio de trabajo: sdmc:/switch/pokemon-anil (reserva)
[nx] mkxp.json accesible: true
```

**El NPDM no se inventa.** Es el manifiesto que declara el ID de programa, los
permisos de sistema de ficheros, los servicios y las llamadas al sistema
permitidas; equivocarse ahí no da un error legible, da un proceso que no
arranca. En vez de escribirlo a mano se parte del `hbl.json` de **nx-hbloader**,
que es el NPDM de aplicación bajo el que ya corre todo el homebrew de la
consola, y se cambian cuatro cosas: el nombre, los tres identificadores de
título, y `application_type` de 2 a 1 —hbloader se declara *applet* porque
suplanta al álbum, y nosotros somos una aplicación de verdad—. Se quitan el
`content_owner_id` del álbum y la entrada `map_region`, que hbloader necesita
para leer la imagen de arranque y nosotros no.

El identificador es `0x05414E494C000000`: el prefijo `05` está fuera del rango
que usa Nintendo, y el resto es `ANIL` en ASCII. Tiene que ser **el mismo** en el
NPDM y en el NACP: hacbrewpack lo lee del NACP —desplazamiento 0x3038— y lo
graba en las cabeceras de los tres NCA, y si el NPDM declarase otro, el cargador
rechazaría el programa.

**Los 702 MB de datos no van dentro del NSP.** Se quedan en la SD, en
`/switch/pokemon-anil`, por tres razones y ninguna es la pereza: el RomFS de un
NCA es de **solo lectura**, y ahí dentro no se podría guardar la partida;
reinstalar 700 MB en cada iteración es inviable; y dejándolos fuera, actualizar
el juego se reduce a copiar ficheros. El NSP pesa **11 MB**.

Un detalle pequeño y visible: el nombre que sale en el menú HOME lleva acentos,
y `nacptool` no puede con ellos —recibe sus argumentos en la página de códigos
ANSI del shell, así que «Pokémon Añil» llega al fichero en Latin-1 y Horizon, que
espera UTF-8, pinta un nombre roto—. `nsp/nacp-utf8.py` reescribe después las
entradas de idioma del NACP, que son 16 bloques de 0x300 bytes: 0x200 de nombre
y 0x100 de autor. Las que `nacptool` dejó vacías se quedan vacías, porque en un
NACP una entrada a cero significa «este idioma no está soportado», no «sin
nombre».

El único componente que no es nuestro es `hacbrewpack`, que construye y cifra
los NCA. Se compila desde fuente en `tools/hacbrewpack/`, y al hacerlo apareció
por cuarta vez el problema de §5.15: GCC pide su directorio temporal a
`GetTempPath()`, acaba en `C:\WINDOWS` y no tiene permiso de escritura. Para las
compilaciones basta `-pipe`, que hace que GCC no cree ficheros temporales; el
enlace final sí los necesita, así que ahí no queda más remedio que decirle dónde:

```bash
cd /c/anilswitch/tools/hacbrewpack
sed -i 's/^CFLAGS = .*/CFLAGS = -O2 -pipe -Wall -std=gnu11/' config.mk
make                                    # compila mbedtls y los objetos
TMP=C:/anilswitch/tmp gcc -o hacbrewpack.exe *.o \
    -L mbedtls/library -lmbedtls -lmbedx509 -lmbedcrypto
```

### 5.48 El arranque tardaba 56 s en preguntar 22.318 veces algo que ya sabía

El juego tardaba más de un minuto en llegar a la pantalla de título, y todos los
indicios señalaban a `createPathCache`, el índice que mkxp-z construye al
arrancar para poder resolver rutas sin distinguir mayúsculas —lo que hace que un
juego escrito en Windows funcione en un sistema que sí las distingue—. Pero
«todos los indicios señalan» no es una medida, así que lo primero fue
cronometrarlo por dentro:

```
[cache] 22318 entradas, 171 directorios | 56065 ms totales
        | 35406 ms en PHYSFS_stat | 139 ms en el resto
        | 20520 ms en PHYSFS_enumerate
```

Dos cosas quedan claras de golpe. La primera: **el trabajo de verdad —pasar a
minúsculas y llenar dos tablas— son 139 ms**. Todo lo demás es sistema de
ficheros. La segunda: no basta con saberlo, porque hay dos culpables posibles y
llevan a soluciones opuestas. Si Horizon es lento leyendo la SD, la única salida
es precalcular el índice al empaquetar y cargarlo de un fichero, con el problema
de que se queda obsoleto en cuanto alguien toca una carpeta. Si el lento es
PhysFS, se puede arreglar de verdad.

`nx/nx_fsprobe.c` recorre el mismo árbol a mano, con `opendir`/`readdir`, en la
misma ejecución:

```
[fs] solo readdir  : 22318 entradas, 171 dirs |   206 ms | d_type desconocido 0 | desacuerdos 0
[fs] readdir + stat: 22318 entradas, 171 dirs | 19040 ms | stat 18912 ms
```

**Doscientos seis milisegundos.** Horizon no tiene ningún problema en recorrer
22.318 ficheros; lo que cuesta es el `stat`, 0,85 ms cada uno porque cada uno es
una llamada IPC al servicio de ficheros. Y ese `stat` sobra: se hace para
averiguar si la entrada es un directorio, que es exactamente lo que `readdir` ya
ha contestado. La newlib de devkitPro declara `_DIRENT_HAVE_D_TYPE` y libnx
rellena el campo siempre —en las 22.318 entradas, **ni un `DT_UNKNOWN` ni un
solo desacuerdo con `stat`**—.

PhysFS lo pregunta igualmente porque su `PHYSFS_enumerate` entrega al callback
el nombre y nada más: quien quiera saber el tipo tiene que volver a preguntar.
Y con 22.318 entradas, volver a preguntar cuesta 35 segundos.

El arreglo es hacer el recorrido nosotros. `nxCacheRapido` construye **las
mismas dos tablas** que `cacheEnumCB` —el mapa de ruta en minúsculas a ruta
real, y la lista de ficheros de cada directorio—, con el mismo criterio de
mayúsculas y recorriendo `PHYSFS_getSearchPath()` en el mismo orden, para que
nada del resto de mkxp-z note la diferencia. Si alguna de las rutas montadas no
es un directorio de verdad —un `.rgssad`, un zip— se devuelve el trabajo a
PhysFS, que es quien sabe abrir eso.

```
[cache] readdir: 22318 entradas, 171 directorios en 300 ms
```

**De 56.065 ms a 300.** Ciento ochenta y siete veces.

De paso, cada línea del registro de arranque lleva ahora delante los
milisegundos transcurridos, que es lo que permite repartir el resto:

```
[     0] [boot] 1/3 primer constructor estatico
[   714] [boot] 4 antes de SDL_Init
[  1432] [boot] 7 mkxp.json leido
[  3255] [boot] 8 initGL OK, hilo RGSS vivo
[  4393] [boot] 10a miembros construidos (shaders compilados)
[  4710] [boot] 10c pathCache construido
[  4826] [boot] 11 SharedState OK, arrancando el interprete Ruby
```

El intérprete arranca a los **4,8 s**, donde antes tardaba más de sesenta. Lo
que queda por delante ya no es del port: son los 770 scripts de Pokémon
Essentials y sus 320 plugins compilándose, y eso es trabajo de Ruby.

### 5.49 La consola sale de la base y no pasa nada

Quedaba pendiente el cambio en caliente entre portátil y sobremesa, y la idea de
partida era que habría que redimensionar algo —lo cual, después de §5.43, sonaba
a problema serio: la ventana de Horizon no se puede redimensionar sin matar el
proceso—.

La pregunta de verdad es más concreta: cuando la consola sale de la base, ¿cambia
la **superficie** donde Mesa dibuja, o solo cambia la salida de vídeo? Hay dos
fuentes que contestan a cosas distintas y hasta ahora solo se anotaba una. Ahora
`nx/nx_pantalla.c` consulta y registra las dos. En sobremesa:

```
[gfx] inicial: nwindow 1920x1080 | applet 1920x1080 | modo sobremesa
[gfx] viewport inicial 0 0 1920 1080
```

Y arrancando el emulador con `docked_mode: false`, que es lo más parecido a
sacar la consola de la base:

```
[gfx] inicial: nwindow 1920x1080 | applet 1280x720 | modo portatil
[gfx] viewport inicial 0 0 1920 1080
```

**La superficie no cambia.** `appletGetDefaultDisplayResolution` baja a 1280x720
porque describe la pantalla física, pero `nwindowGetDimensions` —y el viewport
que entrega OpenGL, que es la medida que no admite discusión— siguen diciendo
1920x1080. Horizon entrega siempre un búfer de 1080p y lo escala al panel de
720p. El juego dibuja igual en los dos modos y no hay nada que hacer.

Eso deja sin sentido el plan original, y de paso corrige el comentario que
encabezaba `nx_pantalla.c` desde H4, escrito antes de §5.46: decía que el búfer
en portátil medía 1280x720, y no es verdad.

Aun así se deja puesto el mecanismo. `nx_pantalla_cambio()` se suscribe a
`appletGetDefaultDisplayResolutionChangeEvent` y `Graphics::checkResize` lo
consulta **una vez por segundo** —una espera con plazo cero, no un IPC por
fotograma—; si algún día la superficie cambiara de verdad, el juego publicaría
el tamaño nuevo en `windowSizeMsg` y `recalculateScreenSize` haría el resto, que
es el mismo apretón de manos de §5.43. Y, sobre todo, quedaría escrito en el
registro. Cuesta prácticamente nada y es la diferencia entre enterarse y dibujar
fuera de sitio.

La advertencia de siempre: esto está medido en Ryujinx. Que el emulador entregue
1080p en modo portátil es coherente con cómo funciona el compositor de Horizon,
pero la consola es la consola.

### 5.50 El juego pedía que escribieras tu nombre con un teclado

Con el arranque ya en veinticinco segundos, guionizar una partida entera dejó de
ser un disparate, y el objetivo era llegar hasta un punto de guardado. La
secuencia iba bien —título, menú, pantalla de controles, la introducción del
profesor Oak entera— hasta que apareció esto:

```
¿Tu nombre?

Escribe texto usando el teclado. Pulsa
Enter para confirmar, o Esc para cancelar.
```

En una Switch no hay teclado. Y esto no es una incomodidad: es un **callejón sin
salida**, porque la partida no puede empezar sin nombre. Lo peor es cómo se
manifiesta: no hay error, no hay excepción, `errorlog.txt` sigue vacío y el juego
sigue a 45 fps dibujando tan contento. Simplemente no avanza. Un port puede estar
perfecto por dentro y el juego ser injugable, y ningún registro te lo va a decir;
sólo jugarlo.

Pokémon Essentials trae **dos** pantallas para escribir un nombre:

| | |
|---|---|
| `PokemonEntryScene` | La del teclado físico. Es la de por defecto. |
| `PokemonEntryScene2` | La rejilla de caracteres de siempre, con cursor, mayúsculas, acentos y un botón OK. Pensada para un mando. |

`pbEnterText` elige entre ellas mirando `$PokemonSystem.textinput`, un ajuste del
menú de opciones. Vale 0 de fábrica, y 0 es la del teclado. De paso, el juego se
contradice a sí mismo: en `0313_UI_Options.rb` el ajuste está comentado como
`(0=cursor, 1=keyboard)` y en `0323_UI_TextEntry.rb` el `if` trata el 0 como
teclado. Manda el `if`.

`lib/nx-teclado.rb` envuelve `pbEnterText` y cambia el ajuste **en el momento de
usarlo**. Se toca el ajuste en vez de duplicar el código de la pantalla: así el
que decide sigue siendo `pbEnterText`, y si Essentials cambia esa lógica mañana,
el parche sigue valiendo.

El problema interesante es *cuándo* aplicarlo. El preload corre antes de que se
carguen los scripts del juego, así que ahí `pbEnterText` todavía no existe. La
solución es engancharse a `Graphics.update` —que corre en todas las pantallas
del juego— y aplicar el parche en la primera llamada en la que las clases ya
aparecen.

La primera versión hacía además una floritura: desengancharse acto seguido,
devolviendo `update` a su alias original para no dejar una llamada de más en el
camino de cada fotograma. Reabrir la clase singleton de `Graphics` desde dentro
del propio método que se está ejecutando salió mal, y salió mal de la peor
manera: la excepción se comió el `Graphics.update` de ese fotograma, el juego se
quedó congelado en la pantalla de controles y **no escribió ni una línea** —ni
`errorlog.txt`, ni traza, nada—. Cuatro capturas idénticas byte a byte fueron la
única pista.

La versión buena hace tres cosas menos elegantes y más sensatas. No toca la clase
singleton en marcha —una comprobación booleana por fotograma no le cuesta nada a
nadie—. Envuelve todo el parche en un `rescue Exception` que registra el fallo y
se marca como hecho, porque **lo que corre en el camino de cada fotograma no
tiene derecho a lanzar excepciones**. Y se marca como hecho —y registra— **antes**
de tocar nada, no después: si el parche llegara a aplicarse dos veces, el segundo
`alias_method` apuntaría nuestro propio envoltorio a sí mismo y la primera
llamada a `pbEnterText` se quedaría dando vueltas para siempre. En un parche que
vive dentro del bucle de dibujo, dar por hecho que se llega al final es
justamente lo que no hay que hacer.

Comprobado sobre el juego: la introducción llega a «¿Tu nombre?» y aparece la
rejilla de caracteres, se escribe con el mando, el botón X salta a OK y la
partida continúa (`docs/capturas/nom2-b-letras.png`).

Queda pendiente algo más elegante: Horizon tiene su propio teclado en pantalla
(`swkbd`), que es lo que usa cualquier juego de la consola para pedir un nombre.
Llevarlo a mkxp-z significa abrir `swkbdShow` desde una binding y devolver el
texto como eventos `SDL_TEXTINPUT`, que no es difícil pero es otra tarde. La
rejilla ya está escrita, ya está pensada para un mando y cuesta sesenta líneas.

### 5.51 «No he podido guardar» significaba «no lo he intentado»

Con el nombre resuelto, la partida llega al mundo y ya se puede probar lo único
que faltaba del bucle principal. Guardar desde el menú de pausa exige navegar
por él con el mando, y eso son varios minutos de guion por intento, así que la
sonda `lib/nx-guardar-ya.rb` llama directamente a `Game.save`, que es
exactamente lo que llama el menú. Primer resultado:

```
[guardar] Game.save -> false en 0 ms
[guardar] sdmc:/switch/pokemon-anil/Game.rxdata: existe=false
```

Falso, y en **cero milisegundos**. Un fallo de escritura en la SD tarda algo;
cero significa que ni lo ha intentado. Y en efecto: Pokémon Añil trae el plugin
*Multi Save*, que redefine `Game.save` entera con otra firma y otra primera
línea:

```ruby
def self.save(slot = nil, auto = false, safe: false)
  slot = $player.save_slot if slot.nil?
  return false if slot.nil?
```

En una partida recién empezada, que no se ha guardado nunca, `save_slot` es
`nil` y la función se va por la puerta de atrás. El port no tenía nada que ver.
El plugin además cambia los nombres de los ficheros: en vez de `Game.rxdata`,
`Auto 1.rxdata` y `Partida 1.rxdata` —**con espacio**, que en un sistema de
ficheros ajeno es exactamente el tipo de detalle que conviene comprobar y no
suponer—.

Hay una lección de método aquí, y no es sobre el plugin. El `Game.save` de
Essentials envuelve la escritura en:

```ruby
rescue IOError, SystemCallError
  $game_system.save_count -= 1
  return false
```

Para el jugador está bien: mejor un «no se pudo guardar» que una pantalla de
error. Para averiguar **por qué** no se pudo, ese `rescue` es exactamente lo que
hay que saltarse. La sonda pasó a llamar a `SaveData.save_to_file` sin red, con
su propio `rescue` que registra la clase, el mensaje y las seis primeras líneas
de la traza. Un booleano no es un diagnóstico.

### 5.52 El registro perdía siempre las últimas líneas

Al comprobar el parche de §5.50 en la configuración de producción apareció algo
que no encajaba: `lib/nx-teclado.rb` se cargaba, su envoltorio de
`Graphics.update` se instalaba y se llamaba —los tres hechos, comprobados con
sondas—, pero la línea que confirmaba el parche no salía en el registro. Y con
`lib/nx-trazas.rb` cargado también, sí salía.

Un parche que funciona o no según qué **otro** fichero esté cargado suena a
problema de orden o de ámbitos, y se fueron tres iteraciones detrás de eso:
reescribir el parche con `send(:define_method)` en vez de reabrir la clase,
mover el `@hecho = true`, envolverlo todo en `rescue Exception`. Nada cambió.

Lo que lo delató fue instrumentar a mano: escribiendo a un fichero **aparte**,
abierto y cerrado en el momento, todo se veía perfectamente —incluido un
`NX.log` de prueba hecho justo ahí, que llegaba a `mkxp-ruby.log` sin problema—.
Lo que faltaba no era la ejecución: era el fichero.

`NX.log` abre `mkxp-ruby.log` una vez, le pone `sync = true` y no lo cierra
nunca, porque el proceso no termina: lo mata el emulador. Y `sync = true` quita
el búfer **de Ruby**, no el de debajo. En Horizon, `write` deja los datos en la
caché del sistema de ficheros y no bajan a la SD hasta que alguien lo pide. Sin
un cierre, las últimas líneas se quedaban en el aire.

Por eso dependía de `nx-trazas.rb`: esa sonda escribe una línea cada 300
fotogramas, y cada escritura suya acababa arrastrando la anterior. Sin ella, la
última línea escrita era justamente la que se quería leer.

```ruby
$nx_log.write(msg.to_s + "\n")
$nx_log.fsync          # baja hasta fsFileFlush
```

Una línea. Y explica de paso varios «el registro se corta aquí» de los hitos
anteriores, que se habían atribuido a que el juego se colgaba en ese punto.

El lado C nunca tuvo el problema, y no por prudencia sino por casualidad:
`nx_boot_trace` abre, escribe y **cierra** en cada llamada —se hizo así para no
depender de que el montón siguiera vivo (§H2)—, y cerrar vacía la caché. El
fichero de arranque siempre estuvo completo; el de Ruby, nunca.

### 5.53 Cuánta memoria gasta el juego de verdad, y por qué el applet no vale

Quedaba una afirmación de §5.47 sin comprobar: que el NSP hace falta porque un
applet no tiene memoria suficiente. Era razonable y no estaba medida, que es
otra manera de decir que no se sabía.

El número que hay en el registro no sirve para contestarla:

```
[mem] aplicacion instalada (NSO) | total 3285 MB | usado 3282 MB | monton 3264 MB
```

3.282 MB usados de 3.285 **desde el primer instante**, y diría lo mismo con el
juego cerrado: `__libnx_initheap` mapea el montón entero al arrancar, así que
`UsedMemorySize` mide lo que libnx ha reservado, no lo que el juego gasta. Es el
techo, y el techo ya se conocía.

Lo que hacía falta es el suelo, y para eso el único contador honesto es
`mallinfo().uordblks`: bytes repartidos de verdad por `malloc`. En Horizon eso
**incluye los búferes de la GPU** —`nvmap` no reserva memoria propia, mapea la
del proceso— y deja fuera las pilas de los hilos, que libnx pide aparte. Es una
cota inferior, pero es la única medible y va sobrada para la pregunta.

La marca de agua se toma una vez por segundo desde el hilo de dibujo,
aprovechando el mismo latido que ya usaba el cambio de resolución (§5.49), y
sólo se anota cuando el pico sube un escalón de 32 MB. Así el registro no se
convierte en el cuello de botella y queda con **una línea por cada vez que el
juego pide más sitio**, que es justo la forma que interesa:

```
                                     guionizado hasta un combate     quieto en el titulo
[    55] [mem] aplicacion (NSO), monton 3264 MB
[ ~14 s] [mem] pico del monton              361 MB                        361 MB
[ ~17 s] [mem] pico del monton              637 MB                        639 MB
[ ~39 s] [mem] pico del monton              683 MB                        693 MB
[ ~78 s] [mem] pico del monton              716 MB                        743 MB
```

Dos ejecuciones. La primera, guionizada de punta a punta: título, menú,
introducción de Oak, el nombre por la rejilla (§5.50), el mapa y un combate
salvaje; los 716 MB caen con Pikachu contra Pidgey en pantalla, comprobado en la
captura. La segunda no hace **nada**: se queda en la pantalla de título los 76 s
sin que nadie toque un botón, y llega más alto, a 743 MB.

Que el caso ocioso gane al que juega dice qué clase de crecimiento es este. No
es el combate: es la caché de texturas de mkxp-z, que acumula mientras haya algo
animado delante, y la pantalla de título lo está. El pico no es un pico, es una
pendiente.

Y de ahí sale la frase que de verdad importa, que no es la del combate sino la
del segundo renglón: **a los 17 segundos ya va por 637 MB**, con el juego recién
arrancado y antes de que nadie haya pulsado nada. Un menú homebrew abierto desde
el icono del álbum recibe unos **448 MB**. No es que el juego no quepa cuando se
pone exigente; es que revienta el presupuesto de un applet en la pantalla de
título y no hay forma de jugar que lo evite. **No cabe**, y no por poco.

El NSP deja de ser una comodidad y pasa a ser el camino; la única alternativa en
la consola es abrir el menú homebrew *suplantando un título* —mantener R al
lanzar un juego—, que hereda el presupuesto de una aplicación.

Falta la otra mitad del diagnóstico: saber en cuál de los tres casos se está
corriendo. `envIsNso()` no basta, porque separa el NRO del NSO y lo que decide
la memoria es otra cosa —un NRO puede correr con memoria de aplicación—. El
discriminador es `appletGetAppletType()`, y la primera línea del registro dice
ahora cuál de los tres es, incluyendo un aviso explícito cuando es el malo:

```c
case AppletType_LibraryApplet:
    return "homebrew (NRO) como applet — MEMORIA REDUCIDA";
```

Y aquí está el límite del emulador, dicho sin rodeos: **este número no se puede
comprobar en Ryujinx.** Lanzando un `.nro` desde la línea de órdenes el emulador
no pasa el contexto ABI del homebrew, libnx concluye que es un NSO y reparte los
3,2 GB conteste lo que conteste `appletGetAppletType`. Ryujinx no modela los
presupuestos. Los 716 MB sí son medida buena —son bytes que el juego pidió—;
cuál de los tres presupuestos le tocan enfrente, eso sólo lo dice la consola.

### 5.54 La música se paraba sola y no volvía

Primer informe de la consola jugando de verdad: tirones de dos o tres segundos
al elegir algunas opciones, y en algún momento **la música de fondo se para y no
vuelve**, mientras los efectos de sonido siguen sonando. Sin `errorlog.txt`: no
era una excepción de Ruby.

Que los efectos sobrevivan y la música no ya señala dónde mirar. Los efectos se
cargan enteros en memoria (`SoundEmitter`); la música se **transmite** desde el
fichero según suena, en un hilo que va rellenando búferes de OpenAL. Sólo lo
segundo depende de que la tarjeta conteste a tiempo.

La cadena entera, de abajo arriba. En `vorbissource.cpp`:

```cpp
long res = ov_read(&vf, bufPtr, canRead, 0, sizeof(int16_t), 1, 0);
if (res < 0)
{
    /* Read error */
    retStatus = ALDataSource::Error;
    break;
}
```

Cualquier negativo es un error. Pero `ov_read` devuelve **`OV_HOLE` (-3)** para
algo que no es un fichero roto: un hueco en el flujo —una página que no llegó a
tiempo, o llegó mal—, y libvorbis lo documenta como **recuperable**: se vuelve a
leer y se sigue. Tratarlo como fatal cuesta lo siguiente, en `alstream.cpp`:

```cpp
status = source->fillBuffer(buf);
if (status == ALDataSource::Error)
{
    sourceExhausted.set();
    return;              /* <- el hilo de streaming se sale para siempre */
}
```

El hilo muere; después `checkStopped()` ve la fuente parada con
`sourceExhausted` puesto y deja el estado en `Stopped`. **La música no vuelve
hasta que algo pida otra distinta.** Que es exactamente el síntoma.

Y explica por qué el emulador nunca lo enseñó: allí la lectura sale casi gratis
y no hay huecos. Sobre una SD de verdad, con el juego pidiéndole texturas a la
vez, los hay.

El arreglo es reintentar, acotado para que un fichero de verdad roto no deje el
hilo dando vueltas:

```cpp
if (res == OV_HOLE && ++huecos <= 8)
    continue;
```

Un chasquido en vez de quedarse sin música. La lección es la de siempre en este
port, y van varias: **un fallo transitorio tratado como permanente es peor que
el fallo.** El código no estaba mal escrito para un PC, donde `OV_HOLE` no pasa
nunca; estaba escrito dando por hecho un sistema de ficheros que contesta.

### 5.55 Un menú costaba dos mil llamadas al sistema

Los tirones son la otra mitad del informe, y admiten dos explicaciones que piden
arreglos opuestos: o la tarjeta es lenta leyendo, o la CPU es lenta
descomprimiendo. Adivinar cuál habría sido apostar, así que `nx/nx_tirones.c`
las separa. Cada lectura pasa por un único embudo —`SDL_RWopsRead`, por donde va
todo: mapas, sprites, música— y ahí se suma el tiempo; al cerrar el fotograma se
comparan las dos cifras. Sólo se anotan los fotogramas que pasan de 250 ms.

El primero que salió lo dijo casi todo:

```
[tiron] marco 1039 ms | 4 ms en 1969 lecturas sobre 41 ficheros
```

**1.969 lecturas sobre 41 ficheros.** Cuarenta y ocho lecturas por fichero.

No es raro y no es culpa de nadie: libpng no lee un PNG de una vez, lee la
firma, luego cada cabecera de trozo, luego cada trozo. En un PC eso es gratis
porque debajo hay un búfer. Aquí no lo hay: **mkxp-z nunca llama a
`PHYSFS_setBuffer`**, y PhysFS no pone búfer por su cuenta, así que cada una de
esas 1.969 lecturas baja tal cual al sistema de ficheros.

Y en Horizon una lectura de fichero es una IPC, que cuesta **0,85 ms medidos**
—el mismo número con el que se arregló el arranque en §5.48—. 1.969 × 0,85 ms =
**1,7 segundos**. En un fotograma. Eso son los dos y tres segundos de
congelación al abrir un menú, y son 41 ficheros: una pantalla normal.

El arreglo es una línea en el sitio por el que pasan todas las aperturas:

```cpp
PHYSFS_setBuffer(handle, 64 * 1024);
```

64 KiB porque la mayoría de los recursos del juego caben enteros, y entonces el
fichero pasa a ser **una** lectura en vez de cuarenta y ocho. El tiempo dentro
de lecturas en ese mismo fotograma bajó de 59 ms a 4 en el emulador, quince
veces; en la consola, donde cada lectura evitada son 0,85 ms de verdad, el
reparto es otro.

Conviene decir qué está medido y qué no. Medido: las 48 lecturas por fichero,
los 0,85 ms por IPC (§5.48) y la caída de 59 a 4 ms. Deducido: que el producto
de los dos primeros es el tirón. El emulador **no puede** confirmarlo, porque
allí la lectura no cuesta y el mismo fotograma seguía tardando 1.039 ms por
trabajo de CPU. Quien lo confirma o lo desmiente es la consola, y ahora el
instrumento para leerlo ya está puesto en ella.

### 5.56 Tres núcleos usados como uno (el principal, al menos)

Tercera sospecha del mismo informe: la Switch tiene cuatro A57 y le presta tres
a las aplicaciones, pero el NPDM declara `"default_cpu_id": 0` y en libnx crear
un hilo con `cpuid = -2` significa «el núcleo por defecto del proceso».
`SDL_CreateThread` —por donde pasan todos los hilos de mkxp-z— no pide ninguno
en concreto. La conclusión parecía inmediata: todo en el núcleo 0.

`nx/nx_nucleos.c` la comprobó antes de arreglarla, anotando cómo estaba cada
hilo **antes** de tocarlo. Y la conclusión inmediata era medio falsa:

```
[nucleo] principal: corria en 0 | preferido 0 mascara 0x1 -> preferido 0 mascara 0x7 (OK)
[nucleo] rgss     : corria en 1 | preferido -1 mascara 0x7 -> preferido -1 mascara 0x7 (OK)
[nucleo] musica   : corria en 2 | preferido -1 mascara 0x7 -> preferido  2 mascara 0x7 (OK)
```

El hilo **principal** sí estaba clavado: máscara `0x1`, un solo núcleo. Los
hijos, no —salen con `0x7` y sin preferencia, y de hecho el de RGSS estaba
corriendo en el 1—. Así que la mitad del diagnóstico era correcta y la otra
mitad me la habría inventado.

Lo que se hace ahora son dos cosas distintas y conviene no confundirlas.
**Ensanchar la máscara** del hilo principal a los tres núcleos es darle permiso
al planificador para repartir; Horizon planifica por prioridad sobre el núcleo
preferido y deja que otro de la máscara recoja el hilo cuando aquél está
ocupado. **Fijar un preferido** es decidir por él. Sólo se hace lo segundo con
la música, y con motivo: ese hilo únicamente tiene que rellenar búferes a
tiempo, y no debe competir por gusto con quien está descomprimiendo un PNG. Con
`OV_HOLE` arreglado (§5.54) llegar tarde ya sólo costaría un chasquido en vez de
la canción entera, pero mejor ninguno.

Detalle que sólo se ve mirando el registro de una partida larga: la línea
`[nucleo] musica` aparece **una vez por cada canción**. Cada BGM nueva levanta
su propio hilo de streaming, así que el reparto hay que hacerlo en la entrada
del hilo y no una vez al arrancar.

### 5.57 La música no se paraba: volvía muda

El arreglo de `OV_HOLE` (§5.54) era correcto y no era el fallo. El segundo
informe de la consola lo dejó claro al traer un dato que el primero no tenía:
*«la música se quitó justo cuando agarré el primer objeto»*.

Eso ya no es un hueco en la tarjeta. Es un **disparador determinista**, y coger
un objeto en RPG Maker hace una cosa muy concreta: suena un **ME** —*Music
Effect*, la fanfarria—, y un ME no se mezcla con la música de fondo: la silencia,
suena solo, y al acabar la devuelve. Ese relevo lo lleva una máquina de estados
de cuatro estados en un hilo aparte, `meWatchFun` en `audio.cpp`. Y en la rama
que devuelve la música:

```cpp
if (sState == ALStream::Paused) {
    /* BGM is paused. -> FadeInBGM */
    track->stream.play();
    meWatch.state = BgmFadingIn;      /* <- se asigna aqui... */
}
else {
    track->setVolume(AudioStream::External, 1.0f);
    if (!track->noResumeStop)
        track->stream.play();
}

meWatch.state = MeNotPlaying;         /* <- ...y se pisa seis lineas despues */
```

La asignación de fuera del `if` machaca la de dentro, siempre. No hay camino en
el que `BgmFadingIn` sobreviva.

Lo que lo convierte en un fallo audible y no en un detalle es lo que hace el
estado anterior: `BgmFadingOut` **deja el volumen en 0** antes de pausar la
pista, porque contaba con que `BgmFadingIn` lo devolviera a 1. Saltándoselo, la
música se reanuda —`stream.play()` sí se llama— pero **a volumen cero**. No está
parada: está sonando muda, y así se queda para siempre, mientras los efectos de
sonido siguen oyéndose porque esos no pasan por aquí.

El arreglo es decidir el estado **después** del bucle, y con varias pistas basta
con que una necesite subir:

```cpp
meWatch.state = hayQueSubir ? BgmFadingIn : MeNotPlaying;
```

Comprobado con `lib/nx-me-ya.rb`, que pone música, le echa una fanfarria encima
y espera, dos veces seguidas:

```
[me] fanfarria terminada -> BgmFadingIn (se devuelve el volumen)
[me] fanfarria terminada -> BgmFadingIn (se devuelve el volumen)
```

Dos cosas que dejar dichas.

La primera es por qué sobrevivió a todas las pruebas. Se guionizó el título, el
menú, la introducción, la entrada del nombre, el mapa, un combate y el guardado
—y **nunca se recogió un objeto**. El fallo no estaba escondido: estaba en el
único camino que a nadie se le ocurrió recorrer. Las pruebas guionizadas cubren
lo que uno ya sabe que hay que probar, y por eso no sustituyen a jugar.

La segunda es sobre el diagnóstico anterior. Con «la música se para y los
efectos no» había dos explicaciones compatibles con los síntomas, y elegí la del
sistema de ficheros porque el port entero venía siendo eso. El dato que
desempataba —*cuándo* se paraba— no estaba en el primer informe, y no lo pedí.
Conviene recordarlo: **«se paró de repente» y «se paró al coger un objeto» son
el mismo síntoma con distinta información, y llevan a sitios distintos.**

### 5.58 Un fichero en vez de 22.148

Copiar el juego a la tarjeta es el único paso del port que hace el jugador, y
era el más largo de todos: **668 MB repartidos en 22.148 ficheros**. Lo que
cuesta ahí no son los bytes. Cada fichero es una entrada de directorio, una
cadena de clusters y una escritura de la tabla de FAT32, y una tarjeta que
escribe 40 MB/s en un fichero grande se arrastra copiando miles de ficheros de
30 KB. Peor: una copia interrumpida a mitad deja una carpeta que no se
distingue de una completa, y el síntoma es el de siempre —pantalla negra.

Así que los recursos pueden viajar dentro de **un solo `anil-datos.zip`**, que
el `.nro` monta al arrancar. No hay motor nuevo que escribir: PhysFS ya sabe
leer un zip —el archivador viene compilado en el `libphysfs` de portlibs— y
mkxp-z ya monta un `.rgssad` si lo encuentra al lado del juego. Son doce líneas
en `sharedstate.cpp`, y las dos decisiones que llevan dentro son las que
importan:

**Almacenado, no comprimido.** De los 668 MB, 535 ya son PNG y OGG, y los
`.rxdata` llevan zlib dentro: comprimir ahorra un 5%. Y se paga dos veces, las
dos en el peor sitio. Una entrada comprimida obliga a PhysFS a pasar cada
lectura por `inflate` en vez de leer el fichero a un desplazamiento; y al buscar
hacia atrás dentro de ella, PhysFS no puede saltar, **rebobina y vuelve a
inflar desde el principio de la entrada**. El juego busca hacia atrás cada vez
que un OGG de música vuelve a su punto de bucle, y son ficheros de varios megas.
Guardado en claro, leer del contenedor es leer de un fichero a otro sitio, y ahí
se acaba el coste.

Esto tiene una consecuencia práctica que costó descubrir: **el
`CompressionLevel.NoCompression` de .NET Framework no almacena.** Sigue usando
deflate (método 8) con bloques sin comprimir, y el fichero sale incluso cinco
bytes más grande. Se vio al inspeccionar el zip de prueba: las 26 entradas,
todas con método 8. Por eso `Empaquetar.ps1` no usa `ZipArchive` y escribe el
zip a mano —cabecera local, índice central y registro final— con noventa
renglones de C# que `Add-Type` compila al vuelo. Sigue sin hacer falta instalar
nada, y el resultado lo leen sin queja el `ZipArchive` de .NET, el `zipfile` de
Python y el `unzip` de Info-ZIP, que es la única forma de saber que la consola
también podrá.

**Delante de `"."`, no detrás.** PhysFS resuelve cada ruta recorriendo los
puntos de montaje en el orden en que se montaron, y preguntar al directorio de
la tarjeta por un fichero que no está ahí cuesta la misma IPC de 0,85 ms que si
estuviera (§5.48). Con la carpeta delante, las 22.148 rutas del juego pagarían
ese fallo antes de encontrarse en el contenedor —no sólo al construir el
`pathCache`, sino en cada apertura de la partida—. Con el contenedor delante, el
acierto es una consulta a una tabla en memoria y el fallo barato lo paga el
puñado de ficheros que siguen sueltos: `mkxp.json`, `lib/`, las partidas
guardadas. Es además lo que mkxp-z ya hacía con el `.rgssad`, así que no hay dos
criterios.

Medido en el PC: el contenedor se construye en **36,7 s** y sale de 22.186
entradas (22.035 ficheros y 151 directorios) con los mismos 651 MB dentro,
byte a byte idénticos tras extraerlos. En un NVMe con la caché caliente
—el caso más favorable a los ficheros sueltos— `robocopy /MT:8` necesita 6,9 s
para el árbol y el fichero único se copia de una pasada.

Y medido en Ryujinx, que es donde se vio lo que costaba de verdad:

```
[   296] [ OK  ] anil-datos.zip (653 MB, 22186 entradas)     ← el inventario, 24 ms
[  4102] [boot] 10a miembros construidos
[ 12521] [boot] 10a+ contenedor anil-datos.zip montado       ← 8,4 s en montar
[ 18101] [boot] 10c pathCache construido                     ← 5,6 s en indexar
[ 18174] [boot] 11 SharedState OK, arrancando el interprete Ruby
```

**Trece segundos y medio de arranque**, contra unos 600 ms que costaba lo mismo
con las carpetas sueltas. Y el reparto dice dónde están, porque ninguno de los
dos es el trabajo:

- **Montar: 8,4 s.** PhysFS lee el índice central entrada por entrada y campo
  por campo —`io->read` de cuatro bytes, y el nombre *byte a byte*— y con 22.186
  entradas eso son cientos de miles de lecturas diminutas. El mismo problema que
  §5.55, en otro sitio: no es el tamaño, es la cuenta de llamadas.
- **Indexar: 5,6 s.** `nxCacheRapido` se rinde a propósito cuando algo montado no
  es un directorio de verdad —un zip no se recorre con `opendir`— y el índice lo
  construye PhysFS. Lo bueno: sus 22.186 `PHYSFS_stat` son ya consultas a memoria
  y no IPC, y por eso el desglose dice `193 ms en PHYSFS_stat`. Lo malo: los otros
  5,4 s se van en `PHYSFS_enumerate`, que para cada uno de los 171 directorios
  recorre la lista entera de entradas.

Las dos tienen el mismo arreglo y es el que §5.48 ya aplicó una vez: hacer el
recorrido nosotros. El índice central de un zip es una tabla plana con nombre,
tamaño y desplazamiento; leerlo de una pasada y llenar las dos tablas del
`pathCache` es exactamente lo que `nxCacheRapido` hace con `readdir`. **Hecho en
§5.63**: 33 s en la consola pasaron a 185 ms en el emulador.

En la consola no está medido todavía: ni la copia real a la tarjeta ni estos dos
tramos, que aquí los mueve el JIT de Ryujinx sobre un x86 y allí un Cortex-A57 a
1 GHz. Las líneas `[boot] 10a+` y `[cache]` del registro lo dicen.

Las carpetas sueltas siguen funcionando y siguen siendo la forma de parchear un
gráfico a mano: `Empaquetar.ps1 -Contenedor carpetas`, o la casilla sin marcar.
Lo que no se puede es tener las dos y esperar que gane la carpeta.

### 5.59 Tres fallos distintos, la misma pantalla negra

Cuando el juego no arranca en la consola, lo que ve el jugador es que el menú
homebrew vuelve. Siempre igual, y son tres cosas que no tienen nada que ver:

1. Los datos no están donde el `.nro` los busca, o la copia a la tarjeta se
   cortó por la mitad.
2. El `.nro` se lanzó como applet de biblioteca, con 448 MB, y el juego necesita
   unos 700 (§5.53).
3. Un fallo de verdad del motor: GL, PhysFS, Ruby.

mkxp-z distingue los tres —tiene mensajes concretos para cada uno— pero los
cuenta llamando a `SDL_ShowSimpleMessageBox`, que en el SDL de Horizon **no
está implementado: devuelve −1 y no pinta nada**. De ahí que todos se vean
iguales, y de ahí que el único diagnóstico posible fuera sacar la tarjeta y leer
`mkxp-boot.log` en el PC.

`nx/nx_aviso.c` pinta ese informe en la pantalla, con la consola de libnx. Son
tres piezas:

- **La revisión del inventario**, antes de `SDL_Init`. Comprueba lo que hace
  falta —el contenedor o las carpetas, `mkxp.json`, `lib/nx-compat.rb`,
  `lib/socket.rb`— y si algo falta lo enseña con la ruta donde estaba mirando y
  los tres pasos para arreglarlo. Va antes de SDL por dos razones: la consola de
  libnx y SDL no pueden tener la ventana por defecto a la vez, y si faltan los
  datos no hay ningún motivo para gastar dos segundos abriendo GL y OpenAL.
- **La revisión del contenedor**, que no se limita a mirar si el fichero está.
  Un zip termina en su registro final (`50 4b 05 06`), así que si esos cuatro
  bytes no aparecen al final, la copia está incompleta y se puede decir eso en
  vez de «pantalla negra». El mismo registro trae la cuenta de entradas, y con
  ella la pantalla contesta la pregunta que de verdad se hace quien copió el
  juego: *¿este fichero lleva los datos dentro?* → `anil-datos.zip (653 MB,
  22186 entradas)`.
- **El aviso de memoria de applet**, que es el caso en el que todo está bien y
  el juego muere igual. No aborta: dice cómo se arranca con memoria de
  aplicación y deja pulsar A para intentarlo de todas formas.

  La primera versión preguntaba `appletGetAppletType()`, que es la pregunta
  natural y era la equivocada: ese dato lo contesta el sistema, y Ryujinx no
  modela la diferencia (§5.53), así que un NRO lanzado en el emulador se declara
  applet de biblioteca con los 3,2 GB de una aplicación en la mano. El aviso
  habría salido con todo en su sitio, que es la peor clase de aviso: el que
  enseña a no leerlos. Decide el **montón** que libnx consiguió —448 MB contra
  3,2 GB, sin ambigüedad posible— y el tipo de applet se anota como dato.

Los fallos del motor (caso 3) se guardan y se pintan al final de `main()`,
después de `SDL_Quit()`, por la razón contraria: SDL no suelta la ventana hasta
entonces.

Todo el texto es ASCII a propósito —la fuente de la consola de libnx no lleva
las vocales acentuadas—, y cada línea que se pinta va también al registro, así
que el informe de pantalla y el de fichero son el mismo.

Probado sin consola, que es lo que hace falta para no depender de ella:
`nx_aviso.c` compila en el PC contra un `switch.h` de mentira con las quince
funciones que usa, y así se recorren los seis escenarios contra carpetas de
verdad —contenedor bueno, contenedor truncado, contenedor de otra cosa,
carpetas sueltas, `lib/socket.rb` ausente, memoria de applet— y se lee la
pantalla que va a ver el jugador antes de enviarla a la consola.

### 5.60 El motor podía leer el contenedor; el juego no sabía preguntar

Con el contenedor montado y todo lo demás en su sitio, el arranque llegaba
entero: PhysFS indexaba las 22.186 rutas, el intérprete arrancaba, Essentials
cargaba sus 770 scripts **desde dentro del zip** —eso ya demuestra que el
contenedor se lee— y a los veinte segundos el juego se moría:

```
Excepción: RuntimeError
Mensaje: No se estableció una posición de inicio en el editor de mapas.
Traza: StartGame:15:in `initialize'
```

El mensaje suena a datos corruptos y no lo eran. La línea que falla es ésta:

```ruby
map_file = sprintf("Data/Map%03d.rxdata", $data_system.start_map_id)
if $data_system.start_map_id == 0 || !pbRgssExists?(map_file)
  raise _INTL("No se estableció una posición de inicio en el editor de mapas.")
end
```

`start_map_id` estaba bien —`Data/System.rxdata` se había cargado del
contenedor, por `load_data`, que va por PhysFS—. Lo que falla es la segunda
condición, y el porqué está en Essentials:

```ruby
def pbRgssExists?(filename)
  return !pbGetFileChar(filename).nil? if FileTest.exist?("./Game.rgssad")
  filename = canonicalize(filename)
  return FileTest.exist?(filename)
end
```

**Dos caminos, y el juego elige mirando si hay un archivo al lado.** Sin
`Game.rgssad`, pregunta con `FileTest.exist?`, que es el sistema de ficheros de
Ruby y no sabe nada de lo que PhysFS tiene montado. Con `Game.rgssad`, pregunta
por `load_data`, que sí. El juego traía el camino bueno desde el principio;
sólo no tenía motivo para tomarlo.

Así que el empaquetador escribe un `Game.rgssad` de **ocho bytes**: la cabecera
de un RGSSAD versión 1 sin ninguna entrada. `RGSS_openArchive` verifica la
cabecera, entra en el bucle de entradas, el primer `readUint32` da EOF y monta
un archivo vacío sin quejarse. No lleva datos: lleva la señal.

Es la clase de fallo que no se encuentra leyendo el motor, porque el motor
estaba bien. Y el diagnóstico de §5.59 ya lo cubre: si hay contenedor y no hay
`Game.rgssad`, la consola lo dice en 24 ms —«FALTA Game.rgssad, LA LLAVE DEL
CONTENEDOR»— en vez de arrancar veinte segundos para morirse.

Con la llave puesta, Ryujinx enseña la intro completa a 60 FPS y el juego llega
a la entrada del nombre leyendo los 653 MB desde dentro del zip:

```
[rutas] resolutor memoizado (Game.rgssad: true)
[teclado] entrada de texto encaminada a la rejilla con cursor
```

Ese `Game.rgssad: true` de `nx-rutas.rb` importa más de lo que parece: con
archivo, cada comprobación de existencia pasa por `pbGetFileChar`, que hace
`load_data` del fichero **entero**. Para los gráficos lo tapa la memoización de
§5.55, que es justo la que guarda esas resoluciones; para el audio y los datos
está sin medir en la consola, y es lo primero que hay que mirar si el
contenedor va más lento de lo que debería.

#### El método que no existía detrás de la puerta

La llave abre el camino del archivo, y ese camino tiene tres puertas más:
`pbRgssExists?`, `pbGetFileChar` y **`pbRgssOpen`**. Las dos primeras funcionan.
La tercera empieza así:

```ruby
def pbRgssOpen(file, mode = nil)
  ...
  file = canonicalize(file)
  Marshal.neverload = true
  str = load_data(file, true)
```

`Marshal.neverload` aparece **una vez en los 770 scripts del juego y cero veces
en todo mkxp-z**. Es un resto de compatibilidad con el mkxp antiguo, donde ese
indicador hacía que `load_data` devolviera la cadena en bruto en vez de
deserializarla; en mkxp-z eso lo dice el segundo argumento de `load_data` —el
`true` de la línea siguiente— y el indicador sobra. Pero sobrar no es lo mismo
que no hacer falta: sin el método, la línea muere con `NoMethodError` la primera
vez que el juego lee sus textos (`Data/messages_*.dat`) o una batalla de reto.

O sea que con contenedor el juego arrancaba y se rompía más tarde y en otro
sitio, que es la peor forma de romperse. El arreglo son doce líneas en
`lib/nx-compat.rb`: un setter vacío y un getter que devuelve `false`. **No
faltaba una función, faltaba una firma**, y esa es la misma categoría que
`lib/socket.rb` — el port existe para tapar huecos de plataforma, y éste lo es.

La lección, que costó una tanda de pruebas: cambiar el contenedor no cambia sólo
cómo se leen los ficheros, **cambia por qué rama del juego se pasa**. Y una rama
que no se recorría nunca no está probada por nadie.

### 5.61 Treinta segundos de pantalla negra son un cuelgue

El arranque tarda lo que tarda: veinte segundos con las carpetas sueltas
(§5.48), trece y medio más con el contenedor (§5.58). Y en todo ese rato la
consola no enseñaba **nada**. El registro decía desde el principio que el
arranque iba bien, pero el jugador no lee registros: ve una pantalla negra, y
una pantalla negra que dura medio minuto es indistinguible de un cuelgue. Es un
fallo de verdad aunque no lo sea del código.

`nx/nx_espera.cpp` dibuja el logo del juego, la palabra CARGANDO y una barra que
avanza en cada hito del arranque. Tres cosas que decidir, y las tres tienen
razón técnica:

**Dónde se dibuja.** Todo esto pasa DENTRO del constructor de `SharedState`: el
`Graphics` de mkxp-z, sus shaders y su caché de estado se están construyendo
justo ahí, y no hay un `shState` al que pedirle nada. Así que hay un programa
GLES mínimo —un cuadrado, dos texturas— que usa la tabla de funciones de mkxp-z
(`gl-fun.h`) para no tener dos formas distintas de llegar al driver. El logo va
empotrado en el binario con `xxd`, como los shaders, porque esto se pinta antes
de que PhysFS monte nada y en ese momento no se puede leer un fichero del juego.

**Por qué hay que limpiar después.** `GLState` es una **caché**: recuerda qué
programa y qué color de fondo dejó puestos y se salta la llamada si le piden lo
que ya cree tener. Una pantalla que cambia el estado a su espalda hace que la
primera escena del juego salga con el programa equivocado. El arreglo no es
adivinar lo que había, es volver a poner de acuerdo caché y driver: al terminar,
`sharedstate.cpp` reinicia las propiedades cacheadas exactamente como hace el
constructor de `GLState`.

**Por qué la barra da saltos.** Entre un hito y el siguiente el hilo está dentro
de PhysFS y no hay a quién pedirle un fotograma. Podría animarse una barra falsa
que avanzara sola; sería mentir sobre el progreso, y una barra que miente es un
adorno. Da saltos: 0,25 al compilar los shaders, 0,55 al montar el contenedor,
0,85 al construir el índice.

Y el primer fotograma se pinta **dos veces**. La superficie de Horizon tiene más
de un búfer y un solo intercambio deja el otro con lo que hubiera antes —negro—;
si el compositor enseña ése, el jugador ve negro hasta el hito siguiente, que
puede estar ocho segundos después. Dos intercambios cuestan 32 ms.

#### Lo que no se pudo hacer: música durante la carga

Una imagen quieta y medio minuto de silencio siguen pareciendo un cuelgue, así
que el paso natural era sonar el tema del título mientras carga —y entraría sin
costura en el juego, porque `AudioStream::play` compara el nombre del fichero
con el que ya suena y, si coincide, no reinicia nada—.

No se puede desde ahí. `audio.bgmPlay()` termina en `alstream.cpp:264`:

```cpp
shState->fileSystem().openRead(handler, filename.c_str());
```

y `shState` —el puntero global al estado compartido— **no se asigna hasta que el
constructor de `SharedState` termina**. El intento costó un
`Invalid memory access at virtual address 0x0` en la consola. Dentro de ese
constructor hay GL, hay OpenAL y hay PhysFS, pero no hay motor al que pedirle un
fichero.

Se intentó entonces desde un script de precarga, que corre con todo publicado.
Funciona, pero llega al mismo sitio al que llega el juego por su cuenta unos
segundos después, y a cambio mete una pieza móvil en el arranque: en la consola
la música empezó antes de que se viera la pantalla de carga y los efectos de
sonido se quedaron mudos. Se quitó. **La música de la carga es un adorno y no
puede ser el motivo de que algo del juego suene distinto**; el sitio donde eso
se arregla de verdad es en los trece segundos y medio de §5.58, no en un
parche que los tape.

### 5.62 El juego no pide sus ficheros por donde uno cree

Con el contenedor montado, el motor leia bien: los mapas cargaban, los graficos
se veian, la musica sonaba. Y el juego se quedaba **sin efectos de sonido**, y
la pantalla de titulo se caia. Costo cuatro vueltas, y cada una enseno lo mismo
por un sitio distinto: **cambiar los datos de sitio no cambia solo como se leen,
cambia por que rama del juego se pasa**, y esas ramas no las habia recorrido
nadie.

**Uno: el audio no se resuelve por donde los graficos.** La asimetria era la
pista —se ve pero no se oye— y estaba en dos funciones que hacen lo mismo por
caminos distintos:

```
pbResolveBitmap  -> pbTryString -> pbGetFileChar -> load_data -> PhysFS   ve el contenedor
pbResolveAudioSE -> RTP.exists? -> FileTest.exist?            -> sistema  no lo ve
```

`RTP.exists?` y `RTP.getPath` preguntan con `FileTest.exist?`, que es el sistema
de ficheros de Ruby. Contestaba que no, `pbResolveAudioSE` devolvia `nil` y nadie
llegaba a pedir el sonido: un fallo mudo en los dos sentidos, sin excepcion ni
linea en el registro. El arreglo no es parchear `RTP` —hay 770 scripts que pueden
preguntar lo mismo por su cuenta— sino contestar la pregunta entera una vez:
`nx/nx_ficheros.cpp` hace que `FileTest.exist?` mire primero la tarjeta, como
siempre, y solo si no esta, el contenedor. **Solo anade verdades.**

**Dos: y entonces el juego intento abrirlo.** El arreglo movio el fallo un paso
mas alla, que es como se sabe que era el arreglo bueno:

```
Errno::ENOENT: rb_sysopen - Audio/BGM/TITULO.ogg
Audio:92:in `open' -> getPlayTime2 -> playBGM   [Pantalla de Titulo Animada]
```

El plugin del titulo abre el OGG con `File.open` para medir su duracion. Mismo
hueco, otra funcion. `File.open` en modo lectura, cuando el fichero no esta en
la tarjeta y PhysFS si lo tiene, devuelve ahora un `FileInt`. Escribir no se
toca: las partidas se guardan con `File.open("wb")` y esas llamadas pasan de
largo.

Con un detalle que se ve en el mensaje: el juego pide `TITULO.ogg` y el fichero
se llama `Titulo.ogg`. En FAT32 da igual; dentro de un zip no. Por eso la
consulta pasa por `desensitize()`, que es el mismo apano por el que el juego
funciona con las carpetas sueltas.

**Tres: `FileInt` sabia decir donde estaba, pero no moverse.**

```
Errno::EBADF: Bad file number
Audio:93:in `pos=' -> block in getPlayTime2
```

`FileInt` es una subclase de `IO` **sin descriptor de fichero debajo** —lo que
hay es un `SDL_RWops` sobre PhysFS—, asi que cualquier metodo de `IO` que no
este reimplementado acaba en el `IO` de verdad y contesta `EBADF`. Estaban
reimplementados… dentro de un `#if RAPI_FULL <= 187`: **solo para Ruby 1.8.7**.
mkxp-z da por hecho que con Ruby moderno el `IO` se apana solo, y para un
`FileInt` no es cierto. Se sacan de ahi `pos` y `getc` y se anaden `pos=`,
`seek`, `rewind`, `eof?` y `size`.

Comprobado en el emulador, con los 653 MB dentro del contenedor y una sonda que
cuenta lo que el juego PIDE (`runtime/diagnostico/nx-sonido.rb`), que es distinto
de lo que se oye:

```
[sonido] FileTest.exist?("Audio/SE/Battle ball drop.ogg") = true
[sonido] pbResolveAudioSE("Battle ball drop") = "Audio/SE/Battle ball drop.ogg"
[sonido] efectos pedidos: 3 | ultimo "Audio/SE/GUI sel cursor"
```

Antes de esto, la primera linea era `false`, la segunda `nil` y la tercera no
existia.

#### Lo que esto dice del contenedor

Tres huecos en una noche, en tres capas distintas, y ninguno estaba en el motor:
estaban en como el juego pregunta. Quedan mas —`IO.read`, `Dir.glob` y
`File.size` no pasan por lo que se ha arreglado aqui—, y aparecera el que use un
plugin que nadie ha abierto todavia. Es una cola larga y es inherente a mover
los datos dentro de un archivo: **el juego se escribio dando por hecho que sus
ficheros estan en un disco**.

La alternativa que corta la cola de raiz es no pedirle al juego que lea de un
archivo: **desempaquetar el contenedor en la propia consola la primera vez**. Se
copia un fichero -que es lo que se queria-, la consola lo abre una vez y a
partir de ahi el juego corre sobre la misma carpeta suelta con la que lleva
meses funcionando: sin llave, sin ganchos, sin los 13,5 s de arranque de §5.58 y
sin ramas nuevas. Cuesta unos minutos una vez, y esta sin hacer.

### 5.63 Treinta y tres segundos que eran una búsqueda lineal

Con el juego dentro del contenedor y ya jugable, quedaba el número feo. Medido
en la consola, no en el emulador:

```
[cache] PhysFS: 22321 entradas, 171 directorios en 33272 ms
[cache]   de ellos 342 ms en PHYSFS_stat y 107 ms en el resto
```

**Treinta y tres segundos**, y el desglose señala al culpable sin margen: el
trabajo de verdad son 107 ms, los `stat` 342 —baratos, porque con el contenedor
son consultas a memoria y no IPC—, y los otros **32,8 s están dentro de
`PHYSFS_enumerate`**. El archivador de zip de PhysFS guarda sus entradas en una
tabla plana y, para contestar «qué hay en este directorio», la recorre entera.
Con 171 directorios y 22.321 entradas, eso son 3,8 millones de comparaciones de
cadena. Es cuadrático. Y por eso Ryujinx —x86 con JIT— lo disimulaba en 5 s
mientras un Cortex-A57 a 1 GHz tarda 33: **el emulador no miente, pero tampoco
avisa.**

El arreglo es el de §5.48 aplicado al otro lado. En vez de preguntar entrada por
entrada, se lee el índice de una pasada: el directorio central de un zip está
pegado al final del archivo y son dos megas con todos los nombres, tamaños y
desplazamientos. `nxIndiceZip` los recorre y llena **las mismas dos tablas** que
`cacheEnumCB`, con el mismo criterio de mayúsculas y la misma regla de
prioridad: el primero que se monta manda, así que no se pisa una clave puesta.

Y `nxCacheRapido` deja de rendirse en bloque. Antes bastaba un punto de montaje
que no fuera un directorio para devolverle todo el trabajo a PhysFS —y con un
contenedor eso es siempre—; ahora decide montaje por montaje: `readdir` para las
carpetas, el índice central para los zips, y sólo se rinde si aparece algo que
no sabemos leer, un `.rgssad` de verdad o un 7z. La llave de §5.60 es un caso
aparte que también se reconoce: ocho bytes de cabecera RGSSAD, un archivo válido
sin ninguna entrada, que no aporta nada que indexar.

```
[cache] readdir: 22324 entradas, 171 directorios en 185 ms
```

**De 5.336 ms a 185 en el emulador**, y el intérprete arranca a los 13,0 s en
vez de a los 18,1. En la consola el número de partida era 33.272 ms, así que ahí
la diferencia se cuenta en decenas de segundos —falta medirlo—.

Con esto el contenedor deja de costar trece segundos y medio de arranque y pasa
a costar los ocho del montaje, que es la siguiente piedra: PhysFS lee la
cabecera de cada entrada campo por campo, y el nombre byte a byte.

### 5.64 Una textura sin memoria detrás mata el proceso sin decir nada

El juego se cayó configurando el Nuzlocke. Ni pantalla de error, ni excepción de
Ruby, ni línea en `mkxp-ruby.log`: la consola volvió al menú y se acabó. Lo
único que quedó fue el volcado de `nx_excepcion.c`, y con el `.elf` y
`addr2line` la pila se lee entera:

```
[exc] otra (acceso a datos) desc=0x101 esr=0x92000006 far=0xe
[exc]   #0  st_render_texture
[exc]   #1  _mesa_framebuffer_texture
[exc]   #2  _mesa_FramebufferTexture2D
[exc]   #3  TexPool::request         texpool.cpp:156
[exc]   #4  Bitmap::Bitmap(int,int)  bitmap.cpp:883
[exc]   #5  Bitmap::drawText         bitmap.cpp:2023
```

`far=0xe` es la dirección que se intentó leer: el campo que hay a catorce bytes
de un puntero nulo. Y el sitio donde aparece ese nulo está en Mesa:
`st_render_texture` guarda lo que devuelva `st_get_texobj_resource(att->Texture)`
y sigue adelante **sin mirar si es nulo**. Si `glTexImage2D` no pudo reservar y
dejó `GL_OUT_OF_MEMORY`, la textura existe como nombre y no tiene recurso
detrás; dos líneas más abajo se desreferencia. No es un fallo nuestro, pero el
que se muere es nuestro proceso, y quien le pasa la textura vacía somos
nosotros.

**Por qué se quedó sin memoria de vídeo**, que es la parte que importa. El
contador de objetos del fondo de texturas —`TexPoolPrivate::objCount`— era
`uint16_t`. El presupuesto del fondo en la consola son 512 MB (§5.53) y una caja
de texto de 64×32 ocupa ocho kilobytes: **65.536 cajas son exactamente 512 MB, y
65.536 es exactamente lo que cabe en `uint16_t`**. Al dar la vuelta a cero, el
bucle de desalojo de `release()` sale por su `if (objCount == 0) break;` sin
haber borrado nada, `memSize` se actualiza igual que siempre y a partir de ese
punto el fondo crece **sin techo** hasta que el driver dice que no.

Y una pantalla de configuración es texto, y nada más que texto: es la forma más
rápida que tiene este juego de fabricar decenas de miles de texturas diminutas.
Por eso apareció ahí y no en el mapa.

**Arreglo, en tres piezas.** Ensanchar el contador a `uint32_t`, que es el fallo
de verdad. Preguntar por `glGetError()` después de reservar y **antes** de
colgar la textura del FBO: si el driver dijo que no, se sueltan todas las
texturas que el fondo estaba guardando por si acaso y se vuelve a pedir; si
tampoco a la segunda, se lanza una excepción de mkxp —el jugador ve un error, no
una consola apagada— y el presupuesto del fondo se queda a la mitad, porque el
techo estaba más bajo de lo que creíamos. Y contar en `[tiron]` cuántas texturas
hay guardadas, no solo cuántos megas: ese es el número que habría visto venir el
desbordamiento.

`patches/mkxpz-textura-sin-memoria.patch`.

**Lo cerca que se pasa, medido en la consola.** Un jugador conto que la 1.0.0 se
le caia megaevolucionando contra el Ladron Matias -el del laberinto de la
Mansion Quemada, mapa 121, cuyo Shiftry es de nivel 55-. Con
`runtime/diagnostico/nx-mega-ya.rb` ese combate se monta y se juega solo, sin
tocar el mando, y en hardware sale entero. Pero el registro deja el numero:

```
fondo 0 aciertos 511 MB
```

**511 de 512.** La animacion de megaevolucion es el momento mas caro de texturas
de todo el juego y roza el techo sin llegar a tocarlo. Ahi no hay margen para
nada, y es justo el escenario que §5.64 convierte de muerte del proceso en
soltar el fondo y seguir.

Y una leccion sobre medir: durante esa prueba el juego daba un tiron de un
segundo cada seis. No era el juego. La sonda escribia su latido cada 300
fotogramas —sesenta y dos lineas de pila, cada una con su `fsync` sobre la
tarjeta— y eso son mil milisegundos exactos. Cinco segundos de fotogramas mas
uno de sonda: los 6.030 ms que separaban un tiron del siguiente. El instrumento
pesaba mas que lo que estaba pesando.

**Reproducido a escala, el 5 de septiembre.** Un segundo jugador conto lo mismo
con otra ropa: al llegar a Ciudad Verde baja a la ruta 1, interactua con un
Pidgey y el juego se cierra, devolviendolo al laboratorio -que es donde estaba
su ultimo guardado, no una partida borrada-. Ni pantalla de error ni
`errorlog.txt`. La misma firma.

Reproducirlo tal cual exige tener 65.536 texturas guardadas a la vez, y eso en
Ryujinx no se puede: cada FBO pasa por la Mesa del invitado y por la GPU
emulada, y el ritmo se derrumba de 10.000 texturas por segundo a menos de 4.000
antes de llegar a diez mil. Medido, no supuesto.

Asi que se reproduce a escala, con dos interruptores en `texpool.cpp`:
`NX_FONDO_MAQUETA` baja el presupuesto del fondo a 2 MB y `NX_FONDO_8BITS`
estrecha el contador a 8 bits. **256 texturas de 8 KB son 2 MB, que es la misma
relacion exacta que 65.536 y 512 MB**, por el mismo camino y en la misma linea
de codigo. La sonda `runtime/diagnostico/nx-fondo-desborde.rb` hace lo que hace
el juego durante media hora de cuadros de texto, en cincuenta milisegundos:
tener muchas texturas diminutas vivas a la vez y soltarlas todas de golpe.

Con el contador de 8 bits:

```
[fondo]  8193 peticiones |  1537 KB |  58 texturas contadas | 314 en cola
[fondo]  8449 peticiones | 18376 KB |   1 texturas contadas | 257 en cola
[fondo]  8705 peticiones | 76237 KB |   1 texturas contadas | 257 en cola
```

314 en la cola y 58 contadas: 314 menos 256. **El contador se ha dado la
vuelta.** Y a partir de ahi el desalojo se rinde en cuanto su contador llega a
cero, dejando 257 texturas que no ha mirado, y el fondo pasa de 2 MB de
presupuesto a **76 MB: treinta y siete veces el techo**, subiendo.

Con el mismo presupuesto y el contador de 32 bits, la misma sonda, el mismo
combate contra el Pidgey: **maximo 2.042 KB, y el contador y la cola coinciden
en todas las lineas**. Ese es el control.

Lo que la maqueta no puede ensenar es el ultimo paso, porque el anfitrion tiene
memoria de video de sobra y `glTexImage2D` nunca llega a decir que no. Que el
fondo crezca sin techo esta demostrado; que ese crecimiento acabe matando el
proceso lo demostro el volcado del 4 de septiembre.

El instrumento que faltaba tambien queda puesto: `nx_pool_reales()` pregunta
cuantas texturas hay **de verdad** en la cola, y el informe periodico `[fondo]`
las escribe al lado de las contadas cada 256 peticiones, con `diagnostico.txt`
puesto. La linea `[tiron]` ya llevaba el numero, pero solo se escribe cuando hay
un tiron, y esto no da ninguno: el juego va fluido hasta que se apaga.

**Confirmado en la consola de un jugador, con su propio volcado.** El mismo dia
llegaron los registros del caso del Pidgey, de la 1.0.0 b14. Dos caidas, una por
sesion, con el mismo `pc` y los mismos registros: `far=0xe`, `x20=0`. El `.elf`
de esa compilacion no se archivo, pero el `.nro` publicado se puede desensamblar
igual, y la instruccion es

```
7abd30:  ldrh  w7, [x20, #14]        con x20 = 0
```

Para ponerle nombre se busca esa misma secuencia en una compilacion que si
conserve simbolos: aparece en la b52 con diecisiete instrucciones identicas byte
a byte alrededor, saltos relativos incluidos. De ahi sale la pila entera:
`st_render_texture` <- `_mesa_framebuffer_texture` <- `_mesa_FramebufferTexture2D`
<- (`TexPool::request`) <- (`Bitmap::Bitmap`) <- `Bitmap::drawText`. Los dos
marcos que no casan son los dos ficheros que este arreglo toco; que no casen es
la confirmacion.

Lo que pidio la textura fue **un cuadro de texto**: el «¡Un PIDGEY salvaje
apareció!». El Pidgey solo tuvo la mala suerte de ser el primero despues de que
se acabara el sitio.

Y el caso corrige una suposicion: **ahi el contador de 16 bits no estaba
implicado**. El fondo se mantuvo entre 250 y 330 MB las dos sesiones, sin crecer
sin techo. La memoria de video se agoto con un fondo de tamano legitimo, o sea
que el techo real esta por debajo de los 512 MB que el presupuesto supone. El
guardian lo cubre igual —suelta el fondo y sigue—, pero el presupuesto inicial
merece bajar. El detalle completo, en `docs/consola/20260905-pidgey/`.

**Y el presupuesto inicial baja de 512 MB, con criterio.** Lo primero que hay
que decir es lo que *no* se acabó: en el momento de la caída el montón iba por
**1.042 MB de 3.166** y quedaban dos gigas sin repartir. `mallinfo().uordblks`
incluye los búferes de la GPU (§5.53), así que el sitio de `malloc` no era el
problema. Lo que se agotó es lo que el driver puede tener **mapeado a la vez**
para la GPU, y eso no hay forma de preguntarlo desde el proceso: no se deduce,
se mide. Y lo único medido es la banda en la que rompió, que son esos 250-330 MB
de fondo.

De ahí sale el techo nuevo: **192 MB**, una cuarta parte por debajo del borde
bajo de la banda. Partirlo por la mitad no habría bastado —512 entre dos son
256, que cae *dentro* de la banda, y eso es exactamente lo que hace el guardián
al primer choque—. Y bajar más de 192 se paga: con 256 el fondo se quedaba
clavado en su presupuesto y cada tira de animación nueva entraba creando contra
el driver y salía borrando contra el driver, `pool 237x 429 ms` en un solo
fotograma. 192 MB no es gratis; es el precio de no volver a pisar el sitio donde
el proceso se moría, con el guardián detrás por si tampoco basta.

Y deja de ser una constante, porque el mismo binario recibe presupuestos muy
distintos según cómo se lance: 3,2 GB como aplicación instalada o como NRO
suplantando un título, unos 448 MB como applet de biblioteca (§5.53). Guardar
192 MB de texturas de un presupuesto de 448 sería absurdo. Así que se pide **un
octavo del montón** —leído en `fake_heap_start`/`fake_heap_end`, los mismos
símbolos que usa `sbrk`, que es el único techo que sí se puede leer— y se acota
entre **64 y 192 MB**. En la consola de verdad manda el techo; en un applet
manda el suelo; si algún día el reparto cambia, el fondo se entera solo.

El registro de arranque lo dice ahora en una línea, para que el próximo informe
de un jugador no obligue a adivinar con qué presupuesto arrancó su consola:

```
[fondo] presupuesto inicial 192 MB (monton 3166 MB, un octavo acotado entre 64 y 192 MB)
```

Y hay que decir que **192 es provisional**. Quien de verdad estrecha el sitio no
es el fondo: es el montón de Ruby, que en esa partida subió a 1.042 MB en diez
minutos de juego, monótono y siempre con veinte megas libres, sin que se sepa
todavía por qué. Ese es otro problema y va aparte; cuando se arregle, este número
podrá volver a subir.

**Lo que esto significa para quien juega la 1.0.0 o la 1.1.0.** Las dos llevan
el contador de 16 bits: el arreglo es posterior a la etiqueta `v1.1.0`. No hay
nada que el jugador pueda hacer salvo guardar a menudo, y el consejo de "prueba
otra vez" funciona porque cada arranque devuelve el contador a cero.



### 5.65 Publicar sin guardar el `.elf` es publicar a ciegas

El caso del Pidgey (§5.64) llegó como llegan todos los casos de un jugador: un
`mkxp-boot.log` y ninguna posibilidad de reproducirlo. Lo único que decía el
volcado era esto:

```
[exc] otra (acceso a datos) desc=0x101 esr=0x92000005 far=0xe
[exc] base=0x440063d000 pc=0x4400de8d30 (+0x7abd30)
```

`+0x7abd30` es un desplazamiento dentro del binario, y para convertirlo en un
nombre de función hace falta el `.elf` **sin desnudar de esa compilación
exacta**. El de la 1.0.0 b14 no se archivó: `make` lo sobrescribió a la
siguiente vuelta, y de una compilación de tres días antes no queda nada.

Se resolvió igualmente, por el camino largo. El `.nro` publicado sí existe, y un
`.nro` no es más que los segmentos del `.elf` copiados sin mover, así que el
desplazamiento del volcado es a la vez el vaddr del `.elf` y el offset dentro
del fichero:

```
$ aarch64-none-elf-objdump -D -b binary -m aarch64       --start-address=0x7abd30 release/anil-switch-1.0.0/pokemon-anil.nro
  7abd2c:  97fd6961   bl   0x7062b0
  7abd30:  79401e87   ldrh w7, [x20, #14]      <-- aqui
```

Con `x20 = 0` eso es leer a catorce bytes de un nulo, que es exactamente lo que
decía `far=0xe`. Para ponerle **nombre** hubo que buscar esas mismas diez
instrucciones en una compilación que sí conservara símbolos —la b52, que seguía
en el árbol de trabajo por casualidad—, comprobar que las diecisiete de
alrededor coincidían byte a byte (saltos relativos incluidos, o sea que es la
misma función compilada igual) y leer el símbolo de allí. Marco a marco, seis
veces.

Funcionó **porque la función no había cambiado entre la b14 y la b52**. Eso no
es un método: es suerte, y la suerte no se planifica. Los dos marcos que no
casaron fueron justo los dos ficheros que el arreglo de §5.64 tocó.

**Lo que se hace ahora.** `construir.sh` termina archivando en
`release/simbolos/<version>-b<n>/` el `.elf` de esa compilación, el `.nro`
byte a byte idéntico al que se entrega, y un `SELLO.txt` con la versión, el
sello `NX_BUILD`, la fecha, el commit y el sha256 de los dos binarios. El hash
del `.nro` es lo que empareja sin dudas un registro de jugador con su
compilación: el sello podría repetirse si alguien tocara `build-numero.txt`, el
hash no. `publicar.sh` se niega a etiquetar si esos símbolos no están, y marca
la carpeta como publicada para que la poda no la toque jamás. Poda hay porque un
`.elf` son noventa megas y aquí se compila veinte veces al día: de cada versión
se guardan enteras las tres compilaciones más recientes y todas las publicadas;
de las demás queda sólo el `SELLO.txt`, que no pesa nada y deja el rastro.

`release/simbolos/` **no entra en git**, y es deliberado: noventa megas por
compilación no tienen sitio en un repositorio. Viven en el disco de quien
compila, que es el único que publica.

**Y el camino largo se automatizó también.** `resolver-pila.py` coge un
`mkxp-boot.log`, saca la compilación de la línea `[build]` que el motor escribe
al arrancar, busca su carpeta de símbolos y pasa cada dirección por
`addr2line`. Si el `.elf` está, la pila sale con nombres en un segundo. Si no
está —las publicaciones anteriores a esto: la 1.0.0 y la 1.1.0—, degrada solo al
método del Pidgey: desensambla el `.nro` publicado en crudo, enseña la
instrucción exacta que falló, y busca las firmas de diez instrucciones en la
compilación con símbolos más reciente para proponer nombres. Lo dice con todas
las letras: son candidatos, valen si la función no cambió, y no hay forma de
saberlo desde ahí. Sobre el registro del Pidgey reproduce la pila que costó una
tarde a mano —`st_update_renderbuffer_surface`, `st_render_texture`,
`_mesa_framebuffer_texture`— y deja en blanco, sin inventarlos, los mismos
marcos que no casaban.

Retroactivamente se archivó lo que quedaba: el `.nro` publicado de la 1.0.0 b14
y el de la 1.1.0 b46, cada uno con su `SELLO.txt` diciendo que su `.elf` está
perdido, y el `.elf` de la b52 que aún seguía en `mkxp-z-nx/` —el que sirvió de
referencia para el caso del Pidgey— marcado para que no se pode. Los `.elf` de
las dos versiones publicadas no se pueden recuperar: no existen.

### 5.66 El montón que subía solo: qué medía ese número, y qué no

El registro del caso del Pidgey (§5.64) deja una serie que da miedo leer. Los
picos de montón de la segunda sesión, en orden:

```
366  696  769  808  849  889  930  963  1009  1042 MB
```

Monótono, sin bajar nunca, y un gigabyte en menos de diez minutos de juego.
Antes de buscar la fuga hay que hacer lo de siempre: averiguar qué mide ese
número. Mide algo distinto de lo que parecía, y de ahí sale casi todo lo demás.

**Qué es.** Lo escribe `nx_memoria_latido()` (`nx/nx_memoria.c`) y es
`mallinfo().uordblks`: los bytes que `malloc` tiene repartidos y sin devolver.
No es lo reservado al sistema —eso es `svcGetInfo(UsedMemorySize)`, que está
clavado en 3.185 MB desde el arranque porque `__libnx_initheap` mapea el montón
entero y diría lo mismo con el juego cerrado (§5.53)—. No es el montón de
objetos de Ruby, que son los *slots* del recolector y se miden con `GC.stat`. Y
no es una categoría aparte de la memoria de vídeo, porque en Horizon **no hay
memoria de vídeo aparte**: `nvmap` mapea memoria del proceso, así que las
texturas están dentro de ese mismo número.

**Dos cosas que el registro ya desmiente, sin medir nada nuevo.**

La primera es la hipótesis natural en Horizon: que el asignador de newlib no
devuelve páginas y por eso el montón se ve grande aunque por dentro no haya nada
vivo. **No es eso.** En el `mallinfo` de newlib, `fordblks` es *todo* el espacio
libre del arena —los huecos de las 128 listas más el trozo de arriba— y
`arena = uordblks + fordblks`. En las diez muestras, `fordblks` va entre 10 y 47
MB mientras `uordblks` sube a 1.042. `malloc` ha pedido 1.069 y tiene 1.042
repartidos: **no hay huecos**. Si esto fuera fragmentación, el hueco sería justo
lo que crece, y es lo único que no crece.

Y de paso corrige la lectura de aquel «siempre con veinte o treinta megas
libres». Esos veinte megas no son lo que le queda a la consola: son lo que le
sobra a `malloc` **dentro de lo que ya ha pedido**. Cuando no le sobra, hace
`sbrk` y pide más, y le quedaban 2.100 MB por pedir. En el momento de la caída
el proceso no estaba corto de montón, cosa que §5.64 ya había establecido por
otro camino.

La segunda es más incómoda: **«monótono» es en parte una propiedad del
instrumento**. `nx_memoria_latido()` guarda una marca de agua y sólo escribe
cuando el pico sube un escalón de 32 MB. Esa línea no puede bajar nunca. Que la
serie sea monótona no demuestra que el montón no baje; demuestra que el registro
no está preparado para contarlo.

**El reparto, hasta donde llegan los datos.** Las líneas `[tiron]` ya llevan el
tamaño de los tres alijos del motor, así que se pueden restar:

| t (s) | montón | fondo | img | cad | alijos | **resto** |
|---:|---:|---:|---:|---:|---:|---:|
| 15,7 | 366 | 57 | 16 | 0 | 73 | **293** |
| 20,9 | 696 | 200 | 18 | 0 | 218 | **478** |
| 96,0 | 889 | 275 | 45 | 3 | 323 | **566** |
| 199,8 | 1.009 | 315 | 79 | 6 | 400 | **609** |
| 2.927 | 1.042 | 306 | 87 | 12 | 405 | **637** |

**Casi la mitad de ese gigabyte son los alijos llenándose, que es lo que hace un
alijo.** De los 676 MB que crece el montón, 332 son el fondo de texturas, el
alijo de imágenes y el de cadenas. Y no habían terminado: con los presupuestos
de la b14 —fondo 512 MB, imágenes 192, cadenas 32— el techo *por diseño* eran
**736 MB de alijo**, y iban por 405. Al montón le quedaban otros 330 MB de
crecimiento correcto, sin ninguna fuga. La rebaja del fondo de §5.64 baja ese
techo de diseño a **416 MB** de propina, aunque se hizo por la memoria de vídeo
y no por esto.

El resto —lo que queda al quitar los alijos— sube de 293 MB antes de cargar
ningún mapa a 637 tres minutos después, y ahí se aplana: durante los cuarenta y
tres minutos de consola suspendida y los cuatro de juego posteriores sube 28 MB.
Eso no tiene forma de fuga por fotograma; tiene forma de conjunto de trabajo que
se llena. Pero dentro de ese «resto» están, sin poder separarse, las **texturas
vivas** —el fondo sólo sabe de las que le devuelven, las que el juego tiene en
uso no las cuenta nadie—, el motor, SDL, Mesa y el intérprete.

**Y una sospecha con mecanismo, no con corazonada.** No hay ningún `RUBY_GC_*`
puesto en ninguna parte: el recolector corre de fábrica. El problema no sería el
ajuste, sería la ceguera. El descriptor de tipo de todas las clases del motor se
genera en `binding-util.h` con **`dsize = 0`**, así que para el recolector un
`Bitmap` de 512×384 es un objeto de cuarenta bytes; y su memoria no pasa por
`ruby_xmalloc` sino por `new` y por el driver, así que tampoco incrementa
`malloc_increase_bytes`, que es el único contador que hace correr al recolector
por presión de memoria. Si eso es lo que pasa, el juego puede acumular cientos
de megas de basura recogible sin que Ruby vea motivo para recogerla.

**El instrumento que separa las cuatro cosas.** En `nx/nx_tirones.c`, tres
líneas cada treinta segundos:

```
[monton] malloc 1042 MB en uso | 27 libres dentro | 1069 pedidos al sistema | el sistema dice 3185 de 3189 MB
[monton] reparto: fondo 306 | img 87 | cad 12 | resto 637 MB (texturas vivas + motor + ruby)
[monton] ruby: 412 recogidas | 45123 slots vivos (1 MB) | 12034 viejos | inc malloc 2 KB
```

Si `arena` sube y `en uso` no, es fragmentación y sólo fragmentación. Si el
`resto` se aplana y lo único que sigue subiendo son los tres alijos, no hay
fuga: hay presupuestos generosos, y el techo del montón pasa a ser una constante
conocida. Si el `resto` sube linealmente con el tiempo de juego, hay fuga de
texturas vivas y hace falta un contador de bytes de textura viva, que hoy no
existe. Y si `inc malloc` se queda en unos pocos KB mientras el montón sube
cientos de MB, queda demostrada la ceguera del recolector, y el arreglo es
acotado y no toca el `GC`: declarar el tamaño real de un `Bitmap` en su
`rb_data_type_t`, o llamar a `rb_gc_adjust_memory_usage()` al crear y destruir
la textura.

**Va en producción, no en modo diagnóstico**, y la decisión tiene argumento: lo
que hay que explicar pasa en la consola de un jugador que juega media hora, y
ningún jugador va a dejar puesto `diagnostico.txt` para eso. El coste es un
`mallinfo`, una llamada al sistema y cuatro consultas a `GC.stat` cada treinta
segundos —unas veinte líneas por sesión— contra un fotograma de 16,7 ms.
`nx_pool_informe()` sí va gobernado por el modo diagnóstico y no es incoherente:
aquél salta una vez cada 256 peticiones al fondo, que en un fotograma malo son
varias por segundo. Es otra clase de coste. Por lo mismo el disparo es sólo por
tiempo y no por escalón: mirar `mallinfo` en cada fotograma es recorrer las 128
listas de huecos del asignador dentro del cronómetro que ese fichero existe para
no perturbar.

Ruby se llama desde ahí con **símbolos débiles**, así que la sonda sigue
enlazando en un binario sin intérprete y se limita a callar esa línea; y sólo se
pregunta desde `nx_marco()`, al que únicamente se llega por `Graphics::update` y
`Graphics::wait`, que salen del guion del juego y por tanto del hilo de Ruby.

**No se ha arreglado nada, y es deliberado**: con los datos de hoy no hay una
causa única que arreglar, hay un reparto que todavía no se puede hacer y una
mitad que apunta a un diseño funcionando como se pidió. El diagnóstico completo,
con la tabla entera y las seis hipótesis ordenadas, en
`docs/consola/20260905-pidgey/monton.md`.


### 5.67 Todo lo demás que decían los registros de dos jugadores

Dos personas jugaron de verdad y mandaron sus registros: 280 KB, veinticinco
sesiones, dos compilaciones distintas (`1.0.0 b14` con los ficheros sueltos y
`1.1.0 b46` con el contenedor). La caída dura se llevó toda la atención y es
§5.64. Pero un registro de alguien jugando dice muchas más cosas que aquella
por la que se pidió, y **nadie había mirado el resto**. Son veinte anomalías
distintas. El inventario completo, con las cuentas y el porqué de cada
clasificación, en `docs/consola/barrido-registros.md`; aquí van las cuatro que
importan.

**Lo primero, y no es la caída: el arranque de 1.1.0 tarda 55 segundos.** Entre
el hito `10a` y el `10a+` sólo hay un `fileSystem.addPath("anil-datos.zip")`, y
en las seis sesiones cuesta entre 54,7 y 55,7 s. El mismo tramo sin contenedor
—`addPath(".")`— son **14 ms**, y el arranque entero de 1.0.0 hasta el
intérprete, 2,0 s. El contenedor de §5.58 se hizo para que copiar el juego a la
tarjeta no costase 22.148 entradas de directorio, y para eso funciona; a cambio,
sin que nadie lo midiera, el arranque se ha vuelto **veinticinco veces más
lento**.

No es el índice de rutas, que eso es §5.63 y se ve en el propio registro: de
`10a+` a `10c` van 319 ms. Es el `PHYSFS_mount`. El archivador de zip de PhysFS
recorre el directorio central entrada por entrada leyéndolo a pellizcos del
descriptor subyacente, y en esta tarjeta cada pellizco es una IPC de las de
0,85 ms de §5.48: 55,4 s entre 22.591 entradas son 2,45 ms por entrada, unas
tres lecturas pequeñas cada una. Cuadra. Y explica por qué no se vio: en el
emulador esas lecturas van a un fichero ya en la caché del anfitrión. Es el
patrón de §5.63 un escalón más abajo —en el montaje en vez de en la
enumeración— y el arreglo es el mismo de siempre, leer de una pasada. **Hecho
en §5.68**, que además afina la cuenta: no son tres lecturas por entrada sino
diecinueve llamadas al sistema, 429.229 en total, y con una ventana de 64 KiB se
quedan en 66.

**Una congelación de dos segundos que es siempre la misma.** Trece fotogramas
en las veinticinco sesiones, con las dos compilaciones, y la huella no varía ni
en una unidad: `nue 2941x`, `lim 2965x`, `blt 2985x`, `pool 1621x`, `fondo 1366
aciertos`. Los mismos 2.941 `Bitmap.new` siempre. No se va en la tarjeta —`io`
son 48 ms de 2.250—: se va en crear 1.575 texturas de cero a 0,29 ms cada una.
El coste vive en `texpool.*`, que lo está tocando quien lleva §5.64, así que
queda apuntado ahí y no aquí.

**La superficie es de 1920×1080 también en portátil.** `nx_pantalla.c` dejaba la
pregunta planteada por escrito —se anotaban las dos fuentes «porque sin las dos
en el registro no hay manera de saberlo»— y ya está contestada, con veinticinco
muestras y sin una sola excepción: `nwindow 1920x1080 | applet 1280x720 | modo
portatil`. La superficie donde Mesa dibuja **no cambia** al salir de la base;
Horizon entrega siempre 1080p y escala él. O sea que el juego dibuja 2,25 veces
los píxeles que el panel enseña, con la GPU a 307 MHz, y el búfer ocupa 2,25
veces más memoria en un proceso que en estos registros llega a 1,3 GB de montón
y se muere por no encontrar sitio para una textura. No es un número pequeño en
el sitio donde menos margen hay. El arreglo —`nwindowSetDimensions` colgado del
evento de cambio de resolución al que ya estamos suscritos— toca de lleno la
memoria de vídeo que se está investigando en §5.64, así que se documenta y se
cede.

**Y el registro se estaba estropeando a sí mismo.** `nx_boot_mark()` escribía el
sello, el mensaje y el salto de línea en tres `write()` seguidas sobre un
descriptor por el que escriben a la vez el hilo de dibujo, el de la música y el
principal. Entre dos de esas tres llamadas cabe otro hilo entero, y el resultado
son **41 líneas trenzadas y 41 líneas vacías** entre los dos jugadores, un 2,5 %
del registro: un `[nucleo]` con un `[tiron]` incrustado detrás sin salto de
línea. No se pierde un byte, pero `resolver-pila.py` y `triaje.py` van línea a
línea y una línea trenzada no es ninguna de las dos que la componen. Arreglado
por los dos lados: un `Mutex` de libnx que ordena a los escritores, y la línea
entera armada en un buffer y soltada de una sola `write()`, para que aunque el
candado no estuviera lo peor posible sea que dos líneas salgan en otro orden.

De la misma pasada salieron otros dos arreglos pequeños en el mismo sitio. La
línea `[nucleo] musica:` se repetía **221 veces** —hasta 20 en una sola
sesión— porque el hilo que rellena los búferes de OpenAL nace y muere con cada
pista; ahora lleva un tope de tres por nombre, el mismo que `nx_traza_me()`
tiene desde §5.57 y por el mismo motivo, y el reparto de núcleos se sigue
haciendo siempre: lo que se calla es contarlo. Y `mkxp-boot.log`, que se abría
en `O_APPEND` y no se truncaba nunca, iba por 182 KB y 1.636 líneas después de
diecinueve partidas; ahora, si pasa de 1 MB, se aparta a `mkxp-boot.1.log` y se
empieza uno nuevo. Una generación y no cero, porque la caída que se quiere
entender suele ser la de la partida anterior, la que hizo al jugador cerrar y
volver a abrir.

**Lo que no era nada.** De las veinte, once son ruido normal del motor y
conviene dejarlo escrito para no volver a investigarlas: el
`Failed to load libfluidsynth.so` de cada arranque (el `mkxp.json` declara a
propósito que no hay MIDI), el `WARNING` de versión de Essentials (script del
juego, cosmético), el aviso de `Dir.exists?` (documentado en `nx-compat.rb`: en
Ruby 3.1.7 esos métodos existen), el `argc = 0` de tres arranques de hbmenu —que
es la ruta de reserva funcionando— y dos etiquetas que engañan pero cuyos
números son buenos: `Data/Scripts.rxdata accesible: false` es la respuesta
correcta cuando los datos están en el contenedor, y `[cache] readdir: 22.730
entradas` con contenedor no es un `readdir` sino la suma del índice del zip y
los ficheros sueltos.

**Y un hueco que no es una línea, sino la falta de ella.** `triaje.py` busca
líneas `[pila]` y las llama «lo más parecido a *dónde estaba el jugador* que hay
en los registros». En los 280 KB no hay ninguna: las escribe
`runtime/diagnostico/nx-gc.rb`, que no va en el `preloadScript` del paquete. La
herramienta de triaje busca siempre en vano una señal que la compilación
publicada nunca escribe, y las quince caídas de §5.64 no dicen ni qué mapa, ni
qué menú, ni qué combate. Hace falta una migaja de pan —una línea al cambiar de
mapa y al empezar y acabar un combate, cuatro o cinco por sesión— y no una
sonda; queda propuesta y sin escribir, porque engancharse a las tripas de
Essentials desde un `preload` es justo la clase de cambio que puede tumbar una
partida ajena y hay que probarlo antes en el emulador.

### 5.68 Cincuenta y cinco segundos leyendo el índice a pellizcos

El contenedor de §5.58 resolvió lo que se le pidió —copiar el juego a la tarjeta
dejó de ser 22.148 entradas de directorio— y §5.63 le quitó los treinta y tres
segundos del índice de rutas. Quedaba la piedra que aquella sección ya dejó
señalada: **el montaje**. Los registros de un jugador de verdad dicen cuánto
pesa, y pesa más de lo que nadie había supuesto:

```
[   919] [boot] 10a miembros construidos (shaders compilados)
[ 56455] [boot] 10a+ contenedor anil-datos.zip montado
```

Entre esas dos líneas de `sharedstate.cpp` no hay más que un `fopen`, un
`fclose` y `fileSystem.addPath("anil-datos.zip")`. **Cincuenta y cinco segundos
y medio**, y no es una casualidad de una sesión: las seis del jugador «user2»
dan 54,7 – 55,7 s, y el arranque entero hasta el intérprete 56,0 – 57,1. El
mismo tramo en la 1.0.0, con las carpetas sueltas, es `addPath(".")` y cuesta
**14 ms**; aquel arranque entero eran 2,0 – 2,4 s.

O sea que quien instaló la 1.1.0 encima de la 1.0.0 vio el arranque **veinticinco
veces más lento**, y lo paga otra vez después de cada caída de §5.64.

**Dónde se va, contado y no estimado.** El archivador de zip de PhysFS lee el
directorio central campo por campo: dieciséis `io->read` de dos y cuatro bytes
para la cabecera de cada entrada, uno más para el nombre, y un `tell` y un `seek`
para saltarse los extras y el comentario. Diecinueve llamadas al sistema por
entrada. Con 22.591 entradas, **429.229**. En Horizon una lectura de fichero no
es una copia de memoria sino una IPC, y 55,4 s repartidos entre 429.229 salen a
**0,13 ms cada una**, que es justo lo que cuesta ahí una IPC pequeña. Cuadra sin
ajustar nada.

Y explica por qué se publicó: en el emulador esas mismas lecturas caen en la
caché del sistema operativo anfitrión y no cuestan nada. Es la lección de §5.63
otra vez —el emulador no miente, pero tampoco avisa— un escalón más abajo, en el
montaje en vez de en la enumeración.

**El arreglo.** PhysFS admite montar desde un `PHYSFS_Io` propio, así que basta
con que ese `Io` no baje al sistema de ficheros cada vez que le piden cuatro
bytes. El de `filesystem.cpp` mantiene delante un trozo del fichero: la primera
lectura pequeña trae 64 KiB y las siguientes miles se sirven de ahí con un
`memcpy`. El directorio central de `anil-datos.zip` son 2,1 MB contiguos pegados
al final del archivo y se recorren hacia delante, de modo que las 429.229
llamadas se quedan en 66. El `tell` y el `seek` dejan además de ser llamadas al
sistema, porque la posición la lleva el `Io` y sólo se hace `lseek` cuando toca
leer de verdad.

**Medido en el PC**, con un banco de pruebas que recorre el índice central de un
zip almacenado de 22.591 entradas exactamente como lo hace `zip_load_entry()` de
PhysFS 3.2.0, primero contra un `Io` crudo y luego contra el del parche:

```
entradas             22591
recorrido valido     si / si   nombres iguales: SI
sin ventana          read() 384047   lseek() 45183   bytes 2098466   0.425 s
con ventana 64 KiB   read() 33       lseek() 33      bytes 2098488   0.003 s
llamadas al sistema  429230 -> 66   (x6503 menos)
4000 lecturas al azar (hasta 293 KiB, con saltos atras): identicas
```

Los 0,425 s contra 0,003 son el suelo de un NVMe con la caché caliente y no
dicen nada de la consola; el número que importa es **429.230 → 66**, y que los
22.591 nombres salen idénticos por los dos caminos. A los 0,13 ms medidos en la
tarjeta, esas 66 llamadas son **ocho milisegundos y medio** donde había
cincuenta y cinco segundos. De los 55,4 s no debería quedar más que traer 2,1 MB
y el trabajo que PhysFS hace en memoria armando sus 22.591 entradas —que es el
mismo con ventana y sin ella, y que en §5.63 se midió en 107 ms para una pasada
comparable—. **La previsión es medio segundo largo de montaje y el arranque
entero de vuelta a los dos segundos de la 1.0.0.**

**Confirmado en la consola** el 6 de septiembre de 2026, 1.1.1 b66:

```
[  1089] [boot] 10a miembros construidos (shaders compilados)
[  1657] [boot] 10a+ contenedor anil-datos.zip montado
[  1991] [boot] 10c pathCache construido
[  2132] [boot] 11 SharedState OK, arrancando el interprete Ruby
```

**568 ms de montaje** para 653 MB y 22.186 entradas, y el intérprete arrancando
a los **2,1 s**. La previsión era la buena, decimal arriba o abajo.

**Por qué 64 KiB y no 256.** Para el montaje daría igual —serían ocho lecturas
en vez de treinta y tres, tres milisegundos de diferencia—. Quien decide es el
otro uso del `Io`, que dura toda la partida: PhysFS resuelve la cabecera local
de cada entrada la primera vez que se abre, y eso son unas pocas lecturas
diminutas en un desplazamiento cualquiera del fichero, donde una ventana grande
es un impuesto —traer 256 KiB de la tarjeta para leer treinta bytes—. Se elige
la más pequeña que ya deja el montaje en nada, y de paso es el mismo número que
§5.55 puso en `PHYSFS_setBuffer` un piso más arriba: un solo tamaño en el fichero
vale más que afinar el segundo decimal.

Ese piso de arriba manda además en la memoria. PhysFS duplica el `Io` por cada
fichero abierto, y sobre el duplicado ya hay un búfer de 64 KiB que pide justo
64 KiB de golpe; una petición tan grande como la ventana no gana nada pasando
por ella, así que se lee directa al búfer de quien llama y ese duplicado **no
reserva nunca nada**. La ventana se aparta la primera vez que hace falta y no
antes, de modo que en la práctica esto cuesta los 64 KiB del `Io` del montaje y
ni un byte más — que en un proceso que llega a 1,3 GB de montón (§5.64) no es un
detalle menor.

**Lo que se descartó, y por qué:**

* **`PHYSFS_setBuffer` sobre el mismo `Io`**, que era la vía barata sugerida en
  el barrido. No sirve: trabaja sobre un `PHYSFS_File` y no sobre un
  `PHYSFS_Io`, así que exigiría `PHYSFS_mountHandle` —montar `"."` con PhysFS
  antes que el contenedor y abrirlo a través de él—, que es justo el orden que
  §5.58 descartó con una medida, y encima el búfer no lo heredarían los
  descriptores duplicados.
* **Un archivador propio de PhysFS para zips almacenados.** Sería más rápido
  todavía, y el índice ya lo sabemos leer de una pasada desde §5.63
  (`nxIndiceZip`), pero habría que escribir también abrir, leer, buscar, `stat`
  y enumerar, y un descuido ahí son ficheros que el juego no encuentra. La
  ventana no cambia ni una línea del archivador de PhysFS: sólo le cambia por
  dónde lee. Cien líneas se llevan casi todo el premio.
* **Precalcular el índice al empaquetar.** No quita este coste. El `pathCache`
  ya se construye así, pero PhysFS necesita además **su** tabla para poder leer
  del zip, y esa la llena montando. Ahorrarse el montaje entero es el archivador
  propio del punto anterior, no un fichero de índice.

Todo esto va en `patches/mkxpz-montaje-ventana.patch`, que se aplica después de
`mkxpz-pathcache-readdir.patch` porque los dos tocan `filesystem.cpp`. Y queda
una trampa apuntada para quien lo herede: la lectura tiene que devolver lo pedido
entero o el final del fichero, porque PhysFS envuelve casi todas sus lecturas en
`__PHYSFS_readAll`, que compara con la longitud pedida y da el archivo por
corrupto si no cuadra. Devolver de menos porque se acabó la ventana rompería el
montaje entero, y con un mensaje que no apuntaría aquí.


---

### 5.69 Lo que nadie contaba, y dónde estaba el jugador

Los diecisiete volcados de los tres jugadores del 5 y 6 de septiembre dejaban dos
huecos, y los dos estaban justo donde hacía falta mirar.

**El primero: el término que manda no lo contaba nadie.** El informe del montón
repartía la memoria así:

```
[monton] reparto: fondo 306 | img 74 | cad 12 | resto 676 MB (texturas vivas + motor + ruby)
```

Ese `resto` —entre 557 y 752 MB según el jugador— es lo que crece durante toda la
partida y de lo que no se sabía nada. La etiqueta era lo único honesto que se
podía escribir: los tres alijos que sí se miden son los que el motor recicla, y
las texturas que el juego tiene **abiertas ahora mismo** —cada sprite en
pantalla, cada tileset, cada retrato, cada cuadro de texto vivo— no pasan por el
fondo de texturas y por lo tanto no pasaban por ninguna cuenta.

Y ese es el número que explica el caso. El jugador del Pidgey se cayó con el
fondo en **259 MB**, muy lejos de su techo. Bajar el presupuesto del fondo de 512
a 192 MB (§5.64) sigue estando bien —el guardián necesita margen para su
reintento— pero no es lo que llena la GPU. Apagar el fuego del vecino no es un
error, es que no es el fuego.

Se cuenta en `gl-util.h`, que es el único sitio sin escapatoria: las tres puertas
por las que pasa toda textura de este motor son `TEX::allocEmpty` —las vacías,
incluido el guardián de §5.64—, `TEX::uploadImage` —las que se cargan de un PNG,
que son la mayoría y las gordas— y `TEX::del`, que es el único borrado. La tabla
va indexada por el nombre de OpenGL, que `glGenTextures` reparte pequeño, denso y
reciclado: un array plano que crece al doble es exacto y cuesta un
desplazamiento. La cuenta es en RGBA de cuatro bytes, que es lo que **pide** el
juego y no lo que nouveau acaba reservando; sirve para compararse consigo misma a
lo largo de una partida, que es para lo que se puso.

Hay un detalle que no es cosmético: `glTexImage2D` no dice sobre qué textura
trabaja, trabaja sobre la que esté atada. Para apuntar el gasto en la cuenta
correcta hay que recordarlo en `TEX::bind`, que es el único sitio donde ese dato
existe. Y reespecificar una textura que ya existía sustituye lo que hubiera, así
que hay que descontar lo viejo antes de sumar lo nuevo: pasa de verdad y no poco
—el guardián reintenta sobre el mismo nombre, y `gpTexFBO` se reespecifica cada
vez que hace falta más grande— y sin esa resta el contador subiría sin que nadie
hubiera pedido memoria.

La línea nueva sale cada treinta segundos, al lado de las otras:

```
[monton] texturas vivas: 612 MB en 1843 | pico 671 MB en 1902
```

El pico va al lado del valor de ahora porque cuando llega una caída lo que
importa no es lo que hay, es **lo que llegó a haber**.

**El segundo hueco: de dieciséis de los diecisiete volcados no se sabe dónde
estaba el jugador.** El del Pidgey se pudo entender porque el jugador lo contó
por escrito —Ciudad Verde, ruta 1, un Pidgey—; los otros son una dirección de
memoria y nada más. Y el sitio es la mitad del diagnóstico: lo que agota la
memoria de vídeo es lo que hay cargado, o sea el mapa y lo que hay encima.

`NX.log()` ya existía, pero escribe en `mkxp-ruby.log`, que es otro fichero y sin
sello de tiempo. Las líneas que hay que poder leer juntas son el `[exc]` de la
caída, los `[monton]` y los `[fondo]` de lo que había reservado, y ésta: las tres
primeras están en `mkxp-boot.log` con milisegundos delante. Así que se añade un
canal —`NXReg.traza`, un solo método, en `nx/nx_donde.cpp`— y el reportero de
mapa de `runtime/lib/nx-compat.rb` escribe por ahí:

```
[ 84412] [donde] mapa 24 Ruta 1 en (18,41)
```

El volcado se lee entonces de arriba abajo —«estaba aquí, tenía esto reservado, y
murió»— en vez de tener que casar dos ficheros sin reloj común.

El enganche está en `Graphics.update`, que corre sesenta veces por segundo, así
que dentro no hay más que leer un entero y compararlo; sólo cuando el mapa cambia
se arma la cadena. Y si `NXReg` no existe —escritorio, o un motor viejo— el
módulo se desengancha en la primera pasada y no queda ni la comparación.

**Y tres ficheros que llevaban semanas fuera del control de versiones.**
Buscando dónde enganchar los contadores apareció el mismo descuido de §5.64 dos
veces más: `src/` está en `.gitignore`, así que un fichero con un `.orig` al lado
y sin parche es trabajo que existe únicamente en la copia de una máquina.
`gl-util.h` llevaba así desde el 31 de agosto —el cronómetro de subida de
texturas— y `bitmap.cpp` tenía veintitrés trozos sin parchear: los dos alijos de
superficies ya cocinadas, el pegado diferido de `set_pixel` y todos los
cronómetros de §5.55. Ahora están en `patches/mkxpz-gl-util.patch` y
`patches/mkxpz-alijos-bitmap.patch`, y una comprobación de que ningún `.orig` del
árbol difiere de su fichero sin tener un parche que lo cubra sale limpia.

**Y una trampa de despliegue que costo veinte minutos.** Se subio el binario
nuevo a la consola, se jugo, y el registro seguia diciendo `1.0.0 b14`. En la
tarjeta habia **dos instalaciones** —`/switch/pokemon-anil`, con los datos en el
contenedor, y `/switch/pokemon-anil-off`, con las carpetas sueltas— y se lanzo la
segunda, que llevaba el binario de cinco dias antes. El registro de arranque no
podia delatarlo: su ruta esta fijada en `nx/nx_boot.c` y no depende de donde este
el `.nro`, asi que las dos instalaciones escriben en el **mismo**
`mkxp-boot.log`, una detras de otra, sin nada que las distinga salvo el sello de
compilacion —que era justo el dato en duda—. Ahora el arranque escribe tambien
`[nro]` con la ruta de `argv[0]`, cuatro lineas despues del sello: una dice
**que** binario y la otra **de donde** salio.

De ahi salio tambien el arreglo del directorio de trabajo. `chdir()` puede salir
bien y dejarte igual de perdido: con el `.nro` en la raiz de `/switch` —que es
donde hbmenu lo ensena en la primera pantalla, sin tener que bajar dos carpetas—
el directorio que sale de `argv[0]` es `/switch`, `chdir` funciona, y mkxp-z se
pone a buscar `mkxp.json` y `Data/` donde no hay nada. La comprobacion ahora es
la unica que decide —si `mkxp.json` esta ahi— y las ubicaciones de reserva son
las dos instalaciones convenidas, probadas por orden.

**Medido, y con una corrección.** Primera sesión con el contador puesto, 1.1.1
b66 en la consola, tres minutos de partida
(`docs/consola/20260906-121847/analisis.md`):

```
                 13,7 s      164 s     crece
malloc en uso     348 MB     777 MB     +429
  fondo             0 MB     189 MB     +189
  img               0 MB      73 MB      +73
  cad               0 MB       6 MB       +6
  resto           348 MB     509 MB     +161
    de ahí: texturas vivas
                    2 MB     245 MB     +243
    o sea, motor + ruby
                  346 MB     264 MB      -82
```

Aquí arriba se dijo que el `resto` era, en su mayor parte, texturas vivas. **No
lo es**: son menos de la mitad —245 de 509—. La etiqueta «texturas vivas + motor
+ ruby» era prudente y hacía bien en serlo.

Lo que sí resuelve la medida es §5.66, que quedó sin diagnosticar. **El motor y
Ruby no crecen: bajan.** Todo lo que sube son los tres alijos y las texturas que
el juego tiene abiertas, o sea cachés llenándose por diseño mientras se va
conociendo el mapa. El «gigabyte de montón en menos de diez minutos» no era una
fuga.

Y el presupuesto de §5.64 queda validado por el otro lado: el fondo se mueve
entre 149 y 189 MB toda la sesión, por debajo de los 192 sin llegar a rozarlos,
y el guardián no tuvo que reintentar ni una vez.

**Lo que queda por medir.** Tres minutos no son una partida. El pico de 272 MB de
texturas vivas es de los primeros cuarenta segundos y no se volvió a superar, que
es buena señal, pero hace falta una sesión larga para saber si se estabilizan o
siguen subiendo —y ahí, si suben, lo primero a mirar son las tiras de animación,
que se redondean a potencia de dos en las dos dimensiones—.

---

### 5.70 Los tirones, y qué se está midiendo antes de tocar nada

La primera sesión de la 1.1.1 en la consola no tuvo ni una caída, pero sí
**veintiocho tirones en tres minutos, el peor de 1,38 s**. No se pierde nada
—el proceso sigue vivo y la partida también— pero un fotograma de segundo y
medio se nota, y ahora que el proceso ya no se muere es lo siguiente.

El reparto de un tirón típico:

```
marco 945 ms | dec 1x 222 ms | abr 2x 236 ms | fis 2x 1 ms | resto 592 ms
```

**Hay una trampa de lectura ahí que conviene deshacer: `abr` no mide abrir.**
Mide `FileSystem::openRead` entera, y `openRead` llama al manejador, que para un
`Bitmap` es descomprimir el PNG. Abrir de verdad es `fis`, y son **2,5–3,5 ms
por fichero**: no es el problema. Los 220 ms son descomprimir **una** imagen. El
peor de la sesión son **452 ms en una sola**.

Y el otro término gordo es `resto` —hasta 832 ms con `cpu 825`—, que es Ruby
ejecutando scripts. Y un tercero, en los fotogramas de menú:

```
pool 316x 193 ms | nue 393x 198 ms | fondo 108 aciertos 189 MB 1500 tex
```

**393 texturas creadas contra 108 aciertos** en un solo fotograma. Eso cuadra
con la auditoría de los registros de los jugadores, que daba un 29–32% de
acierto sostenido.

**Lo que se ha puesto es instrumentación, no arreglos.** Dos medidas, las dos en
producción, porque las dos son baratas y ninguna de las dos preguntas se puede
contestar desde el PC:

**1. Qué fichero es el que tarda.** Saber que una apertura costó 222 ms y no
cuál es como no saber nada: no se puede juzgar si sobra resolución, si es una
tira de animación de las que se redondean a potencia de dos, o si es una imagen
que el juego pide en mitad de un fotograma pudiendo haberla pedido antes.
Cualquier apertura que pase de 40 ms deja su nombre:

```
[ 34211] [lento] 222 ms abriendo Graphics/Battlebacks/field_bg
```

**2. Si redondear los tamaños serviría de algo.** La sospecha lleva escrita
desde §5.55: los sprites de Pokémon son de tamaños **todos distintos**, y el
fondo guarda por tamaño exacto, así que un cubo con una sola textura dentro no
se reaprovecha jamás. Redondear —reservar un poco de más y declarar lo pedido—
convertiría cientos de cubos de uno en unas pocas decenas de cubos llenos.

Pero redondear **no es gratis**: reserva memoria de más, y en una consola donde
la GPU ya dice que no, gastar por si acaso es exactamente lo que no se hace a
ciegas. Así que se mide lo único que decide —de todos los fallos, cuántos
habrían sido aciertos con el tamaño redondeado— y se ponen las dos reglas
candidatas una al lado de la otra. La forma de la línea —los números son de
ejemplo, la medida todavía no está hecha— es ésta:

```
[fondo] fallos N | con multiplo de 16 serian aciertos N (N%, N tamanos)
        | con potencia de 2, N (N%, N)
```

Múltiplo de 16 gasta poco y agrupa poco; potencia de dos gasta mucho y agrupa
mucho. Con los dos números delante, la decisión es una resta y no una corazonada.
Lo mismo vale para el ejemplo de `[lento]` de más arriba: ese nombre de fichero
está inventado para enseñar el formato.
El censo son dos tablas abiertas de tamaño fijo, y si se llenan lo dice: un
número corto que se sabe corto es útil, uno que miente no.

---

### 5.70-bis Lo que dijeron las dos medidas

Cuatro minutos de partida con la instrumentación puesta, y las dos preguntas
tienen respuesta.

**La primera: el fichero que tarda es siempre el mismo.**

```
    6  225 ms abriendo Graphics/Tilesets/Exterior1
    4  227 ms abriendo Graphics/Tilesets/Exterior1
    2  226 ms abriendo Graphics/Tilesets/Exterior1
    ...
    2  193 ms abriendo Graphics/Tilesets/Interior1
```

**Veintiuna descompresiones de la misma imagen**, a 225 ms cada una: **4,7
segundos** de una sesión de cuatro minutos, y cada una de ellas un fotograma
parado. Más las cuatro de `Interior1`.

Y el motivo estaba a la vista en cuanto se supo el nombre. `Exterior1.png` mide
**256 × 23370** píxeles: es más alto que `maxTexSize`, así que no cabe en una
textura y entra por la rama de **«mega surface»**, que se queda en RAM. Y el
guardado en el alijo de imágenes estaba **en la otra rama del `if`**. O sea que
las imágenes más caras del juego —las únicas que no caben en la GPU— eran
justamente las únicas que no se reaprovechaban nunca.

El arreglo es de tres líneas y una sutileza: el dueño de una mega surface es el
`Bitmap` —`releaseResources()` la libera—, así que el alijo no puede quedarse
con la que entrega. Guarda una copia y reparte copias. Copiar 23 MB son unos
milisegundos; descomprimirla otra vez son 225.

**La segunda: redondear agruparía, pero el fondo no está preparado para
recibirlo.**

```
[fondo] fallos 5488 | con multiplo de 16 serian aciertos 5338 (97%, 150 tamanos)
                    | con potencia de 2, 5427 (98%, 61)
```

La sospecha de §5.55 era correcta y el número es contundente: **el 97 % de los
5.488 fallos habrían sido aciertos** redondeando al múltiplo de 16 más cercano,
y la potencia de dos sólo añade un punto por mucho más gasto. La regla barata es
la buena.

**Se implementó, se midió, y no servía.** La predicción era de sesenta y siete
puntos; lo medido, dos:

```
acierto del fondo    b72 (sin redondeo): 2.488 de 8.306  (30 %)
                     b77 (con redondeo): 1.902 de 6.004  (32 %)
```

**El censo contestaba a otra pregunta.** Contaba cuántos fallos eran de un tamaño
redondeado *ya visto antes*, y de ahí se dedujo que agrupar los cubos los
convertiría en aciertos. Pero un fallo del fondo no ocurre porque el tamaño sea
nuevo: ocurre porque **el cubo está vacío en ese momento**, o sea porque todas
las texturas de ese tamaño están vivas a la vez en manos del juego. Agrupar
tamaños no crea texturas libres donde no las hay.

El redondeo se quitó. No hacía daño —el contrato del fondo se mantuvo intacto,
reespecificando al entregar— pero añadía un camino de código y una sutileza de
contabilidad a cambio de nada. El razonamiento quedó escrito en `texpool.cpp`,
donde se lo encontrará quien vuelva a tener la idea, y el censo se quedó puesto
porque ahora se sabe leer: dice cuántos tamaños se repiten, no cuántos aciertos
se ganarían.

**Y redirige el trabajo.** Lo que sube el acierto del fondo no es la clave del
cubo: es tener menos texturas vivas simultáneas, o más presupuesto. En esa sesión
había **1.541 texturas vivas ocupando 257 MB** y el fondo tiene 192. Ahí está el
número que hay que mover, y es el mismo que §5.69 dejó apuntado.

### 5.70-ter Lo que sí funcionó: 31 segundos parados que pasan a 11

El alijo de mega surfaces, medido en la consola con la misma partida:

```
b72:  21 x Graphics/Tilesets/Exterior1  a ~225 ms
       4 x Graphics/Tilesets/Interior1  a ~195 ms
b77:   1 x Exterior1,  1 x Interior1
```

| | b72 | b77 |
|---|---|---|
| ficheros lentos (>40 ms) | 25 | **2** |
| tirones | 36 | **14** |
| tiempo total parado | 31,0 s | **11,2 s** |
| peor fotograma | 1.692 ms | 1.376 ms |

Cada tileset se descomprime exactamente una vez por sesión. Veinte segundos de
fotogramas parados que desaparecen en cuatro minutos de juego, arreglando una
rama del `if` que no guardaba en el alijo.

---

### 5.71 `patches/` todavía no basta para rehacer `src/`

`src/` está en `.gitignore`, así que **lo único que queda de todo el trabajo
hecho sobre mkxp-z son los parches de `patches/`**. Es una decisión razonable
—un árbol de fuentes de terceros no va en el repositorio— pero convierte esos
veintinueve ficheros en el único ejemplar de meses de trabajo, y hasta hoy nadie
había comprobado que basten.

Comprobarlo dio esto:

* **Tres ficheros no tenían parche ninguno**: `texpool.h`, `gl-util.h` y
  `bitmap.cpp` —éste con veintitrés trozos: los dos alijos, el pegado diferido
  de `set_pixel` y todos los cronómetros de §5.55—. Tenían su `.orig` al lado y
  nada más. Se habrían perdido en silencio el día que alguien clonara el
  repositorio en otra máquina. Ya están en `patches/`.
* **El orden de aplicación no está escrito en ninguna parte.** Cuatro parches
  tocan `filesystem.cpp` y tres tocan `main.cpp`; aplicarlos en otro orden no
  funciona, y ese orden vivía sólo en la cabeza de quien los hizo.
* **`reconstruir-src.py`** parte de `src/mkxpz.tar.gz` —el mkxp-z 2.4.2 original,
  que ya viajaba en el árbol— y **deduce el orden probando**: vuelta tras vuelta
  mira cuál de los que quedan aplica limpio sobre lo que hay. Luego compara
  fichero a fichero con `src/mkxp-z`.

**Y el resultado, hoy, es que no sale.** Coloca 17 de los 29 y deja 12 fuera, y
12 ficheros se desvían del árbol. Los motivos que ya están identificados:

* Dos parches nombran ficheros que en el 2.4.2 limpio no existen con ese nombre
  (`keybindings.cpp`, `audio.cpp`), señal de que se generaron contra un árbol que
  no es exactamente esta versión.
* Varios se generaron con `diff -u fichero.orig fichero` **dentro de la carpeta
  del fichero**, así que su cabecera es relativa a un sitio y no a la raíz. La
  herramienta ya resuelve eso llamando a `patch` desde la carpeta correcta, pero
  quedan casos donde la cola del nombre encaja en más de un sitio.
* Y de `sharedstate.cpp` no hay `.orig`: los dos parches que lo tocan se midieron
  contra un `.antes-rutas` que sólo existe en esta máquina.

**Esto no es una alarma: es el inventario que faltaba.** Nada de lo que funciona
hoy depende de que la reconstrucción salga —el árbol de trabajo está en el disco
y compila—, pero mientras no salga, `patches/` es una copia de seguridad que
nadie ha probado a restaurar. El trabajo pendiente es regenerar esos doce contra
el 2.4.2 limpio, uno a uno, y guardar `patches/ORDEN.txt`, que la herramienta
escribe sola en cuanto la reconstrucción cuadre.

---

### 5.72 La Pokédex esperaba a internet, y cada Pokémon se recortaba cien veces

Tres quejas de Randy jugando en la consola: que en la Pokédex, «si pulso A sin
querer en la barra se congela unos segundos»; que los menús tardan al cambiar
de Pokémon (equipo, resumen); y que los menús en general van a tirones.

**El banco.** Ninguna de las tres se puede medir con `nx-metodos.rb` en la
consola sin alguien delante pulsando, y conducir el juego del PC con
`keybd_event` pide el foco de teclado, que comparten tres agentes y otra sesión.
Así que `runtime/diagnostico/nx-banco-menus.rb` no pulsa nada: carga una
partida, abre cada pantalla con las mismas llamadas que el menú de pausa
(`PokemonPokedexScreen`, `pbPokemonScreen`, `PokemonSummaryScreen`,
`PokemonBagScreen`) y le da una **entrada de mentira**: `Input.trigger?`,
`repeat?`, `press?` y `dir4` devuelven lo que diga un guion de pasos («A en la
lista», «derecha hasta Datos», «A», «abajo»...), y el ratón no existe. Por cada
fotograma mide el tiempo de Ruby entre dos `Graphics.update` y, si pasa de
30 ms, apunta el paso y los métodos envueltos que más tardaron. Corrió sobre
una copia del Añil 4.13 de PC en `tmp/pc-anil/` (los `Graphics/` y `Audio/` son
uniones de directorio al original, que no se toca), con una partida del PC de
diez vistos y el equipo rellenado a seis en memoria. El PC es varias veces más
rápido que la consola; lo que vale es el reparto.

**1. «A en la barra» es la red.** La entrada de la Pokédex tiene cuatro
páginas y la última, Datos, es la del plugin *[MUI] Pokedex Data Page*. Pulsar
A ahí abre su menú, y lo primero que hace `pbDataPageMenu` —antes de pintar
nada— es `PokeAPI.get_data`, un plugin propio de Añil que compara las
estadísticas del juego con las oficiales:

```
[lento] 1204 ms | datos: A (menu de datos) | API#get_data 1x/1186ms  HTTP#get 2x/1180ms
        network_available? 1x/501ms  pbDownloadData 1x/679ms
```

`network_available?` es un GET por HTTPS a google.com para saber si hay red
(y si falla, otro a 1.1.1.1, otro a 8.8.8.8 y otro a api.github.com), y después
viene el JSON entero de `pokeapi.co/api/v2/pokemon/<especie>`. **1,2 segundos
con fibra en el PC**, en el mismo fotograma. Hasta la 0.1.x esto no existía en
la consola porque `HTTPLite` fallaba al instante; desde que el motor tiene red
(0.2.0, libcurl con el TLS del servicio `ssl`) se hace de verdad, por Wi-Fi.
Sin red es peor: cada intento son hasta 10 s de plazo de conexión, cuatro
intentos, y el fallo no se recuerda. Y no sólo con A: llevar el cursor del menú
a «estadísticas» o a «movimientos» también llama a `get_data` si esa especie no
está en la caché.

`juegos/pokemon-anil/lib/nx-pokeapi.rb`: `get_data` devuelve lo que haya en
caché **en ese momento**, y si no hay, lanza la descarga en un hilo de Ruby y
devuelve `nil` —lo mismo que el original sin red, que el plugin ya sabe
pintar—. `HTTPLite` suelta el GVL mientras espera, así que el juego sigue
dibujando. El resultado pasa a la caché desde el hilo principal (en `pbUpdate`
de la escena, nunca desde el hilo, porque esa caché vive en `$PokemonGlobal` y
se guarda con la partida); si la escena sigue en el menú de esa especie, recibe
`@api_data`, se repinta la nota y el botón Especial empieza a funcionar.
`network_available?` recuerda su respuesta (10 min si había red, 2 si no) y una
especie que falló no se reintenta en 2 minutos.

**Y de paso, la partida.** Cada entrada de esa caché guardaba el JSON entero de
PokeAPI: todos los movimientos con sus versiones, los sprites de todas las
generaciones. En la partida del PC, **dos especies vistas eran 455.440 bytes de
los 782.176 de la partida: el 58 %**, y cada especie mirada en Datos la
engordaba unos 190 KB más, que se escriben en cada guardado. El shim guarda
sólo lo que el juego vuelve a leer (`species`, `form`, `stats`, `abilities`,
`types`, `sprite_urls` y los sprites sin `versions`): **193.777 bytes por
entrada pasan a 2.376**, y las que ya trae una partida se adelgazan la primera
vez que se usa la caché.

**2. La página Datos recorría la Pokédex 4.556 veces.** Entrar en Datos, y
cada arriba/abajo dentro de ella, regenera las listas de «especies parecidas»:

```
drawPageData 1x/90ms  pbGenerateDataLists 1x/78ms  Sp#display_species? 4556x/77ms
```

`pbGenerateDataLists` recorre todas las especies y formas, y por cada una llama
hasta tres veces a `display_species?`, cuya primera línea es
`dexlist.any? { |dex| dex[:species] == @species }`: un recorrido lineal de las
1.027 entradas de la Pokédex **por llamada**, dos millones de vueltas de bloque
por especie mirada. `nx-datos.rb` responde a «¿está en la lista?» con un `Hash`
que se hace una vez por lista (y vive en la propia lista), y luego llama al
original con una lista de un elemento, para que el resto del método —lo que de
verdad decide— quede intacto. Comprobado contra el original en el banco:
**24.304 comparaciones, 0 diferencias.** Sólo se instala si
`display_species?` tiene la firma de cuatro argumentos de la versión de Añil
(la de Vanguard, por ejemplo, ya trae esa línea comentada).

**3. Cada Pokémon se recortaba entero para enseñar un fotograma.** Es la
firma de los tirones de menú en la consola —cientos de texturas nuevas en un
fotograma, `nue 393x` en §5.70— y en el banco tiene nombre:

```
pbUpdateDummyPokemon 1x/99ms  DeluxeBitmapWrapper#refresh 3x/68ms  Bmp.new(wxh) 276x/46ms
```

*[DBK] Animated Pokemon System* guarda cada Pokémon como una hoja con todos sus
fotogramas en fila, y `DeluxeBitmapWrapper#refresh` la recorta **entera** al
crearse: un `Bitmap.new` y un `stretch_blt` por fotograma, unos cien por
Pokémon, cada uno una textura. En la Pokédex son tres a la vez; en el resumen,
uno por cada cambio de Pokémon, y además `compile_strip` (que
`sprite_bitmap_from_pokemon` llama siempre) **tira ese recorte y lo rehace**
para pintar las manchas de Spinda, lo tenga o no la especie. `nx-tira.rb` ya
evitaba rehacerlo al cambiar de pestaña del mismo Pokémon; esto es el caso
general. `nx-fotogramas.rb` guarda la hoja y recorta cada fotograma la primera
vez que se pide: al abrir la pantalla cuesta uno, y los demás llegan de uno en
uno mientras la animación avanza; cuando están todos, la hoja se suelta. El
segundo recorte de `compile_strip` se omite cuando la especie no tiene función
`alterBitmap` (para Spinda se hace el original), y `hue_change` se recuerda
para los fotogramas que falten. Comprobado píxel a píxel contra el recorte
entero, con el tono de súper shiny aplicado: **979 fotogramas de 10 especies,
0 distintos.** En el recorrido del banco, de 2.301 fotogramas que el original
habría recortado se recortaron 806.

**Antes y después** (PC, peor fotograma de cada paso, ms). «Antes» lleva lo
que ya iba en la consola (`nx-rutas`, `nx-centro`, `nx-tira`, `nx-bolas`), y
para que `nx-centro` pueda instalarse en el PC el banco le da un
`nx_opaque_bounds` de mentira hecho sobre `raw_data`, con las mismas reglas que
el de `bitmap.cpp`:

| Paso | antes | después |
|---|---:|---:|
| Pokédex: A en la lista (abre la entrada) | 64 | 39 |
| entrada: derecha hasta Datos | 90 | 22 |
| **Datos: A (menú de datos)** | **952** | **20** |
| Datos: abajo/arriba (otra especie) | 150–172 | 45–80 |
| resumen: abrir | 71 | 24 |
| resumen: cambiar de Pokémon (cinco cambios) | 55–94 | 14–47 |
| resumen: volver al anterior (tres) | 50 | 17 |
| Suma del tiempo de Ruby en todo el recorrido | 3.203 | 1.887 |

Lo que sube un poco en algunos pasos (`entrada: derecha (área)`, de 14 a 43 ms
de total en 31 fotogramas) es el coste repartido a propósito: los fotogramas
del Pokémon que se van recortando mientras la animación avanza, uno por
fotograma; el peor fotograma de esos pasos no cambia.

**Por qué esto pesa tanto más en la consola.** En el registro de la sesión del
9 de septiembre (`docs/consola/20260909-180525-pokemon-anil/`) hay fotogramas
con `resto` —Ruby ejecutando, nada de E/S ni GPU— de 1,2 y hasta 1,9 s, y una
familia que se repite con la forma exacta de tres Pokémon recortados a la vez:

```
marco 252 ms | txt 44x 1 ms | pool 344x 175 ms | nue 344x 179 ms | resto 29 ms
```

344 texturas nuevas en un fotograma son tres hojas de unos 115 fotogramas: la
entrada de la Pokédex, o la página Datos al cambiar de especie. Y el Ruby de la
consola va del orden de diez a veinte veces más despacio que el del PC, así que
los 78 ms de `pbGenerateDataLists` del PC son más de un segundo allí, antes de
contar la red.

**En el emulador.** El banco corrió también en Ryujinx con el `.nro` de la
tarjeta y los tres shims en `preloadScript` (la partida de la tarjeta, Litten y
151 especies en su Pokédex regional, con el equipo rellenado en memoria). Las
dos comprobaciones de equivalencia salen igual que en el PC —**0 diferencias en
24.304 comparaciones y 0 fotogramas distintos de 979**—, así que los shims se
instalan y hacen lo mismo en el binario de la consola. Los tiempos del
emulador no se pueden leer como los de la consola —Ryujinx traduce cada
operación de GPU, y la lectura de una textura (`get_pixel`, `nx_opaque_bounds`
sobre un sprite recién pintado) le cuesta 30–55 ms—, pero el microbanco del
mismo fichero dejó dos cosas que mirar en la consola de verdad: `set_pixel`
alternado con cualquier otra operación de dibujo cuesta 25 ms por pareja (el
pegado diferido tiene que volcarse cada vez), y eso es lo que hace el hexágono
de estadísticas de Marin Better Bitmaps en las páginas 3–5 del resumen, con
100–190 `set_pixel` por dibujo; y `draw_text` va a 1,7 ms, que en la lista de la
Pokédex son 180 llamadas al abrirla. En la consola, el registro da `draw_text`
a ~0,4–0,6 ms (`txt 1040x 589 ms`) y el `set_pixel` sin coste visible (`pix 1x
1–7 ms`), así que ninguna de las dos se ha tocado aquí.

**Lo que no está resuelto ni medido aquí.** Que «la barra» sea la página Datos
es la lectura más probable —es la última página, A ahí no hace nada visible y
es lo único de la Pokédex que tarda segundos—, pero no se le ha preguntado a
Randy. El banco no ha corrido en una consola de verdad: los números son del PC
y del emulador, y el emulador tiene la red apagada (`enable_internet_access`),
así que la descarga en segundo plano por Wi-Fi —`HTTPLite` desde un hilo que no
es el principal— está probada en el PC pero no en Horizon. Para medirlo allí:
`nx-banco-menus.rb` en `lib/` y en `preloadScript` detrás de los shims, y en la
carpeta del juego `banco-menus.flujo` con `dex` y `banco-menus.sincache`; deja
`banco-menus.log` y sale sin guardar.

Queda también, sin tocar:

* Otra espera a la red en el hilo principal, que no es de menús: la pantalla de
  carga llama a `PokeUpdater.check_for_updates`, que es `network_available?`
  más una descarga de pastebin. Desde la 0.2.0 eso se espera de verdad, una vez
  por arranque (con este shim, el «hay red» que deja le sirve luego a la
  Pokédex).
* La lista de la Pokédex: abrirla son ~50 ms de Ruby en el PC
  (`pbRefreshDexList` y el `Window_Pokedex` pintando sus filas con
  `draw_text`), el orden de medio segundo en la consola.
* El hexágono de estadísticas del resumen (`set_pixel` uno a uno) y el texto,
  que son del motor y no de un plugin: si la consola confirma lo que dice el
  emulador, el arreglo es un `draw_line` que junte los píxeles y los pegue de
  una vez, en `bitmap.cpp`.

### 5.73 La pantalla táctil

Randy, jugando en portátil: que el PC de cajas se pueda manejar con el dedo,
y si se puede el resto de la interfaz. Hasta aquí la pantalla táctil de la
consola estaba **muerta**, y no por falta de una línea en Ruby.

**Lo que había en el motor.** mkxp-z 2.4.2 sí recibe los dedos: `eventthread.cpp`
guarda hasta cuatro en `EventThread::touchState`. Pero nadie lo lee —ni `Input`
ni ningún binding de Ruby lo expone—. Y los eventos de ratón que SDL sintetiza a
partir de un toque se tiran a propósito (`event.button.which ==
SDL_TOUCH_MOUSEID`, en el filtro de entrada del bucle de eventos), para que en
un portátil con pantalla táctil el mismo toque no llegue dos veces. Resultado:
un juego no podía enterarse de un toque de ninguna manera.

**El motor: un dedo es el botón izquierdo del ratón.** Lo más pequeño que sirve
es no inventar API: en Horizon, el primer dedo que se apoya mueve `mouseState` y
aprieta el botón izquierdo hasta que se levanta; un segundo dedo se ignora
(`nxDedoComoRaton`, `patches/mkxpz-tactil.patch`). Ruby lo lee como lee el ratón
en el PC —`Input.mouse_x`, `Input.mouse_y`, `Input.press?(Input::MOUSELEFT)`—, y
ya en coordenadas de la **pantalla lógica** del juego (512×384 en Añil), porque
`Input::mouseX` les resta `screenOffset` y les aplica `sizeResoRatio`, las
mismas cuentas del encaje con franjas negras de 43b1bed.

No se aprovechan los eventos sintéticos de SDL por un detalle de unidades: vienen
en las de `SDL_GetWindowSize`, que en devkitPro contesta 1920×1080 también en
portátil, mientras que `screenOffset` se calcula sobre la superficie que mide
`nx_resolucion_pantalla` (§5.46 y `nx_pantalla.c`). El dedo de SDL llega
normalizado de 0 a 1 sobre la pantalla entera; multiplicado por esa misma medida
cae en el sistema que `Input` espera. Medido en Ryujinx: un toque mandado al
píxel lógico (406, 38) llega a Ruby como (402, 44) con el ruido del emulador, y
con el arreglo de abajo en `jugar.ps1`, exacto.

Un toque rápido tampoco se pierde. El hilo RGSS mira el botón una vez por
fotograma, y un toque de 40 ms en un fotograma lento (una carga, un combate)
cabría entero entre dos miradas. Si el dedo se levanta antes de que
`Input::update` lo haya visto apretado, la suelta se aplaza a justo después de
esa lectura (`EventThread::nxRatonVisto`). Quién suelta se decide con un
compare-and-swap, porque el hilo de eventos y el RGSS pueden llegar a la vez.

**Ruby: traducir, no reescribir.** Essentials no sabe de ratones: cada pantalla
lee la cruceta y A/B. Reescribir sus bucles —y los de cada plugin, que en Añil
redefinen el PC, la mochila, el menú de pausa, el combate— no acaba nunca.
`runtime/shims/nx-tactil.rb` (shim `tactil` del catálogo, encendido en el perfil
de Añil) hace tres cosas:

1. **Decide al principio del fotograma.** En `Input.update`, contra lo que
   estaba en pantalla en el fotograma anterior: cada lista, cada escena con
   cursor propio y cada mensaje se *registran* al actualizarse. Así da igual que
   el bucle de la escena mire los botones antes o después de actualizar sus
   ventanas, que en Essentials hay de las dos maneras.
2. **«Pulsar A» es inyectar**: durante ese fotograma `Input.trigger?(Input::USE)`
   contesta que sí, como si el jugador lo hubiera apretado. El bucle original
   hace el resto, con sus sonidos y sus reglas. Una inyección que nadie ha
   mirado sobrevive a un `Input.update` de más en el mismo fotograma (los hay,
   y se llevaban el toque sin rastro); una que ya se vio, no, que es justo lo
   que quiere quien vacía la entrada después de aceptar.
3. **«Llevar el cursor allí»** depende de la pantalla. En las listas se fija el
   índice dentro de su propio `update`, para que la escena vea el cambio igual
   que con la cruceta (la mochila repinta la descripción comparando el índice
   de antes y el de después). En el PC y en el equipo se inyecta una flecha y
   se intercepta `pbChangeSelection`, que es a quien esos bucles preguntan a
   dónde va el cursor; la respuesta sólo vale en ese fotograma, para que una
   flecha de verdad más tarde no salte a un sitio olvidado.

Las clases de Essentials no existen cuando corre el preload, así que los
módulos se **anteponen** (`Module#prepend`) la primera vez que existe cada una.
Anteponer y no aliasar: Añil redefine `SpriteWindow_Selectable#update` entero
en un script suyo (`Bag with interactuable party`) y `pbSelectBoxInternal` en
otro (`Storage System Utilities`), y lo antepuesto queda delante de cualquier
`def` posterior.

**Qué responde** (probado en Ryujinx en modo portátil, con la partida de
Randy):

| Pantalla | Toque |
|---|---|
| Cargar partida | tocar un panel lo elige; tocar el elegido carga |
| Menú de pausa (DP Pause Menu) | tocar un botón lo elige (a pasos, con su animación); tocar el elegido entra |
| Listas (`SpriteWindow_Selectable` y todas sus hijas: Sí/No, menús de comandos, mochila; la tienda y la Pokédex son de la misma familia, pero no se han abierto en la prueba) | tocar elige, tocar lo elegido confirma, arrastrar en vertical desplaza, deslizar de lado es izquierda/derecha |
| Mensajes | mientras se escriben o esperan, tocar en cualquier sitio es A |
| PC de cajas | ver abajo |
| Equipo | tocar un Pokémon lo elige; tocar el elegido abre su menú; «Salir» igual |
| Mochila | además de la lista, tocar el icono de un bolsillo va a él |
| Resumen | deslizar de lado cambia de página; de arriba abajo, de Pokémon |
| Combate | Luchar/Mochila/Pokémon/Huir y los cuatro movimientos: tocar elige, tocar lo elegido acepta |

**El PC.** Tocar una casilla lleva allí el cursor (y el panel de la izquierda
enseña el Pokémon); tocar la que ya estaba seleccionada es A, con su menú
(«Mover», «Datos», «Sacar»...). **Arrastrar** un Pokémon lo coge y soltarlo en
otra casilla lo deja, sin menú: es el «cambio rápido» del propio juego,
encendido sólo para ese gesto (`quickswap` contesta que sí justo cuando
`pbStartScreen` lo mira). Soltarlo encima de otro es, para el juego, un
intercambio que deja al otro en la mano; con el dedo eso no tiene sentido —el
gesto era «pon este aquí»—, así que el desplazado vuelve solo a la casilla de
la que salió el primero (en el equipo, que se compacta al coger, al primer
hueco). Soltar el dedo mientras el juego aún anima la cogida no se pierde: se
espera a que la caja vuelva a mirar los botones. Las flechas de la caja cambian
de caja (también arrastrando un Pokémon encima), el nombre abre el menú de la
caja, «Equipo» saca la pestaña y «Salir» pregunta. En la pestaña del equipo,
igual con sus huecos; «Atrás» o tocar fuera de la pestaña la cierra.

**Qué no.** Un toque que no cae sobre nada de lo anterior no hace nada: no hay
«tocar fuera = B» salvo en la pestaña del equipo del PC. El mapa, el menú de
objetivos del combate (su índice es el del combatiente y fijarlo a mano podría
elegir uno que no vale), el teclado de texto y las pantallas propias de cada
plugin que no son listas siguen siendo de botones.

Todo lo de la tabla se ha visto funcionar en el emulador, con capturas: el
`Window_CommandPokemon` del menú del PC (de «Mover» a «Cancelar» y aceptar), el
Sí/No de «¿Desea salir de la caja?», el bolsillo de Medicinas tocando su icono
y la descripción del objeto cambiando al tocar otro, la página de notas del
resumen deslizando, y un Arañazo elegido y lanzado contra un Rattata con dos
toques. En el PC: Bulbasaur arrastrado a una casilla vacía; Pikachu soltado
encima de Bulbasaur (se cambian y la mano queda vacía); Pikachu llevado de la
caja 1 a la 2 pasando el dedo por la flecha y dejado allí con un toque; Litten
arrastrado sobre otro del equipo; las flechas, «Equipo», «Atrás» y «Salir».

**Cómo se probó.** Ryujinx hace de cada clic izquierdo sobre su ventana un dedo
en la pantalla táctil, pero sólo en modo portátil, y en esta máquina arranca en
modo base: `jugar.ps1 -Portatil` le pasa `--handheld-mode`. `jugar.ps1` ganó
`toque:x,y` y `arrastre:x1,y1,x2,y2` en píxeles de la pantalla lógica: mide
dónde está la imagen del juego dentro del área de cliente (la tira negra más
larga de la columna izquierda es la franja lateral del 4:3), y antes de apoyar
el dedo menea el ratón un píxel, porque Ryujinx no se entera de un
`SetCursorPos` hasta que llega un movimiento de verdad y el dedo se apoyaba
donde estuviera antes el ratón. De paso, `Enfocar` ya no podía con el primer
plano (Windows sólo deja cambiarlo a quien recibió la última entrada; se engancha
la cola de entrada del hilo con `AttachThreadInput`, porque la alternativa de
pulsar Alt abría la barra de menú de Ryujinx y las teclas siguientes se iban a
ella) y restaura la ventana si alguien la ha minimizado.

El PC se abrió con un arnés de prueba que no va al repositorio (tocar una
esquina del mapa rellena la caja 1 y el equipo en memoria y abre
`PokemonStorageScreen`; otra esquina empieza un combate con un Rattata); la
partida no se guardó. Con `tactil-traza.txt` en la carpeta del juego el shim
apunta cada movimiento y cada suelta; sin él, sólo una línea por toque
(`[tactil] toque en 274,80 -> PokemonStorageScene`), que es lo primero que hay
que mirar cuando un toque «no hace nada».

**Lo que queda.** No se ha probado en una consola de verdad: el identificador
de dedo de Horizon no tiene por qué ser pequeño (por eso el dedo se lee antes
del filtro de `MAX_FINGERS`), y el ruido de un dedo real es mayor que el de un
ratón (el umbral de arrastre son 10 píxeles lógicos). Las geometrías del PC,
del menú de pausa y de los bolsillos son las de Añil (v21 con sus plugins); en
otro Essentials las listas y los mensajes funcionan igual, y el PC depende de
que la caja siga en (184, 18). Por eso el shim no va «siempre» todavía: lo
enciende cada perfil.

---

## 5-bis. Criterio de diseño para los stubs

Auditando `libc.a`, `libsysbase.a` y `libnx.a` con `nm`, el reparto es:

- **Presente** — toda la capa de archivos: `getcwd`, `opendir`, `readdir`,
  `realpath`, `lstat`, `fsync`, `ftruncate`, `dup2`, `readlink`, `symlink`…
- **Ausente** — el modelo de procesos, usuarios y señales: `waitpid`, `execv`,
  `getpgrp`, `setsid`, `getuid`, `sigaction`, `sigprocmask`, `pipe`…

**Regla aplicada:** solo se añade un stub cuando el compilador o el enlazador lo
exige, y se mantiene `ac_cv_func_X=no` para que Ruby siga eligiendo sus rutas de
respaldo. Convencer a `configure` de que una función existe cuando en realidad
es un stub vacío haría que Ruby tomase caminos que fallan **en silencio** —
mucho peor que un error de compilación.

---

## 6. Hitos

- [x] **H0** — Entorno: devkitA64 r30 / GCC 16.1.0 / libnx 4.12.0 + 11 deps
- [x] **H1** — **CRuby 3.1.7 → `libruby-static.a` (44 MB, 87 objetos)** ✅
      `elf64-littleaarch64` verificado. Los 12 símbolos de la API de embebido
      presentes: `ruby_init`, `ruby_setup`, `rb_eval_string_protect`,
      `ruby_init_stack`, `rb_funcall`…
      Hasta donde he podido verificar, **es la primera compilación de CRuby
      para homebrew de Nintendo Switch**.
- [x] **H2** — **`hello-ruby-nx.nro` (3,3 MB) — Ruby enlazado en un homebrew** ✅
      Magic `NRO0` verificado en offset 0x10. ELF de 23 MB, `elf64-littleaarch64`,
      6947 símbolos de código. `ruby_init`, `ruby_setup`, `ruby_init_loadpath`,
      `ruby_cleanup`, `rb_eval_string_protect`, `rb_intern`, `ruby_sysinit`
      presentes, junto con los 21 stubs de `libnxcompat`.
      Secciones TLS colocadas correctamente por `switch.ld`
      (`.text` en 0x0, `.tls.align` en 0x2ca330, `.main.tls` en 0x333b08).
      Extensiones estáticas incluidas: **`Init_zlib`, `Init_stringio`,
      `Init_strscan`** + `deflate`/`inflate` de la libz de Switch.
      NRO final: 3,45 MB · 7338 símbolos de código.
      **VERIFICADO EN CONSOLA REAL con Atmosphere: 23/23 pruebas OK**,
      incluidos los 4 parches de compatibilidad de mkxp-z
      (`docs/test-results-hardware-real.txt`).
      El resultado es **idéntico línea por línea** al de Ryujinx 1.3.3 con
      firmware 20.5.0 (`docs/test-results-ryujinx.txt`), lo que además convierte
      al emulador en un sustituto validado del hardware para iterar en H4.
- [x] **H3** — **Dependencias que devkitPro no empaqueta, portadas** ✅
      `libpixman-1.a` (7,1 MB) · `libSDL2_sound.a` (2,5 MB) ·
      `libiconv.a` (1,9 MB) · `libuchardet.a` (782 KB).
      Todas `elf64-littleaarch64`, verificadas por símbolo real.
      Lista tomada del `meson.build` de mkxp-z — **no usa sigc++**, al
      contrario de lo que asumí al principio.
- [x] **H3a** — Parches de compatibilidad mkxp-z aplicados a Ruby y
      **verificados en ejecución** (23/23) ✅
- [x] **H4** — **El juego arranca, dibuja y se juega** ✅
      `pokemon-anil.nro`, **17,2 MB**. Las 70 fuentes de mkxp-z más 8 del
      backend de Switch. Comprobado de punta a punta bajo Ryujinx: pantalla de
      título animada con música, menú principal, y la introducción del profesor
      Oak avanzando con el botón A, a **60,0 fps** sostenidos.
      GLES 3.2 sobre nouveau real (26 shaders), PhysFS con 22.141 ficheros,
      CRuby 3.1.7 ejecutando Essentials 21.1 y sus 320 plugins sin un error,
      hilos de Ruby con planificador (§5.39, §5.40, §5.42), HID con el reparto
      de botones de Nintendo (§5.45) e imagen 4:3 centrada en 1920x1080.
      **Falta**: la consola real. El guardado, la carga y el combate ya están
      comprobados; ver §10.
- [x] **H5** — **Paquete de SD listo: 702 MB, 22.141 ficheros** ✅
      `out/sdcard/switch/pokemon-anil/`. 112 MB y 3.687 ficheros de lastre de
      escritorio retirados. `mkxp.json` reescrito para 1280×720 (imagen de
      960×720, escala exacta 1,875×) con sus 22 claves contrastadas contra
      `config.cpp`. Biblioteca estándar de Ruby 3.1.7 recortada (1,2 MB) +
      sustitutos de `socket`/`io/wait` que **desbloquean el arranque** (§5.25).
      0 nombres no ASCII, 0 caracteres ilegales en exFAT, ruta más larga 74 B.
- [ ] **H6** — Optimización. **La mitad hecha**: `createPathCache` bajó de
      56.065 ms a 300 recorriendo el árbol con `readdir` en vez de con un
      `PHYSFS_stat` por fichero (§5.48), y el intérprete Ruby arranca a los
      **4,8 s** donde antes tardaba más de sesenta. Los tirones de los menús
      resultaron ser código del juego (plugins barriendo sprites píxel a píxel
      desde Ruby) y se arreglaron en `runtime/lib/nx-*.rb` sin tocar el reloj:
      el juego va bien a la frecuencia de fábrica. Queda la coroutine arm64.
- [x] **H7** — **NSP instalable: el juego deja de ser homebrew** ✅
      `out/pokemon-anil.nsp`, **11 MB**. Icono propio en el menú HOME, arranque
      directo y presupuesto de aplicación: **3.264 MB de montón** medidos con
      `svcGetInfo` (`nx/nx_memoria.c`). El mismo ELF pasado por `elf2nso`; NPDM
      derivado del de nx-hbloader; ID de título `0x05414E494C000000`. Los 702 MB
      de datos siguen en la SD, porque el RomFS de un NCA es de solo lectura y
      ahí no se podría guardar la partida. Comprobado bajo Ryujinx: arranca,
      dibuja y llega al menú principal (§5.47).

## 7. Reproducir

```bash
# Desde el shell MSYS2 de devkitPro
/c/anilswitch/build-ruby-switch.sh    # configure + make de CRuby
/c/anilswitch/make-resume.sh          # reanudar compilacion (incremental)
/c/anilswitch/finalize-ruby.sh        # sustituir dmyext.o e insertar extensiones

cd /c/anilswitch/hello-ruby-nx && make   # generar el NRO
```

Logs en `docs/configure-log.txt` y `docs/make-log.txt`.

### Probar en la consola

El NRO listo está en `out/sdcard/switch/hello-ruby-nx.nro`.

1. Copiar a la tarjeta SD en `/switch/hello-ruby-nx.nro`
2. Arrancar Atmosphère y abrir el **Homebrew Menu**
3. Lanzar *Ruby on Switch*

### Resultado verificado (Ryujinx 1.3.3, firmware 20.5.0)

```
[ OK ] version     3.1.7          [ OK ] require     true
[ OK ] plataforma  aarch64-elf    [ OK ] zlib        rxdata
[ OK ] aritmetica  5050           [ OK ] stringio    ok
[ OK ] cadenas     LINA NOMEKOP   [ OK ] strscan     a
[ OK ] bloques     [1, 4, 9]      [ OK ] rxdata      script
[ OK ] hash        {:a=>10,:b=>20}[ OK ] alloc       5000
[ OK ] struct      [4, 5]         [ OK ] GC.count    3
[ OK ] excepcion   capturada      [ OK ] GC.stat     3
[ OK ] marshal     {:s=>[1,2]...} [ OK ] GC.start    sobrevivio
                                  [ OK ] post-GC     110

=== RESULTADO: 19 OK, 0 fallos ===
```

La prueba **`rxdata`** es la decisiva:
`Marshal.load(Marshal.dump(Zlib::Inflate.inflate(Zlib::Deflate.deflate(...))))`
— exactamente la tubería con la que Pokémon Essentials lee cada archivo de
mapas, scripts y datos del juego.

Salida completa guardada en `docs/test-results-ryujinx.txt`.

### Instalar el juego en la consola

```bash
/c/anilswitch/pack-anil.sh          # 702 MB de datos -> out/sdcard/
cd /c/anilswitch/mkxp-z-nx && make  # el binario
/c/anilswitch/empaquetar-nsp.sh     # -> out/pokemon-anil.nsp (11 MB)
```

Y a la tarjeta, con la SD montada en `F:`:

```powershell
robocopy "C:\anilswitch\out\sdcard\switch\pokemon-anil" "F:\switch\pokemon-anil" `
         /E /NFL /NDL /NJH /NP /R:2 /W:2 /MT:8
Copy-Item "C:\anilswitch\out\pokemon-anil.nsp" "F:\pokemon-anil.nsp"
```

22.148 ficheros, 668 MB, unos 4 minutos a los 3,4 MB/s que da la tarjeta. Los
datos van **en la SD y no dentro del NSP**, por lo que explica §5.47: la RomFS
de un NCA es de sólo lectura y no se podría guardar la partida.

**Cómo lanzarlo, que no da igual.** Hay tres maneras y una no funciona:

| Vía | Memoria | ¿Sirve? |
|---|---|---|
| Menú homebrew abierto desde el **álbum** | ~448 MB | **No.** El juego pide 716 (§5.53) |
| Menú homebrew **suplantando título** (mantener R al abrir un juego) | de aplicación | Sí, y no hay que instalar nada |
| **NSP instalado**, icono en el menú HOME | de aplicación | Sí |

Para iterar, la segunda: mantener **R** mientras se abre cualquier juego
instalado abre el menú homebrew con presupuesto de aplicación, y ahí ya sale
*Pokémon Añil*. Cambiar de versión es copiar un `.nro` de 17 MB.

Para dejarlo puesto, la tercera: instalar `pokemon-anil.nsp` con DBI, Goldleaf o
Awoo. Hace falta que Atmosphère tenga **sigpatches**, porque los NCA van
firmados con tus claves y no con las de Nintendo. Después, *Pokémon Añil 4.0*
aparece en el menú HOME con su icono.

`empaquetar-nsp.sh` busca las `prod.keys` en `~/.switch/` y, si no están, en la
carpeta de Ryujinx; se puede señalar otra con `CLAVES=/ruta/prod.keys`. Esas
claves salen de tu propia consola con Lockpick_RCM y de ningún otro sitio.

### Qué mirar después de la primera vez

En el emulador las trazas se leen en caliente. En la consola no: si el juego se
cae, la pantalla se queda negra o salta el panel de error de Horizon, y lo único
que sobrevive es lo que llegó a escribirse en la SD. Con la tarjeta de vuelta en
el PC:

```powershell
C:\anilswitch\recoger.ps1
```

Busca la SD sola —la unidad extraíble que tiene a la vez `/atmosphere` y
`/switch`—, copia los cuatro registros del juego, las partidas `.rxdata` y los
informes recientes de `atmosphere/crash_reports` y `fatal_errors` a
`docs/consola/<fecha>/`, y saca por pantalla las líneas `[mem]` y `[gfx]`, el
final del arranque y el `errorlog.txt` si tiene algo.

Los informes de Atmosphère importan porque cubren justo el hueco que deja
`nx/nx_excepcion.c`: sirven cuando el fallo ha sido tan temprano que nuestro
manejador todavía no estaba puesto.

> Aviso al leer fechas: el reloj de esta consola va **24 años adelantado** y sus
> ficheros salen fechados en 2050. Por eso `recoger.ps1` se queda con los N
> informes más recientes en vez de filtrar por fecha: ordenar sólo exige que el
> reloj sea consistente consigo mismo, no que acierte.

Y el diagnóstico, por síntoma:

| Lo que se ve | Lo que significa |
|---|---|
| Pantalla negra y **no hay `mkxp-boot.log`** | No se llegó ni al primer constructor: el NRO no cargó. Comprobar que el fichero se copió entero (`Get-FileHash`) |
| El registro dice `como applet — MEMORIA REDUCIDA` y muere | Es el caso malo de la tabla de arriba (§5.53). Relanzar suplantando título, o instalar el NSP |
| Llega a `[boot] 11` y se para | Ruby arrancó y algo de Essentials falló: la respuesta está en `errorlog.txt` |
| Panel de error de Horizon con un código | `crash_reports` trae registros y pila; para traducir el PC, el `addr2line` de abajo |
| Va, pero lento | La consola no es el emulador. `Status-Monitor-Overlay` ya está en la SD y da fps en vivo |

**ReverseNX-Tool** permite forzar sobremesa o portátil sin tocar la base, que es
la manera de comprobar §5.49 en hardware de verdad.

---

## 8. Análisis de assets → dependencias eliminadas

Inventario real de `Pokemon Anil`:

| Tipo | Cantidad | Implicación |
|---|---|---|
| PNG | 17.815 | SDL2_image + libpng ✅ |
| WAV | 2.188 | SDL_sound nativo ✅ |
| OGG | 1.702 | libvorbis ✅ |
| MP3 | 44 | mpg123 ✅ |
| **MID** | **1** | ⚠️ **fluidsynth NO merece la pena** |
| Vídeo (ogv/avi/mp4) | **0** | ⚠️ **libtheora INNECESARIA** |
| JPG / GIF / BMP | 9 | soporte básico de SDL2_image |

**Dos dependencias eliminadas:**

- **fluidsynth** — era el port más difícil (API compleja, sin paquete devkitPro).
  Asumí que habría que convertir ese único MIDI a OGG. **En H5 resultó que ni
  eso hace falta**: `title_dppt.mid` (2,5 KB) sólo aparece en presets
  *comentados* del plugin «Pantalla de Título Animada», cuya configuración
  activa es `"bgm:Titulo"` → `Titulo.ogg`, que ya existe. Es contenido muerto.
  El paquete de Switch lleva **cero ficheros MIDI**, así que `soundfont.sf2`
  (4 MB) se va con él y fluidsynth deja de ser una dependencia — por hecho
  comprobado, no por decisión de compromiso.
- **libtheora** — el juego no tiene vídeo. Se compila sin soporte de vídeo.

Esto reduce la superficie de porteo y quita ~5 MB del paquete final.

### Decisión de empaquetado

17.815 PNG + 2.188 WAV = muchísimos archivos sueltos. Abrir archivos en la SD
por FatFS es lento. Opciones:

1. **romfs embebido en el NRO** — un solo archivo, rápido, pero un `.nro` de
   814 MB es poco manejable y no permite parches.
2. **Assets sueltos en SD + PhysFS con `pathCache: true`** ← *elegida en H5*.
   mkxp-z ya cachea el árbol de rutas en memoria al arrancar, que es
   exactamente la mitigación para este problema.
3. **Un `anil-datos.zip` almacenado, montado por PhysFS** ← *añadida después,
   y ahora la de por omisión*. Resuelve lo que la opción 2 dejaba en pie, que no
   era el arranque sino **la copia a la tarjeta**: 22.148 ficheros no se copian
   a la velocidad de la tarjeta. Un solo fichero además se envía de una pieza y
   se comprueba con un hash. Sin comprimir, para no pagar `inflate` en cada
   lectura ni rebobinados al buscar dentro de un OGG. El detalle, en §5.58.

Las opciones 2 y 3 conviven: el `.nro` monta el contenedor si está y las
carpetas si no, y `Empaquetar.ps1` produce cualquiera de las dos formas.


---

## 9. H5 — El paquete de tarjeta SD

Construido por `pack-anil.sh`. Salida en `out/sdcard/`, que es un espejo literal
de la raíz de la tarjeta:

```
sdcard/
└── switch/
    ├── hello-ruby-nx.nro          ← prueba de H2 (23/23 en Ryujinx)
    └── pokemon-anil/
        ├── pokemon-anil.nro       ← pendiente de H4
        ├── mkxp.json              ← reescrito para Switch
        ├── Game.ini
        ├── preload.rb
        ├── Audio/    331 MB
        ├── Graphics/ 323 MB
        ├── Data/      48 MB
        ├── Fonts/    292 KB
        └── lib/      1,2 MB       ← stdlib de Ruby 3.1.7 + sustitutos
```

Con contenedor (`CONTENEDOR=zip ./pack-anil.sh`, o la casilla de
`Empaquetar.ps1`), las cuatro carpetas de recursos se sustituyen por un fichero
y la carpeta entera baja de 22.148 entradas a 15 más `lib/`:

```
        ├── pokemon-anil.nro
        ├── mkxp.json
        ├── Game.ini
        ├── preload.rb
        ├── anil-datos.zip   654 MB  ← Audio/ Graphics/ Data/ Fonts/, almacenado
        └── lib/             1,2 MB
```

Las partidas guardadas y los registros siguen escribiéndose sueltos en esa misma
carpeta: el contenedor es de sólo lectura y el juego no escribe dentro.

hbmenu recorre los subdirectorios de `/switch/`, así que el `.nro` puede vivir
junto a sus datos en vez de separarlos.

### Qué se quitó y por qué

| Retirado | Peso | Motivo |
|---|---|---|
| `poke_updater/` | 40 MB | Actualizador en Python + Tk. 1.084 `.pyc`, 61 `.pyd`, 128 `.tcl`. Nada de eso corre en Horizon. |
| `Game.exe` | 21 MB | Binario PE de Windows. |
| `Ruby Library 3.3.0/` | 17 MB | Biblioteca estándar de Ruby **3.3.0 para MinGW**, con extensiones `.so` de x64. Nuestro intérprete es **3.1.7**: mezclar versiones es pedir problemas. Sustituida por la stdlib 3.1.7 recortada. |
| `Audio/Game.exe` | 14 MB | Un segundo ejecutable escondido dentro de `Audio/`. |
| `x64-msvcrt-ruby310.dll` | 9,5 MB | Ruby 3.1 de Windows; ahora va estático dentro del NRO. |
| `soundfont.sf2` | 4,0 MB | Sin MIDI que sintetizar (§8). |
| `discord_game_sdk.dll` + `DiscordAPI_XP.dll` | 3,9 MB | Rich Presence de Discord. |
| `PBS/` | 3,1 MB | Fuentes de texto que Essentials sólo recompila en modo depuración. Los `.dat` ya compilados están en `Data/`. |
| `RGSS104E.dll`, `zlib1.dll`, `libgcc_s_seh-1.dll`, `libgomp-1.dll`, `libwinpthread-1.dll` | 1,4 MB | DLLs de Windows. |
| `settings.json`, `gamepad.json` | 4 KB | **De JoiPlay, no de mkxp-z**: `settings.json` apunta a `/storage/emulated/0` y `gamepad.json` trae códigos de tecla de Android. |
| `como_jugar_en_macos.pdf`, `Partida guardada.lnk`, `.nomedia`, `README.md`, `1LEE ESTO…txt` | 265 KB | Documentación y accesos directos. |

**814 MB / 25.828 ficheros → 702 MB / 22.141 ficheros.**

### Decisiones de `mkxp.json`

**Escalado.** La Switch entrega 1280×720 en ambos modos. `720 / 384 = 1,875`
exacto, y `512 × 1,875 = 960`: sale una imagen de **960×720** con bandas negras
laterales, sin recorte ni deformación. Por eso `integerScalingActive` va
**desactivado**: a 720p el único múltiplo entero que cabe es 1×, que dejaría el
juego a 512×384 en mitad de la pantalla. `smoothScaling` cubre el 1,875×.
`lanczos3Scaling` queda para H6 — filtra mejor, pero es un shader caro para una
GPU a 307 MHz en portátil.

**`pathCache`.** Ya viene `true` por defecto en mkxp-z v2.4.2; se deja explícito
porque en esta consola no es un lujo. Son 17.815 PNG y 2.187 WAV sueltos sobre
exFAT, y sin el índice en memoria cada `Bitmap.new` se convierte en una apertura
de FatFS.

**`preloadScript`.** `preload.rb` **no se carga solo** por estar en la carpeta:
el valor por omisión de `preloadScript` en `config.cpp:177` es un array vacío.
Hay que declararlo. (Con Ruby 3.1.7 no es crítico —`Dir.exists?` todavía
existe— pero silencia los avisos de obsolescencia.)

**`rgssVersion: 1`.** Fijado a mano en vez de dejar que se deduzca de
`Library=RGSS104E.dll`, para no depender de que el análisis de `Game.ini` se
comporte igual en Horizon.

Las 22 claves se contrastaron una a una contra la lista de opciones que
`src/config.cpp` reconoce: ninguna inventada.

### Validación del paquete

| Comprobación | Resultado |
|---|---|
| Restos de escritorio (`exe`/`dll`/`so`/`pyc`/`pyd`/`lnk`/`pdf`/`sf2`/`mid`) | **0** |
| Nombres con caracteres no ASCII | **0** de 22.141 |
| Caracteres ilegales en FAT32/exFAT (`< > : " \| ? *`) | **0** |
| Ruta relativa más larga | **74 B** (límite de Horizon ≈ 769) |
| `mkxp.json` como JSON | válido, 22 claves, todas reconocidas |
| Sustitutos de `socket`/`io/wait` contra el código real de Cable Club | **1 OK, 0 fallos** |

### Lo que queda pendiente en el paquete

1. **`pokemon-anil.nro`** — sale de H4.
2. **Dónde se guardan las partidas.** mkxp-z usa `SDL_GetPrefPath()`, que en
   Horizon no tiene un destino evidente. H4 debe fijarlo explícitamente a
   `sdmc:/switch/pokemon-anil/Saves/`, que es escribible.
3. ~~**Verificación en consola real.**~~ **Hecha.** `hello-ruby-nx.nro` se
   ejecutó en una Switch con Atmosphère y dio **23/23**, idéntico al emulador.
   CRuby 3.1.7 corre en hardware Horizon real.

---

## 10. H4 — Estado exacto

### Lo que ya funciona

`mkxp-z-nx/Makefile` compila **las 70 fuentes** (48 C++ de `src/`, 3 C de
`theoraplay`/`libnsgif`, 19 de `binding/`) y enlaza `pokemon-anil.nro`:

| | |
|---|---|
| Tamaño | 17.182.720 bytes |
| Magic | `NRO0` en offset 0x10 ✅ |
| ELF | `elf64-littleaarch64`, 31.110 símbolos de código |
| Referencias sin resolver | **0** |
| Secciones TLS | `.text` 0x0 · `.tls.align` 0xdc8e70 · `.main.tls` 0x1119ac0 — sin solapamiento |

Enlazados y comprobados por símbolo: `ruby_init`, `SDL_Init`, `alcOpenDevice`,
`PHYSFS_init`, `TTF_Init`, `IMG_Init`, `Sound_Init`, `uchardet_new`,
`libiconv_open`, `eglInitialize`, y 95 símbolos de pixman incluidas sus rutas
NEON.

### El muro superado: era el ASET (§5.32)

Al NRO le faltaba la sección `ASET` (icono + NACP) que `elf2nro` añade con
`--icon`/`--nacp`. Sin ella Ryujinx aceptaba el fichero pero **nunca cargaba la
imagen**: no llegaba ni a `LoadNsos`. Con ella:

```
Loader LoadNsos: Loading image 0 at 0x0000000008500000...
Application Loaded: Firmware Application Pokemon Anil 4.0 v4.0 [64-bit]
Hid SetupNpad: Connected Controller ProController to Player1
[boot] 1/3 primer constructor estatico — heap y __appInit sobrevividos
[boot] 2/3 ultimo constructor estatico — los 45 pasaron
[boot] 3/3 main() alcanzado
[boot] 4 antes de SDL_Init
[boot] 5 SDL_Init OK
[boot] 6 eventos de usuario OK, leyendo mkxp.json
[nx] getcwd -> sdmc:/switch/pokemon-anil
[nx] mkxp.json accesible: true
[nx] Data/Scripts.rxdata accesible: true
```

Lo que esto demuestra, y no es poco: **SDL2 inicializa vídeo y mando en Horizon**,
el mando queda emparejado, el directorio de trabajo se resuelve y el juego
encuentra sus datos en la tarjeta.

### Muro 2 resuelto: la configuración por usuario (`SDL_GetPrefPath`)

Con trazas finas dentro de `readConfFile` quedó claro que **mi sospecha sobre
uchardet era infundada**: funciona sin problema en Horizon.

```
[boot] 6a readConfFile: antes de fileExists
[boot] 6b fileExists OK, leyendo el fichero
[boot] 6c fichero leido, convirtiendo codificacion
[boot] 6d entrando en uchardet_new
[boot] 6e uchardet OK          <- uchardet funciona
[boot] 6f codificacion OK, parseando JSON
[boot] 6g JSON parseado        <- mkxp.json se lee entero
[boot] 6d ... 6e ...           <- segunda conversion (titulo de Game.ini)
[boot] 6a readConfFile ...     <- SEGUNDA llamada, y aqui se colgaba
```

El cuelgue era la **segunda** llamada a `readConfFile`, la del `mkxp.json` del
directorio de preferencias del usuario (`config.cpp:270`). Esa ruta sale de
`prefPath()` → `SDL_GetPrefPath()`, que en Horizon no tiene destino: devuelve
vacío, `customDataPath` queda vacío, y `normalizePath("" + "/mkxp.json")`
termina resolviendo una ruta sin dispositivo. `fileExists()` sobre eso se
quedaba colgado **sin lanzar excepción**, que es por lo que el `try/catch` de
`readConfFile` no registraba nada.

### Estado: el juego se juega

Pokémon Añil 4.0 arranca en Horizon OS, dibuja y responde al mando. La secuencia
completa, comprobada de punta a punta bajo Ryujinx:

```
[boot] 1/3 primer constructor estatico   [boot] 2/3 los 45 pasaron
[boot] 3/3 main() alcanzado              [boot] 5 SDL_Init OK
[boot] 6a..6n Config::read completo      [boot] 7 mkxp.json leido
[boot] 8 initGL OK, hilo RGSS vivo       [boot] 9 contexto OpenAL creado
[boot] 10a..10f SharedState construido   [boot] 11 arrancando Ruby

Backend      : OpenGL          GL Vendor  : nouveau
GL Renderer  : NV120           GL Version : OpenGL ES 3.2 Mesa 20.1.0-rc3
[gfx] inicial: nwindow 1920x1080 | applet 1920x1080 | modo sobremesa
[nx] require set: OK  tsort: OK  socket: OK  io/wait: OK
[hid] joysticks: 8 | mando abierto: Switch Controller

WARNING: mkxp-z version 2.4.2 detected, but this version of Pokémon Essentials
         was designed for mkxp-z version 2.4.2/d13f35c.
[Advanced AI] Hotfixes loaded: Wonder Launcher, Item AI, Type Effectiveness
[traza] Thread.new #1 devuelto -> Thread
[traza] fotograma 600 | 60.0 fps en los ultimos 300
```

Y en pantalla, en este orden: la pantalla de título animada con su música, el
menú principal (*Partida Nueva / Opciones / Comprobar Actualizaciones / Borrar
Partida / Cerrar Juego*), la pantalla de controles y la introducción del
profesor Oak, con diálogo que avanza al pulsar A. Las capturas están en
`docs/capturas/`.

Lo que eso implica, punto por punto:

* Los 26 shaders compilan sobre el controlador **nouveau** real, GLES 3.2.
* PhysFS monta el juego y sus 22.318 rutas se indexan en 300 ms (§5.48).
* CRuby 3.1.7 arranca, carga la biblioteca estándar recortada, ejecuta Pokémon
  Essentials 21.1 y **los 320 scripts de plugin sin un solo error**.
* Los hilos de Ruby funcionan, con su planificador y su hilo temporizador
  (§5.39, §5.40, §5.42).
* La imagen sale a 1440x1080 centrada en una pantalla de 1920x1080, con las dos
  franjas negras que le tocan a un 4:3.
* **60,0 fps** en la pantalla de título y **60,0 en el mapa**, andando por el
  mundo. La introducción del profesor Oak, que es una escena a pantalla completa
  con partículas sobre un fondo animado, se queda entre **41 y 49** — medido
  bajo Ryujinx, donde el techo lo pone también el emulador.
* El mando responde con el reparto de botones de Nintendo (§5.45).
* El MIDI se desactiva con elegancia, como se diseñó en H5; la música de verdad
  es `.ogg` y suena.
* **Se juega de verdad, de principio a fin del arranque**: título, menú,
  introducción del profesor Oak, elección de nombre con la rejilla de caracteres
  (§5.50), elección de modo de juego y el mundo, con el jugador andando por su
  habitación. Todo con el mando y sin tocar un teclado.
* **Se guarda la partida**: 90 KB en 49 ms, releídos con el cargador del propio
  juego (§5.51).
* **El combate funciona** y se mantiene entre 41 y 55 fps.

Y desde H7 no hace falta pasar por el menú homebrew: `out/pokemon-anil.nsp` se
instala como una aplicación cualquiera, sale en el menú HOME con su icono y
arranca con los 3.264 MB de montón que Horizon reserva a un juego (§5.47). Los
702 MB de datos se quedan en la SD.

### Lo que queda

1. ~~**El arranque tarda ~55 s.**~~ **Resuelto** (§5.48): 56.065 ms → 300, y el
   intérprete arranca a los 4,8 s. Lo que queda por delante ya no es del port,
   son los 770 scripts de Essentials compilándose; ahí sí cabría un caché de
   bytecode, pero es otro proyecto.
2. ~~**Guardar partida.**~~ **Hecho**, con la partida en marcha y por el mismo
   camino que el menú de pausa:

   ```
   [guardar] ruta "sdmc:/switch/pokemon-anil/Partida 1.rxdata"
   [guardar] escritura pelada OK (2 B)
   [guardar] save_to_file OK en 49 ms, 90430 B
   [guardar] releido: Hash con 19 claves
   [guardar] Game.save("Partida 1") -> true, 90553 B
   ```

   90 KB en 49 ms, releídos con el mismo cargador que usa el juego al cargar. El
   nombre del fichero lleva un espacio —cosa del plugin *Multi Save*, §5.51— y a
   Horizon no le importa.

   Y la vuelta entera: al arrancar de nuevo, la partida sale en el menú de
   título con sus datos leídos del fichero —*Partida 1 · Intro Oak · Unnamed ·
   Medallas 0 · Tiempo 0m*—, se carga y se sigue jugando
   (`docs/capturas/cargar-01-menu.png`).
3. **Combate: medido, y es el suelo.** `lib/nx-combate-ya.rb` mete al jugador en
   un combate salvaje sin tener que ir hasta la hierba. El combate entero
   —introducción, ataques con animación, cambios de ventana— duró 80 s y se
   mantuvo entre **41,3 y 55,4 fps**, media 47; repetido sobre una partida
   cargada del fichero, entre 40,1 y 55,0, media 47,2. Es el mismo orden que la
   introducción del profesor Oak; el mapa, en cambio, va a 60,0 limpios. Bajo
   Ryujinx, donde el techo lo pone también el emulador: en consola hay que
   repetirlo. La captura está en `docs/capturas/cargar-b06.png`.
4. ~~**Cambio en caliente entre portátil y sobremesa.**~~ **Contestado**
   (§5.49): la superficie no cambia —Horizon entrega 1080p siempre y escala al
   panel de 720p—, así que no hay nada que redimensionar. El mecanismo queda
   puesto y vigilando por si en la consola de verdad fuese distinto.
5. **Consola real.** Encendida, instalada como NSP y **jugada**. Lo que
   contestó, que es lo que ningún emulador podía contestar:

   | | Ryujinx | Consola |
   |---|---|---|
   | Presupuesto de memoria | 3285 MB | **3285 MB** (aplicación, NSP) |
   | Arranque hasta Ruby | 4.896 ms | **4.861 ms** |
   | `createPathCache` | 290 ms | **1.101 ms** (SD real, 3,7×) |
   | Superficie en portátil | 1920x1080 | **1920x1080** con salida a 1280x720 |
   | Pico de montón | 637 MB | **637 MB** |

   §5.49 queda cerrado de verdad: en hardware y en portátil, la superficie no
   cambia. Y el arreglo de §5.48 vale más aquí que en el emulador —sin él,
   1.101 ms serían minutos sobre esta tarjeta—.

   Jugando aparecieron tres fallos que sólo da el hardware, los tres arreglados:
   la música que se paraba para siempre (§5.54), los menús que costaban dos mil
   llamadas al sistema (§5.55) y el hilo principal clavado a un núcleo (§5.56).
   **Falta volver a medirlos en la consola con los arreglos puestos**, que es lo
   único que sigue abierto.

   Lo que se ha podido adelantar sin ella es la mitad medible de la pregunta de
   memoria (§5.53): el juego pasa de **637 MB** de montón **a los 17 segundos**,
   en la pantalla de título y antes de que nadie pulse nada, y de ahí sigue
   subiendo hasta 716-743 según se juegue o se deje quieto. Como un menú
   homebrew abierto desde el álbum recibe unos 448, la ventaja del NSP deja de
   estar razonada y pasa a estar medida por el lado que importaba —cuánto pide
   el juego—; lo que sigue sin poder comprobarse en el emulador es cuánto le dan
   enfrente, porque Ryujinx reparte 3,2 GB con independencia del envoltorio.

   Lo demás que sólo contesta el hardware: los fps de verdad sobre un Tegra X1
   a 307-768 MHz, que no tienen por qué parecerse a los del emulador; los 300 ms
   de `createPathCache` (§5.48) leídos de una SD que escribe a 3,4 MB/s en vez
   de un NVMe; y si la superficie cambia al sacar la consola de la base, para lo
   que la propia tarjeta trae **ReverseNX-Tool**.

   El procedimiento, las tres formas de lanzarlo y la tabla de diagnóstico por
   síntoma están en §7; `recoger.ps1` saca de la SD todo lo que la consola tenga
   que contar.

### Herramientas de diagnóstico

| Fichero | Para qué |
|---|---|
| `fixup-arm64.py` | Neutraliza las instrucciones ARMv9 de libgcc tras enlazar (§5.33) |
| `dump-scripts.py` | Lector de Marshal 4.8 en Python; extrae los 770 scripts del juego sin necesitar un Ruby anfitrión |
| `iterate.sh` | Compilar, desplegar, ejecutar y volcar los cuatro registros. Con `NSP=1`, como aplicación instalada |
| `empaquetar-nsp.sh` | ELF → NSO → NSP instalable, con NPDM, NACP e iconos (§5.47) |
| `captura.ps1` | Capturas del emulador mientras corre (con DPI, §5.46) |
| `jugar.ps1` | **Conduce** el juego: manda pulsaciones y toma capturas entre medias (§5.45); con `-Portatil`, `toque:x,y` y `arrastre:...` en píxeles del juego (§5.73) |
| `tmp/rethread.mk` | Recompila un objeto suelto de Ruby y lo mete en `libruby-static.a` |
| `nx/nx_excepcion.c` | Manejador de excepciones y `--wrap=fatalThrow`, con traza de pila (§5.43) |
| `nx/nx_pipe.c` | `pipe()`, `poll()` y `select()` sobre devoptab (§5.42) |
| `nx/nx_fcntl.c` | `fcntl` para ficheros y tuberías (§5.35, §5.42) |
| `nx/nx_realpath.c` | `realpath` sin prefijo de dispositivo (§5.34) |
| `nx/nx_pthread_np.c` | `pthread_getattr_np` sobre libnx (§5.39) |
| `nx/nx_pantalla.c` | La resolución de verdad de la pantalla (§5.46) |
| `nx/nx_memoria.c` | Bajo qué envoltorio corre y cuánto montón pide de verdad (§5.53) |
| `recoger.ps1` | Saca de la SD los registros, las partidas y los informes de Atmosphère (§7) |
| `nx/nx_tirones.c` | Cronometra cada fotograma y separa el tiempo de tarjeta del de CPU (§5.55); reparte el montón entre alijos, texturas vivas y Ruby cada 30 s (§5.66, §5.69) |
| `nx/nx_nucleos.c` | Anota en qué núcleo corre cada hilo y ensancha la máscara (§5.56) |
| `nx/nx_texturas.c` | Cuenta la memoria de vídeo que el juego tiene viva, y su pico (§5.69) |
| `nx/nx_donde.cpp` | `NXReg.traza`: un script escribe en `mkxp-boot.log`, con sello de tiempo (§5.69) |
| `nx/nx_audio.c` | Testigo del relevo entre la fanfarria y la música de fondo (§5.57) |
| `nx/nx_fsprobe.c` | Cronometra el recorrido de la SD con y sin `stat`. Solo corre si existe el testigo `nx-medir-fs` (§5.48) |
| `nsp/npdm.json` | Manifiesto de la aplicación: ID, permisos, servicios y llamadas (§5.47) |
| `nsp/nacp-utf8.py` | Arregla el nombre del juego en el NACP, que `nacptool` escribe en Latin-1 (§5.47) |
| `lib/nx-compat.rb` | `MKXP`, constantes de `Encoding`, `$LOAD_PATH` y redirección de `$stdout`, con `fsync` por línea (§5.52); y el reportero de mapa que escribe `[donde]` (§5.69) |
| `lib/nx-teclado.rb` | Encamina la entrada de texto a la rejilla con cursor: en una consola no hay teclado (§5.50) |
| `lib/nx-trazas.rb` | Sondas de Ruby: hilos, fotogramas y fps. No se carga en producción |
| `lib/nx-guardado.rb` | Prueba el camino de guardado de Essentials sobre la SD. Tampoco se carga en producción |
| `lib/nx-guardar-ya.rb` | Guarda la partida en cuanto existe una, sin pasar por el menú (§5.51) |
| `lib/nx-combate-ya.rb` | Mete al jugador en un combate salvaje para poder medirlo |
| `patches/mkxpz-tactil.patch` | El primer dedo de la pantalla táctil como botón izquierdo del ratón, sin perder toques cortos (§5.73) |
| `shims/nx-tactil.rb` | Lo que significa un toque en cada pantalla de Essentials: listas, mensajes, PC, equipo, mochila, combate (§5.73) |
| `resolver-pila.py` | Convierte las líneas `[exc]` de un registro en nombres de función, con el `.elf` archivado de esa compilación (§5.65) |
| `triaje.py` | Lee un volcado entero de un jugador y saca el informe: compilación, caídas, fondo, montón y tirones (`TRIAJE.md`) |

Para leer una traza de pila del manejador de excepciones, si se tiene delante el
`.elf` de esa misma compilación:

```sh
aarch64-none-elf-addr2line -f -C -e pokemon-anil.elf +0x669068
```

Y si el registro es de un jugador —o sea, de una compilación publicada que ya no
está en el árbol—, la pila entera de una vez, buscando el `.elf` en
`release/simbolos/` y degradando al desensamblado en crudo si no lo hay (§5.65):

```sh
python resolver-pila.py docs/consola/20260905-pidgey/mkxp-boot.log
```
