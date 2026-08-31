# nx-teclado.rb — en una Switch no hay teclado.
#
# Pokemon Essentials trae DOS pantallas para escribir un nombre y elige entre
# ellas con $PokemonSystem.textinput:
#
#   PokemonEntryScene   pide "Escribe texto usando el teclado. Pulsa Enter
#                       para confirmar". Es la de por defecto.
#   PokemonEntryScene2  es la rejilla de caracteres de siempre, con cursor,
#                       mayusculas, acentos y un boton OK.
#
# En un ordenador la primera es comoda. En una consola no es una molestia: es un
# callejon sin salida, porque la partida no puede empezar sin nombre y no hay
# manera de teclearlo. El juego se queda ahi para siempre y ademas sin dar
# ningun error.
#
# El parche no puede aplicarse en el preload, porque las clases del juego
# todavia no existen: los scripts se cargan despues. Se engancha a
# Graphics.update, que corre en todas las pantallas del juego, y en cuanto ve
# que las clases han aparecido hace el cambio y no vuelve a intentarlo.

module NXTeclado
  @hecho = false
  class << self
    attr_accessor :hecho
  end

  def self.revisar
    return unless defined?(PokemonEntryScene2)
    return unless Object.private_method_defined?(:pbEnterText) ||
                  Object.method_defined?(:pbEnterText)

    # Marcar ANTES de tocar nada, y registrar tambien antes. Si el parche se
    # aplicase dos veces, el segundo alias_method apuntaria nuestro propio
    # envoltorio a si mismo y la primera llamada a pbEnterText se quedaria dando
    # vueltas para siempre. Y esto corre dentro de Graphics.update, en el camino
    # de cada fotograma: mejor no depender de llegar al final.
    @hecho = true
    NX.log("[teclado] entrada de texto encaminada a la rejilla con cursor")

    # send(:alias_method) y send(:define_method) en vez de reabrir la clase:
    # menos magia de ambitos y ninguna duda sobre donde acaba cada metodo.
    Object.send(:alias_method, :nx_pbEnterText_con_teclado, :pbEnterText)
    Object.send(:define_method, :pbEnterText) do |*args|
      # Se toca el ajuste del juego en vez de duplicar su codigo: asi el que
      # elige la pantalla sigue siendo pbEnterText, y si Essentials cambia esa
      # logica manana, esto sigue valiendo.
      if defined?($PokemonSystem) && $PokemonSystem.respond_to?(:textinput) &&
         $PokemonSystem.textinput == 0
        $PokemonSystem.textinput = 1
      end
      nx_pbEnterText_con_teclado(*args)
    end
  rescue Exception => e
    @hecho = true          # un fallo por fotograma es peor que ninguno
    NX.log("[teclado] FALLO #{e.class}: #{e.message}")
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_teclado, :update

    def update
      NXTeclado.revisar unless NXTeclado.hecho
      nx_update_sin_teclado
    end
  end
end
