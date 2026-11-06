// Server-rendered pages: /, /story, /login, /join, /app, /docs, /privacy.

import { Hono, type Context } from "hono";
import type { AppEnv } from "../types";
import { pageSession } from "../lib/auth";
import { UUID_RE } from "../lib/crypto";
import { daySummaries, listDevices, querySamples, type DayOut, type DeviceOut } from "../lib/queries";
import { addDays, isDate, localDate, localHourOfDay, startOfLocalDay } from "../lib/time";
import { isHeartRate } from "../lib/validate";
import { MAX_WEBHOOKS } from "../lib/webhooks";
import { dial, heartBuckets, hourlyFromCumulative, pulseCurve } from "../views/dial";
import { clock, dayLabel, num, percent, shortDay } from "../views/format";
import { html, raw, type Safe } from "../views/html";
import { page, type OpenGraph } from "../views/layout";
import { APP_JS, JOIN_JS, LOGIN_JS } from "../views/scripts";
import { DOCS_TITLE, docsBody } from "../views/docs";
import { PRIVACY_TITLE, privacyBody } from "../views/privacy";
import { GUIDE_DESCRIPTION, GUIDE_TITLE, guideBody } from "../views/guide";
import { HOME_DESCRIPTION, HOME_IMAGE_ALT, HOME_TITLE, homeBody } from "../views/home";
import { alternates, localPath, type Lang } from "../views/i18n";
import { STORY_DESCRIPTION, STORY_IMAGE_ALT, STORY_TITLE, storyBody } from "../views/story";

export const pages = new Hono<AppEnv>();

const MODEL_NAMES: Record<string, string> = { band10: "Band 10", band10pro: "Band 10 Pro" };
const NOW_WINDOW_MS = 10 * 60_000;
/** An hour with more steps than this counts as active (same rule as the iOS app). */
const ACTIVE_HOUR_STEPS = 250;

const CHEV_L = raw('<svg class="ico" viewBox="0 0 10 10" aria-hidden="true"><path d="M6.5 1.5 3 5l3.5 3.5"/></svg>');
const CHEV_R = raw('<svg class="ico" viewBox="0 0 10 10" aria-hidden="true"><path d="M3.5 1.5 7 5 3.5 8.5"/></svg>');

function render(
  c: Context<AppEnv>,
  title: string,
  body: Safe,
  extra: {
    script?: string;
    signedIn?: boolean;
    analytics?: boolean;
    actions?: Safe;
    description?: string;
    og?: OpenGraph;
    lang?: Lang;
    alternates?: Record<Lang, string>;
  } = {},
) {
  return c.html(page({ title, nonce: c.get("nonce"), body, path: c.req.path, ...extra }));
}

const legend = (lang: Lang): Safe =>
  lang === "en"
    ? html`<ul class="legend" aria-hidden="true"><li><i class="sw sw-step"></i>steps per hour</li><li><i class="sw sw-hr"></i>heart rate</li><li><i class="sw sw-now"></i>now</li><li><i class="sw sw-night"></i>night, 22–06</li></ul>`
    : html`<ul class="legend" aria-hidden="true"><li><i class="sw sw-step"></i>saatlik adım</li><li><i class="sw sw-hr"></i>nabız</li><li><i class="sw sw-now"></i>şimdi</li><li><i class="sw sw-night"></i>gece, 22–06</li></ul>`;

/** True when the browser's first language is Turkish (for entry points the app and invites open). */
function prefersTurkish(c: Context<AppEnv>): boolean {
  const first = (c.req.header("accept-language") ?? "").split(",")[0]?.trim().toLowerCase() ?? "";
  return first === "tr" || first.startsWith("tr-");
}

/** Redirect an English entry page to its Turkish version for Turkish browsers, keeping the query. */
function turkishRedirect(c: Context<AppEnv>, lang: Lang, path: string): Response | null {
  if (lang !== "en" || !prefersTurkish(c)) return null;
  const q = new URL(c.req.url).search;
  return c.redirect(localPath("tr", path) + q, 302);
}

// ---------------------------------------------------------------------------

/** Open Graph data for a public page; absolute URLs on the public hostname. */
function og(c: Context<AppEnv>, path: string, image: string, imageAlt: string): OpenGraph {
  const origin = `https://${c.env.PUBLIC_HOSTNAME}`;
  return { url: origin + path, image: `${origin}/img/${image}`, imageAlt };
}

// Public pages in English (root) and Turkish (/tr).
pages.get("/tr/", (c) => c.redirect("/tr", 301));
for (const lang of ["en", "tr"] as const) {
  const suffix = lang === "en" ? "" : `-${lang}`;

  pages.get(localPath(lang, "/"), async (c) => {
    const signedIn = (await pageSession(c)) !== null;
    const deleted = c.req.query("silindi") === "1" || c.req.query("deleted") === "1";
    return render(c, HOME_TITLE[lang], homeBody({ deleted, lang, testflight: c.env.TESTFLIGHT_URL }), {
      analytics: true,
      signedIn,
      lang,
      alternates: alternates("/"),
      description: HOME_DESCRIPTION[lang],
      og: og(c, localPath(lang, "/"), `og-home${suffix}.png`, HOME_IMAGE_ALT[lang]),
    });
  });

  pages.get(localPath(lang, "/story"), async (c) => {
    const signedIn = (await pageSession(c)) !== null;
    return render(c, `${STORY_TITLE[lang]} · Freeband`, storyBody(lang), {
      analytics: true,
      signedIn,
      lang,
      alternates: alternates("/story"),
      description: STORY_DESCRIPTION[lang],
      og: og(c, localPath(lang, "/story"), `og-story${suffix}.png`, STORY_IMAGE_ALT[lang]),
    });
  });

  pages.get(localPath(lang, "/guide"), async (c) => {
    const signedIn = (await pageSession(c)) !== null;
    return render(c, `${GUIDE_TITLE[lang]} · Freeband`, guideBody(lang, c.env.TESTFLIGHT_URL), {
      analytics: true,
      signedIn,
      lang,
      alternates: alternates("/guide"),
      description: GUIDE_DESCRIPTION[lang],
      og: og(c, localPath(lang, "/guide"), `og-home${suffix}.png`, HOME_IMAGE_ALT[lang]),
    });
  });

  pages.get(localPath(lang, "/privacy"), async (c) => {
    const signedIn = (await pageSession(c)) !== null;
    return render(c, PRIVACY_TITLE[lang], privacyBody(lang), {
      analytics: true,
      signedIn,
      lang,
      alternates: alternates("/privacy"),
      og: og(c, localPath(lang, "/privacy"), `og-home${suffix}.png`, HOME_IMAGE_ALT[lang]),
    });
  });
}

// ---------------------------------------------------------------------------

for (const lang of ["en", "tr"] as const) {
  const T = (en: string, tr: string): string => (lang === "en" ? en : tr);

  pages.get(localPath(lang, "/login"), (c) => {
    const away = turkishRedirect(c, lang, "/login");
    if (away) return away;
    const body = html`
<section class="narrow">
  <p class="label">${T("web panel", "web paneli")}</p>
  <h1>${T("Sign in to the panel", "Panele giriş")}</h1>
  <p class="lede">${T("When you tap Open web panel in the app, you're signed in here automatically. On another computer, paste your key.", "Uygulamada Web paneli aç'a dokunduğunda buraya kendiliğinden girersin. Başka bir bilgisayardaysan anahtarı yapıştır.")}</p>
  <div class="box">
    <p id="login-status" role="status" aria-live="polite"></p>
    <noscript><p class="error">${T("Signing in needs JavaScript turned on in your browser.", "Giriş için tarayıcında JavaScript açık olmalı.")}</p></noscript>
    <form id="login-form" class="stack" hidden autocomplete="off">
      <div>
        <label for="token">${T("Access key", "Erişim anahtarı")}</label>
        <input id="token" name="token" type="password" placeholder="fb_..." spellcheck="false" autocapitalize="off" required>
      </div>
      <button type="submit">${T("Sign in", "Giriş yap")}</button>
    </form>
  </div>
  <p class="small muted">${T("You'll find the key in the app under Settings, in the Web access section. The key isn't kept in the browser; it goes to the server once to sign you in, and you get a session cookie that lasts 30 days instead.", "Anahtarı uygulamada Ayarlar'daki Web erişimi bölümünde bulursun. Anahtar tarayıcıda saklanmaz; yalnız oturum açmak için bir kez sunucuya gider ve yerine 30 gün geçerli bir oturum çerezi alırsın.")}</p>
</section>`;
    return render(c, T("Sign in", "Giriş"), body, { script: LOGIN_JS, lang, alternates: alternates("/login") });
  });

  pages.get(localPath(lang, "/join"), (c) => {
    const away = turkishRedirect(c, lang, "/join");
    if (away) return away;
    const testflight = c.env.TESTFLIGHT_URL;
    const install = testflight
      ? lang === "en"
        ? html`<a href="${testflight}">Install Freeband from TestFlight</a>. You may be asked to install the TestFlight app from the App Store first.`
        : html`<a href="${testflight}">Freeband'i TestFlight'tan kur</a>. Önce App Store'dan TestFlight uygulamasını kurman istenebilir.`
      : html`${T("Ask the person who invited you for Freeband's TestFlight link.", "Seni davet edenden Freeband'in TestFlight bağlantısını iste.")}`;
    const body = html`
<section>
  <p class="label">${T("invite", "davet")}</p>
  <h1>${T("Join Freeband", "Freeband'e katıl")}</h1>
  <p class="lede">${T("Use the Xiaomi Smart Band 10 or 10 Pro on your wrist without a Xiaomi account; your data stays on your phone. With Web access on, you can see your panel on this server and reach your data through the API.", "Bileğindeki Xiaomi Smart Band 10 ya da 10 Pro'yu Xiaomi hesabı olmadan kullanırsın; verilerin telefonunda kalır. Web erişimini açınca bu sunucudan panelini görebilir, API ile verine ulaşabilirsin.")}</p>
  <ol class="grid g2 steps">
    <li><h3>${T("Install the app.", "Uygulamayı kur.")}</h3><p class="muted">${install}</p></li>
    <li><h3>${T("Pair your band with Mi Fitness once.", "Bandını Mi Fitness'la bir kez eşle.")}</h3><p class="muted">${T("Freeband reads the band's key from there. Don't delete Mi Fitness.", "Freeband bandın anahtarını oradan okur. Mi Fitness'ı silme.")}</p></li>
    <li><h3>${T("Open Freeband and finish the setup.", "Freeband'i aç ve ilk kurulumu bitir.")}</h3><p class="muted">${T("The app walks you through it.", "Uygulama seni adım adım götürür.")}</p></li>
    <li><h3>${T("Join web access.", "Web erişimine katıl.")}</h3><p class="muted">${T("If this page is open on your phone, tap the button; Freeband opens with the invite code filled in.", "Bu sayfa telefonunda açıksa düğmeye dokun; Freeband davet kodu dolu açılır.")}</p>
      <p><a id="join-link" class="btn" href="#">${T("Open in Freeband", "Freeband'de aç")} ${CHEV_R}</a></p>
      <p class="small muted">${T("Invite code", "Davet kodu")}: <code id="join-code">…</code></p>
    </li>
  </ol>
  <p class="note small muted">${T("The invite code sits after the # in the link and is never sent to the server from this page.", "Davet kodu bağlantının # sonrasında durur ve bu sayfadan sunucuya gönderilmez.")}</p>
</section>`;
    return render(c, T("Join Freeband", "Freeband'e katıl"), body, {
      script: JOIN_JS,
      lang,
      alternates: alternates("/join"),
      description: HOME_DESCRIPTION[lang],
      og: og(c, localPath(lang, "/join"), `og-home${lang === "en" ? "" : "-tr"}.png`, HOME_IMAGE_ALT[lang]),
    });
  });
}

// ---------------------------------------------------------------------------

interface DayView {
  steps: number | null;
  calories: number | null;
  /** Standing hours from the latest live sample. */
  standing: number | null;
  lastHr: { bpm: number; ts: number } | null;
  hrMin: number | null;
  hrMax: number | null;
  battery: number | null;
  hourly: number[];
  heart: Array<{ h: number; bpm: number }>;
  hasData: boolean;
}

async function loadDay(db: D1Database, accountId: string, tz: string, device: DeviceOut, date: string): Promise<DayView> {
  const from = startOfLocalDay(date, tz);
  const to = startOfLocalDay(addDays(date, 1), tz);
  const rows = await querySamples(db, accountId, { from, to, device: device.id, limit: 20_000 });
  const stepPts: Array<{ h: number; steps: number }> = [];
  const hrPts: Array<{ h: number; bpm: number }> = [];
  let steps: number | null = null;
  let calories: number | null = null;
  let standing: number | null = null;
  let lastHr: DayView["lastHr"] = null;
  let hrMin: number | null = null;
  let hrMax: number | null = null;
  let battery: number | null = null;
  for (const r of rows) {
    const h = localHourOfDay(r.ts, tz);
    if (r.type === "live") {
      if (r.steps !== null) {
        stepPts.push({ h, steps: r.steps });
        steps = Math.max(steps ?? 0, r.steps);
      }
      if (r.calories !== null) calories = Math.max(calories ?? 0, r.calories);
      if (r.standing_hours !== null) standing = r.standing_hours;
      if (isHeartRate(r.heart_rate)) {
        hrPts.push({ h, bpm: r.heart_rate });
        lastHr = { bpm: r.heart_rate, ts: r.ts };
        hrMin = Math.min(hrMin ?? r.heart_rate, r.heart_rate);
        hrMax = Math.max(hrMax ?? r.heart_rate, r.heart_rate);
      }
    } else if (r.level !== null) {
      battery = r.level;
    }
  }
  return {
    steps,
    calories,
    standing,
    lastHr,
    hrMin,
    hrMax,
    battery,
    hourly: hourlyFromCumulative(stepPts),
    heart: heartBuckets(hrPts),
    hasData: rows.length > 0,
  };
}

function appHref(lang: Lang, device: string | null, date: string | null): string {
  const p = new URLSearchParams();
  if (device) p.set("device", device);
  if (date) p.set("date", date);
  const s = p.toString();
  const path = localPath(lang, "/app");
  return s ? `${path}?${s}` : path;
}

/** One reading in the panel grid: a small label over a figure, "–" when missing. */
function reading(cls: string, label: string, value: string | null, unit = ""): Safe {
  return html`<div class="${cls}"><span class="label">${label}</span>${
    value === null ? html`<span class="fig none">–</span>` : html`<span class="fig">${value}${unit ? html`<span class="unit">${unit}</span>` : ""}</span>`
  }</div>`;
}

for (const lang of ["en", "tr"] as const) {
const T = (en: string, tr: string): string => (lang === "en" ? en : tr);

pages.get(localPath(lang, "/app"), async (c) => {
  const s = await pageSession(c);
  if (!s) return c.redirect(localPath(lang, "/"), 303);
  const a = s.account;
  const db = c.env.DB;
  const now = Date.now();
  const today = localDate(now, a.tz);

  const devices = await listDevices(db, a.id);
  const qDevice = (c.req.query("device") ?? "").toUpperCase();
  const device = (UUID_RE.test(qDevice) && devices.find((d) => d.id === qDevice)) || devices[0] || null;
  const qDate = c.req.query("date");
  const date = qDate && isDate(qDate) && qDate <= today ? qDate : today;
  const isToday = date === today;
  const multi = devices.length > 1;
  const devParam = multi && device ? device.id : null;

  const [day, list, hooks] = await Promise.all([
    device ? loadDay(db, a.id, a.tz, device, date) : Promise.resolve(null),
    device ? daySummaries(db, a.id, a.tz, addDays(today, -13), today, device.id) : Promise.resolve([] as DayOut[]),
    db
      .prepare(
        "SELECT id, url, last_delivery_at, last_status, last_error FROM webhooks WHERE account_id = ?1 ORDER BY created_at",
      )
      .bind(a.id)
      .all<{ id: string; url: string; last_delivery_at: number | null; last_status: number | null; last_error: string | null }>(),
  ]);

  // --- dial
  const liveNow = !!day?.lastHr && isToday && now - day.lastHr.ts <= NOW_WINDOW_MS;
  let caption: string | null = null;
  if (day?.lastHr) {
    caption = liveNow ? T("bpm, now", "bpm, şimdi") : `bpm, ${clock(day.lastHr.ts, a.tz)}`;
  } else if (day?.hasData) {
    caption = T("no heart rate", "nabız ölçülmedi");
  }
  const dialSvg = dial({
    hourlySteps: day?.hourly ?? new Array(24).fill(0),
    heart: day?.heart ?? [],
    nowHour: isToday ? localHourOfDay(now, a.tz) : null,
    centerValue: day?.lastHr ? String(day.lastHr.bpm) : day?.hasData ? "–" : null,
    centerCaption: caption,
    label: `${dayLabel(date, lang)}: ${day?.steps !== null && day?.steps !== undefined ? `${day.steps} ${T("steps", "adım")}` : T("no steps", "adım yok")}, ${day?.lastHr ? `${T("last heart rate", "son nabız")} ${day.lastHr.bpm}` : T("no heart rate", "nabız yok")}`,
    lang,
    live: liveNow,
  });

  const emptyText = !device
    ? T("No data yet. Open Freeband on your phone and tap Sync.", "Henüz veri gelmedi. Telefonda Freeband'i açıp Senkronize et'e dokun.")
    : !day?.hasData
      ? isToday
        ? T("No data for today. Open Freeband on your phone and tap Sync.", "Bugün için veri yok. Telefonda Freeband'i açıp Senkronize et'e dokun.")
        : T("No data for this day. Pick another day.", "Bu gün için veri yok. Başka bir gün seç.")
      : null;

  const lastSync = device ? Date.parse(device.last_seen) : null;
  const lastSyncText =
    lastSync === null
      ? null
      : localDate(lastSync, a.tz) === today
        ? clock(lastSync, a.tz)
        : `${shortDay(localDate(lastSync, a.tz), lang)} ${clock(lastSync, a.tz)}`;
  const fresh = lastSync !== null && now - lastSync <= NOW_WINDOW_MS;

  const deviceSwitcher = multi
    ? html`<nav class="devices" aria-label="${T("Bands", "Bantlar")}">${devices.map(
        (d) =>
          html`<a href="${appHref(lang, d.id, date)}" aria-current="${d.id === device?.id ? "true" : "false"}">${d.name}<span class="muted"> ${MODEL_NAMES[d.model] ? `(${MODEL_NAMES[d.model]})` : ""}</span></a>`,
      )}</nav>`
    : "";

  const status = device
    ? html`<p class="status"><span>${device.name}</span>${
        lastSyncText ? html`<span class="sync"><span class="dot${fresh ? " on" : ""}" aria-hidden="true"></span>${T("last sync", "son senkron")} ${lastSyncText}</span>` : ""
      }</p>`
    : html`<p class="status"><span class="sync"><span class="dot" aria-hidden="true"></span>${T("No band yet", "Henüz bant yok")}</span></p>`;

  // --- readings
  const hrRange =
    day?.hrMin != null && day.hrMax != null ? (day.hrMin === day.hrMax ? `${day.hrMin}` : `${day.hrMin}–${day.hrMax}`) : null;
  const activeHours = day ? day.hourly.filter((n) => n > ACTIVE_HOUR_STEPS).length : 0;
  const curve = day ? pulseCurve(day.heart, `${dayLabel(date, lang)} ${T("heart rate curve: lowest", "nabız eğrisi: en düşük")} ${day.hrMin ?? "–"}, ${T("highest", "en yüksek")} ${day.hrMax ?? "–"}`) : null;

  // --- 14-day list
  const byDate = new Map(list.map((r) => [r.date, r]));
  const rows14 = Array.from({ length: 14 }, (_, i) => addDays(today, -i)).map((d) => {
    const r = byDate.get(d);
    return html`<tr aria-current="${d === date ? "true" : "false"}">
  <td><a href="${appHref(lang, devParam, d)}">${d === today ? T("Today", "Bugün") : dayLabel(d, lang)}</a></td>
  <td class="n">${r?.steps != null ? num(r.steps, lang) : "–"}</td>
  <td class="n">${r?.heart_rate_avg != null ? num(r.heart_rate_avg, lang) : "–"}</td>
  <td class="n hide-s">${r?.battery_last != null ? percent(r.battery_last, lang) : "–"}</td>
</tr>`;
  });

  // --- webhooks
  const hookItems = hooks.results.map((h) => {
    const status =
      h.last_delivery_at === null
        ? T("Nothing sent yet.", "Henüz gönderim yapılmadı.")
        : `${T("Last delivery", "Son gönderim")} ${shortDay(localDate(h.last_delivery_at, a.tz), lang)} ${clock(h.last_delivery_at, a.tz)}: ${
            h.last_error === null ? `${T("delivered", "ulaştı")} (HTTP ${h.last_status})` : `${T("not delivered", "ulaşmadı")} (${h.last_error})`
          }.`;
    return html`<li>
  <div class="url">${h.url}</div>
  <div id="wh-status-${h.id}" class="small ${h.last_error ? "error" : "muted"}" role="status">${status}</div>
  <div class="row"><button type="button" class="ghost sm" data-action="test" data-id="${h.id}">${T("Test", "Test et")}</button><button type="button" class="ghost danger sm" data-action="delete" data-id="${h.id}">${T("Delete", "Sil")}</button></div>
</li>`;
  });
  const canAddHook = hooks.results.length < MAX_WEBHOOKS;

  const prev = addDays(date, -1);
  const next = addDays(date, 1);

  const body = html`
<div class="dayhead">
  <div>
    <p class="label">${isToday ? T("today", "bugün") : T("a past day", "geçmiş bir gün")}</p>
    <h1>${dayLabel(date, lang)}</h1>
    ${status}
  </div>
  <form class="picker" method="get" action="${localPath(lang, "/app")}">
    ${devParam ? html`<input type="hidden" name="device" value="${devParam}">` : ""}
    <a class="btn ghost sq" href="${appHref(lang, devParam, prev)}" aria-label="${T("Previous day", "Önceki gün")}" title="${T("Previous day", "Önceki gün")}">${CHEV_L}</a>
    <label class="sr" for="date">${T("Day", "Gün")}</label>
    <input id="date" name="date" type="date" value="${date}" max="${today}">
    <button type="submit" class="ghost">${T("Show", "Göster")}</button>
    ${next <= today ? html`<a class="btn ghost sq" href="${appHref(lang, devParam, next)}" aria-label="${T("Next day", "Sonraki gün")}" title="${T("Next day", "Sonraki gün")}">${CHEV_R}</a>` : ""}
    ${isToday ? "" : html`<a class="btn" href="${appHref(lang, devParam, null)}">${T("Back to today", "Bugüne dön")}</a>`}
  </form>
</div>
${deviceSwitcher}

<div class="grid board">
  <div class="dialcell">
    ${dialSvg}
    ${emptyText ? html`<p class="empty">${emptyText}</p>` : legend(lang)}
  </div>
  ${reading("metric m-steps", T("steps", "adım"), day?.steps != null ? num(day.steps, lang) : null)}
  ${reading("metric m-cal", T("calories", "kalori"), day?.calories != null ? num(day.calories, lang) : null, "kcal")}
  ${reading("metric m-bat", T("battery", "pil"), day?.battery != null ? percent(day.battery, lang) : null)}
  ${reading("fact", T("heart rate range", "nabız aralığı"), hrRange, "bpm")}
  ${reading("fact", T("standing", "ayakta"), day?.standing != null ? String(day.standing) : null, T("h", "saat"))}
  ${reading("fact", T("active hours", "aktif saat"), activeHours > 0 ? String(activeHours) : null, T("h", "saat"))}
  ${reading("fact", T("last reading", "son ölçüm"), day?.lastHr ? clock(day.lastHr.ts, a.tz) : null)}
  <div class="curvecell">
    <span class="label">${isToday ? T("heart rate, today", "nabız, bugün") : `${T("heart rate", "nabız")}, ${shortDay(date, lang)}`}</span>
    ${curve ?? html`<p class="small muted">${isToday ? T("The day's heart rate curve shows up here as you use live heart rate or sync.", "Canlı nabzı açtıkça ya da senkronize ettikçe günün nabız eğrisi burada belirir.") : T("No heart rate curve for this day.", "Bu gün için nabız eğrisi yok.")}</p>`}
  </div>
</div>

<section>
  <h2>${T("The last 14 days.", "Son 14 gün.")} <span class="muted">${T("Tap a day to open it above.", "Bir güne dokunursan yukarıda açılır.")}</span></h2>
  ${device
    ? html`<div class="tablewrap"><table class="days">
<thead><tr><th>${T("Day", "Gün")}</th><th class="n">${T("Steps", "Adım")}</th><th class="n">${T("Average heart rate", "Ortalama nabız")}</th><th class="n hide-s">${T("Battery", "Pil")}</th></tr></thead>
<tbody>${rows14}</tbody>
</table></div>`
    : html`<p class="muted">${T("After the first sync, your days are listed here.", "İlk senkronizasyondan sonra günlerin burada listelenir.")}</p>`}
</section>

<section>
  <h2>${T("Take your data with you.", "Verini taşı.")} <span class="muted">${T("Download it, or send it to your own server after every sync.", "İndir ya da her senkronizasyondan sonra kendi sunucuna gönder.")}</span></h2>
  <div class="grid g3">
    <div>
      <h3>${T("Export", "Dışa aktar")}</h3>
      <p class="muted">${T("Download everything stored here. Each row says which band it came from. JSON has everything; the CSV is for live samples and battery, and the other kinds have their own CSVs.", "Buradaki tüm verini indir. Her satırda hangi banttan geldiği yazar. JSON her şeyi içerir; CSV canlı örnekler ve pil içindir, diğer türlerin kendi CSV'leri var.")}</p>
      <div class="row"><a class="btn ghost" href="/v1/export.csv" download>${T("Download CSV", "CSV indir")}</a><a class="btn ghost" href="/v1/export.json" download>${T("Download JSON", "JSON indir")}</a></div>
      <p class="small muted">${T("Other CSVs", "Diğer CSV'ler")}: <a href="/v1/export.csv?type=minute" download>${T("minutes", "dakikalar")}</a>, <a href="/v1/export.csv?type=sleep" download>${T("sleep", "uyku")}</a>, <a href="/v1/export.csv?type=score" download>${T("scores", "skorlar")}</a>.</p>
    </div>
    <div class="span2">
      <h3>${T("Webhooks", "Webhook'lar")}</h3>
      <p class="muted">${T("After every sync, your data also goes to your own server in a signed request. The address must start with https://, and you can add up to", "Her senkronizasyondan sonra veri, imzalı bir istekle kendi sunucuna da gönderilir. Adres https:// ile başlamalı; en fazla")} ${MAX_WEBHOOKS} ${T("addresses. The", "adres ekleyebilirsin. İmzayı doğrulamayı")} <a href="${localPath(lang, "/docs")}#imza">${T("API docs", "API belgesi")}</a> ${T("explain how to verify the signature.", "anlatıyor.")}</p>
      ${hookItems.length ? html`<ul id="wh-list" class="hooks">${hookItems}</ul>` : html`<p class="small muted">${T("No webhooks yet.", "Henüz webhook yok.")}</p>`}
      ${canAddHook
        ? html`<form id="wh-form" class="stack" autocomplete="off">
        <div><label for="wh-url">${T("Address", "Adres")}</label><input id="wh-url" name="url" type="url" placeholder="${T("https://example.com/freeband", "https://ornek.com/freeband")}" required></div>
        <button type="submit">${T("Add webhook", "Webhook ekle")}</button>
        <p id="wh-out" class="small" role="status"></p>
      </form>`
        : html`<p class="muted small">${T("You can add up to", "En fazla")} ${MAX_WEBHOOKS} ${T("webhooks. Delete one to add a new one.", "webhook ekleyebilirsin. Yenisi için önce birini sil.")}</p>`}
      <div id="wh-created" hidden>
        <p>${T("Webhook added. Copy this secret now; it won't be shown again. Your server checks the signature of incoming requests with it.", "Webhook eklendi. Bu gizli değeri şimdi kopyala; bir daha gösterilmeyecek. Sunucun gelen isteklerin imzasını bununla doğrular.")}</p>
        <code id="wh-secret" class="secret"></code>
        <div class="row"><button type="button" id="wh-copy">${T("Copy", "Kopyala")}</button><button type="button" class="ghost" id="wh-done">${T("Done", "Tamam")}</button></div>
      </div>
    </div>
  </div>
</section>

<section>
  <h2>${T("Account.", "Hesap.")} <span class="muted">${T("Renew your key, or delete everything.", "Anahtarını yenile ya da her şeyi sil.")}</span></h2>
  <div class="grid g2">
    <div>
      <h3>${T("Access key", "Erişim anahtarı")}</h3>
      <p class="muted">${T("The app sends your data with this key. If you think someone else has it, make a new one.", "Uygulama veriyi bu anahtarla gönderir. Anahtarın başkasının eline geçtiğini düşünüyorsan yenisini oluştur.")}</p>
      <button type="button" class="ghost" id="rot-start">${T("Make a new key", "Yeni anahtar oluştur")}</button>
      <div id="rot-confirm" class="confirm" hidden>
        ${lang === "en" ? html`<p>The old key stops working right away and sessions in other browsers end. The app can't send data until you paste the new key into <strong>Settings → Web access → Enter API key</strong> in Freeband on your phone.</p>` : html`<p>Eski anahtar hemen çalışmaz olur ve diğer tarayıcılardaki oturumlar kapanır. Yeni anahtarı telefonda Freeband'de <strong>Ayarlar → Web erişimi → API anahtarını gir</strong> alanına yapıştırana kadar uygulama veri gönderemez.</p>`}
        <div class="row"><button type="button" id="rot-go">${T("Make the new key", "Yeni anahtarı oluştur")}</button><button type="button" class="ghost" id="rot-cancel">${T("Cancel", "Vazgeç")}</button></div>
        <p id="rot-out" class="small" role="status"></p>
      </div>
      <div id="rot-result" hidden>
        ${lang === "en" ? html`<p>This is your new key. Copy it now; it won't be shown again. Open Freeband on your phone and paste it into <strong>Settings → Web access → Enter API key</strong> (in Turkish: Ayarlar → Web erişimi → API anahtarını gir).</p>` : html`<p>Yeni anahtarın bu. Şimdi kopyala; bir daha gösterilmeyecek. Telefonda Freeband'i aç ve <strong>Ayarlar → Web erişimi → API anahtarını gir</strong> alanına yapıştır (İngilizce arayüzde Settings → Web access → Enter API key).</p>`}
        <code id="rot-token" class="secret"></code>
        <button type="button" id="rot-copy">${T("Copy", "Kopyala")}</button>
      </div>
    </div>
    <div>
      <h3>${T("Delete account", "Hesabı sil")}</h3>
      <p class="muted">${T("Your account and all your samples, minute, sleep and score records, band records, webhooks and sessions on this server are deleted for good. The data on your phone isn't touched.", "Hesabın ve bu sunucudaki tüm örneklerin, dakika, uyku ve skor kayıtların, bant kayıtların, webhook'ların ve oturumların kalıcı olarak silinir. Telefondaki veriye dokunulmaz.")}</p>
      <button type="button" class="ghost danger" id="del-start">${T("Delete account", "Hesabı sil")}</button>
      <div id="del-confirm" class="confirm" hidden>
        ${lang === "en" ? html`<label for="del-input">Type <strong>delete</strong> to confirm</label>` : html`<label for="del-input">Onaylamak için <strong>sil</strong> yaz</label>`}
        <input id="del-input" class="wide" type="text" autocomplete="off" spellcheck="false">
        <div class="row"><button type="button" class="danger" id="del-go" disabled>${T("Delete the account for good", "Hesabı kalıcı olarak sil")}</button><button type="button" class="ghost" id="del-cancel">${T("Cancel", "Vazgeç")}</button></div>
        <p id="del-out" class="small" role="status"></p>
      </div>
    </div>
  </div>
</section>
`;

  return render(c, "Panel", body, {
    lang,
    alternates: alternates("/app"),
    script: APP_JS,
    signedIn: true,
    actions: html`<a class="navlink" href="${localPath(lang, "/docs")}">${T("API docs", "API belgesi")}</a><button type="button" class="ghost sm" id="signout">${T("Sign out", "Çıkış yap")}</button>`,
  });
});
}

// ---------------------------------------------------------------------------

for (const lang of ["en", "tr"] as const) {
  pages.get(localPath(lang, "/docs"), async (c) => {
    const signedIn = (await pageSession(c)) !== null;
    const suffix = lang === "en" ? "" : `-${lang}`;
    return render(c, DOCS_TITLE[lang], docsBody(new URL(c.req.url).origin, lang), {
      analytics: true,
      signedIn,
      lang,
      alternates: alternates("/docs"),
      description: lang === "en"
        ? "Freeband's REST API and signed webhooks: authentication, sending and reading data, minutes, sleep, scores, export."
        : "Freeband'in REST API'si ve imzalı webhook'ları: kimlik doğrulama, veri gönderme ve okuma, dakikalar, uyku, skorlar, dışa aktarma.",
      og: og(c, localPath(lang, "/docs"), `og-home${suffix}.png`, HOME_IMAGE_ALT[lang]),
    });
  });
}
