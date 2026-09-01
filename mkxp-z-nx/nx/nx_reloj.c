/*
 * nx_reloj.c — a que velocidad va de verdad esta consola. Solo mira; no toca.
 *
 * Existe porque durante la caza de los tirones hubo que descartar el reloj como
 * causa, y "he puesto un perfil de overclock" no es una medida: sys-clk puede
 * no aplicarlo, aplicarlo solo en la base, o no coincidir el titulo. Asi que el
 * juego pregunta a clkrst y lo anota. Solo escribe cuando cambia: el reloj se
 * mueve al entrar y salir de la base, y esas transiciones son lo que interesa.
 *
 * Hubo una version de este fichero que ademas FORZABA la CPU a 1785 MHz. Se
 * quito: los tirones resultaron ser codigo del juego barriendo sprites pixel a
 * pixel (ver runtime/lib/nx-centro.rb), y una vez arreglado eso el juego va
 * bien al reloj de fabrica. Forzar el reloj desde una aplicacion es ademas
 * meterse en el terreno del gestor de energia de la consola: gasta bateria,
 * le quita presupuesto a la GPU y es cosa del usuario (sys-clk), no del juego.
 */
#include <switch.h>
#include <stdio.h>

void nx_boot_trace(const char *msg);
void nx_reloj(void);

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
