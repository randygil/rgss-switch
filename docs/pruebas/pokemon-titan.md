# Pokémon Titán 2.10 en el emulador — 9 de septiembre de 2026

Primera vez que este juego se enciende. Ryujinx, tarjeta virtual en
`%APPDATA%\Ryujinx\sdcard`, motor de HEAD. Lo común está en
[`familia-ruby18.md`](familia-ruby18.md).

**Estado: `arranca`.** Como Iberia, **a la primera y sin una sola vuelta de
arreglo**, y un poco más lejos que él: título, menú de carga, partida nueva y la
introducción con la profesora hablando. Ni una excepción, ni `errorlog.txt`.

## Qué se empaquetó y cómo

```
powershell -NoProfile -ExecutionPolicy Bypass -File Empaquetar.ps1 -SinInterfaz `
  -Juego "C:\Users\Usuario\Downloads\RPG MAKERS POKEMONS FANS\POKEMON TITAN V2.10" `
  -Salida "C:\Users\Usuario\AppData\Roaming\Ryujinx\sdcard" -Contenedor zip `
  -Entrega "C:\rgss-switch\release\rgss-switch-0.1.0"
```

431 MB en 1.407 ficheros, con `Animations/` suelta y `PBS` excluida: el mismo
reparto que Iberia, como el censo decía. Tampoco trae `mkxp.json` ni
`preload.rb`.

## Vueltas: ninguna

Los mismos nueve arreglos de la familia se disparan en el mismo orden. La única
diferencia con Iberia en el registro es que Titán **no** pide
`user32!GetDC`/`gdi32!BitBlt` (no trae el `Map - Klein.rb` con su
`Graphics.snap_to_bitmap` de gdi32), aunque sí pide `kleinbitmap!version`.

## Los tiempos

| ms | línea |
|---|---|
| 365 | `[juego] carpeta: sdmc:/switch/pokemon-titan` |
| 3.662 | `[boot] 8 initGL OK, hilo RGSS vivo` |
| 4.844 | `[boot] 10a+ contenedor datos.zip montado` |
| 5.124 | `[boot] 10c pathCache construido` |
| 5.224 | `[boot] 11 SharedState OK, arrancando el intérprete Ruby` |
| 6.137 | `[boot] scripts pasan por NXFuente.transforma` |
| 9.665 | primer `[monton]`: el juego ya está dibujando |

`[fuente] TOTAL: 167 secciones, 4 tocadas, 28 arreglos, 1806.5 ms`, otra vez
clavado con el censo.

`[223890] [donde] mapa 1 Intro en (9,7)`, y un `[tiron]` de 2.722 ms al entrar,
con `io 1772193x 95 ms`.

## Lo único feo que se ha visto en esta familia

`docs/capturas/pokemon-titan-intro-profesora.png`: la profesora habla, el cuadro
de diálogo está bien, la fuente está bien... y a su lado hay **un sprite hecho
de ruido**, una columna de píxeles blancos y naranjas sin forma.

Es el `RtlMoveMemory` postizo. El juego construye ese bitmap escribiendo memoria
a mano, pasando `bitmap.__id__*2+16` como si el `object_id` fuera la dirección
del objeto —cierto en el Ruby 1.8 de 32 bits, falso en cualquier Ruby moderno—.
El postizo devuelve 0 y no toca memoria, que es lo único que se puede hacer:
escribir ahí sería corromper el montón. El bitmap sale sin inicializar.

Es el primer sitio donde se ve en pantalla lo que el comentario de
`nx-ruby18.rb` anunciaba, y merece la pena tenerlo apuntado: en esta familia,
un gráfico roto y aislado en medio de una escena que por lo demás está bien es
casi seguro `RtlMoveMemory`, no un recurso que falte.

## Win32API: 28 pedidas, ninguna sin semántica

Llamadas de verdad: `advapi32!RegOpenKeyExA`, `kernel32!GetCurrentProcess`,
`kernel32!GetPrivateProfileString` (esa sí se implementa: lee el `Game.ini` de
la tarjeta), `kernel32!SetPriorityClass`, `kleinbitmap!version`,
`ole32!CoTaskMemFree` y `shell32!SHGetKnownFolderPath`.

## Hitos

| # | Hito | Captura |
|---|---|---|
| 1 | Pantalla de título | `pokemon-titan-hito-1-titulo.png` |
| 2 | Partida nueva | `pokemon-titan-hito-2-partida-nueva.png` |
| 3 | Nombre del jugador en la rejilla | se atravesó con el patrón Z-C-Z; la captura que sí está es la de la introducción, `pokemon-titan-intro-profesora.png` |
| 4 | Primer mapa | `1 Intro` en el registro |
| 5 | Menú | no se llegó |
| 6 | Guardar | no se llegó |
| 7 | Combate | no se llegó |

## Lo que queda

- Lo mismo que Iberia: introducción, mapa jugable, menú y guardar. No hay error
  que lo impida.
- El sprite de `RtlMoveMemory`: averiguar qué script lo construye y si vale la
  pena reescribirlo contra `Bitmap` de mkxp-z en un shim del perfil.
- Los tres `.mid` no suenan, por lo mismo que en Iberia.

---

## Segunda vuelta — 9 de septiembre de 2026, tarde: **jugable**, y un arreglo de 1.8 más

**Estado: `jugable`.** `Game.rxdata` de 56.737 bytes en `12 Casa`. Tres vueltas:
la primera destapó el décimo arreglo de la familia, y es el más caro de los diez
porque no mata al arrancar sino **al cambiar de mapa**, o sea en cualquier
momento de una partida.

### Vuelta 1 — pantalla negra a 0 FPS al entrar en el primer mapa

Sin `errorlog.txt`. En `mkxp-debug.log`:

```
Section116:95:in `block in <main>': unexpected return (LocalJumpError)
	from Section040:54:in `block in trigger'      (PBEvent#trigger)
	from Section040:49:in `each'
	from Section088:622:in `setMapChanged'
	from Section088:600:in `setup'
	from Section019:230:in `transfer_player'
	...
	from Section150:263:in `main'
```

La línea es de `PokemonRoaming.rb`:

```ruby
Events.onMapChange+=proc {|sender,e|
   return if !$PokemonGlobal
```

**En Ruby 1.8 `Kernel#proc` era un alias de `lambda`**, así que ese `return`
salía del proc y era legal. Desde 1.9 `proc` es `Proc.new`, el `return` intenta
volver a un método que ya no existe —el bloque se escribió en el nivel superior
de la sección— y sale `LocalJumpError`. El cargador de Essentials **no** rescata
esto: el hilo RGSS se muere y la pantalla se queda negra a 0 FPS.

Cuántos hay, contados con las llaves emparejadas sobre los cinco corpus y no con
un grep de tres líneas:

| Juego | `proc {...}` | con `return` | ficheros |
|---|---|---|---|
| Ópalo | 845 | **74** | 10 |
| Z | 1.341 | **74** | 10 |
| Iberia | 703 | **72** | 9 |
| Titán | 674 | **72** | 9 |
| Uranium | 669 | **78** | 10 |
| Añil (v21.1, Ruby 3.1) | 2.060 | **0** | 0 |

Siempre los mismos ficheros: los manejadores de objetos
(`ItemHandlers::UseInField`), los MO de campo, el Pokémon errante, el Poké Radar,
el Chatter, los Pokémon oscuros. Y **cero en Añil**, que es la versión moderna de
Essentials: eso es lo que confirma que es una diferencia de 1.8 y no una manía de
estos juegos.

**Arreglo** (`runtime/lib/nx-ruby18.rb`): `Kernel#proc` devuelve el bloque
**envuelto** en otro `Proc` que recoge el `LocalJumpError` de su `return` y
devuelve `exit_value`, que es el valor que el juego quería devolver. No se
convierte el bloque en lambda —`define_method` es el único camino y le cambia el
`self`, que es justo lo que estos manejadores necesitan conservar—, y así además
se mantiene la tolerancia de arity de los `Proc`, que es *más* permisiva que la
del `lambda` de 1.8 y por tanto no puede romper nada que antes funcionara. El
`arity` se repone a mano sobre el envoltorio porque `PBEvent#trigger` lo mira
(`if callback.arity>2`) para distinguir los manejadores de tres argumentos.

En el registro sale, la primera vez que dispara:

```
[1.8] `return` dentro de un proc de 1.8 en Section116:92
```

### Vueltas 2 y 3 — la introducción y el guardado

`Map001`, evento 4 «Intro», 223 comandos: ocho cajas de Oak y de la profesora
Sarya, la elección de iniciales, chico/chica, la rejilla, el
`¿Así que te llamas X?`, dos cajas, el randomizador, la modalidad especial
(Shinylocke/Starterlocke) y la dificultad. **En las seis elecciones el índice 0
es lo que interesa**, así que un chorro de `Z` con una `C` intercalada la cruza
sola; aquí bajar sería meterse en las ramas de `Infórmame`, que vuelven a
preguntar. Detrás, `267 Intro` tiene quince cajas más y luego transfiere a
`12 Casa` en (4,7): con dieciséis bloques se quedaba en la segunda escena
(vuelta 2), con veinticuatro llega (vuelta 3).

Menú de pausa igual que Iberia: `Mochila / <nombre> / Guardar / ...`, **dos
ABAJO**.

| ms | dónde |
|---|---|
| 51.871 | `[donde] mapa 1 Intro en (9,7)` |
| 108.153 | `[donde] mapa 267 Intro en (9,6)` |
| 164.464 | `[donde] mapa 12 Casa en (4,7)` |

### Hitos

| # | Hito | Captura |
|---|---|---|
| 4 | Primer mapa jugable | `pokemon-titan-hito-4-mapa.png`, `-5-andando.png` |
| 5 | Menú | `pokemon-titan-hito-6-menu.png`, `-7-menu-guardar.png` |
| 6 | **Guardar** | `pokemon-titan-hito-8-confirmar.png`, `-9-guardado.png` |
| 7 | Combate | no se llegó |

### Lo que queda

- El primer combate.
- El sprite de ruido de `RtlMoveMemory` junto a la profesora, igual que estaba.

---

## 20 de octubre de 2026: Ryujinx se cae en Pueblo Paleto (mapa 3), y es Ryujinx

Recorrido con `guion.ps1` y una partida nueva que empieza en `MetadataHome`
(mapa 3, *Pueblo Paleto*, el primer exterior que se pisa en este port). Tres de
tres veces, **`Ryujinx.exe` se cierra** (visor de eventos: `APPCRASH`,
`0xc0000005` en `Ryujinx.exe`, offsets distintos) sin una línea de error ni en
el juego ni en el registro del emulador. Igual con la ventana visible, con la
memoria en `SoftwarePageTable` y sin PPTC.

Acotado con trazas: dentro de `CustomTilemap#refresh_autotiles`, el triple
bucle `for y / for x / for z ... break` que busca autotiles animados (el pueblo
tiene `agua`, de 11 fotogramas). Y reproducido **sin datos del juego**:

```ruby
for y in 0...2000
  for z in 0...3
    break        # Ryujinx muere en el 407.º
  end
end
```

`break` desde un bloque llamado por C (`Range#each`) es un `longjmp`. ARMeilleure
traduce cada llamada del juego a una llamada nativa del PC, y un `longjmp` del
juego deja esos marcos en la pila del PC: unos 400 la agotan. En la consola,
`longjmp` restaura la pila y no se acumula nada; por eso se da por **fallo del
emulador**, sin comprobar en hardware. Iberia no lo dispara porque Albacete no
tiene autotiles animados.

Consecuencia práctica: los exteriores de Titán con agua animada no se pueden
probar en Ryujinx 1.3.3. Las sondas de la traza (`nx-traza-mapa.rb`,
`nx-bucle.rb`) eran temporales y no se guardan.
