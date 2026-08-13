// 최소 정적 파일 서버 — WebGPU 프로토타입 측정용.
// WebGPU는 secure context를 요구하고 localhost는 secure로 취급되므로 http로 충분하다.
const http = require('http');
const fs = require('fs');
const path = require('path');

// 프로토타입(proto/webgpu)과 설계 시안(.drive/...)을 함께 서빙하려고 루트를 프로젝트 최상위로 둔다.
const ROOT = path.resolve(__dirname, '..', '..');
const PORT = 8123;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.wgsl': 'text/plain; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
};

http.createServer((req, res) => {
  const urlPath = decodeURIComponent(req.url.split('?')[0]);
  const rel = urlPath === '/'
    ? '.drive/nbody-simulator/design-mockup.html'
    : urlPath.replace(/^\/+/, '');
  const filePath = path.join(ROOT, rel);

  // ROOT 밖으로 나가는 경로는 거부
  if (!filePath.startsWith(ROOT)) {
    res.writeHead(403);
    res.end('forbidden');
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('not found: ' + rel);
      return;
    }
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
}).listen(PORT, () => {
  console.log('nbody proto server on http://localhost:' + PORT);
});
