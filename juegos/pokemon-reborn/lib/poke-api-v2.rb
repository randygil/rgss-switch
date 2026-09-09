# poke-api-v2.rb — sustituto para Nintendo Switch (Horizon OS)
#
# Scripts/Validator.rb hace `require 'poke-api-v2'` en su tercera linea. La gema
# de verdad consulta https://pokeapi.co por HTTP para comprobar que los datos
# del juego cuadran con los oficiales: es una herramienta de los desarrolladores
# de Reborn, no algo que se use jugando (PokeApi.get solo aparece dentro de los
# metodos de la clase Validator, y a Validator.new no lo llama nadie salvo
# validateGen, que se invoca a mano desde la consola de depuracion).
#
# Pero el require esta en el nivel superior, y en el cargador de Reborn un
# LoadError no lo recoge nadie -su `rescue` es StandardError y LoadError es
# ScriptError-, asi que sin este fichero el juego no arranca. Misma familia que
# lib/discord.rb y que el socket.rb generico: no falta una funcion, falta una
# firma.
#
# PokeApi.get eleva en vez de devolver nil a proposito: si algun dia alguien
# llama al validador desde la consola, mas vale que diga por que no puede que
# no que conteste datos vacios y parezca que faltan movimientos.

module PokeApi
  MSG = "poke-api-v2 consulta pokeapi.co por HTTP y en la version para " \
        "Nintendo Switch no hay red"

  def self.get(*)
    raise NotImplementedError, MSG
  end
end

NX.log("[reborn] poke-api-v2 postizo: el validador es de escritorio") if defined?(NX)
