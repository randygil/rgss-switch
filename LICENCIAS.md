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
