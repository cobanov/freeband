# Freeband: ürün planı ve Tesla dilinde yeniden tasarım

## Bağlam

Freeband (eski BandProbe/OpenBand), Xiaomi Smart Band 10 / 10 Pro'yu Mi Fitness ve Xiaomi hesabı olmadan iPhone'dan okuyan yerel bir uygulama. Bir günde protokol çözüldü, auth + şifreli kanal, canlı adım/nabız, bildirim/titreşim, saat eşitleme, aktivite dosyası çekme, Cloudflare hub (API, webhook, web paneli) ve TestFlight hattı kuruldu. Ama ekranlar plansız büyüdü: üç kez görsel yön değişti (mavi kadran → dither → "WHOOP/Tesla" isteği), Uyku ve Geçmiş sekmeleri boş, analiz yok, yeteneklerin çoğu ya gizli (Araçlar) ya hiç yok.

Kullanıcı kodlamayı durdurdu ve şu sırayı istedi: önce **özellikler**, **ekranlarda ne görüneceği**, **yetenekler**, **akış**; sonra **Tesla tasarım dili**; ancak ondan sonra kod. Bu plan o sırayı izliyor.

Durum notu: aktivite dosyası çözücüleri Swift'e taşındı (`ios/Freeband/Band/ActivityFiles.swift`, 147/147 test, Python referansıyla birebir; 44 bin bozuk dosyada çökme yok). Kalan küçük işler: iki eksik uyku testi, BandLink ile birlikte tip kontrolü. Gerçek bant dosyalarıyla doğrulama bekliyor (Gadgetbridge'de dakikalık veri ve uyku için gerçek örnek yok).

### Kullanıcının kararları (2026-10-14)
- **Tema:** sisteme uyan, koyu öncelikli (Tesla "Auto" gibi); açık tema da birinci sınıf.
- **Dil:** İngilizce varsayılan + Türkçe (String Catalog).
- **Mi Fitness:** önce yanında çalışır (aç-oku-bırak), sonra yerini alır (arka planda bağlı oturum, dosya temizliği, telefonu bul).
- **Skorlar:** kendi şeffaf skorlarımız: Uyku 0–100, Toparlanma 0–100, Yük 0–21; her skorun katkı satırları görünür.
- **Süreç:** plan onaylanmadan kod yok; her faz kendi başına gönderilebilir ve doğrulanabilir.

### Araştırma özeti
- **Envanter:** ekranlar plansız büyüdü. Uyku sekmesi boş. Aktivite dosyaları çekiliyor ama hiç çözülmüyor. Hatalar: bant silinince/veri silinince ham dosyalar kalıyor; senkronlar arası adımlar sonraki saate yığılıyor; gün başı gece yarısı yenilenmiyor; hub ile uygulamada nabız eşiği farklı; senkron yarıda kesilince başarılı sayılıyor; web'deki anahtar yenileme metni uygulamada olmayan bir alanı gösteriyor.
- **Bant verisi:** sahada doğrulanan yalnız canlı istatistik (8/47), pil, bildirim ve bulma. Dakikalık veri, günlük özet, uyku (evre, RR) ve elle ölçümler yalnız şartnamede; gerçek Band 10 dosyası hiç yakalanmadı. RR (HRV) bilinmiyor; Toparlanma skoru buna bağlı.
- **Yetenekler (kısa oturumla, S):** alarmlar, kullanıcı bilgisi/hedefler, nabız/SpO2/stres/hareketsizlik ayarları, DND, bileği kaldırınca ekran, takvim, hatırlatıcılar, kadran listesi/değiştirme, depolama. **Bağlı oturum gerekenler:** telefonu bul, müzik, canlı antrenman, GPS. **iOS'un izin vermedikleri:** arama, başka uygulamaların bildirimleri (ANCS zaten iletiyor), SMS cevabı, sessiz anahtarı, iPhone alarmları.
- **Tesla dili:** resmî tasarım sistemi yok. Üçüncü taraf çıkarımlarına göre:
  - tek mavi aksiyon rengi `#3E6AE1`, mürekkep `#171A20`;
  - yalnız 400/500 ağırlık, büyük harf yok;
  - 8 pt aralık tabanı, köşe yarıçapı 4/12, kenarlık ve gölge yok;
  - hareket yalnız renk geçişi;
  - uygulamada: kahraman nesne (araç), hızlı aksiyon satırı, chevron'lu liste, bağlamsal bilgi (şarj yalnız takılıyken görünür).
- **Sağlık arayüzü kalıpları:** WHOOP üç skor ve derin sayfalar; Oura katkı satırları ve üç sekme; Garmin tek kelimelik hüküm; Apple Health trend oku ve fark; 7 günlük sparkline.
- **Skill'ler (onaydan sonra kurulacak):** `swiftui-pro` (Paul Hudson), `swiftui-expert-skill` (Antoine van der Lee), `swift-charts`, `ios-hig-design`; yerelde `checklist-design`, `dataviz`, `frontend-design`. Tesla'ya özgü güvenilir bir skill yok.

## 1. Özellikler (öncelik)

| P | Özellik | Veri / komut |
|---|---|---|
| P0 | Açılışta otomatik senkron, dosyaları kaydederken çözme | 2/3, 2/2, 2/78, 2/1, 8/45–47, 8/1–3 + kanal 5 |
| P0 | Uyku, Toparlanma, Yük skorları ve katkı satırları | DailyDetails, SleepDetails/Stages, DailySummary |
| P0 | Uyku gecesi detayı; nabız, aktivite, stres, SpO2 detayları | aynı dosyalar |
| P0 | Bant merkezi: pil, bilekte/şarj, bul, bildirim, canlı nabız | 2/1, 2/78, 2/18, 7/0, 8/45–47 |
| P0 | EN/TR, sistem teması, 6 hata düzeltmesi, kalibrasyon, profil (yaş, cinsiyet, boy, kilo, maks. nabız) | yerel |
| P1 | Alarmlar | 17/0,1,2,4 |
| P1 | Sağlık izleme ayarları | 8/8–15 |
| P1 | Kullanıcı bilgisi ve hedefler | 8/0 |
| P1 | Hava durumu (Open-Meteo) | 10/x |
| P1 | DND, bileği kaldırınca ekran (önce GET) | 2/22–25 |
| P1 | Uyku modu programı, kadranlar, depolama | 17/8–9, 4/0–1, 2/62 |
| P1 | 7/30/90 gün trendleri; hub'a dakikalık veri, uyku ve skor; skor kısayolları | — |
| P2 | Arka planda bağlı oturum, dosya temizliği (ACK), telefonu bul, bandın istediği hava durumu | 8/5, 2/17, 10/3 |
| P2 | Takvim, hatırlatıcı, canlı antrenman, müzik, antrenman dosyaları, HealthKit, widget'lar | — |

## 2. Bilgi mimarisi: üç sekme

**Bugün · Trendler · Bant**: Oura'nın üç sekme modeli ve WHOOP tarzı derin sayfalar. Mevcut Uyku ve Geçmiş sekmeleri Bugün'ün derin sayfalarına ve Trendler'e taşınıyor.

- **Bugün:** gün kaydırıcı (‹ tarih ›).
  - Derin sayfalar: Uyku detayı, Toparlanma detayı, Yük detayı, Metrik detayı (nabız, adım, stres, SpO2, kalori).
  - Sayfa: Canlı nabız.
- **Trendler:** metrik listesi, 7/30/90 seçici, her satırdan trend detayına geçiş.
- **Bant (Tesla'daki "aracın" karşılığı):** bant seçici; hızlı aksiyonlar Bul, Bildirim, Canlı, Senkron; Alarmlar, Sağlık izleme, Ekran ve DND, Hava durumu, Kadranlar, Cihaz bilgisi.
- **Ayarlar** (Bant'taki dişli ya da Bugün'deki profil):
  - Profil ve hedefler; birimler ve dil; görünüm (Sistem/Koyu/Açık).
  - Entegrasyonlar: webhook, web erişimi ("API anahtarı gir" eklenecek), dışa aktarma, Kestirmeler.
  - Veri: yeniden çöz, sil.
  - Tanılama (kalibrasyon dahil), hakkında.
- **İlk kurulum:**
  1. Hoş geldin.
  2. Mi Fitness ön şartı.
  3. Anahtar.
  4. Bağlantı kontrolü.
  5. Profil (atlanabilir).
  6. İlk senkron.

  Davet ve QR ile katılma her aşamada çalışır.

## 3. Ekran içerikleri (özet)

- **Bugün:**
  - Başlık: tarih, durum çipi ("3 dk önce" / "senkron 4/12" / hata), profil.
  - Kahraman: üç skor yan yana, her birinin altında tek satır bağlam: Toparlanma ("Hazır · HRV 48 ms"), Uyku ("7 sa 12 dk"), Yük ("Orta"). Güven düşükse işaret.
  - 24 saatlik zaman çizgisi: uyku bandı, saatlik adım ve nabız.
  - 2×3 gösterge: adım/hedef, aktif kalori, dinlenik nabız, HRV, ortalama stres, gece SpO2.
  - Bant şeridi: pil, bilekte, son senkron.
  - Durumlar: boş ("Bant ekle", "İlk senkron", "Kalibre ediliyor 2/3 gece"), yükleniyor (eski değerler soluk, ilerleme çubuğu), hata (tek banner, tek aksiyon).
- **Uyku detayı:** skor, toplam uyku, yatış→kalkış; katkılar (değer, alt skor, 14 günlük bazal); hipnogram; evre dakikaları; gece nabzı ve en düşük nabız; SpO2 (ort/min/%90 altı dakika); HRV (RR varsa); uyanma sayısı ve WASO (uykuya daldıktan sonra uyanık geçen dakikalar); kısa uykular; kaynak dosya ve güven notu.
- **Toparlanma detayı:** skor ve bant (düşük/orta/yüksek); katkılar: HRV, dinlenik nabız, uyku skoru, önceki günün yükü (bugün, bazal, z); 30 günlük sparkline; "nasıl hesaplanır".
- **Yük detayı:** 0–21; nabız bölgelerinde dakikalar (Z1–Z5); bölge başına TRIMP; saatlik yük; adım ve kalori; bandın kendi antrenman yükü yalnız referans olarak.
- **Bant merkezi:** model ve kimlik, büyük pil yüzdesi ve şarj durumu, bilekte, firmware, bağlantı satırı. Hızlı aksiyonlar: Bul, Bildirim, Canlı, Senkron. Kontrol listesi, her satırda canlı alt yazı ("Sonraki alarm 07:00", "Nabız 10 dk · SpO2 uyku").
- **Alarmlar:** banttan liste (17/0), aç/kapat (17/2), kaydırıp sil (17/4), ekle (17/1); düzenleyici: saat, tekrar, akıllı uyandırma.
- **Sağlık izleme:** nabız aralığı ve yüksek/düşük uyarıları, gelişmiş uyku izleme, SpO2 modu ve uyarısı, stres ve rahatla hatırlatıcısı, hareketsizlik penceresi; her birinde pil etkisi notu.

## 4. Akışlar

- **Günlük açılış:** uygulama öne gelir, son senkron 15 dakikadan eskiyse, Bluetooth açıksa ve bağlantı boşsa otomatik senkron. Her dosya CRC'den sonra saklanır ve çözülür. Etkilenen günlerin skorları yeniden hesaplanır (en fazla 90 gün). Arayüz güncellenir, webhook'lar ve hub tetiklenir. Gece yarısı gün kendiliğinden yenilenir.
- **Ayar değiştirme:** GET → kayıpsız ağaç (`PBTree`: alan, tür, bayt sırasıyla) → yalnız bilinen alanlar değişir, bilinmeyenler aynen geri gider → SET → tekrar GET ile doğrulama. "0 = desteklenmiyor" alanları hiç gönderilmez.
- **Kalibrasyon (Faz 0):**
  1. Mi Fitness'ın arka plan yenilemesini kapat (ACK atıp dosyaları siliyor).
  2. Bir gece bandı tak.
  3. Sabah önce Freeband'i senkronize et.
  4. Dosya başına rapor: tür, sürüm, CRC, çözüm durumu ve makullük kontrolleri. Kontroller: dakikalık adım toplamı günlük özetin ±%2'si içinde olmalı, nabız 30–220 arasında olmalı, nabız kayıtlı dakikaların kaçında var (bandın ölçüm aralığı; 2 dakikada birden seyrekse uyarı), kayıt sayısı geçen dakikalarla uyuşmalı, yatış ve kalkış saatleri makul olmalı, RR var mı yok mu.
  5. İstersen Mi Fitness'taki sayılarla karşılaştırma.
- **Hatalar:** tipli `LinkError` ve yerelleştirilmiş tek cümle + tek aksiyon:
  - Mi Fitness bandı tutuyor → "Mi Fitness'ı kapatıp tekrar dene".
  - Bluetooth kapalı.
  - Anahtar eşleşmiyor → anahtarı yeniden oku.
  - Kısmi senkron → "20 dosyadan 12'si, kalanı sonra"; başarı sayılmaz.

## 5. Analiz formülleri (şeffaf, sürümlü)

- **Geçerli değerler:** nabız 30–220, SpO2 70–100, stres 1–100.
- **Gün ve gece:** gün = dosyanın kendi saat dilimindeki yerel gün. Gece, uyanılan güne aittir. 10:00–20:00 arasında başlayan ve 3 saatten kısa olan uyku "şekerleme" sayılır.
- **Bazal:** önceki 14 geçerli günün medyanı; σ = 1,4826 × MAD (alt sınırlı). 3 günden azsa "kalibre ediliyor", 3–6 gün düşük güven, 7 ve üstü normal.
- **Dinlenik nabız:** sırayla ilk bulunan kullanılır:
  1. uykuda en düşük 5 dakikalık ortalama (yüksek güven);
  2. bandın `hrResting` değeri (orta);
  3. gündüz adımsız dakikaların 10. yüzdeliği (düşük).
- **HRV:** yalnız RR varsa. RR 300–2000 ms aralığında tutulur, %20'den fazla sıçrayan atım elenir. 5 dakikalık pencerelerde RMSSD hesaplanır; gecenin değeri ikinci yarıdaki pencerelerin medyanıdır (en az 3 pencere). 10 ms çözünürlük nedeniyle "yaklaşık" etiketi taşır.
  - **SpO2 ölçümünden sonraki bozulma için ayrı kural yok (2026-11-13, algoritma v1 değişmedi).** "Band 10'un RR verisi filtresiz, her SpO2 ölçümünden sonra birkaç saniye bozuk" iddiası incelendi; eldeki kaynakların hiçbirinde yok (`docs/SOURCES-2026-11-13.md`, `docs/MIFITNESS-2026-11-13.md`, Gadgetbridge `SleepDetailsParser.java`; Gadgetbridge Xiaomi için RMSSD hesaplamıyor) ve ölçümle de gösterilmedi. Kural yazmak için ayrıca RR atımlarını SpO2 örneklerinin saatine birkaç saniye hassasiyetle oturtmak gerekir; RR paketinin zaman damgası birkaç saniye kayıyor (Gadgetbridge'in Band 9 notu, `docs/ACTIVITY.md` 6.3.2) ve birimi kesin değil. Bozuk atımlar aralık dışına çıkıyor ya da %20'den fazla sıçrıyorsa mevcut filtre onları zaten eliyor; yarısından azı sağlam kalan pencere sayılmıyor. Gerçek bir gece dosyasında SpO2 saatlerinin çevresinde reddedilen fark oranı ölçülürse kural o veriden yazılır.
- **Uyku skoru:** mevcut katkıların ağırlıklı ortalaması.
  - Süre 35, verimlilik 15, derin 10, REM 10, huzur 10 (uyanma ve WASO), düzen 10 (7 gecelik uyku ortası sapması), nabız düşüşü 10.
  - Süre yoksa skor yok. Mevcut ağırlık 60'ın altındaysa skor "tahmini" olarak gösterilir.
  - **v2 (2026-11-16): skor, süre alt skorunun en fazla 10 puan üstünde olabilir.** Ölçülen gece: 4 sa 52 dk uyku (ihtiyaç 8 sa), süre alt skoru 61, öbür katkıların hepsi 100'e yakın, ağırlıklı ortalama 76 çıktı. Kısa ama derli toplu bir gecenin "iyi" görünmesi yanıltıcı; sınırla aynı gece 71 eder. 10 bir seçimdir, doğrulanmış değil. `ScoreEngine.algoVersion` 2 oldu, saklı skorlar yeniden hesaplanır.
  - Uyku borcu (içgörü) gündüz uykularını da sayar: o günün `naps` dakikaları gece süresine eklenir.
- **Toparlanma:** f(z) = 60 + 20z (0–100'e sınırlı), yani "senin normalin" 60 eder.
  - RR varsa ağırlıklar: HRV 40, dinlenik nabız 25, uyku 25, dünkü yük 10.
  - RR yoksa: dinlenik nabız 45, uyku 40, yük 15; güven en fazla "orta".
- **Yük (0–21):**
  - Maksimum nabız = 208 − 0,7 × yaş. Nabız rezervi oranı r = (nabız − dinlenik) / (maks. − dinlenik).
  - Bölgeler (r'ye göre): Z1 0,5–0,6, Z2 0,6–0,7, Z3 0,7–0,8, Z4 0,8–0,9, Z5 ≥ 0,9.
  - TRIMP = Σ r · 0,64 · e^(k·r); k erkekte 1,92, kadında 1,67, bilinmiyorsa 1,80.
  - Yük = min(21, 21 · ln(1 + TRIMP/25) / ln 25).
  - Nabız uyanık dakikaların yarısından azını kapsıyorsa: kısa boşluklar doldurulur, dakikada 100 adım ve üstü "r = 0,4" sayılır, güven düşük olur.
  - **Uygulamada (algoritma v1):** r < 0,3 olan dakikalar TRIMP'e katılmaz. Formül harfiyen uygulanınca hareketsiz bir gün yaklaşık 90 TRIMP, yani 10 civarında yük çıkarıyordu.
- **Stres ve SpO2:** skora girmez. Stres: zaman ağırlıklı ortalama ve 4 banttaki dakikalar. SpO2: gece ortalaması, minimumu ve %90 altındaki dakikalar. Tıbbi iddia yok.
- **Güven:** yüksek/orta/düşük/yok, her zaman gerekçe listesiyle ("RR yok", "nabız 30 dakikada bir", "bazalde 5/14 gece").

### 5.1 Dikkat çekenler (içgörüler, v1)

Bugün ekranında, skorların altında, en çok üç satır; önce uyarılar. Her kural kişiyi kendi bazalıyla karşılaştırır, tam bazal (7 gün) ister, yoksa susar. Eşikler seçimdir, bir popülasyonla doğrulanmadı. `Analytics/Insights.swift`.

- **Dinlenik nabız yüksek:** bazaldan 2σ yukarıda. 3σ ya da üst üste 3 gün ise uyarı. Her günün z'si kendi önceki günlerinin bazalına göre.
- **İki haftanın en düşük dinlenik nabzı:** z ≤ −1 ve önceki 14 geçerli günün hepsinden düşük (olumlu).
- **HRV düşük:** bazaldan 2σ aşağıda; 3σ ya da üst üste 3 gece ise uyarı.
- **Uyku açığı:** son 7 gecede (en az 5'i verili) ihtiyaçtan toplam 5 saat eksik; 10 saat ise uyarı.
- **Uyku saati kaydı:** gecenin ortası, önceki gecelerin (en az 4) medyanından 90 dakika ileri ya da geri; saat gece yarısında sarılır.
- **Yoğun günler, düşük toparlanma:** önceki 3 günün her birinde yük bazalın 1σ üstünde ve bugünkü toparlanma düşük bantta (34'ün altı).

## 6. Veri hattı ve hata düzeltmeleri

- **Yeni modeller** (`Data/HealthModels.swift`):
  - `MinuteDay`: günde 1440 dilimlik paketlenmiş diziler; dakika başına satır tutulsaydı 90 günde 130 bin satır olurdu.
  - `DaySummary`, `SleepSession`, `SleepRR`, `ManualReading`, `DailyScore` (algoritma sürümü ve katkılar JSON olarak).
  - `ActivityBlob`'a `parserVersion` ve `parseStatus` eklenir.
- **Çözme:** `@ModelActor ActivityIngest` → saf `IngestMapper` (swiftc ile test edilebilir) → kaynak dosyaya göre sil + ekle (idempotent) → `DailyRollup` → `ScoreEngine`. Çözücü sürümü değişince arka planda yeniden çözülür; algoritma sürümü değişince skorlar yeniden hesaplanır. Mevcut store'dan yeni şemaya `VersionedSchema` ile geçilir.
- **Sözleşme** (`freeband.v1`'e ekleme): `minute`, `sleep`, `score` türleri ve `sync.partial` olayı. Webhook'lar Faz 1'den itibaren yeni türleri gönderir; hub, Faz 5'te tabloları eklenince açılır.
- **Hata düzeltmeleri:**
  1. Bant silme, veri silme ve birleştirme ham dosyaları ve türetilmiş veriyi de kapsar.
  2. Saatlik adımlar `MinuteDay`'den gelir.
  3. Gün değişimi gece yarısı yakalanır.
  4. Hub'daki nabız eşiği 30–220 olur.
  5. Senkron sonucu `complete`/`partial`/`failed` olarak raporlanır.
  6. Uygulamaya "API anahtarı gir" alanı eklenir.

## 7. Yerelleştirme

- String Catalog dosyaları: `Localizable`, `InfoPlist`, `AppShortcuts`. Kaynak dil İngilizce, Türkçe katalogda doldurulur.
- `project.yml`'de geliştirme bölgesi `en`, desteklenen diller `[en, tr]`.
- Zorla açılan koyu tema kaldırılır; `Theme.locale` kaldırılır ve biçimler `Locale.current`'ı izler.
- Biçimlendirme: mesafe ve kalori `Measurement` ile, süreler `Duration` ile ("7h 12m" / "7 sa 12 dk"), yüzdeler `.percent` ile (Türkçede "%46"). Çoğullar katalogda; küçük harfe çevirme açık yerel ayarla (İ/ı sorunu).

## 8. Tasarım sistemi v3: Tesla dili

**Sekmeler: Bugün · Uyku · Trendler · Bant** (dört). Ürün planındaki üç sekme önerisinden ayrıldık, çünkü uyku ana değer ve Türkçe etiketler dörde sığıyor. Ayarlar, Tesla'daki gibi Bant'ın altında: "Freeband ayarları" satırı ve dişli düğmesi.

**İlkeler:**
1. Her ekranda tek odak nesnesi.
2. Bant "araba", gün "yolculuk".
3. Bağlamsal bilgi yalnız geçerliyken görünür: canlı nabız, şarj, titreşim, Bluetooth kapalı.
4. İki ağırlık, büyük harf yok.
5. Mavi yalnız "bas ve onayla" demek.
6. Renk hak edilir; renk tek başına anlam taşımaz.
7. Önce hüküm, sonra sayılar: Hazır / Dengeli / Dinlen.

**Renk (koyu / açık):**
- Zemin ve metin: canvas `#0E0F12` / `#FFFFFF`; surface `#171A20` / `#F4F4F4`; raised `#22252C` / `#FFFFFF`; hairline `#2C2F36` / `#EEEEEE`; metin `#F4F4F4` / `#171A20`; ikincil `#A2A4A9` / `#5C5E62`.
- Aksiyon: `#3E6AE1`.
- Veri renkleri: iyi `#3CCB7F`, orta `#F2B33D`, düşük `#E5483B`; uyku menekşesi `#A98FFF`; aktivite ve yük camgöbeği `#3EC6DE`; nabız macentası `#FF6FB3`. Açık tema için koyu karşılıkları var.
- Bantlar: Toparlanma 67/34; Uyku 80/60. Yük renksiz, yalnız kelimelerle: Hafif, Orta, Yüksek, Tam.
- Increase Contrast için ayrı değerler var.

**Yazı:** Open Sauce Sans, yalnız 400 ve 500 ağırlık; 600 yalnız Kalın Metin erişilebilirlik ayarında, Light silinir. Ölçek: 56/40/28/28/17/16/15/16/14/12. `Font.custom(relativeTo:)` ile Dynamic Type ve tabular rakamlar.

**Ölçüler ve hareket:**
- Aralık 4/8/16/24/32/48; kenar boşluğu 16.
- Köşe yarıçapı: grafiklerde 0, düğmelerde 4, kartlarda 12. Hap biçimi yok, gölge yok.
- Hareket: yalnız renk geçişi (0,33 sn, `timingCurve(.5,0,0,.75)`). İstisnalar: skor yayı açılışta 0,66 sn'de çizilir, sayılar `numericText` ile değişir. Reduce Motion açıkken bunlar da kapanır.

**Bileşenler** (`UI/Design/Components/`): ScoreArc (270° yay, eşik çentikleri), MetricRow (sparkline + fark), ContributorRow, Hypnogram, ZoneBar, TrendChart (7/30/90, seçimde değer), StatusLine ("Band 10 Pro · %82 · 2 dk önce senkron"), QuickActionButton (56 pt daire, ince ikon), ListCard/ListRow, SegmentedPicker, SnapSlider, sayfa stilleri, EmptyState, ContextCard (canlı/şarj/bulma/uyarı), BandRender (düz vektör bant çizimi, ekranında canlı saat ve pil).

**Ekranlar:**
- Bugün: hüküm başlığı, StatusLine, üç ScoreArc, **günün izi** (`DayTrace`: gece yarısından gece yarısına nabız çizgisi, çeyrek saatlik adım çubukları, evre renkleriyle uyku bandı; bugün için "şimdi" çizgisi; kartsız, sayfanın kendi figürü), dikkat çekenler, bağlamsal kart, "Bugün" metrik listesi. Hızlı aksiyonlar (Senkron, Canlı, Bul) yalnız Bant sekmesinde; Bugün'de aşağı çekince senkron.
- Skor detayı (üç skor için tek şablon).
- Uyku (gece kaydırıcı, hipnogram, evre tablosu, nabız, SpO2).
- Trendler (kartlar → detay).
- Bant (BandRender, durum, hızlı aksiyonlar, kontrol listesi, Freeband ayarları).
- Alarmlar ve alarm düzenleyici, Sağlık izleme, Ekran ve DND, Freeband ayarları, İlk kurulum (3 adım), Canlı nabız sayfası.

**İkon:** tek 270° açık yay (ScoreArc), `#171A20` / `#F4F4F4`; koyu ve tinted varyantları; kırmızı, gradyan ya da dither yok.

**Hub:** aynı token'lar `design/tokens.json` → Swift ve CSS'e üretilir; açık/koyu tema; skor, hipnogram ve trendler sunucu tarafında SVG.

**Silinecekler:** `DayDial.swift`, `Theme.swift` (yerine Tokens ve Typography gelir), eski Today/History/ConnectionStatus/ToolsSheet görünümleri (mantıkları taşınınca), Light font, hub'da `dial.ts`, `wordmark.ts` ve dither CSS'i.

**Skill'ler (okuma referansı olarak):** `ios-hig-design`, `swiftui-expert-skill`, `swiftui-pro`, `swift-charts`; yerelde `dataviz` ve `checklist-design` (son tasarım denetimi).

### 8.1 Tasarım v4 (2026-11-13): gece gösterge paneli

Kullanıcı "tamamen yeni, çok daha profesyonel, en az WHOOP kalitesinde" bir arayüz istedi. v3'ün ince çizgili, kartsız sadeliği bırakıldı; bileşen adları ve belirteç hattı (`design/tokens.json` → `gen_tokens.py`) aynı kaldı, bu yüzden değişiklik bütün ekranlara birden yansıdı.

- **Zemin:** koyu öncelikli, soğuk mürekkep siyahı: canvas `#07090D`, surface `#11151C`, raised `#1A202A`, hairline `#1F2632`. Açık tema: canvas `#F3F5F8`, beyaz kartlar.
- **Renk veride:** iyi `#35E0A1`, orta `#FFC043`, düşük `#FF5A5F`; uyku `#8E7BFF`, yük ve adım `#3BA7FF`, nabız `#FF5C93`. Aksiyon rengi artık mavi değil, temanın mürekkebi (koyuda beyaz düğme); açık anahtarlar "iyi" yeşili.
- **Halka:** 1 pt iz ve 3 pt yay yerine kalın halka (ana 9, kahraman 12, detay 14 pt), yuvarlak uçlu; iz, skorun kendi renginin %20'si; bant eşikleri halkadan kesilmiş çentikler.
- **Yazı:** Open Sauce Sans kaldı; rakamlar, başlıklar ve düğmeler 600 (önceden en çok 500). Büyük rakam 64 pt.
- **Şekil:** kart yarıçapı 20, ince kenar çizgili; düğme yarıçapı 14.
- **Bugün:** kahraman kart (Toparlanma halkası ve yanında dinlenik nabız, HRV, uyku), yan yana Uyku ve Yük kartları, kart içinde günün izi, dikkat çekenler, sayı ızgarası (Adım geniş, diğerleri ikili; her karoda değer, 7 günlük ortalamaya göre değişim ve metriğin renginde çizgi).
- **Uyku:** gecenin kahraman kartı (Uyku halkası, yanında süre, yatış–kalkış ve verim, derin ve REM), altında evreler ve gece grafikleri.
- **Trendler:** her kartta metrik adı, büyük ortalama ve aynı uzunluktaki önceki döneme göre değişim (iki yanda en az 3 gün varsa), altında grafik.
- **Bant:** tek kartta bant çizimi, adı, büyük pil yüzdesi ve durum satırı; altında hızlı aksiyonlar ve ayarlar.
- Yapılmadı: skor detayının düzeni v3'teki gibi (yalnız yeni renk, halka ve kartları aldı); README ve App Store ekran görüntüleri eski tasarımda; hub'ın CSS belirteçleri üretildi ama site yayınlanmadı.

## 9. Fazlar ve yürütme (gece, otonom; kullanıcı 2026-10-14'te onay verdi)

| Faz | İçerik | Kim | Durum |
|---|---|---|---|
| 0 | Kalibrasyon araçları: rapor, makullük kontrolleri, dışa aktarma. Gerçek dosyalar sabah | A | **tamam** (`a99fdd2`) |
| 1 | Veri hattı (modeller, ingest, rollup), analiz motoru ve testleri, hata düzeltmeleri 1/2/3/5, 30 günlük demo veri, webhook'a yeni türler | A | **tamam** (`a99fdd2`; düzeltme 6 `9d2333f`) |
| 5a | Hub veri katmanı: `minute`/`sleep`/`score`, upsert, yeni uç noktalar, hata düzeltmeleri 4/6, testler | D | **tamam, canlıda** (`f4b719e`) |
| 2a | Tasarım sistemi: token'lar, yazı, hareket ve bileşenler (önizlemelerle) | B | **tamam** (`91c9288`) |
| 2b | Ekranlar (4 sekme), yerelleştirme (EN/TR), ikon, eski kodun silinmesi | E | **tamam** (`a67c16d`, `bdf7770`, `9b4f275`) |
| 3 | Bant kontrolleri: kayıpsız `PBTree`, `.exchange` oturumu, alarmlar, sağlık izleme, DND ve bileği kaldırınca ekran (önce GET), hava durumu, kadranlar | — | **ertelendi** (ajan bütçesi; cihaz doğrulaması zaten sabah gerekli) |
| 5b | Hub paneli Tesla diline ve yeni verilere geçer; yayın (önce migration) | — | **ertelendi** (ajan bütçesi) |
| 4 | Mi Fitness'ın yerine geçme: arka plan modu, ACK. **Bu gece yalnız iskelet, ACK varsayılan kapalı** | — | sona |
| QA | Ekran görüntüsü matrisi (açık/koyu × normal/büyük yazı × EN/TR), checklist-design denetimi, TestFlight, Obsidian/PLAN.md güncellemesi | ben | **tamam**: 0.5.0 build 36 TestFlight'ta |

**Ajan bütçesi (kullanıcı isteği):** aynı anda en fazla 2 ajan; bu gece A, B ve D bitince yalnız 1 yeni ajan (E, ekranlar). Gerisi ana oturumda ya da sonraki oturumda.

Kurallar: ajanlar commit atmaz, her akışın sonunda ben test edip commit'lerim. Her ajanın kendi derleme klasörü olur. Banda yazan hiçbir test gece çalıştırılmaz, telefon başında kimse yok. 8/5 ACK gönderilmez. Repo private kalır.

## 10. Doğrulama

- Testler: protokol vektörleri, aktivite çözücü (147), analiz ve ingest harness'ları (yeni), hub vitest; hepsi yeşil kalmalı.
- Simülatörde `-freeband-demo full|empty|calibrating` ile her ekranın açık/koyu × normal/AX × EN/TR görüntüsü (`out/design-v3/`), checklist-design denetimi.
- Cihazda (sabah, kullanıcıyla): senkron → dosyalar çözülüyor mu, skorlar Mi Fitness ile makul mü, alarm oluşturma, sağlık ayarı yazıp tekrar okuma, kalibrasyon raporu.
- Hub: yerelde `wrangler dev` + uygulama; yayından sonra canlıda uçtan uca.
