// Mock Kinde over HTTPS (rotates refresh tokens, rejects reuse) and a static server for the test app.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { createServer as createHttpServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
const appPort = Number(process.env.APP_PORT ?? 47080);
const kindePort = Number(process.env.KINDE_PORT ?? 47443);
const builds = {
  new: process.env.APP_ROOT ?? join(here, 'app', 'build', 'web'),
  old: process.env.OLD_APP_ROOT,
};
let appRoot = builds.new;
const certDir = join(here, '.certs');

function selfSignedCertificate() {
  const key = join(certDir, 'key.pem');
  const cert = join(certDir, 'cert.pem');
  if (!existsSync(cert)) {
    mkdirSync(certDir, { recursive: true });
    execFileSync('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '30',
      '-subj', '/CN=localhost', '-keyout', key, '-out', cert,
    ], { stdio: 'ignore' });
  }
  return { key: readFileSync(key), cert: readFileSync(cert) };
}

const base64Url = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
const unsignedJwt = (claims) => `${base64Url({ alg: 'none' })}.${base64Url(claims)}.signature`;

let counter = 0;
let refreshDelayMs = 0;
let stats = { refreshRequests: 0, rejectedRefreshes: 0, codeExchanges: 0 };
const codes = new Map();
const refreshTokens = new Map();

function issueTokens(orgCode) {
  const now = Math.floor(Date.now() / 1000);
  const refreshToken = `rt_${++counter}`;
  refreshTokens.set(refreshToken, orgCode);
  return {
    access_token: unsignedJwt({ sub: 'kp_user', org_code: orgCode, iat: now, exp: now + 3600, n: counter }),
    id_token: unsignedJwt({ sub: 'kp_user', org_codes: ['org_pool', 'org_meridian'], iat: now, exp: now + 3600 }),
    refresh_token: refreshToken,
    token_type: 'bearer',
    expires_in: 3600,
    scope: 'openid profile email offline',
  };
}

function corsHeaders(request) {
  return {
    'access-control-allow-origin': request.headers.origin ?? '*',
    'access-control-allow-credentials': 'true',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': request.headers['access-control-request-headers'] ?? '*',
  };
}

function send(request, response, status, body, headers = {}) {
  response.writeHead(status, { ...corsHeaders(request), 'content-type': 'application/json', ...headers });
  response.end(typeof body === 'string' ? body : JSON.stringify(body));
}

async function readForm(request) {
  let body = '';
  for await (const chunk of request) body += chunk;
  return new URLSearchParams(body);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function handleKinde(request, response) {
  const url = new URL(request.url, `https://localhost:${kindePort}`);
  if (request.method === 'OPTIONS') return send(request, response, 204, '');

  switch (`${request.method} ${url.pathname}`) {
    case 'GET /.well-known/jwks.json':
      return send(request, response, 200, { keys: [] });
    case 'GET /oauth2/auth': {
      const code = `code_${++counter}`;
      codes.set(code, url.searchParams.get('org_code') ?? 'org_pool');
      const back = new URL(url.searchParams.get('redirect_uri'));
      back.searchParams.set('code', code);
      back.searchParams.set('state', url.searchParams.get('state'));
      response.writeHead(200, { 'content-type': 'text/html' });
      return response.end(`<a id="approve" href="${back}">Approve ${codes.get(code)}</a>`);
    }
    case 'POST /oauth2/token': {
      const form = await readForm(request);
      if (form.get('grant_type') === 'authorization_code') {
        const orgCode = codes.get(form.get('code'));
        codes.delete(form.get('code'));
        stats.codeExchanges++;
        if (!orgCode) return send(request, response, 400, { error: 'invalid_grant' });
        return send(request, response, 200, issueTokens(orgCode));
      }
      stats.refreshRequests++;
      const presented = form.get('refresh_token');
      const orgCode = refreshTokens.get(presented);
      refreshTokens.delete(presented);
      await sleep(refreshDelayMs);
      if (!orgCode) {
        stats.rejectedRefreshes++;
        return send(request, response, 400, { error: 'invalid_grant' });
      }
      return send(request, response, 200, issueTokens(orgCode));
    }
    case 'GET /logout':
      response.writeHead(302, { location: url.searchParams.get('redirect') ?? `http://localhost:${appPort}/` });
      return response.end();
    case 'GET /__stats':
      return send(request, response, 200, stats);
    case 'POST /__serve': {
      const build = url.searchParams.get('build');
      if (!Object.hasOwn(builds, build) || !builds[build]) return send(request, response, 400, { error: `no ${build} build` });
      appRoot = builds[build];
      return send(request, response, 200, { build, appRoot });
    }
    case 'POST /__reset':
      refreshDelayMs = Number(url.searchParams.get('refreshDelayMs') ?? 0);
      stats = { refreshRequests: 0, rejectedRefreshes: 0, codeExchanges: 0 };
      return send(request, response, 200, { refreshDelayMs });
    default:
      return send(request, response, 404, { error: 'not_found' });
  }
}

const contentTypes = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json',
  '.wasm': 'application/wasm', '.css': 'text/css', '.png': 'image/png', '.ttf': 'font/ttf',
  '.otf': 'font/otf', '.yaml': 'text/plain', '.bin': 'application/octet-stream', '.frag': 'text/plain',
};

function handleApp(request, response) {
  const path = normalize(decodeURIComponent(new URL(request.url, 'http://localhost').pathname));
  const file = join(appRoot, path.endsWith('/') ? `${path}index.html` : path);
  if (!file.startsWith(appRoot) || !existsSync(file)) {
    response.writeHead(404);
    return response.end();
  }
  response.writeHead(200, {
    'content-type': contentTypes[extname(file)] ?? 'application/octet-stream',
    'cache-control': 'no-store',
  });
  response.end(readFileSync(file));
}

createHttpsServer(selfSignedCertificate(), (request, response) => {
  handleKinde(request, response).catch((error) => send(request, response, 500, { error: String(error) }));
}).listen(kindePort, () => console.log(`mock Kinde on https://localhost:${kindePort}`));

createHttpServer(handleApp).listen(appPort, () => console.log(`test app on http://localhost:${appPort}`));
