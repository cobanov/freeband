// /story ("How we did it") and /tr/story ("Nasıl yaptık"): docs/STORY.md as a
// designed page, in English and Turkish. The content is inline; keep both in step
// with docs/STORY.md and keep their facts exact. Diagrams are inline SVG coloured by
// classes in layout.ts.

import { html, raw, type Safe } from "./html";
import type { Lang, Text } from "./i18n";
import { GITHUB_URL } from "./layout";

export const STORY_TITLE: Text = {
  en: "How we worked out the Xiaomi Smart Band 10",
  tr: "Xiaomi Smart Band 10'u nasıl çözdük",
};
export const STORY_DESCRIPTION: Text = {
  en: "What it took to read the Xiaomi Smart Band 10 without Mi Fitness or a Xiaomi account, step by step: the BLE channel, the key, the handshake, encrypted frames and activity files.",
  tr: "Xiaomi Smart Band 10'u Mi Fitness ve Xiaomi hesabı olmadan okumak için yaptıklarımız, adım adım: BLE kanalı, anahtar, el sıkışma, şifreli çerçeveler ve aktivite dosyaları.",
};
export const STORY_IMAGE_ALT: Text = {
  en: "The encrypted frame layout: a5 a5, type, seq, len, crc16, payload",
  tr: "Şifreli çerçeve düzeni: a5 a5, type, seq, len, crc16, payload",
};

const blob = (path: string): string => `${GITHUB_URL}/blob/main/${path}`;
const FINDINGS = blob("findings.md");
const CAPABILITIES = blob("docs/CAPABILITIES.md");
const ACTIVITY = blob("docs/ACTIVITY.md");

// Phone ↔ band handshake, drawn top to bottom so it stays readable at 390 px.
const HANDSHAKE_TEXT = {
  en: {
    label: "Handshake: the phone sends a nonce, the band answers with its nonce and an HMAC; both derive session keys from the auth key and the nonces with HKDF-SHA256; the phone sends device_type = iOS encrypted with AES-CCM; after that, messages go as protobuf encrypted with AES-128-CTR.",
    phone: "Phone", band: "Band", inputs: "auth key + nonces", keys: "session keys", ok: "the band's HMAC matched: the key is right",
  },
  tr: {
    label: "El sıkışma: telefon nonce gönderir, bant nonce ve HMAC ile yanıtlar; iki taraf auth key ve nonce'lardan HKDF-SHA256 ile oturum anahtarlarını türetir; telefon AES-CCM ile şifreli device_type = iOS gönderir; sonra mesajlar AES-128-CTR ile şifreli protobuf olarak gider.",
    phone: "Telefon", band: "Bant", inputs: "auth key + nonce'lar", keys: "oturum anahtarları", ok: "bandın HMAC'i tuttu: anahtar doğru",
  },
};

const esc = (s: string): string => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

const HANDSHAKE = (lang: Lang): Safe => {
  const s = HANDSHAKE_TEXT[lang];
  return raw(`<svg viewBox="0 0 320 304" role="img" aria-label="${esc(s.label)}">
<text class="lane" x="44" y="14" text-anchor="middle">${esc(s.phone)}</text>
<text class="lane" x="276" y="14" text-anchor="middle">${esc(s.band)}</text>
<line class="life" x1="44" y1="24" x2="44" y2="304"/>
<line class="life" x1="276" y1="24" x2="276" y2="304"/>
<text class="mono" x="160" y="48" text-anchor="middle">nonce</text>
<line class="msg" x1="44" y1="56" x2="268" y2="56"/><path class="head" d="M276 56l-9-4.5v9z"/>
<text class="mono" x="160" y="92" text-anchor="middle">nonce + HMAC</text>
<line class="msg" x1="276" y1="100" x2="52" y2="100"/><path class="head" d="M44 100l9-4.5v9z"/>
<rect class="box" x="12" y="118" width="296" height="88" rx="4"/>
<text x="160" y="137" text-anchor="middle">${esc(s.inputs)}</text>
<path class="msg" d="M160 143v9"/><path class="head" d="M160 157l-3.5-6h7z"/>
<text class="mono" x="160" y="173" text-anchor="middle">HKDF-SHA256 "miwear-auth"</text>
<path class="msg" d="M160 178v7"/><path class="head" d="M160 190l-3.5-6h7z"/>
<text x="160" y="201" text-anchor="middle">${esc(s.keys)}</text>
<text class="cap" x="52" y="226">${esc(s.ok)}</text>
<text class="mono" x="160" y="250" text-anchor="middle">device_type = iOS · AES-CCM</text>
<line class="msg" x1="44" y1="258" x2="268" y2="258"/><path class="head" d="M276 258l-9-4.5v9z"/>
<text class="mono" x="160" y="286" text-anchor="middle">protobuf · AES-128-CTR</text>
<line class="chan" x1="54" y1="294" x2="266" y2="294"/><path class="chan-head" d="M44 294l11-5.5v11z"/><path class="chan-head" d="M276 294l-11-5.5v11z"/>
</svg>`);
};

// One frame on the encrypted channel.
const FRAME_CELLS: Array<[x: number, w: number, label: string, cap: Text]> = [
  [0, 64, "a5 a5", { en: "header", tr: "başlık" }],
  [66, 40, "type", { en: "type", tr: "tür" }],
  [108, 40, "seq", { en: "sequence", tr: "sıra" }],
  [150, 46, "len", { en: "length", tr: "uzunluk" }],
  [198, 50, "crc16", { en: "checksum", tr: "sağlama" }],
];
const FRAME_TEXT = {
  en: { label: "Frame layout: the a5 a5 header, type, sequence, length, crc16 and the payload.", payload: "encrypted" },
  tr: { label: "Çerçeve düzeni: a5 a5 başlığı, tür, sıra, uzunluk, crc16 ve payload.", payload: "şifreli" },
};
const FRAME = (lang: Lang): Safe =>
  raw(`<svg viewBox="0 0 320 70" role="img" aria-label="${esc(FRAME_TEXT[lang].label)}">
${FRAME_CELLS.map(
  ([x, w, label, cap]) =>
    `<rect class="cell" x="${x}" y="4" width="${w}" height="36" rx="2"/><text class="mono" x="${x + w / 2}" y="26" text-anchor="middle">${label}</text><text class="cap" x="${x + w / 2}" y="60" text-anchor="middle">${esc(cap[lang])}</text>`,
).join("")}
<rect class="pay" x="250" y="4" width="70" height="36" rx="2"/><text class="mono pay-t" x="285" y="26" text-anchor="middle">payload</text><text class="cap" x="285" y="60" text-anchor="middle">${esc(FRAME_TEXT[lang].payload)}</text>
</svg>`);

interface Step {
  title: string;
  body: Safe;
  milestone?: boolean;
  extra?: Safe;
}

const c = (s: string): Safe => html`<code>${s}</code>`;

const STEPS_TR: Step[] = [
  {
    title: "Masa başı keşif",
    body: html`<ul>
  <li>Gadgetbridge'in (açık kaynak Android uygulaması) Xiaomi kodunu okuduk: bağlantı, kimlik doğrulama, şifreleme, komutlar, dosya formatları.</li>
  <li>AstroBox'ın (Band 10'u destekleyen bir iOS uygulaması) protobuf şemalarıyla karşılaştırdık.</li>
  <li>Sonuç: Band 10 Xiaomi'nin yeni protokolünü konuşuyor ve iPhone'da BLE üzerinden büyük olasılıkla mümkün.</li>
</ul>`,
  },
  {
    title: "Mac'ten ilk temas",
    body: html`<ul>
  <li>BLE taramasında bant Xiaomi'nin ${c("FE95")} yayınıyla göründü.</li>
  <li>Mac'ten bağlanma iki kez zaman aşımına düştü: bant yalnızca eşleştiği iPhone'u kabul ediyor.</li>
  <li>nRF Connect: bant iPhone'a bağlıyken hiç yayın yapmıyor.</li>
</ul>`,
  },
  {
    title: "iPhone'da bir test uygulaması",
    milestone: true,
    body: html`<p>iOS'un zaten bağlı tuttuğu bandı yeniden eşlemeden aldık. GATT tablosunda ${c("FE95")} servisi, ${c("005E")} (okuma) ve ${c("005F")} (yazma) karakteristikleri çıktı: BLE V2 kanalı açık. <strong>Projenin geçer/kalır anı buydu.</strong></p>`,
  },
  {
    title: "Anahtar",
    body: html`<ul>
  <li>Bant, ilk eşlemede Xiaomi sunucusunun ürettiği 16 baytlık bir anahtar (auth key) istiyor.</li>
  <li>iPhone'da bu anahtar Dosyalar → Mi Fitness klasöründe, bir önbellek veritabanının içinde duruyor.</li>
  <li>Uygulama klasörü kullanıcıya seçtiriyor, anahtarı telefonda okuyor ve Keychain'e yazıyor. Anahtar hiçbir yere gönderilmiyor.</li>
</ul>`,
  },
  {
    title: "El sıkışma",
    body: html`<ul>
  <li>Telefon ve bant rastgele sayılar (nonce) değiş tokuş ediyor.</li>
  <li>Anahtar ve bu sayılardan HKDF-SHA256 (${c('"miwear-auth"')}) ile oturum anahtarları türetiliyor. Bandın HMAC'i tutunca anahtarın doğru olduğu anlaşılıyor.</li>
  <li>Son adımda kendimizi ${c("device_type = iOS")} olarak tanıtıyoruz; bu bilgi AES-CCM ile şifreli gidiyor.</li>
</ul>`,
    extra: html`<figure class="diagram">${HANDSHAKE("tr")}<figcaption>El sıkışmadan sonra her mesaj AES-128-CTR ile şifreli protobuf.</figcaption></figure>`,
  },
  {
    title: "Şifreli kanal ve ilk komut",
    milestone: true,
    body: html`<ul>
  <li>Mesajlar ${c("a5 a5")} başlıklı, CRC16'lı çerçevelerde, AES-128-CTR ile şifrelenmiş protobuf olarak gidiyor.</li>
  <li>İlk komut pil oldu: <strong>%46</strong>. Aynı değeri standart BLE pil servisinden de okuyup şifre çözmenin doğru olduğunu doğruladık.</li>
</ul>
<div class="figs"><div><b>%46</b><span>ilk komutun cevabı: pil</span></div></div>`,
    extra: html`<figure class="diagram">${FRAME("tr")}<figcaption>Şifreli kanalda bir mesajın çerçevesi.</figcaption></figure>`,
  },
  {
    title: "Bağımsız doğrulama",
    body: html`<p>Protokol kodunu Mac'te ayrı bir Python uygulamasıyla 13 test vektörüne karşı doğruladık.</p>`,
  },
  {
    title: "Canlı veri",
    body: html`<p>Bir komutla bant canlı istatistik göndermeye başlıyor: adım, kalori, nabız. Pili korumak için 2 dakika sonra kapatıyoruz.</p>`,
  },
  {
    title: "Mi Fitness ile çakışma",
    body: html`<ul>
  <li>Aynı kanalda iki oturum olamıyor. Uygulamamız kanalı bırakmayınca Mi Fitness'ın senkronu takıldı; kanalı bırakmayı ekledik.</li>
  <li>Mi Fitness dosyaları onaylayınca (ACK) bant onları siliyor.</li>
</ul>`,
  },
  {
    title: "Diğer komutlar",
    body: html`<p>Bildirim gönderme, bandı titreterek bulma, saat eşitleme.</p>`,
  },
  {
    title: "Geçmiş veri (aktivite dosyaları)",
    body: html`<ul>
  <li>Bant bugünün ve geçmiş günlerin dosya listesini veriyor.</li>
  <li>Her dosyanın 7 baytlık bir kimliği var: zaman, saat dilimi, sürüm ve tür (dakikalık veri, günlük özet, uyku, uyku evreleri, elle ölçüm).</li>
  <li>Dosyalar parça parça geliyor, sonunda CRC32 var.</li>
  <li>Biz ACK göndermiyoruz, bandaki veri silinmiyor.</li>
</ul>`,
  },
  {
    title: "Dosya formatları",
    body: html`<ul>
  <li>Önce belgeye döktük. Sonra kodu sıfırdan yazdık: bir Python referans çözücü ve onunla birebir aynı sonucu veren bir Swift çözücü.</li>
  <li>147 test geçiyor; 37 bin bozuk dosyada bile çökmüyor.</li>
</ul>
<div class="figs"><div><b>147</b><span>test geçiyor</span></div><div><b>37 bin</b><span>bozuk dosyada çökme yok</span></div></div>`,
  },
  {
    title: "Ürün",
    body: html`<ul>
  <li>Freeband bu verilerden kendi Uyku, Toparlanma ve Yük skorlarını hesaplıyor; her skorun katkıları ve güveni görünüyor.</li>
</ul>`,
  },
  {
    title: "Açık kalanlar",
    body: html`<ul>
  <li>Gerçek bir uyku dosyası henüz doğrulanmadı.</li>
  <li>Bandın kendiliğinden gönderdiği ${c("2/110")} mesajının anlamı bilinmiyor.</li>
  <li>Sıfır bir bandı Mi Fitness olmadan eşlemek şimdilik mümkün değil, çünkü anahtar Xiaomi sunucusunda üretiliyor.</li>
</ul>`,
  },
];

const STEPS_EN: Step[] = [
  {
    title: "Desk research",
    body: html`<ul>
  <li>We read the Xiaomi code in Gadgetbridge (an open source Android app): connection, authentication, encryption, commands and file formats.</li>
  <li>We compared it with the protobuf schemas of AstroBox, an iOS app that supports the Band 10.</li>
  <li>Conclusion: the Band 10 speaks Xiaomi's new protocol, and doing this over BLE on an iPhone was very likely possible.</li>
</ul>`,
  },
  {
    title: "First contact from a Mac",
    body: html`<ul>
  <li>In a BLE scan the band showed up with Xiaomi's ${c("FE95")} advertisement.</li>
  <li>Connecting from the Mac timed out twice: the band only accepts the iPhone it is paired with.</li>
  <li>nRF Connect showed that the band doesn't advertise at all while it's connected to the iPhone.</li>
</ul>`,
  },
  {
    title: "A test app on the iPhone",
    milestone: true,
    body: html`<p>We picked up the band that iOS already keeps connected, without pairing again. Its GATT table had the ${c("FE95")} service with the ${c("005E")} (read) and ${c("005F")} (write) characteristics: the BLE V2 channel was open. <strong>This was the make-or-break moment of the project.</strong></p>`,
  },
  {
    title: "The key",
    body: html`<ul>
  <li>The band wants a 16-byte auth key that Xiaomi's server creates when the band is first paired.</li>
  <li>On an iPhone that key sits in Files → Mi Fitness, inside a cache database.</li>
  <li>The app asks you to pick that folder, reads the key on the phone and keeps it in the Keychain. The key is never sent anywhere.</li>
</ul>`,
  },
  {
    title: "The handshake",
    body: html`<ul>
  <li>The phone and the band swap random numbers (nonces).</li>
  <li>Session keys are derived from the key and those numbers with HKDF-SHA256 (${c('"miwear-auth"')}). When the band's HMAC matches, the key is right.</li>
  <li>In the last step we introduce ourselves as ${c("device_type = iOS")}, encrypted with AES-CCM.</li>
</ul>`,
    extra: html`<figure class="diagram">${HANDSHAKE("en")}<figcaption>After the handshake, every message is protobuf encrypted with AES-128-CTR.</figcaption></figure>`,
  },
  {
    title: "The encrypted channel and the first command",
    milestone: true,
    body: html`<ul>
  <li>Messages travel as AES-128-CTR encrypted protobuf, in frames that start with ${c("a5 a5")} and carry a CRC16.</li>
  <li>The first command was the battery: <strong>46%</strong>. We read the same value from the standard BLE battery service too, which proved the decryption right.</li>
</ul>
<div class="figs"><div><b>46%</b><span>the answer to the first command: battery</span></div></div>`,
    extra: html`<figure class="diagram">${FRAME("en")}<figcaption>The frame of one message on the encrypted channel.</figcaption></figure>`,
  },
  {
    title: "Independent check",
    body: html`<p>We checked the protocol code against 13 test vectors with a separate Python implementation on the Mac.</p>`,
  },
  {
    title: "Live data",
    body: html`<p>One command makes the band stream live stats: steps, calories, heart rate. We turn it off after 2 minutes to save the battery.</p>`,
  },
  {
    title: "Getting along with Mi Fitness",
    body: html`<ul>
  <li>There can't be two sessions on the same channel. When our app didn't let go of the channel, Mi Fitness's sync got stuck; we added releasing the channel.</li>
  <li>When Mi Fitness acknowledges (ACKs) the files, the band deletes them.</li>
</ul>`,
  },
  {
    title: "Other commands",
    body: html`<p>Sending notifications, finding the band by making it vibrate, setting the clock.</p>`,
  },
  {
    title: "History (activity files)",
    body: html`<ul>
  <li>The band lists the files for today and for past days.</li>
  <li>Each file has a 7-byte ID: time, time zone, version and kind (per-minute data, daily summary, sleep, sleep stages, manual readings).</li>
  <li>Files arrive in chunks and end with a CRC32.</li>
  <li>We never send the ACK, so nothing is deleted from the band.</li>
</ul>`,
  },
  {
    title: "File formats",
    body: html`<ul>
  <li>We wrote the formats down first. Then we wrote the code from scratch: a Python reference parser, and a Swift parser that gives exactly the same output.</li>
  <li>147 tests pass, and it doesn't crash even on 37,000 corrupted files.</li>
</ul>
<div class="figs"><div><b>147</b><span>tests passing</span></div><div><b>37,000</b><span>corrupted files, no crash</span></div></div>`,
  },
  {
    title: "The product",
    body: html`<ul>
  <li>From this data Freeband works out its own Sleep, Recovery and Strain scores; each score shows its contributors and how confident it is.</li>
</ul>`,
  },
  {
    title: "Still open",
    body: html`<ul>
  <li>A real sleep file hasn't been verified yet.</li>
  <li>We don't know yet what the ${c("2/110")} message, which the band sends on its own, means.</li>
  <li>Pairing a brand-new band without Mi Fitness isn't possible for now, because the key is created on Xiaomi's server.</li>
</ul>`,
  },
];

const ext = (name: string, url: string): Safe => html`<a href="${url}">${name}</a>`;
const THANKS_TR: Safe[] = [
  html`${ext("Gadgetbridge", "https://codeberg.org/Freeyourgadget/Gadgetbridge")}<span>Protokolün en ayrıntılı açık kaynak anlatımı.</span>`,
  html`${ext("AstroBox", "https://github.com/AstralSightStudios")}<span>iOS'ta BLE ve ${c("device_type = iOS")} ipucu, protobuf şemaları.</span>`,
  html`${ext("xiaomi-band-ios-export", "https://github.com/artyomxx/xiaomi-band-ios-export")}<span>Anahtarın iPhone'daki yeri.</span>`,
  html`${ext("blueband-map", "https://github.com/LordierClaw/blueband-map")}<span>Band 10'da BLE'yi deneyen açık kaynak denemelerden biri.</span>`,
  html`${ext("band9-rust-ios", "https://github.com/ireescc277-dotcom/band9-rust-ios")}<span>Band 10'da BLE'yi deneyen açık kaynak denemelerden biri.</span>`,
];

const THANKS_EN: Safe[] = [
  html`${ext("Gadgetbridge", "https://codeberg.org/Freeyourgadget/Gadgetbridge")}<span>The most detailed open source account of the protocol.</span>`,
  html`${ext("AstroBox", "https://github.com/AstralSightStudios")}<span>BLE on iOS, the ${c("device_type = iOS")} hint and the protobuf schemas.</span>`,
  html`${ext("xiaomi-band-ios-export", "https://github.com/artyomxx/xiaomi-band-ios-export")}<span>Where the key lives on an iPhone.</span>`,
  html`${ext("blueband-map", "https://github.com/LordierClaw/blueband-map")}<span>One of the open source experiments with BLE on the Band 10.</span>`,
  html`${ext("band9-rust-ios", "https://github.com/ireescc277-dotcom/band9-rust-ios")}<span>One of the open source experiments with BLE on the Band 10.</span>`,
];

const pad = (n: number): string => String(n).padStart(2, "0");

const LABELS = {
  en: {
    label: "How we did it",
    lede: "The goal: use the Xiaomi Smart Band 10 / 10 Pro with our own iPhone app, without Mi Fitness or a Xiaomi account, with the data staying on the phone.",
    refs: "Detailed documents", findings: "findings and source references", capabilities: "command map", activity: "file formats",
    thanks: "Thanks", more: "Details on GitHub", findingsCard: "Detailed findings and source references", capabilitiesCard: "Command map", activityCard: "File formats",
    source: "Source code on GitHub",
  },
  tr: {
    label: "Nasıl yaptık",
    lede: "Hedef: Xiaomi Smart Band 10 / 10 Pro'yu Mi Fitness ve Xiaomi hesabı olmadan, verisi telefonda kalan kendi iPhone uygulamamızla kullanmak.",
    refs: "Ayrıntılı belgeler", findings: "bulgular ve kaynak atıfları", capabilities: "komut haritası", activity: "dosya formatları",
    thanks: "Teşekkürler", more: "Ayrıntılar GitHub'da", findingsCard: "Ayrıntılı bulgular ve kaynak atıfları", capabilitiesCard: "Komut haritası", activityCard: "Dosya formatları",
    source: "Kaynak kod GitHub'da",
  },
};

export function storyBody(lang: Lang): Safe {
  const l = LABELS[lang];
  const steps = lang === "en" ? STEPS_EN : STEPS_TR;
  const thanks = lang === "en" ? THANKS_EN : THANKS_TR;
  return html`
<article class="story">
  <header class="story-head">
    <p class="label">${l.label}</p>
    <h1>${STORY_TITLE[lang]}</h1>
    <p class="lede">${l.lede}</p>
    <ul class="refs" aria-label="${l.refs}">
      <li><a href="${FINDINGS}"><code>findings.md</code>${l.findings}</a></li>
      <li><a href="${CAPABILITIES}"><code>CAPABILITIES.md</code>${l.capabilities}</a></li>
      <li><a href="${ACTIVITY}"><code>ACTIVITY.md</code>${l.activity}</a></li>
    </ul>
  </header>

  <ol class="timeline">${steps.map(
    (s, i) => html`
    <li class="${s.milestone ? "milestone" : ""}">
      <span class="step-n" aria-hidden="true">${pad(i + 1)}</span>
      <div class="step"><h2><span class="sr">${i + 1}. </span>${s.title}</h2>${s.body}</div>
      ${s.extra ?? ""}
    </li>`,
  )}
  </ol>

  <section class="story-more">
    <h2>${l.thanks}</h2>
    <ul class="rows">${thanks.map((t) => html`<li>${t}</li>`)}</ul>
  </section>

  <section class="story-more">
    <h2>${l.more}</h2>
    <ul class="cards c3">
      <li><a class="card" href="${FINDINGS}"><code>findings.md</code><p>${l.findingsCard}</p></a></li>
      <li><a class="card" href="${CAPABILITIES}"><code>docs/CAPABILITIES.md</code><p>${l.capabilitiesCard}</p></a></li>
      <li><a class="card" href="${ACTIVITY}"><code>docs/ACTIVITY.md</code><p>${l.activityCard}</p></a></li>
    </ul>
    <div class="actions note"><a class="btn ghost" href="${GITHUB_URL}">${l.source}</a></div>
  </section>
</article>`;
}
