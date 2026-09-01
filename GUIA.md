# Pokémon Añil 4.0 en Nintendo Switch — guía rápida

Este port hace que el juego corra **nativo** en la consola (no es un emulador
de Windows). Necesitas tres cosas: una Switch con CFW (Atmosphère), **tu propia
copia de Pokémon Añil 4.0 para PC**, y la entrega de este port.

> El juego no viene aquí ni vendrá. Añil es de sus autores y Pokémon es de
> Nintendo; este repositorio sólo contiene el motor portado y las herramientas.

## Jugar (5 minutos)

1. **Descarga la entrega** (`anil-switch-x.y.z.zip`) y descomprímela.
2. **Doble clic en `Empaquetar.cmd`.** Elige la carpeta de tu Añil 4.0 de PC
   (la que tiene `Game.exe`, `Data`, `Graphics`…) y una carpeta de salida —
   puede ser directamente la raíz de la tarjeta SD. Copia unos 700 MB.
3. Si la salida no era la SD, **copia la carpeta `switch`** a la raíz de la tarjeta.
   Debe quedar `SD:/switch/pokemon-anil/pokemon-anil.nro`.
4. Elige una forma de lanzarlo:
   - **NSP (recomendado)**: instala `pokemon-anil.nsp` con Awoo Installer, DBI o
     Goldleaf. Aparece en el menú HOME con su icono y arranca con toda la memoria.
     El NSP sólo lleva el motor (5 MB); los datos siguen en `SD:/switch/pokemon-anil/`.
   - **Homebrew**: abre el Álbum **manteniendo R** sobre cualquier juego (así el
     menú homebrew corre como aplicación, con memoria de sobra) y lanza *Pokemon Anil 4.0*.
     Desde el Álbum a secas **no arranca**: un applet no tiene memoria para 700 MB de recursos.

La primera carga tarda unos 20 segundos (indexa 22.000 ficheros). Las partidas
se guardan en `SD:/switch/pokemon-anil/` como en PC.

## Mando

| Botón | Hace |
|---|---|
| A / B | Aceptar / Cancelar |
| X | Correr |
| Y | Acción |
| ZL | Menú |
| ZR | Especial |
| L / R | Anterior / Siguiente |

## Si algo va mal

- **Se queda en negro o vuelve al menú**: mira `SD:/switch/pokemon-anil/mkxp-boot.log`
  (primera línea: la versión que arrancó) y `mkxp-ruby.log`. Si hay un error
  del juego, `errorlog.txt`. Adjúntalos al reportar.
- **Va a tirones**: crea un fichero vacío `SD:/switch/pokemon-anil/diagnostico.txt`
  y vuelve a jugar; el registro traerá una línea `[tiron]` por cada fotograma
  lento con su reparto. Sin ese fichero el juego arranca más rápido.
- **Actualizar**: sustituye `pokemon-anil.nro`, `mkxp.json` y `lib/` por los de
  la entrega nueva. Los recursos del juego no cambian.

## Hacer tu propia versión

Para tocar el motor hace falta devkitPro (devkitA64) y la shell MSYS2 que
instala. Entonces:

```sh
./construir.sh        # compila el .nro, el .nsp si tienes prod.keys, y monta release/
```

Si es la primera vez en esa máquina, antes hay que portar CRuby y las
dependencias (`build-deps.sh`, `build-deps2.sh`, `build-ruby-switch.sh`,
`finalize-ruby.sh`); `construir.sh` lo dice cuando falta. El `README.md` es la
bitácora completa: cada problema que da esa cadena y cómo se arregló.

Los shims de Ruby que arreglan el rendimiento están en `runtime/lib/nx-*.rb`,
cada uno con el porqué medido en su cabecera. Las sondas con las que se
encontraron están en `runtime/diagnostico/`.
