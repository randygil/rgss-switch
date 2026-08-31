# socket.rb — sustituto para Pokemon Anil 4.0 en Nintendo Switch (Horizon OS)
#
# El plugin "Cable Club" hace `require 'socket'` en el nivel superior de su
# archivo #4, asi que un LoadError aqui aborta el arranque del juego entero.
# CRuby 3.1.7 se compilo con --with-out-ext=socket (ver build-ruby-switch.sh),
# por lo que la extension nativa no existe.
#
# Este fichero define la jerarquia de clases suficiente para que el `require`
# tenga exito y para que Cable Club se cargue. La unica puerta de entrada real
# que usa el plugin es TCPSocket.open(host, port) (archivo #4, linea 11); todo
# lo demas opera sobre el objeto devuelto. Al elevar SocketError ahi, el juego
# arranca con normalidad y solo falla si el jugador entra al Cable Club, que
# sin servidor no funcionaria de todas formas.
#
# libnx SI exporta socket/connect/bind/getaddrinfo, de modo que la extension
# nativa es construible. Ver H6 en README.md.

class SocketError < StandardError; end

NX_SOCKET_MSG = "Cable Club no esta disponible en la version para Nintendo Switch"

class BasicSocket
  def self.open(*)   raise SocketError, NX_SOCKET_MSG end
  def self.new(*)    raise SocketError, NX_SOCKET_MSG end
  def self.do_not_reverse_lookup;      true  end
  def self.do_not_reverse_lookup=(v);  v     end
end

class IPSocket   < BasicSocket; end
class TCPSocket  < IPSocket;    end
class TCPServer  < TCPSocket;   end
class UDPSocket  < IPSocket;    end
class UNIXSocket < BasicSocket; end
class UNIXServer < UNIXSocket;  end

class Socket < BasicSocket
  AF_INET = 2; SOCK_STREAM = 1; SOCK_DGRAM = 2; IPPROTO_TCP = 6
  def self.gethostname; "switch" end
  def self.getaddrinfo(*) raise SocketError, NX_SOCKET_MSG end
  class Option; end
end

class Addrinfo
  def self.tcp(*) raise SocketError, NX_SOCKET_MSG end
  def self.udp(*) raise SocketError, NX_SOCKET_MSG end
end
