/*
 * nx_pthread_np.c — pthread_getattr_np() para Horizon OS.
 *
 * Ruby necesita conocer los limites de la pila de cada hilo para que el
 * recolector de basura sepa hasta donde escanear. Lo averigua con
 * pthread_getattr_np, y si esa funcion no existe define STACKADDR_AVAILABLE a
 * nada; entonces thread_pthread.c:1028 hace:
 *
 *     rb_raise(rb_eNotImpError,
 *              "ruby engine can initialize only in the main thread");
 *
 * en CUALQUIER hilo nuevo que no sea el que inicializo el interprete. mkxp-z
 * inicializa Ruby en el hilo RGSS, asi que el primer Thread.new del juego
 * -- uno de nivel superior en el plugin BoxIntegration -- mataba el proceso.
 * Y lo mataba de mala manera: la excepcion se lanza antes de que el contexto
 * de ejecucion del hilo este montado, asi que en vez de una excepcion de Ruby
 * sale un acceso a la direccion 0.
 *
 * devkitA64 trae toda la familia pthread_attr_* en libsysbase pero no la
 * extension _np de glibc. Falta poco: libnx guarda la pila de cada hilo en su
 * estructura Thread, y threadGetSelf() la devuelve. Se rellena el attr con la
 * API publica (setstack) para no depender de como sea pthread_attr_t por
 * dentro.
 *
 * Ruby solo llama a esta funcion con pthread_self() (ver get_stack en
 * thread_pthread.c), asi que no hace falta resolver un hilo arbitrario. Si aun
 * asi llega otro, se responde EINVAL en vez de inventar una respuesta.
 */
#include <errno.h>
#include <pthread.h>
#include <switch.h>

int pthread_getattr_np(pthread_t hilo, pthread_attr_t *attr)
{
    Thread *t;
    int r;

    if (!attr)
        return EINVAL;

    if (!pthread_equal(hilo, pthread_self()))
        return EINVAL;

    t = threadGetSelf();
    if (!t || !t->stack_mem || t->stack_sz == 0) {
        /* El hilo principal no lo crea libnx y no aparece en su lista. Ruby ya
           trata ese caso por separado (compara con native_main_thread.id), asi
           que aqui basta con reconocer que no lo sabemos. */
        return ENOENT;
    }

    r = pthread_attr_init(attr);
    if (r != 0)
        return r;

    r = pthread_attr_setstack(attr, t->stack_mem, t->stack_sz);
    if (r != 0) {
        pthread_attr_destroy(attr);
        return r;
    }

    return 0;
}
