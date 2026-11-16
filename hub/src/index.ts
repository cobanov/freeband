// Freeband site: Worker entry point.

import { Hono, type MiddlewareHandler } from "hono";
import type { AppEnv } from "./types";
import { pages } from "./routes/pages";
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

const OTHER_CSP = "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

/** 18 random bytes as base64url. */
function newNonce(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(18));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_");
}

/** Security headers on every response; a fresh CSP nonce per request. */
const securityHeaders: MiddlewareHandler<AppEnv> = async (c, next) => {
  const nonce = newNonce();
  c.set("nonce", nonce);
  await next();
  const h = c.res.headers;
  const isHtml = (h.get("content-type") ?? "").startsWith("text/html");
  h.set("Content-Security-Policy", isHtml ? htmlCsp(nonce) : OTHER_CSP);
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
app.route("/", pages);

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

app.notFound((c) =>
  c.html(
    errorPage(c.get("nonce"), c.req.path, { en: "Page not found", tr: "Sayfa bulunamadı" }, { en: "The page you're looking for isn't here.", tr: "Aradığın sayfa burada değil." }),
    404,
  ),
);

app.onError((err, c) => {
  // Never echo internals; log the message and the path only (no bodies, no headers).
  console.error(
    JSON.stringify({
      message: "unhandled error",
      error: err instanceof Error ? err.message : String(err),
      method: c.req.method,
      path: c.req.path,
    }),
  );
  return c.html(
    errorPage(
      c.get("nonce"),
      c.req.path,
      { en: "Something went wrong", tr: "Bir sorun var" },
      { en: "Something unexpected went wrong. Try again in a little while.", tr: "Beklenmeyen bir hata oldu. Biraz sonra tekrar dene." },
    ),
    500,
  );
});

export default { fetch: app.fetch } satisfies ExportedHandler<Env>;
