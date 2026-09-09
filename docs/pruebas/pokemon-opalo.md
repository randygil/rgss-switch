# Pokémon Ópalo 2.11 en el emulador — 9 de septiembre de 2026

Primera vez que este juego se enciende. Medido sobre Ryujinx
(`C:\Games\publish\Ryujinx.exe`), tarjeta virtual en `%APPDATA%\Ryujinx\sdcard`,
motor de HEAD. Lo común con Z, Iberia y Titán está en
[`familia-ruby18.md`](familia-ruby18.md); aquí van las vueltas de este juego.

**Estado: `no-arranca`.** Carga sus 214 secciones y muere en la última que se
evalúa antes de `Main`, sin llegar a dibujar un píxel. Los seis arreglos que
salieron de aquí son los que después hicieron arrancar a los otros tres.

## Qué se empaquetó y cómo

```
powershell -NoProfile -ExecutionPolicy Bypass -File Empaquetar.ps1 -SinInterfaz `
  -Juego "C:\Users\Usuario\Downloads\RPG MAKERS POKEMONS FANS\Pokemon Opalo V2.11" `
  -Salida "C:\Users\Usuario\AppData\Roaming\Ryujinx\sdcard" -Contenedor zip `
  -Entrega "C:\rgss-switch\release\rgss-switch-0.1.0"
```

16.555 ficheros y 633 MB en `datos.zip`; `PBS` excluida; 4 ficheros sueltos de
la raíz; 653 MB en 113 ficheros. El perfil no pide nada raro y no hizo falta
tocarlo. El `mkxp.json` compuesto lleva el `preloadScript` de la familia:

```
"lib/nx-compat.rb", "lib/nx-teclado.rb", "lib/nx-rutas.rb", "lib/nx-ruby18.rb"
```

## Vuelta 1 — el motor se muere en una sección distinta cada vez

**Síntoma.** El proceso muere sin excepción de Ruby. El registro del emulador
trae una traza de invitado:

```
Invalid memory access at virtual address 0x0000000000000000.
  callable_method_entry   ruby-3.1.7/vm_method.c:1318
  vm_respond_to           ruby-3.1.7/vm_method.c:2704
  rb_string_value         ruby-3.1.7/string.c:2525
  rb_f_eval               ruby-3.1.7/vm_eval.c:1814     <- StringValue(vfile)
  evalHelper              binding-mri.cpp:853
```

La primera vuelta murió en la sección 47; la segunda, con una traza por
sección puesta a mano, en la 25.

**Causa.** El gancho de `NXFuente` metió código de Ruby —y por tanto una
reserva, y por tanto el recolector— entre el `newStringUTF8` que crea el nombre
de la sección y el `eval` que lo usa. Los dos objetos solo viven en variables
locales de C.

**Arreglo.** `binding-mri.cpp` guarda el fuente, el nombre y lo que devuelve
`transforma` en un array registrado con `rb_gc_register_address` mientras la
sección se evalúa. Contado entero en `familia-ruby18.md` y en el propio parche.

Con eso, **212 de las 214 secciones cargan**.

## Vuelta 2 — `comparison of String with 6 failed`

**Síntoma.**

```
Section068:136:in `>=': comparison of String with 6 failed (ArgumentError)
	from Section068:136:in `pbGetStartExperience'
	from Section122:133:in `level='
	from Section122:942:in `initialize'
	...
	from Section211:41:in `<main>'
```

**Causa.** `PokeBattle_Pokemon#growthrate` lee el byte 20 de `dexdata.dat` con
`fgetb`, que baja por `StringInput#each_byte`, que hace `yield getc`, que hace
`@string[@pos]`: en 1.8 un `Integer`, en 3.1 una cadena de un carácter.

**Arreglo.** `StringInput#each_byte` entrega bytes. Se envolvió primero `getc`,
que parecía lo natural, y **hubo que deshacerlo**: `Marshal.load` lee el puerto
con `getc` y espera una cadena (vuelta 3 de `pokemon-z.md`).

## Vuelta 3 — el mismo `fgetb` daba 65 en una sección y `"A"` en otra

Costó cinco arranques, y la pista fue justo ésa. `0195_Map - Klein.rb` trae:

```ruby
class String
  alias getbyte  []
  alias setbyte  []=
  alias bytesize size
end
```

En 1.8 eso era **añadir**; en 3.1 los tres métodos ya existen y hacen lo
correcto, así que el alias los **destruye** para todo lo que se cargue después
—Zlib, Marshal, el postizo de `Win32API` que rellena búferes, y el propio
`nx-ruby18.rb`—. Se guardan los tres al cargar el preload y se reponen en
cuanto alguien los pisa.

## Vuelta 4 — hasta aquí llega: 679 Pokémon en el nivel superior

Con lo anterior puesto, la sección 212 (`Mesón Batalla`) **mata el proceso del
emulador entero**: sin excepción de Ruby, sin `errorlog.txt`, sin traza de
invitado en el registro de Ryujinx, y con Ryujinx desapareciendo a los 30 s de
lanzarse. Vuelta tras vuelta.

Lo que ese script hace en el nivel superior:

```ruby
TRAINERS = [
  { "type" => PBTrainers::Ranger, "name" => "Álvaro", ...
    "party" => [ generateNewPoke(PBSpecies::ALAKAZAM, 100, 31), ... ] },
  ...
]
```

**679 llamadas a `generateNewPoke`**, o sea 679 Pokémon completos construidos
al cargar el script, para armar la plantilla de entrenadores del Mesón Batalla.

Lo que se midió, con el contador puesto en `PokeBattle_Pokemon#initialize`:

- Muere siempre en **la misma creación**, la 155 de la lista (Quagsire, especie
  195), vuelta tras vuelta.
- **No es la especie**: esa misma especie 195, creada la segunda de todas, se
  construye sin problema.
- **No es la memoria de Ruby**: el montón está plano. De la creación 1 a la 141,
  `heap_live_slots` va de 120.618 a 121.667 y `heap_allocated_pages` no se
  mueve de 299. Forzar `GC.start` cada 25 no cambia nada.
- **No es el tiempo**: con los `.dat` memorizados (abajo) las creaciones 76 a
  151 tardan 0,1 s en total, y sigue muriendo en la 155.
- **No es "crear muchos Pokémon"**: se metieron 800 creaciones extra de la
  especie 1 antes de empezar la lista, y las 800 salieron bien.

Es decir: es posicional en la lista, no dependiente de los datos, del tiempo ni
del recuento de objetos, y el que se muere es el **proceso del emulador**, no
el juego. Un proceso de Ryujinx que desaparece sin escribir una línea es lo que
se ve cuando el anfitrión —no el invitado— se cae; puede ser un fallo del
emulador y no del motor. **No se ha resuelto**, y es lo único que separa a
Ópalo de sus tres hermanos.

Sí salió de aquí una mejora que se queda: `PokeBattle_Pokemon#initialize` abre
`Data/attacksRS.dat` **entero** (63 KB) por cada Pokémon, y con el contenedor
eso es abrir el zip, buscar la entrada y copiarla. `pbRgssOpen` memoriza ahora
los `Data/*.dat` en su forma sin bloque.

## Los tiempos

| ms | línea |
|---|---|
| 334 | `[juego] carpeta: sdmc:/switch/pokemon-opalo` |
| 4.048 | `[boot] 8 initGL OK, hilo RGSS vivo` |
| 7.760 | `[boot] 10a+ contenedor datos.zip montado` |
| 7.943 | `[boot] 10c pathCache construido` (16.724 entradas, 54 directorios, 139 ms) |
| 8.047 | `[boot] 11 SharedState OK, arrancando el intérprete Ruby` |
| 8.4 s | `[boot] scripts pasan por NXFuente.transforma` |
| ~30 s | el emulador desaparece, en la sección 212 |

`NXFuente`: **214 secciones, 3 tocadas, 25 arreglos** —los 23 `when X:` de
`AudioUtilities`, el `retry` de `PScreen_Load:508` y la regex con `\xNN` de
`PSystem_Utilities:199`—, que es exactamente lo que el censo había contado a
mano.

## Win32API: 34 funciones pedidas, ninguna sin semántica

Ni una línea `sin semantica` en el registro. Se **llamaron** de verdad dos:
`shell32!SHGetKnownFolderPath` y `ole32!CoTaskMemFree` (Essentials buscando
«Mis documentos» para guardar; el postizo contesta que no y el juego cae a su
reserva, que es guardar junto al ejecutable, que es lo que hay que hacer aquí).

## Hitos

| # | Hito | Captura |
|---|---|---|
| 1 | Pantalla de título | **no se llega** |
| 2–7 | — | — |

## Lo que queda

- La sección 212, `Mesón Batalla`, y sus 679 Pokémon. Es el único blocante.
  Lo primero que hay que averiguar es si el mismo juego se cae igual en una
  consola de verdad o si es cosa de Ryujinx: la muerte silenciosa del proceso
  anfitrión apunta más a lo segundo.
- Si se confirma que es del emulador, Ópalo pasa a `arranca` sin tocar una
  línea; si no, hay que entender qué agota esa lista.
