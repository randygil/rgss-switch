/*
 * nx_texturas.c — cuenta la memoria de video que el juego tiene viva.
 *
 * Los registros de los tres jugadores del 5 y 6 de septiembre de 2026 dejaban
 * un agujero justo en el sitio donde estaba el problema. El monton se repartia
 * asi:
 *
 *   [monton] reparto: fondo 306 | img 74 | cad 12 | resto 676 MB
 *
 * y ese "resto" —entre 557 y 752 MB segun el jugador— es el termino que manda,
 * el que crece durante toda la partida y del que no se sabia nada. Se le habia
 * puesto la etiqueta "texturas vivas + motor + ruby" porque era lo unico
 * honesto que se podia decir: nadie las contaba.
 *
 * El fondo de texturas (TexPool) solo ve las que pasan por el: las que un
 * Bitmap suelta y otro reaprovecha. Las que el juego tiene ABIERTAS en este
 * momento —cada sprite en pantalla, cada tileset, cada retrato, cada cuadro de
 * texto vivo— no pasan por ahi y nunca se han contado. El presupuesto del
 * fondo se baja a 192 MB para que la GPU no se quede sin sitio, pero si lo que
 * llena la GPU son estas, bajar el presupuesto es apagar el fuego del vecino.
 *
 * Aqui se cuentan, y se cuentan donde no hay escapatoria: en glTexImage2D. Los
 * dos sitios de gl-util.h por los que pasa toda textura de este motor son
 * TEX::allocEmpty (las que se reservan vacias, incluido el guardian de §5.64) y
 * TEX::uploadImage (las que se cargan de un PNG, que son la mayoria y las
 * gordas). Y se descuentan en TEX::del, que es el unico borrado.
 *
 * La tabla va indexada por el nombre de la textura de OpenGL. Los nombres que
 * reparte glGenTextures son pequenos, densos y se reciclan, asi que un array
 * plano que crece al doble es exacto y cuesta un desplazamiento por operacion;
 * un mapa seria mas codigo y mas lento para el mismo resultado. Si el nombre se
 * sale de la tabla y no se puede agrandar, la textura no se cuenta y se anota:
 * es mejor un numero que se sabe corto que un numero que miente.
 *
 * Todo esto vive en el hilo de dibujo y solo en el —OpenGL en mkxp-z es de un
 * solo hilo, y el informe sale de nx_marco(), que es ese mismo hilo—, asi que
 * no hay candado. Si algun dia se llama desde otro sitio, hara falta.
 */

#include <switch.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* Bytes de cada nombre de textura vivo. Cero es "no hay textura con ese
 * nombre", que es lo mismo que dice OpenGL del nombre 0. */
static unsigned *tabla;
static unsigned  tabla_n;

static unsigned long long vivos_bytes;
static unsigned           vivas;
static unsigned           perdidas;   /* las que no cupieron en la tabla */

/* El maximo historico, que es el numero que de verdad explica una caida:
 * cuando la GPU dice que no, lo que importa no es lo que hay ahora sino lo que
 * llego a haber. */
static unsigned long long pico_bytes;
static unsigned           pico_vivas;

static int tabla_cabe(unsigned nombre)
{
    unsigned nueva;
    unsigned *p;

    if (nombre < tabla_n)
        return 1;

    /* Un nombre absurdo no agranda la tabla hasta comerse el monton: por
     * encima de un millon de texturas vivas algo esta mal en otro sitio y no
     * se va a arreglar reservando cuatro megas mas. */
    if (nombre >= 1000000u)
        return 0;

    nueva = tabla_n ? tabla_n : 256u;
    while (nueva <= nombre)
        nueva *= 2u;

    p = (unsigned *)realloc(tabla, nueva * sizeof(unsigned));
    if (!p)
        return 0;

    memset(p + tabla_n, 0, (nueva - tabla_n) * sizeof(unsigned));
    tabla = p;
    tabla_n = nueva;
    return 1;
}

void nx_textura_reserva(unsigned nombre, unsigned ancho, unsigned alto);
void nx_textura_reserva(unsigned nombre, unsigned ancho, unsigned alto)
{
    unsigned bytes;

    if (!nombre)
        return;                 /* nadie reserva sobre el nombre 0 */

    if (!tabla_cabe(nombre)) {
        perdidas++;
        return;
    }

    /* RGBA de un byte por canal, que es lo unico que este motor sube. Es lo
     * que pide el juego, no lo que la GPU acaba gastando: nouveau alinea y
     * puede reservar mas. El numero sirve para comparar consigo mismo a lo
     * largo de una partida, que es para lo que se puso. */
    bytes = ancho * alto * 4u;

    /* Reespecificar una textura que ya existia sustituye lo que hubiera: se
     * descuenta lo viejo antes de sumar lo nuevo. Esto pasa de verdad y no
     * poco —el guardian de §5.64 reintenta sobre el mismo nombre, y gpTexFBO
     * se reespecifica cada vez que hace falta mas grande—, y sin esta resta
     * el contador subiria sin que nadie hubiera pedido memoria. */
    if (tabla[nombre]) {
        vivos_bytes -= tabla[nombre];
        vivas--;
    }

    tabla[nombre] = bytes;
    vivos_bytes += bytes;
    vivas++;

    if (vivos_bytes > pico_bytes) {
        pico_bytes = vivos_bytes;
        pico_vivas = vivas;
    }
}

void nx_textura_borra(unsigned nombre);
void nx_textura_borra(unsigned nombre)
{
    if (!nombre || nombre >= tabla_n || !tabla[nombre])
        return;

    vivos_bytes -= tabla[nombre];
    vivas--;
    tabla[nombre] = 0;
}

/* Lo que se ensena en el informe del monton. Devuelve los megas vivos ahora y
 * deja el resto por referencia, para que quien lo llame arme una sola linea. */
unsigned nx_texturas_informe(unsigned *n_vivas, unsigned *pico_mb,
                             unsigned *n_pico, unsigned *n_perdidas);
unsigned nx_texturas_informe(unsigned *n_vivas, unsigned *pico_mb,
                             unsigned *n_pico, unsigned *n_perdidas)
{
    if (n_vivas)    *n_vivas    = vivas;
    if (pico_mb)    *pico_mb    = (unsigned)(pico_bytes / (1024u * 1024u));
    if (n_pico)     *n_pico     = pico_vivas;
    if (n_perdidas) *n_perdidas = perdidas;
    return (unsigned)(vivos_bytes / (1024u * 1024u));
}
