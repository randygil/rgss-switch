# discord.rb — sustituto para Nintendo Switch (Horizon OS)
#
# Scripts/Online/DiscordRichPresence.rb hace `require 'discord'` en su PRIMERA
# linea. La gema de verdad esta en gems/discord.rb y carga gems/discord.so, una
# extension NATIVA DE WINDOWS que ademas habla con discord_game_sdk.dll: en
# Horizon no hay nada de eso y no se puede construir.
#
# Y un LoadError aqui no se queda en "sin Discord". El cargador de Reborn
# (Scripts/ScriptLoader.rb) envuelve cada eval en un `rescue` a secas, o sea
# StandardError, y LoadError es ScriptError: NO lo recoge. Un require que falla
# tumba el arranque entero del juego sin escribir una linea en errorlog.txt.
#
# Este fichero vive en lib/, que va antes que gems/ en rubyLoadpath (el perfil
# lo pone asi a proposito), de modo que gana este y la gema nativa no se llega a
# mirar. Define los cinco metodos que los scripts usan -salieron de un grep
# sobre los 193 ficheros de Scripts/: connect, connected?, disconnect, update y
# update_activity- y no hace ninguno nada.
#
# Lo que hace esto inofensivo no es que connected? conteste false -DiscordRPC
# .start justamente se corta cuando ya esta conectado- sino que ninguno de los
# cinco haga nada: connect no conecta, update no manda y update_activity no
# publica. DiscordRichPresence.rb envuelve ademas Graphics.update para llamar a
# Discord.update en cada fotograma, asi que ese metodo tiene que ser barato: es
# un `nil` y ya.

module Discord
  def self.connect(*);         false end
  def self.connected?;         false end
  def self.disconnect(*);      nil   end
  def self.update(*);          nil   end
  def self.update_activity(*); nil   end
end

NX.log("[reborn] discord postizo: la gema nativa de Windows no viaja") if defined?(NX)
