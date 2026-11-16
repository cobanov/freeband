// The public home page in English ("/") and Turkish ("/tr"): the product first
// (one line, the app screens, two actions), then three short sections.

import { html, raw, type Safe } from "./html";
import { localPath, type Lang, type Text } from "./i18n";
import { GITHUB_URL } from "./layout";

export const HOME_TITLE: Text = {
  en: "Freeband · Xiaomi Smart Band 10, no account",
  tr: "Freeband · Xiaomi Smart Band 10, hesapsız",
};

export const HOME_DESCRIPTION: Text = {
  en: "Freeband is an iPhone app that reads the Xiaomi Smart Band 10 and 10 Pro without Mi Fitness or a Xiaomi account. Your data stays on your phone.",
  tr: "Freeband, Xiaomi Smart Band 10 ve 10 Pro'yu Mi Fitness ve Xiaomi hesabı olmadan okuyan bir iPhone uygulaması. Verin telefonunda kalır.",
};

export const HOME_IMAGE_ALT: Text = {
  en: "The Today and Recovery screens of the Freeband app",
  tr: "Freeband uygulamasının Bugün ve Toparlanma ekranları",
};

interface Shot {
  file: string;
  name: Text;
  alt: Text;
}

const SHOTS: Shot[] = [
  {
    file: "today",
    name: { en: "Today", tr: "Bugün" },
    alt: {
      en: "Today screen: the day's verdict, the Sleep, Recovery and Strain arcs, and rows for steps, resting heart rate and sleep.",
      tr: "Bugün ekranı: günün hükmü; Uyku, Toparlanma ve Yük yayları; adım, dinlenik nabız ve uyku satırları.",
    },
  },
  {
    file: "score-recovery",
    name: { en: "Recovery", tr: "Toparlanma" },
    alt: {
      en: "Recovery detail: the score, a one-line explanation, and contributor rows for heart rate variability and resting heart rate against their usual range.",
      tr: "Toparlanma ayrıntısı: skor, tek satırlık açıklama, nabız değişkenliği ve dinlenik nabız katkı satırları, normale göre konumlarıyla.",
    },
  },
  {
    file: "sleep",
    name: { en: "Sleep", tr: "Uyku" },
    alt: {
      en: "Sleep screen: time asleep, bed and wake times, efficiency, and a timeline of awake, REM, light and deep stages with their durations.",
      tr: "Uyku ekranı: uyku süresi, yatış ve kalkış, verimlilik; uyanık, REM, hafif ve derin evrelerin zaman çizelgesi ve süreleri.",
    },
  },
  {
    file: "band",
    name: { en: "Band", tr: "Bant" },
    alt: {
      en: "Band screen: a drawing of the Band 10 Pro with its battery and last sync, and buttons to sync, find, notify and start live heart rate.",
      tr: "Bant ekranı: Band 10 Pro çizimi, pil ve son senkron; senkronla, bul, bildir ve canlı nabız düğmeleri.",
    },
  },
];

interface Card {
  title: string;
  text: string;
  range?: string;
  wide?: boolean;
}

interface Copy {
  h1: string;
  lede: string;
  story: string;
  guide: string;
  shotsCaption: string;
  noAccount: { h: string; p: string; cards: Card[] };
  scores: { h: string; p: string; cards: Card[] };
  status: { h: string; line: string; lineSoon: string; p: Safe; join: string };
}

const COPY: Record<Lang, Copy> = {
  en: {
    h1: "An iPhone app for the Xiaomi Smart Band 10, no account needed",
    lede: "Freeband reads your band without Mi Fitness or a Xiaomi account and works out your scores on the phone. Your data stays on your phone.",
    story: "How we did it",
    guide: "Try it yourself",
    shotsCaption: "Screens show demo data.",
    noAccount: {
      h: "No Mi Fitness, no account",
      p: "Freeband talks to the band directly over Bluetooth. There's no account to create; your steps, heart rate, sleep and scores stay on your phone.",
      cards: [
        { title: "The key stays on your phone", text: "Freeband reads the band's key once from Mi Fitness's folder on the phone and keeps it in the Keychain. It's never sent anywhere." },
        { title: "Your history stays on the band", text: "Freeband never acknowledges the band's files (no ACK), so the band doesn't delete your history." },
        { title: "Mi Fitness once, at setup", text: "A brand-new band still needs Mi Fitness for pairing, because the key is created on Xiaomi's server." },
      ],
    },
    scores: {
      h: "Your own scores, worked out in the open",
      p: "Scores are calculated on the phone from the band's raw data. Each one shows why it has that value, through its contributors, and how far to trust it, through a confidence level.",
      cards: [
        { title: "Sleep", range: "0–100", text: "Duration, efficiency, deep sleep, REM, restfulness, regularity and the overnight heart rate dip." },
        { title: "Recovery", range: "0–100", text: "Heart rate variability, resting heart rate, sleep and yesterday's strain, against your own last 14 days." },
        { title: "Strain", range: "0–21", text: "Minutes in heart rate zones based on your heart rate reserve. Not good or bad, just how much." },
        { title: "Confidence", wide: true, text: "High, medium, low or none, always with a reason, such as “no RR data” or “5 of 14 nights in the baseline”." },
      ],
    },
    status: {
      h: "Status",
      line: "Public beta on TestFlight",
      lineSoon: "Public beta on TestFlight soon, once Apple has reviewed the first build",
      p: html`Freeband isn't on the App Store yet. The source code is <a href="${GITHUB_URL}">on GitHub</a>, <a href="/story">How we did it</a> tells how the band was worked out, and <a href="/guide">Try it yourself</a> shows how to set it up with your own band.`,
      join: "Join the beta on TestFlight",
    },
  },
  tr: {
    h1: "Xiaomi Smart Band 10 için hesapsız bir iPhone uygulaması",
    lede: "Freeband bandını Mi Fitness ve Xiaomi hesabı olmadan okur, skorlarını telefonda hesaplar. Verin telefonunda kalır.",
    story: "Nasıl yaptık",
    guide: "Kendin dene",
    shotsCaption: "Ekranlar demo veriyle.",
    noAccount: {
      h: "Mi Fitness'sız, hesapsız",
      p: "Freeband bandla Bluetooth üzerinden doğrudan konuşur. Hesap açmazsın; adım, nabız, uyku ve skorlar telefonda kalır.",
      cards: [
        { title: "Anahtar telefonda", text: "Bandın anahtarını Mi Fitness'ın telefondaki klasöründen bir kez okur ve Keychain'e yazar. Anahtar hiçbir yere gönderilmez." },
        { title: "Veri bantta kalır", text: "Freeband dosyaları onaylamaz (ACK göndermez), bu yüzden bant geçmiş veriyi silmez." },
        { title: "Kurulumda bir kez Mi Fitness", text: "Sıfır bir bandı eşlemek için Mi Fitness şart, çünkü anahtar Xiaomi sunucusunda üretiliyor." },
      ],
    },
    scores: {
      h: "Kendi skorların, açık hesapla",
      p: "Skorlar telefonda, bandın ham verisinden hesaplanır. Her skor neden o değerde olduğunu katkı satırlarıyla, ne kadar güvenilir olduğunu güven düzeyiyle gösterir.",
      cards: [
        { title: "Uyku", range: "0–100", text: "Süre, verimlilik, derin uyku, REM, huzur, düzen ve gece nabız düşüşü." },
        { title: "Toparlanma", range: "0–100", text: "Nabız değişkenliği, dinlenik nabız, uyku ve dünkü yük; son 14 günlük normaline göre." },
        { title: "Yük", range: "0–21", text: "Nabız rezervine göre bölgelerde geçen dakikalar. İyi ya da kötü değil, yalnız ne kadar." },
        { title: "Güven", wide: true, text: "Yüksek, orta, düşük ya da yok; her zaman gerekçesiyle, örneğin “RR yok” ya da “bazalde 5/14 gece”." },
      ],
    },
    status: {
      h: "Durum",
      line: "TestFlight'ta herkese açık beta",
      lineSoon: "Apple ilk build'i inceleyince TestFlight'ta herkese açık beta",
      p: html`Freeband henüz App Store'da değil. Kaynak kodu <a href="${GITHUB_URL}">GitHub'da</a>, bandın nasıl çözüldüğü <a href="/tr/story">Nasıl yaptık</a> sayfasında, kendi bandınla nasıl kuracağın <a href="/tr/guide">Kendin dene</a> sayfasında.`,
      join: "TestFlight'ta betaya katıl",
    },
  },
};

function card(c: Card): Safe {
  const head = c.range
    ? html`<div class="score-head"><h3>${c.title}</h3><span class="range">${c.range}</span></div>`
    : html`<h3>${c.title}</h3>`;
  return html`<li class="card${c.wide ? " wide" : ""}">${head}<p>${c.text}</p></li>`;
}

export function homeBody(o: { lang: Lang; testflight: string }): Safe {
  const t = COPY[o.lang];
  const suffix = o.lang === "en" ? "" : `-${o.lang}`;
  return html`
<section class="hero">
  <h1>${t.h1}</h1>
  <p class="lede">${t.lede}</p>
  <div class="actions"><a class="btn" href="${localPath(o.lang, "/story")}">${t.story}</a><a class="btn ghost" href="${localPath(o.lang, "/guide")}">${t.guide}</a><a class="btn ghost" href="${GITHUB_URL}">GitHub</a></div>
  <figure class="stage">
    <ul class="shots">${SHOTS.map(
      (s, i) =>
        html`<li><img src="/img/${s.file}${suffix}.webp" width="600" height="1300" alt="${s.alt[o.lang]}" ${i === 0 ? "" : raw('loading="lazy" ')}decoding="async"><span>${s.name[o.lang]}</span></li>`,
    )}</ul>
    <figcaption>${t.shotsCaption}</figcaption>
  </figure>
</section>

<section class="sect">
  <header>
    <h2>${t.noAccount.h}</h2>
    <p>${t.noAccount.p}</p>
  </header>
  <ul class="cards c3">${t.noAccount.cards.map(card)}</ul>
</section>

<section class="sect">
  <header>
    <h2>${t.scores.h}</h2>
    <p>${t.scores.p}</p>
  </header>
  <ul class="cards c3">${t.scores.cards.map(card)}</ul>
</section>

<section class="sect">
  <header>
    <h2>${t.status.h}</h2>
  </header>
  <div class="card">
    <p class="status-line"><span class="dot" aria-hidden="true"></span>${o.testflight ? t.status.line : t.status.lineSoon}</p>
    <p>${t.status.p}</p>
    ${o.testflight ? html`<div class="actions note"><a class="btn" href="${o.testflight}">${t.status.join}</a></div>` : ""}
  </div>
</section>`;
}
