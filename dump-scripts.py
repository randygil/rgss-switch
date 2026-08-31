#!/usr/bin/env python3
"""Extrae Scripts.rxdata / PluginScripts.rxdata a ficheros .rb legibles.

No hay interprete Ruby en esta maquina, asi que se lee el formato Marshal 4.8
directamente. Solo hace falta el subconjunto que usa RPG Maker XP para los
scripts: Array, Fixnum, String (con o sin envoltura de variables de instancia
para la codificacion), Symbol y enlace a simbolo. El codigo de cada script va
comprimido con zlib dentro de la tercera casilla de cada tripleta
[id, nombre, codigo]; PluginScripts.rxdata anida un nivel mas, asi que se
recorre el arbol y se intenta descomprimir cualquier cadena que lo permita.
"""
import sys, os, zlib, struct

class Marshal:
    def __init__(self, data):
        self.d = data; self.i = 0
        self.symbols = []; self.objects = []
    def byte(self):
        b = self.d[self.i]; self.i += 1; return b
    def sbyte(self):
        b = self.byte(); return b - 256 if b > 127 else b
    def fixnum(self):
        c = self.sbyte()
        if c == 0: return 0
        if c > 0:
            if c > 4: return c - 5
            n = 0
            for k in range(c): n |= self.byte() << (8 * k)
            return n
        if c < -4: return c + 5
        n = -1
        for k in range(-c):
            n &= ~(0xFF << (8 * k)); n |= self.byte() << (8 * k)
        return n
    def blob(self):
        n = self.fixnum(); s = self.d[self.i:self.i + n]; self.i += n; return s
    def parse(self):
        t = chr(self.byte())
        if t == '0': return None
        if t == 'T': return True
        if t == 'F': return False
        if t == 'i': return self.fixnum()
        if t == '"':
            v = self.blob(); self.objects.append(v); return v
        if t == ':':
            s = self.blob().decode('ascii', 'replace'); self.symbols.append(s); return s
        if t == ';': return self.symbols[self.fixnum()]
        if t == '@':
            k = self.fixnum()
            # La tabla de enlaces cuenta TODO objeto no inmediato en orden de
            # aparicion (cadenas incluidas). Si aun asi el indice se sale, es
            # que el fichero usa algo que no modelamos: devolver None es
            # preferible a abortar, porque los scripts ya extraidos valen.
            return self.objects[k] if 0 <= k < len(self.objects) else None
        if t == 'I':
            v = self.parse()
            for _ in range(self.fixnum()): self.parse(); self.parse()
            return v
        if t == '[':
            n = self.fixnum(); a = []; self.objects.append(a)
            for _ in range(n): a.append(self.parse())
            return a
        if t == '{':
            n = self.fixnum(); h = {}; self.objects.append(h)
            for _ in range(n):
                k = self.parse(); h[repr(k)] = self.parse()
            return h
        if t in 'ou':
            name = self.parse()
            if t == 'u':
                v = ('userdef', name, self.blob()); self.objects.append(v); return v
            h = {}; self.objects.append(h)
            for _ in range(self.fixnum()):
                k = self.parse(); h[repr(k)] = self.parse()
            return ('object', name, h)
        raise ValueError("tipo Marshal no soportado: %r en %d" % (t, self.i - 1))

def texto(b):
    for enc in ('utf-8', 'cp1252', 'latin-1'):
        try: return b.decode(enc)
        except UnicodeDecodeError: pass
    return b.decode('latin-1', 'replace')

def limpia(s):
    s = "".join(c if (c.isalnum() or c in " _-.") else "_" for c in s).strip()
    return s[:80] or "sin_nombre"

def recorre(nodo, salida, ruta, n):
    """Baja por el arbol buscando tripletas [id, nombre, zlib]."""
    if isinstance(nodo, list):
        nombre = None
        for e in nodo:
            if isinstance(e, bytes):
                try:
                    src = zlib.decompress(e)
                except zlib.error:
                    if nombre is None: nombre = texto(e)
                    continue
                n[0] += 1
                fn = "%04d_%s.rb" % (n[0], limpia(nombre or "script"))
                with open(os.path.join(salida, fn), 'wb') as f:
                    f.write(src)
                nombre = None
            else:
                recorre(e, salida, ruta, n)

for origen, salida in [(sys.argv[1], sys.argv[2])]:
    os.makedirs(salida, exist_ok=True)
    raw = open(origen, 'rb').read()
    assert raw[:2] == b'\x04\x08', "no es Marshal 4.8"
    m = Marshal(raw); m.i = 2
    arbol = m.parse()
    n = [0]
    recorre(arbol, salida, "", n)
    print("%s -> %d scripts en %s" % (os.path.basename(origen), n[0], salida))
