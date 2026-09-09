# rgss-switch — juegos de RPG Maker XP en Nintendo Switch

Un mismo motor para cualquier juego de RPG Maker XP / Pokémon Essentials que ya
funcione sobre mkxp-z en el PC: **mkxp-z 2.4.2 + CRuby 3.1.7 compilados nativos
para Horizon OS**. No es un emulador de Windows. Cada juego vive en su propia
carpeta de la tarjeta, con su icono y su nombre en el menú HOME.

Necesitas tres cosas: una Switch con CFW (Atmosphère), **tu propia copia del
juego para PC**, y la entrega de este proyecto.

> Ningún juego viene aquí ni vendrá. Son de sus autores, y Pokémon es de
> Nintendo; este repositorio sólo contiene el motor portado y las herramientas.

## Jugar

1. **Descarga la entrega** (`rgss-switch-x.y.z.zip`) y descomprímela entera. El
   empaquetador necesita todo lo que va dentro (`motor/`, `lib/`, `juegos/`,
   `tools/`), así que no lo saques de la carpeta.
2. **Doble clic en `Empaquetar.cmd`.** Elige la carpeta de tu juego para PC (la
   que tiene `Game.exe`, `Data`, `Graphics`…) y una carpeta de salida — puede
   ser directamente la raíz de la tarjeta SD.

   En cuanto eliges la carpeta te dice **qué juego ha reconocido**, qué perfil
   le toca, con qué intérprete venía y qué carpetas suyas van dentro y fuera del
   contenedor. Léelo antes de empaquetar: ahí sale el aviso de Ruby 1.8 (más
   abajo), y es mejor saberlo antes de esperar veinte minutos de copia.

   Deja marcada la casilla **«Juntar los recursos en un solo fichero»**: los
   recursos de estos juegos son decenas de miles de ficheros y una tarjeta SD
   los copia mucho más despacio que los mismos megas en un fichero único
   (`datos.zip`). El juego lee de dentro sin descomprimir nada. Desmárcala si
   quieres cambiar gráficos o mapas a mano, o si el juego pasa de 4 GB.
3. Si la salida no era la SD, **copia la carpeta `switch`** a la raíz de la
   tarjeta. Debe quedar `SD:/switch/<slug>/<slug>.nro` — por ejemplo
   `SD:/switch/pokemon-anil/pokemon-anil.nro`. **Espera a que la copia termine
   del todo**: si se corta a medias, el juego lo dirá al arrancar, pero mejor no
   llegar ahí.
4. Elige una forma de lanzarlo:
   - **NSP (recomendado)**: instala el `<slug>.nsp` que quedó junto a la carpeta
     `switch` con Awoo Installer, DBI o Goldleaf. Aparece en el menú HOME con su
     icono y arranca con toda la memoria. El NSP sólo lleva el motor (unos
     5 MB); los datos siguen en `SD:/switch/<slug>/`.
     El empaquetador sólo puede crearlo si encuentra tus `prod.keys` (ver abajo).
   - **Homebrew**: abre el Álbum **manteniendo R** sobre cualquier juego (así el
     menú homebrew corre como aplicación, con memoria de sobra) y lanza el juego
     de la lista. Desde el Álbum a secas **no arranca**: un applet no tiene
     memoria para cientos de megas de recursos con un intérprete de Ruby dentro.

Mientras carga verás el logo del juego con una barra: **es normal que tarde**.
Con los recursos sueltos son unos veinte segundos; con el contenedor unos
segundos más, porque el motor tiene que abrir el archivo y leer su índice antes
de empezar. Si la barra se mueve, va bien.

Las partidas se guardan en `SD:/switch/<slug>/`, como en PC.

## Mando

Los nombres de los botones los pone cada juego (salen en el menú de ayuda de
mkxp-z). El reparto es siempre éste:

| Botón | RGSS |
|---|---|
| A / B | Aceptar (C) / Cancelar (B) |
| X | X |
| Y | A |
| ZL / ZR | Y / Z |
| L / R | L / R |
| Cruceta y palanca izquierda | Direcciones |

## Juegos probados

El estado sale de `juegos/<slug>/perfil.json`, y lo actualiza quien lo prueba.
Hoy, 9 de septiembre de 2026:

| Juego | Motor del PC | Estado |
|---|---|---|
| Pokémon Añil 4.0 | ruby31 | **jugable** |
| Pokémon Vanguard 4.0.3 | ruby31 | sin probar |
| Pokémon Reborn 19.5.0 | ruby31 | sin probar |
| Pokémon Ópalo 2.11 | ruby18 | sin probar |
| Pokémon Z 2.13 | ruby18 | sin probar |
| Pokémon Iberia 2.10 | ruby18 | sin probar |
| Pokémon Titán 2.10 | ruby18 | sin probar |
| Pokémon Uranium 1.3.2 | rgss1 | sin probar |

Un juego que no está en la lista se empaqueta igual, con el perfil genérico. Si
arranca, dilo: lo que hace falta para que salga en esta tabla es un perfil de
cinco líneas y alguien que lo haya encendido.

## La nota de Ruby 1.8

Este motor lleva **CRuby 3.1.7**. Muchos fan games se distribuyen con un
`Game.exe` que es mkxp-z con **Ruby 1.8.7** embebido (Ópalo, Iberia, Titán, Z), y
Uranium con el RPG Maker XP original, que es Ruby 1.8.1. El empaquetador lo
detecta mirando su ejecutable y **te avisa, pero empaqueta igual**: saber si
arranca cuesta una prueba, y suponerlo no cuesta nada y no sirve de nada.

Lo que hay medido (`docs/censo-juegos.md`): de la sintaxis son 25–28 líneas por
juego sobre corpus de más de cien mil, y el motor las transforma al cargar. Lo
que de verdad separa a esos juegos es que llaman a `Win32API` —doce o catorce
veces nada más empezar, para mover la ventana, leer el teclado o reproducir
sonido— y en una Switch no hay ninguna DLL de Windows que cargar. Si tu juego se
queda en la pantalla de carga, eso es lo primero que dirán los registros.

## Si algo va mal

Lo primero es leer la pantalla: cuando algo falta, el juego **no** se queda en
negro. Enseña un informe con lo que buscaba, dónde lo buscaba y qué hacer, y se
sale con **+**. Lo que puede decir:

- **«No encuentro los datos del juego»** — el `.nro` está en la tarjeta pero los
  recursos no, o no en la misma carpeta. Vuelve al paso 2.
- **«El paquete de datos está incompleto: la copia se cortó»** — `datos.zip`
  llegó a medias. Cópialo otra vez y espera a que termine.
- **«Falta Game.rgssad, la llave del contenedor»** — ese fichero de ocho bytes
  es lo que hace que el juego lea de dentro del `.zip`. Lo escribe el
  empaquetador; si no está, vuelve al paso 2 en vez de copiarlo a mano.
- **«Arrancado con memoria de applet»** — todo está en su sitio, pero el menú
  homebrew se abrió sin memoria suficiente. Ábrelo manteniendo **R** sobre un
  juego, o instala el NSP. (Puedes pulsar **A** para intentarlo igualmente.)

Si la pantalla no dice nada, o el fallo es del motor o del juego, **los
registros están todos en `SD:/switch/<slug>/`** y son los que hay que adjuntar
al reportar:

| Fichero | Qué trae |
|---|---|
| `mkxp-boot.log` | El arranque del motor. Primera línea: qué versión arrancó. |
| `mkxp-ruby.log` | Todo lo que el juego imprimió con `puts`, y los errores de Ruby. |
| `errorlog.txt` | El error del juego, si el juego lo escribió. |
| `mkxp-debug.log` | Lo que mkxp-z tenga que decir. |

- **Se queda en negro o vuelve al menú**: `mkxp-boot.log` y `mkxp-ruby.log`.
- **Va a tirones**: `Empaquetar.ps1 -Diagnostico` deja las sondas puestas y crea
  el `diagnostico.txt` que las enciende; el registro traerá una línea `[tiron]`
  por cada fotograma lento con su reparto. Sin ese fichero el juego arranca más
  rápido, así que bórralo cuando termines de medir.
- **Actualizar el motor**: marca **«Solo actualizar el motor»** (o pasa
  `-SoloMotor`). Rehace `<slug>.nro`, `mkxp.json` y `lib/` y **no toca ni un
  mega** de los recursos, ni las partidas guardadas, ni el `Game.ini`. La
  carpeta del juego ya tiene que existir en la salida; si no, te lo dice.
- **No tengas las dos cosas a la vez**: si en la carpeta hay un `datos.zip` *y*
  las carpetas sueltas, el juego lee del `.zip` y las carpetas sólo ocupan
  sitio. El empaquetador te avisa cuando pasa.

## El NSP y las `prod.keys`

Un NSP va firmado con las claves de una consola, y esas claves **sólo salen de
tu propia Switch**, con Lockpick_RCM. El empaquetador las busca en
`%USERPROFILE%\.switch\prod.keys` y en `%APPDATA%\Ryujinx\system\prod.keys`, o
donde le digas con `-Claves <ruta>`. **Las lee donde están y no las copia a
ningún sitio.** Sin ellas te entrega sólo el `.nro` y te dice por qué.

## Desde la línea de órdenes

```powershell
# sólo detectar: qué juego es, qué perfil le toca, cuánto ocupa
powershell -File Empaquetar.ps1 -Juego "C:\...\Pokemon Opalo" -SoloDetectar

# empaquetar
powershell -File Empaquetar.ps1 -Juego "C:\...\Pokemon Opalo" -Salida D:\ -Contenedor zip

# actualizar solo el motor de una instalacion que ya esta en la tarjeta
powershell -File Empaquetar.ps1 -Juego "C:\...\Pokemon Opalo" -Salida D:\ -SoloMotor
```

Y desde una shell POSIX (la de devkitPro, WSL, Git Bash):

```sh
./empaquetar.sh "/c/juegos/Pokemon Opalo" /d/            # contenedor
./empaquetar.sh "/c/juegos/Pokemon Opalo" /d/ carpetas   # sueltos
./empaquetar.sh "/c/juegos/Pokemon Opalo" /d/ --solo-motor
DETECTAR=1 ./empaquetar.sh "/c/juegos/Pokemon Opalo"
```

## Añadir tu juego

Si el perfil genérico no basta —tu juego lee alguna carpeta suya con `Dir` o
`File.read`, o necesita una clave de `mkxp.json` que no está—, un perfil son
cinco líneas de JSON. Cómo se escribe está en `juegos/README.md`, y el contrato
entero (nombres, capas de `mkxp.json`, qué va dentro del contenedor y qué no) en
`CONVENCIONES.md`.

## Hacer tu propia versión del motor

Para tocar el motor hace falta devkitPro (devkitA64) y la shell MSYS2 que
instala. Entonces:

```sh
./construir.sh        # compila el .nro, el NSO y monta release/
```

Si es la primera vez en esa máquina, antes hay que portar CRuby y las
dependencias (`build-deps.sh`, `build-deps2.sh`, `build-ruby-switch.sh`,
`finalize-ruby.sh`); `construir.sh` lo dice cuando falta. El `README.md` es la
bitácora completa: cada problema que da esa cadena y cómo se arregló.

Los shims de Ruby que arreglan la compatibilidad y el rendimiento están en
`runtime/lib/nx-*.rb`, cada uno con el porqué medido en su cabecera; los que son
de un juego concreto, en `juegos/<slug>/lib/`. Las sondas con las que se
encontraron los tirones están en `runtime/diagnostico/`.
