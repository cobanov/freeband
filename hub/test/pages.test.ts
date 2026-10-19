import { describe, expect, it } from "vitest";
import { DEV_B, bearer, call, createAccount, ingest, live, login, syncBody } from "./helpers";

function cspNonce(csp: string): string {
  const m = /script-src 'nonce-([A-Za-z0-9_-]+)'/.exec(csp);
  expect(m).not.toBeNull();
  return m?.[1] ?? "";
}

describe("security headers", () => {
  it("sends a nonce-based CSP and hardening headers on HTML", async () => {
    for (const path of ["/", "/story", "/guide", "/tr", "/tr/story", "/tr/guide", "/tr/privacy", "/login", "/tr/login", "/join", "/tr/join", "/docs", "/tr/docs", "/privacy", "/does-not-exist", "/tr/does-not-exist"]) {
      const res = await call(path);
      expect(res.headers.get("content-type"), path).toContain("text/html");
      const csp = res.headers.get("content-security-policy") ?? "";
      expect(csp).toContain("default-src 'none'");
      expect(csp).toContain("frame-ancestors 'none'");
      expect(csp).toContain("base-uri 'none'");
      expect(csp).not.toContain("unsafe-inline");
      expect(csp).not.toContain("unsafe-eval");
      expect(res.headers.get("x-content-type-options")).toBe("nosniff");
      expect(res.headers.get("referrer-policy")).toBe("no-referrer");
      expect(res.headers.get("x-frame-options")).toBe("DENY");
      expect(res.headers.get("strict-transport-security")).toContain("max-age=");

      const nonce = cspNonce(csp);
      const htmlText = await res.text();
      const scripts = [...htmlText.matchAll(/<script\b([^>]*)>/g)];
      for (const s of scripts) expect(s[1], path).toContain(`nonce="${nonce}"`);
      const styles = [...htmlText.matchAll(/<style\b([^>]*)>/g)];
      for (const s of styles) expect(s[1], path).toContain(`nonce="${nonce}"`);
      // No inline handlers or style attributes that the CSP would have to allow.
      expect(htmlText).not.toMatch(/\son[a-z]+\s*=/i);
      expect(htmlText).not.toMatch(/\sstyle\s*=/i);
      // No third-party resources (outbound links such as GitHub are fine).
      expect(htmlText).not.toMatch(/\ssrc="https?:\/\//);
      // <link> may only point at this site (the hreflang alternates are absolute URLs).
      const linked = [...htmlText.matchAll(/<link\b[^>]*href="(https?:\/\/[^"]+)"/g)].map((m) => m[1] ?? "");
      expect(linked.filter((u) => !u.startsWith("https://freeband.cobanov.dev/")), path).toEqual([]);
    }
  });

  it("uses a fresh nonce per response", async () => {
    const a = cspNonce((await call("/")).headers.get("content-security-policy") ?? "");
    const b = cspNonce((await call("/")).headers.get("content-security-policy") ?? "");
    expect(a).not.toBe(b);
  });

  it("locks down JSON responses too", async () => {
    const { token } = await createAccount();
    const res = await call("/v1/me", { headers: bearer(token) });
    expect(res.headers.get("content-security-policy")).toContain("default-src 'none'");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("access-control-allow-origin")).toBeNull();
    const nf = await call("/v1/nope");
    expect(nf.status).toBe(404);
    expect(((await nf.json()) as { error: string }).error).toBe("not_found");
  });
});

describe("pages", () => {
  it("renders the home page in English at / and in Turkish at /tr", async () => {
    const res = await call("/");
    expect(res.status).toBe(200);
    const home = await res.text();
    expect(home).toContain('<html lang="en">');
    expect(home).toContain('<meta name="color-scheme" content="light dark">');
    // The product first: screens, an honest caption and the two actions.
    for (const img of ["today", "score-recovery", "sleep", "band"]) expect(home).toContain(`src="/img/${img}.webp"`);
    expect(home).toContain("Screens show demo data.");
    expect(home).toMatch(/<a class="btn" href="\/story">How we did it<\/a>/);
    expect(home).toMatch(/<a class="btn ghost" href="https:\/\/github.com\/cobanov\/freeband">GitHub<\/a>/);
    for (const s of ["No Mi Fitness, no account", "Sleep", "Recovery", "Strain", "Optional web access", "TestFlight", "App Store"]) {
      expect(home).toContain(s);
    }
    // The public beta link, no old dial, no pixel wordmark.
    expect(home).toContain('<a class="btn" href="https://testflight.apple.com/join/Qq9A6c1E">Join the beta on TestFlight</a>');
    expect(home).not.toContain('class="dial"');
    expect(home).not.toContain('class="wordmark"');
    // Open Graph, hreflang, the language switch and the trademark line.
    expect(home).toContain('<meta property="og:image" content="https://freeband.cobanov.dev/img/og-home.png">');
    expect(home).toContain('<meta property="og:locale" content="en_US">');
    expect(home).toContain('<meta name="twitter:card" content="summary_large_image">');
    expect(home).toContain('<meta name="twitter:image" content="https://freeband.cobanov.dev/img/og-home.png">');
    for (const tag of ['<link rel="icon" href="/favicon.svg" type="image/svg+xml">', '<link rel="apple-touch-icon" href="/apple-touch-icon.png">', '<link rel="manifest" href="/site.webmanifest">']) {
      expect(home).toContain(tag);
    }
    expect(home).toContain('<link rel="alternate" hreflang="tr" href="https://freeband.cobanov.dev/tr">');
    expect(home).toContain('<link rel="alternate" hreflang="x-default" href="https://freeband.cobanov.dev/">');
    // The globe picker lists both languages and marks the current one.
    expect(home).toContain('<details class="lang"><summary class="navlink" aria-label="Language: English">');
    expect(home).toContain('<a href="/" hreflang="en" lang="en" aria-current="true">English</a>');
    expect(home).toContain('<a href="/tr" hreflang="tr" lang="tr" aria-current="false">Türkçe</a>');
    expect(home).toContain("is not affiliated with Xiaomi");

    const slash = await call("/tr/", { redirect: "manual" });
    expect(slash.status).toBe(301);
    expect(slash.headers.get("location")).toBe("/tr");
    const tr = await (await call("/tr")).text();
    expect(tr).toContain('<html lang="tr">');
    for (const img of ["today", "score-recovery", "sleep", "band"]) expect(tr).toContain(`src="/img/${img}-tr.webp"`);
    for (const s of ["Ekranlar demo veriyle", "Mi Fitness&#39;sız, hesapsız", "Toparlanma", "İsteğe bağlı web erişimi", "Xiaomi ile bağlantısı yoktur"]) {
      expect(tr).toContain(s);
    }
    expect(tr).toMatch(/<a class="btn" href="\/tr\/story">Nasıl yaptık<\/a>/);
    expect(tr).toContain('<meta property="og:image" content="https://freeband.cobanov.dev/img/og-home-tr.png">');
    expect(tr).toContain('<meta property="og:locale" content="tr_TR">');
    expect(tr).toContain('aria-label="Dil: Türkçe"');
    expect(tr).toContain('<a href="/tr" hreflang="tr" lang="tr" aria-current="true">Türkçe</a>');
  });

  it("renders the docs and both privacy pages", async () => {
    const docs = await (await call("/docs")).text();
    expect(docs).toContain("<h1>API docs</h1>");
    expect(docs).toContain("verify the signature over the raw body");
    const belge = await (await call("/tr/docs")).text();
    expect(belge).toContain("<h1>API belgesi</h1>");
    expect(belge).toContain('id="imza"');
    expect(docs).toContain("X-Freeband-Signature");
    expect(docs).toContain("createHmac");
    expect(docs).toContain("hmac.new");
    expect(docs).toContain("curl");
    const privacy = await (await call("/privacy")).text();
    for (const s of ["Cloudflare", "DELETE /v1/account", "Web access", "SHA-256", "Minute data"]) expect(privacy).toContain(s);
    const gizlilik = await (await call("/tr/privacy")).text();
    for (const s of ["Cloudflare", "DELETE /v1/account", "Web erişimi", "SHA-256", "Dakikalık veri"]) expect(gizlilik).toContain(s);
  });

  it("renders the story page as a numbered timeline with diagrams, in both languages", async () => {
    const res = await call("/story");
    expect(res.status).toBe(200);
    const story = await res.text();
    expect(story).toContain("<title>How we worked out the Xiaomi Smart Band 10 · Freeband</title>");
    expect(story).toMatch(/<meta name="description" content="[^"]+">/);
    expect(story).toContain('<meta property="og:url" content="https://freeband.cobanov.dev/story">');
    expect(story).toContain('<meta property="og:image" content="https://freeband.cobanov.dev/img/og-story.png">');
    expect(story).toContain('<ol class="timeline">');
    expect(story.match(/<span class="step-n" aria-hidden="true">/g)).toHaveLength(14);
    expect(story).toContain(">14</span>");
    // Facts from docs/STORY.md, code terms in chips.
    for (const s of ["46%", "13 test vectors", "147 tests", "37,000", "HKDF-SHA256", "AES-128-CTR", "AES-CCM", "Keychain", "Thanks"]) {
      expect(story).toContain(s);
    }
    for (const s of ["FE95", "005E", "005F", "a5 a5", "2/110", "device_type = iOS"]) expect(story).toContain(`<code>${s}</code>`);
    // Two inline SVG diagrams.
    expect(story.match(/<svg viewBox="[^"]+" role="img"/g)).toHaveLength(2);
    // Links to the repo's notes and the projects we learned from.
    for (const href of [
      "https://github.com/cobanov/freeband/blob/main/findings.md",
      "https://github.com/cobanov/freeband/blob/main/docs/CAPABILITIES.md",
      "https://github.com/cobanov/freeband/blob/main/docs/ACTIVITY.md",
      "https://codeberg.org/Freeyourgadget/Gadgetbridge",
      "https://github.com/AstralSightStudios",
      "https://github.com/artyomxx/xiaomi-band-ios-export",
      "https://github.com/LordierClaw/blueband-map",
      "https://github.com/ireescc277-dotcom/band9-rust-ios",
    ]) {
      expect(story).toContain(`href="${href}"`);
    }

    const tr = await (await call("/tr/story")).text();
    expect(tr).toContain("<title>Xiaomi Smart Band 10&#39;u nasıl çözdük · Freeband</title>");
    expect(tr).toContain('<meta property="og:image" content="https://freeband.cobanov.dev/img/og-story-tr.png">');
    expect(tr.match(/<span class="step-n" aria-hidden="true">/g)).toHaveLength(14);
    for (const s of ["%46", "13 test vektörüne", "147 test", "37 bin", "Teşekkürler", "Telefon"]) expect(tr).toContain(s);
    expect(tr.match(/<svg viewBox="[^"]+" role="img"/g)).toHaveLength(2);
  });

  it("has the shared nav on public pages and marks the current one", async () => {
    // English pages link English pages; pages that exist only in Turkish link the Turkish ones.
    const en = ["/", "/story", "/guide", '<a href="/privacy">Privacy</a>'] as const;
    const tr = ["/tr", "/tr/story", "/tr/guide", '<a href="/tr/privacy">Gizlilik</a>'] as const;
    const cases: Array<[path: string, links: readonly [string, string, string, string]]> = [
      ["/", en], ["/story", en], ["/guide", en], ["/privacy", en], ["/docs", en], ["/join", en],
      ["/tr", tr], ["/tr/story", tr], ["/tr/guide", tr], ["/tr/docs", tr], ["/tr/join", tr],
    ];
    for (const [path, [home, story, guide, privacy]] of cases) {
      const page = await (await call(path)).text();
      const docs = home === "/" ? "/docs" : "/tr/docs";
      const login = home === "/" ? "/login" : "/tr/login";
      for (const href of [story, guide, docs, "https://github.com/cobanov/freeband", login]) {
        expect(page, `${path} → ${href}`).toContain(`class="navlink" href="${href}"`);
      }
      expect(page, path).toContain(`<a class="brand" href="${home}">Freeband</a>`);
      expect(page, path).toContain(privacy);
    }
    expect(await (await call("/story")).text()).toContain('href="/story" aria-current="page"');
    expect(await (await call("/tr/story")).text()).toContain('href="/tr/story" aria-current="page"');
  });

  it("renders the step-by-step guide in both languages", async () => {
    const en = await (await call("/guide")).text();
    expect(en).toContain("<title>Try Freeband with your own band · Freeband</title>");
    // Seven steps with TestFlight, then three for building from source.
    expect(en.match(/<span class="step-n" aria-hidden="true">/g)).toHaveLength(10);
    expect(en).toContain("Install Freeband from TestFlight");
    expect(en).toContain('<a class="btn" href="https://testflight.apple.com/join/Qq9A6c1E">Join the beta on TestFlight</a>');
    for (const s of ["git clone https://github.com/cobanov/freeband", "brew install xcodegen", "xcodegen generate", "DEVELOPMENT_TEAM", "Get started", "Choose folder", "Connect", "Offload App", "Never unpair the band"]) {
      expect(en, s).toContain(s);
    }
    expect(en).toContain('<link rel="alternate" hreflang="tr" href="https://freeband.cobanov.dev/tr/guide">');
    const tr = await (await call("/tr/guide")).text();
    expect(tr.match(/<span class="step-n" aria-hidden="true">/g)).toHaveLength(10);
    expect(tr).toContain("TestFlight&#39;tan kur");
    for (const s of ["Başlayalım", "Klasörü seç", "Bağlan", "Uygulamayı Boşalt", "eşleşmeden çıkarma"]) expect(tr, s).toContain(s);
    // The home page links it.
    expect(await (await call("/")).text()).toContain('<a class="btn ghost" href="/guide">Try it yourself</a>');
    expect(await (await call("/tr")).text()).toContain('<a class="btn ghost" href="/tr/guide">Kendin dene</a>');
  });

  it("swaps the sign-in link for the panel when signed in", async () => {
    const { token } = await createAccount();
    const cookie = await login(token);
    const home = await (await call("/", { headers: { Cookie: cookie } })).text();
    expect(home).toContain('<a class="navlink" href="/app">Open panel</a>');
    const tr = await (await call("/tr", { headers: { Cookie: cookie } })).text();
    expect(tr).toContain('<a class="navlink" href="/tr/app">Panele git</a>');
    expect(home).not.toContain('href="/login" aria-current');
  });

  it("renders the panel with the dial and escapes user data", async () => {
    const { token } = await createAccount({ tz: "Europe/Istanbul" });
    const evil = `<script>alert(1)</script>"'&`;
    await ingest(token, syncBody([live("2026-10-13T10:00:00Z", 4200, 77)], { name: evil }));
    const cookie = await login(token);
    const page = await (await call("/tr/app?date=2026-10-13", { headers: { Cookie: cookie } })).text();
    expect(page).toContain('<svg class="dial"');
    expect(page).toContain('class="bar h13"'); // 10:00Z = 13:00 Istanbul
    expect(page).toContain('class="hr"');
    expect(page).toContain("Salı, 13 Ekim");
    expect(page).toContain("4 200");
    expect(page).not.toContain(evil);
    expect(page).toContain("&lt;script&gt;alert(1)&lt;/script&gt;&quot;&#39;&amp;");
    // One band: no switcher.
    expect(page).not.toContain('class="devices"');
  });

  it("shows a device switcher when the account has more than one band", async () => {
    const { token } = await createAccount();
    await ingest(token, syncBody([live("2026-10-13T10:00:00Z", 1)]));
    await ingest(token, syncBody([live("2026-10-13T10:00:00Z", 2)], { id: DEV_B, name: "Band 10 4F21", model: "band10" }));
    const cookie = await login(token);
    const page = await (await call(`/tr/app?device=${DEV_B}&date=2026-10-13`, { headers: { Cookie: cookie } })).text();
    expect(page).toContain('class="devices"');
    expect(page).toMatch(new RegExp(`href="/tr/app\\?device=${DEV_B}&amp;date=2026-10-13" aria-current="true"`));
    expect(page).toContain("Band 10 4F21");
  });

  it("shows an empty state when there is no data", async () => {
    const { token } = await createAccount();
    const cookie = await login(token);
    const page = await (await call("/tr/app", { headers: { Cookie: cookie } })).text();
    expect(page).toContain('<svg class="dial"');
    expect(page).toContain("Henüz veri gelmedi.");
    const en = await (await call("/app", { headers: { Cookie: cookie } })).text();
    expect(en).toContain("No data yet. Open Freeband on your phone and tap Sync.");
    expect(en).toContain('<a href="/tr/app" hreflang="tr" lang="tr" aria-current="false">Türkçe</a>');
    expect(page).not.toContain('class="bar');
  });

  it("keeps the login token out of server requests", async () => {
    const page = await (await call("/login")).text();
    expect(page).toContain("location.hash");
    expect(page).toContain("history.replaceState");
    expect(page).toContain('fetch("/v1/session"');
  });
});
