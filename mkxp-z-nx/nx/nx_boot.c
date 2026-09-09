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

#include "nx_juego.h"

#define NX_BOOTLOG_NOMBRE "mkxp-boot.log"

/* Cuando el registro deja de caber en una lectura.
 *
 * El fichero se abre en O_APPEND y no se trunca nunca, asi que crece durante
 * toda la vida de la instalacion. En los registros de dos jugadores reales
 * eran 182 KB despues de diecinueve partidas —1.636 lineas— y ese ritmo no se
 * para solo. Lo que se pierde no es sitio en la tarjeta, que sobra: es la
 * posibilidad de leerlo. Un mkxp-boot.log de varios megas ya no se adjunta a
 * un informe ni se abre de un vistazo, y la sesion que interesa esta al final,
 * detras de todas las que no interesan.
 *
 * Se guarda UNA generacion, no cero: la caida que se quiere entender suele ser
 * la de la partida anterior, la que hizo al jugador cerrar y volver a abrir.
 * Truncar sin mas seria borrar justo esa. */
#define NX_LOG_MAX (1024u * 1024u)

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

/* Donde acaba este registro.
 *
 * Ya no es una constante. La carpeta del juego no se sabe hasta que main()
 * llama a nxSetupWorkdir, y para entonces los 45 constructores estaticos ya
 * han escrito sus lineas —que son justamente las que interesan cuando un
 * arranque no llega a main()—. Asi que hasta ese momento las lineas se guardan
 * en memoria, y cuando la carpeta aparece se vuelcan de golpe al fichero.
 *
 * Si la carpeta nunca aparece —no hay juego que valga y lo que se va a ver es
 * la pantalla de aviso—, main() llama a nx_carpeta_juego_rendirse() y lo
 * acumulado sale por NX_LOG_HUERFANO, que es el unico sitio de la tarjeta
 * donde se puede escribir sin saber nada. */
static char rutas[3][512];
static int  n_rutas;            /* 0 = destino todavia sin decidir */
static int  rendido;            /* nadie va a decir ya cual es la carpeta */

static int nx_boot_destino(void)
{
    const char *c;

    if (n_rutas)
        return 1;

    c = nx_carpeta_juego();
    if (c && *c) {
        snprintf(rutas[0], sizeof(rutas[0]), "%s/%s", c, NX_BOOTLOG_NOMBRE);
        snprintf(rutas[1], sizeof(rutas[1]), "%s", NX_BOOTLOG_NOMBRE);
        snprintf(rutas[2], sizeof(rutas[2]), "%s", NX_LOG_HUERFANO);
        n_rutas = 3;
        return 1;
    }
    if (rendido) {
        snprintf(rutas[0], sizeof(rutas[0]), "%s", NX_BOOTLOG_NOMBRE);
        snprintf(rutas[1], sizeof(rutas[1]), "%s", NX_LOG_HUERFANO);
        n_rutas = 2;
        return 1;
    }
    return 0;
}

/* Lo que se dijo antes de saber donde escribirlo.
 *
 * 32 KB dan para las ~200 lineas que salen antes de main() con el diagnostico
 * puesto, que es el caso peor. Si se llena, se da por perdida la espera: se
 * vuelca a donde se pueda y se sigue en directo, porque un registro que se
 * corta por el principio todavia sirve y uno que se corta por el final no. */
#define NX_PRE_BUF (32 * 1024)

static char   prebuf[NX_PRE_BUF];
static size_t prebuf_n;

/* Aparta el registro de la instalacion anterior si ya no se puede leer.
 *
 * Se hace una sola vez por proceso y ANTES de abrir el descriptor de escritura,
 * porque renombrar un fichero que tenemos abierto en O_APPEND deja el
 * descriptor apuntando a un sitio que ya no se llama asi. Si el renombrado
 * falla —la tarjeta esta protegida, el destino existe y no se deja borrar— no
 * pasa nada: se sigue escribiendo en el fichero grande, que es peor que
 * rotarlo pero mucho mejor que quedarse sin registro. */
static void nx_boot_rota(void)
{
    unsigned i;

    for (i = 0; i < (unsigned)n_rutas; i++) {
        struct stat st;
        char viejo[520];
        size_t l;

        if (stat(rutas[i], &st) != 0)
            continue;
        if ((unsigned)st.st_size < NX_LOG_MAX)
            return;             /* el que vamos a usar cabe: nada que hacer */

        /* ".log" -> ".1.log", para que el visor lo siga reconociendo. */
        l = strlen(rutas[i]);
        if (l < 5 || l + 3 >= sizeof(viejo))
            return;
        memcpy(viejo, rutas[i], l - 4);
        memcpy(viejo + l - 4, ".1.log", 7);

        unlink(viejo);
        rename(rutas[i], viejo);
        return;
    }
}

/* Una linea, una llamada a write().
 *
 * El sello, el mensaje y el salto de linea se escribian en tres write()
 * seguidas sobre un descriptor compartido, y por ese descriptor escriben a la
 * vez el hilo de dibujo (los [tiron] y los [mem]), el de la musica (los
 * [nucleo]) y el principal. Entre dos de esas tres llamadas cabe otro hilo
 * entero, y en los registros de los dos jugadores hay 41 lineas asi: un
 * "[nucleo] musica: ... (OK)" con un "[tiron] marco ..." incrustado detras sin
 * salto de linea, y a continuacion una linea vacia con el salto huerfano. No
 * se pierde informacion —los bytes estan todos— pero se pierde el poder
 * leerlos con una herramienta, que para un registro es casi lo mismo:
 * resolver-pila.py y triaje.py van linea a linea.
 *
 * Se arregla por los dos lados a la vez, porque ninguno basta solo. El candado
 * ordena a los escritores entre si; armar la linea entera en un buffer y
 * soltarla de una write() hace que, aunque el candado no estuviera, lo peor
 * que pueda pasar sea que dos lineas salgan en otro orden y no que salgan
 * trenzadas. Es un Mutex de libnx, que en .bss vale cero y cero es
 * "desbloqueado": vale desde el primer constructor estatico, que es antes de
 * que exista nada a lo que llamar para inicializarlo. */
static Mutex nx_log_mtx;

static void nx_boot_mark(const char *msg)
{
    static int fd_abierto = -1;
    static int rotado;
    char linea[512];
    unsigned ms, i, n = 0;
    size_t largo;

    mutexLock(&nx_log_mtx);

    if (!base_tick)
        base_tick = armGetSystemTick();
    ms = (unsigned)(armTicksToNs(armGetSystemTick() - base_tick) / 1000000);

    {
        char t[12];
        int k = 0;
        if (!ms) t[k++] = '0';
        while (ms) { t[k++] = (char)('0' + ms % 10); ms /= 10; }
        while (k < 6) t[k++] = ' ';          /* a la derecha, hasta 6 huecos */
        linea[n++] = '[';
        while (k) linea[n++] = t[--k];
        linea[n++] = ']';
        linea[n++] = ' ';
    }

    /* El mensaje mas largo que se escribe es un [tiron], que nace de un
     * snprintf de 448; con el sello y el salto cabe de sobra. Se recorta por si
     * algun dia deja de caber: mejor una linea corta que una pila pisada. */
    largo = strlen(msg);
    if (largo > sizeof(linea) - n - 1)
        largo = sizeof(linea) - n - 1;
    memcpy(linea + n, msg, largo);
    n += (unsigned)largo;
    linea[n++] = 0x0A;

    /* Abrir, escribir y cerrar por cada linea costaba unos 40 ms en la SD:
     * las sesenta lineas del arranque eran mas de dos segundos de espera antes
     * de que el juego hiciera nada. En produccion el descriptor se abre una
     * vez y se queda; la ultima linea puede perderse si el proceso muere, pero
     * para eso esta el informe de fallo de Atmosphere. Con diagnostico.txt se
     * vuelve al modo lento y seguro, que es el que quiere quien depura. */
    if (fd_abierto >= 0 && !nx_diagnostico()) {
        write(fd_abierto, linea, n);
        mutexUnlock(&nx_log_mtx);
        return;
    }

    /* Todavia no se sabe donde: a memoria. */
    if (!nx_boot_destino()) {
        if (prebuf_n + n <= sizeof(prebuf)) {
            memcpy(prebuf + prebuf_n, linea, n);
            prebuf_n += n;
            mutexUnlock(&nx_log_mtx);
            return;
        }
        rendido = 1;            /* el buffer se lleno: hay que soltarlo ya */
        nx_boot_destino();
    }

    if (!rotado) {
        rotado = 1;
        nx_boot_rota();
    }

    for (i = 0; i < (unsigned)n_rutas; i++) {
        int fd = open(rutas[i], O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd < 0)
            continue;
        /* Lo acumulado va delante, y en una sola write(): son las lineas de
         * los constructores estaticos y tienen que salir en su orden. */
        if (prebuf_n) {
            write(fd, prebuf, prebuf_n);
            prebuf_n = 0;
        }
        write(fd, linea, n);
        if (nx_diagnostico())
            close(fd);
        else
            fd_abierto = fd;
        break;                  /* con que llegue a uno, basta */
    }

    mutexUnlock(&nx_log_mtx);
}

/* Las llama nx_juego.c cuando la carpeta se sabe, o cuando ya se sabe que no
 * va a saberse. Lo unico que hacen es forzar que la proxima linea decida
 * destino y arrastre consigo todo lo acumulado; escribir una linea es la
 * manera mas simple de hacerlo y ademas deja constancia. */
void nx_boot_vuelca(void);
void nx_boot_vuelca(void)
{
    nx_boot_mark("[boot] 0 registro volcado desde memoria a la carpeta del juego");
}

void nx_boot_rendirse(void);
void nx_boot_rendirse(void)
{
    mutexLock(&nx_log_mtx);
    rendido = 1;
    mutexUnlock(&nx_log_mtx);
    nx_boot_mark("[boot] 0 sin carpeta de juego: el registro se queda huerfano");
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
