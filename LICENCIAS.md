# Licencias

Este repositorio contiene **el porteo**, no el juego. Tres bloques distintos,
con condiciones distintas.

---

## 1. El código propio de este porteo — GPLv2 o posterior

Cubre todo lo que se escribió aquí:

| Qué | Dónde |
|---|---|
| Los 13 shims de Horizon | `mkxp-z-nx/nx/*.c` |
| El sistema de compilación que sustituye a meson | `mkxp-z-nx/Makefile` |
| El shim de POSIX para newlib | `patches/nxcompat.c`, `patches/include/` |
| Los sustitutos de la biblioteca estándar | `runtime/lib/*.rb`, `runtime/lib/io/wait.rb` |
| La biblioteca de shims y su catálogo, salvo los dos ficheros de la tabla de §2.1 | `runtime/shims/catalogo.json`, `runtime/shims/discord.rb`, `poke-api-v2.rb`, `rubygems.rb`, `nx-rutas-windows.rb`, `nx-marshal-huerfano.rb`, `nx-msgbox.rb` |
| La configuración del motor para la consola | `runtime/mkxp.json` |
| El banco de pruebas del intérprete | `hello-ruby-nx/` |
| Los guiones de compilación, empaquetado y depuración | `*.sh`, `*.py`, `*.ps1`, `nsp/` |
| La bitácora de ingeniería | `README.md` |

**Por qué GPLv2+ y no algo más permisivo.** No es una preferencia: los shims de
`nx/` se enlazan estáticamente dentro de mkxp-z, que es GPLv2+, y el binario
resultante se distribuye como una sola obra. Publicar ese código bajo una
licencia incompatible no se sostendría. El texto completo está en
[`LICENSE`](LICENSE).

## 2. Los parches — heredan la licencia de lo que parchean

Un parche es obra derivada del fichero al que se aplica, así que cada uno va
bajo la licencia de su origen. No hay nada que elegir aquí.

| Parches | Obra derivada de | Licencia |
|---|---|---|
| `patches/000[1-5]-*.patch` | CRuby 3.1.7 | Licencia de Ruby o BSD-2, a elección |
| `patches/mkxpz-*.patch` | mkxp-z 2.4.2 | GPLv2+ |

### 2.1 Shims copiados de Empo

Dos ficheros de `runtime/shims/` **no** se escribieron aquí: vienen de
[`mkxp-z-apple-mobile`](https://github.com/mateo-m/mkxp-z-apple-mobile), el fork
de mkxp-z de [Empo](https://github.com/mateo-m/empo-app) (el reproductor de
juegos de RPG Maker para iOS), que resuelve el mismo problema que este porteo en
otra consola. Se copian con su cabecera de autoría intacta y con una cabecera en
español encima que dice qué arreglan y de dónde salen.

| Fichero | Origen | Autores | Licencia |
|---|---|---|---|
| `runtime/shims/win32_wrap.rb` | `scripts/preload/win32_wrap.rb` | Ancurio (2014), ediciones de Splendide Imaginarius (2023-2024) | **CC0 1.0** (dominio público; lo dice el propio fichero) |
| `runtime/shims/win32_wrap_encoding.rb` | `scripts/preload/win32_wrap_encoding.rb` | del fork | Sin cabecera propia: la del repositorio, o sea **GPLv2+** heredada de mkxp-z (`COPYING`) |

Las dos son compatibles con la GPLv2+ con la que se distribuye esto. El segundo
fichero no se puede relicenciar ni meter en una entrega que no sea GPL, y no
hace falta: esta lo es.

**Lo que NO se copió, y por qué.** `scripts/postload/nilclass_safe_stubs.rb`,
`rgss_plugin_stubs.rb` y `pokemon_online_stubs.rb` son de *postload*, y este
motor no tiene `postloadScript`: mkxp-z 2.4.2 sólo lee `preloadScript`
(`src/config.cpp:196`). De `windows_fs.rb` y `rgss_plugin_stubs.rb` se tomó la
**idea** (rutas con contrabarra y `Dir.chdir`; `msgbox`; clases ausentes al
deserializar) y se escribió de cero en `nx-rutas-windows.rb`, `nx-msgbox.rb` y
`nx-marshal-huerfano.rb`, que son propios y van en la tabla de §1. Tampoco se
copió `mkxp_wrap.rb` (CC0): `runtime/lib/nx-compat.rb` ya define el módulo
`MKXP`, y dos definiciones del mismo módulo se pisarían.

## 3. Lo que hace falta y **no** está aquí

### Terceros que se descargan aparte

| Componente | Licencia | Se enlaza |
|---|---|---|
| [mkxp-z](https://github.com/mkxp-z/mkxp-z) 2.4.2 | GPLv2+ | sí, estáticamente |
| [CRuby](https://www.ruby-lang.org) 3.1.7 | Ruby / BSD-2 | sí, estáticamente |
| devkitPro / libnx | ISC y zlib | sí |
| SDL2, SDL2_image, SDL2_ttf | zlib | sí |
| OpenAL-soft | LGPLv2+ | sí |
| PhysFS | zlib | sí |
| libiconv 1.16 | LGPLv2+ (la biblioteca; `COPYING.LIB`) | sí |
| pixman | MIT | sí |
| uchardet | MPL 1.1 / GPL 2.0 / LGPL 2.1 | sí |
| SDL_sound | zlib | sí |
| [hacbrewpack](https://github.com/The-4N/hacbrewpack) | ISC | sí, en `tools/` de la entrega |
| `nacptool`, `npdmtool` y `build_romfs` ([switch-tools](https://github.com/switchbrew/switch-tools)) | ISC | sí, en `tools/` de la entrega |
| Liberation Sans (dentro de mkxp-z) | SIL OFL 1.1 | empotrada |
| SDL_GameControllerDB | zlib | empotrada |

Todas son compatibles con la GPLv2 con la que se distribuye el binario. La de
uchardet lo es por la rama GPL 2.0 de su triple licencia; la MPL 1.1 a secas no
lo sería.

### Material que no se distribuye, y no por descuido

- **Los juegos.** Ninguno. `rgss-switch` es el motor y nada más: ni los
  `Data/`, `Graphics/`, `Audio/` y `Fonts/` de ningún juego, ni sus scripts
  Ruby. Pon tú tu propia copia y señálasela a `Empaquetar.cmd`, que la
  convierte en una carpeta para la tarjeta en tu propia máquina. Nada de eso
  está versionado aquí ni viaja en la entrega.
- **Pokémon** es marca de Nintendo, Creatures y GAME FREAK. Este porteo no está
  asociado ni respaldado por ellos, ni por los autores del juego.
- **`prod.keys`** — las claves de tu consola, que `Empaquetar.ps1` necesita
  para firmar el NSP (sin ellas entrega sólo el `.nro` y dice por qué). Salen
  de tu propio hardware con Lockpick_RCM y de ningún otro sitio; se leen donde
  están y no se copian a ninguna parte. El `.gitignore` las bloquea por patrón, además de por la lista
  blanca.
