// Page shell and the single stylesheet (docs/design-v3-spec.md §6: Tesla
// language, light and dark from the generated tokens, Open Sauce 400/500,
// cards on surface tone, blue only on primary buttons, colour-only motion).
// Everything inline is covered by the per-response CSP nonce.

import { html, raw, type Safe } from "./html";
import { localPath, type Lang } from "./i18n";
import { COLOR_VARS, TOKEN_CSS } from "./tokens";

export const GITHUB_URL = "https://github.com/cobanov/freeband";

const FONT = (weight: number, file: string): string =>
  `@font-face{font-family:"Open Sauce Sans";font-style:normal;font-weight:${weight};font-display:swap;src:url(/fonts/OpenSauceSans-${file}.woff2) format("woff2")}`;

const CSS = `
${FONT(400, "Regular")}${FONT(500, "Medium")}
${TOKEN_CSS}
:root{
  --code:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace;
  --gut:var(--space-gutter);
  --nav-h:56px;
  /* secondary buttons and fields: one step off the surface they sit on */
  --btn-2:var(--surface);--btn-2-card:var(--canvas);--field:var(--surface);--field-card:var(--canvas);
  --motion:color var(--duration-standard) var(--ease-standard),background-color var(--duration-standard) var(--ease-standard),text-decoration-color var(--duration-standard) var(--ease-standard),border-color var(--duration-standard) var(--ease-standard);
}
@media (prefers-color-scheme:dark){:root{--btn-2:var(--raised);--btn-2-card:var(--raised)}}
@media (min-width:720px){:root{--gut:32px}}
@media (min-width:1200px){:root{--gut:48px}}
@media (prefers-reduced-motion:reduce){:root{--motion:none}*,*::before,*::after{animation:none!important;transition:none!important}}
*,*::before,*::after{box-sizing:border-box}
html{background:var(--canvas);-webkit-text-size-adjust:100%;text-size-adjust:100%;scroll-padding-top:calc(var(--nav-h) + 16px)}
body{margin:0;min-height:100vh;min-height:100dvh;display:flex;flex-direction:column;background:var(--canvas);color:var(--text-body);font:var(--type-body);-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
::selection{background:var(--text-primary);color:var(--canvas)}
[hidden]{display:none!important}
.sr{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}

/* type: two weights, sentence case, tracking 0 */
h1{font:var(--type-title);color:var(--text-primary);margin:0 0 16px;text-wrap:balance}
h2{font:500 22px/28px var(--font-sans);color:var(--text-primary);margin:0 0 16px;text-wrap:balance}
h3{font:var(--type-headline);color:var(--text-primary);margin:0 0 8px}
@media (min-width:720px){h1{font:var(--type-figure-l)}h2{font:var(--type-title)}}
h2 .muted{color:var(--text-secondary)}
p,ul,ol{margin:0 0 16px;max-width:64ch}
li{margin:0 0 8px}
ul{padding-left:20px}
li::marker{color:var(--text-tertiary)}
strong{font-weight:500;color:var(--text-primary)}
a{color:var(--text-primary);text-decoration:underline;text-decoration-color:var(--hairline-strong);text-decoration-thickness:1px;text-underline-offset:3px;transition:var(--motion)}
a:hover{text-decoration-color:currentColor}
.muted{color:var(--text-secondary)}
.small{font:var(--type-subhead)}
.label{display:block;font:var(--type-caption);font-weight:500;color:var(--text-secondary);margin:0 0 8px}
.lede{font:var(--type-body);color:var(--text-secondary)}
@media (min-width:720px){.lede{font-size:18px;line-height:26px}}
:focus-visible{outline:2px solid var(--text-primary);outline-offset:2px}

/* code */
code,pre{font-family:var(--code);font-size:13px}
code{overflow-wrap:anywhere;color:var(--text-primary)}
p code,li code{font-size:.85em;background:var(--field);border-radius:var(--radius-control);padding:2px 6px}
pre{overflow-x:auto;padding:16px;margin:0 0 24px;background:var(--surface);border-radius:var(--radius-card);line-height:1.55;max-width:100%;color:var(--text-body)}
pre code{color:inherit}

/* shell */
.wrap{max-width:1200px;margin:0 auto;padding:0 var(--gut);width:100%}
header.nav{position:sticky;top:0;z-index:10;background:var(--canvas);background:color-mix(in srgb,var(--canvas) 75%,transparent);-webkit-backdrop-filter:saturate(180%) blur(20px);backdrop-filter:saturate(180%) blur(20px)}
@media (prefers-reduced-transparency:reduce){header.nav{background:var(--canvas);-webkit-backdrop-filter:none;backdrop-filter:none}}
.nav-in{display:flex;align-items:center;justify-content:space-between;gap:16px;height:var(--nav-h)}
.brand{display:inline-flex;align-items:center;height:40px;font:var(--type-headline);font-size:19px;color:var(--text-primary);text-decoration:none}
.links{display:none;align-items:center;gap:4px}
.navlink{display:inline-flex;align-items:center;height:40px;padding:0 12px;border-radius:var(--radius-control);font:var(--type-button);font-size:14px;color:var(--text-primary);text-decoration:none;white-space:nowrap;cursor:pointer;transition:var(--motion)}
.navlink:hover,.navlink[aria-current=page],.menu[open] summary{background:var(--surface)}
.menu summary{list-style:none;-webkit-user-select:none;user-select:none}
.menu summary::-webkit-details-marker{display:none}
.menu-panel{position:absolute;left:0;right:0;top:var(--nav-h);display:flex;flex-direction:column;gap:2px;padding:8px var(--gut) 16px;background:var(--canvas);border-bottom:1px solid var(--hairline)}
.menu-panel .navlink{height:48px;font-size:16px}
.nav-right{display:flex;align-items:center;gap:4px}
.lang{position:relative}
.lang summary{list-style:none;gap:6px;-webkit-user-select:none;user-select:none}
.lang summary::-webkit-details-marker{display:none}
.lang[open] summary{background:var(--surface)}
.lang .globe{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.5}
.lang-panel{position:absolute;right:0;top:calc(100% + 4px);min-width:160px;display:flex;flex-direction:column;gap:2px;padding:6px;background:var(--raised);border:1px solid var(--hairline);border-radius:var(--radius-card);z-index:20}
.lang-panel a{display:flex;align-items:center;justify-content:space-between;height:40px;padding:0 12px;border-radius:var(--radius-control);color:var(--text-primary);text-decoration:none;font-size:15px}
.lang-panel a:hover{background:var(--surface)}
.lang-panel a[aria-current=true]::after{content:"✓";color:var(--text-secondary)}
@media (min-width:720px){.links{display:flex}.menu{display:none}}
main.wrap{display:block;flex:1 0 auto;padding-top:32px;padding-bottom:80px}
@media (min-width:720px){main.wrap{padding-top:48px;padding-bottom:112px}}
main.wrap>*+section{margin-top:64px}
@media (min-width:720px){main.wrap>*+section{margin-top:96px}}
footer.foot{border-top:1px solid var(--hairline)}
.foot-in{display:flex;flex-direction:column;gap:16px;padding-top:24px;padding-bottom:32px;font:var(--type-subhead);color:var(--text-secondary)}
.foot-in p{margin:0;max-width:60ch}
.foot-in nav{display:flex;gap:0 24px;flex-wrap:wrap}
.foot-in a{display:inline-block;padding:10px 0;color:var(--text-secondary);text-decoration:none}
.foot-in a:hover{color:var(--text-primary)}
@media (min-width:960px){.foot-in{flex-direction:row;justify-content:space-between;align-items:center;gap:48px}.foot-in nav{flex:none}}

/* controls: 40 px, radius 4, only the primary is blue */
button,.btn{-webkit-appearance:none;appearance:none;display:inline-flex;align-items:center;justify-content:center;gap:8px;height:var(--size-hub-button);padding:0 20px;margin:0;font:var(--type-button);white-space:nowrap;text-decoration:none;cursor:pointer;border:0;border-radius:var(--radius-control);background:var(--action);color:var(--on-action);transition:var(--motion)}
button:hover,.btn:hover{background:var(--action-pressed);color:var(--on-action)}
button.ghost,.btn.ghost{background:var(--btn-2);color:var(--text-primary)}
button.ghost:hover,.btn.ghost:hover{background:var(--hairline);color:var(--text-primary)}
[role=status]:empty{display:none}

/* cards: radius 12, no border, separated by surface tone */
.card,.box{--btn-2:var(--btn-2-card);--field:var(--field-card)}
.card{background:var(--surface);border-radius:var(--radius-card);padding:var(--space-card-padding);margin:0}
@media (min-width:720px){.card{padding:var(--space-m)}}
.card p:last-child,.card ul:last-child{margin-bottom:0}
.cards{display:grid;grid-template-columns:minmax(0,1fr);gap:8px;list-style:none;margin:0;padding:0;max-width:none}
@media (min-width:720px){.cards.c2{grid-template-columns:repeat(2,minmax(0,1fr))}.cards.c3{grid-template-columns:repeat(3,minmax(0,1fr))}}
.cards>li{margin:0}
.note{margin-top:16px}
.banner{padding:12px 16px;margin:0 0 32px;background:var(--surface);border-radius:var(--radius-card);color:var(--text-primary);max-width:none}

/* home */
.hero{text-align:center;padding-top:8px}
.hero h1{max-width:22ch;margin:0 auto 16px}
.hero .lede{max-width:44ch;margin:0 auto 24px}
.actions{display:flex;gap:8px;flex-wrap:wrap}
.hero .actions{justify-content:center}
.actions .btn{min-width:150px}
@media (min-width:720px){.hero{padding-top:24px}.hero h1{max-width:26ch}.actions .btn{min-width:200px}}
@media (min-width:960px){.hero h1{font:var(--type-figure-xl);line-height:62px;margin-bottom:24px}.hero .lede{margin-bottom:32px}}
.stage{margin:40px 0 0;padding:24px 0 16px;background:var(--surface);border-radius:var(--radius-card);max-width:none}
.shots{list-style:none;margin:0;padding:0 16px;display:flex;gap:12px;overflow-x:auto;scroll-snap-type:x mandatory;scrollbar-width:none;max-width:none}
.shots::-webkit-scrollbar{display:none}
.shots li{flex:0 0 62%;margin:0;scroll-snap-align:center;text-align:center}
.shots img{display:block;width:100%;height:auto;border-radius:var(--radius-card);background:var(--canvas)}
.shots span{display:block;margin-top:12px;font:var(--type-subhead);color:var(--text-primary)}
.stage figcaption{margin:16px 16px 0;font:var(--type-caption);color:var(--text-secondary);text-align:center}
@media (min-width:600px){.shots li{flex-basis:40%}}
@media (min-width:960px){.stage{padding:40px 0 24px}.shots{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:32px;padding:0 40px;overflow:visible}}
.sect{display:grid;grid-template-columns:minmax(0,1fr);gap:8px 48px;align-items:start}
.sect>header p{color:var(--text-secondary)}
@media (min-width:960px){.sect{grid-template-columns:minmax(0,4fr) minmax(0,8fr)}.sect>header{position:sticky;top:calc(var(--nav-h) + 24px)}}
.score-head{display:flex;justify-content:space-between;align-items:baseline;gap:8px;margin-bottom:12px}
.score-head h3{margin:0}
.range{font:var(--type-subhead);font-variant-numeric:tabular-nums;color:var(--text-secondary);white-space:nowrap}
.card>p{color:var(--text-secondary)}
.card.wide{grid-column:1/-1}
.status-line{display:flex;align-items:center;gap:8px;font:var(--type-headline);color:var(--text-primary);margin:0 0 8px}
.dot{display:inline-block;width:var(--size-status-glyph);height:var(--size-status-glyph);border-radius:50%;background:var(--text-tertiary);flex:none}
.sect .actions{margin-top:16px}

/* story */
.story{max-width:760px;margin:0 auto}
.story-head{margin-bottom:48px}
.story-head .lede{margin-bottom:24px}
.refs{display:flex;flex-wrap:wrap;gap:8px;list-style:none;padding:0;margin:0;max-width:none}
.refs li{margin:0}
.refs a{display:inline-flex;align-items:center;gap:8px;height:var(--size-hub-button);padding:0 14px;border-radius:var(--radius-control);background:var(--btn-2);font:var(--type-subhead);color:var(--text-secondary);text-decoration:none;transition:var(--motion)}
.refs a:hover{background:var(--hairline);color:var(--text-primary)}
.refs code{font-size:13px;color:var(--text-primary)}
ol.timeline{list-style:none;margin:0;padding:0;max-width:none}
ol.timeline>li{position:relative;display:grid;grid-template-columns:32px minmax(0,1fr);gap:0 16px;margin:0;padding-bottom:40px}
ol.timeline>li::before{content:"";position:absolute;left:15.5px;top:40px;bottom:8px;width:1px;background:var(--hairline-strong)}
ol.timeline>li:last-child{padding-bottom:0}
ol.timeline>li:last-child::before{display:none}
.step-n{display:flex;align-items:center;justify-content:center;width:32px;height:32px;border-radius:var(--radius-control);background:var(--surface);font:var(--type-figure-s);font-size:14px;font-variant-numeric:tabular-nums;color:var(--text-primary)}
.milestone .step-n{background:var(--text-primary);color:var(--canvas)}
.step{min-width:0}
.step h2{font:var(--type-headline);line-height:32px;margin:0 0 8px}
.step ul{margin-bottom:0;list-style:disc}
.step li:last-child,.step p:last-child{margin-bottom:0}
.step p+ul,.step ul+p{margin-top:16px}
@media (min-width:720px){
  ol.timeline>li{grid-template-columns:40px minmax(0,1fr);gap:0 24px;padding-bottom:48px}
  ol.timeline>li::before{left:19.5px;top:48px}
  .step-n{width:40px;height:40px;font-size:15px}
  .step h2{font-size:20px;line-height:40px}
}
.figs{display:flex;flex-wrap:wrap;gap:16px 32px;margin:16px 0 0}
.figs div{display:flex;flex-direction:column;gap:4px}
.figs b{font:var(--type-figure-l);font-variant-numeric:tabular-nums;color:var(--text-primary)}
.figs span{font:var(--type-caption);color:var(--text-secondary)}
.diagram{position:relative;grid-column:1/-1;margin:16px 0 0;padding:12px;background:var(--surface);border-radius:var(--radius-card)}
@media (min-width:720px){.diagram{grid-column:2;padding:24px}}
.diagram svg{display:block;width:100%;height:auto;max-width:440px;margin:0 auto;overflow:visible}
.diagram figcaption{margin-top:12px;font:var(--type-caption);color:var(--text-secondary);text-align:center}
.diagram text{font-family:var(--font-sans);font-size:12px;fill:var(--text-body)}
.diagram .mono{font-family:var(--code);font-size:11.5px;fill:var(--text-primary)}
.diagram .lane{font-size:13px;font-weight:500;fill:var(--text-primary)}
.diagram .cap{font-size:11px;fill:var(--text-secondary)}
.diagram .life{stroke:var(--hairline-strong);stroke-width:1}
.diagram .msg{stroke:var(--text-secondary);stroke-width:1.5;fill:none}
.diagram .head{fill:var(--text-secondary)}
.diagram .chan{stroke:var(--text-primary);stroke-width:2;fill:none}
.diagram .chan-head{fill:var(--text-primary)}
.diagram .box{fill:var(--raised)}
.diagram .cell{fill:var(--canvas)}
.diagram .pay{fill:var(--text-primary)}
.diagram .pay-t{fill:var(--canvas)}
.story-more{margin-top:64px}
.needs{max-width:560px}
.needs h2{font:var(--type-headline);font-size:17px;margin:0 0 8px}
.needs ul{margin:0}
.step pre{margin:16px 0 0}
.step pre code{padding:0;background:none;border-radius:0;font-size:inherit}
.story-more h2{font:var(--type-headline);font-size:20px;margin-bottom:16px}
.rows{list-style:none;padding:0;margin:0;display:grid;gap:2px;border-radius:var(--radius-card);overflow:hidden;max-width:none}
.rows li{margin:0;padding:14px 16px;background:var(--surface)}
.rows a{font-weight:500}
.rows span{display:block;margin-top:2px;font:var(--type-subhead);color:var(--text-secondary)}
a.card{display:block;text-decoration:none;transition:var(--motion)}
a.card:hover{background:var(--hairline)}
a.card code{font-size:14px}
a.card p{margin:8px 0 0;font:var(--type-subhead)}

/* narrow pages */
.narrow{max-width:560px}
.box{background:var(--surface);border-radius:var(--radius-card);padding:20px 16px;margin:24px 0 16px}
@media (min-width:720px){.box{padding:24px}}

/* privacy: one row per topic */
.split{display:grid;grid-template-columns:minmax(0,1fr);gap:8px;border-top:1px solid var(--hairline);padding:28px 0;margin:0}
.split:last-child{border-bottom:1px solid var(--hairline)}
.split h2{font:var(--type-headline);font-size:20px;margin:0 0 8px}
.split h2::before{content:counter(topic,decimal-leading-zero);counter-increment:topic;display:block;font:var(--type-caption);font-weight:500;color:var(--text-secondary);margin-bottom:8px;font-variant-numeric:tabular-nums}
.topics{counter-reset:topic;margin-top:48px}
@media (min-width:960px){.split{grid-template-columns:280px minmax(0,1fr);gap:48px}}
`;

export interface OpenGraph {
  /** Absolute page URL. */
  url: string;
  /** Absolute image URL, 1200×630. */
  image: string;
  imageAlt: string;
}

export interface PageOpts {
  title: string;
  nonce: string;
  body: Safe;
  /** The visit counter; the error pages leave it off. */
  analytics?: boolean;
  /** Request path, to mark the current nav link. */
  path?: string;
  /** Meta description; also the Open Graph description. */
  description?: string;
  og?: OpenGraph;
  /** Page language; the chrome follows it. Pages without an English version stay "tr". */
  lang?: Lang;
  /** Both language versions of this page: adds the language switch and hreflang links. */
  alternates?: Record<Lang, string>;
}

const CHROME = {
  en: {
    story: "How we did it", guide: "Try it", privacy: "Privacy",
    menu: "Menu", mainNav: "Main menu", footNav: "Footer menu", language: "Language", locale: "en_US", code: "EN",
    trademark: "Freeband is an independent project and is not affiliated with Xiaomi. Xiaomi, Mi Band and Mi Fitness are trademarks of Xiaomi Inc.",
  },
  tr: {
    story: "Nasıl yaptık", guide: "Kendin dene", privacy: "Gizlilik",
    menu: "Menü", mainNav: "Ana menü", footNav: "Alt menü", language: "Dil", locale: "tr_TR", code: "TR",
    trademark: "Freeband bağımsız bir projedir, Xiaomi ile bağlantısı yoktur. Xiaomi, Mi Band ve Mi Fitness, Xiaomi Inc.'in ticari markalarıdır.",
  },
} as const;

const current = (path: string | undefined, href: string): string => (path === href ? "page" : "false");

function navLinks(o: PageOpts): Safe {
  const lang = o.lang ?? "tr";
  const s = CHROME[lang];
  const story = localPath(lang, "/story");
  const guide = localPath(lang, "/guide");
  return html`<a class="navlink" href="${story}" aria-current="${current(o.path, story)}">${s.story}</a><a class="navlink" href="${guide}" aria-current="${current(o.path, guide)}">${s.guide}</a><a class="navlink" href="${GITHUB_URL}">GitHub</a>`;
}

const GLOBE = raw(
  '<svg class="globe" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="7.5"/><path d="M2.5 10h15M10 2.5c2.1 2.1 3.2 4.6 3.2 7.5s-1.1 5.4-3.2 7.5M10 2.5C7.9 4.6 6.8 7.1 6.8 10s1.1 5.4 3.2 7.5"/></svg>',
);

/** The globe button: a small menu with both languages, each linking this page in that language. */
function languagePicker(o: PageOpts): Safe {
  if (!o.alternates) return html``;
  const lang = o.lang ?? "tr";
  const s = CHROME[lang];
  const option = (l: Lang, name: string): Safe =>
    html`<a href="${o.alternates![l]}" hreflang="${l}" lang="${l}" aria-current="${l === lang ? "true" : "false"}">${name}</a>`;
  return html`<details class="lang"><summary class="navlink" aria-label="${s.language}: ${lang === "en" ? "English" : "Türkçe"}">${GLOBE}<span aria-hidden="true">${s.code}</span></summary><div class="lang-panel" role="group" aria-label="${s.language}">${option("en", "English")}${option("tr", "Türkçe")}</div></details>`;
}

function header(o: PageOpts): Safe {
  const s = CHROME[o.lang ?? "tr"];
  const picker = languagePicker(o);
  const links = navLinks(o);
  return html`<div class="nav-right"><nav class="links" aria-label="${s.mainNav}">${links}</nav>
  <details class="menu"><summary class="navlink">${s.menu}</summary><nav class="menu-panel" aria-label="${s.mainNav}">${links}</nav></details>${picker}</div>`;
}

function meta(o: PageOpts): Safe {
  const s = CHROME[o.lang ?? "tr"];
  const alt = o.alternates && o.og
    ? html`
<link rel="alternate" hreflang="en" href="${new URL(o.alternates.en, o.og.url).href}">
<link rel="alternate" hreflang="tr" href="${new URL(o.alternates.tr, o.og.url).href}">
<link rel="alternate" hreflang="x-default" href="${new URL(o.alternates.en, o.og.url).href}">`
    : html``;
  const desc = html`${o.description ? html`<meta name="description" content="${o.description}">` : ""}${alt}`;
  if (!o.og) return desc;
  return html`${desc}
<meta property="og:type" content="website">
<meta property="og:site_name" content="Freeband">
<meta property="og:locale" content="${s.locale}">
<meta property="og:title" content="${o.title}">
${o.description ? html`<meta property="og:description" content="${o.description}">` : ""}
<meta property="og:url" content="${o.og.url}">
<meta property="og:image" content="${o.og.image}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="${o.og.imageAlt}">
<meta property="og:image:type" content="image/png">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${o.title}">
${o.description ? html`<meta name="twitter:description" content="${o.description}">` : ""}
<meta name="twitter:image" content="${o.og.image}">
<meta name="twitter:image:alt" content="${o.og.imageAlt}">`;
}

export function page(o: PageOpts): string {
  const lang = o.lang ?? "tr";
  const s = CHROME[lang];
  return html`<!doctype html>
<html lang="${lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="${COLOR_VARS.light["--canvas"]}" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="${COLOR_VARS.dark["--canvas"]}" media="(prefers-color-scheme: dark)">
<title>${o.title}</title>
${meta(o)}
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon-32.png" type="image/png" sizes="32x32">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
<link rel="preload" href="/fonts/OpenSauceSans-Regular.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/fonts/OpenSauceSans-Medium.woff2" as="font" type="font/woff2" crossorigin>
<style nonce="${o.nonce}">${raw(CSS)}</style>
${o.analytics ? html`<script async nonce="${o.nonce}" src="https://oa-c.cobanov.run/oa.js" data-key="oa_pk_WqOPR-XTWPNBRdffHmLVbIMJLfBuX51X" data-collector="https://oa-c.cobanov.run"></script>` : ""}
</head>
<body>
<header class="nav">
<div class="wrap nav-in">
  <a class="brand" href="${localPath(lang, "/")}">Freeband</a>
  ${header(o)}
</div>
</header>
<main class="wrap">
${o.body}
</main>
<footer class="foot">
<div class="wrap foot-in">
  <p>${s.trademark}</p>
  <nav aria-label="${s.footNav}"><a href="${localPath(lang, "/story")}">${s.story}</a><a href="${localPath(lang, "/guide")}">${s.guide}</a><a href="${localPath(lang, "/privacy")}">${s.privacy}</a><a href="${GITHUB_URL}">GitHub</a></nav>
</div>
</footer>
</body>
</html>`.value;
}
