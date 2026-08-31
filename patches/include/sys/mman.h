/*
 * <sys/mman.h> minimo para Nintendo Switch (Horizon OS / libnx / newlib).
 *
 * Horizon no expone memoria mapeada POSIX. CRuby solo necesita mapeos
 * anonimos privados para el pool de pilas de Fiber (cont.c), asi que:
 *
 *   mmap      -> memalign(4096, len)   memoria alineada a pagina
 *   munmap    -> free()
 *   mprotect  -> no-op (sin paginas de guarda por hardware)
 *   madvise   -> no-op
 *
 * Consecuencia aceptada: se pierde la deteccion por hardware de
 * desbordamiento de pila en Fibers. Ruby sigue siendo funcional; solo
 * desaparece la red de seguridad. Es la misma concesion que hace el
 * port oficial a WASI (ver la rama __wasi__ en cont.c).
 *
 * Deliberadamente NO se definen las macros MADV_*: asi cont.c no toma
 * ninguna rama de madvise, igual que en WebAssembly.
 */
#ifndef _NXSHIM_SYS_MMAN_H
#define _NXSHIM_SYS_MMAN_H

#include <stdlib.h>
#include <malloc.h>
#include <errno.h>
#include <sys/types.h>

#define PROT_NONE   0x0
#define PROT_READ   0x1
#define PROT_WRITE  0x2
#define PROT_EXEC   0x4

#define MAP_SHARED     0x01
#define MAP_PRIVATE    0x02
#define MAP_FIXED      0x10
#define MAP_ANON       0x20
#define MAP_ANONYMOUS  MAP_ANON

#define MAP_FAILED  ((void *) -1)

#define NXSHIM_PAGE_SIZE 0x1000

#ifdef __cplusplus
extern "C" {
#endif

static inline void *
mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset)
{
    (void)addr; (void)prot; (void)flags; (void)offset;
    if (fd != -1)   { errno = ENODEV; return MAP_FAILED; }  /* sin mapeo de ficheros */
    if (length == 0){ errno = EINVAL; return MAP_FAILED; }
    void *p = memalign(NXSHIM_PAGE_SIZE, length);
    if (!p)         { errno = ENOMEM; return MAP_FAILED; }
    return p;
}

static inline int munmap(void *addr, size_t length)
{ (void)length; free(addr); return 0; }

static inline int mprotect(void *addr, size_t len, int prot)
{ (void)addr; (void)len; (void)prot; return 0; }

static inline int madvise(void *addr, size_t len, int advice)
{ (void)addr; (void)len; (void)advice; return 0; }

static inline int posix_madvise(void *addr, size_t len, int advice)
{ (void)addr; (void)len; (void)advice; return 0; }

static inline int msync(void *addr, size_t len, int flags)
{ (void)addr; (void)len; (void)flags; return 0; }

static inline int mlock(const void *addr, size_t len)
{ (void)addr; (void)len; return 0; }

static inline int munlock(const void *addr, size_t len)
{ (void)addr; (void)len; return 0; }

#ifdef __cplusplus
}
#endif

#endif /* _NXSHIM_SYS_MMAN_H */
