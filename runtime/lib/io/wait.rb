# io/wait.rb — sustituto para Nintendo Switch.
#
# La extension nativa io/wait no se compilo. Cable Club la pide junto a
# 'socket'. Como sus sockets nunca llegan a abrirse, basta con definir los
# metodos sobre IO usando IO.select, que si esta en el nucleo de Ruby.

class IO
  unless method_defined?(:wait_readable)
    def wait_readable(timeout = nil)
      IO.select([self], nil, nil, timeout) ? self : nil
    end
  end
  unless method_defined?(:wait_writable)
    def wait_writable(timeout = nil)
      IO.select(nil, [self], nil, timeout) ? self : nil
    end
  end
  unless method_defined?(:ready?)
    def ready?
      !IO.select([self], nil, nil, 0).nil?
    end
  end
  unless method_defined?(:wait)
    def wait(timeout = nil, mode = :read)
      mode == :write ? wait_writable(timeout) : wait_readable(timeout)
    end
  end
  unless method_defined?(:nread)
    def nread; 0 end
  end
end
