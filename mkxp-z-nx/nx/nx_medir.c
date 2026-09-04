/*
 * nx_medir.c — cuanto sitio hay, cuanto ocupa de verdad un fichero y cuanto
 * cuesta escribir. Las tres preguntas que decidian si desempaquetar el
 * contenedor en la consola era buena idea o una tonteria cara.
 *
 * El contenedor son 654 MB en UN fichero; el juego suelto son 651 MB en 22.035.
 * Parece lo mismo y no lo es, porque un fichero no ocupa lo que mide: ocupa
 * clusters enteros. Con cluster de 4 KB el desperdicio son 49 MB y da igual; con
 * cluster de 128 KB —lo normal en una tarjeta grande con exFAT— son 2,4 GB y ya
 * no da igual en absoluto. Ese numero no se puede suponer: depende de como este
 * formateada la tarjeta de cada uno.
 *
 * COMO SE MIDE EL CLUSTER. No hay API que lo diga —libnx no trae statvfs y
 * fsFsGetFreeSpace solo da bytes—, asi que se pregunta a la tarjeta de la unica
 * forma honesta: se mira el espacio libre, se crea un fichero de UN byte, y se
 * vuelve a mirar. Lo que baja es lo que ocupa un fichero minimo. Nada de
 * deducirlo del tamano de la tarjeta, que es donde se equivoca todo el mundo.
 *
 * COMO SE MIDE LA ESCRITURA. Unos pocos megas en ficheros del tamano medio de un
 * asset del juego (30 KB), cronometrando aparte lo que cuesta CREAR y lo que
 * cuesta escribir: con 22.035 ficheros por delante, la cuenta que manda es la de
 * las creaciones, igual que en §5.48 mandaba la de los stat.
 *
 * Se activa poniendo un fichero vacio `medir.txt` en la carpeta del juego, y no
 * con diagnostico.txt: aquello enciende ademas el registro lento y todas las
 * autopruebas, y aqui interesa medir la tarjeta, no el arranque.
 */

#include <switch.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

void nx_boot_trace(const char *msg);
void nx_medir_tarjeta(void);

#define NX_MUESTRA   64          /* ficheros de prueba */
#define NX_TAM       (30 * 1024) /* 651 MB / 22.035 ficheros = 30 KB de media */
#define NX_CARPETA   "sdmc:/switch/pokemon-anil/nx-medida"

static u64 libre(void)
{
    FsFileSystem *fs = fsdevGetDeviceFileSystem("sdmc");
    s64 n = 0;

    if (!fs || R_FAILED(fsFsGetFreeSpace(fs, "/", &n)))
        return 0;
    return (u64)n;
}

static u64 ms_desde(u64 t0)
{
    return armTicksToNs(armGetSystemTick() - t0) / 1000000;
}

void nx_medir_tarjeta(void)
{
    char linea[224], ruta[128];
    static char relleno[NX_TAM];
    u64 antes, despues, cluster = 0;
    u64 t0, ms_crear = 0, ms_escribir = 0, ms_cerrar = 0;
    int i, fd;

    {
        int marca = open("medir.txt", O_RDONLY);
        if (marca < 0)
            return;
        close(marca);
    }

    /* 1. Cuanto hay. */
    {
        FsFileSystem *fs = fsdevGetDeviceFileSystem("sdmc");
        s64 total = 0;
        if (fs)
            fsFsGetTotalSpace(fs, "/", &total);
        antes = libre();
        snprintf(linea, sizeof(linea), "[medida] tarjeta: %llu MB libres de %llu MB",
                 (unsigned long long)(antes / (1024 * 1024)),
                 (unsigned long long)((u64)total / (1024 * 1024)));
        nx_boot_trace(linea);
    }

    mkdir(NX_CARPETA, 0777);

    /* 2. Cuanto ocupa un fichero de un byte: eso es el cluster. */
    fd = open(NX_CARPETA "/uno", O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd >= 0) {
        write(fd, "x", 1);
        close(fd);
        despues = libre();
        cluster = (antes > despues) ? (antes - despues) : 0;
        snprintf(linea, sizeof(linea),
                 "[medida] un fichero de 1 byte ocupa %llu KB -> ese es el cluster",
                 (unsigned long long)(cluster / 1024));
        nx_boot_trace(linea);
    }

    /* 3. Que cuesta escribir. Crear, escribir y cerrar por separado, porque con
     *    22.035 ficheros por delante lo que manda no es el caudal. */
    memset(relleno, 'a', sizeof(relleno));
    for (i = 0; i < NX_MUESTRA; i++) {
        snprintf(ruta, sizeof(ruta), NX_CARPETA "/f%03d", i);

        t0 = armGetSystemTick();
        fd = open(ruta, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        ms_crear += ms_desde(t0);
        if (fd < 0)
            continue;

        t0 = armGetSystemTick();
        write(fd, relleno, sizeof(relleno));
        ms_escribir += ms_desde(t0);

        t0 = armGetSystemTick();
        close(fd);
        ms_cerrar += ms_desde(t0);
    }

    snprintf(linea, sizeof(linea),
             "[medida] %d ficheros de %d KB: crear %llu ms, escribir %llu ms, cerrar %llu ms",
             NX_MUESTRA, NX_TAM / 1024,
             (unsigned long long)ms_crear, (unsigned long long)ms_escribir,
             (unsigned long long)ms_cerrar);
    nx_boot_trace(linea);

    /* 4. La cuenta que interesa, hecha aqui para que este en el registro y no en
     *    la cabeza de nadie: lo que costaria desempaquetar el juego entero. */
    {
        u64 por_fichero = (ms_crear + ms_cerrar) / (NX_MUESTRA ? NX_MUESTRA : 1);
        u64 mb_por_s = ms_escribir ? ((u64)NX_MUESTRA * NX_TAM / 1024) * 1000
                                     / (ms_escribir * 1024) : 0;
        u64 seg_ficheros = por_fichero * 22035 / 1000;
        u64 seg_datos = mb_por_s ? 651 / mb_por_s : 0;

        snprintf(linea, sizeof(linea),
                 "[medida] extrapolado a 22.035 ficheros y 651 MB: %llu s de ficheros"
                 " + %llu s de datos = %llu min | ocuparia %llu MB",
                 (unsigned long long)seg_ficheros, (unsigned long long)seg_datos,
                 (unsigned long long)((seg_ficheros + seg_datos + 59) / 60),
                 (unsigned long long)(cluster ? (22035 * (cluster / 2) + 651ull * 1024 * 1024)
                                                / (1024 * 1024)
                                              : 0));
        nx_boot_trace(linea);
    }

    /* 5. Y se recoge: la medida no puede dejar basura en la tarjeta de nadie. */
    for (i = 0; i < NX_MUESTRA; i++) {
        snprintf(ruta, sizeof(ruta), NX_CARPETA "/f%03d", i);
        unlink(ruta);
    }
    unlink(NX_CARPETA "/uno");
    rmdir(NX_CARPETA);
    nx_boot_trace("[medida] hecho; borra medir.txt para no repetirlo");
}
