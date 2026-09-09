# rgss-switch

Motor genérico de RPG Maker XP (mkxp-z 2.4.2 + CRuby 3.1.7) para Nintendo
Switch, con un perfil por juego. Nació del porteo de Pokémon Añil
(`C:\anilswitch`, que es OTRO repositorio con otra sesión encima: no se toca).

**Antes de tocar nada, lee `CONVENCIONES.md`**: nombres, la carpeta de cada
juego en la tarjeta, cómo encuentra el motor su juego, cómo se compone
`mkxp.json`, qué es un perfil (`juegos/<slug>/perfil.json`) y las reglas de la
casa. `docs/censo-juegos.md` dice qué tan lejos está cada juego de correr.

## Búsqueda de código

Usa `tgrep` en lugar de `grep` o `rg` (hay índice en `.tgrep/`; si falta:
`tgrep index C:\rgss-switch`; si falla, la herramienta Grep).

- Patrón o regex: `tgrep "patrón" .`
- Literal: `tgrep -F "texto" .`
- Por tipo: `tgrep "patrón" . -t cpp` (o `-t c`, `-t ruby`, `-t py`, `-t ps1`)
- Solo nombres: `tgrep "patrón" . -l`

## Cosas de esta máquina

- El heredoc de bash se come las barras invertidas: ficheros con barras o muchas
  comillas se escriben con la herramienta Write.
- Los `.c`/`.cpp`/`.rb` del porteo pueden ser CRLF: respeta el final de línea
  que tenga cada fichero.
- `.gitignore` es lista blanca: un fichero nuevo no entra hasta que se nombra.
- Ryujinx (`C:\Games\publish\Ryujinx.exe`): una sola instancia a la vez; su
  tarjeta es `%APPDATA%\Ryujinx\sdcard\switch\<slug>\`.
- Ruby 3.1 del PC para probar sin consola:
  `src/rubyinstaller-3.1.4-1-x64/bin/ruby.exe`.
- Se compila desde bash con `make -C mkxp-z-nx -j8` (devkitPro en
  `C:\devkitPro`); `construir.sh` monta la entrega.
