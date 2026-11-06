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
.fig{font-weight:500;font-variant-numeric:tabular-nums;color:var(--text-primary);line-height:1}
.unit{font:var(--type-caption);font-weight:500;color:var(--text-secondary);margin-left:6px}
.error{color:var(--destructive)}
:focus-visible{outline:2px solid var(--text-primary);outline-offset:2px}

/* code */
code,pre,.secret{font-family:var(--code);font-size:13px}
code{overflow-wrap:anywhere;color:var(--text-primary)}
p code,li code,label code,td code{font-size:.85em;background:var(--field);border-radius:var(--radius-control);padding:2px 6px}
pre{overflow-x:auto;padding:16px;margin:0 0 24px;background:var(--surface);border-radius:var(--radius-card);line-height:1.55;max-width:100%;color:var(--text-body)}
pre code{color:inherit}
.secret{display:block;overflow-wrap:anywhere;padding:12px 14px;margin:8px 0 12px;background:var(--field);border-radius:var(--radius-control)}

/* shell */
.wrap{max-width:1200px;margin:0 auto;padding:0 var(--gut);width:100%}
header.nav{position:sticky;top:0;z-index:10;background:var(--canvas);background:color-mix(in srgb,var(--canvas) 75%,transparent);-webkit-backdrop-filter:saturate(180%) blur(20px);backdrop-filter:saturate(180%) blur(20px)}
@media (prefers-reduced-transparency:reduce){header.nav{background:var(--canvas);-webkit-backdrop-filter:none;backdrop-filter:none}}
.nav-in{display:flex;align-items:center;justify-content:space-between;gap:16px;height:var(--nav-h)}
.brand{display:inline-flex;align-items:center;height:40px;font:var(--type-headline);font-size:19px;color:var(--text-primary);text-decoration:none}
.links{display:none;align-items:center;gap:4px}
.links.show{display:flex}
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
button.danger{background:var(--destructive);color:var(--canvas)}
button.danger:hover{background:var(--low);color:var(--canvas)}
button.ghost.danger{background:var(--btn-2);color:var(--destructive)}
button.ghost.danger:hover{background:var(--hairline);color:var(--destructive)}
button.sm,.btn.sm{padding:0 14px}
.btn.sq{width:var(--size-hub-button);padding:0}
button:disabled,button:disabled:hover{opacity:.4;cursor:not-allowed;background:var(--action)}
button.danger:disabled{background:var(--destructive)}
.ico{width:10px;height:10px;flex:none;fill:none;stroke:currentColor;stroke-width:1.5}
input,select{font:var(--type-body);color:var(--text-primary);background:var(--field);border:1px solid transparent;border-radius:var(--radius-control);height:var(--size-hub-button);padding:0 12px;max-width:100%;min-width:0;transition:var(--motion)}
input:hover,input:focus{border-color:var(--hairline-strong)}
input::placeholder{color:var(--text-tertiary)}
input[type=url],input[type=password],input.wide{width:100%}
input[type=date]{font-variant-numeric:tabular-nums}
label{display:block;font:var(--type-caption);font-weight:500;color:var(--text-secondary);margin:0 0 8px}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.stack>*+*{margin-top:16px}
.confirm{margin-top:16px;padding:16px;background:var(--surface);border-radius:var(--radius-card)}
.confirm p:last-child{margin-bottom:0}
.confirm input+.row{margin-top:12px}
[role=status]:empty{display:none}

/* cards: radius 12, no border, separated by surface tone */
.card,.grid>*,.box,.confirm{--btn-2:var(--btn-2-card);--field:var(--field-card)}
.card{background:var(--surface);border-radius:var(--radius-card);padding:var(--space-card-padding);margin:0}
@media (min-width:720px){.card{padding:var(--space-m)}}
.card p:last-child,.card ul:last-child{margin-bottom:0}
.cards{display:grid;grid-template-columns:minmax(0,1fr);gap:8px;list-style:none;margin:0;padding:0;max-width:none}
@media (min-width:720px){.cards.c2{grid-template-columns:repeat(2,minmax(0,1fr))}.cards.c3{grid-template-columns:repeat(3,minmax(0,1fr))}}
.cards>li{margin:0}
.grid{display:grid;grid-template-columns:minmax(0,1fr);gap:8px;margin:0;padding:0;list-style:none;max-width:none}
.grid>*{background:var(--surface);border-radius:var(--radius-card);min-width:0;margin:0;padding:20px 16px}
@media (min-width:720px){.grid>*{padding:24px}.g2{grid-template-columns:repeat(2,minmax(0,1fr))}.g3{grid-template-columns:repeat(3,minmax(0,1fr))}.span2{grid-column:span 2}}
.grid p:last-child,.grid ul:last-child{margin-bottom:0}
ol.steps{counter-reset:step}
ol.steps>li{counter-increment:step}
ol.steps>li::before{content:counter(step,decimal-leading-zero);display:block;font:var(--type-figure-s);color:var(--text-secondary);font-variant-numeric:tabular-nums;margin-bottom:24px}
.note{margin-top:16px}
.lede+.grid,.lede+ol.grid{margin-top:40px}
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
.dot.on{background:var(--good)}
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

/* panel */
.dayhead{display:flex;justify-content:space-between;align-items:flex-end;gap:20px 32px;flex-wrap:wrap;margin-bottom:28px}
.dayhead h1{margin:0 0 8px}
.status{display:flex;align-items:center;gap:4px 20px;flex-wrap:wrap;font:var(--type-subhead);color:var(--text-secondary);margin:0}
.sync{display:inline-flex;align-items:center;gap:8px}
.picker{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.picker input{width:auto}
.devices{display:flex;flex-wrap:wrap;gap:2px;margin:0 0 28px;width:fit-content;max-width:100%;border-radius:var(--radius-control);overflow:hidden}
.devices a{flex:1 1 auto;background:var(--surface);padding:10px 12px;font:var(--type-subhead);font-weight:500;text-decoration:none;color:var(--text-secondary)}
.devices a[aria-current=true]{background:var(--hairline-strong);color:var(--text-primary)}
.devices a .muted{font-weight:400}
.board{grid-template-columns:repeat(2,minmax(0,1fr))}
.board .dialcell,.board .m-steps,.board .curvecell{grid-column:1/-1}
@media (min-width:960px){
  .board{grid-template-columns:repeat(4,minmax(0,1fr))}
  .board .dialcell{grid-column:1/3;grid-row:1/4}
  .board .m-steps,.board .m-cal,.board .m-bat{grid-column:3/5}
}
.dialcell{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:20px;padding:28px 0!important}
.empty{text-align:center;color:var(--text-secondary);margin:0 16px;max-width:36ch}
.legend{display:flex;gap:6px 18px;flex-wrap:wrap;justify-content:center;list-style:none;padding:0 16px;margin:0;font:var(--type-caption);color:var(--text-secondary);max-width:none}
.legend li{display:flex;align-items:center;gap:8px;margin:0}
.sw{display:inline-block;width:8px;height:8px}
.sw-step{background:var(--activity)}.sw-hr{background:var(--heart)}.sw-now{background:var(--text-primary)}
.sw-night{background:linear-gradient(var(--text-secondary) 0 0) 0 0/2px 2px no-repeat,linear-gradient(var(--text-secondary) 0 0) 4px 4px/2px 2px no-repeat,linear-gradient(var(--hairline-strong) 0 0) 4px 0/2px 2px no-repeat,linear-gradient(var(--hairline-strong) 0 0) 0 4px/2px 2px no-repeat}
.metric{display:flex;flex-direction:column;justify-content:space-between;gap:20px}
.metric .fig{font-size:44px}
.fact .fig{font-size:22px}
.fig.none{color:var(--text-tertiary)}
@media (max-width:479px){.m-cal .fig,.m-bat .fig{font-size:33px}}
@media (min-width:960px){.metric{min-height:150px}}
.curve{position:relative;padding-right:36px}
.curve svg{display:block;width:100%;height:112px;overflow:visible}
.curve .gl{stroke:var(--hairline-strong);stroke-width:1;fill:none}
.curve .ln{stroke:var(--heart);stroke-width:1.5;fill:none;stroke-linejoin:round}
.yl{position:absolute;right:0;font:var(--type-caption);color:var(--text-secondary);font-variant-numeric:tabular-nums;line-height:1}
.yl.hi{top:0}.yl.lo{top:100px}
.axis{display:flex;justify-content:space-between;margin-top:10px;font:var(--type-caption);color:var(--text-secondary);font-variant-numeric:tabular-nums}
.tablewrap{border-radius:var(--radius-card);overflow:hidden;background:var(--surface)}
table.days{width:100%;border-collapse:collapse;font-size:15px}
table.days th{font:var(--type-caption);font-weight:500;color:var(--text-secondary);text-align:left;padding:12px 16px;vertical-align:bottom}
table.days td{padding:11px 16px;border-top:2px solid var(--canvas);vertical-align:baseline}
table.days .n{text-align:right}
table.days td.n{font-weight:500;font-variant-numeric:tabular-nums;color:var(--text-primary)}
table.days a{text-decoration:none}
table.days a:hover{text-decoration:underline}
table.days tr[aria-current=true] td{background:var(--hairline)}
@media (max-width:559px){table.days .hide-s{display:none}table.days th,table.days td{padding-left:12px;padding-right:12px}}
ul.hooks{list-style:none;padding:0;margin:0 0 16px;max-width:none}
ul.hooks li{border-bottom:1px solid var(--hairline-strong);padding:12px 0;margin:0}
ul.hooks .url{overflow-wrap:anywhere;font-family:var(--code);font-size:13px;margin-bottom:4px;color:var(--text-primary)}
ul.hooks .row{margin-top:8px}

/* the panel's 24-hour dial: 72×72 cells at an integer (or half) pixel size per cell */
.dial{--c:4.5;display:block;width:calc(72px * var(--c));max-width:100%;height:auto;overflow:visible}
@media (min-width:480px){.dial{--c:6}}
@media (min-width:960px){.dial{--c:5.5}}
@media (min-width:1200px){.dial{--c:7}}
.dial .trk{fill:var(--hairline-strong)}
.dial .steps{fill:var(--activity)}
.dial .hr{fill:var(--heart)}
.dial .now{fill:var(--text-primary)}
.dial text{font-family:var(--font-sans);font-variant-numeric:tabular-nums}
.dial .lbl{fill:var(--text-secondary);font-size:calc(12px / var(--c));font-weight:500}
.dial .big{fill:var(--text-primary);font-size:10.5px;font-weight:500}
.dial .big.none{fill:var(--text-tertiary)}
.dial .cap{fill:var(--text-secondary);font-size:calc(12px / var(--c));font-weight:500}
.dial .live{animation:live 1.2s steps(1,end) infinite}
@keyframes live{50%{fill:var(--hairline-strong)}}

/* docs */
.doc{display:grid;grid-template-columns:minmax(0,1fr);gap:32px}
.toc{display:flex;flex-wrap:wrap;gap:2px;align-self:start;border-radius:var(--radius-card);overflow:hidden}
.toc .label{display:none}
.toc a{flex:1 1 auto;background:var(--surface);padding:10px 12px;font:var(--type-subhead);font-weight:500;color:var(--text-secondary);text-decoration:none;white-space:nowrap}
.toc a:hover{color:var(--text-primary)}
@media (min-width:960px){
  .doc{grid-template-columns:220px minmax(0,1fr);gap:56px}
  .toc{position:sticky;top:calc(var(--nav-h) + 24px);display:block;border-radius:0;border-left:1px solid var(--hairline-strong)}
  .toc .label{display:block;padding-left:16px}
  .toc a{display:block;padding:6px 16px;background:none}
}
.prose h2{margin-top:64px;padding-top:24px;border-top:1px solid var(--hairline)}
.prose h3{margin-top:32px}
.prose>h1+p{margin-top:0}

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
  script?: string;
  signedIn?: boolean;
  /** Public pages only: never the panel or the sign-in forms, which carry health data. */
  analytics?: boolean;
  /** Request path, to mark the current nav link. */
  path?: string;
  /** Header actions that replace the default nav (e.g. the panel's sign-out button). */
  actions?: Safe;
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
    story: "How we did it", guide: "Try it", docs: "API docs", signIn: "Sign in", panel: "Open panel", privacy: "Privacy",
    menu: "Menu", mainNav: "Main menu", footNav: "Footer menu", language: "Language", locale: "en_US", code: "EN",
    trademark: "Freeband is an independent project and is not affiliated with Xiaomi. Xiaomi, Mi Band and Mi Fitness are trademarks of Xiaomi Inc.",
  },
  tr: {
    story: "Nasıl yaptık", guide: "Kendin dene", docs: "API belgesi", signIn: "Giriş yap", panel: "Panele git", privacy: "Gizlilik",
    menu: "Menü", mainNav: "Ana menü", footNav: "Alt menü", language: "Dil", locale: "tr_TR", code: "TR",
    trademark: "Freeband bağımsız bir projedir, Xiaomi ile bağlantısı yoktur. Xiaomi, Mi Band ve Mi Fitness, Xiaomi Inc.'in ticari markalarıdır.",
  },
} as const;

const current = (path: string | undefined, href: string): string => (path === href ? "page" : "false");

function navLinks(o: PageOpts): Safe {
  const lang = o.lang ?? "tr";
  const s = CHROME[lang];
  const account = o.signedIn
    ? html`<a class="navlink" href="${localPath(lang, "/app")}">${s.panel}</a>`
    : html`<a class="navlink" href="${localPath(lang, "/login")}" aria-current="${current(o.path, localPath(lang, "/login"))}">${s.signIn}</a>`;
  const story = localPath(lang, "/story");
  const guide = localPath(lang, "/guide");
  return html`<a class="navlink" href="${story}" aria-current="${current(o.path, story)}">${s.story}</a><a class="navlink" href="${guide}" aria-current="${current(o.path, guide)}">${s.guide}</a><a class="navlink" href="${localPath(lang, "/docs")}" aria-current="${current(o.path, localPath(lang, "/docs"))}">${s.docs}</a><a class="navlink" href="${GITHUB_URL}">GitHub</a>${account}`;
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
  if (o.actions) return html`<div class="nav-right"><nav class="links show" aria-label="${s.mainNav}">${o.actions}</nav>${picker}</div>`;
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
  <a class="brand" href="${o.signedIn ? localPath(lang, "/app") : localPath(lang, "/")}">Freeband</a>
  ${header(o)}
</div>
</header>
<main class="wrap">
${o.body}
</main>
<footer class="foot">
<div class="wrap foot-in">
  <p>${s.trademark}</p>
  <nav aria-label="${s.footNav}"><a href="${localPath(lang, "/story")}">${s.story}</a><a href="${localPath(lang, "/guide")}">${s.guide}</a><a href="${localPath(lang, "/docs")}">${s.docs}</a><a href="${localPath(lang, "/privacy")}">${s.privacy}</a><a href="${GITHUB_URL}">GitHub</a></nav>
</div>
</footer>
${o.script ? html`<script nonce="${o.nonce}">${raw(o.script)}</script>` : ""}
</body>
</html>`.value;
}
