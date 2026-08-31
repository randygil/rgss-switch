/*
 * nx_fcntl.c — fcntl() utilizable sobre ficheros en Horizon OS.
 *
 * libnx implementa fcntl() dentro de su capa de sockets (para poder poner un
 * socket en modo no bloqueante). Para cualquier OTRO descriptor la respuesta es
 * inservible; medido sobre un fichero de la SD:
 *
 *     open("lib/socket.rb", O_RDONLY) -> 3      correcto
 *     fstat(3)  -> modo 0100666, S_ISREG        correcto
 *     fcntl(3, F_GETFD) -> 95                   basura
 *     fcntl(3, F_GETFL) -> -1, errno 108        ENOTSOCK
 *
 * Ruby lo nota al cargar ficheros: open_load_file() abre con O_NONBLOCK y
 * despues llama a fcntl(F_GETFL) para quitarlo; al fallar, aborta con
 * "LoadError: Socket operation on non-socket". Eso deja inservible require(),
 * y el juego lo usa para 'set', 'tsort', 'socket' e 'io/wait' -- el gestor de
 * plugins muere en el primero y cierra el juego.
 *
 * Se envuelve fcntl con -Wl,--wrap=fcntl. El criterio de reparto es fstat: si
 * el descriptor es un fichero de verdad lo atendemos aqui; si no, se delega en
 * libnx, que es quien sabe de sockets.
 *
 * Las respuestas son las que daria un POSIX cualquiera sobre un fichero
 * regular. En Horizon no hay exec(), asi que FD_CLOEXEC no significa nada, y
 * los ficheros nunca bloquean, asi que O_NONBLOCK tampoco. F_GETFL informa
 * O_RDWR porque el sistema de ficheros no guarda con que banderas se abrio y
 * la respuesta permisiva es la que no provoca errores falsos de "no abierto
 * para escritura".
 */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/stat.h>

int __real_fcntl(int fd, int cmd, ...);

/* nx_pipe.c */
int nx_pipe_es(int fd);
int nx_pipe_getfl(int fd);
int nx_pipe_setfl(int fd, int flags);

int __wrap_fcntl(int fd, int cmd, ...)
{
    va_list ap;
    uintptr_t arg;
    struct stat st;

    va_start(ap, cmd);
    arg = va_arg(ap, uintptr_t);
    va_end(ap);

    /* Las tuberias de nx_pipe.c SI distinguen bloqueante de no bloqueante, y
     * de eso depende que funcionen: consume_communication_pipe() lee en bucle
     * hasta recibir EAGAIN, asi que con O_NONBLOCK ignorado se quedaria
     * esperando para siempre en la segunda lectura. Van antes que el reparto
     * por fstat porque aqui la respuesta permisiva no vale. */
    if (fd >= 0 && nx_pipe_es(fd)) {
        switch (cmd) {
        case F_GETFD:  return 0;
        case F_SETFD:  return 0;                  /* no hay exec() en Horizon */
        case F_GETFL:  return nx_pipe_getfl(fd);
        case F_SETFL:  return nx_pipe_setfl(fd, (int)arg);
        case F_DUPFD:  return dup(fd);
        default:
            errno = EINVAL;
            return -1;
        }
    }

    if (fd >= 0 && fstat(fd, &st) == 0 && !S_ISSOCK(st.st_mode)) {
        switch (cmd) {
        case F_GETFD:  return 0;
        case F_SETFD:  return 0;
        case F_GETFL:  return O_RDWR;
        case F_SETFL:  return 0;
        case F_DUPFD:  return dup(fd);
        default:
            errno = EINVAL;
            return -1;
        }
    }

    return __real_fcntl(fd, cmd, arg);
}
