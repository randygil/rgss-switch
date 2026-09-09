# encoding: utf-8
#
# comprobar-ruby18.rb — prueba runtime/lib/nx-ruby18.rb en el PC, sin consola.
#
#   src/rubyinstaller-3.1.4-1-x64/bin/ruby.exe comprobar-ruby18.rb
#
# Dos pruebas, y las dos deciden si el shim vale:
#
#   A) Los OCHO corpus de tmp/censo/<slug>/scripts/*.rb pasan por
#      NXFuente.transforma y el resultado tiene que compilar con
#      RubyVM::InstructionSequence.compile, que es lo que hace mkxp-z al evaluar
#      cada seccion. Criterio: los cinco juegos de Ruby 1.8 al 100 %, y los tres
#      de Ruby 3.1 (Anil, Vanguard, Reborn) con CERO ficheros modificados —si la
#      transformacion toca uno solo de esos, esta tocando codigo bueno.
#
#   B) Las asignaciones de Win32API que se evaluan al CARGAR el script (las que
#      matan el arranque) se ejecutan de verdad contra el postizo, y se
#      comprueba que ninguna lanza y que .call devuelve lo que el script espera.

RAIZ = File.expand_path(File.dirname(__FILE__))
CENSO = File.join(RAIZ, "tmp", "censo")

# NX.log postizo: por pantalla, y contando por tipo de arreglo.
module NX
  @lineas = []
  def self.log(msg)
    @lineas << msg.to_s
    puts "    #{msg}" if $nx_verboso
    nil
  end
  def self.lineas; @lineas; end
  def self.limpia; @lineas = []; end
end

# mkxp define Graphics; aqui no hay, y el shim lo comprueba con defined?.
require File.join(RAIZ, "runtime", "lib", "nx-ruby18.rb")

JUEGOS18 = %w[pokemon-opalo pokemon-iberia pokemon-titan pokemon-z pokemon-uranium]
JUEGOS31 = %w[pokemon-anil pokemon-vanguard pokemon-reborn]

def compila?(src, nombre)
  v, $VERBOSE = $VERBOSE, nil
  RubyVM::InstructionSequence.compile(src, nombre)
  true
rescue SyntaxError => e
  [false, e.message.lines.first.to_s.strip]
ensure
  $VERBOSE = v
end

puts "=" * 78
puts "A) transformacion de fuente sobre los ocho corpus"
puts "=" * 78
printf("%-18s %7s %7s %8s %7s %7s %7s %9s %s\n",
       "juego", "fich.", "tocad.", "when:", "break", "retry", "regex", "ms", "fallan")
puts "-" * 78

fallos_globales = []
total_ms = 0.0

(JUEGOS18 + JUEGOS31).each do |slug|
  dir = File.join(CENSO, slug)
  unless File.directory?(dir)
    puts "#{slug}: no hay #{dir}"
    next
  end
  # Recursivo: Vanguard y Reborn tienen los scripts en subcarpetas
  # (Data/Scripts/ numeradas, Scripts/Reborn/...), no en un solo nivel.
  ficheros = Dir.glob(File.join(dir, "**", "*.rb")).sort
  NX.limpia
  tocados = 0
  fallan = []
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ficheros.each do |f|
    nombre = File.basename(f, ".rb")
    original = File.binread(f).force_encoding("UTF-8")
    salida = NXFuente.transforma(nombre, original)
    tocados += 1 if salida != original
    r = compila?(salida, nombre)
    fallan << [nombre, r[1]] unless r == true
  end
  ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
  total_ms += ms

  cuenta = Hash.new(0)
  NX.lineas.each do |l|
    cuenta[:when]  += 1 if l.include?("when X: ->")
    cuenta[:break] += 1 if l.include?("break -> return")
    cuenta[:retry] += 1 if l.include?("retry -> redo")
    cuenta[:regex] += 1 if l.include?("regex con")
  end

  printf("%-18s %7d %7d %8d %7d %7d %7d %9.0f %s\n",
         slug, ficheros.size, tocados, cuenta[:when], cuenta[:break],
         cuenta[:retry], cuenta[:regex], ms,
         fallan.empty? ? "-" : fallan.size.to_s)
  fallan.each { |n, m| fallos_globales << "#{slug}/#{n}: #{m}" }
  if JUEGOS31.include?(slug) && tocados > 0
    fallos_globales << "#{slug}: #{tocados} ficheros MODIFICADOS y no debia tocarse ninguno"
  end
end
puts "-" * 78
printf("%-18s %7s %7s %8s %7s %7s %7s %9.0f\n", "TOTAL", "", "", "", "", "", "", total_ms)

unless fallos_globales.empty?
  puts
  puts "FALLOS:"
  fallos_globales.each { |f| puts "  #{f}" }
end

# ---------------------------------------------------------------------------
puts
puts "=" * 78
puts "B) Win32API postizo: las asignaciones que se evaluan al cargar"
puts "=" * 78

# Las de Opalo, sacadas del corpus con
#   grep -nE "^\s{0,4}[A-Za-z_@$][A-Za-z_0-9]*\s*=\s*Win32API\.new" *.rb
# quedandose con las que estan en el cuerpo de una clase o un modulo (o sea,
# las que corren al evaluar la seccion) y no dentro de un def.
CARGA = [
  ["0005_Win32API",        "@@GetCurrentThreadId=Win32API.new('kernel32','GetCurrentThreadId', '%w()','l')"],
  ["0005_Win32API",        "@@GetWindowThreadProcessId=Win32API.new('user32','GetWindowThreadProcessId', '%w(l p)','l')"],
  ["0005_Win32API",        "@@FindWindowEx=Win32API.new('user32','FindWindowEx', '%w(l l p p)','l')"],
  ["0029_Sprite_Resizer",  "RtlMoveMemory_pi = Win32API.new('kernel32', 'RtlMoveMemory', 'pii', 'i')"],
  ["0029_Sprite_Resizer",  "SwapRgb = Win32API.new('./rubyscreen.dll', 'SwapRgb', 'pi', '') rescue nil"],
  ["0045_Audio",           "w32_LL = Win32API.new(\"kernel32.dll\", \"LoadLibrary\", 'p', 'l')"],
  ["0047_AudioUtilities",  "waveOutOpen=Win32API.new(\"winmm.dll\",\"waveOutOpen\",\"plplll\",\"l\")"],
  ["0047_AudioUtilities",  "MciSendString = Win32API.new('winmm','mciSendString','%w(p,p,l,l)','l')"],
  ["0051_SpriteWindow",    "FormatMessageA=Win32API.new(\"kernel32\",\"FormatMessageA\",\"LPLLPLP\",\"L\")"],
  ["0051_SpriteWindow",    "RegOpenKeyExA=Win32API.new(\"advapi32\",\"RegOpenKeyExA\",\"LPLLP\",\"L\")"],
  ["0051_SpriteWindow",    "shGetKnownFolderPath=Win32API.new(\"shell32.dll\",\"SHGetKnownFolderPath\",\"pllp\",\"i\") rescue nil"],
  ["0142_PScreen_Load",    "AFR = Win32API.new('gdi32', 'AddFontResource', ['P'], 'L')"],
  ["0142_PScreen_Load",    "WPS = Win32API.new('kernel32', 'WriteProfileString', ['P'] * 3, 'L')"],
  ["0169_PSystem_Controls","@GetKeyState=Win32API.new(\"user32\", \"GetAsyncKeyState\", \"i\", \"i\")"],
  ["0171_PSystem_Utilities","getUserName=Win32API.new('advapi32.dll','GetUserName','pp','i')"],
  ["0195_Map - Klein",     "RtlMoveMemory = Win32API.new('kernel32', 'RtlMoveMemory', 'ppi', 'i')"],
  ["0006_Sockets",         "Win32API.new(\"ws2_32\", \"socket\", \"lll\", \"l\")"],
]

malas = 0
$nx_verboso = false
CARGA.each do |seccion, linea|
  begin
    # Se evalua DENTRO del cuerpo de un modulo, que es donde estan de verdad
    # (`class Win32API` / `module AudioState`): un @@ en el nivel superior es
    # RuntimeError en Ruby 3.x y eso seria un fallo de la prueba, no del shim.
    eval("module NXCarga#{CARGA.index([seccion, linea])}
#{linea}
end")
    printf("  %-24s %-62s OK\n", seccion, linea[0, 62])
  rescue Exception => e
    malas += 1
    printf("  %-24s %-62s %s: %s\n", seccion, linea[0, 62], e.class, e.message)
  end
end
puts "  -> #{CARGA.size - malas}/#{CARGA.size} asignaciones de nivel de carga se evaluan sin excepcion"

puts
puts "  .call sobre cada una (valor y tipo):"
PRUEBAS = [
  ["kernel32!GetCurrentThreadId", Win32API.new("kernel32", "GetCurrentThreadId", "", "l"), [], Integer],
  ["user32!FindWindowEx",         Win32API.new("user32", "FindWindowEx", "llpp", "l"), [0, 0, "RGSS Player", 0], Integer],
  ["user32!GetAsyncKeyState",     Win32API.new("user32", "GetAsyncKeyState", "i", "i"), [65], Integer],
  ["kernel32!RtlMoveMemory",      Win32API.new("kernel32", "RtlMoveMemory", "pii", "i"), ["\0" * 4, 0, 4], Integer],
  ["gdi32!AddFontResource",       Win32API.new("gdi32", "AddFontResource", ["P"], "L"), ["Fonts/x.ttf"], Integer],
  ["winmm!mciSendString",         Win32API.new("winmm", "mciSendString", "pplL", "l"), ["play x", "", 0, 0], Integer],
  ["ws2_32!socket",               Win32API.new("ws2_32", "socket", "lll", "l"), [2, 1, 6], Integer],
  ["ws2_32!inet_ntoa",            Win32API.new("ws2_32", "inet_ntoa", "l", "p"), [0], String],
  ["KleinBitmap!scroll_up",       Win32API.new("KleinBitmap.dll", "scroll_up", "ll", ""), [1, 1], Integer],
  ["rubyscreen!TakeScreenshot",   Win32API.new("rubyscreen.dll", "TakeScreenshot", "%w(p)", "i"), ["a.png"], Integer],
]
PRUEBAS.each do |nombre, api, args, tipo|
  v = api.call(*args)
  ok = v.is_a?(tipo)
  malas += 1 unless ok
  printf("  %-30s -> %-12s %-8s %s\n", nombre, v.inspect[0, 12], v.class, ok ? "OK" : "TIPO MALO, se esperaba #{tipo}")
end

# --- los tres casos con semantica de verdad --------------------------------
puts
puts "  semantica de verdad:"

# pbBatteryLow?: power="\0"*12; sps.call(power); power.unpack("CCCCVV")
sps = Win32API.new("kernel32.dll", "GetSystemPowerStatus", "p", "l")
power = "\0" * 12
r = sps.call(power)
st = power.unpack("CCCCVV")
baja = (st[1] != 255 && (st[1] & 6) != 0) || st[2] < 3 || st[4] < 300
puts "    GetSystemPowerStatus -> #{r}, #{st.inspect}, pbBatteryLow? = #{baja}"
malas += 1 unless r == 1 && baja == false

# GetWindowRect: rect.unpack('l4') -> Rect.new(x,y,w-x,h-y)
gwr = Win32API.new("user32", "GetWindowRect", "lp", "i")
rect = [0, 0, 0, 0].pack("l4")
gwr.call(1, rect)
puts "    GetWindowRect        -> #{rect.unpack('l4').inspect}"
malas += 1 unless rect.unpack("l4") == [0, 0, 512, 384]

# GetUserName
gun = Win32API.new("advapi32.dll", "GetUserName", "pp", "i")
buf = "\0" * 32
gun.call(buf, [32].pack("L"))
puts "    GetUserName          -> #{buf.delete("\0").inspect}"
malas += 1 unless buf.delete("\0") == "Switch"

# Game.ini de verdad: se escribe uno en tmp/ y se lee con las dos funciones.
require "tmpdir"
Dir.mktmpdir do |d|
  Dir.chdir(d) do
    File.binwrite("Game.ini", "[Game]\r\nLibrary=RGSS104E.dll\r\nScripts=Data\\Scripts.rxdata\r\nTitle=Pokemon Opalo\r\n")
    gps = Win32API.new("kernel32", "GetPrivateProfileString", %w[p p p p l p], "l")
    val = "\0" * 256
    gps.call("Game", "Scripts", "", val, 256, ".\\Game.ini")
    leido = val.delete("\0")
    puts "    GetPrivateProfileString('Game','Scripts') -> #{leido.inspect}"
    malas += 1 unless leido == "Data\\Scripts.rxdata"

    wps = Win32API.new("kernel32", "WritePrivateProfileString", %w[p p p p], "l")
    wps.call("Opciones", "Idioma", "es", ".\\Game.ini")
    val2 = "\0" * 256
    gps.call("Opciones", "Idioma", "nada", val2, 256, ".\\Game.ini")
    puts "    WritePrivateProfileString + relectura      -> #{val2.delete("\0").inspect}"
    malas += 1 unless val2.delete("\0") == "es"
  end
end

# --- C) preload.rb de Z: MKXP.zinflate -------------------------------------
puts
puts "=" * 78
puts "C) la cadena del preload.rb de Pokemon Z (Zlib -> MKXP.zinflate)"
puts "=" * 78
require "zlib"
unless defined?(MKXP)
  # nx-compat.rb todavia no trae zinflate/zdeflate; se simula igual que alli,
  # con la INSTANCIA Zlib::Inflate.new y no con el metodo de clase, que es lo
  # que evita la recursion infinita cuando el preload.rb del juego lo redefine.
  module MKXP
    def self.zinflate(s)
      z = Zlib::Inflate.new
      begin
        r = z.inflate(s); z.finish; r
      ensure
        z.close rescue nil
      end
    end
    def self.zdeflate(s, n = nil)
      z = n ? Zlib::Deflate.new(n) : Zlib::Deflate.new
      begin
        z.deflate(s, Zlib::FINISH)
      ensure
        z.close rescue nil
      end
    end
  end
  puts "  (MKXP.zinflate simulado igual que en nx-compat.rb: esta prueba no carga nx-compat.rb,"
  puts "   que hace E/S y toca $LOAD_PATH, y lo que se prueba aqui es la cadena, no el shim de al lado)"
end

# Lo que hace el preload.rb de Z, literalmente.
module Zlib
  class Inflate
    def self.inflate(s); MKXP.zinflate(s); end
  end
  class Deflate
    def self.deflate(s, n = nil); MKXP.zdeflate(s, n); end
  end
end

original = "def main\n  " + ("x" * 2000) + "\nend\n"
comprimido = Zlib::Deflate.deflate(original, 9)
vuelta = Zlib::Inflate.inflate(comprimido)
puts "  #{original.bytesize} bytes -> #{comprimido.bytesize} comprimidos -> #{vuelta.bytesize} de vuelta"
if vuelta == original
  puts "  OK: la cadena preload.rb de Z -> MKXP.zinflate -> Zlib::Inflate.new no recursa"
else
  malas += 1
  puts "  FALLO: el texto no vuelve igual"
end

puts
puts "=" * 78
if fallos_globales.empty? && malas == 0
  puts "TODO BIEN: los cinco corpus de 1.8 compilan al 100 %, los tres de 3.1 salen intactos,"
  puts "           y el Win32API postizo aguanta las asignaciones de carga."
  exit 0
else
  puts "HAY FALLOS: #{fallos_globales.size} en la transformacion, #{malas} en el Win32API."
  exit 1
end
