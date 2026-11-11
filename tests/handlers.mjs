import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';

const flavor = process.argv[2] || 'node';
const entry = flavor === 'bun'
  ? await import('../package/bun/index.ts')
  : await import('../package/node/index.mjs');
const cookies = [
  'session=one; Path=/; HttpOnly; Secure; SameSite=None',
  'session=two; Path=/other; Expires=Wed, 01 Jan 2031 00:00:00 GMT',
];
const seen = [];
const server = createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  seen.push({ method: req.method, body: Buffer.concat(chunks).toString() });
  res.writeHead(200, { 'content-type': 'application/json', 'set-cookie': cookies });
  res.end(JSON.stringify({ ok: true }));
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
try {
  for (const method of ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']) {
    const body = JSON.stringify({
      url: `http://127.0.0.1:${server.address().port}/`,
      method,
      data: 'request-body',
      timeout: 5000,
    });
    const response = flavor === 'bun'
      ? await entry.default.fetch(new Request('http://localhost/', { method: 'POST', body }))
      : await entry.handler({ httpMethod: 'POST', path: '/', body });
    assert.equal(flavor === 'bun' ? response.status : response.statusCode, 200);
    const result = flavor === 'bun' ? await response.json() : JSON.parse(response.body);
    assert.equal(result.status, 200, JSON.stringify(result));
    assert.deepEqual(result.setCookie, cookies);
    assert.deepEqual(seen.at(-1), {
      method,
      body: ['GET', 'HEAD'].includes(method) ? '' : 'request-body',
    });
  }
  console.log(`${flavor}: 7 HTTP methods and complete Set-Cookie headers passed`);
} finally {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
}
