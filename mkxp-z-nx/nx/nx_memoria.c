/*
 * nx_memoria.c — cuanta memoria nos ha dado Horizon, y cuanta gastamos.
 *
 * Son dos preguntas distintas y hasta ahora solo se contestaba la primera.
 *
 * EL TECHO. El mismo binario recibe presupuestos muy distintos segun como se
 * lance:
 *
 *   - Menu homebrew abierto desde el album: corre como APPLET de biblioteca,
 *     y un applet comparte memoria con el juego suspendido que hay detras.
 *     En una consola de verdad son ~448 MB.
 *   - Menu homebrew con suplantacion de titulo (mantener R al abrir un juego):
 *     hereda el presupuesto de una aplicacion, ~3,2 GB.
 *   - Instalado como NSP: es una aplicacion, con su presupuesto entero.
 *
 * Ryujinx no modela esa diferencia: conteste lo que conteste appletGetAppletType,
 * reparte los 3,2 GB. Asi que el techo NO se puede medir aqui —hay que ir a la
 * consola— pero si se puede anotar cual de los tres casos cree el sistema que
 * es, que es la mitad del diagnostico y la que explica un cuelgue.
 *
 * EL SUELO. Cuanto gasta el juego de verdad. Esto SI se mide en el emulador, y
 * es el numero que decide si los 448 MB del applet dan o no dan. No vale
 * UsedMemorySize: libnx mapea el monton entero en __libnx_initheap, asi que el
 * sistema informa de 3.282 MB usados desde el primer instante y seguiria
 * diciendo lo mismo con el juego cerrado. El unico que cuenta bytes repartidos
 * de verdad es mallinfo().uordblks.
 *
 * Cuenta lo que pasa por malloc, que en Horizon incluye los bufers de la GPU
 * —nvmap no reserva memoria propia, mapea la del proceso— y deja fuera las
 * pilas de los hilos, que libnx pide aparte. Es una cota inferior, pero es la
 * unica cota medible y va sobrada para la pregunta.
 */
#include <switch.h>
#include <malloc.h>
#include <stdio.h>

void nx_boot_trace(const char *msg);

void nx_memoria_latido(void);

/* libnx no expone el tamano del monton por API: lo unico publico es lo que
 * __libnx_initheap deja en los simbolos de newlib. Son los mismos que usa
 * sbrk(), asi que su diferencia es exactamente lo que malloc puede repartir. */
extern char *fake_heap_start;
extern char *fake_heap_end;

static const char *como_arranco(void)
{
    /* envIsNso separa el NRO del NSO; appletGetAppletType separa lo que de
     * verdad importa, que es el presupuesto. Un NRO puede correr con memoria
     * de aplicacion (suplantando un titulo) y por eso no basta con el primero. */
    if (!envIsNso()) {
        switch (appletGetAppletType()) {
        case AppletType_Application:
        case AppletType_SystemApplication:
            return "homebrew (NRO) con memoria de aplicacion";
        case AppletType_LibraryApplet:
            return "homebrew (NRO) como applet — MEMORIA REDUCIDA";
        default:
            return "homebrew (NRO), tipo de applet desconocido";
        }
    }
    return "aplicacion instalada (NSO)";
}

__attribute__((constructor(103)))
static void nx_traza_memoria(void)
{
    char linea[224];
    u64 total = 0, usado = 0;

    svcGetInfo(&total, InfoType_TotalMemorySize, CUR_PROCESS_HANDLE, 0);
    svcGetInfo(&usado, InfoType_UsedMemorySize,  CUR_PROCESS_HANDLE, 0);

    snprintf(linea, sizeof(linea),
             "[mem] %s | total %llu MB | usado %llu MB | monton %llu MB",
             como_arranco(),
             (unsigned long long)(total / (1024 * 1024)),
             (unsigned long long)(usado / (1024 * 1024)),
             (unsigned long long)((fake_heap_end - fake_heap_start) / (1024 * 1024)));
    nx_boot_trace(linea);
}

/* Marca de agua del monton.
 *
 * Se llama una vez por segundo desde el hilo de dibujo (el mismo latido que ya
 * usa nx_pantalla_cambio). Anotar cada muestra convertiria el registro en el
 * cuello de botella y ademas no dice nada: lo que interesa no es la serie, es
 * el maximo. Asi que solo se escribe cuando el pico sube un escalon entero, y
 * el registro queda con una linea por cada vez que el juego pide mas sitio.
 *
 * El escalon son 32 MB porque el reparto util es "cabe en 448 o no cabe", y a
 * esa escala 32 MB es resolucion de sobra. */
#define NX_ESCALON (32u * 1024 * 1024)

void nx_memoria_latido(void)
{
    static size_t pico;
    struct mallinfo mi = mallinfo();

    if (mi.uordblks < pico + NX_ESCALON)
        return;

    pico = mi.uordblks;
    {
        char linea[160];
        snprintf(linea, sizeof(linea),
                 "[mem] pico del monton %llu MB (libre en el monton %llu MB)",
                 (unsigned long long)(mi.uordblks / (1024 * 1024)),
                 (unsigned long long)(mi.fordblks / (1024 * 1024)));
        nx_boot_trace(linea);
    }
}
