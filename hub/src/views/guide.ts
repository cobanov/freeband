// /guide ("Try it yourself") and /tr/guide ("Kendin dene"): how someone else sets
// Freeband up with their own band, one step after another. The app comes from the
// public TestFlight link (TESTFLIGHT_URL); building from source is a section for
// developers at the end. Keep the button names in step with the app's strings
// (Localizable.xcstrings) and the commands in step with the README.

import { html, type Safe } from "./html";
import type { Lang, Text } from "./i18n";
import { GITHUB_URL } from "./layout";

export const GUIDE_TITLE: Text = {
  en: "Try Freeband with your own band",
  tr: "Freeband'i kendi bandınla dene",
};
export const GUIDE_DESCRIPTION: Text = {
  en: "Step by step: pair the band once, install Freeband from TestFlight, read the key on your iPhone, connect, and keep Mi Fitness out of the way.",
  tr: "Adım adım: bandı bir kez eşle, Freeband'i TestFlight'tan kur, anahtarı iPhone'da oku, bağlan ve Mi Fitness'ı devre dışı bırak.",
};

interface Step {
  title: string;
  body: Safe;
  code?: string;
  /** The TestFlight step: shows the public link, or says it's on its way. */
  install?: boolean;
}

const c = (s: string): Safe => html`<code>${s}</code>`;

const CLONE = `git clone ${GITHUB_URL}
cd freeband/ios
brew install xcodegen`;
const SIGNING = `# ios/project.yml
DEVELOPMENT_TEAM: ABCDE12345                      # your team ID
PRODUCT_BUNDLE_IDENTIFIER: com.yourname.freeband  # any identifier of your own`;
const SIGNING_TR = `# ios/project.yml
DEVELOPMENT_TEAM: ABCDE12345                      # kendi ekip kimliğin
PRODUCT_BUNDLE_IDENTIFIER: com.adin.freeband      # sana ait herhangi bir kimlik`;
const GENERATE = `xcodegen generate
open Freeband.xcodeproj`;

const STEPS: Record<Lang, Step[]> = {
  en: [
    {
      title: "Pair the band with Mi Fitness, once",
      body: html`<p>If the band is already set up in Mi Fitness on this iPhone, skip this step. Otherwise pair it in Mi Fitness and let it sync once. This is the only time you need Mi Fitness: Xiaomi's server creates the band's key during pairing.</p>`,
    },
    {
      title: "Check that the key folder is there",
      body: html`<p>Open the Files app and go to On My iPhone. You should see a ${c("Mi Fitness")} folder. Freeband reads the key from it later.</p>`,
    },
    {
      title: "Install Freeband from TestFlight",
      body: html`<p>Freeband is a public beta on TestFlight, Apple's app for testing apps before they reach the App Store. Open the link below on your iPhone, install TestFlight if it asks, then tap Install.</p>`,
      install: true,
    },
    {
      title: "Read the key",
      body: html`<p>In Freeband tap <strong>Get started</strong>, then <strong>Choose folder</strong>, and go to Browse → On My iPhone → Mi Fitness → Open. Freeband finds the key there and keeps it in the iPhone's Keychain. It's never sent anywhere.</p>`,
    },
    {
      title: "Connect",
      body: html`<p>Close Mi Fitness from the app switcher, keep the band on your wrist close to the phone and tap <strong>Connect</strong>. You should see the battery and today's steps.</p>`,
    },
    {
      title: "Keep Mi Fitness out of the way",
      body: html`<p>Turn off Mi Fitness's background refresh (Settings → General → Background App Refresh), or offload the app (Settings → General → iPhone Storage → Mi Fitness → Offload App). Offloading keeps its folder, and the key with it. Otherwise Mi Fitness fetches the band's files first, and the band deletes them.</p>`,
    },
    {
      title: "Sync and give it a few nights",
      body: html`<p>Freeband syncs when you open it, if the last sync is more than 15 minutes old, and when you pull down on Today. Sleep, Recovery and Strain need a few nights to learn your normal; until then they say they're calibrating.</p>`,
    },
    {
      title: "Optional: Apple Health",
      body: html`<p>Under Band → Freeband settings → Integrations → Apple Health you can opt in to write eligible steps, heart rate and sleep stages, including local history, while Freeband is open. Freeband does not read Health data. Corrections can change its own entries; turning export off leaves them in Health. Use one exporting iPhone per band.</p><p>When building this version from source, check in Xcode that your Apple Developer team's development provisioning profile supports the HealthKit entitlement.</p>`,
    },
  ],
  tr: [
    {
      title: "Bandı bir kez Mi Fitness ile eşle",
      body: html`<p>Bant bu iPhone'daki Mi Fitness'ta zaten kuruluysa bu adımı geç. Değilse Mi Fitness'ta eşle ve bir kez senkronize olmasını bekle. Mi Fitness'a yalnız burada ihtiyacın var: bandın anahtarını eşleme sırasında Xiaomi'nin sunucusu üretiyor.</p>`,
    },
    {
      title: "Anahtar klasörünün yerinde olduğuna bak",
      body: html`<p>Dosyalar uygulamasını aç ve iPhone'umda'ya git. Orada bir ${c("Mi Fitness")} klasörü görmelisin. Freeband anahtarı birazdan buradan okuyacak.</p>`,
    },
    {
      title: "Freeband'i TestFlight'tan kur",
      body: html`<p>Freeband, TestFlight'ta herkese açık bir beta. TestFlight, Apple'ın uygulamaları App Store'a çıkmadan önce denemek için kullandığı uygulama. Aşağıdaki bağlantıyı iPhone'unda aç, isterse TestFlight'ı kur, sonra Yükle'ye dokun.</p>`,
      install: true,
    },
    {
      title: "Anahtarı oku",
      body: html`<p>Freeband'de <strong>Başlayalım</strong>'a, sonra <strong>Klasörü seç</strong>'e dokun ve Gözat → iPhone'umda → Mi Fitness → Aç yolunu izle. Freeband anahtarı orada bulur ve iPhone'un Keychain'inde saklar. Anahtar hiçbir yere gönderilmez.</p>`,
    },
    {
      title: "Bağlan",
      body: html`<p>Mi Fitness'ı uygulama değiştiriciden kapat, bant bileğinde ve telefona yakın dursun, <strong>Bağlan</strong>'a dokun. Pili ve bugünkü adımlarını görmelisin.</p>`,
    },
    {
      title: "Mi Fitness'ı devre dışı bırak",
      body: html`<p>Mi Fitness'ın arka planda yenilemesini kapat (Ayarlar → Genel → Arka Planda Uygulama Yenileme) ya da uygulamayı boşalt (Ayarlar → Genel → iPhone Saklama Alanı → Mi Fitness → Uygulamayı Boşalt). Boşaltmak klasörünü, dolayısıyla anahtarı da korur. Yoksa Mi Fitness bandın dosyalarını önce alır ve bant onları siler.</p>`,
    },
    {
      title: "Senkronize et, birkaç gece bekle",
      body: html`<p>Freeband açıldığında, son senkron 15 dakikadan eskiyse kendiliğinden senkronize olur; Bugün ekranını aşağı çekerek de senkronlayabilirsin. Uyku, Toparlanma ve Yük senin normalini öğrenmek için birkaç gece ister; o zamana kadar kalibre edildiklerini söylerler.</p>`,
    },
    {
      title: "İsteğe bağlı: Apple Health",
      body: html`<p>Bant → Freeband ayarları → Entegrasyonlar → Apple Health bölümünden uygun adım, nabız ve uyku evrelerinin, telefondaki geçmiş dahil, Freeband açıkken aktarılmasını açabilirsin. Freeband Sağlık verilerini okumaz. Düzeltmeler kendi kayıtlarını değiştirebilir; kapatmak Sağlık'taki kayıtları silmez. Her bileklik için tek iPhone kullan.</p><p>Bu sürümü kaynak koddan derlerken Apple Developer ekibinin geliştirme hazırlama profilinin HealthKit yetkisini desteklediğini Xcode'da kontrol et.</p>`,
    },
  ],
};

/** Building from source instead of TestFlight, for developers. */
const DEV_STEPS: Record<Lang, Step[]> = {
  en: [
    {
      title: "Get the code",
      body: html`<p>On a Mac with Xcode 27, clone the repository and install XcodeGen, which generates the Xcode project.</p>`,
      code: CLONE,
    },
    {
      title: "Sign it as yourself",
      body: html`<p>In ${c("ios/project.yml")}, put your own team ID and an app identifier of your own. A free Apple ID is enough; an app signed with one runs for 7 days, then you build it again.</p>`,
      code: SIGNING,
    },
    {
      title: "Generate the project and install it",
      body: html`<p>Connect your iPhone and turn on Developer Mode (Settings → Privacy &amp; Security). In Xcode, pick the iPhone as the run destination and press Run (⌘R). The first time, trust your developer certificate in Settings → General → VPN &amp; Device Management.</p>`,
      code: GENERATE,
    },
  ],
  tr: [
    {
      title: "Kodu indir",
      body: html`<p>Xcode 27 kurulu bir Mac'te repoyu klonla ve Xcode projesini üreten XcodeGen'i kur.</p>`,
      code: CLONE,
    },
    {
      title: "Kendi adınla imzala",
      body: html`<p>${c("ios/project.yml")} dosyasına kendi ekip kimliğini ve sana ait bir uygulama kimliği yaz. Ücretsiz bir Apple ID yeterli; onunla imzalanan uygulama 7 gün çalışır, sonra yeniden derlersin.</p>`,
      code: SIGNING_TR,
    },
    {
      title: "Projeyi üret ve iPhone'a kur",
      body: html`<p>iPhone'u bağla ve Geliştirici Modu'nu aç (Ayarlar → Gizlilik ve Güvenlik). Xcode'da çalıştırma hedefi olarak iPhone'u seç ve Run'a bas (⌘R). İlk seferde geliştirici sertifikana Ayarlar → Genel → VPN ve Aygıt Yönetimi'nden güven.</p>`,
      code: GENERATE,
    },
  ],
};

const LABELS = {
  en: {
    label: "Try it yourself",
    lede: "Freeband isn't on the App Store yet; it's a public beta on TestFlight. Setting it up takes about 10 minutes.",
    needs: "You need",
    needList: ["An iPhone with iOS 17 or later", "A Xiaomi Smart Band 10 or 10 Pro", "Mi Fitness, once, to pair the band"],
    join: "Join the beta on TestFlight",
    pending: "The public TestFlight link opens once Apple has reviewed the first build. Until then you can build Freeband from source, below.",
    devH: "Build it from source instead",
    devP: "For developers: a Mac with Xcode 27 and a free Apple ID. These steps replace step 3; the rest stay the same.",
    never: "Never unpair the band in Mi Fitness and never factory-reset it. Either one changes the key, and you would need Mi Fitness again to get the new one.",
    optionalH: "Optional: web access",
    optional: html`The hub on this site is invite-only, so turning on Web access in the app needs an invite code. You can also run your own hub from ${c("hub/")} in the repository (Cloudflare Workers and D1); its README walks through it.`,
    stuckH: "Stuck?",
    stuck: html`Open an issue on <a href="${GITHUB_URL}/issues">GitHub</a>. Freeband's Diagnostics screen (Band → Freeband settings → Diagnostics) has a log and a report you can attach; check them for anything personal first.`,
    repo: "Source code on GitHub",
  },
  tr: {
    label: "Kendin dene",
    lede: "Freeband henüz App Store'da değil; TestFlight'ta herkese açık bir beta. Kurulumu yaklaşık 10 dakika sürer.",
    needs: "Gerekenler",
    needList: ["iOS 17 ya da sonrası olan bir iPhone", "Bir Xiaomi Smart Band 10 ya da 10 Pro", "Bandı eşlemek için bir kez Mi Fitness"],
    join: "TestFlight'ta betaya katıl",
    pending: "Herkese açık TestFlight bağlantısı, Apple ilk build'i inceledikten sonra açılacak. O zamana kadar Freeband'i aşağıdaki gibi kaynak koddan derleyebilirsin.",
    devH: "Ya da kaynak koddan derle",
    devP: "Geliştiriciler için: Xcode 27 kurulu bir Mac ve ücretsiz bir Apple ID. Bu adımlar 3. adımın yerine geçer; gerisi aynı.",
    never: "Bandı Mi Fitness'ta asla eşleşmeden çıkarma ve fabrika ayarlarına döndürme. İkisi de anahtarı değiştirir; yenisini almak için yine Mi Fitness gerekir.",
    optionalH: "İsteğe bağlı: web erişimi",
    optional: html`Bu sitedeki hub davetle çalışıyor; uygulamada Web erişimini açmak için davet kodu gerekir. İstersen repodaki ${c("hub/")} klasöründen kendi hub'ını da kurabilirsin (Cloudflare Workers ve D1); README'si adım adım anlatıyor.`,
    stuckH: "Takıldın mı?",
    stuck: html`<a href="${GITHUB_URL}/issues">GitHub</a>'da bir issue aç. Freeband'in Tanılama ekranında (Bant → Freeband ayarları → Tanılama) ekleyebileceğin bir günlük ve rapor var; eklemeden önce kişisel bir şey içerip içermediğine bak.`,
    repo: "Kaynak kod GitHub'da",
  },
};

const pad = (n: number): string => String(n).padStart(2, "0");

export function guideBody(lang: Lang, testflight: string): Safe {
  const l = LABELS[lang];
  const install = testflight
    ? html`<p><a class="btn" href="${testflight}">${l.join}</a></p>`
    : html`<p class="small muted">${l.pending}</p>`;
  return html`
<article class="story">
  <header class="story-head">
    <p class="label">${l.label}</p>
    <h1>${GUIDE_TITLE[lang]}</h1>
    <p class="lede">${l.lede}</p>
    <div class="card needs">
      <h2>${l.needs}</h2>
      <ul>${l.needList.map((n) => html`<li>${n}</li>`)}</ul>
    </div>
  </header>

  <ol class="timeline">${STEPS[lang].map(
    (s, i) => html`
    <li>
      <span class="step-n" aria-hidden="true">${pad(i + 1)}</span>
      <div class="step"><h2><span class="sr">${i + 1}. </span>${s.title}</h2>${s.body}${s.install ? install : ""}${s.code ? html`<pre><code>${s.code}</code></pre>` : ""}</div>
    </li>`,
  )}
  </ol>

  <section class="story-more">
    <p class="banner" role="note"><strong>${l.never}</strong></p>
  </section>

  <section class="story-more" id="source">
    <h2>${l.devH}</h2>
    <p>${l.devP}</p>
    <ol class="timeline">${DEV_STEPS[lang].map(
      (s, i) => html`
      <li>
        <span class="step-n" aria-hidden="true">3${String.fromCharCode(97 + i)}</span>
        <div class="step"><h3>${s.title}</h3>${s.body}${s.code ? html`<pre><code>${s.code}</code></pre>` : ""}</div>
      </li>`,
    )}
    </ol>
  </section>

  <section class="story-more">
    <h2>${l.optionalH}</h2>
    <p>${l.optional}</p>
    <h2>${l.stuckH}</h2>
    <p>${l.stuck}</p>
    <div class="actions note"><a class="btn ghost" href="${GITHUB_URL}">${l.repo}</a></div>
  </section>
</article>`;
}
