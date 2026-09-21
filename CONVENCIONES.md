# Convenciones de rgss-switch

Este repositorio nace del porteo de Pokémon Añil 4.0 a Nintendo Switch
(`C:\anilswitch`, historia completa en `git log`) y lo convierte en un **motor
genérico**: mkxp-z 2.4.2 + CRuby 3.1.7 compilados para Horizon OS, capaces de
correr cualquier juego de RPG Maker XP / Pokémon Essentials que ya funcione
sobre mkxp-z en el PC, con un **perfil por juego** para lo que cada uno tenga
de particular. Añil pasa a ser un perfil más.

Este fichero es el contrato entre las piezas (motor en C/C++, empaquetador en
PowerShell y bash, shims de Ruby, perfiles). Si algo cambia aquí, cambia en
todas.

## 1. Nombres

| Cosa | Nombre |
|---|---|
| Proyecto y repositorio | `rgss-switch` |
| Binario del motor (homebrew) | `motor/rgss-switch.nro` en la entrega; `mkxp-z-nx/rgss-switch.nro` al compilar |
| El mismo binario como NSO | `motor/main` |
| Carpeta de cada juego en la tarjeta | `SD:/switch/<slug>/` |
| Binario dentro de esa carpeta | `SD:/switch/<slug>/<slug>.nro` (copia del motor con NACP e icono del juego) |
| Contenedor de recursos | `datos.zip` (almacenado, sin comprimir) |
| Llave del contenedor | `Game.rgssad` de 8 bytes (`RGSSAD\0\1`), sólo cuando hay contenedor y el juego no traía uno |
| Registros | `mkxp-boot.log`, `mkxp-debug.log`, `mkxp-ruby.log`, `errorlog.txt` (del juego), todos en la carpeta del juego |
| Interruptor de diagnóstico | `SD:/switch/<slug>/diagnostico.txt` (existe = modo diagnóstico) |
| Perfiles | `juegos/<slug>/perfil.json` (+ `lib/*.rb`, `icono.jpg` opcionales) |
| Perfil de reserva | `juegos/generico/perfil.json` |

**El slug** sale del `Title=` de `Game.ini`: minúsculas, sin acentos ni eñes
(`ñ`→`n`), todo lo que no sea `[a-z0-9]` se vuelve `-`, los guiones se colapsan
y se recortan de los extremos. `Pokemon  Vanguard` → `pokemon-vanguard`,
`Pokémon Añil 4.0` → `pokemon-anil-4-0`. Un perfil puede fijar otro slug
(Añil fija `pokemon-anil` para no mover las instalaciones que ya existen).

## 2. Lo que hay en `SD:/switch/<slug>/`

```
<slug>.nro            el motor, con el NACP y el icono de este juego
mkxp.json             compuesto por el empaquetador (ver §5)
lib/                  shims de Ruby del motor + subconjunto de la stdlib 3.1.7 + los del catálogo que este juego encienda + shims del perfil
datos.zip             Data/ Graphics/ Audio/ Fonts/ Movies/ dentro   (modo contenedor)
Game.rgssad           la llave de 8 bytes                             (modo contenedor)
Data/ Graphics/ ...   sueltos                                         (modo carpetas)
Game.ini, preload.rb, *.bmp, *.json ...   todo fichero suelto de la raíz del juego (ver abajo)
Scripts/, Data/Scripts/, Plugins/, patch/, stdlib/, gems/ ...   carpetas que van SIEMPRE sueltas
```

**Regla de lo suelto.** Va al contenedor lo que el motor lee por PhysFS
(`load_data`, `Bitmap`, `Audio`): `Data/`, `Graphics/`, `Audio/`, `Fonts/`,
`Movies/`. Va suelto lo que el juego lee con la API de ficheros de Ruby
(`Dir`, `File.read`, `File.open`), porque Ruby no ve dentro de PhysFS:

- `Data/Scripts/` (cargador de Essentials v20+: `Dir.foreach` + `File.open`).
  Se saca del contenedor y se copia suelta aunque el resto de `Data/` vaya dentro.
- `Scripts/` en la raíz (Reborn: `eval(File.read("Scripts/..."))`).
- `Plugins/`, `patch/`, `stdlib/`, `gems/`, `Mods/` y cualquier carpeta que el
  perfil liste en `sueltos`.
- De la raíz del juego se copian **todos los ficheros** salvo `*.exe`, `*.dll`,
  `*.pdf`, `*.lnk`, `*.rar`, `*.zip`, `*.7z`, `Thumbs.db`, `desktop.ini`,
  `*.parcial`, y salvo `mkxp.json` (que se compone, no se copia).

**Se excluyen por omisión** `PBS/`, `DataBackup/`, `DataExport/`, `dist/`,
`Credits/` y cualquier carpeta que el perfil liste en `excluir`: material de
desarrollo que un juego publicado no necesita. Un perfil puede rescatar una.

## 3. Cómo encuentra el motor su juego

En este orden, y para en el primero que tenga `mkxp.json`:

1. El directorio de `argv[0]` (lanzado como `.nro` desde hbmenu).
2. La ruta escrita en `romfs:/juego.txt` (una línea: `sdmc:/switch/<slug>`),
   que es lo que lleva un NSP porque una aplicación no tiene `argv`.
3. Si no hay ninguno, la pantalla de aviso de `nx_aviso.c` dice qué se buscó
   y dónde, y no adivina.

**Ninguna ruta a un juego concreto se escribe en el código del motor.** El
registro de arranque se acumula en memoria hasta que se conoce la carpeta
(los constructores estáticos corren antes que `main`) y entonces se vuelca a
`<carpeta>/mkxp-boot.log`. Si nunca se conoce, va a `sdmc:/rgss-switch.log`.

## 4. El NSP y el NRO de cada juego

Los construye **el empaquetador**, en la máquina del jugador, en PowerShell:

- **NRO**: toma `motor/rgss-switch.nro`, le rehace la sección ASET del final
  (icono JPEG 256×256 baseline + NACP) con el nombre, el autor y el icono del
  juego, y lo deja como `<slug>.nro`. El cuerpo del NRO no se toca.
- **NSP** (sólo si hay `prod.keys`): `motor/main` (NSO) + `main.npdm`
  generado con `tools/npdmtool.exe` a partir de `motor/npdm.json` con el title
  id del juego + `control.nacp` de `tools/nacptool.exe` reescrito en UTF-8 +
  iconos + `romfs/juego.txt` → `tools/hacbrewpack.exe`. Sale
  `<slug>.nsp` junto a la carpeta `switch/` de la salida.

**Title id**: `05` seguido de los 14 primeros hexadecimales de `SHA1(slug)`,
en mayúsculas. El perfil puede fijar otro (Añil conserva
`05414E494C000000`). Tiene que ser el mismo en el NPDM y en el NACP.

Las `prod.keys` se buscan en `%USERPROFILE%\.switch\prod.keys` y en
`%APPDATA%\Ryujinx\system\prod.keys`; sin ellas se entrega sólo el `.nro` y se
dice por qué. Nunca se copian a ningún sitio.

## 5. Cómo se compone `mkxp.json`

Cuatro capas, la de abajo pisa a la de arriba:

1. `runtime/mkxp.base.json`: lo que la Switch necesita siempre (pantalla
   completa, aspecto fijo, escalado suave, `pathCache`, sin `enableReset` ni
   `enableSettings`, `rubyLoadpath: ["lib"]`, `rgssVersion: 1`...).
2. Del `mkxp.json` **del propio juego**, sólo estas claves: `windowTitle`,
   `defScreenW`, `defScreenH`, `rgssVersion`, `SESourceCount`,
   `BGMTrackCount`, `midiSoundFont`, `subImageFix`, `enableBlitting`,
   `bindingNames`, `inputRepeatStart`, `inputRepeatDelay`, `patches`,
   `JITEnable`... (lista blanca en el empaquetador; lo de resolución de
   ventana, vsync y rutas del PC se ignora). Los `mkxp.json` de los juegos
   son JSON5: llevan comentarios `//` y comas finales, y hay que quitarlos
   antes de `ConvertFrom-Json`.
3. `mkxp` del perfil.
4. `preloadScript`, compuesto a partir del **catálogo de shims**
   (`runtime/shims/catalogo.json`, `shims/catalogo.json` en la entrega): los
   que van `siempre` (los de `runtime/lib/`, en su orden) → el de la `familia`
   de motor (`nx-ruby18.rb` en `ruby18` y `rgss1`) → los que el perfil pida por
   nombre en `shims` → los shims del perfil (`juegos/<slug>/lib/*.rb`, la lista
   `preload`) → `preload.rb` del juego si existe. `rubyLoadpath` = `["lib"]` +
   lo que el perfil añada (`stdlib`, `gems`...).

   Un shim del catálogo con `carga: "require"` **no** entra en
   `preloadScript`: sólo se copia a `lib/`, para que lo encuentre el `require`
   del propio juego (`discord`, `poke-api-v2`, `rubygems`). Uno con
   `carga: "postload"` saldría en `postloadScript`, que **este motor ignora**:
   mkxp-z 2.4.2 sólo lee `preloadScript`. Lo que un shim implique en
   `mkxp.json` (su campo `mkxp`) se aplica justo por debajo de la capa 3, para
   que el perfil siempre pueda pisarlo.

Si el juego no trae `mkxp.json`, la capa 2 está vacía y `windowTitle` sale
del `Title=` de `Game.ini`.

## 6. El perfil

```json
{
  "slug": "pokemon-reborn",
  "nombre": "Pokémon Reborn",
  "autor": "Reborn Team",
  "titleid": null,
  "detectar": { "titulo": "^Pokemon Reborn$", "ficheros": ["Scripts/ScriptLoader.rb"] },
  "motor": "ruby31",
  "estado": "sin-probar",
  "mkxp": { "SESourceCount": 12 },
  "shims": ["discord", "rubygems"],
  "preload": ["nx-ejemplo.rb"],
  "sueltos": ["Scripts", "patch", "stdlib", "gems"],
  "excluir": [],
  "rubyLoadpath": ["stdlib", "gems"],
  "notas": "Lo que hay que saber de este juego, en una o dos frases."
}
```

- `motor`: `ruby31` (mkxp-z con Ruby 3.x: lo que este motor corre),
  `ruby18` (mkxp-z con Ruby 1.8.7 embebido: Ópalo, Iberia, Titán, Z) o
  `rgss1` (RPG Maker XP original con `RGSS10x.dll`: Uranium). El
  empaquetador lo detecta si no hay perfil: `x64-msvcrt-ruby310.dll` o un
  `Game.exe` grande con la cadena `mkxp-z.exe` y sin `/lib/ruby/1.8` → `ruby31`;
  `Game.exe` grande con `/lib/ruby/1.8` → `ruby18`; `Game.exe` pequeño (< 1 MB)
  con `RGSS10*.dll` → `rgss1`. Con `ruby18` o `rgss1` empaqueta igual pero
  **avisa** de que los scripts son de Ruby 1.8 y el motor lleva 3.1.
- `shims`: nombres del catálogo (`runtime/shims/catalogo.json`), no ficheros.
  Es la biblioteca compartida: un arreglo que sirve para más de un juego se
  escribe **una vez** ahí y cada perfil lo enciende por su nombre. `preload`
  sigue siendo para lo que sólo sirve en ESE juego y vive en
  `juegos/<slug>/lib/`; va detrás de los del catálogo.
- `estado`: `jugable`, `arranca`, `no-arranca`, `sin-probar`. Lo actualiza
  quien lo prueba, con la fecha en `notas`.
- Todo es opcional menos `slug` y `nombre`. Lo que falta cae al perfil
  `generico`.

## 7. Entrega (`release/rgss-switch-<VERSION>/`)

```
Empaquetar.cmd  Empaquetar.ps1  GUIA.md  LICENSE  LICENCIAS.md  VERSION.txt
motor/   rgss-switch.nro  main  npdm.json  icono.jpg
lib/     runtime/lib/**  +  los ficheros de runtime/lib-stdlib.txt desde src/ruby-3.1.7/lib
shims/   runtime/shims/**  (la biblioteca compartida y su catalogo.json; el
         empaquetador copia a lib/ sólo los que cada juego encienda)
mkxp.base.json
juegos/  <slug>/perfil.json  [lib/*.rb]  [icono.jpg]   (todos los perfiles del repo)
tools/   hacbrewpack.exe  nacptool.exe  npdmtool.exe   (+ sus licencias en LICENCIAS.md)
```

`construir.sh` la monta. El juego no entra en la entrega, nunca.

## 8. Ryujinx

`C:\Games\publish\Ryujinx.exe`. Su tarjeta virtual es
`%APPDATA%\Ryujinx\sdcard\`, así que un juego se prueba dejándolo en
`%APPDATA%\Ryujinx\sdcard\switch\<slug>\` y lanzando
`Ryujinx.exe --fullscreen <ruta al .nro>`. Los registros se leen en caliente
de esa carpeta. **Sólo puede correr un Ryujinx a la vez**: quien lo lance lo
cierra al terminar (`Stop-Process`), y no lo lanza si ya hay uno.

`iterate.sh <slug>` compila, despliega y lanza; `jugar.ps1 -Juego <slug>`
lanza y conduce con el teclado (A=Z, B=X, X=C, Y=V, cruceta=flechas).

## 9. Reglas de la casa

- **Nada de `C:\anilswitch`** se toca: es otro repositorio con otra sesión
  encima. Se lee si hace falta; no se escribe.
- **No se hace `git push`** a ningún remoto. Se confirma en local, en `main`,
  con mensajes en español que digan qué cambia y por qué, como los del
  historial.
- `.gitignore` es una **lista blanca**: un fichero nuevo no entra en un commit
  hasta que se nombra ahí. Comprobar con `git status --short` que lo nuevo
  aparece.
- Comentarios y textos en español, en el tono del historial: se explica el
  fallo que motivó cada cosa, no sólo qué hace.
- Los `.c`/`.cpp`/`.rb` del porteo pueden ser CRLF. Los parches en Python
  normalizan al leer y devuelven lo que había. Los ficheros con barras
  invertidas o muchas comillas se escriben con la herramienta Write, no con
  heredoc (el heredoc de esta máquina se come las barras).
- `tgrep` no tiene índice en este árbol: `tgrep index C:\rgss-switch` una vez,
  o usar la herramienta Grep.
- Ruby 3.1 del PC, para comprobar sintaxis y probar shims sin consola:
  `src/rubyinstaller-3.1.4-1-x64/bin/ruby.exe`.
- Rutas fijas de compilación: `C:/devkitPro` se queda; `C:/anilswitch` se
  sustituye por la raíz de este repo (`$(CURDIR)/..` en el Makefile,
  `$RAIZ` en los guiones).
