# Freeband site

The Cloudflare Worker that serves `https://freeband.cobanov.dev`: the public pages about the Freeband app, in English and Turkish. It has no accounts, no API, no database and no secrets. The folder is still called `hub/` and the Worker `openband-hub`. The visual system is [`../docs/DESIGN.md`](../docs/DESIGN.md).

## Pages

| Path | Turkish | What |
|---|---|---|
| `/` | `/tr` | Home: what the app does, its screens, the TestFlight link |
| `/story` | `/tr/story` | How the band was worked out |
| `/guide` | `/tr/guide` | Setting the app up with your own band |
| `/privacy` | `/tr/privacy` | What the site stores (nothing) and how visits are counted |

Anything else answers 404 with an error page, including the old `/login`, `/join`, `/app`, `/docs` and `/v1/*`.

## Layout

```
hub/
  wrangler.jsonc          Worker config: custom domain, static assets, PUBLIC_HOSTNAME and TESTFLIGHT_URL vars
  public/                 Static assets: self-hosted Open Sauce Sans (SIL OFL), favicons, screenshots, og images, _headers
  src/
    index.ts              Entry: security headers with a CSP nonce per response, 404 and 500 pages
    routes/pages.ts       The four pages in both languages
    views/layout.ts       Page shell and the single stylesheet
    views/tokens.ts       Design tokens, generated from ../design/tokens.json by ../scripts/gen_tokens.py
    views/home.ts, story.ts, guide.ts, privacy.ts   Page bodies
    views/html.ts         Auto-escaping HTML template tag
    views/i18n.ts         Language paths
  test/                   Vitest suites running inside workerd via @cloudflare/vitest-plugin
```

The only runtime dependency is `hono`. Versions are pinned exactly in `package.json` (`.npmrc` has `save-exact=true`); `undici` and `sharp`, which only the local toolchain uses, are overridden to patched releases.

## Development

Requirements: Node.js 22 or newer and npm. Nothing below touches a Cloudflare account.

```sh
cd hub
npm ci
npm run dev         # wrangler dev --local, http://localhost:8787
npm test            # vitest run
npm run typecheck   # tsc --noEmit
```

After changing `wrangler.jsonc`, regenerate `worker-configuration.d.ts` with `npm run types`.

`TESTFLIGHT_URL` in `wrangler.jsonc` is the public beta link on the home page and `/guide`; an empty value hides it.

## Deploying

Only when the owner approves. It needs the `cobanov.dev` zone in the same Cloudflare account and a Wrangler login.

```sh
npx wrangler deploy --dry-run   # check the bundle without uploading
npx wrangler deploy
```

`workers_dev` and `preview_urls` are off, so the Worker is reachable only on `freeband.cobanov.dev`.

The first deploy after the account system was removed drops the Worker's D1 binding and its daily cron (`triggers.crons` is an empty list on purpose). It does not delete what is left in the Cloudflare account: the `openband-hub` D1 database and the `HUB_SECRET` and `HUB_INVITE_CODES` secrets. Remove those by hand once the deploy is live.

## Security

- HTML responses carry a per-response nonce CSP (`default-src 'none'`, scripts and styles by nonce only, fonts and images from this origin, `frame-ancestors 'none'`, `base-uri 'none'`), no `unsafe-inline`, no inline handlers or style attributes. Every response gets `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, COOP/CORP `same-origin`, HSTS and, unless set, `Cache-Control: no-store`. Static assets get theirs from `public/_headers`.
- HTML is built with an auto-escaping template tag.
- Fonts are self-hosted. The one outside script is the visit counter on the four pages (OpenAnalytics at `oa-c.cobanov.run`, the owner's own server); the privacy page describes it. The error pages don't load it.
- No cookies are set and nothing is stored.
