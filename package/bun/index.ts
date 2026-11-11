/**
 * AWS Lambda (bun 커스텀 런타임) 프록시 — @alice-doctor/wreq-js 브라우저 TLS 지문.
 *
 * bun 레이어 유지: export default { fetch }, handler = index.fetch.
 *
 * 요청 body(JSON):
 *   {
 *     url, method='GET', headers={}, data, encoding, // encoding=응답 (base64|…)
 *     dataEncoding?,     // 'base64' 이면 data 는 요청 본문 base64 (gzip 등)
 *     browser?,          // 프리셋 프로필 (getProfiles() 전체)
 *     os?,               // windows|macos|linux|android|ios
 *     proxy?,
 *     timeout?,
 *     insecure?,
 *     disableDefaultHeaders?,
 *     // 사설/커스텀 프로필 — browser/os 없으면 standalone custom emulation
 *     emulation?: {
 *       tlsOptions?: { ... CustomTlsOptions },
 *       http1Options?: { ... },
 *       http2Options?: { ... },
 *       headers?: object,
 *       origHeaders?: string[],
 *     },
 *     // emulation.tlsOptions 단축 별칭 (동일 의미)
 *     tls?: { ... CustomTlsOptions },
 *   }
 *
 * GET /health  — status
 * GET /profiles — 지원 프로필·OS 목록
 */

// 기본 프로파일 — plus 통과 실측값 (요청에 browser/emulation/tls 없을 때).
const DEFAULT_PROFILE = 'safari_ios_26.2';

// 로드된 모듈 캐시(실패한 promise 영구 캐시 방지).
let _lib: any = null;
const loadWreq = async () => {
    if (_lib) return _lib;
    try {
        // package.json 에서 wreq-js → @alice-doctor/wreq-js 로 alias.
        _lib = await import('wreq-js');
        return _lib;
    } catch (err: any) {
        // scoped 패키지 직접 시도 (alias 없는 배포 대비).
        try {
            _lib = await import('@alice-doctor/wreq-js');
            return _lib;
        } catch {
            _lib = null;
            throw new Error(
                `wreq-js 로드 실패 — 네이티브 모듈 미설치 또는 bun napi 미지원. 원인: ${err.message}`,
            );
        }
    }
};

/** getProfiles() 결과를 Set 으로 캐시 (콜드스타트 이후 재사용). */
let _profileSet: Set<string> | null = null;
const getProfileSet = async (): Promise<Set<string>> => {
    if (_profileSet) return _profileSet;
    const w = await loadWreq();
    const list: string[] =
        typeof w.getProfiles === 'function' ? w.getProfiles() : [];
    _profileSet = new Set(list);
    return _profileSet;
};

const corsHeaders = {
    'content-type': 'application/json',
    'Access-Control-Allow-Origin': '*',
};

/** body.tls 를 emulation.tlsOptions 로 병합. */
function buildEmulation(body: any): any | undefined {
    const emu = body.emulation && typeof body.emulation === 'object'
        ? { ...body.emulation }
        : {};
    const tls = body.tls && typeof body.tls === 'object' ? body.tls : null;
    if (tls) {
        emu.tlsOptions = { ...(emu.tlsOptions || {}), ...tls };
    }
    // 비어 있으면 undefined (프리셋 전용 경로 유지).
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
 * dataEncoding=base64 → Buffer. Node Buffer JSON 형태 복구.
 */
function resolveRequestBody(data: any, dataEncoding?: string): any {
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
    if (typeof Buffer !== 'undefined' && Buffer.isBuffer(data)) return data;
    return JSON.stringify(data);
}

export default {
    async fetch(req: Request): Promise<Response> {
        const u = new URL(req.url);

        if (req.method === 'GET' && (u.pathname === '/health' || u.pathname === '/')) {
            let profilesCount: number | null = null;
            let pkg = '@alice-doctor/wreq-js';
            try {
                const w = await loadWreq();
                profilesCount =
                    typeof w.getProfiles === 'function' ? w.getProfiles().length : null;
            } catch {
                /* health 는 모듈 실패해도 200 가능하도록 카운트만 null */
            }
            return Response.json(
                {
                    status: 'ok',
                    timestamp: Date.now(),
                    package: pkg,
                    runtime: 'bun',
                    profilesCount,
                    defaultProfile: DEFAULT_PROFILE,
                },
                { headers: corsHeaders },
            );
        }

        if (req.method === 'GET' && u.pathname === '/profiles') {
            try {
                const w = await loadWreq();
                const profiles =
                    typeof w.getProfiles === 'function' ? w.getProfiles() : [];
                const operatingSystems =
                    typeof w.getOperatingSystems === 'function'
                        ? w.getOperatingSystems()
                        : ['windows', 'macos', 'linux', 'android', 'ios'];
                return Response.json(
                    {
                        package: '@alice-doctor/wreq-js',
                        runtime: 'bun',
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
                    },
                    { headers: corsHeaders },
                );
            } catch (e: any) {
                return new Response(JSON.stringify({ error: e.message }), {
                    status: 500,
                    headers: corsHeaders,
                });
            }
        }

        // CORS preflight
        if (req.method === 'OPTIONS') {
            return new Response(null, {
                status: 204,
                headers: {
                    ...corsHeaders,
                    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
                    'Access-Control-Allow-Headers': 'content-type, authorization',
                },
            });
        }

        const requestedAt = Date.now();

        try {
            let body: any;
            const rawText = await req.text();
            if (!rawText || !rawText.trim()) {
                return new Response(
                    JSON.stringify({ error: 'url 필드가 필요합니다 (JSON body)' }),
                    { status: 400, headers: corsHeaders },
                );
            }
            try {
                body = JSON.parse(rawText);
            } catch {
                return new Response(
                    JSON.stringify({ error: 'JSON body 파싱 실패' }),
                    { status: 400, headers: corsHeaders },
                );
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
                return new Response(
                    JSON.stringify({ error: 'url 필드가 필요합니다' }),
                    { status: 400, headers: corsHeaders },
                );
            }

            const emulation = buildEmulation(body);
            const standaloneCustom = !!emulation && !browser && !os;

            // browser 검증 — getProfiles() 전체 화이트리스트. standalone custom 이면 생략.
            if (browser) {
                const profiles = await getProfileSet();
                if (!profiles.has(browser)) {
                    return new Response(
                        JSON.stringify({
                            error: `지원하지 않는 browser 프로파일: ${browser}`,
                            supported: [...profiles].sort(),
                            hint: 'GET /profiles 또는 body.emulation / body.tls 로 사설 프로필 사용',
                        }),
                        { status: 400, headers: corsHeaders },
                    );
                }
            }

            // 프리셋: browser 지정 또는 기본값. standalone custom 이면 browser 생략.
            const profile = standaloneCustom
                ? undefined
                : (browser ?? DEFAULT_PROFILE);

            const w = await loadWreq();
            const init: any = {
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
            const res = await w.fetch(url, {
                ...init,
                method: m,
                ...(m !== 'GET' && m !== 'HEAD' ? { body: reqBody } : {}),
            });
            const fetchEnd = Date.now();

            const ct = res.headers?.get?.('content-type') || '';
            const setCookie = res.headers.getSetCookie();

            let payload: any;
            if (encoding === 'base64') {
                if (typeof res.bytes === 'function') {
                    payload = Buffer.from(await res.bytes()).toString('base64');
                } else if (typeof res.arrayBuffer === 'function') {
                    payload = Buffer.from(await res.arrayBuffer()).toString(
                        'base64',
                    );
                } else {
                    payload = Buffer.from(await res.text(), 'utf8').toString(
                        'base64',
                    );
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
                : (profile as string);

            return new Response(
                JSON.stringify({
                    data: payload,
                    setCookie,
                    status: res.status,
                    profile: profileLabel,
                    os: os ?? null,
                    customEmulation: !!emulation,
                }),
                {
                    headers: {
                        ...corsHeaders,
                        'x-requested-at': String(requestedAt),
                        'x-fetch-ms': String(fetchEnd - fetchStart),
                        'x-total-ms': String(respondedAt - requestedAt),
                        'x-wreq-profile': profileLabel,
                        'x-wreq-package': '@alice-doctor/wreq-js',
                        'x-wreq-runtime': 'bun',
                        ...(emulation ? { 'x-wreq-custom-emulation': '1' } : {}),
                    },
                },
            );
        } catch (e: any) {
            return new Response(JSON.stringify({ error: e.message }), {
                status: 500,
                headers: corsHeaders,
            });
        }
    },
};
