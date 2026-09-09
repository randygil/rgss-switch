/*
 * nx_excepcion.c — manejador de excepciones de CPU con traza de pila.
 *
 * Hasta ahora, cuando el juego provocaba una excepcion de CPU, Horizon
 * respondia con la pantalla de error y Ryujinx anotaba
 *
 *     ResultCode: 2345-0007   FatalPolicy: ErrorReportAndErrorScreen
 *
 * y nada mas: los registros que imprime el emulador son los del proceso
 * "fatal", no los nuestros, y salen todos a cero. Inservible.
 *
 * libnx tiene el gancho justo para esto. En exception.s, __libnx_exception_entry
 * carga __libnx_exception_handler y, si vale cero —es un simbolo debil sin
 * definir—, se va a __libnx_exception_entry_abort, que es de donde sale ese
 * 2345-0007. Basta con definirlo para quedarnos nosotros con el volcado.
 *
 * Dos precauciones que no son opcionales:
 *
 *   1. Nada de snprintf. El manejador corre sobre una pila propia y pequena y
 *      con el proceso en un estado desconocido; si lo que ha reventado es el
 *      monton, printf reserva memoria y la sonda muere sin decir nada. Se
 *      formatea a mano, que para hexadecimal son diez lineas.
 *   2. __nx_exception_ignoredebug = 1. Sin eso, libnx se va al aborto en
 *      cuanto detecta un depurador conectado, y bajo Ryujinx eso puede pasar.
 *
 * La traza de pila se saca recorriendo la cadena de x29: en AArch64 cada marco
 * guarda [fp] = fp anterior y [fp+8] = direccion de retorno. Las direcciones se
 * imprimen restando la base de carga (ver base_de_carga, mas abajo),
 * asi que se pueden pasar tal cual a
 *
 *     aarch64-none-elf-addr2line -f -C -e rgss-switch.elf <direccion>
 */
#include <stdint.h>
#include <switch.h>

void nx_boot_trace(const char *msg);

/* Sin esto libnx renuncia al manejador si cree que hay un depurador. */
u32 __nx_exception_ignoredebug = 1;

/* La base de carga NO es &__start__: el enlazador lo deja como simbolo
 * absoluto de valor cero, asi que en tiempo de ejecucion vale 0 y las restas
 * salen sin sentido. Se le pregunta al nucleo por la region que contiene a una
 * funcion nuestra; para un NRO enlazado en 0 esa region empieza justo en la
 * base del modulo, que es lo que hay que restar para volver al ELF. */
static uint64_t base_de_carga(void)
{
    static uint64_t cache;
    MemoryInfo mi;
    u32 pi;

    if (cache)
        return cache;
    if (R_SUCCEEDED(svcQueryMemory(&mi, &pi, (u64)(uintptr_t)&base_de_carga)))
        cache = mi.addr;
    return cache;
}

static char *pon(char *p, const char *s)
{
    while (*s)
        *p++ = *s++;
    return p;
}

static char *pon_hex(char *p, uint64_t v)
{
    static const char d[] = "0123456789abcdef";
    int i, empezado = 0;

    *p++ = '0';
    *p++ = 'x';
    for (i = 60; i >= 0; i -= 4) {
        int n = (int)((v >> i) & 0xF);
        if (n || empezado || i == 0) {
            *p++ = d[n];
            empezado = 1;
        }
    }
    return p;
}

static char *pon_dec(char *p, unsigned v)
{
    char t[12];
    int i = 0;

    if (!v) { *p++ = '0'; return p; }
    while (v) { t[i++] = (char)('0' + v % 10); v /= 10; }
    while (i)  *p++ = t[--i];
    return p;
}

static const char *descripcion(u32 desc)
{
    switch (desc) {
    case ThreadExceptionDesc_InstructionAbort: return "fallo al leer instruccion";
    case ThreadExceptionDesc_MisalignedPC:     return "PC desalineado";
    case ThreadExceptionDesc_MisalignedSP:     return "SP desalineado";
    case ThreadExceptionDesc_SError:           return "SError";
    case ThreadExceptionDesc_BadSVC:           return "SVC invalida";
    case ThreadExceptionDesc_Trap:             return "instruccion atrapada";
    case ThreadExceptionDesc_Other:            return "otra (acceso a datos)";
    default:                                   return "desconocida";
    }
}

/* Cadena de marcos. En AArch64 cada marco guarda [fp]=fp anterior y
 * [fp+8]=direccion de retorno. Se exige alineacion a 16 y que la cadena avance
 * siempre hacia arriba, que es lo que evita dar vueltas si la pila esta pisada.
 * Las direcciones salen ya restada la base de carga, listas para
 *     aarch64-none-elf-addr2line -f -C -e rgss-switch.elf +0x...
 */
static void volcar_pila(uint64_t fp)
{
    char linea[256], *p;
    uint64_t base = base_de_carga();
    uint64_t anterior = 0, lr;
    int i;

    nx_boot_trace("[exc] pila:");
    for (i = 0; i < 24 && fp; i++) {
        uint64_t *marco = (uint64_t *)(uintptr_t)fp;

        if ((fp & 0xF) || fp <= anterior)
            break;
        lr = marco[1];
        if (lr < base || lr > base + 0x2000000)
            break;

        p = pon(linea, "[exc]   #");
        p = pon_dec(p, (unsigned)i);
        p = pon(p, "  +");
        p = pon_hex(p, lr - base);
        *p = 0;
        nx_boot_trace(linea);

        anterior = fp;
        fp = marco[0];
    }
}

/* No toda muerte es una excepcion de CPU: libnx tambien aborta a proposito con
 * diagAbortWithResult, y ahi el manejador de arriba no se entera. Es el caso de
 * 2345-0007. Envolverlo dice QUIEN llama. */
void __real_diagAbortWithResult(Result res);
void __wrap_diagAbortWithResult(Result res);

void __wrap_diagAbortWithResult(Result res)
{
    char linea[256], *p;

    p = pon(linea, "[exc] diagAbortWithResult res=");
    p = pon_hex(p, (uint64_t)res);
    p = pon(p, " modulo=");
    p = pon_dec(p, (unsigned)(res & 0x1FF));
    p = pon(p, " desc=");
    p = pon_dec(p, (unsigned)((res >> 9) & 0x1FFF));
    p = pon(p, " llamado desde +");
    p = pon_hex(p, (uint64_t)(uintptr_t)__builtin_return_address(0)
                       - base_de_carga());
    *p = 0;
    nx_boot_trace(linea);

    volcar_pila((uint64_t)(uintptr_t)__builtin_frame_address(0));

    __real_diagAbortWithResult(res);
    __builtin_unreachable();
}

/* El winsys de Mesa para Switch no devuelve errores: llama a fatalThrow y se
 * acabo. Hay tres sitios —switch_swap_buffers, switch_st_framebuffer_validate y
 * switch_create_window_surface— y desde fuera los tres se ven igual: la pantalla
 * de error de Horizon con un codigo y ni una pista de cual fue. */
void __real_fatalThrow(Result res);
void __wrap_fatalThrow(Result res);

void __wrap_fatalThrow(Result res)
{
    char linea[256], *p;
    uint64_t tp;

    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tp));

    p = pon(linea, "[exc] fatalThrow res=");
    p = pon_hex(p, (uint64_t)res);
    p = pon(p, " modulo=");
    p = pon_dec(p, (unsigned)(res & 0x1FF));
    p = pon(p, " desc=");
    p = pon_dec(p, (unsigned)((res >> 9) & 0x1FFF));
    p = pon(p, " desde +");
    p = pon_hex(p, (uint64_t)(uintptr_t)__builtin_return_address(0)
                       - base_de_carga());
    p = pon(p, " hilo tp=");
    p = pon_hex(p, tp);
    *p = 0;
    nx_boot_trace(linea);

    volcar_pila((uint64_t)(uintptr_t)__builtin_frame_address(0));

    __real_fatalThrow(res);
    __builtin_unreachable();
}

void __libnx_exception_handler(ThreadExceptionDump *ctx)
{
    char linea[256], *p;
    uint64_t base = base_de_carga();
    uint64_t fp, lr, pc, sp, anterior;
    int i;

    pc = ctx->pc.x;
    lr = ctx->lr.x;
    sp = ctx->sp.x;
    fp = ctx->fp.x;

    p = pon(linea, "[exc] ");
    p = pon(p, descripcion(ctx->error_desc));
    p = pon(p, " desc=");
    p = pon_hex(p, ctx->error_desc);
    p = pon(p, " esr=");
    p = pon_hex(p, ctx->esr);
    p = pon(p, " far=");
    p = pon_hex(p, ctx->far.x);
    *p = 0;
    nx_boot_trace(linea);

    p = pon(linea, "[exc] base=");
    p = pon_hex(p, base);
    p = pon(p, " pc=");
    p = pon_hex(p, pc);
    p = pon(p, " (+");
    p = pon_hex(p, pc - base);
    p = pon(p, ") lr=+");
    p = pon_hex(p, lr - base);
    p = pon(p, " sp=");
    p = pon_hex(p, sp);
    *p = 0;
    nx_boot_trace(linea);

    /* Registros de cuatro en cuatro, para no pasarse del buffer. */
    for (i = 0; i < 28; i += 4) {
        int j;
        p = pon(linea, "[exc] ");
        for (j = i; j < i + 4 && j < 29; j++) {
            p = pon(p, "x");
            p = pon_dec(p, (unsigned)j);
            p = pon(p, "=");
            p = pon_hex(p, ctx->cpu_gprs[j].x);
            p = pon(p, " ");
        }
        *p = 0;
        nx_boot_trace(linea);
    }

    volcar_pila(fp);

    nx_boot_trace("[exc] fin del volcado; se cierra el proceso");
    svcExitProcess();
    __builtin_unreachable();
}
