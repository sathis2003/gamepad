// PocketPad site Worker. Static files in docs/ are served by Cloudflare assets first;
// only requests with no matching file reach this code.
//
// POST /api/subscribe {email}  ->  KV key "email:<address>" = {"email","subscribed_at"}
// The EMAILS KV binding is configured in wrangler.jsonc.

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/api/subscribe') return new Response('Not found', { status: 404 });
    if (request.method !== 'POST') return json({ error: 'Use POST.' }, 405);
    if (!env.EMAILS) return json({ error: 'Email signup is not switched on yet. Please check back soon.' }, 503);

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'Send JSON like {"email": "you@example.com"}.' }, 400);
    }
    if (body.company) return json({ ok: true }); // honeypot field filled: a bot, pretend success

    const email = String(body.email || '').trim().toLowerCase();
    if (email.length > 254 || !EMAIL_RE.test(email)) {
      return json({ error: 'That does not look like an email address.' }, 400);
    }

    // ponytail: no rate limit; add Cloudflare's rate-limiting binding if bots start filling KV
    const key = `email:${email}`;
    if (!(await env.EMAILS.get(key))) {
      await env.EMAILS.put(key, JSON.stringify({ email, subscribed_at: new Date().toISOString() }));
    }
    return json({ ok: true });
  },
};
