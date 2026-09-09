/*
 * nx_ficheros.cpp — que FileTest.exist? vea tambien dentro del contenedor.
 *
 * EL FALLO. Con los datos en el contenedor, el juego se quedaba sin efectos de
 * sonido. Los graficos si aparecian, y esa asimetria es la pista: son dos
 * caminos distintos dentro de Pokemon Essentials.
 *
 *   pbResolveBitmap  -> pbTryString -> pbGetFileChar -> load_data  -> PhysFS  OK
 *   pbResolveAudioSE -> RTP.exists? -> FileTest.exist?            -> sistema  NO
 *
 * RTP.exists? y RTP.getPath preguntan con FileTest.exist?, que es el sistema de
 * ficheros de Ruby y no sabe nada de lo que PhysFS tiene montado. Con las
 * carpetas sueltas acierta siempre; con el contenedor no encuentra nada, y
 * pbResolveAudioSE devuelve nil sin llegar a pedir el sonido. El juego no falla
 * ni se queja: se queda mudo.
 *
 * DONDE SE ARREGLA. Se podria parchear RTP en Ruby, pero seria reescribir el
 * juego para tapar una diferencia de plataforma, y hay 770 scripts que pueden
 * preguntar lo mismo por su cuenta. El hueco de verdad esta mas abajo: en esta
 * consola "existe un fichero" tiene dos respuestas -la tarjeta y el contenedor-
 * y solo se estaba contestando una. Asi que se contesta la pregunta entera, una
 * vez, para todo el que la haga.
 *
 * SOLO ANADE VERDADES. Primero se pregunta al sistema, exactamente como antes;
 * solo si dice que no, se le pregunta a PhysFS. Un fichero real sigue existiendo
 * y nada que existiera deja de existir: la unica diferencia es que ahora los que
 * viajan dentro del contenedor tambien cuentan. Por eso no rompe las partidas
 * guardadas -que son ficheros de verdad y se siguen encontrando por el primer
 * camino- ni el require de Ruby, que nunca mira en Data/ ni en Audio/.
 *
 * Y NO SUSTITUYE A LA LLAVE. Game.rgssad sigue haciendo falta (README 5.60):
 * pbGetFileChar comprueba la existencia y ademas ABRE el fichero, y para abrirlo
 * usa File.open, que solo lee de la tarjeta. Son dos huecos distintos: este
 * arregla quien pregunta, la llave arregla quien lee.
 */

#include <ruby.h>

#include <unistd.h>

#include "sharedstate.h"
#include "filesystem.h"

extern "C" {
void nx_boot_trace(const char *msg);
void nx_ficheros_init(void);
}

static VALUE nx_existe(int argc, VALUE *argv, VALUE self)
{
    VALUE ruta;
    const char *p;

    (void)self;
    rb_scan_args(argc, argv, "1", &ruta);

    /* rb_get_path es la conversion que usa el propio Ruby en sus funciones de
     * fichero: admite String y Pathname y protesta igual que protestaria
     * File.exist? con cualquier otra cosa. */
    ruta = rb_get_path(ruta);
    p = RSTRING_PTR(ruta);
    if (!p || !*p)
        return Qfalse;

    /* 1. La tarjeta, que es lo que se contestaba hasta ahora. */
    if (access(p, F_OK) == 0)
        return Qtrue;

    /* 2. Lo que haya montado el motor: el contenedor, y de paso un .rgssad o
     *    cualquier RTP. Si todavia no hay motor -esto puede llamarse desde un
     *    script de precarga muy temprano- no hay nada mas que mirar. */
    if (!shState)
        return Qfalse;

    if (shState->fileSystem().exists(p))
        return Qtrue;

    /* 3. Y con el nombre tal como esta escrito de verdad. El juego viene de
     *    Windows y pide "Audio/SE/Anim/foo" con mayusculas que no siempre
     *    coinciden; desensitize resuelve eso con el indice de rutas, que es el
     *    mismo apano que hace que el juego funcione con las carpetas sueltas. */
    {
        const char *real = shState->fileSystem().desensitize(p);
        if (real && real != p && shState->fileSystem().exists(real))
            return Qtrue;
    }

    return Qfalse;
}

void nx_ficheros_init(void)
{
    VALUE mFileTest = rb_const_get(rb_cObject, rb_intern("FileTest"));

    /* Los tres nombres con los que el juego pregunta lo mismo. exists? esta
     * obsoleto en Ruby 3 pero Essentials lo usa, y mkxp-z tambien. */
    rb_define_module_function(mFileTest, "exist?", RUBY_METHOD_FUNC(nx_existe), -1);
    rb_define_module_function(mFileTest, "exists?", RUBY_METHOD_FUNC(nx_existe), -1);
    rb_define_singleton_method(rb_cFile, "exist?", RUBY_METHOD_FUNC(nx_existe), -1);
    rb_define_singleton_method(rb_cFile, "exists?", RUBY_METHOD_FUNC(nx_existe), -1);

    nx_boot_trace("[fs] FileTest.exist? contesta tambien por el contenedor");
}
