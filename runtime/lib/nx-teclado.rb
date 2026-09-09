# nx-teclado.rb — en una Switch no hay teclado.
#
# Pokemon Essentials trae DOS pantallas para escribir un nombre:
#
#   PokemonEntryScene   pide "Enter text using the keyboard. Press Enter to
#                       confirm". Es la de por defecto.
#   PokemonEntryScene2  es la rejilla de caracteres de siempre, con cursor,
#                       mayusculas, acentos y un boton OK. Es la del mando.
#
# En un ordenador la primera es comoda. En una consola no es una molestia: es un
# callejon sin salida, porque la partida no puede empezar sin nombre y no hay
# manera de teclearlo. El juego se queda ahi para siempre y ademas sin dar
# ningun error.
#
# EL AJUSTE MIENTE, Y MIENTE DISTINTO EN CADA VERSION. pbEnterText elige entre
# las dos mirando $PokemonSystem.textinput, y hasta hoy este shim se limitaba a
# ponerlo a 1. Eso vale para Anil (Essentials v21.1), donde el `if` de
# pbEnterText trata el 0 como teclado -aunque el comentario del ajuste, en
# UI_Options.rb, diga "(0=cursor, 1=keyboard)": manda el `if`-. En Project
# Vanguard (v20.1) el mismo `if` esta escrito al reves:
#
#     if ($PokemonSystem.textinput == 1 rescue false)   # Keyboard
#
# o sea que poner el ajuste a 1 pedia EXACTAMENTE la pantalla que no hay forma
# de usar. Medido: primera partida de Vanguard en Ryujinx, "Your name?" con
# "Enter text using the keyboard. Press Enter to confirm, or Esc to cancel."
# y el cursor parpadeando para siempre (docs/pruebas/pokemon-vanguard.md, vuelta
# 2). Dos juegos de la misma familia y el mismo numero significa lo contrario en
# cada uno: el numero no se puede usar para decidir nada.
#
# ASI QUE NO SE DECIDE. En vez de elegir la rama, se hace que las dos ramas
# lleven al mismo sitio: PokemonEntryScene pasa a ser la rejilla. Las dos clases
# tienen la misma interfaz -pbStartScene(helptext, minlength, maxlength,
# initialText, subject, pokemon), pbEntry y pbEndScene- porque quien las usa es
# la misma PokemonEntry en las dos ramas, y las dos se construyen con .new sin
# argumentos. Da igual lo que valga el ajuste, lo que diga el comentario y en
# que sentido lo lea la version del juego: sale la rejilla.
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
    return unless defined?(PokemonEntryScene)

    # Marcar ANTES de tocar nada, y registrar tambien antes. Esto corre dentro
    # de Graphics.update, en el camino de cada fotograma: mejor no depender de
    # llegar al final.
    @hecho = true

    if PokemonEntryScene.equal?(PokemonEntryScene2)
      NX.log("[teclado] la pantalla de teclado ya era la rejilla")
      return
    end

    # remove_const antes de const_set: sin el, Ruby avisa por $stderr con
    # "already initialized constant" y ese canal va al registro (nx-compat.rb
    # redirige $stdout y $stderr), o sea una linea de ruido por cada arranque.
    # La clase original no se pierde: queda con su nombre viejo por si algun
    # script la busca por ahi.
    Object.send(:const_set, :NXPokemonEntrySceneTeclado, PokemonEntryScene)
    Object.send(:remove_const, :PokemonEntryScene)
    Object.send(:const_set, :PokemonEntryScene, PokemonEntryScene2)
    NX.log("[teclado] PokemonEntryScene -> la rejilla con cursor " \
           "(la del teclado queda en NXPokemonEntrySceneTeclado)")
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
