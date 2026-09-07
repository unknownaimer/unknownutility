// unknowntweaks private-beta gate. A Cloudflare Worker (free tier is enough).
//
// What it does
//   GET /ut?k=KEY       serves the compiled script from the PRIVATE GitHub repository, but only for
//                       a known, unrevoked key, and stamps the copy with the key and the tester's
//                       name so a leaked file or one-liner says who leaked it.
//   GET /status?k=KEY   answers the script's start-up check: "ok", "revoked", "unknown", "disabled".
//
// KV namespace bound as GATE
//   killswitch          "on" turns everything off at once (downloads 403, status "disabled")
//   key:<KEY>           JSON {"name":"tester","revoked":false,"note":""}
// Vars (wrangler.toml)  GH_OWNER, GH_REPO, GH_BRANCH, GH_FILE
// Secret                GH_TOKEN  fine-grained PAT, Contents: read-only, this repository only
//
// Every hit is logged as one JSON line (wrangler tail): key, tester, IP, country, path, version,
// answer. A key seen from many countries in an hour is a leaked key; revoke that one key.

const TEXT = { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' };
const reply = (status, body) => new Response(body, { status, headers: TEXT });
const KEY_SHAPE = /^[A-Za-z0-9_-]{8,64}$/;

async function lookup(env, key) {
  if (!KEY_SHAPE.test(key)) return null;
  const rec = await env.GATE.get('key:' + key, { type: 'json' });
  return rec && typeof rec === 'object' ? rec : null;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const key = url.searchParams.get('k') || '';
    const kill = (await env.GATE.get('killswitch')) === 'on';
    const rec = await lookup(env, key);
    const who = {
      t: new Date().toISOString(),
      key,
      name: rec ? rec.name : null,
      ip: request.headers.get('cf-connecting-ip'),
      country: request.cf ? request.cf.country : null,
      path: url.pathname,
      v: url.searchParams.get('v') || null,
    };
    const log = (answer, extra) => console.log(JSON.stringify(Object.assign({}, who, { answer }, extra || {})));

    if (url.pathname === '/status') {
      let answer = 'ok';
      if (kill) answer = 'disabled';
      else if (!rec) answer = 'unknown';
      else if (rec.revoked) answer = 'revoked';
      log(answer);
      return reply(200, answer);
    }

    if (url.pathname !== '/ut') return reply(404, 'not found');
    if (kill) { log('disabled'); return reply(403, 'disabled'); }
    if (!rec || rec.revoked) { log(rec ? 'revoked' : 'unknown'); return reply(403, 'invalid key'); }

    // The contents API with the raw media type: documented to accept fine-grained tokens and to
    // return the file bytes as-is for anything under 100 MB.
    const upstream = 'https://api.github.com/repos/' + env.GH_OWNER + '/' + env.GH_REPO + '/contents/' + env.GH_FILE + '?ref=' + encodeURIComponent(env.GH_BRANCH || 'main');
    const src = await fetch(upstream, {
      headers: {
        Authorization: 'Bearer ' + env.GH_TOKEN,
        Accept: 'application/vnd.github.raw+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'unknowntweaks-gate',
      },
      cf: { cacheTtl: 300, cacheEverything: true },
    });
    if (!src.ok) { log('upstream ' + src.status); return reply(502, 'upstream unavailable'); }
    let text = await src.text();

    // Never hand out a public build through the gate. If the workflow rebuilt without GATE_URL set,
    // the committed file carries the MIT header and $sync.beta = $false; serving that would make a
    // leak a permitted redistribution. Fail closed until the beta build is back.
    if (!/^\$sync\.beta\s*=\s*\$true\s*$/m.test(text)) { log('refused: committed file is not a -Beta build'); return reply(503, 'beta build not available yet'); }

    // Stamp the three marker lines Compile.ps1 -Beta emits. A function replacement so a tester
    // name containing "$" cannot be interpreted as a replacement pattern.
    const psq = (s) => String(s).replace(/'/g, "''");
    const stamp = (name, value) => {
      const re = new RegExp('^\\$sync\\.' + name + '\\s*=.*$', 'm');
      if (!re.test(text)) throw new Error('marker $sync.' + name + ' missing (not a -Beta build?)');
      text = text.replace(re, () => '$sync.' + name + " = '" + psq(value) + "'");
    };
    try {
      stamp('url', url.origin + '/ut?k=' + key);
      stamp('statusUrl', url.origin + '/status?k=' + key);
      stamp('betaTester', rec.name || key);
    } catch (e) { log('stamp failed', { error: e.message }); return reply(500, 'gate misconfigured'); }

    log('served', { bytes: text.length });
    return reply(200, text);
  },
};
