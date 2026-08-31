#!/usr/bin/env python3
"""Neutraliza las extensiones ARMv9 que GCC 16 emite en libgcc y que el
traductor de Ryujinx (ARMeilleure) no sabe convertir.

El problema no es de ejecucion sino de TRADUCCION: ARMeilleure recorre el grafo
de flujo del bloque completo antes de ejecutarlo, asi que una instruccion en una
rama muerta tumba el proceso igual que si se ejecutara. La traza lo dice:

    at ARMeilleure.Instructions.InstEmit.Mrs(...)
    at ARMeilleure.Translation.Translator.EmitAndGetCFG(...)

Las instrucciones afectadas vienen todas del desenrollador de excepciones
(_Unwind_*) y de las rutinas de soporte de SME de libgcc. Ninguna se ejecuta en
un Cortex-A57 -- que es ARMv8.0-A y no tiene ni GCS ni SME -- porque estan tras
comprobaciones en tiempo de ejecucion que dan negativo. Se sustituyen por NOP o
por `movz Xt,#0`, que es el valor que esas comprobaciones ya asumen.

Consecuencia de no hacerlo: la PRIMERA excepcion de C++ que lanza el programa
mata el proceso. Y mkxp-z usa excepciones para todo (GUARD en config.cpp,
Ruby, SDL_sound...), asi que sin esto no hay juego.

Cada parche es semanticamente neutro en hardware real:
  * chkfeat x16 ya es un NOP en ARMv8.0 (espacio HINT no asignado)
  * mrs Xt,gcspr_el0 solo se alcanza si chkfeat dijo "hay GCS"
  * mrs Xt,tpidr2_el0 va precedido de `ldrb w14,[flag_sme]; cbz w14,ret`,
    de modo que dejar x14 a cero conserva el camino correcto
"""
import struct, sys

NOP = 0xD503201F

def movz(rt):
    return 0xD2800000 | rt

# (nombre, mascara, valor, funcion que produce el reemplazo a partir del original)
RULES = [
    ("chkfeat x16",        0xFFFFFFFF, 0xD503251F, lambda w: NOP),
    ("mrs gcspr_el0",      0xFFFFFFE0, 0xD53B2520, lambda w: movz(w & 0x1F)),
    ("gcspopm",            0xFFFFFFE0, 0xD52B7720, lambda w: NOP),
    ("mrs tpidr2_el0",     0xFFFFFFE0, 0xD53BD0A0, lambda w: movz(w & 0x1F)),
    ("msr tpidr2_el0",     0xFFFFFFE0, 0xD51BD0A0, lambda w: NOP),
    ("smstart/smstop",     0xFFFFF0FF, 0xD503407F, lambda w: NOP),
]

path = sys.argv[1]
blob = bytearray(open(path, 'rb').read())

phoff = struct.unpack_from('<Q', blob, 0x20)[0]
phentsize, phnum = struct.unpack_from('<HH', blob, 0x36)
ranges = []
for i in range(phnum):
    o = phoff + i * phentsize
    p_type, p_flags = struct.unpack_from('<II', blob, o)
    p_offset, _, _, p_filesz = struct.unpack_from('<QQQQ', blob, o + 8)
    if p_type == 1 and (p_flags & 0x1):        # PT_LOAD ejecutable
        ranges.append((p_offset, p_offset + (p_filesz & ~3)))

counts = {}
for lo, hi in ranges:
    for off in range(lo, hi, 4):
        w = struct.unpack_from('<I', blob, off)[0]
        for name, mask, val, repl in RULES:
            if (w & mask) == val:
                struct.pack_into('<I', blob, off, repl(w))
                counts[name] = counts.get(name, 0) + 1
                break

open(path, 'wb').write(blob)
total = sum(counts.values())
detail = ", ".join("%s x%d" % (k, v) for k, v in sorted(counts.items()))
print("ARMv9: %d instrucciones neutralizadas%s" % (total, (" (" + detail + ")") if detail else ""))
