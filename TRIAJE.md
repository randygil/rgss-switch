# Triaje de registros de jugadores

`triaje.py` lee la carpeta de registros que manda un jugador y escribe un
informe en español en `docs/consola/AAAAMMDD-<etiqueta>/analisis.md`, con los
registros crudos archivados al lado. Sustituye a leer los `[exc]` a mano.

## Cómo se usa

```
python triaje.py "C:/Users/Usuario/Downloads/AÑIL ERROR" --etiqueta pidgey
```

Con eso basta. Opciones que a veces hacen falta:

| opción | para qué |
|---|---|
| `--etiqueta pidgey` | la palabra que nombra el caso; por defecto, el nombre de la carpeta |
| `--fecha 20260905` | la fecha del caso; por defecto, hoy |
| `--relato "..."` | lo que contó el jugador, en una frase, para que entre en el informe |
| `--destino <carpeta>` | escribir en otro sitio en lugar de `docs/consola/AAAAMMDD-<etiqueta>` |
| `--nombre otro.md` | otro nombre para el informe |
| `--sin-archivar` | no copiar los registros crudos al destino |

Si en el destino ya hay un `analisis.md` escrito a mano, el informe se guarda
como `analisis-automatico.md` y el escrito a mano no se toca. Eso es lo que hay
en `docs/consola/20260905-pidgey/`: el análisis a mano y, al lado, el que sale
de la herramienta, para poder compararlos.

## Qué mira

* **La compilación**: la primera línea de `mkxp-boot.log` —`[build] 1.0.0 b14
  01/09 17:43`— y, contra la tabla `ARREGLOS` del propio guion, si esa
  compilación lleva los arreglos conocidos. Cuando salga una publicación que
  lleve el guardián de §5.64, se añade a esa tabla y todos los informes
  siguientes lo saben.
* **Los volcados `[exc]`**: el desplazamiento relativo (`pc` menos `base`, que
  es lo único comparable entre arranques), los registros, la pila, y si dos
  volcados son el mismo camino de código o el mismo sitio alcanzado por
  caminos distintos.
* **Las series**: tamaño del fondo de texturas, picos del montón y hueco libre,
  con mínimo, máximo y si suben sin bajar nunca —que es la señal de una fuga—.
  El montón se juzga por sesión, porque entre una sesión y la siguiente el
  proceso muere y el contador vuelve a empezar. Y del fondo, además del rango,
  **la última medida antes de cada caída**: el rango de la partida entera
  arrastra la rampa del arranque desde 57 MB y hace parecer holgado lo que no lo
  estaba, así que ése es el número que decide si se tocó el techo.
* **Los tirones**, separando el tirón de verdad de la consola dormida. El
  criterio son tres reglas: por encima de un minuto siempre es una suspensión
  —un fotograma de tres minutos no existe—; por debajo, hace falta que la CPU no
  haya hecho nada (menos del 5 % del fotograma) y que el tiempo esté en los
  cajones de esperar, que son `comp` **y** `resto`. Mirar sólo `comp`, que es lo
  que se hacía, dejaba escapar la mitad de las suspensiones.
* **La partida**: sesiones, duración de cada una, y si Essentials dejó
  excepción en `errorlog.txt`. Que no haya `errorlog.txt` también es un dato:
  significa que la muerte fue por debajo de Ruby.
* **Dónde estaba el jugador**: en un registro real, en ningún sitio. El informe
  lo dice con esas palabras en lugar de prometer lo que no hay, y remite a la
  especificación de la línea `[donde]` que haría falta en el motor
  (`docs/consola/20260906-dos-jugadores.md`).
* **Los casos ya archivados** en `docs/consola/`: si el desplazamiento coincide
  y la compilación es la misma, el informe lo dice. La compilación que se
  compara es la de la sesión de cada volcado, no el primer `[build]` del
  fichero, porque un registro de desarrollo mezcla compilaciones.

Lo que **no** hace por sí mismo: poner nombres de función a los
desplazamientos. Eso pide el binario de esa compilación y es otra herramienta;
entra por el enganche que se explica abajo, y cuando puede resolver, la pila del
informe sale con los nombres puestos.

## El enganche para los símbolos

La función `resolver_simbolos(compilacion, desplazamientos)` de `triaje.py` es
el punto por donde entra la herramienta que resuelve un desplazamiento a nombre
de función con el `.elf` archivado. Está separada a propósito: necesita el
binario de esa compilación concreta y el toolchain, y el triaje tiene que
funcionar igual sin ellos.

El contrato es corto: se le pasa el `dict` de la compilación (`version`, `b`,
`fecha`) y una lista de desplazamientos en hexadecimal (`"0x7abd30"`), y
devuelve la pareja `(nombres, modo)`. `nombres` es un `dict`
`{desplazamiento: "nombre_de_funcion  fichero:linea"}` con lo que haya sabido
resolver. `modo` es `None` cuando se resolvió con el `.elf` de esa misma
compilación —los nombres son ciertos— y, si no, la frase que explica de dónde
salen y por qué son candidatos. `(None, None)` si no se puede resolver nada.

Quien lo cumple hoy es `resolver-pila.py`, que está al lado y busca el binario
en `release/simbolos/<version>-b<n>/`. `triaje.py` lo carga por camino —su
nombre lleva guion y no se puede importar como módulo— y usa sus piezas:
`buscar()`, `archivos()`, `palabras()`, `herramienta()` y `correr()`. Hay dos
caminos:

* **Con `.elf` de esa compilación**: `addr2line` y los nombres son ciertos.
* **Sin `.elf` pero con el `.nro`** —el caso de la b14 y la b46, que se
  perdieron—: el método del Pidgey. Se toman las diez instrucciones que empiezan
  en cada marco y se buscan byte a byte en el `.text` de otra compilación que sí
  conserve símbolos; si aparecen —codificaciones relativas de los saltos
  incluidas— es la misma función compilada igual. Salen **candidatos**, y el
  informe lo dice con esa palabra. Si la misma secuencia aparece dos veces, no
  identifica nada y ese marco se queda sin nombre.

Si esa herramienta no está, si de esa compilación no se archivó ni `.elf` ni
`.nro`, o si cambia de forma por dentro, el enganche devuelve `(None, None)` y
el triaje sigue igual: el informe explica entonces cómo resolver la pila a mano.

Un detalle que costó nombres equivocados: `por_addr2line()` de `resolver-pila.py`
pasa `-i` a `addr2line` para ver las funciones metidas en línea, y con `-i` una
sola dirección puede contestar tres pares nombre/fichero en lugar de uno. Al
llamarlo con veinticinco direcciones de golpe, el primer marco con código en
línea corre todo lo que viene detrás y cada marco sale con el nombre del
siguiente. `triaje.py` llama a `addr2line` por su cuenta, sin `-i`, para que las
cuentas cuadren.

Un aviso práctico: `addr2line` es de devkitA64 y no siempre está en el `PATH`.
Si no aparece, hay que lanzar el triaje con `DEVKITPRO` apuntando a la
instalación (`C:/devkitPro`), que es donde `resolver-pila.py` lo busca.

## Qué pedirle al jugador

Esto es lo que se le copia y pega, tal cual:

> Para poder mirar qué pasó necesito los registros que el juego deja en la
> tarjeta. No son partidas ni datos personales: son ficheros de texto con lo
> que el juego fue anotando.
>
> 1. Apaga la consola y saca la tarjeta microSD, o conéctala al ordenador como
>    prefieras.
> 2. Entra en la carpeta **`switch`** y, dentro, en **`pokemon-anil`**.
> 3. Copia de ahí estos ficheros, los que estén —puede que alguno no exista, no
>    pasa nada—:
>    * `mkxp-boot.log`
>    * `mkxp-ruby.log`
>    * `mkxp-debug.log`
>    * `errorlog.txt`
>    * `mkxp.json`
> 4. Métemelos todos en una carpeta o en un zip y mándamelo.
>
> **Importante: no juegues otra partida antes de copiarlos.** Cada vez que
> arrancas el juego se escribe encima de esos ficheros y lo que pasó se pierde.
>
> Y cuéntame con tus palabras: dónde estabas, qué estabas haciendo justo antes,
> si la consola se había quedado suspendida un rato, y si te ha pasado más
> veces. Los registros dicen cuándo se cayó y por qué, pero no dicen en qué
> mapa estabas: eso solo lo sabes tú.

No importa cómo venga la carpeta —los ficheros sueltos, dentro de dos carpetas,
la `pokemon-anil` entera—: la herramienta los busca por todo el árbol. Si hay
copias repetidas, se queda con la más grande.

**Un jugador por triaje.** Si en el árbol hay registros de dos personas —una
carpeta `user 1` y otra `user2`, que es como llegaron los del 6 de septiembre—,
hay que pasar la herramienta **a cada subcarpeta por separado**, con su etiqueta.
Apuntarla a la carpeta de arriba mezclaría a los dos y saldría el informe de un
jugador que no existe. Para que eso no pueda pasar en silencio, manda el
`mkxp-boot.log`: los demás registros sólo se toman si están en su misma carpeta,
y lo que se queda fuera se avisa por pantalla y se dice en el informe.

## Lo que hace falta para que esto siga funcionando

Archivar el `.elf` de cada publicación. Sin él, resolver la pila de un jugador
depende de que la función no haya cambiado entre su compilación y otra que
conserve símbolos; el caso del Pidgey se resolvió así y fue suerte.
