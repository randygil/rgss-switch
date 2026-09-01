/*
 * nx_reloj.c — a que velocidad va de verdad esta consola.
 *
 * Repartido el fotograma entre once embudos, el trozo que manda en los menus no
 * es ningun embudo: es "resto", 370 ms de 605 en un cambio de pestana. Durante
 * un tiempo dimos por hecho que "resto" era el interprete de Ruby, y de ahi
 * salio este fichero: si es CPU, mas reloj tiene que arreglarlo.
 *
 * No lo arreglo. El reloj subio a 1785 MHz de verdad —esta medido abajo, con
 * rc=0x0 y la relectura confirmandolo— y los fotogramas malos se quedaron
 * igual. Asi que "resto es Ruby" era una suposicion y ya no se sostiene. Lo que
 * queda en pie del fichero es la medida, que sigue valiendo: sin ella
 * seguiriamos creyendo que sys-clk estaba aplicando algo.
 *
 * Horizon corre las aplicaciones a 1020 MHz. Hay sys-clk instalado en esta
 * tarjeta, con perfiles por titulo a 1683 MHz para otros dos juegos, asi que
 * el margen existe. Pero "he puesto un perfil de overclock" no es una medida:
 * sys-clk puede no aplicarlo, puede aplicarlo solo en la base, o el titulo
 * puede no coincidir. Por eso el juego pregunta el reloj el mismo, y lo anota.
 *
 * Se consulta a clkrst, que es el servicio de firmware moderno. Solo se anota
 * cuando cambia: el reloj se mueve al entrar y salir de la base, y esas
 * transiciones son justo lo que interesa ver.
 */
#include <switch.h>
#include <stdio.h>
#include <stdlib.h>

void nx_boot_trace(const char *msg);
void nx_reloj(void);
void nx_reloj_forzar(void);
void nx_reloj_soltar(void);

static int arrancado;          /* 0 sin intentar, 1 listo, -1 no disponible */
static u32 cpu_previo, gpu_previo, emc_previo;

static u32 lee(PcvModuleId modulo)
{
    ClkrstSession s;
    u32 hz = 0;

    if (R_FAILED(clkrstOpenSession(&s, modulo, 3)))
        return 0;
    clkrstGetClockRate(&s, &hz);
    clkrstCloseSession(&s);
    return hz;
}

static int abre(void)
{
    if (arrancado == 0)
        arrancado = R_SUCCEEDED(clkrstInitialize()) ? 1 : -1;
    return arrancado == 1;
}

void nx_reloj(void)
{
    u32 cpu, gpu, emc;
    char linea[160];

    if (!abre())
        return;

    cpu = lee(PcvModuleId_CpuBus);
    gpu = lee(PcvModuleId_GPU);
    emc = lee(PcvModuleId_EMC);

    if (cpu == cpu_previo && gpu == gpu_previo && emc == emc_previo)
        return;
    cpu_previo = cpu;
    gpu_previo = gpu;
    emc_previo = emc;

    snprintf(linea, sizeof(linea),
             "[reloj] CPU %u MHz | GPU %u MHz | RAM %u MHz | %s",
             (unsigned)(cpu / 1000000), (unsigned)(gpu / 1000000),
             (unsigned)(emc / 1000000),
             appletGetOperationMode() == AppletOperationMode_Handheld
                 ? "portatil" : "sobremesa");
    nx_boot_trace(linea);
}

/* --------------------------------------------------------------------------
 * Y ahora la parte que actua, no solo la que mira.
 *
 * La lectura de arriba contesto la pregunta que dejaba abierta el reparto del
 * fotograma. Un cambio de pestana en la vista de Pokemon son 676 ms, de los
 * cuales 333 son "resto", o sea el interprete de Ruby. Y el registro dice
 * "CPU 1020 MHz": el reloj de fabrica en portatil. Hay sys-clk instalado en
 * esta tarjeta, pero sus perfiles van por identificador de titulo y el juego
 * arranca como homebrew sobre el titulo de otro, asi que el perfil no le toca
 * nunca. Esperar a que sys-clk lo aplique es esperar sentado.
 *
 * Se puede pedir el reloj sin intermediarios. clkrst es el mismo servicio que
 * ya abrimos para leer, y la sesion sirve para las dos cosas: si GetClockRate
 * funciona, SetClockRate funciona.
 *
 * 1785 MHz no es un overclock inventado. Es el reloj de "boost" que usa el
 * propio firmware para acortar las pantallas de carga, esta en la tabla de
 * frecuencias de Horizon y el sistema sigue vigilando la temperatura por
 * encima de el. 1600 MHz de memoria es el reloj que la consola usa puesta en
 * la base. Sostener CPU 1785 + GPU 307 en portatil consume menos que el
 * GPU 460 de la base, que es para lo que esta dimensionado el ventilador; lo
 * que si cuesta es bateria.
 *
 * La GPU se dejaba en paz a proposito, porque gasta 10 ms de los 676 del
 * fotograma malo. Visto lo de abajo, esa decision resulto ser justo la que
 * hacia dano: al subir CPU y memoria el gestor de energia le quito potencia.
 *
 * Se reaplica una vez por segundo porque no somos los unicos que tocan esto:
 * el gestor de energia rebaja el reloj al entrar y salir de la base y al
 * cambiar de modo de rendimiento. Y no se anuncia el resultado a partir de lo
 * que hemos pedido, sino releyendo: la linea [reloj] de despues dice el reloj
 * de verdad, y si dijera 1020 sabriamos que esto no ha servido de nada.
 */
#define NX_CPU_TURBO   1785000000u   /* boost oficial de Horizon */
#define NX_EMC_TURBO   1600000000u   /* memoria al reloj de la base */
#define NX_CPU_FABRICA 1020000000u
#define NX_EMC_FABRICA 1331200000u

/* Encendido por defecto, despues de haberlo apagado y tener que rectificar.
 *
 * Se apago porque al subir CPU y RAM la GPU, clavada en 307 MHz, se puso a
 * bailar entre 115 y 230: hay un presupuesto de potencia repartido y se lo
 * estabamos quitando. Eso sigue siendo verdad. Lo que estaba mal era la otra
 * mitad del razonamiento —"y a cambio no compra nada"—, que salio de comparar
 * fotogramas de binarios distintos medidos a relojes distintos.
 *
 * Con la sonda de tiempo de CPU puesta, un fotograma de la lista de objetos
 * dice "marco 732 ms | cpu 455 ms": el hilo esta quemando CPU de verdad mas de
 * la mitad del fotograma. Y lo hace a 612 MHz, porque sin turbo la consola se
 * planta ahi, que es la MITAD del reloj de fabrica. Esos 455 ms a 1785 MHz son
 * unos 156. El trabajo de GPU del mismo fotograma son unos 60 ms; aunque
 * bajarle el reloj lo doblara, sale ganando de largo.
 *
 * Hay una segunda razon, y a la larga pesa mas: sin fijar el reloj no se puede
 * comparar nada. Las medidas de esta tarde se tomaron a 612, 918, 1224, 1326,
 * 1428 y 1785 MHz segun le apetecia al gestor de energia, y con eso ninguna
 * pareja de numeros significa nada. Un banco de pruebas que se mueve solo no
 * es un banco de pruebas.
 *
 * Se apaga creando turbo-no.txt junto al .nro. */
#define NX_FRENO "sdmc:/switch/pokemon-anil/turbo-no.txt"

static int turbo;              /* 0 sin decidir, 1 aplicando, -1 desactivado */

static Result pon(PcvModuleId modulo, u32 hz)
{
    ClkrstSession s;
    Result rc;

    rc = clkrstOpenSession(&s, modulo, 3);
    if (R_FAILED(rc))
        return rc;
    rc = clkrstSetClockRate(&s, hz);
    clkrstCloseSession(&s);
    return rc;
}

void nx_reloj_soltar(void)
{
    if (arrancado != 1 || turbo != 1)
        return;
    pon(PcvModuleId_CpuBus, NX_CPU_FABRICA);
    pon(PcvModuleId_EMC, NX_EMC_FABRICA);
}

void nx_reloj_forzar(void)
{
    char linea[192];
    Result rc;

    if (!abre())
        return;

    if (turbo == 0) {
        FILE *f = fopen(NX_FRENO, "rb");
        if (f) {
            fclose(f);
            turbo = -1;
            nx_boot_trace("[reloj] turbo apagado: existe turbo-no.txt");
            return;
        }
        turbo = 1;
        /* Al salir, devolver el reloj. Horizon lo restaura solo cuando el
         * gestor de energia reconfigura, pero no cuesta nada no depender de
         * ello: si el juego peta y deja la consola a 1785 MHz en el menu,
         * la bateria se va sin que nadie sepa por que. */
        atexit(nx_reloj_soltar);

        rc = pon(PcvModuleId_CpuBus, NX_CPU_TURBO);
        pon(PcvModuleId_EMC, NX_EMC_TURBO);
        snprintf(linea, sizeof(linea),
                 "[reloj] turbo: pedidos CPU %u MHz y RAM %u MHz, rc=0x%x "
                 "(se apaga con turbo-no.txt)",
                 NX_CPU_TURBO / 1000000u, NX_EMC_TURBO / 1000000u,
                 (unsigned)rc);
        nx_boot_trace(linea);
        return;
    }

    if (turbo != 1)
        return;

    pon(PcvModuleId_CpuBus, NX_CPU_TURBO);
    pon(PcvModuleId_EMC, NX_EMC_TURBO);
}
