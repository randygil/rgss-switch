/*
 * nx_thread_probe.c — comprobacion de TLS en hilos.
 *
 * Un hilo creado por Ruby se estrello en rb_current_execution_context, que lee
 * la variable __thread ruby_current_ec. La secuencia que falla es
 *
 *     __aarch64_read_tp:  mrs x0, tpidrro_el0
 *                         ldr x0, [x0, #504]   <- x0 valia 0
 *
 * Es decir, el hilo no tiene puntero de TLS. El hilo RGSS, que crea SDL con la
 * API de libnx, si lo tiene y ejecuta Ruby sin problemas; el que falla lo crea
 * Ruby con pthread_create. Esto separa las dos vias en una sola ejecucion:
 * se lee tpidrro_el0 ANTES de tocar nada con __thread, para que la sonda
 * sobreviva aunque el TLS este roto.
 */
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <switch.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <time.h>
#include <unistd.h>

void nx_boot_trace(const char *msg);

static __thread int nx_tls_testigo;

static uint64_t leer_tp(void)
{
    uint64_t tp;
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tp));
    return tp;
}

static void *cuerpo_hilo(void *arg)
{
    char buf[192];
    uint64_t tp = leer_tp();

    snprintf(buf, sizeof(buf), "[hilo] pthread: tpidrro_el0 = 0x%llx",
             (unsigned long long)tp);
    nx_boot_trace(buf);

    if (tp == 0) {
        nx_boot_trace("[hilo] pthread SIN TLS: no se toca la variable __thread");
        return NULL;
    }

    nx_tls_testigo = 42;
    {
        Thread *yo = threadGetSelf();
        snprintf(buf, sizeof(buf),
                 "[hilo] pthread: __thread = %d | pila = %lu KiB en %p",
                 nx_tls_testigo,
                 yo ? (unsigned long)(yo->stack_sz / 1024) : 0UL,
                 yo ? yo->stack_mem : (void *)0);
        nx_boot_trace(buf);
    }
    return NULL;
}

void nx_probe_threads(const char *donde)
{
    char buf[192];
    pthread_t t;
    int r;

    snprintf(buf, sizeof(buf), "[hilo] %s: tpidrro_el0 = 0x%llx", donde,
             (unsigned long long)leer_tp());
    nx_boot_trace(buf);

    nx_tls_testigo = 1;
    snprintf(buf, sizeof(buf), "[hilo] %s: __thread = %d", donde, nx_tls_testigo);
    nx_boot_trace(buf);

    /* Ruby pide 2 MiB por hilo con pthread_attr_setstacksize. Si devkitA64 no
       lo respeta, hay que bajar las expectativas de Ruby en vez de subir las
       suyas. */
    {
        pthread_attr_t at;
        size_t leido = 0;
        pthread_t t2;
        pthread_attr_init(&at);
        pthread_attr_setstacksize(&at, 1024 * 1024);
        pthread_attr_getstacksize(&at, &leido);
        snprintf(buf, sizeof(buf), "[hilo] %s: attr pide 1024 KiB, guarda %lu KiB",
                 donde, (unsigned long)(leido / 1024));
        nx_boot_trace(buf);
        if (pthread_create(&t2, &at, cuerpo_hilo, NULL) == 0)
            pthread_join(t2, NULL);
        pthread_attr_destroy(&at);
    }

    r = pthread_create(&t, NULL, cuerpo_hilo, NULL);
    snprintf(buf, sizeof(buf), "[hilo] %s: pthread_create -> %d", donde, r);
    nx_boot_trace(buf);
    if (r == 0)
        pthread_join(t, NULL);
    nx_boot_trace(donde);
}

/* Las cuatro propiedades de las que depende Ruby en una tuberia, y que la
 * version de nx_pipe.c tiene que cumplir todas: O_NONBLOCK de verdad (si no,
 * consume_communication_pipe se cuelga en la segunda lectura), poll() que no
 * espere cuando hay datos, poll() que respete el plazo cuando no los hay, y
 * poll() que DESPIERTE al escribir otro hilo. Esto ultimo es lo que reparte el
 * GVL: sin ello el juego avanza un fotograma cada plazo de espera. */
static void *escritor_tardio(void *arg)
{
    int fd = *(int *)arg;
    struct timespec t = { 0, 40000000 };   /* 40 ms */
    nanosleep(&t, NULL);
    write(fd, "z", 1);
    return NULL;
}

static void nx_probe_tuberia(int fds[2])
{
    char buf[192];
    char c;
    struct pollfd pfd;
    struct timespec a, b;
    pthread_t hilo;
    int r, ms;

    /* 1. no bloqueante */
    r = fcntl(fds[0], F_GETFL);
    snprintf(buf, sizeof(buf), "[tub] F_GETFL antes -> 0x%x", r);
    nx_boot_trace(buf);
    r = fcntl(fds[0], F_SETFL, (r < 0 ? 0 : r) | O_NONBLOCK);
    c = 0;
    ms = (int)read(fds[0], &c, 1);
    snprintf(buf, sizeof(buf), "[tub] F_SETFL -> %d ; read vacia -> %d errno %d (EAGAIN=%d)",
             r, ms, errno, EAGAIN);
    nx_boot_trace(buf);

    /* 2. poll con datos, sin espera */
    write(fds[1], "a", 1);
    pfd.fd = fds[0]; pfd.events = POLLIN; pfd.revents = 0;
    r = poll(&pfd, 1, 0);
    snprintf(buf, sizeof(buf), "[tub] poll con datos -> %d revents 0x%x", r, pfd.revents);
    nx_boot_trace(buf);
    read(fds[0], &c, 1);

    /* 3. poll vacia, con plazo: tiene que agotarlo, no volver al instante */
    clock_gettime(CLOCK_MONOTONIC, &a);
    pfd.revents = 0;
    r = poll(&pfd, 1, 60);
    clock_gettime(CLOCK_MONOTONIC, &b);
    ms = (int)((b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000);
    snprintf(buf, sizeof(buf), "[tub] poll vacia 60ms -> %d en %d ms", r, ms);
    nx_boot_trace(buf);

    /* 4. poll indefinida, despertada por otro hilo */
    if (pthread_create(&hilo, NULL, escritor_tardio, &fds[1]) == 0) {
        clock_gettime(CLOCK_MONOTONIC, &a);
        pfd.revents = 0;
        r = poll(&pfd, 1, 2000);
        clock_gettime(CLOCK_MONOTONIC, &b);
        ms = (int)((b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000);
        snprintf(buf, sizeof(buf), "[tub] poll despertada por otro hilo -> %d en %d ms", r, ms);
        nx_boot_trace(buf);
        pthread_join(hilo, NULL);
        read(fds[0], &c, 1);
    }

    fcntl(fds[0], F_SETFL, 0);
}

/* Ruby crea hilos correctamente pero el interprete se queda parado al volver a
 * tomar el bloqueo global. Los dos mecanismos de los que depende su planificador
 * son la tuberia de despertar (setup_communication_pipe) y las variables de
 * condicion con reloj monotono. Se comprueban por separado. */
void nx_probe_sync(void)
{
    char buf[192];
    int fds[2];
    int r;
    char c = 'x';
    ssize_t n;
    pthread_condattr_t ca;
    pthread_cond_t cv;
    pthread_mutex_t mx;
    struct timespec ts;

    r = pipe(fds);
    snprintf(buf, sizeof(buf), "[sinc] pipe() -> %d (fds %d,%d, errno %d)",
             r, r == 0 ? fds[0] : -1, r == 0 ? fds[1] : -1, errno);
    nx_boot_trace(buf);
    if (r == 0) {
        n = write(fds[1], &c, 1);
        c = 0;
        r = (int)read(fds[0], &c, 1);
        snprintf(buf, sizeof(buf), "[sinc] pipe write=%ld read=%d byte='%c'",
                 (long)n, r, c ? c : '?');
        nx_boot_trace(buf);
        nx_probe_tuberia(fds);
        close(fds[0]); close(fds[1]);
    }

    r = pthread_condattr_init(&ca);
    snprintf(buf, sizeof(buf), "[sinc] condattr_init -> %d", r);
    nx_boot_trace(buf);
    r = pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    snprintf(buf, sizeof(buf), "[sinc] condattr_setclock(MONOTONIC) -> %d", r);
    nx_boot_trace(buf);

    pthread_cond_init(&cv, &ca);
    pthread_mutex_init(&mx, NULL);
    clock_gettime(CLOCK_MONOTONIC, &ts);
    ts.tv_nsec += 50000000;          /* 50 ms */
    if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
    pthread_mutex_lock(&mx);
    r = pthread_cond_timedwait(&cv, &mx, &ts);
    pthread_mutex_unlock(&mx);
    snprintf(buf, sizeof(buf), "[sinc] cond_timedwait 50ms -> %d (ETIMEDOUT=%d)",
             r, ETIMEDOUT);
    nx_boot_trace(buf);

    pthread_cond_destroy(&cv);
    pthread_mutex_destroy(&mx);
    pthread_condattr_destroy(&ca);
    nx_boot_trace("[sinc] prueba terminada");
}
