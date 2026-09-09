/*
 * nx_juego.c — la carpeta del juego. Ver nx_juego.h para el porque.
 *
 * Todo lo de aqui son buffers estaticos y llamadas crudas: se consulta desde
 * el primer constructor estatico, cuando el monton todavia puede no estar en
 * condiciones y no hay nada inicializado a lo que llamar.
 */

#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

#include "nx_juego.h"

/* nx/nx_boot.c: el registro de arranque, que es quien tiene lineas guardadas
 * esperando a saber donde escribirlas. */
void nx_boot_trace(const char *msg);
void nx_boot_vuelca(void);
void nx_boot_rendirse(void);
/* nx/nx_debug.c no existe: el volcado de mkxp-debug.log vive aqui abajo. */
void nx_debug_vuelca(void);

/* -------------------------------------------------------------- la carpeta */

static char carpeta[512];
static int  hay_carpeta;

const char *nx_carpeta_juego(void)
{
    return hay_carpeta ? carpeta : 0;
}

void nx_carpeta_juego_fija(const char *ruta)
{
    size_t n;
    char linea[600];

    if (!ruta || !*ruta || hay_carpeta)
        return;

    snprintf(carpeta, sizeof(carpeta), "%s", ruta);
    /* Sin barra final: quien la use la pone, y "sdmc:/switch/x//mkxp-boot.log"
     * abre igual pero sale feo en cada linea del registro. */
    n = strlen(carpeta);
    while (n > 1 && (carpeta[n - 1] == '/' || carpeta[n - 1] == '\\'))
        carpeta[--n] = 0;
    hay_carpeta = 1;

    /* Este es el momento en que los dos registros dejan de estar en memoria y
     * pasan a un fichero. El orden importa poco, pero la linea si: es la unica
     * prueba de que la carpeta elegida es la que se pretendia. */
    snprintf(linea, sizeof(linea), "[juego] carpeta: %s", carpeta);
    nx_boot_vuelca();
    nx_boot_trace(linea);
    nx_debug_vuelca();
}

static void nx_debug_rendirse(void);

void nx_carpeta_juego_rendirse(void)
{
    nx_boot_rendirse();
    nx_debug_rendirse();
}

char *nx_ruta_juego(char *buf, size_t tam, const char *nombre)
{
    if (!hay_carpeta)
        return 0;
    snprintf(buf, tam, "%s/%s", carpeta, nombre);
    return buf;
}

/* --------------------------------------------------------------- el titulo */

static char titulo[128];

void nx_titulo_juego_fija(const char *t)
{
    if (t && *t)
        snprintf(titulo, sizeof(titulo), "%s", t);
}

/* El Title= de Game.ini.
 *
 * Se lee del directorio de trabajo, que para cuando esto se llama ya es la
 * carpeta del juego. Game.ini es un INI de RPG Maker XP: seccion [Game] y
 * lineas clave=valor en CRLF. No se usa el iniconfig del motor porque esto
 * corre antes de que exista SharedState y porque un titulo que no se puede
 * leer no es motivo para no ensenar la pantalla. */
static void lee_game_ini(void)
{
    FILE *f;
    char linea[256];
    char ruta[600];

    f = 0;
    if (nx_ruta_juego(ruta, sizeof(ruta), "Game.ini"))
        f = fopen(ruta, "rb");
    if (!f)
        f = fopen("Game.ini", "rb");
    if (!f)
        return;

    while (fgets(linea, sizeof(linea), f)) {
        char *v;
        size_t n;

        if (strncmp(linea, "Title=", 6) != 0 && strncmp(linea, "title=", 6) != 0)
            continue;
        v = linea + 6;
        n = strlen(v);
        while (n && (v[n - 1] == '\n' || v[n - 1] == '\r' || v[n - 1] == ' '))
            v[--n] = 0;
        if (n)
            snprintf(titulo, sizeof(titulo), "%s", v);
        break;
    }
    fclose(f);
}

const char *nx_titulo_juego(void)
{
    static int leido;

    if (!titulo[0] && !leido) {
        leido = 1;
        lee_game_ini();
    }
    return titulo[0] ? titulo : "rgss-switch";
}

/* ------------------------------------------------- lo que se probo y fallo */

#define NX_MAX_INTENTOS 4

static char intentos[NX_MAX_INTENTOS][160];
static int  n_intentos;

void nx_intento(const char *linea)
{
    if (!linea || !*linea || n_intentos >= NX_MAX_INTENTOS)
        return;
    snprintf(intentos[n_intentos], sizeof(intentos[0]), "%s", linea);
    n_intentos++;
}

int nx_intentos_n(void)
{
    return n_intentos;
}

const char *nx_intento_lee(int i)
{
    return (i >= 0 && i < n_intentos) ? intentos[i] : "";
}

/* ---------------------------------------------------------- el diagnostico */

static int existe_fichero(const char *ruta)
{
    int fd = open(ruta, O_RDONLY);
    if (fd < 0)
        return 0;
    close(fd);
    return 1;
}

int nx_diagnostico(void)
{
    static int decidido = -1;
    static int con_carpeta;

    /* El interruptor global se mira una vez y para siempre: se consulta desde
     * el primer constructor estatico y no puede costar una apertura de fichero
     * -40 ms en la tarjeta- por cada linea del registro. */
    if (decidido < 0)
        decidido = existe_fichero("sdmc:/switch/diagnostico.txt");

    /* El del juego se mira otra vez, la primera vez que hay carpeta. Solo
     * puede encender: si el global ya dijo que si, el de aqui no lo apaga. */
    if (!con_carpeta && nx_carpeta_juego()) {
        char ruta[600];
        con_carpeta = 1;
        if (nx_ruta_juego(ruta, sizeof(ruta), "diagnostico.txt")
            && existe_fichero(ruta))
            decidido = 1;
    }

    return decidido;
}

/* ------------------------------------------------- el registro de Debug() */

/* mkxp-debug.log, con el mismo problema que mkxp-boot.log: Debug() se usa
 * desde los constructores estaticos y desde el hilo RGSS, o sea antes y
 * despues de que se sepa donde escribir. Lo de antes se guarda aqui.
 *
 * 8 KB es el tamano de lo que Debug() dice antes de main() con todo yendo
 * bien; si se pasa -que en un arranque que falla puede pasar- se vuelca lo que
 * hay al registro huerfano y se sigue en directo, porque perder el final es
 * peor que perder el principio: el final es donde esta el fallo. */
#define NX_DEBUG_BUF (8 * 1024)

static char  dbuf[NX_DEBUG_BUF];
static size_t dbuf_n;
static int   dbuf_rendido;

static FILE *nx_debug_abre(void)
{
    char ruta[600];
    FILE *f;

    if (nx_ruta_juego(ruta, sizeof(ruta), "mkxp-debug.log")) {
        f = fopen(ruta, "a");
        if (f)
            return f;
    }
    if (!dbuf_rendido)
        return 0;
    f = fopen("mkxp-debug.log", "a");
    if (!f)
        f = fopen(NX_LOG_HUERFANO, "a");
    return f;
}

/* Ya no va a haber carpeta: lo acumulado se escribe donde se pueda. */
static void nx_debug_rendirse(void)
{
    dbuf_rendido = 1;
    nx_debug_vuelca();
}

void nx_debug_vuelca(void)
{
    FILE *f;

    if (!dbuf_n)
        return;
    f = nx_debug_abre();
    if (!f)
        return;
    fwrite(dbuf, 1, dbuf_n, f);
    fclose(f);
    dbuf_n = 0;
}

/* La escribe debugwriter.h en cada Debug(). Se abre y se cierra por linea a
 * proposito: asi el registro sobrevive a un cierre brusco, que es la clase de
 * cierre que interesa. */
void nx_debug_log(const char *s);
void nx_debug_log(const char *s)
{
    size_t n;
    FILE *f;

    if (!s)
        return;
    n = strlen(s);

    if (!nx_carpeta_juego() && !dbuf_rendido) {
        if (dbuf_n + n + 1 <= sizeof(dbuf)) {
            memcpy(dbuf + dbuf_n, s, n);
            dbuf_n += n;
            dbuf[dbuf_n++] = 0x0A;
            return;
        }
        dbuf_rendido = 1;       /* no cabe mas: a partir de aqui, en directo */
        nx_debug_vuelca();
    }

    f = nx_debug_abre();
    if (!f)
        return;
    fwrite(s, 1, n, f);
    fputc(0x0A, f);
    fclose(f);
}
