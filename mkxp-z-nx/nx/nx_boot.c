/*
 * nx_boot.c — sondas de arranque para Horizon OS.
 *
 * El NRO carga, el proceso no se estrella y la primera traza de main() nunca
 * aparece. Entre la entrada del NRO y main() solo hay tres tramos:
 *
 *   __libnx_initheap  ->  __appInit  ->  __libc_init_array  ->  main()
 *                                        (45 constructores estaticos)
 *
 * Estas sondas los separan en una sola ejecucion. Se usan open()/write()
 * crudos en vez de fopen(): fopen reserva memoria, y si lo que falla es el
 * monton, la propia sonda moriria sin decir nada.
 *
 * Prioridades: 101 es la primera que permite GCC (0-100 estan reservadas),
 * 65534 la ultima. Si aparece "early" pero no "late", el fallo esta en uno de
 * los 45 constructores. Si no aparece ninguna, es anterior a __libc_init_array.
 */

#include <switch.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>

#define NX_BOOTLOG_A "sdmc:/switch/pokemon-anil/mkxp-boot.log"
#define NX_BOOTLOG_B "mkxp-boot.log"
#define NX_BOOTLOG_C "sdmc:/mkxp-boot.log"

/* Cada linea lleva delante los milisegundos transcurridos desde la primera.
 *
 * Sin ellos, "el arranque tarda mucho" es una impresion; con ellos, el registro
 * dice exactamente donde se van los segundos, que es como se descubrio que 56
 * de los 58 estaban en createPathCache (§5.48). El origen no es el arranque del
 * proceso sino la primera traza —__appInit ya ha corrido para entonces—, pero
 * eso son unos pocos milisegundos y lo que importa son los tramos.
 *
 * armGetSystemTick cuenta a 19,2 MHz y no es una llamada al sistema. El numero
 * se formatea a mano: aqui todavia no se toca el monton. */
static u64 base_tick;

/* Modo diagnostico: existe SD:/switch/pokemon-anil/diagnostico.txt. Enciende
 * las autopruebas del arranque (ficheros, hilos, tuberias, sincronizacion) y
 * el registro linea a linea. Se decide una vez y se cachea, porque se consulta
 * desde el primer constructor estatico, antes de que exista nada mas. */
int nx_diagnostico(void);
int nx_diagnostico(void)
{
    static int decidido = -1;
    if (decidido < 0) {
        int fd = open("sdmc:/switch/pokemon-anil/diagnostico.txt", O_RDONLY);
        decidido = (fd >= 0) ? 1 : 0;
        if (fd >= 0) close(fd);
    }
    return decidido;
}

static void nx_boot_mark(const char *msg)
{
    static const char *paths[3] = { NX_BOOTLOG_A, NX_BOOTLOG_B, NX_BOOTLOG_C };
    char sello[16];
    char nl = 0x0A;
    unsigned ms, i, n = 0;

    if (!base_tick)
        base_tick = armGetSystemTick();
    ms = (unsigned)(armTicksToNs(armGetSystemTick() - base_tick) / 1000000);

    {
        char t[12];
        int k = 0;
        if (!ms) t[k++] = '0';
        while (ms) { t[k++] = (char)('0' + ms % 10); ms /= 10; }
        while (k < 6) t[k++] = ' ';          /* a la derecha, hasta 6 huecos */
        sello[n++] = '[';
        while (k) sello[n++] = t[--k];
        sello[n++] = ']';
        sello[n++] = ' ';
    }

    /* Abrir, escribir y cerrar por cada linea costaba unos 40 ms en la SD:
     * las sesenta lineas del arranque eran mas de dos segundos de espera antes
     * de que el juego hiciera nada. En produccion el descriptor se abre una
     * vez y se queda; la ultima linea puede perderse si el proceso muere, pero
     * para eso esta el informe de fallo de Atmosphere. Con diagnostico.txt se
     * vuelve al modo lento y seguro, que es el que quiere quien depura. */
    static int fd_abierto = -1;
    if (fd_abierto >= 0 && !nx_diagnostico()) {
        write(fd_abierto, sello, n);
        write(fd_abierto, msg, strlen(msg));
        write(fd_abierto, &nl, 1);
        return;
    }
    for (i = 0; i < 3; i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd < 0)
            continue;
        write(fd, sello, n);
        write(fd, msg, strlen(msg));
        write(fd, &nl, 1);
        if (nx_diagnostico())
            close(fd);
        else
            fd_abierto = fd;
        return;                 /* con que llegue a uno, basta */
    }
}

void nx_boot_trace(const char *msg);
void nx_boot_trace(const char *msg) { nx_boot_mark(msg); }

/* NX_BUILD lo genera el Makefile en cada compilacion. Existe porque el 1 de
 * septiembre de 2026, despues de tres despliegues por FTP seguidos, no habia
 * forma de saber si la consola estaba arrancando el binario nuevo o el de hace
 * media hora: los registros se parecian demasiado. Un numero que sube solo, en
 * la primera linea del registro y en la version que ensena hbmenu, cierra esa
 * duda antes de que empiece a contaminar las medidas. */
#ifndef NX_BUILD
#define NX_BUILD "sin sellar"
#endif

const char *nx_build(void);
const char *nx_build(void) { return NX_BUILD; }

__attribute__((constructor(101)))
static void nx_boot_early(void)
{
    nx_boot_mark("[build] " NX_BUILD);
    nx_boot_mark("[boot] 1/3 primer constructor estatico — heap y __appInit sobrevividos");
}

__attribute__((constructor(65534)))
static void nx_boot_late(void)
{
    nx_boot_mark("[boot] 2/3 ultimo constructor estatico — los 45 pasaron");
}

/* Diagnostico del sistema de ficheros.
 *
 * require() de Ruby no encuentra ficheros que IO.sysopen SI abre. La diferencia
 * esta en rb_file_load_ok, que tras abrir llama a ruby_is_fd_loadable ->
 * fstat(fd) y exige S_ISREG. Aqui se compara stat() sobre la ruta con fstat()
 * sobre el descriptor: si el segundo no dice "fichero regular", ese es el motivo.
 */
void nx_probe_fs(const char *path)
{
    char buf[256];
    struct stat sp, sf;
    int fd, rp, rf, gfd, gfl;

    rp = stat(path, &sp);
    fd = open(path, O_RDONLY);
    rf = (fd >= 0) ? fstat(fd, &sf) : -1;
    gfd = (fd >= 0) ? fcntl(fd, F_GETFD) : -1;
    gfl = (fd >= 0) ? fcntl(fd, F_GETFL) : -1;

    snprintf(buf, sizeof(buf),
             "[fs] %s: stat=%d modo=%o | fd=%d fstat=%d modo=%o esReg=%d tam=%ld"
             " | F_GETFD=%d F_GETFL=%d errno=%d",
             path, rp, (rp == 0) ? (unsigned)sp.st_mode : 0u,
             fd, rf, (rf == 0) ? (unsigned)sf.st_mode : 0u,
             (rf == 0) ? (S_ISREG(sf.st_mode) ? 1 : 0) : -1,
             (rf == 0) ? (long)sf.st_size : -1L,
             gfd, gfl, errno);
    nx_boot_mark(buf);
    if (fd >= 0) close(fd);
}
