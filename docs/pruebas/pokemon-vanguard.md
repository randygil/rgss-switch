# Project Vanguard 4.0.3 en el emulador — 9 de septiembre de 2026

Primera vez que este juego se enciende. Todo lo que sigue esta medido sobre
Ryujinx (`C:\Games\publish\Ryujinx.exe`) con la tarjeta virtual en
`%APPDATA%\Ryujinx\sdcard`, con el motor de HEAD (0.1.0 b12) y el perfil
`juegos/pokemon-vanguard/perfil.json` tal cual estaba, sin tocarlo.

## Que se empaqueto y como

```
./construir.sh
powershell -NoProfile -ExecutionPolicy Bypass -File Empaquetar.ps1 -SinInterfaz `
  -Juego "C:\Users\Usuario\Downloads\RPG MAKERS POKEMONS FANS\Project Vanguard 4.0.3 Main" `
  -Salida "C:\Users\Usuario\AppData\Roaming\Ryujinx\sdcard" -Contenedor zip `
  -Entrega "C:\rgss-switch\release\rgss-switch-0.1.0"
```

Salio a la primera y sin un solo aviso que hubiera que atender:

- 23.970 ficheros y 1.545 MB dentro de `datos.zip`; 24.067 entradas releidas del
  indice en la comprobacion.
- `Data/Scripts/`, `Plugins/` y `Mods/` sueltas, que es lo que dice el perfil.
- `Credits`, `DataBackup`, `DataExport`, `dist` y `PBS` excluidas.
- `midiSoundFont: soundfont.sf2` no se copio, porque el fichero no existe en el
  juego. El empaquetador lo dijo por pantalla.
- 1.572 MB en 578 ficheros en `switch/pokemon-vanguard/`, mas el `.nsp` firmado.

**El `.nro` del empaquetador no arranca en Ryujinx**, y no es culpa suya (ver
abajo): para todas las pruebas el `.nro` lo rehizo `iterate.sh`.

## Vuelta 1 — el `.nro` no encontraba el juego

**Sintoma.** El `<slug>.nro` que produce hoy el empaquetador, y el que copiaba
`iterate.sh`, salen con el romfs VACIO del motor. Ryujinx lanza los `.nro` con
`argc = 0`, asi que el paso (a) de CONVENCIONES §3 —el directorio de `argv[0]`—
no contesta nada, y sin `romfs:/juego.txt` tampoco contesta el (b).

```
[nx] mkxp-z arrancando en Horizon OS; argc = 0 argv[0] = (vacio)
```

**Causa.** El romfs del motor tiene que existir (un ASET que pide un romfs
inexistente mata al emulador, 6128ea3) pero esta vacio a proposito, y
`iterate.sh` copiaba `rgss-switch.nro` tal cual.

**Arreglo.** `iterate.sh` rehace el `.nro` del slug con `elf2nro` y un romfs de
un solo fichero, `juego.txt`, con la linea `sdmc:/switch/<slug>` en UTF-8 sin
BOM. Commit propio. Desde entonces:

```
[nx] directorio de trabajo: sdmc:/switch/pokemon-vanguard (romfs:/juego.txt)
```

**Lo del empaquetador se deja anotado y NO se toca** (es de otro agente).
Durante la sesion ese agente lo arreglo -el empaquetador ya anuncia
`romfs:/juego.txt -> sdmc:/switch/<slug>` y `comprobar-nro.py` lee el fichero
dentro-, pero el `.nro` que produce **sigue sin arrancar en Ryujinx**: el
emulador se queda en "Loading as homebrew" y no crea proceso. Esta contado con
detalle en `docs/pruebas/pokemon-reborn.md`, vuelta 0. Todas las pruebas se
hicieron con el `.nro` de `elf2nro`.

## Arranque: los tiempos

De `mkxp-boot.log`, primera vuelta con `pathCache` frio:

| ms | linea |
|---|---|
| 264 | `[nro] (sin ruta: lanzado sin argumentos)` |
| 353 | `[juego] carpeta: sdmc:/switch/pokemon-vanguard` |
| 2.924 | `[boot] 8 initGL OK, hilo RGSS vivo` |
| 4.483 | `[boot] 10a+ contenedor datos.zip montado` |
| 4.726 | `[boot] 10c pathCache construido` (24.756 entradas, 207 directorios, 250 ms) |
| 4.825 | `[boot] 11 SharedState OK, arrancando el interprete Ruby` |
| 5.382 | `[fs] FileTest.exist? contesta tambien por el contenedor` |

O sea: **el motor esta listo en 4,8 s**. Lo que tarda es el juego: los 432
scripts y sus 176.701 lineas. La pantalla de creditos de Essentials aparece
sobre los 45 s de reloj, el titulo hacia los 60 s, y la pantalla de New Game a
los **102 s** (`[tiron] marco 293 ms` justo ahi). El primer mapa jugable,
`81 Destiny's House`, aparece a los **337 s** de reloj del juego contando la
introduccion entera pasada a botonazos.

```
[142687] [donde] mapa 1 Intro en (10,4)
[336889] [donde] mapa 81 Destiny's House en (27,5)
```

Ni una excepcion en `mkxp-debug.log`, `errorlog.txt` no llego a crearse.

## Vuelta 2 — el nombre del jugador: el ajuste significa lo contrario

**Sintoma.** Con el shim generico tal cual estaba, la pantalla del nombre salio
asi (captura `pokemon-vanguard-nombre-teclado.png`):

> Your name?
> Enter text using the keyboard. Press Enter to confirm, or Esc to cancel.

Es el callejon sin salida exacto que `runtime/lib/nx-teclado.rb` existe para
evitar: en una consola no hay teclado y la partida no puede empezar sin nombre.

**Linea del registro.** El shim decia que se habia instalado:

```
[teclado] entrada de texto encaminada a la rejilla con cursor
```

O sea que el shim corrio y no sirvio. **La causa no era el enganche: era el
numero.** `pbEnterText` elige pantalla mirando `$PokemonSystem.textinput`, y el
`if` esta escrito al reves en cada juego:

| juego | Essentials | el `if` de `pbEnterText` |
|---|---|---|
| Anil | v21.1 | `textinput == 0` es el teclado; poner 1 da la rejilla |
| Vanguard | v20.1 | `if ($PokemonSystem.textinput == 1) # Keyboard` |

El shim ponia el ajuste a 1, o sea que en Vanguard pedia **exactamente** la
pantalla que no se puede usar. Los dos juegos comentan el ajuste igual
(`0=cursor, 1=keyboard`) y los dos lo leen distinto: el numero no sirve para
decidir nada.

**Arreglo.** `runtime/lib/nx-teclado.rb` deja de elegir la rama y hace que las
dos ramas lleven al mismo sitio: `PokemonEntryScene` (la del teclado) pasa a ser
`PokemonEntryScene2` (la rejilla). Las dos clases tienen la misma interfaz
—`pbStartScene(helptext, minlength, maxlength, initialText, subject, pokemon)`,
`pbEntry`, `pbEndScene`— porque las usa la misma `PokemonEntry`, y las dos se
construyen con `.new` sin argumentos. Da igual lo que valga el ajuste y en que
sentido lo lea la version del juego.

```
[teclado] PokemonEntryScene -> la rejilla con cursor (la del teclado queda en NXPokemonEntrySceneTeclado)
```

**Como se escribe un nombre con el mando**, que hacia falta saberlo para
conducir la prueba: en la rejilla, `Input::USE` (tecla Z = boton A) mete la
letra bajo el cursor, `Input::ACTION` (tecla C = boton X) **salta el cursor al
OK**, y otro `USE` confirma. De ahi el patron `Z, C, Z` con el que se atraveso
la introduccion sin saber en que pulsacion iba a aparecer la rejilla: en un
cuadro de dialogo la `C` no hace nada y en la rejilla es justo lo que falta.

## Vuelta 3 — `Mods/` no se carga: `File.expand_path` sobre `Dir.pwd`

**Sintoma**, escrito por el propio juego en `mkxp-ruby.log`:

```
Checking Mods path: sdmc:/switch/pokemon-vanguard/sdmc:/switch/pokemon-vanguard/Mods
Directory exists? false
```

**Causa.** `022_Main/999_Main.rb:37` hace `File.expand_path("Mods", Dir.pwd)`.
`Dir.pwd` en Horizon es `sdmc:/switch/<slug>`, que `rb_is_absolute_path` no
acepta como absoluta porque no empieza por `/`, asi que `expand_path` le vuelve
a pegar el directorio de trabajo delante. Es el mismo fallo que `nx-compat.rb`
ya arreglaba para `$LOAD_PATH`, y por el mismo motivo.

**Arreglo.** `runtime/lib/nx-compat.rb` hace que `Dir.pwd` conteste la ruta
**sin dispositivo** (`/switch/<slug>`), que es la misma forma que ya se usa para
el `$LOAD_PATH`: newlib resuelve las rutas sin dispositivo contra el de por
omision —la tarjeta— y para Ruby empieza por `/`, o sea que es absoluta y no se
duplica. El original queda en `Dir.nx_pwd_con_dispositivo`.

## Vuelta 4 — el menu de pausa se abre con la tecla C, no con la X

Anotado porque se perdio una sesion entera con esto. En Vanguard el menu **no**
lo abre `Input::B`: `003_Game processing/002_Scene_Map.rb:188` dice

    elsif Input.trigger?(Input::ACTION)
      unless $game_system.menu_disabled || $game_player.moving?
        $game_temp.menu_calling = true

o sea `Input::A` (`"a": "Action"` en el `bindingNames` compuesto), que en este
emulador es el boton X del mando y por tanto **la tecla C**. La X del teclado es
el boton B del mando, `Input::B`, y en el mapa no hace nada.

El menu es el de *Voltseon's Pause Menu*: una **fila horizontal** de iconos que
se recorre con IZQUIERDA y DERECHA —ABAJO no hace nada, y ocho ABAJO seguidos
dejan la seleccion donde estaba—. Con la partida recien empezada la seleccion
arranca en `Bag` y **`Save` esta a una DERECHA**.

## Vuelta 5 — `File.file?` no ve dentro del contenedor

**Sintoma.** Al abrir la lista de encuentros del menu de pausa (dos DERECHA), el
juego se cae y escribe `errorlog.txt`:

```
Exception: RuntimeError
Message: You are missing the graphic for this UI. Make sure the image is in
         your Graphics/Pictures folder and that it is named appropriately.
[Encounter List UI (v20)] 002_UI_Encounters.rb:94:in `pbStartScene'
[Voltseon's Pause Menu] 005_VoltseonMenu_Entries.rb:274:in `block in selected'
```

**Causa.** La linea 94 es
`if !File.file?("Graphics/Pictures/EncounterUI/"+WINDOWSKIN)`. La imagen esta,
dentro de `datos.zip`; lo que no la ve es `File.file?`. El motor engancha
`FileTest.exist?`, `FileTest.exists?`, `File.exist?` y `File.exists?`
(`nx/nx_ficheros.cpp`, README 5.62) pero no `file?`.

**Arreglo.** `nx_ficheros.cpp` registra tambien `File.file?` y
`FileTest.file?`, con una funcion propia: en la tarjeta se mira con `stat` y
solo vale un fichero regular —`file?` tiene que seguir diciendo que no a un
directorio— y solo si el sistema dice que no se consulta PhysFS. La traza de
arranque lo dice entero:

```
[fs] FileTest.exist? y File.file? contestan tambien por el contenedor
```

## Hitos

| # | Hito | Captura |
|---|---|---|
| 1 | Pantalla de titulo | `pokemon-vanguard-hito-1-titulo.png` |
| 2 | Partida nueva, introduccion | `pokemon-vanguard-hito-2-partida-nueva.png` |
| 3 | Nombre del jugador en la rejilla | sin captura: se atraveso con el patron Z-C-Z y el nombre por omision, "Player", quedo puesto (se lee en la pantalla de guardado). La captura que si esta es la del fallo: `pokemon-vanguard-nombre-teclado.png` |
| 4 | Primer mapa con el jugador (81 Destiny's House) | `pokemon-vanguard-hito-4-mapa.png` |
| 5 | Menu | `pokemon-vanguard-hito-5-menu.png` |
| 6 | Guardar | `pokemon-vanguard-hito-6-guardar.png`, y en la carpeta del juego quedan `File A.rxdata` y `File A 1 0h 8m Destiny's House.rxdata` (la copia del plugin *Infinite Save Backups*) |
| 7 | Combate | no se llego en el tiempo de la prueba |

## Lo que queda

- El `.nro` del empaquetador sin `juego.txt` en el romfs (otro agente).
- `patches`/`System.file_exist?` no aplican a este juego.
- `Data/PluginScripts.rxdata` se quedo dentro del contenedor y **no dio ningun
  fallo de escritura**: la sospecha que llevaba el perfil no se cumplio.

## Regresion de Anil

Los tres arreglos de aqui son **genericos** —`nx-teclado.rb`, `Dir.pwd` en
`nx-compat.rb` y `File.file?` en el motor—, asi que se volvio a encender Anil
con ellos puestos antes de dar la sesion por buena: `.nro` rehecho con el motor
de HEAD, los dos shims copiados a su `lib/`, sin tocar sus partidas.

Llega a la pantalla de carga con `Partida 1 / Randy / Pueblo Paleta / 7m`
intacta, `errorlog.txt` no se crea, y en `mkxp-ruby.log` salen sus cuatro shims
de perfil y la linea nueva:

```
[teclado] PokemonEntryScene -> la rejilla con cursor (la del teclado queda en NXPokemonEntrySceneTeclado)
```

Antes decia "entrada de texto encaminada a la rejilla" y hacia lo mismo por otro
camino; el resultado en Anil no cambia.
