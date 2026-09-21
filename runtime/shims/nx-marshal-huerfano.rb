# nx-marshal-huerfano.rb - Marshal.load de clases que ya no existen.
#
# Arregla: "undefined class/module Win32API" (o Mouse, o Sprite_Custom...) al
# cargar una partida o un .rxdata de un juego que guardo objetos de una clase
# que en esta consola no se define, porque su script era de Windows y no se
# carga. Marshal no deja continuar: eleva ArgumentError y se lleva la carga
# entera, o sea la partida del jugador.
# Visto en el censo de la familia ruby18 (Uranium guarda objetos de FmodEx).
# De donde sale: idea de los stubs de JoiPlay que recoge Empo
# (scripts/postload/rgss_plugin_stubs.rb, GPLv2+), escrito aqui de cero; sin
# probar en consola todavia (2026-09-11): ningun perfil lo enciende.

module NXMarshalHuerfano
  # Una clase inerte por cada nombre que falte. Hereda de Object y traga
  # cualquier mensaje: lo que el juego haga con ella despues no es asunto de
  # este fichero, pero al menos la partida termina de cargarse.
  class Inerte
    def method_missing(*)   nil end
    def respond_to_missing?(*) true end
    def marshal_dump;       {} end
    def marshal_load(_);    nil end
  end

  # "undefined class/module Foo::Bar" -> se crean Foo y Foo::Bar.
  def self.define(nombre)
    partes = nombre.to_s.split("::").reject(&:empty?)
    return nil if partes.empty?
    padre = Object
    partes.each_with_index do |parte, i|
      ultimo = (i == partes.size - 1)
      if padre.const_defined?(parte, false)
        padre = padre.const_get(parte, false)
      elsif ultimo
        padre = padre.const_set(parte, Class.new(Inerte))
      else
        padre = padre.const_set(parte, Module.new)
      end
    end
    padre
  end
end

module Marshal
  class << self
    alias_method :nx_load_estricto, :load unless respond_to?(:nx_load_estricto)

    # Se reintenta tantas veces como clases falten, no una sola: un .rxdata
    # suele traer varias. El limite de veinte es para que un fallo que NO sea de
    # una clase ausente no deje el arranque dando vueltas.
    def load(puerto, *resto, &blq)
      intentos = 0
      begin
        # Marshal lee de un puerto y consume: si hay que reintentar, hay que
        # volver al principio. Con una cadena se rebobina sola; con un fichero
        # se pide el rebobinado y, si no se puede, se eleva lo de siempre.
        nx_load_estricto(puerto, *resto, &blq)
      rescue ArgumentError => e
        nombre = e.message[/undefined class\/module ([\w:]+)/, 1]
        raise if nombre.nil? || intentos >= 20
        intentos += 1
        NXMarshalHuerfano.define(nombre)
        NX.log("[nx] Marshal: clase ausente #{nombre}, definida inerte y reintento") if defined?(NX)
        puerto.rewind if puerto.respond_to?(:rewind)
        retry
      end
    end
  end
end

NX.log("[nx] Marshal tolerante: una clase que falte no se lleva la partida") if defined?(NX)
