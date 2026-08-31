/*
 * nxcompat.c - Funciones POSIX que faltan en Horizon OS (newlib + libnx).
 *
 * newlib declara estas funciones en sus cabeceras pero NO las implementa:
 * el enlazado falla con "undefined reference". Aqui se proveen con valores
 * correctos para la consola.
 *
 * Nintendo Switch (Tegra X1):
 *   - pagina de memoria: 4 KiB
 *   - 4 nucleos Cortex-A57; el homebrew usa 3 (el cuarto lo reserva el sistema)
 */
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/resource.h>
#include <pwd.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <limits.h>

#define NX_PAGE_SIZE   4096L
#define NX_CORES       3L

long sysconf(int name)
{
    switch (name) {
    case _SC_PAGESIZE:            return NX_PAGE_SIZE;
    case _SC_NPROCESSORS_CONF:    return 4L;
    case _SC_NPROCESSORS_ONLN:    return NX_CORES;
    case _SC_CLK_TCK:             return 100L;
    case _SC_OPEN_MAX:            return 256L;
    case _SC_STREAM_MAX:          return 256L;
    case _SC_ARG_MAX:             return 32768L;
    case _SC_SYMLOOP_MAX:         return 8L;
    case _SC_HOST_NAME_MAX:       return 255L;
    case _SC_LOGIN_NAME_MAX:      return 32L;
    case _SC_TTY_NAME_MAX:        return 32L;
    case _SC_GETPW_R_SIZE_MAX:    return 1024L;
    case _SC_GETGR_R_SIZE_MAX:    return 1024L;
    case _SC_THREAD_STACK_MIN:    return 16384L;
    case _SC_THREAD_THREADS_MAX:  return 64L;
    case _SC_NGROUPS_MAX:         return 16L;
    case _SC_PHYS_PAGES:          return (4L * 1024L * 1024L * 1024L) / NX_PAGE_SIZE; /* 4 GiB */
    default:
        errno = EINVAL;
        return -1L;
    }
}

int getpagesize(void)
{
    return (int)NX_PAGE_SIZE;
}

/*
 * setmode() - newlib DEFINE la macro O_BINARY (como _FBINARY) pero no provee
 * la funcion. io.c de Ruby protege sus llamadas con #ifdef O_BINARY, dando por
 * hecho que toda plataforma con esa macro es de tipo DOS y trae setmode().
 *
 * Horizon abre los archivos en binario de forma nativa: no hay traduccion de
 * fin de linea, asi que no hay nada que conmutar. Devolvemos el modo previo,
 * que siempre es binario.
 */
int setmode(int fd, int mode)
{
    (void)fd; (void)mode;
    return O_BINARY;
}

/*
 * waitpid() - Horizon no tiene modelo de procesos: nunca existen hijos.
 *
 * process.c de Ruby lleva un "#error waitpid or wait4 is required", asi que
 * no basta con omitirla: hay que definir HAVE_WAITPID y proveerla. Devolver
 * -1 con ECHILD ("sin procesos hijos") es la respuesta semanticamente
 * correcta, y hace que Process.wait lance Errno::ECHILD, que es justo lo que
 * deberia ocurrir en una consola sin procesos.
 */
pid_t waitpid(pid_t pid, int *status, int options)
{
    (void)pid; (void)options;
    if (status) *status = 0;
    errno = ECHILD;
    return (pid_t)-1;
}

/* =========================================================================
 *  Modelo de procesos y usuarios
 *
 *  Horizon OS no tiene procesos, ni usuarios, ni permisos de archivo al
 *  estilo POSIX. newlib DECLARA estas funciones pero no las implementa.
 *  file.c y process.c de Ruby las referencian sin proteger, dando por hecho
 *  que "todo lo que no es Windows" es POSIX completo — pese a que ninguna
 *  de sus macros HAVE_* esta definida en config.h.
 *
 *  Criterio: valores honestos. Un unico usuario con UID/GID 0 (el homebrew
 *  corre sin aislamiento), y ENOSYS donde la operacion es genuinamente
 *  imposible, para que Ruby lance Errno::ENOSYS en vez de fallar en silencio.
 * ========================================================================= */

/* --- Identidad: un solo usuario, sin separacion de privilegios --- */
uid_t getuid(void)   { return 0; }
uid_t geteuid(void)  { return 0; }
gid_t getgid(void)   { return 0; }
gid_t getegid(void)  { return 0; }
pid_t getppid(void)  { return 0; }   /* no hay proceso padre */

/* --- Permisos de archivo: Horizon no tiene bits de modo POSIX --- */
mode_t umask(mode_t cmask)   { (void)cmask; return 0; }
int chown(const char *path, uid_t owner, gid_t group)
{ (void)path; (void)owner; (void)group; errno = ENOSYS; return -1; }

/* --- Base de datos de usuarios: no existe --- */
struct passwd *getpwnam(const char *name) { (void)name; errno = ENOENT; return NULL; }
void endpwent(void) { }

/* --- Ejecucion de programas: imposible, no hay modelo de procesos --- */
int execv(const char *path, char *const argv[])
{ (void)path; (void)argv; errno = ENOSYS; return -1; }
int execl(const char *path, const char *arg, ...)
{ (void)path; (void)arg; errno = ENOSYS; return -1; }
int execle(const char *path, const char *arg, ...)
{ (void)path; (void)arg; errno = ENOSYS; return -1; }

/* --- Tuberias y subprocesos --- */
int pipe(int fildes[2])
{ (void)fildes; errno = ENOSYS; return -1; }
FILE *popen(const char *command, const char *mode)
{ (void)command; (void)mode; errno = ENOSYS; return NULL; }
int pclose(FILE *stream)
{ (void)stream; errno = ENOSYS; return -1; }

/* --- Contabilidad de recursos: se devuelve a cero, no -1, para que
 *     Process.times y el perfilador del GC no exploten --- */
int getrusage(int who, struct rusage *usage)
{
    (void)who;
    if (!usage) { errno = EFAULT; return -1; }
    memset(usage, 0, sizeof(*usage));
    return 0;
}

/* --- pthread_kill: no hay senales que entregar.
 *     Ruby 3.1.7 llama a esta funcion SIN comprobar el retorno
 *     (thread_pthread.c:1363 y :2280), asi que devolver 0 es seguro. --- */
int pthread_kill(pthread_t thread, int sig)
{ (void)thread; (void)sig; return 0; }
