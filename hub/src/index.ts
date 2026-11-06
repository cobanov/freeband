// Freeband hub: Worker entry point.

import { Hono, type MiddlewareHandler } from "hono";
import type { AppEnv } from "./types";
import { api } from "./routes/api";
import { pages } from "./routes/pages";
import { ConfigError, b64url, randomBytes } from "./lib/crypto";
import { HttpError, errorBody } from "./lib/http";
import { html } from "./views/html";
import { page } from "./views/layout";

const app = new Hono<AppEnv>();

function htmlCsp(nonce: string): string {
  return [
    "default-src 'none'",
    `script-src 'nonce-${nonce}'`,
    `style-src 'nonce-${nonce}'`,
    "font-src 'self'",
    "img-src 'self' data:",
    "manifest-src 'self'",
    "connect-src 'self' https://oa-c.cobanov.run",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "base-uri 'none'",
  ].join("; ");
}

const API_CSP = "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

/** Security headers on every response; a fresh CSP nonce per request. */
const securityHeaders: MiddlewareHandler<AppEnv> = async (c, next) => {
  const nonce = b64url(randomBytes(18));
  c.set("nonce", nonce);
  await next();
  const h = c.res.headers;
  const isHtml = (h.get("content-type") ?? "").startsWith("text/html");
  h.set("Content-Security-Policy", isHtml ? htmlCsp(nonce) : API_CSP);
  h.set("X-Content-Type-Options", "nosniff");
  h.set("Referrer-Policy", "no-referrer");
  h.set("X-Frame-Options", "DENY");
  h.set("Cross-Origin-Opener-Policy", "same-origin");
  h.set("Cross-Origin-Resource-Policy", "same-origin");
  h.set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()");
  if (new URL(c.req.url).protocol === "https:") {
    h.set("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  }
  if (!h.has("Cache-Control")) h.set("Cache-Control", "no-store");
};

app.use("*", securityHeaders);
app.route("/v1", api);
app.route("/", pages);

const isApi = (path: string): boolean => path === "/v1" || path.startsWith("/v1/");

/** Error pages are Turkish under /tr and English elsewhere. */
function errorPage(nonce: string, path: string, title: { en: string; tr: string }, text: { en: string; tr: string }): string {
  const lang = path === "/tr" || path.startsWith("/tr/") ? "tr" : "en";
  const home = lang === "en" ? "/" : "/tr";
  const label = lang === "en" ? "error" : "hata";
  const back = lang === "en" ? "Back to the home page" : "Ana sayfaya dön";
  return page({
    title: title[lang],
    nonce,
    lang,
    body: html`<section class="narrow"><p class="label">${label}</p><h1>${title[lang]}</h1><p class="lede">${text[lang]}</p><a class="btn ghost" href="${home}">${back}</a></section>`,
  });
}

const PROBLEM = { en: "Something went wrong", tr: "Bir sorun var" };

app.notFound((c) => {
  if (isApi(c.req.path)) return c.json(errorBody("not_found", "Böyle bir uç nokta yok."), 404);
  return c.html(
    errorPage(c.get("nonce"), c.req.path, { en: "Page not found", tr: "Sayfa bulunamadı" }, { en: "The page you're looking for isn't here.", tr: "Aradığın sayfa burada değil." }),
    404,
  );
});

app.onError((err, c) => {
  if (err instanceof HttpError) {
    for (const [k, v] of Object.entries(err.headers)) c.header(k, v);
    if (isApi(c.req.path)) {
      return c.json(errorBody(err.code, err.message), err.status as 400);
    }
    return c.html(errorPage(c.get("nonce"), c.req.path, PROBLEM, { en: err.message, tr: err.message }), err.status as 400);
  }
  if (err instanceof ConfigError) {
    console.error(JSON.stringify({ message: "configuration error", error: err.message }));
    return c.json(errorBody("not_configured", "Sunucu henüz tam yapılandırılmadı."), 503);
  }
  // Never echo internals; log the message and the path only (no bodies, no headers).
  console.error(
    JSON.stringify({
      message: "unhandled error",
      error: err instanceof Error ? err.message : String(err),
      method: c.req.method,
      path: c.req.path,
    }),
  );
  if (isApi(c.req.path)) return c.json(errorBody("internal", "Beklenmeyen bir hata oldu. Tekrar dene."), 500);
  return c.html(
    errorPage(c.get("nonce"), c.req.path, PROBLEM, { en: "Something unexpected went wrong. Try again in a little while.", tr: "Beklenmeyen bir hata oldu. Biraz sonra tekrar dene." }),
    500,
  );
});

export default {
  fetch: app.fetch,

  /** Daily cleanup of expired sessions and stale rate-limit windows. */
  async scheduled(_controller, env, ctx) {
    const now = Date.now();
    ctx.waitUntil(
      env.DB.batch([
        env.DB.prepare("DELETE FROM sessions WHERE expires_at <= ?1").bind(now),
        env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?1").bind(Math.floor(now / 1000) - 2 * 86_400),
      ]).then(
        () => console.log(JSON.stringify({ message: "cleanup done" })),
        (err: unknown) =>
          console.error(JSON.stringify({ message: "cleanup failed", error: err instanceof Error ? err.message : String(err) })),
      ),
    );
  },
} satisfies ExportedHandler<Env>;
