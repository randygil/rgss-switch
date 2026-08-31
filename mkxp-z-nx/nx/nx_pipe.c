/*
 * nx_pipe.c — pipe(), poll() y select() sobre Horizon OS.
 *
 * El muro de §5.41. Horizon no tiene tuberias: la libc de devkitPro deja
 * pipe() como un cabo suelto y nuestro propio libnxcompat lo remataba con
 * ENOSYS. Ruby lo detecta y lo dice con todas las letras:
 *
 *     rb_warn("pipe creation failed for timer: %s, scheduling broken")
 *
 * Y no exagera. En thread_pthread.c, rb_thread_create_timer_thread() abre tres
 * tuberias —signal_self_pipe.normal, signal_self_pipe.ub_main y, como aqui no
 * hay timer_create(), la de UBF_TIMER_PTHREAD— y si la primera falla, RETORNA
 * SIN MAS. Sin ellas TIMER_THREAD_CREATED_P() es falso para siempre, el hilo
 * temporizador no existe, nadie reparte el GVL y el primer Thread.new se queda
 * colgado. Que es exactamente donde estabamos.
 *
 * La solucion no necesita nucleo. Una tuberia es un bufer circular con un
 * cerrojo y una variable de condicion, y los tres funcionan aqui (medido en
 * nx_thread_probe.c: pthread_cond_timedwait con CLOCK_MONOTONIC devuelve
 * ETIMEDOUT puntualmente). Lo unico que falta es colgarla de un descriptor de
 * fichero, y para eso newlib tiene devoptab: AddDevice() registra una tabla de
 * operaciones y __alloc_handle() reserva un fd que apunta a ella. A partir de
 * ahi read(), write(), close() y fstat() llegan solos, porque libsysbase los
 * despacha por esa misma tabla. Es el mismo mecanismo con el que libnx cuelga
 * sus sockets.
 *
 * Un cerrojo GLOBAL para todas las tuberias, no uno por tuberia. Es peor en un
 * servidor con miles; aqui hay tres y jamas hay contienda, y a cambio poll()
 * sobre varios descriptores se vuelve trivial: un solo mutex que tomar y una
 * sola condicion en la que dormir. Con cerrojos por tuberia haria falta o un
 * hilo por descriptor o una lista de espera compartida, que es reinventar esto
 * mismo peor.
 *
 * poll() y select() se envuelven porque en libnx pertenecen —otra vez— a la
 * capa de sockets y no saben nada de estos fds. El reparto es el de §5.35: si
 * no hay ninguna tuberia en la lista, se delega en libnx sin tocar nada.
 */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/iosupport.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

/* 64 KiB es lo que da Linux desde 2.6.11. Ruby escribe un byte cada vez para
 * despertar al temporizador, asi que sobra con muchisimo menos, pero el coste
 * es una reserva por tuberia y hay tres en toda la vida del juego. */
#define NXPIPE_CAP 65536

typedef struct {
    unsigned char *buf;
    size_t         cap;
    size_t         head;        /* proxima posicion a leer   */
    size_t         len;         /* bytes disponibles         */
    int            readers;     /* extremos de lectura abiertos   */
    int            writers;     /* extremos de escritura abiertos */
} nxpipe_t;

typedef struct {
    nxpipe_t *tuberia;
    int       escritura;        /* 1 = extremo de escritura */
    int       flags;            /* solo O_NONBLOCK importa  */
} nxpipe_fd_t;

static pthread_mutex_t g_cerrojo;
static pthread_cond_t  g_cambio;
static int             g_dispositivo = -1;

/*---------------------------------------------------------------------------
 * Operaciones del dispositivo
 *-------------------------------------------------------------------------*/

static int nxpipe_close(struct _reent *r, void *fd)
{
    nxpipe_fd_t *f = (nxpipe_fd_t *)fd;
    nxpipe_t *t;

    (void)r;
    if (!f || !f->tuberia)
        return 0;

    pthread_mutex_lock(&g_cerrojo);
    t = f->tuberia;
    if (f->escritura)
        t->writers--;
    else
        t->readers--;
    f->tuberia = NULL;
    /* Cerrar un extremo cambia lo que ve el otro: fin de fichero si se cierra
     * el que escribe, EPIPE si se cierra el que lee. Hay que despertarlos. */
    pthread_cond_broadcast(&g_cambio);

    if (t->readers <= 0 && t->writers <= 0) {
        pthread_mutex_unlock(&g_cerrojo);
        free(t->buf);
        free(t);
        return 0;
    }
    pthread_mutex_unlock(&g_cerrojo);
    return 0;
}

static ssize_t nxpipe_read(struct _reent *r, void *fd, char *ptr, size_t len)
{
    nxpipe_fd_t *f = (nxpipe_fd_t *)fd;
    nxpipe_t *t;
    size_t n, primera;

    if (!f || !f->tuberia || f->escritura) {
        r->_errno = EBADF;
        return -1;
    }
    if (len == 0)
        return 0;

    pthread_mutex_lock(&g_cerrojo);
    t = f->tuberia;

    while (t->len == 0) {
        if (t->writers <= 0) {           /* nadie puede escribir ya: EOF */
            pthread_mutex_unlock(&g_cerrojo);
            return 0;
        }
        if (f->flags & O_NONBLOCK) {
            pthread_mutex_unlock(&g_cerrojo);
            r->_errno = EAGAIN;
            return -1;
        }
        pthread_cond_wait(&g_cambio, &g_cerrojo);
    }

    n = (len < t->len) ? len : t->len;
    primera = t->cap - t->head;          /* hasta el final del circulo */
    if (primera >= n) {
        memcpy(ptr, t->buf + t->head, n);
    } else {
        memcpy(ptr, t->buf + t->head, primera);
        memcpy(ptr + primera, t->buf, n - primera);
    }
    t->head = (t->head + n) % t->cap;
    t->len -= n;

    pthread_cond_broadcast(&g_cambio);
    pthread_mutex_unlock(&g_cerrojo);
    return (ssize_t)n;
}

static ssize_t nxpipe_write(struct _reent *r, void *fd, const char *ptr, size_t len)
{
    nxpipe_fd_t *f = (nxpipe_fd_t *)fd;
    nxpipe_t *t;
    size_t hueco = 0, n, cola, primera;

    if (!f || !f->tuberia || !f->escritura) {
        r->_errno = EBADF;
        return -1;
    }
    if (len == 0)
        return 0;

    pthread_mutex_lock(&g_cerrojo);
    t = f->tuberia;

    for (;;) {
        if (t->readers <= 0) {
            /* POSIX manda ademas SIGPIPE. Aqui no hay senales de verdad y
             * Ruby ya trata EPIPE, asi que basta con el errno. */
            pthread_mutex_unlock(&g_cerrojo);
            r->_errno = EPIPE;
            return -1;
        }
        hueco = t->cap - t->len;
        if (hueco > 0)
            break;
        if (f->flags & O_NONBLOCK) {
            pthread_mutex_unlock(&g_cerrojo);
            r->_errno = EAGAIN;
            return -1;
        }
        pthread_cond_wait(&g_cambio, &g_cerrojo);
    }

    n = (len < hueco) ? len : hueco;
    cola = (t->head + t->len) % t->cap;
    primera = t->cap - cola;
    if (primera >= n) {
        memcpy(t->buf + cola, ptr, n);
    } else {
        memcpy(t->buf + cola, ptr, primera);
        memcpy(t->buf, ptr + primera, n - primera);
    }
    t->len += n;

    pthread_cond_broadcast(&g_cambio);
    pthread_mutex_unlock(&g_cerrojo);
    return (ssize_t)n;
}

static off_t nxpipe_seek(struct _reent *r, void *fd, off_t pos, int dir)
{
    (void)fd; (void)pos; (void)dir;
    r->_errno = ESPIPE;
    return (off_t)-1;
}

/* Imprescindible: rb_update_max_fd() llama a fstat sobre cada extremo recien
 * creado y hace rb_bug() si responde EBADF. */
static int nxpipe_fstat(struct _reent *r, void *fd, struct stat *st)
{
    nxpipe_fd_t *f = (nxpipe_fd_t *)fd;

    (void)r;
    memset(st, 0, sizeof(*st));
    st->st_mode = S_IFIFO | 0600;
    st->st_nlink = 1;
    st->st_blksize = 4096;
    if (f && f->tuberia && !f->escritura)
        st->st_size = (off_t)f->tuberia->len;
    return 0;
}

static int nxpipe_fsync(struct _reent *r, void *fd)
{
    (void)r; (void)fd;
    return 0;
}

static const devoptab_t nxpipe_devoptab = {
    .name        = "nxpipe",
    .structSize  = sizeof(nxpipe_fd_t),
    .open_r      = NULL,        /* no se abre por ruta, solo con pipe() */
    .close_r     = nxpipe_close,
    .write_r     = nxpipe_write,
    .read_r      = nxpipe_read,
    .seek_r      = nxpipe_seek,
    .fstat_r     = nxpipe_fstat,
    .fsync_r     = nxpipe_fsync,
};

static void nxpipe_iniciar(void)
{
    pthread_condattr_t attr;

    pthread_mutex_init(&g_cerrojo, NULL);
    /* CLOCK_MONOTONIC: los plazos de poll() son relativos y no deben moverse
     * si el juego o el sistema cambian la hora. */
    pthread_condattr_init(&attr);
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    pthread_cond_init(&g_cambio, &attr);
    pthread_condattr_destroy(&attr);

    g_dispositivo = AddDevice(&nxpipe_devoptab);
}

static int nxpipe_dispositivo(void)
{
    static pthread_once_t una_vez = PTHREAD_ONCE_INIT;
    pthread_once(&una_vez, nxpipe_iniciar);
    return g_dispositivo;
}

/* NULL si el descriptor no es de los nuestros. Sin cerrojo: la tabla de
 * descriptores de libsysbase es estable mientras el fd siga vivo. */
static nxpipe_fd_t *nxpipe_buscar(int fd)
{
    __handle *h;

    if (fd < 0 || g_dispositivo < 0)
        return NULL;
    h = __get_handle(fd);
    if (!h || (int)h->device != g_dispositivo)
        return NULL;
    return (nxpipe_fd_t *)h->fileStruct;
}

/*---------------------------------------------------------------------------
 * pipe()
 *-------------------------------------------------------------------------*/

int __wrap_pipe(int fds[2]);
int __wrap_pipe(int fds[2])
{
    int dev = nxpipe_dispositivo();
    nxpipe_t *t = NULL;
    int lectura = -1, escritura = -1;
    nxpipe_fd_t *fl, *fe;

    if (dev < 0) { errno = ENOSYS; return -1; }
    if (!fds)    { errno = EFAULT; return -1; }

    t = (nxpipe_t *)calloc(1, sizeof(nxpipe_t));
    if (!t) goto sin_memoria;
    t->buf = (unsigned char *)malloc(NXPIPE_CAP);
    if (!t->buf) goto sin_memoria;
    t->cap = NXPIPE_CAP;

    lectura = __alloc_handle(dev);
    if (lectura < 0) goto sin_memoria;
    escritura = __alloc_handle(dev);
    if (escritura < 0) goto sin_memoria;

    fl = (nxpipe_fd_t *)__get_handle(lectura)->fileStruct;
    fe = (nxpipe_fd_t *)__get_handle(escritura)->fileStruct;

    fl->tuberia = t; fl->escritura = 0; fl->flags = 0;
    fe->tuberia = t; fe->escritura = 1; fe->flags = 0;
    t->readers = 1;
    t->writers = 1;

    fds[0] = lectura;
    fds[1] = escritura;
    return 0;

sin_memoria:
    if (escritura >= 0) __release_handle(escritura);
    if (lectura  >= 0) __release_handle(lectura);
    if (t) { free(t->buf); free(t); }
    errno = ENOMEM;
    return -1;
}

/*---------------------------------------------------------------------------
 * Puentes para nx_fcntl.c
 *-------------------------------------------------------------------------*/

int nx_pipe_es(int fd);
int nx_pipe_getfl(int fd);
int nx_pipe_setfl(int fd, int flags);

int nx_pipe_es(int fd)
{
    return nxpipe_buscar(fd) != NULL;
}

int nx_pipe_getfl(int fd)
{
    nxpipe_fd_t *f = nxpipe_buscar(fd);
    if (!f) { errno = EBADF; return -1; }
    return (f->escritura ? O_WRONLY : O_RDONLY) | (f->flags & O_NONBLOCK);
}

int nx_pipe_setfl(int fd, int flags)
{
    nxpipe_fd_t *f = nxpipe_buscar(fd);
    if (!f) { errno = EBADF; return -1; }
    pthread_mutex_lock(&g_cerrojo);
    f->flags = flags & O_NONBLOCK;
    pthread_mutex_unlock(&g_cerrojo);
    return 0;
}

/*---------------------------------------------------------------------------
 * poll()
 *-------------------------------------------------------------------------*/

static short nxpipe_estado(nxpipe_fd_t *f, short interes)
{
    nxpipe_t *t = f->tuberia;
    short rev = 0;

    if (!t)
        return POLLNVAL;

    if (f->escritura) {
        if (t->readers <= 0)        rev |= POLLERR;   /* tuberia rota */
        else if (t->len < t->cap)   rev |= (short)(interes & POLLOUT);
    } else {
        if (t->len > 0)             rev |= (short)(interes & POLLIN);
        else if (t->writers <= 0)   rev |= POLLHUP;   /* fin de fichero */
    }
    return rev;
}

static uint64_t nxpipe_ahora_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

int __real_poll(struct pollfd *fds, nfds_t nfds, int timeout);
int __wrap_poll(struct pollfd *fds, nfds_t nfds, int timeout);

int __wrap_poll(struct pollfd *fds, nfds_t nfds, int timeout)
{
    struct pollfd pila[8];
    struct pollfd *otros = NULL;
    nfds_t i, n_tuberias = 0, n_otros = 0;
    uint64_t plazo = 0;
    int reservado = 0;

    if (nfds == 0 || !fds)
        return __real_poll(fds, nfds, timeout);

    nxpipe_dispositivo();

    for (i = 0; i < nfds; i++) {
        if (fds[i].fd < 0)            continue;
        if (nxpipe_buscar(fds[i].fd)) n_tuberias++;
        else                          n_otros++;
    }

    /* Ni una tuberia: es asunto de libnx, no lo tocamos (§5.35). */
    if (n_tuberias == 0)
        return __real_poll(fds, nfds, timeout);

    if (n_otros > 0) {
        if (n_otros <= 8) {
            otros = pila;
        } else {
            otros = (struct pollfd *)malloc((size_t)n_otros * sizeof(struct pollfd));
            if (!otros) { errno = ENOMEM; return -1; }
            reservado = 1;
        }
    }

    if (timeout > 0)
        plazo = nxpipe_ahora_ms() + (uint64_t)timeout;

    for (;;) {
        int listos = 0, ajenos = 0;
        struct timespec ts;
        uint64_t ahora, resto;

        /* Los que no son tuberias, a libnx y sin esperar. Fuera del cerrojo:
         * __real_poll puede tardar y no conviene bloquear a los escritores. */
        if (n_otros > 0) {
            nfds_t j = 0;
            int r;
            for (i = 0; i < nfds; i++) {
                if (fds[i].fd >= 0 && nxpipe_buscar(fds[i].fd)) continue;
                otros[j].fd = fds[i].fd;
                otros[j].events = fds[i].events;
                otros[j].revents = 0;
                j++;
            }
            r = __real_poll(otros, j, 0);
            j = 0;
            for (i = 0; i < nfds; i++) {
                if (fds[i].fd >= 0 && nxpipe_buscar(fds[i].fd)) continue;
                fds[i].revents = (r > 0) ? otros[j].revents : 0;
                if (fds[i].revents) ajenos++;
                j++;
            }
        }

        pthread_mutex_lock(&g_cerrojo);
        for (i = 0; i < nfds; i++) {
            nxpipe_fd_t *f;
            if (fds[i].fd < 0) { fds[i].revents = 0; continue; }
            f = nxpipe_buscar(fds[i].fd);
            if (!f) continue;                       /* ya resuelto arriba */
            fds[i].revents = nxpipe_estado(f, fds[i].events);
            if (fds[i].revents) listos++;
        }
        listos += ajenos;

        if (listos > 0) {
            pthread_mutex_unlock(&g_cerrojo);
            if (reservado) free(otros);
            return listos;
        }
        if (timeout == 0) {
            pthread_mutex_unlock(&g_cerrojo);
            if (reservado) free(otros);
            return 0;
        }

        ahora = nxpipe_ahora_ms();
        if (timeout > 0) {
            if (ahora >= plazo) {
                pthread_mutex_unlock(&g_cerrojo);
                if (reservado) free(otros);
                return 0;
            }
            resto = plazo - ahora;
        } else {
            resto = 3600000;                        /* espera indefinida */
        }
        /* Con descriptores ajenos en la lista hay que volver a preguntarle a
         * libnx cada poco, porque un socket que se pone legible no despierta
         * nuestra condicion. 10 ms es el sondeo de siempre. */
        if (n_otros > 0 && resto > 10)
            resto = 10;

        clock_gettime(CLOCK_MONOTONIC, &ts);
        ts.tv_sec  += (time_t)(resto / 1000);
        ts.tv_nsec += (long)((resto % 1000) * 1000000L);
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
        pthread_cond_timedwait(&g_cambio, &g_cerrojo, &ts);
        pthread_mutex_unlock(&g_cerrojo);
    }
}

/*---------------------------------------------------------------------------
 * select()
 *
 * Ruby solo lo usa desde IO.select, y ahi los descriptores son sockets o
 * ficheros; las tuberias del temporizador van siempre por poll(). Se envuelve
 * de todos modos porque el reparto cuesta cuatro lineas y la alternativa es
 * que un dia devuelva EBADF sin explicacion.
 *-------------------------------------------------------------------------*/

int __real_select(int n, fd_set *lec, fd_set *esc, fd_set *exc, struct timeval *tv);
int __wrap_select(int n, fd_set *lec, fd_set *esc, fd_set *exc, struct timeval *tv);

int __wrap_select(int n, fd_set *lec, fd_set *esc, fd_set *exc, struct timeval *tv)
{
    struct pollfd *p;
    int i, cuenta = 0, hay_tuberia = 0, r, espera;

    nxpipe_dispositivo();

    for (i = 0; i < n; i++) {
        int quiere = (lec && FD_ISSET(i, lec)) || (esc && FD_ISSET(i, esc)) ||
                     (exc && FD_ISSET(i, exc));
        if (!quiere) continue;
        cuenta++;
        if (nxpipe_buscar(i)) hay_tuberia = 1;
    }

    if (!hay_tuberia)
        return __real_select(n, lec, esc, exc, tv);

    p = (struct pollfd *)calloc((size_t)cuenta, sizeof(struct pollfd));
    if (!p) { errno = ENOMEM; return -1; }

    cuenta = 0;
    for (i = 0; i < n; i++) {
        short ev = 0;
        if (lec && FD_ISSET(i, lec)) ev |= POLLIN;
        if (esc && FD_ISSET(i, esc)) ev |= POLLOUT;
        if (exc && FD_ISSET(i, exc)) ev |= POLLPRI;
        if (!ev) continue;
        p[cuenta].fd = i;
        p[cuenta].events = ev;
        cuenta++;
    }

    if (!tv)
        espera = -1;
    else if (tv->tv_sec > (INT_MAX / 1000) - 1)
        espera = INT_MAX;
    else
        espera = (int)(tv->tv_sec * 1000 + (tv->tv_usec + 999) / 1000);

    r = __wrap_poll(p, (nfds_t)cuenta, espera);

    if (r >= 0) {
        int marcados = 0;
        if (lec) FD_ZERO(lec);
        if (esc) FD_ZERO(esc);
        if (exc) FD_ZERO(exc);
        for (i = 0; i < cuenta; i++) {
            int marcado = 0;
            short rv = p[i].revents;
            if (lec && (rv & (POLLIN | POLLHUP | POLLERR))) { FD_SET(p[i].fd, lec); marcado = 1; }
            if (esc && (rv & (POLLOUT | POLLERR)))          { FD_SET(p[i].fd, esc); marcado = 1; }
            if (exc && (rv & POLLPRI))                      { FD_SET(p[i].fd, exc); marcado = 1; }
            if (marcado) marcados++;
        }
        r = marcados;
    }

    free(p);
    return r;
}
