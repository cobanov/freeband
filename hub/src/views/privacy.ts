// /privacy (English) and /tr/privacy (Turkish). Keep both short and accurate,
// and update them together whenever what the site stores or who processes it changes.

import { html, type Safe } from "./html";
import type { Lang } from "./i18n";

const EN = (): Safe =>
  html`
<p class="label">privacy</p>
<h1>Privacy</h1>
<p class="lede">Mert Çobanov runs this hub. It isn't a company service.</p>

<div class="topics">
<section class="split"><h2>What is stored</h2><div>
<p>The Freeband app keeps your data on your phone. Nothing comes here.</p>
<p>Your name, email address, location, Xiaomi account and your band's encryption key are not stored here.</p>
</div></section>
<section class="split"><h2>Cloudflare</h2><div>
<p>The hub runs on Cloudflare Workers. Cloudflare provides the infrastructure as a data processor: it handles requests. While handling requests it keeps technical logs such as the IP address and the requested URL, and deletes them within a few days.</p>
</div></section>
<section class="split"><h2>Visits</h2><div>
<p>The public pages (home, story, guide and this one) count visits with OpenAnalytics, which runs on my own server. It keeps a random visitor ID in your browser's localStorage and records the pages you view, the labels of links and buttons you click, the referring site, your screen size, browser and device type, and the country and city looked up from your IP address. The IP address itself is not saved. Cloudflare Web Analytics also counts page views across the site, without cookies; it sees page addresses and load times, never your health data.</p>
</div></section>
<section class="split"><h2>Questions</h2><div>
<p>If something's wrong or you're curious about anything, write to Mert Çobanov, who runs the hub.</p>
</div></section>
</div>
`;

const TR = (): Safe =>
  html`
<p class="label">gizlilik</p>
<h1>Gizlilik</h1>
<p class="lede">Bu hub'ı Mert Çobanov işletiyor. Burası bir şirket hizmeti değil.</p>

<div class="topics">
<section class="split"><h2>Ne saklanır</h2><div>
<p>Freeband uygulaması verini telefonda tutar. Buraya hiçbir şey gelmez.</p>
<p>Adın, e-posta adresin, konumun, Xiaomi hesabın ya da bandının şifreleme anahtarı burada tutulmaz.</p>
</div></section>
<section class="split"><h2>Cloudflare</h2><div>
<p>Hub, Cloudflare Workers üzerinde çalışır. Cloudflare burada veri işleyen olarak altyapıyı sağlar: istekleri karşılar. İstekleri işlerken IP adresi ve istenen adres gibi teknik kayıtlar tutar ve bunları birkaç gün içinde siler.</p>
</div></section>
<section class="split"><h2>Ziyaretler</h2><div>
<p>Herkese açık sayfalar (ana sayfa, hikâye, rehber ve bu sayfa) ziyaretleri kendi sunucumda çalışan OpenAnalytics ile sayar. Tarayıcının localStorage'ında rastgele bir ziyaretçi kimliği tutar; gezdiğin sayfaları, tıkladığın bağlantı ve düğmelerin adlarını, geldiğin siteyi, ekran boyutunu, tarayıcı ve cihaz türünü, IP adresinden bakılan ülke ve şehri kaydeder. IP adresinin kendisi saklanmaz. Cloudflare Web Analytics de sitenin tamamında sayfa görüntülemelerini çerezsiz sayar; sayfa adreslerini ve yüklenme sürelerini görür, sağlık verini asla görmez.</p>
</div></section>
<section class="split"><h2>Soru</h2><div>
<p>Sorun ya da merak ettiğin bir şey olursa hub'ı işleten Mert Çobanov'a yaz.</p>
</div></section>
</div>
`;

export const PRIVACY_TITLE: Record<Lang, string> = { en: "Privacy", tr: "Gizlilik" };

export function privacyBody(lang: Lang): Safe {
  return lang === "en" ? EN() : TR();
}
