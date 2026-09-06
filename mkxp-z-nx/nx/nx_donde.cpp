/*
 * nx_donde.cpp — un canal para que los scripts escriban en el registro con
 * sello de tiempo, y con el la respuesta a "donde estaba el jugador".
 *
 * EL AGUJERO. Los tres jugadores del 5 y 6 de septiembre de 2026 mandaron
 * diecisiete volcados entre todos, y de ninguno se sabe donde estaba el
 * jugador. Uno lo conto por escrito -Ciudad Verde, ruta 1, un Pidgey- y por eso
 * ese caso se pudo entender; los otros dieciseis son una direccion de memoria y
 * nada mas. Y el sitio importa: la memoria de video se agota por lo que hay
 * cargado, o sea por el mapa, y sin saber que mapa era no hay forma de repetir
 * la caida ni de ver si dos jugadores se caen en el mismo.
 *
 * POR QUE NO SE ESCRIBE DESDE RUBY. NX.log() existe y funciona, pero escribe en
 * mkxp-ruby.log, que es otro fichero y sin sello de tiempo. Las lineas que hay
 * que poder leer juntas son [exc] -la caida-, [monton] y [fondo] -lo que habia
 * reservado- y esta: las tres primeras estan en mkxp-boot.log y llevan
 * milisegundos delante. Poniendo esta en el mismo sitio, el volcado se lee de
 * arriba abajo y dice "estaba aqui, tenia esto reservado, y murio".
 *
 * QUE SE EXPONE. Un solo metodo, NXReg.traza(texto). No es un canal de
 * proposito general para el juego: es para las sondas y para el reportero de
 * mapa de nx-compat.rb, y por eso no lleva formato, ni niveles, ni nada que
 * invite a llamarlo desde un bucle. El lado C++ ya recorta a 512 y serializa
 * con su candado (nx/nx_boot.c), asi que aqui no hace falta ninguna de las dos
 * cosas.
 */

#include <ruby.h>

extern "C" {
void nx_boot_trace(const char *msg);
void nx_donde_init(void);
}

static VALUE nx_traza(VALUE self, VALUE texto)
{
    (void)self;

    /* StringValueCStr protestaria por un nul en medio; aqui basta con no
     * mirarlo, porque lo que se escribe es una linea de registro y un nul solo
     * la cortaria antes. rb_obj_as_string admite cualquier cosa, que es lo que
     * se quiere de un canal de diagnostico: que nunca sea el que rompa. */
    texto = rb_obj_as_string(texto);
    nx_boot_trace(RSTRING_PTR(texto));

    return Qnil;
}

void nx_donde_init(void)
{
    VALUE m = rb_define_module("NXReg");

    rb_define_module_function(m, "traza", RUBY_METHOD_FUNC(nx_traza), 1);

    nx_boot_trace("[donde] NXReg.traza disponible para los scripts");
}
