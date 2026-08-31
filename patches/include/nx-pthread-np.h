/* Declaracion de pthread_getattr_np para recompilar thread.c de Ruby.
   devkitA64 trae toda la familia pthread_attr_* pero no la extension _np de
   glibc; la implementacion esta en mkxp-z-nx/nx/nx_pthread_np.c, sobre la
   estructura Thread de libnx. Este cabecero se inyecta solo en esa unidad de
   compilacion para no alterar el resto de la construccion de Ruby. */
#ifndef NX_PTHREAD_NP_H
#define NX_PTHREAD_NP_H
#include <pthread.h>
int pthread_getattr_np(pthread_t hilo, pthread_attr_t *attr);
#endif

/* Ruby solo llama a pthread_attr_setstacksize si PTHREAD_STACK_MIN existe
   (thread_pthread.c:1199). devkitA64 no la define en ningun cabecero, asi que
   Ruby no pedia tamano y sus hilos se quedaban con los 127 KiB por omision,
   cuando el propio Ruby reserva 1 MiB con alloca nada mas entrar: el primer
   Thread.new se salia de la pila por abajo.
   Se comprobo midiendo que devkitA64 SI respeta la peticion cuando se hace
   (se pidio 1 MiB y el hilo salio con 1023 KiB), asi que basta con definirla.
   El valor es el minimo de POSIX; Ruby solo la usa como condicion. */
#ifndef PTHREAD_STACK_MIN
#define PTHREAD_STACK_MIN 16384
#endif
