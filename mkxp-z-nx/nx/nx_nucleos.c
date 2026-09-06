/*
 * nx_nucleos.c — repartir los hilos entre los nucleos que hay.
 *
 * La Switch tiene cuatro A57 y le presta tres a las aplicaciones; el cuarto se
 * lo queda el sistema. Pero el NPDM declara "default_cpu_id": 0, y en libnx
 * crear un hilo con cpuid = -2 significa "el nucleo por defecto del proceso".
 * SDL_CreateThread —por donde pasan TODOS los hilos de mkxp-z: el de RGSS, el
 * de la musica, los de los fundidos— no pide ninguno en concreto.
 *
 * La consecuencia, si nadie lo remedia, es que los tres nucleos se usan como
 * uno. En el emulador no se nota porque el anfitrion tiene de sobra. En la
 * consola se nota en dos sitios a la vez:
 *
 *   - Los tirones. El hilo de RGSS descomprime un PNG y lee de la SD; mientras
 *     tanto no hay quien mueva nada mas, porque no hay donde.
 *   - La musica. El hilo que rellena los bufers de OpenAL no llega a tiempo,
 *     el sonido se queda sin datos y hay que volver a arrancarlo.
 *
 * Aqui se hacen dos cosas y en este orden, que importa: primero se ANOTA como
 * estaba —para que quede la prueba de que era eso y no otra cosa— y luego se
 * ensancha la mascara a los tres nucleos.
 *
 * Ensanchar la mascara no es lo mismo que fijar un nucleo. Horizon planifica
 * por prioridad sobre el nucleo preferido y deja que otro nucleo de la mascara
 * recoja el hilo cuando el preferido esta ocupado. Poner la mascara al maximo
 * es darle permiso al planificador para repartir; fijar a mano seria decidir
 * por el con menos informacion de la que tiene.
 *
 * La excepcion es la musica, que si pide nucleo preferido propio: no compite
 * por gusto con quien esta descomprimiendo texturas.
 */
#include <switch.h>
#include <stdio.h>
#include <string.h>

void nx_boot_trace(const char *msg);

void nx_nucleo(const char *quien, int preferido);

/* Nucleos 0, 1 y 2. El 3 es del sistema y pedirlo da error. */
#define NX_TODOS 0x7

/* Cuantas veces se anota lo mismo antes de callarse.
 *
 * "principal" y "rgss" llaman aqui una vez cada uno, desde su arranque. La
 * musica no: el hilo que rellena los bufers de OpenAL NACE Y MUERE con cada
 * pista, asi que nx_nucleo("musica", 2) corre otra vez en cada cambio de
 * cancion. En los registros de dos jugadores reales son hasta 20 lineas
 * identicas en una sola sesion y 133 en el fichero entero —mas que todas las
 * del arranque juntas—, y cada una es una write() a la tarjeta SD hecha justo
 * cuando empieza a sonar algo.
 *
 * La informacion que aportan es una: que el reparto se hizo y salio bien. Eso
 * se ve en la primera. Las demas son el precio de no haber puesto un tope,
 * que es el mismo que ya lleva nx_traza_me() para las fanfarrias (§5.57) y por
 * el mismo motivo: esta consola escribe el registro sobre la misma tarjeta que
 * estamos midiendo.
 *
 * Tres y no una, porque si alguna vez FALLA interesa verlo aunque las primeras
 * salieran bien; y el tope es por nombre, no global, para que la musica no
 * consuma el cupo de nadie mas. */
#define NX_NUCLEO_MAX   3
#define NX_NUCLEO_NOMS  4

static int nx_nucleo_calla(const char *quien)
{
    static const char *nombre[NX_NUCLEO_NOMS];
    static unsigned veces[NX_NUCLEO_NOMS];
    unsigned i;

    for (i = 0; i < NX_NUCLEO_NOMS; i++) {
        if (!nombre[i]) {
            nombre[i] = quien;
            veces[i] = 1;
            return 0;
        }
        if (strcmp(nombre[i], quien) == 0) {
            if (veces[i] >= NX_NUCLEO_MAX)
                return 1;
            veces[i]++;
            return 0;
        }
    }
    return 0;                   /* mas nombres de los previstos: no callar */
}

void nx_nucleo(const char *quien, int preferido)
{
    char linea[224];
    s32 pref = -1;
    u64 mascara = 0;
    u32 corriendo = svcGetCurrentProcessorNumber();
    Result r = svcGetThreadCoreMask(&pref, &mascara, CUR_THREAD_HANDLE);

    if (R_FAILED(r)) {
        snprintf(linea, sizeof(linea),
                 "[nucleo] %s: no se pudo consultar (0x%x)", quien, (unsigned)r);
        nx_boot_trace(linea);
        return;
    }

    {
        s32 nuevo = (preferido >= 0) ? (s32)preferido : pref;
        Result r2 = svcSetThreadCoreMask(CUR_THREAD_HANDLE, nuevo, NX_TODOS);

        /* El reparto se hace SIEMPRE; lo que se calla es contarlo. Un hilo de
         * musica que naciera sin su nucleo preferido por ahorrarse una linea
         * de registro seria cambiar un cromo por una vaca. */
        if (R_SUCCEEDED(r2) && nx_nucleo_calla(quien))
            return;

        snprintf(linea, sizeof(linea),
                 "[nucleo] %s: corria en %u | preferido %d mascara 0x%llx"
                 " -> preferido %d mascara 0x%x (%s)",
                 quien, (unsigned)corriendo, (int)pref,
                 (unsigned long long)mascara, (int)nuevo, NX_TODOS,
                 R_SUCCEEDED(r2) ? "OK" : "fallo");
        nx_boot_trace(linea);
    }
}

/* El hilo principal se apunta solo. Los otros dos llaman a nx_nucleo() desde
 * su propia entrada, que es el unico sitio donde un hilo puede hablar de si
 * mismo: CUR_THREAD_HANDLE es siempre "el que pregunta". */
__attribute__((constructor(104)))
static void nx_nucleo_principal(void)
{
    nx_nucleo("principal", -1);
}
