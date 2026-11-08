// /privacy (English) and /tr/privacy (Turkish). Keep both short and accurate,
// and update them together whenever what the hub stores or who processes it changes.

import { html, type Safe } from "./html";
import type { Lang } from "./i18n";

const EN = (): Safe =>
  html`
<p class="label">privacy</p>
<h1>Privacy</h1>
<p class="lede">Mert Çobanov runs this hub for personal use and for invited friends. It isn't a company service; because it carries health data, it was built to keep as little as possible.</p>

<div class="topics">
<section class="split"><h2>Apple Health</h2><div>
<p>Apple Health export is optional and runs on the iPhone. If enabled, Freeband writes eligible steps, heart rate and sleep stages; it never reads Health data. It can update or remove its own entries when band data is corrected. Turning it off, deleting Freeband data or deleting the hub account does not delete Health entries. Health-side deletions cannot be detected. Use one exporting iPhone per band; reinstalling or switching phones can cause duplicates.</p>
</div></section>
<section class="split"><h2>Optional</h2><div>
<p>The Freeband app keeps your data on your phone. Nothing comes here unless you turn on Web access in the app. When you do, the app creates an account and sends your band's data here after every sync. Turning Web access off stops new uploads; to delete what is already here, delete the account.</p>
</div></section>
<section class="split"><h2>What is stored</h2><div>
<ul>
  <li>Account: a random account ID, the SHA-256 hash of your access key (not the key itself), your time zone, the device name given when the account was created, and when it was created.</li>
  <li>Bands: a random ID the app makes for each band (not its MAC address or serial number), the band's name and model, the app version, and when the band was first and last seen.</li>
  <li>Samples: time, steps, calories, heart rate, standing hours and battery percentage.</li>
  <li>Minute data: steps, heart rate, blood oxygen (SpO2), stress, active calories and distance for each minute.</li>
  <li>Sleep: bed and wake times, stages and their durations, number of wake-ups, efficiency, the night's lowest heart rate, SpO2 and heart rate variability (HRV).</li>
  <li>Scores: the daily sleep, recovery and strain scores the app calculates on the phone, resting heart rate, confidence levels, contributors and the algorithm version.</li>
  <li>Webhooks: the addresses you add, their encrypted secrets and the result of the last delivery.</li>
  <li>Web sessions: a hash of your browser's cookie and when it expires (30 days at most).</li>
  <li>Short-lived counters to limit abuse: a keyed hash of your IP address, not the raw IP. They are deleted within two days.</li>
</ul>
<p>Your name, email address, location, Xiaomi account and your band's encryption key are not stored here.</p>
</div></section>
<section class="split"><h2>Who can see it</h2><div>
<p>Only you can see your data, with your key or your session; accounts can't see each other's data. The person running the hub can technically access the database. Your data is never sold or shared; there are no ads, analytics or tracking tools. Pages load nothing from other sites, the font included. The only cookie is the session cookie used for signing in.</p>
</div></section>
<section class="split"><h2>Cloudflare</h2><div>
<p>The hub runs on Cloudflare Workers and Cloudflare D1. Cloudflare provides the infrastructure as a data processor: it handles requests and hosts the database. While handling requests it keeps technical logs such as the IP address and the requested URL, and deletes them within a few days. The hub never writes keys, cookies or health data to those logs.</p>
</div></section>
<section class="split"><h2>Visits</h2><div>
<p>The public pages (home, story, guide, docs and this one) count visits with OpenAnalytics, which runs on my own server. It keeps a random visitor ID in your browser's localStorage and records the pages you view, the labels of links and buttons you click, the referring site, your screen size, browser and device type, and the country and city looked up from your IP address. The IP address itself is not saved. It doesn't run on the sign-in pages or the panel. Cloudflare Web Analytics also counts page views across the site, without cookies; it sees page addresses and load times, never your health data.</p>
</div></section>
<section class="split"><h2>Webhooks</h2><div>
<p>If you add a webhook, your data is also sent to the address you chose after every sync. Once it reaches that address, its owner is responsible for it.</p>
</div></section>
<section class="split"><h2>Deleting</h2><div>
<p>Tap Delete account in the panel or call <code>DELETE /v1/account</code>. Your account, samples, minute data, sleep and score records, band records, webhooks and sessions are deleted immediately and permanently; this can't be undone. Deleted data may stay in Cloudflare D1's restore log for up to 30 more days; during that time it can't be reached from the panel or the API, and it disappears on its own when the time is up.</p>
<p>The data on your phone isn't affected; remove it from the app, or by deleting the app.</p>
</div></section>
<section class="split"><h2>Questions</h2><div>
<p>If something's wrong or you're curious about anything, write to whoever invited you, or to Mert Çobanov, who runs the hub.</p>
</div></section>
</div>
`;

const TR = (): Safe =>
  html`
<p class="label">gizlilik</p>
<h1>Gizlilik</h1>
<p class="lede">Bu hub'ı Mert Çobanov kendisi ve davet ettiği arkadaşları için işletiyor. Burası bir şirket hizmeti değil; sağlık verini taşıdığı için olabildiğince az şey tutacak şekilde yapıldı.</p>

<div class="topics">
<section class="split"><h2>Apple Health</h2><div>
<p>Apple Health aktarımı isteğe bağlıdır ve iPhone'da çalışır. Açıldığında Freeband uygun adım, nabız ve uyku evrelerini yazar; Sağlık verilerini asla okumaz. Bileklik verisi düzeltildiğinde kendi kayıtlarını güncelleyebilir veya silebilir. Aktarımı kapatmak, Freeband verilerini ya da hub hesabını silmek Sağlık kayıtlarını silmez. Sağlık'taki silmeler algılanamaz. Her bileklik için tek aktarım yapan iPhone kullan; yeniden yükleme veya telefon değiştirme yinelenen kayıtlar oluşturabilir.</p>
</div></section>
<section class="split"><h2>İsteğe bağlı</h2><div>
<p>Freeband uygulaması verini telefonda tutar. Uygulamada Web erişimini açmadıkça buraya hiçbir şey gelmez. Açtığında uygulama bir hesap oluşturur ve her senkronizasyonda bandının verisini buraya gönderir. Web erişimini kapatmak yeni gönderimi durdurur; buradaki veriyi silmek için hesabı silmen gerekir.</p>
</div></section>
<section class="split"><h2>Ne saklanır</h2><div>
<ul>
  <li>Hesap: rastgele bir hesap kimliği, erişim anahtarının SHA-256 özeti (anahtarın kendisi değil), saat dilimi, hesap açılırken verilen cihaz adı ve oluşturulma zamanı.</li>
  <li>Bantlar: uygulamanın her bant için ürettiği rastgele kimlik (MAC adresi ya da seri numarası değil), bant adı, modeli, uygulama sürümü, ilk ve son görülme zamanı.</li>
  <li>Örnekler: zaman, adım, kalori, nabız, ayakta geçen saat ve pil yüzdesi.</li>
  <li>Dakikalık veri: her dakika için adım, nabız, kandaki oksijen (SpO2), stres, aktif kalori ve mesafe.</li>
  <li>Uyku: yatış ve kalkış zamanı, evreler ve süreleri, uyanma sayısı, verimlilik, gece en düşük nabız, SpO2 ve kalp atım değişkenliği (HRV).</li>
  <li>Skorlar: uygulamanın telefonda hesapladığı günlük uyku, toparlanma ve yük skorları, dinlenik nabız, güven düzeyi, katkı satırları ve algoritma sürümü.</li>
  <li>Webhook'lar: eklediğin adresler, şifrelenmiş gizli değerleri ve son gönderimin sonucu.</li>
  <li>Web oturumları: tarayıcındaki çerezin özeti ve bitiş zamanı (en fazla 30 gün).</li>
  <li>Kötüye kullanımı sınırlamak için kısa süreli sayaçlar: IP adresinin anahtarlı özeti, ham IP değil. En geç iki gün içinde silinir.</li>
</ul>
<p>Adın, e-posta adresin, konumun, Xiaomi hesabın ya da bandının şifreleme anahtarı burada tutulmaz.</p>
</div></section>
<section class="split"><h2>Kim görebilir</h2><div>
<p>Verini yalnız anahtarınla ya da oturumunla sen görürsün; hesaplar birbirinin verisini göremez. Hub'ı işleten kişi teknik olarak veritabanına erişebilir. Verin satılmaz, kimseyle paylaşılmaz; reklam, analiz ya da izleme aracı yoktur. Sayfalar dış kaynak yüklemez, yazı tipi de buradan gelir. Tek çerez giriş için kullanılan oturum çerezidir.</p>
</div></section>
<section class="split"><h2>Cloudflare</h2><div>
<p>Hub, Cloudflare Workers ve Cloudflare D1 üzerinde çalışır. Cloudflare burada veri işleyen olarak altyapıyı sağlar: istekleri karşılar ve veritabanını barındırır. İstekleri işlerken IP adresi ve istenen adres gibi teknik kayıtlar tutar ve bunları birkaç gün içinde siler. Hub bu kayıtlara anahtar, çerez ya da sağlık verisi yazmaz.</p>
</div></section>
<section class="split"><h2>Ziyaretler</h2><div>
<p>Herkese açık sayfalar (ana sayfa, hikâye, rehber, API belgesi ve bu sayfa) ziyaretleri kendi sunucumda çalışan OpenAnalytics ile sayar. Tarayıcının localStorage'ında rastgele bir ziyaretçi kimliği tutar; gezdiğin sayfaları, tıkladığın bağlantı ve düğmelerin adlarını, geldiğin siteyi, ekran boyutunu, tarayıcı ve cihaz türünü, IP adresinden bakılan ülke ve şehri kaydeder. IP adresinin kendisi saklanmaz. Giriş sayfalarında ve panelde çalışmaz. Cloudflare Web Analytics de sitenin tamamında sayfa görüntülemelerini çerezsiz sayar; sayfa adreslerini ve yüklenme sürelerini görür, sağlık verini asla görmez.</p>
</div></section>
<section class="split"><h2>Webhook'lar</h2><div>
<p>Bir webhook eklersen verin her senkronizasyondan sonra seçtiğin adrese de gönderilir. O adrese ulaştıktan sonra veriden adresin sahibi sorumludur.</p>
</div></section>
<section class="split"><h2>Silme</h2><div>
<p>Panelde Hesabı sil'e dokun ya da <code>DELETE /v1/account</code> çağır. Hesabın, örneklerin, dakikalık veri, uyku ve skor kayıtların, bant kayıtların, webhook'ların ve oturumların hemen ve kalıcı olarak silinir; geri alınamaz. Silinen veri, Cloudflare D1'in geri yükleme kaydında en fazla 30 gün daha kalabilir; bu sürede panelden ya da API'den ulaşılamaz ve süre dolunca kendiliğinden kaybolur.</p>
<p>Telefondaki veri bundan etkilenmez; onu uygulamadan ya da uygulamayı silerek kaldırırsın.</p>
</div></section>
<section class="split"><h2>Soru</h2><div>
<p>Sorun ya da merak ettiğin bir şey olursa seni davet eden kişiye ya da hub'ı işleten Mert Çobanov'a yaz.</p>
</div></section>
</div>
`;

export const PRIVACY_TITLE: Record<Lang, string> = { en: "Privacy", tr: "Gizlilik" };

export function privacyBody(lang: Lang): Safe {
  return lang === "en" ? EN() : TR();
}
