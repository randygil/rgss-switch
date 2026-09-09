# Lee un MapNNN.rxdata de RPG Maker XP con el Ruby 3.1 del PC y escupe los
# comandos de evento en texto. Sirve para saber, ANTES de encender el emulador,
# cuantas cajas de dialogo y cuantos menus de eleccion tiene una introduccion:
# conducir a ciegas contando pulsaciones cuesta vueltas de emulador enteras.
#
#   ruby leer-mapa.rb <MapNNN.rxdata> [id_evento]
#
# Marshal necesita que las clases existan; no necesita que hagan nada. RPG::*
# se fabrican al vuelo con const_missing, y Table/Color/Tone se definen a mano
# porque son de las que llevan _load propio.

class Table
  def self._load(s); t = allocate; t.instance_variable_set(:@bytes, s); t; end
end
class Color
  def self._load(s); allocate; end
end
class Tone
  def self._load(s); allocate; end
end

module RPG
  # Marshal no pasa por const_missing (usa rb_path_to_class), asi que las
  # clases hay que tenerlas puestas de antemano. Son las nueve que aparecen en
  # un MapNNN.rxdata de RPG Maker XP.
  class Map; end
  class EventCommand; end
  class MoveRoute; end
  class MoveCommand; end
  class AudioFile; end
  class Event
    class Page
      class Condition; end
      class Graphic; end
    end
  end
end

def iv(o, n) = o.instance_variable_get(n)

ruta = ARGV[0]
solo = ARGV[1] ? ARGV[1].to_i : nil
mapa = Marshal.load(File.binread(ruta))
eventos = iv(mapa, :@events)
eventos.sort.each do |id, ev|
  next if solo && id != solo
  puts "=== evento #{id} \"#{iv(ev, :@name)}\" en (#{iv(ev, :@x)},#{iv(ev, :@y)})"
  iv(ev, :@pages).each_with_index do |pag, i|
    lista = iv(pag, :@list)
    puts "--- pagina #{i + 1}: #{lista.size} comandos"
    lista.each do |c|
      cod = iv(c, :@code)
      par = iv(c, :@parameters)
      next if cod == 0
      txt = par.map { |p| p.is_a?(String) ? p.inspect : p.inspect }.join(", ")
      puts format("  %4d %s", cod, txt[0, 200])
    end
  end
end
