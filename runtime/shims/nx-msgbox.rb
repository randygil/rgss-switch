# nx-msgbox.rb - msgbox y compania, que en una consola no hay donde ensenarlos.
#
# Arregla: "undefined method `msgbox'" en los avisos de arranque y de version de
# Essentials v20+ (Game.msgbox, Kernel.msgbox, pbMessage fuera de una escena) y
# en los plugins que usan msgbox_p para depurar. En Windows abren una ventana de
# MessageBox; mkxp-z solo enlaza Kernel.msgbox bajo RGSS3 y este motor corre
# como RGSS1, asi que el metodo no existe y el aviso mata el arranque.
# Visto en el censo de Vanguard (Essentials v20.1, avisos de version).
# De donde sale: idea de scripts/postload/rgss_plugin_stubs.rb de
# mkxp-z-apple-mobile (Empo, GPLv2+), escrito aqui de cero; sin probar en
# consola todavia (2026-09-11): ningun perfil lo enciende.

module Kernel
  # El texto NO se tira: va al registro de Ruby, que es donde se lee todo lo
  # demas de esta consola. Un msgbox que no deja rastro es peor que uno que no
  # se ve, porque suele ser justo el que explica por que el juego se para.
  def msgbox(*args)
    texto = args.map { |a| a.to_s }.join(" ")
    if defined?(NX)
      NX.log("[msgbox] " + texto)
    else
      puts("[msgbox] " + texto)
    end
    nil
  end

  def msgbox_p(*args)
    msgbox(args.map { |a| a.inspect }.join(", "))
  end
end

# Essentials v20+ llama a Game.msgbox y a Game.msgboxp desde su arranque, antes
# de que exista una escena en la que pintar nada.
module Game
  def self.msgbox(*args);  Kernel.msgbox(*args)   end
  def self.msgboxp(*args); Kernel.msgbox_p(*args) end
end unless defined?(Game) && Game.respond_to?(:msgbox)

NX.log("[nx] msgbox postizo: los avisos van a mkxp-ruby.log") if defined?(NX)
