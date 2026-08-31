/*
 * nx_fsprobe.c — cuanto cuesta de verdad recorrer la tarjeta SD.
 *
 * createPathCache tarda 56 s sobre 22.318 entradas, y la instrumentacion de
 * filesystem.cpp reparte asi la culpa:
 *
 *     35.406 ms en PHYSFS_stat      (1,59 ms por entrada)
 *     20.520 ms en PHYSFS_enumerate (0,92 ms por entrada)
 *        139 ms en el trabajo real  (minusculas y tablas hash)
 *
 * Es todo sistema de ficheros. La pregunta que decide como arreglarlo es si la
 * lentitud es de Horizon o de PhysFS, y solo hay una manera de saberlo: recorrer
 * el mismo arbol a mano, con opendir/readdir, y cronometrarlo.
 *
 * De paso se comprueba algo que puede ahorrar la mitad del trabajo: el
 * `d_type` de readdir. La newlib de devkitPro declara _DIRENT_HAVE_D_TYPE, y si
 * libnx lo rellena de verdad, distinguir fichero de directorio no cuesta ni una
 * llamada extra —que es exactamente lo que PhysFS esta pagando con su stat—.
 *
 * La sonda no se ejecuta salvo que exista el fichero "nx-medir-fs" en la
 * carpeta del juego: son otros 20 s de arranque y no se pagan sin querer.
 */
#include <switch.h>
#include <dirent.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>

void nx_boot_trace(const char *msg);

#define CARPETA "sdmc:/switch/pokemon-anil"
#define TESTIGO CARPETA "/nx-medir-fs"

static unsigned n_entradas, n_dirs, n_desacuerdos, n_desconocidos;
static u64 t_stat;

/* ruta[] se reutiliza en toda la recursion: reservar 512 bytes por nivel en la
 * pila de un hilo de 1 MiB no acaba bien. */
static void recorrer(char *ruta, size_t largo, int con_stat)
{
    DIR *d = opendir(ruta);
    struct dirent *e;

    if (!d)
        return;

    while ((e = readdir(d)) != NULL) {
        size_t n;
        int es_dir_tipo, es_dir;

        if (e->d_name[0] == '.' &&
            (e->d_name[1] == 0 || (e->d_name[1] == '.' && e->d_name[2] == 0)))
            continue;

        n = strlen(e->d_name);
        if (largo + 1 + n + 1 > 512)
            continue;
        ruta[largo] = '/';
        memcpy(ruta + largo + 1, e->d_name, n + 1);

        n_entradas++;
        es_dir_tipo = (e->d_type == DT_DIR);
        if (e->d_type == DT_UNKNOWN)
            n_desconocidos++;

        es_dir = es_dir_tipo;
        if (con_stat) {
            struct stat st;
            u64 t0 = armGetSystemTick();
            int r = stat(ruta, &st);
            t_stat += armGetSystemTick() - t0;
            if (r == 0) {
                es_dir = S_ISDIR(st.st_mode) ? 1 : 0;
                if (es_dir != es_dir_tipo)
                    n_desacuerdos++;
            }
        }

        if (es_dir) {
            n_dirs++;
            recorrer(ruta, largo + 1 + n, con_stat);
        }
    }
    closedir(d);
}

static void medir(int con_stat, const char *etiqueta)
{
    static char ruta[512];
    char linea[192];
    u64 t0, ms;

    n_entradas = n_dirs = n_desacuerdos = n_desconocidos = 0;
    t_stat = 0;
    strcpy(ruta, CARPETA);

    t0 = armGetSystemTick();
    recorrer(ruta, strlen(CARPETA), con_stat);
    ms = armTicksToNs(armGetSystemTick() - t0) / 1000000;

    snprintf(linea, sizeof(linea),
             "[fs] %s: %u entradas, %u dirs | %llu ms | stat %llu ms"
             " | d_type desconocido %u | desacuerdos %u",
             etiqueta, n_entradas, n_dirs, (unsigned long long)ms,
             (unsigned long long)(armTicksToNs(t_stat) / 1000000),
             n_desconocidos, n_desacuerdos);
    nx_boot_trace(linea);
}

__attribute__((constructor(104)))
static void nx_medir_fs(void)
{
    struct stat st;

    if (stat(TESTIGO, &st) != 0)
        return;

    nx_boot_trace("[fs] testigo nx-medir-fs presente: midiendo el recorrido");
    medir(0, "solo readdir");
    medir(1, "readdir + stat");
}
