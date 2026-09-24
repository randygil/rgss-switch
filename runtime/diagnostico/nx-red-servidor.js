// Servidor de prueba para nx-red.rb: eco, binario, redireccion, formulario.
const http = require('http');
const PORT = 8787;
const log = (...a) => console.log(new Date().toISOString(), ...a);

http.createServer((req, res) => {
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const url = new URL(req.url, 'http://x');
    log(req.method, req.url, 'len', body.length, 'ua', req.headers['user-agent'], 'expect', req.headers['expect'] || '-');
    if (url.pathname === '/eco') {
      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'X-Servidor': 'eco' });
      res.end(JSON.stringify({ method: req.method, url: req.url, headers: req.headers, len: body.length, texto: 'ñandú' }));
    } else if (url.pathname === '/binario') {
      const b = Buffer.alloc(256); for (let i = 0; i < 256; i++) b[i] = i;
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      res.end(b);
    } else if (url.pathname === '/espejo') {
      // devuelve el cuerpo tal cual, con el mismo tipo
      res.writeHead(200, { 'Content-Type': req.headers['content-type'] || 'application/octet-stream', 'X-Largo': String(body.length) });
      res.end(body);
    } else if (url.pathname === '/redir') {
      res.writeHead(302, { Location: '/eco?desde=redir' }); res.end();
    } else if (url.pathname === '/lento') {
      setTimeout(() => { res.writeHead(200); res.end('tarde'); }, 3000);
    } else {
      res.writeHead(404, { 'Content-Type': 'text/plain' }); res.end('no');
    }
  });
}).listen(PORT, '0.0.0.0', () => log('escuchando en', PORT));
