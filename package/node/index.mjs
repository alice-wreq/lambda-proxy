/**
 * AWS Lambda (nodejs) 프록시 — @alice-doctor/wreq-js 브라우저 TLS 지문.
 *
 * handler: index.handler  /  runtime: nodejs24.x (arm64)
 *
 * body(JSON):
 *   {
 *     url, method='GET', headers={}, data, encoding,  // encoding = 응답 인코딩 (base64|…)
 *     dataEncoding?,   // 'base64' 이면 data 는 요청 본문 base64 (gzip 바이너리 등)
 *     browser?, os?, proxy?, timeout?, insecure?, disableDefaultHeaders?,
 *     emulation?: { tlsOptions?, http1Options?, http2Options?, headers?, origHeaders? },
 *     tls?: { ... CustomTlsOptions },  // emulation.tlsOptions 단축
 *   }
 *
 * GET /health  |  GET /profiles
 */

const DEFAULT_PROFILE = 'safari_ios_26.2';
const PKG = '@alice-doctor/wreq-js';

let _lib = null;
const loadWreq = async () => {
  if (_lib) return _lib;
  try {
    _lib = await import('wreq-js');
    return _lib;
  } catch (err) {
    try {
      _lib = await import('@alice-doctor/wreq-js');
      return _lib;
    } catch {
      _lib = null;
      throw new Error(
        `wreq-js 로드 실패 — 네이티브 모듈 미설치이거나 번들러가 제외 안 함. 원인: ${err.message}`,
      );
    }
  }
};

let _profileSet = null;
const getProfileSet = async () => {
  if (_profileSet) return _profileSet;
  const w = await loadWreq();
  const list = typeof w.getProfiles === 'function' ? w.getProfiles() : [];
  _profileSet = new Set(list);
  return _profileSet;
};

const corsHeaders = {
  'content-type': 'application/json',
  'Access-Control-Allow-Origin': '*',
};

function buildEmulation(body) {
  const emu =
    body.emulation && typeof body.emulation === 'object'
      ? { ...body.emulation }
      : {};
  const tls = body.tls && typeof body.tls === 'object' ? body.tls : null;
  if (tls) {
    emu.tlsOptions = { ...(emu.tlsOptions || {}), ...tls };
  }
  if (
    !emu.tlsOptions &&
    !emu.http1Options &&
    !emu.http2Options &&
    !emu.headers &&
    !emu.origHeaders
  ) {
    return undefined;
  }
  return emu;
}

/**
 * 업스트림 요청 본문.
 * - dataEncoding=base64 + string → Buffer (gzip 등 바이너리)
 * - Node Buffer JSON {type:'Buffer',data:number[]} 복구
 * - string → 그대로
 * - object → JSON.stringify
 */
function resolveRequestBody(data, dataEncoding) {
  if (data == null) return null;
  if (dataEncoding === 'base64' && typeof data === 'string') {
    return Buffer.from(data, 'base64');
  }
  if (
    typeof data === 'object' &&
    data.type === 'Buffer' &&
    Array.isArray(data.data)
  ) {
    return Buffer.from(data.data);
  }
  if (typeof data === 'string') return data;
  if (Buffer.isBuffer(data)) return data;
  return JSON.stringify(data);
}

function json(statusCode, obj, extraHeaders = {}) {
  return {
    statusCode,
    headers: { ...corsHeaders, ...extraHeaders },
    body: JSON.stringify(obj),
  };
}

async function handleHealth() {
  let profilesCount = null;
  try {
    const w = await loadWreq();
    profilesCount =
      typeof w.getProfiles === 'function' ? w.getProfiles().length : null;
  } catch {
    /* health 는 모듈 실패해도 200 */
  }
  return json(200, {
    status: 'ok',
    timestamp: Date.now(),
    package: PKG,
    runtime: 'node',
    profilesCount,
    defaultProfile: DEFAULT_PROFILE,
  });
}

async function handleProfiles() {
  try {
    const w = await loadWreq();
    const profiles =
      typeof w.getProfiles === 'function' ? w.getProfiles() : [];
    const operatingSystems =
      typeof w.getOperatingSystems === 'function'
        ? w.getOperatingSystems()
        : ['windows', 'macos', 'linux', 'android', 'ios'];
    return json(200, {
      package: PKG,
      runtime: 'node',
      defaultProfile: DEFAULT_PROFILE,
      count: profiles.length,
      profiles,
      operatingSystems,
      customEmulation: {
        note:
          'browser/os 없이 emulation 또는 tls 만내면 standalone 사설 프로필. ' +
          'browser 와 함께 주면 preset 위에 layer.',
        fields: [
          'emulation.tlsOptions',
          'emulation.http1Options',
          'emulation.http2Options',
          'emulation.headers',
          'emulation.origHeaders',
          'tls (→ emulation.tlsOptions 단축)',
        ],
      },
    });
  } catch (e) {
    return json(500, { error: e.message });
  }
}

export const handler = async (event) => {
  const httpMethod =
    event.requestContext?.http?.method || event.httpMethod || 'GET';
  const path = event.rawPath || event.path || '/';

  if (httpMethod === 'OPTIONS') {
    return {
      statusCode: 204,
      headers: {
        ...corsHeaders,
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'content-type, authorization',
      },
      body: '',
    };
  }

  if (httpMethod === 'GET' && (path === '/health' || path === '/')) {
    return handleHealth();
  }
  if (httpMethod === 'GET' && path === '/profiles') {
    return handleProfiles();
  }

  const requestedAt = Date.now();

  try {
    if (!event.body) {
      return json(400, { error: 'url 필드가 필요합니다 (JSON body)' });
    }
    let raw =
      typeof event.body === 'string'
        ? event.body
        : JSON.stringify(event.body);
    if (event.isBase64Encoded) {
      raw = Buffer.from(raw, 'base64').toString('utf8');
    }
    let body;
    try {
      body = JSON.parse(raw);
    } catch {
      return json(400, { error: 'JSON body 파싱 실패' });
    }

    const {
      url,
      method = 'GET',
      headers = {},
      data,
      encoding,
      dataEncoding,
      browser,
      os,
      proxy,
      timeout,
      insecure,
      disableDefaultHeaders,
    } = body;

    if (!url || typeof url !== 'string') {
      return json(400, { error: 'url 필드가 필요합니다' });
    }

    const emulation = buildEmulation(body);
    const standaloneCustom = !!emulation && !browser && !os;

    if (browser) {
      const profiles = await getProfileSet();
      if (!profiles.has(browser)) {
        return json(400, {
          error: `지원하지 않는 browser 프로파일: ${browser}`,
          supported: [...profiles].sort(),
          hint: 'GET /profiles 또는 body.emulation / body.tls 로 사설 프로필 사용',
        });
      }
    }

    const profile = standaloneCustom ? undefined : browser ?? DEFAULT_PROFILE;
    const w = await loadWreq();
    const init = {
      headers,
      ...(profile ? { browser: profile } : {}),
      ...(os ? { os } : {}),
      ...(emulation ? { emulation } : {}),
      ...(proxy ? { proxy } : {}),
      ...(timeout != null ? { timeout } : {}),
      ...(insecure != null ? { insecure } : {}),
      ...(disableDefaultHeaders != null
        ? { disableDefaultHeaders }
        : {}),
    };

    const reqBody = resolveRequestBody(data, dataEncoding);

    const fetchStart = Date.now();
    const m = String(method).toUpperCase();
    let res;
    if (m === 'GET' && typeof w.get === 'function') {
      res = await w.get(url, init);
    } else if (typeof w[m.toLowerCase()] === 'function' && m !== 'GET') {
      res = await w[m.toLowerCase()](url, reqBody, init);
    } else if (typeof w.request === 'function') {
      res = await w.request(url, { ...init, method: m, body: reqBody });
    } else if (typeof w.fetch === 'function') {
      res = await w.fetch(url, { ...init, method: m, body: reqBody });
    } else {
      throw new Error(`지원하지 않는 method: ${method}`);
    }
    const fetchEnd = Date.now();

    const ct = res.headers?.get?.('content-type') || '';
    const cookieRecord = res.cookies || {};
    const setCookie = Object.entries(cookieRecord).flatMap(([k, v]) =>
      Array.isArray(v) ? v.map((x) => `${k}=${x}`) : [`${k}=${v}`],
    );

    let payload;
    if (encoding === 'base64') {
      if (typeof res.bytes === 'function') {
        payload = Buffer.from(await res.bytes()).toString('base64');
      } else if (typeof res.arrayBuffer === 'function') {
        payload = Buffer.from(await res.arrayBuffer()).toString('base64');
      } else {
        payload = Buffer.from(await res.text(), 'utf8').toString('base64');
      }
    } else if (ct.includes('application/json')) {
      const text = await res.text();
      try {
        payload = JSON.parse(text);
      } catch {
        payload = text;
      }
    } else {
      payload = await res.text();
    }

    const respondedAt = Date.now();
    const profileLabel = standaloneCustom
      ? 'custom-emulation'
      : profile;

    return {
      statusCode: 200,
      headers: {
        ...corsHeaders,
        'x-requested-at': String(requestedAt),
        'x-fetch-ms': String(fetchEnd - fetchStart),
        'x-total-ms': String(respondedAt - requestedAt),
        'x-wreq-profile': profileLabel,
        'x-wreq-package': PKG,
        'x-wreq-runtime': 'node',
        ...(emulation ? { 'x-wreq-custom-emulation': '1' } : {}),
      },
      body: JSON.stringify({
        data: payload,
        setCookie,
        status: res.status,
        profile: profileLabel,
        os: os ?? null,
        customEmulation: !!emulation,
      }),
    };
  } catch (e) {
    return json(500, { error: e.message });
  }
};
