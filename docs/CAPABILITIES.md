# Freeband yetenek haritası: telefon, Xiaomi Smart Band 10 / 10 Pro ile neler yapabilir

Telefon uygulamasının Gadgetbridge'in uyguladığı protokol (BLE V2 üzerinde şifreli protobuf `Command{type, subtype, ...}`) üzerinden bantla yapabileceği her şeyin haritası. Her yetenek için: ne yaptığı, yönü, mesajın alan numaralarıyla tam yolu, Band 10 / 10 Pro'nun bunu beyan edip etmediği, Freeband için iOS'ta yapılabilirliği, efor ve risk.

Tarih: 2026-10-14. Kaynak: Gadgetbridge `d4bd8367` (`vendor/Gadgetbridge`), AstroBox-NG `vendor/astrobox-Core` ve `vendor/astrobox-Pb`, Freeband `ios/`. Arka plan: `findings.md`, aktivite dosyaları için `docs/ACTIVITY.md`.

## 0. Kısaltmalar, işaretler, ölçekler

| Kısaltma | Yol |
|---|---|
| `X/` | `vendor/Gadgetbridge/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/` |
| `XD/` | `vendor/Gadgetbridge/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/devices/xiaomi/` |
| `W/` | `XD/watches/` |
| `GB/` | `vendor/Gadgetbridge/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/` |
| `P/` | `vendor/Gadgetbridge/GBProtobufGenerator/src/main/proto/` |
| `ABP/` | `vendor/astrobox-Pb/protos/xiaomi/` |
| `ABC/` | `vendor/astrobox-Core/src/` |
| `FB/` | `ios/Freeband/` |

- **[KOD]** Gadgetbridge kaynağında görüldü. **[AB]** AstroBox kaynağında görüldü. **[FB]** Freeband kaynağında. **[ÖLÇÜM]** kullanıcının bilekliğinde ölçüldü (`findings.md`).
- **[iOS]** Apple platformunun bilinen davranışı (belgelerden); bu bileklikle denenmedi.
- **[TAHMİN]** kaynakta açıkça yazmıyor, çıkarım.
- **Efor:** S = tek komut ya da GET/SET çifti ve küçük bir ekran, en fazla 1 gün. M = birkaç komut, durum takibi ya da yeni bir iOS izni, 2–5 gün. L = yeni altyapı (sürekli oturum, dosya aktarımı, arka plan konumu), bir haftadan fazla.
- **Risk:** düşük = yanlış gönderilse en kötü ihtimalle ayar bozulur, bant kendini düzeltir; orta = bantta görünür yan etki ya da belirsiz alan; yüksek = bantta kalıcı bozulma, pil ya da App Store riski.

Alan yolu yazımı: `Command.system(4).clock(4).{date 1{year 1, month 2, day 3}, ...}` = `Command` mesajının 4 numaralı `system` alanı, onun 4 numaralı `clock` alanı ve o mesajın alanları. Köşeli `[]` tekrarlanan (repeated) alan demek.

## 1. Ortak kurallar

### 1.1 Zarf

Her komut aynı zarfta gider [KOD] `P/xiaomi.proto:22-45`:

```
Command { type 1 (uint32, zorunlu), subtype 2 (uint32), <yük alanı>, status 100 (uint32, cevaplarda; 0 = başarı) }
```

Yük alanının numarası her zaman `type + 2`:

| `type` | Servis | Yük alanı | Gadgetbridge sınıfı |
|---|---|---|---|
| 1 | Auth | `auth 3` | `X/XiaomiAuthService.java` |
| 2 | System | `system 4` | `X/services/XiaomiSystemService.java:76` |
| 4 | Watchface | `watchface 6` | `X/services/XiaomiWatchfaceService.java:44` |
| 7 | Notification | `notification 9` | `X/services/XiaomiNotificationService.java:65` |
| 8 | Health | `health 10` | `X/services/XiaomiHealthService.java:91` |
| 10 | Weather | `weather 12` | `X/services/XiaomiWeatherService.java:67` |
| 12 | Calendar | `calendar 14` | `X/services/XiaomiCalendarService.java:43` |
| 17 | Schedule | `schedule 19` | `X/services/XiaomiScheduleService.java:68` |
| 18 | Music | `music 20` | `X/services/XiaomiMusicService.java:36` |
| 20 | Rpk | `rpk 22` | `X/services/XiaomiRpkService.java:47` |
| 21 | Phonebook | `phonebook 23` | `X/services/XiaomiPhonebookService.java:43` |
| 22 | DataUpload | `dataUpload 24` | `X/services/XiaomiDataUploadService.java:43` |

AstroBox aynı numaralandırmayı `WearPacket{type 1, id 2, payload}` adıyla kullanıyor ve Gadgetbridge'de olmayan tipleri de tanımlıyor: 5 NFC, 9 LPA (eSIM), 11 Stock, 13 Factory, 14 AIVS, 15 Market, 16 GNSS, 19 Alexa, 23 Interconnection [AB] `ABP/wear.proto:30-77`. Bölüm 16.

- Gadgetbridge yük içermeyen GET'leri `Command{type, subtype}` olarak yollar [KOD] `X/XiaomiSupport.java:471-479`. Freeband'in `PBWriter`'ı aynı şeyi yapabiliyor [FB] `FB/Band/MiProtocol.swift:315-322` (`batteryCommand`).
- Proto2: açıkça set edilen `0`/`false` da kabloya yazılır [KOD] `P/xiaomi.proto:1`. Gadgetbridge'in `setX(0)` dediği her alanı Swift tarafı da yazmalı.
- Freeband'in `PBWriter`'ında bugün yalnız `varint`, `bytes`, `string`, `message` var [FB] `FB/Band/MiProtocol.swift:89-123`. Eklenmesi gerekenler: `sint32` zigzag (saat dilimi, hava sıcaklığı), `float` / wire type 5 (kilo, hava basıncı, GPS hızı/yönü), `double` / wire type 1 (GPS enlem/boylam/irtifa), `bool`.
- Ayarların hepsi aynı kalıpta: `GET` subtype → bant tüm mesajı döner → telefon **tüm** mesajı değiştirip `SET` subtype'ıyla geri yollar. Gadgetbridge SET'i sıfırdan kurar, bilmediği alanları taşımaz (ör. `X/services/XiaomiHealthService.java:631-642`). Freeband de önce GET yapıp gelen değerleri koruyarak SET kurmalı.

### 1.2 "Destekleniyor" iki katmanlı

Gadgetbridge'de Band 10 / 10 Pro ne söylüyor, iki yerden okunur:

1. **Statik beyan:** `XiaomiCoordinator` (ortak) ve onu genişleten `MiBand10Coordinator` / `MiBand10ProCoordinator`. Ör. `supportsWeather`, `supportsFindDevice`, `supportsCalendarEvents`, `supportsMusicInfo` hepsi `true` [KOD] `XD/XiaomiCoordinator.java:325`, `:441`, `:529`, `:534`.
2. **Çalışma anında tespit:** Ayarların çoğu `FEAT_*` bayraklarıyla açılır. Bayrak, bant ilgili GET'e cevap verince `true` olur [KOD] `X/XiaomiPreferences.java:45-61`, `XD/XiaomiCoordinator.java:776-778`. Ör. kamera uzaktan kumandası ancak bant `Command{2,7}`'ye cevap verirse görünür (`X/services/XiaomiSystemService.java:517-525`). Alarm, hatırlatıcı ve hazır cevap sayısı da bantın döndüğü sayıdan gelir (`XD/XiaomiCoordinator.java:265`, `:452`, `:457`).

Yani "Band 10 destekliyor mu" sorusunun çoğu için cevap "ortak Xiaomi davranışı, bant cevap verirse açılır". Freeband aynı yolu izleyebilir: her ayar ekranını, bant ilgili GET'e cevap verdiyse göstermek. Ayrıca auth'un son adımında bant `auth(3).authStep4(33).{unknown1 1, device_capability 2, device_capability_2 3}` döndürüyor; Gadgetbridge okumuyor, bit anlamları bilinmiyor [KOD] `P/xiaomi/wear_account.proto:48-52`. Freeband bu iki sayıyı loglamalı; ileride özellik tespitine yarayabilir. Aşağıdaki tablolarda **Beyan** sütunu bunu ayırır: `statik` (coordinator `true` döner), `runtime` (bant cevabına bağlı), `yok` (beyan edilmemiş ya da UI'da gizli).

Band 10 ile 10 Pro arasındaki coordinator farkları [KOD]:

| | Band 10 | Band 10 Pro |
|---|---|---|
| Özel titreşim deseni düzenleme | `true`, yerleşik desenler 250–255 | beyan yok (varsayılan `false`) |
| Navigasyon | açıkça `true` | ortak sınıftan `true` |
| Ekran | 212 × 520 | 336 × 480 |
| Bağlantı | `BT_CLASSIC`, deneysel | `BT_CLASSIC`, deneysel |
| Kaynak | `W/MiBand10Coordinator.java:46-49`, `:61-93` | `W/MiBand10ProCoordinator.java:45-48`, `:60-63`; varsayılan `GB/devices/AbstractDeviceCoordinator.java:1296-1298` |

Gadgetbridge Band 10 / 10 Pro'yu BT Classic üzerinden konuşturuyor; Freeband'in BLE V2 yolu aynı paket sınıfını ve aynı protobuf'u kullanır (`findings.md` §3.2). Aşağıdaki her şey, aksi yazılmadıkça, BLE V2'de de aynı baytlardır.

### 1.3 iOS'ta ortak kısıtlar

Bunlar her bölümde tekrar etmemek için burada:

1. **Oturum modeli.** Freeband bugün "bağlan, auth, komutları gönder, 2 sn bekle, kanalı bırak" yapıyor [FB] `FB/Band/BandLink.swift:236-246` (`didAuthenticate`, `.send` amacı), `:471-482` (`release`). Senkron amacında ise pil, canlı akış ve aktivite dosyalarını çekip yine bırakıyor (`:247-270`). `Info.plist`'te `UIBackgroundModes` yok [FB] `FB/Info.plist`. Bu modelle **telefon → bant** yönündeki her şey çalışır (bildirim, ayar, alarm, hava). **Bant → telefon** olayları (telefonu bul, müzik tuşu, hava isteği, bildirim kapatma, antrenman GPS isteği) ancak oturum açıkken gelir. Bunlar için `bluetooth-central` arka plan modu, `CBCentralManager` state restoration ve sürekli açık bir oturum gerekir [iOS]. Bu "tutulan oturum" altyapısı bir kez yapılır (L), sonra birçok özelliği açar.
2. **Mi Fitness ile çakışma.** Aynı `005E/005F` kanalında aynı anda tek oturum yürür; Mi Fitness arka planda bağlıyken Freeband'in auth'u ya da Mi Fitness'ın senkronu bozulur [ÖLÇÜM] `findings.md` §5.4. Tutulan oturum, Mi Fitness'ın kaldırılması ya da boşaltılması demek. Kısa "bağlan-gönder-bırak" komutları Mi Fitness kapalıyken sorunsuz.
3. **ANCS ve AMS.** iPhone, eşleşmiş BLE aksesuarlara bildirimleri ANCS, medya kontrolünü AMS üzerinden **uygulamadan bağımsız** verir; üçüncü parti iOS uygulaması başka uygulamaların bildirimlerini ya da çalan medyasını okuyamaz [iOS]. Mi Fitness'ın iOS'ta bildirim iletebilmesi de bu yüzden ANCS'e dayanıyor olmalı [TAHMİN]. Sonuç: Freeband'in `Command{7,0}`'ı başka uygulamaların bildirimlerini iletmek için **kullanılamaz ve gerekmez**; yalnız Freeband'in kendi içeriği için. Bant ANCS'e Mi Fitness olmadan da abone oluyor mu, doğrulanmadı (`findings.md` §9.3).
4. **Uygulama başka uygulamaların işini yapamaz.** SMS göndermek kullanıcı arayüzü ister, aramayı reddetmek ve arayanı öğrenmek mümkün değil, zil/sessiz anahtarı okunamaz ve ayarlanamaz, sistem ses düzeyi programla değiştirilemez [iOS]. Bant bu işleri isterse Freeband "yapılamadı" cevabı vermeli.
5. **AGPL.** Gadgetbridge ve AstroBox kodu kopyalanmamalı; alan numaraları ve akışlar birlikte çalışabilirlik bilgisi (`findings.md` §8).

## 2. Özet tablo

Yön: `T→B` telefon → bant, `B→T` bant → telefon, `↔` iki yönlü. Beyan: `statik` / `runtime` / `yok` (bölüm 1.2); `AB` = yalnız AstroBox'ta tanımlı. iOS: `kolay` = kısa oturumla, ek izin yok; `oturum` = tutulan BLE oturumu gerekir (bölüm 1.3); `izin` = yeni bir iOS izni ya da yetenek; `hayır` = iOS'ta yapılamaz.

| § | Yetenek | Yön | Komut | Beyan | iOS | Efor | Risk | Freeband |
|---|---|---|---|---|---|---|---|---|
| 3.1 | Özel bildirim | T→B | 7/0 | statik | kolay | S | düşük | **var** |
| 3.2 | Bildirimi kaldır | ↔ | 7/1 | statik | kolay | S | düşük | yok |
| 3.3 | Telefonda aç | B→T | 7/8 | statik | oturum | M | düşük | yok |
| 3.4 | Bildirim ikonu | ↔ | 7/15, 7/16 + 22/0 | statik | oturum | M | düşük | yok |
| 3.5 | Gelen arama | ↔ | 7/0, 7/1, 7/2, 7/5 | statik | hayır (ANCS) | — | — | — |
| 3.6 | Hazır cevaplar | ↔ | 7/9, 7/12–14 | runtime | liste kolay, gönderim hayır | S | düşük | yok |
| 3.7 | Bildirimde ekranı aç | T→B | 7/6, 7/7 | runtime | kolay | S | düşük | yok |
| 3.8 | Uygulama başına bildirim izni | T→B | 7/3, 7/4 | AB | kolay | S | orta | yok |
| 3.9 | Navigasyon | T→B | 7/0 | statik | veri yok | L | düşük | yok |
| 4.1 | Bandı bul | ↔ | 2/18 | statik | kolay | S | düşük | **var** |
| 4.2 | Telefonu bul | ↔ | 2/17 | statik | oturum + ses | M | orta | yok |
| 4.3 | Titreşim desenleri, anlık desen | T→B | 2/46, 47, 58, 59, 60, 61 | B10 statik, Pro yok | kolay | M | düşük | yok |
| 5.1 | Saat, saat dilimi, 12/24 | T→B | 2/3 | statik | kolay | S | düşük | yok |
| 5.2 | Alarmlar | T→B | 17/0, 1, 2, 4 | statik + runtime | kolay | S | düşük | yok |
| 5.3 | Hatırlatıcılar | T→B | 17/14, 15, 17, 18 | runtime | kolay | S | düşük | yok |
| 5.4 | Takvim | T→B | 12/1 | statik | izin (EventKit) | S–M | düşük | yok |
| 5.5 | Dünya saati | T→B | 17/10, 11 | yok | kod tablosu yok | M | orta | yok |
| 5.6 | Uyku modu programı | T→B | 17/8, 9 | runtime | kolay | S | düşük | yok |
| 6 | Hava durumu | ↔ | 10/0–3, 5–8, 10 | statik | kolay (+ konum izni isteğe bağlı) | M | düşük | yok |
| 7 | Müzik | ↔ | 18/0–2 | statik | oturum, yalnız Apple Music | M | düşük | yok |
| 8.1 | Kullanıcı bilgisi, günlük hedefler | T→B | 8/0 | statik | kolay | S | düşük | yok |
| 8.2 | Hedef bildirimi, ikincil hedef, vitality | T→B | 8/21–22, 42–43, 35–36 | runtime | kolay | S | düşük | yok |
| 9.1 | Nabız aralığı, yüksek/düşük alarm, uyku | T→B | 8/10, 11 | statik + runtime | kolay | S | düşük | yok |
| 9.2 | SpO2 | T→B | 8/8, 9 | runtime | kolay | S | düşük | yok |
| 9.3 | Stres | T→B | 8/14, 15 | runtime | kolay | S | düşük | yok |
| 9.4 | Hareketsizlik hatırlatıcısı | T→B | 8/12, 13 | runtime | kolay | S | düşük | yok |
| 9.6 | Canlı nabız/adım | ↔ | 8/45–47 | statik | kolay | S | düşük | **var** |
| 9.7 | Takılı / şarjda / uyuyor, pil ayrıntısı | ↔ | 2/78, 2/79, 2/1 | runtime | kolay (itme: oturum) | S | düşük | pil seviyesi var |
| — | Aktivite geçmişi (dakikalık, uyku, antrenman) | ↔ | 8/1–3 + kanal 5 | statik | kolay | — | — | **var** (`docs/ACTIVITY.md`; `FB/Band/BandLink.swift:317-334`, `:539-542`) |
| 10.1 | Bileği kaldırınca ekran | T→B | 2/24, 25 | yok (GB# teyit) | kolay | S | düşük–orta | yok |
| 10.2 | Rahatsız etmeyin | ↔ | 2/22, 23; senkron 2/15 | yok (GB# teyit) | kolay | S | düşük | yok |
| 10.3 | Ekran gece modu | T→B | 2/10, 11 | AB | kolay | S | orta | yok |
| 10.4 | Parlaklık / ekran süresi / AOD | T→B | yok / yok / 2/65, 66 | — | AOD için yakalama gerekir | S | orta | yok |
| 10.5 | Ekran öğeleri, düzen, kısayollar | T→B | 2/29, 30; 2/31, 41; 2/32–38 | runtime / AB | kolay | M | düşük | yok |
| 10.6 | Widget'lar | T→B | 2/51–53 (v2), 2/83–85 (v3) | runtime | kolay | M | orta | yok |
| 10.7 | Dil | T→B | 2/6 | statik | kolay | S | düşük | yok |
| 10.8 | Birimler | T→B | yalnız 10/10 (°C/°F) | statik | kolay | S | düşük | yok |
| 10.9 | Ekran kilidi şifresi | T→B | 2/9, 21 | runtime | kolay | S | orta | yok |
| 10.10 | Takma modu, güç modu, kopma uyarısı | ↔ | 2/14, 15, 42 | runtime / AB | kolay | S | düşük–orta | yok |
| 10.11 | Telefonun sessiz modu | ↔ | 2/43–45 | statik | hayır | — | — | — |
| 11 | Kamera uzaktan kumandası | T→B | 2/7, 8 (HID) | runtime | ayar kolay, deklanşör sistemde | S | orta | yok |
| 12.1 | Telefon GPS'iyle antrenman | ↔ | 8/30, 8/26, 8/48 | statik | oturum + arka plan konum | L | orta | yok |
| 12.2 | Canlı antrenman istatistiği | B→T | 8/50 | yok | oturum | M | düşük | yok |
| 12.3 | Telefondan antrenman, ham ivme | ↔ | 8/26, 30, 45, 49, 53 | statik (SaA) | oturum, bütün gece | L | yüksek | yok |
| 13.1 | Dosya yükleme altyapısı | T→B | 22/0 + kanal 2 | statik | önde çalışırken | L | orta | yok |
| 13.2 | Kadran listele / değiştir / sil | T→B | 4/0, 1, 2 | statik | kolay | S | düşük | yok |
| 13.2 | Kadran yükle | T→B | 4/4, 4/5 + 22/0 | statik | önde çalışırken | M | orta | yok |
| 13.3 | Hızlı uygulama (RPK) | T→B | 20/0–4 + 22/0 | statik | kolay / yükleme önde | S–M | orta | yok |
| 13.5 | Firmware güncelleme | T→B | 2/5 + 22/0 | statik, dosya tanınmıyor | önde çalışırken | M | **yüksek** | yok |
| 14 | Cihaz bilgisi, depolama | T→B | 2/2, 2/62 | statik / AB | kolay | S | düşük | yok |
| 15 | Kişiler, acil durum kişisi | ↔ | 21/2, 3, 7; 21/0, 1 | yok / AB | izin (Kişiler) | S–M | orta | yok |
| 16.1 | Bantta internet (ağ vekili) | ↔ | 2/92 + kanal 7 | AB | oturum + TCP/IP yığını | L | yüksek | yok |
| 16.2 | Hızlı uygulamayla mesajlaşma | ↔ | 20/6–9 | AB | oturum + bant uygulaması | L | orta | yok |
| 16.3 | Kadın sağlığı, rota, tıbbi kimlik, temel veri... | ↔ | 8/7, 20, 37–41, 44, 57–62... | AB | çoğu kolay | S–L | orta | yok |
| 16.6 | Bilinmeyen 2/110 | B→T | 2/110 | — | loglanmalı | S | düşük | loglanıyor, çözülmüyor |

## 3. Bildirimler ve aramalar

### 3.1 Özel bildirim gönderme

- **Ne yapar:** Bantta başlık, gövde ve uygulama adıyla bir bildirim gösterir, titreşir.
- **Yön:** telefon → bant.
- **Mesaj:** `Command{7,0}` → `Command.notification(9).notification2(3).notification3(1).{package 1, appName 2, title 3, unknown4 4 (""), body 5, timestamp 6 "yyyyMMdd'T'HHmmss" (yerel saat), id 7 (uint32), isCall 8, repliesAllowed 11, key 12, openOnPhone 13}` [KOD] `P/xiaomi/wear_notification.proto:6-46`, `X/services/XiaomiNotificationService.java:63`, `:174-236`.
  - `appName` boşsa bildirim görünmüyor; Gadgetbridge bu yüzden `"UNKNOWN"` yazıyor (`:208-213`).
  - `title` olarak gönderen ya da başlık (`:199-202`).
  - `openOnPhone 13 = true` yalnız `key 12` ile birlikte anlamlı; `key` biçimi `"0|<package>|<id>|null|12345"` (`P/xiaomi/wear_notification.proto:44-45`, `X/services/XiaomiNotificationService.java:215-218`).
  - Bant `package`'a göre ikon arar (bölüm 3.4). Bilinmeyen paket için genel ikon [TAHMİN].
  - Emoji: Gadgetbridge Xiaomi'de Unicode emoji destekli sayıyor ve bazılarını eşliyor [KOD] `XD/XiaomiCoordinator.java:544-546`, `X/XiaomiSupport.java:596-640`.
  - AstroBox aynı mesajı (`notification2(3)` → `data(1)`) `NotifyData{app_id 1, app_name 2, title 3, sub_title 4, text 5, date 6, uid 7, call_type 8, app_group 9, call_number 10, support_reply 11, key 12, support_open 13, focus 14, focus_v2 15}` olarak tanımlıyor; 1–7, 9, 10 ve 12 `required` [AB] `ABP/wear_notification.proto:66-127`. Gadgetbridge 9 ve 10'u göndermiyor; Gadgetbridge'in bildirimleri çalıştığına göre bant eksik `required` alanları tolere ediyor [TAHMİN]. AstroBox `date` alanına milisaniye cinsinden epoch yazıyor, Gadgetbridge `yyyyMMdd'T'HHmmss` [AB] `ABC/device/xiaomi/components/notification.rs:79-118`.
  - **Canlı bildirim (Focus):** `focus 14 {style 1, title 2, content 3, desc 4, progress 5{section_count 1, progress 2, color 3}, updatable 6, sequence 7}` ve `focus_v2 15`. HyperOS'un ilerleme çubuklu "canlı etkinlik" bildirimleri; aynı `uid`/`key` ile yeniden gönderilip güncellenir [AB] `ABP/wear_notification.proto:92-110`, `ABC/device/xiaomi/components/notification.rs:11-15`, `:81-85`. Freeband için zamanlayıcı, antrenman ya da senkron ilerlemesi gibi şeyler bantta canlı gösterilebilir. Band 10'un bunu desteklediği doğrulanmadı [TAHMİN].
- **Beyan:** statik. Bildirim ayarları her Xiaomi cihazında var [KOD] `XD/XiaomiCoordinator.java:644-658`.
- **iOS:** **Freeband'de var** [FB] `FB/Band/MiProtocol.swift:355-379`, `FB/App/AppModel.swift:64-68`, `FB/UI/ToolsSheet.swift`. Kullanım alanı Freeband'in kendi içeriği: hub/webhook olayları, sağlık uyarıları, hatırlatmalar, Kısayollar otomasyonları. Başka uygulamaların bildirimleri ANCS'in işi (bölüm 1.3). Aynı bildirimi hem ANCS hem Freeband iletirse çift görünür; Freeband sistem bildirimlerini asla yansıtmamalı.
  - Fırsat: bir **App Intent** ("Banda bildirim gönder") ile Kısayollar ve Otomasyonlar uygulamayı arka planda çalıştırıp bildirimi gönderebilir. Bağlantı zaten iOS'ta açık olduğu için `retrieveConnectedPeripherals` ile auth + gönderim yaklaşık 1 sn [ÖLÇÜM] `findings.md` §1. Arka planda CoreBluetooth'un çalışması için `bluetooth-central` arka plan modunun bildirilmesi gerekir; oturumu sürekli tutmak gerekmez [iOS].
- **Efor / risk:** S (yapıldı) / düşük.

### 3.2 Bildirimi banttan kaldırma

- **Ne yapar:** Daha önce gönderilen bildirimi banttan siler. Ters yönde, kullanıcı bantta bildirimi kapatınca telefona haber verir.
- **Yön:** iki yönlü.
- **Mesaj:** `Command{7,1}` → `Command.notification(9).notificationDismiss(4).notificationId(1)[].{id 1, package 2, key 4}` [KOD] `P/xiaomi/wear_notification.proto:48-56`, `X/services/XiaomiNotificationService.java:238-276`. Bant aynı subtype ile kendi kapattıklarını bildirir (`:109-117`).
- **Beyan:** statik.
- **iOS:** telefon → bant yönü kısa oturumla yapılır (ör. hub'daki bir uyarı çözülünce). Bant → telefon yönü tutulan oturum ister ve Freeband'in kendi bildirimleri dışında anlamı yok.
- **Efor / risk:** S / düşük.

### 3.3 "Telefonda aç"

- **Ne yapar:** Bantta bildirime "Telefonda aç" düğmesi koyar; basılınca telefona haber gelir.
- **Yön:** telefon → bant (`openOnPhone 13 = true`, `key 12`), sonra bant → telefon.
- **Mesaj:** bant → telefon `Command{7,8}` → `Command.notification(9).openOnPhone(2).{id 1, package 2, key 4}` [KOD] `P/xiaomi/wear_notification.proto:7-8`, `X/services/XiaomiNotificationService.java:140-145`.
- **Beyan:** statik.
- **iOS:** tutulan oturum gerekir. Uygulama arka plandayken kendini öne getiremez; en fazla yerel bildirim gösterip dokunulunca ilgili ekranı açar [iOS]. Değeri düşük.
- **Efor / risk:** M (tutulan oturum varsa S) / düşük.

### 3.4 Bildirim ikonları

- **Ne yapar:** Bant bir uygulamanın ikonunu bilmiyorsa telefondan ister; telefon bitmap'i yükler.
- **Yön:** bant → telefon isteği, telefon → bant yükleme.
- **Mesaj (sıra):** [KOD] `X/services/XiaomiNotificationService.java:446-480`, `:525-561`, `P/xiaomi/wear_notification.proto:22-27`, `:64-79`
  1. bant → `Command{7,16}` `notification(9).notificationIconQuery(16).{package 1}` (paket adı kırpılmış gelebilir).
  2. telefon → `Command{7,15}` `notification(9).notificationIconReply(14).{package 1}`.
  3. bant → `Command{7,15}` `notification(9).notificationIconRequest(15).{status 1 (0 = devam), pixelFormat 2, size 3}`.
  4. telefon → DataUpload, tip 50 (bölüm 13.1), içerik `size × size` ham piksel.
  - Piksel biçimleri: 0 RGB565 LE, 1 RGB565 BE, 2 XRGB8888 LE, 3 ARGB8888 LE, 7 ARGB8565 LE, 8 ABGR8565 LE [KOD] `X/XiaomiBitmapUtils.java:39-44`, dönüşümler `:75-148`.
- **Beyan:** statik (bildirim servisiyle birlikte).
- **iOS:** tutulan oturum ve dosya yükleme altyapısı gerekir. Başka uygulamaların ikonuna iOS'ta erişim yok [iOS]; yalnız Freeband'in kendi `package`'ı için gömülü bir ikon anlamlı.
- **Efor / risk:** M (yükleme altyapısı bölüm 13 ile ortak) / düşük.

### 3.5 Gelen arama

- **Ne yapar:** Bantta arayan adı/numarasıyla arama ekranı; bantta reddet ya da sustur.
- **Yön:** iki yönlü.
- **Mesaj:**
  - telefon → `Command{7,0}` `notification3(1).{id 7 = 0, package 1 = "phone", appName 2 = "phone", title 3 = ad, body 5 = numara, isCall 8 = true, repliesAllowed 11, timestamp 6}` [KOD] `X/services/XiaomiNotificationService.java:302-338`.
  - arama bitince telefon → `Command{7,1}` `notificationDismiss(4).notificationId(1).{id 1 = 0, package 2 = "phone"}` (`:283-299`).
  - bant → telefon `Command{7,2}` reddet, `Command{7,5}` yok say (`:118-127`).
  - AstroBox'ta `isCall 8` bool değil `call_type 8` enum'u: 0 yok, 1 gelen, 2 cevapsız, 3 giden; numara `call_number 10`. Reddet `2` ve sustur `5` yüksüz gelir; **"cevapla" komutu yok** [AB] `ABP/wear_notification.proto:7-12`, `:24-43`.
- **Beyan:** statik.
- **iOS:** **Yapılamaz ve gerekmez.** Üçüncü parti uygulama gelen aramanın numarasını/adını öğrenemez (`CXCallObserver` yalnız durum verir) ve aramayı reddedemez [iOS]. Gelen arama ANCS'in `IncomingCall` kategorisiyle zaten banta gidiyor [iOS, banttaki karşılığı TAHMİN].
- **Efor / risk:** — / —.

### 3.6 Hazır cevaplar (canned replies)

- **Ne yapar:** Bantta aramayı reddedip SMS ile hazır cevap gönderme listesi.
- **Yön:** iki yönlü.
- **Mesaj:** [KOD] `X/services/XiaomiNotificationService.java:358-440`, `:482-523`, `P/xiaomi/wear_notification.proto:13-20`, `:58-75`
  - GET `Command{7,9}` `notification(9).unknown8(8) = 1` → cevap `notification(9).cannedMessages(9).{minReplies 1, reply 2[], maxReplies 3}`.
  - SET `Command{7,12}` aynı `cannedMessages(9)`; `minReplies`'a kadar `"-"` ile doldurulur (`:387-389`).
  - bant → `Command{7,13}` `notificationReply(12).{unknown1 1, message 2, unknown3 3, number 4}` → telefon SMS atar, aramayı reddeder, `Command{7,14}` `notificationReplyStatus(13)` = 0 başarı / 1 hata.
  - AstroBox adları: `reply_msg(9){target 1 (1 SMS, 2 WeChat), contents 2[], support_max_numbers 3}`, ekle `7,10`, sil `7,11`, sonuç `reply_msg_result(11)`; cevap isteği `reply_request(12){target 1, contents 2, need_result 3, phone_number 4 | notify_id 5}`, sonuç `reply_result(13)`: 0 başarı, 1 hedef desteklenmiyor, 2 bildirim yok, 3 izin yok, 4 hata [AB] `ABP/wear_notification.proto:14-20`, `:141-175`. Yalnız metin; emoji ya da ses id'si yok.
- **Beyan:** runtime; bant `maxReplies > 0` dönerse açılır [KOD] `XD/XiaomiCoordinator.java:457-459`, `:652-654`.
- **iOS:** listeyi bantta düzenlemek mümkün (S), ama cevabı **göndermek mümkün değil**: iOS'ta SMS yalnız kullanıcı onaylı `MFMessageComposeViewController` ile gider, arama reddedilemez [iOS]. Freeband `Command{7,13}` gelirse `status 1` dönmeli.
- **Efor / risk:** S (yalnız liste) / düşük; değer düşük.

### 3.7 Bildirimde ekranı aç

- **Ne yapar:** Bildirim gelince bant ekranı yansın mı.
- **Yön:** telefon → bant.
- **Mesaj:** GET `Command{7,6}`, SET `Command{7,7}` → `Command.notification(9).screenOnOnNotifications(7)` (bool) [KOD] `X/services/XiaomiNotificationService.java:128-139`, `:341-356`, `P/xiaomi/wear_notification.proto:12`.
  - Proto'da ayrıca `Command{2,15}` `system(4).miscSettingSet(35).miscNotificationSettings(1).{wakeScreen 1, onlyWhenPhoneLocked 2, onlyWhenWorn 3}` (0 dokunma, 1 aç, 2 kapat) var, Gadgetbridge göndermiyor [KOD] `P/xiaomi/wear_system.proto:213-223`.
- **Beyan:** runtime (`FEAT_SCREEN_ON_ON_NOTIFICATIONS`) [KOD] `XD/XiaomiCoordinator.java:648-650`.
- **iOS:** sorunsuz.
- **Efor / risk:** S / düşük.

### 3.8 Uygulama başına bildirim izni

- **Ne yapar:** Bantın hangi uygulamaların bildirimini göstereceği listesi.
- **Mesaj:** GET `Command{7,3}` → `notification(9).app_info_list(6)`, SET `Command{7,4}` → `notification(9).app_info(5).{app_type 1, enable 2}`; `app_type` Xiaomi'nin sabit listesi, ör. WhatsApp 68, Telegram 72, Messenger 73, Discord 74, LINE 77, Twitter 78, Gmail 79, Outlook 80, Facebook 81, Instagram 88, YouTube 89 [AB] `ABP/wear_notification.proto:198-300`. Eşleme adlardan çıkarım [TAHMİN].
- **Beyan:** yok (Gadgetbridge'de yok).
- **iOS:** ANCS ile gelen bildirimleri bantın bu listeye göre süzüp süzmediği bilinmiyor [TAHMİN]. Süzüyorsa, iPhone'da Bildirimler ayarına dokunmadan banttaki gürültüyü azaltmanın tek yolu bu olur.
- **Efor / risk:** S (doğrulandıktan sonra) / orta.

### 3.9 Navigasyon

- **Ne yapar:** Adım adım yol tarifi. Gadgetbridge Xiaomi'de bunu ayrı bir protokolle değil, **sıradan bildirimlerle** yapıyor [KOD] `GB/service/AbstractDeviceSupport.java:658-666`.
- **Beyan:** statik; Band 10 açıkça `true` [KOD] `W/MiBand10Coordinator.java:85-88`, ortak `XD/XiaomiCoordinator.java:767-770`.
- **iOS:** Apple/Google Haritalar'ın navigasyon durumuna erişim yok [iOS]. Ancak Freeband kendi rotasını (MapKit) hesaplarsa bölüm 3.1 ile gönderebilir.
- **Efor / risk:** L / düşük; değer düşük.

## 4. Bulma ve titreşim

### 4.1 Bandı bul (titret)

- **Ne yapar:** Bant, kullanıcı bantta dokunana ya da telefon durdurana kadar titrer.
- **Yön:** telefon → bant; bantta "buldum"a basılınca bant → telefon.
- **Mesaj:** `Command{2,18}` → `Command.system(4).findDevice(5)`: 0 başlat, 1 durdur [KOD] `P/xiaomi/wear_system.proto:16-17`, `X/services/XiaomiSystemService.java:941-952`. Bant aynı subtype ile döner (`:201-206`).
- **Beyan:** statik `true` [KOD] `XD/XiaomiCoordinator.java:534-536`; yalnız Band 9 Active kapatıyor (`W/MiBand9ActiveCoordinator.java:53-56`).
- **iOS:** **Freeband'de var** [FB] `FB/Band/MiProtocol.swift:381-391`, `FB/App/AppModel.swift:70-73`. Gadgetbridge bunu Sleep as Android alarmında titreşim darbesi olarak da kullanıyor [KOD] `X/XiaomiSupport.java:588-594`; yani "bileği titret" ilkeli olarak kullanılabilir (zamanlayıcı, sessiz uyarı).
- **Efor / risk:** S (yapıldı) / düşük.

### 4.2 Telefonu bul

- **Ne yapar:** Bantta "Telefonu bul"a basılınca telefon çalar.
- **Yön:** bant → telefon (başlat/durdur), telefon → bant (telefonda durdurulunca bantı susturmak).
- **Mesaj:** bant → `Command{2,17}` `system(4).findDevice(5)`: 0 başlat, diğer değer durdur [KOD] `X/services/XiaomiSystemService.java:189-200`. Telefon kendi tarafında durdurunca `Command{2,17}` `findDevice(5) = 1` (`:917-931`).
- **Beyan:** statik (`supportsFindDevice`).
- **iOS:** tutulan oturum şart. **Freeband'de var, saatte henüz denenmedi**: "Bağlı kal" ayarı ve çalma, ayrıntılar ve denenecekler `docs/STAY-CONNECTED.md`'de. Ses çalmak için seçenekler [iOS]:
  - yerel bildirim + ses: kolay, ama sessiz anahtar ve Odak modlarına takılır;
  - `audio` arka plan modu + `AVAudioSession` `.playback`: sessiz anahtarı yok sayar, ama arka planda sıfırdan çalmaya başlamak ve App Store incelemesi riskli;
  - Critical Alerts: Apple'dan özel yetki ister.
- **Efor / risk:** M (tutulan oturumdan sonra) / orta (arka planda ses).

### 4.3 Titreşim desenleri

- **Ne yapar:** Bildirim türlerine (arama, alarm, etkinlik...) farklı titreşim atama; özel desen oluşturma, silme, deneme.
- **Yön:** telefon → bant.
- **Mesaj:** [KOD] `P/xiaomi/wear_system.proto:63-79`, `:268-317`, `X/services/XiaomiVibrationManager.java:44-46`, `:62-165`
  - GET `Command{2,46}` → `system(4).vibrationPatterns(38).{notificationType 1[].{notificationType 1, preset 2}, unknown2 2 (50, olası üst sınır), customVibrationPattern 3[].{id 1, name 2, vibration 3[].{vibrate 1 (0/1), ms 2, strength 3}, type 4}}`. GET desen segmentlerini hiç döndürmez.
  - Oluştur `Command{2,58}` `system(4).vibrationPatternCreate(40)` = `CustomVibrationPattern`; `id` yoksa bant sessizce yok sayar; `type = 1` (arama) olan yeni desen otomatik olarak aramaya atanır (`X/services/XiaomiVibrationManager.java:35-40`).
  - Sil `Command{2,61}` `system(4).vibrationRemove(42).{id 1[]}`.
  - Cevap `system(4).vibrationPatternAck(43).{status 1}`: 0 OK, 1 sayı sınırı, 2 id yok.
  - Proto'da var, Gadgetbridge göndermiyor: atama `Command{2,47}` `vibrationSetPreset(39).{notificationType 1, preset 2}`, deneme `Command{2,59}` `vibrationTestCustom(41).{vibration 1[]}`.
  - `VibrationType`: 0 yok, 1 arama, 2 görev, 3 alarm, 4 bildirim, 5 hareketsizlik, 6 SMS, 7 hedef, 8 etkinlik.
  - AstroBox adları ve fazlası [AB] `ABP/wear_system.proto:108-113`, `:828-886`: GET cevabı `vibrator_setting(38){items 1, max_number 2, vibrators 3, version 4}`; atama `Vibrator_item(39){type 1, id 2, supported_builtin_ids 3}`; güncelle `Command{2,60}` `Vibrator(40)`; deneme `Command{2,59}` `vibrator_effect(41){segments 1[]{on 1, duration 2 (ms), strength 3}, item 2}`. `item` verilirse kayıtlı bir desen denenir.
  - Örnek deneme, 200 ms titre / 100 ms dur / 200 ms titre: `08 02 10 3b 22 17 ca 02 14 0a 05 08 01 10 c8 01 0a 04 08 00 10 64 0a 05 08 01 10 c8 01` (şifrelemeden önce).
- **Beyan:** Band 10 statik `true`, yerleşik desen id'leri 250–255 (Good day, Beeper, Toybox, Iced latte, Jump, Wave) silinmemeli [KOD] `W/MiBand10Coordinator.java:61-83`. Band 10 Pro beyan etmiyor (varsayılan `false`), aynı yazılım ailesi olduğu için çalışması muhtemel [TAHMİN].
- **iOS:** sorunsuz. `Command{2,59}` (deneme) bildirim göndermeden **istenen desende anlık titreşim** demek; zamanlayıcı ya da "nabız yüksek" gibi uyarılar için iyi bir ilkel olabilir [TAHMİN, denenmedi].
- **Efor / risk:** M (desen düzenleyici arayüzü) / düşük–orta.

## 5. Zaman, alarm, takvim

### 5.1 Saat ve saat dilimi

- **Ne yapar:** Bantın saatini, tarihini, saat dilimini ve 12/24 saat biçimini ayarlar.
- **Yön:** telefon → bant.
- **Mesaj:** `Command{2,3}` → `Command.system(4).clock(4).{date 1{year 1, month 2, day 3}, time 2{hour 1, minute 2, second 3, millisecond 4}, timezone 3{zoneOffset 1 (sint32, 15 dk blok, DST hariç), dstOffset 2 (sint32, 15 dk blok), name 3 (IANA adı, ör. "Europe/Istanbul")}, isNot24hour 4}` [KOD] `P/xiaomi/wear_system.proto:110-115`, `P/xiaomi/wear_common.proto:10-28`, `X/services/XiaomiSystemService.java:318-355`. Tarih ve saat **yerel** değerler.
  - AstroBox `Timezone`'a `id_spec 4` (zorunlu, AstroBox `""` yolluyor) ekliyor ve ofsetleri `int32` sayıyor [AB] `ABP/wear_common.proto:545-550`, `ABC/device/xiaomi/components/sync.rs:77-110`. Gadgetbridge'in `sint32` kodlaması sahada çalışan yol (bölüm 16.3).
- **Beyan:** statik; Gadgetbridge her auth'tan hemen sonra gönderiyor [KOD] `X/XiaomiSupport.java:453-460`, `:277-284`.
- **iOS:** `zoneOffset = (TimeZone.current.secondsFromGMT() − daylightSavingTimeOffset()) / 900`, `dstOffset = daylightSavingTimeOffset() / 900`, `name = TimeZone.current.identifier`. Her bağlantıda ve `NSSystemTimeZoneDidChange` / `significantTimeChangeNotification` sonrası gönderilmeli. Mi Fitness kaldırılınca saat dilimi değişikliğini (seyahat, yaz saati) bantla senkronlayan tek şey bu olur.
- **Efor / risk:** S / düşük.

### 5.2 Alarmlar

- **Ne yapar:** Bantın kendi titreşimli alarmlarını listeler, ekler, düzenler, siler; akıllı uyandırma.
- **Yön:** telefon → bant (bant listeyi döner).
- **Mesaj:** [KOD] `P/xiaomi/wear_clock.proto:7-63`, `X/services/XiaomiScheduleService.java:68-90`, `:439-606`
  - GET `Command{17,0}` → `schedule(19).alarms(1).{alarm 1[].{id 1 (1'den başlar), alarmDetails 2}, maxAlarms 2 (10), unknown3 3, unknown4 4}`.
  - `AlarmDetails = {time 2{hour 1, minute 2}, repeatMode 3 (0 bir kez, 1 her gün, 5 haftalık), repeatFlags 4 (yalnız haftalık; gün bit maskesi, Pzt = 1, Sal = 2, ..., hafta içi = 31), enabled 5, smart 7 (1 akıllı, 2 normal)}`.
  - Ekle `Command{17,1}` `schedule(19).createAlarm(2)` = `AlarmDetails`; bant aynı subtype ile döner, `ackId 4` yeni id [KOD] `P/xiaomi/wear_clock.proto:15`, Gadgetbridge sonra listeyi yeniden ister (`X/services/XiaomiScheduleService.java:119-128`).
  - Düzenle `Command{17,2}` `schedule(19).editAlarm(3)` = `AlarmInfo{id 1, alarmDetails 2}`. Gadgetbridge protosunun yorumu "17, 3" diyor (`P/xiaomi/wear_clock.proto:12-13`), kod 2 kullanıyor (`X/services/XiaomiScheduleService.java:72`); AstroBox'ta `UPDATE_CLOCK = 2`, `3` tek alarm silme, yani kod doğru [AB] `ABP/wear_clock.proto:22-45`.
  - Sil `Command{17,4}` `schedule(19).deleteAlarm(5).{id 1[]}`. AstroBox'ta ayrıca `17,3` tek id ile silme ve `17,5` aç/kapat var.
  - AstroBox `clock_data` alarma **etiket** de veriyor: `{time 2, clock_mode 3, week_days 4, enable 5, label 6}` (`label` AstroBox'ta `required`, Gadgetbridge göndermiyor); `clock_mode` daha zengin (0 bir kez, 1 her gün, 2 iş günü, 3 tatil, 4 Pzt–Cum, 5 özel, 6 haftalık, 7 aylık, 8 yıllık). Gadgetbridge'in `smart 7` alanı AstroBox'ta yok [AB] `ABP/wear_common.proto:511-522`, `ABP/wear_clock.proto:69-86`.
- **Beyan:** statik (`supportsAlarms`, `supportsSmartWakeup`), slot sayısı runtime [KOD] `XD/XiaomiCoordinator.java:265-272`, `:790-792`.
- **iOS:** saf CRUD, arka plan gerekmez. iPhone Saat alarmları okunamaz [iOS]; Freeband kendi alarm ekranını sunar. Değeri yüksek: sessiz bilek alarmı.
- **Efor / risk:** S / düşük.

### 5.3 Hatırlatıcılar

- **Ne yapar:** Bantta tarih/saatli, tekrar edebilen kısa metinli hatırlatıcılar.
- **Yön:** telefon → bant.
- **Mesaj:** [KOD] `P/xiaomi/wear_clock.proto:23-38`, `:76-96`, `X/services/XiaomiScheduleService.java:184-402`
  - GET `Command{17,14}` → `schedule(19).reminders(10).{reminder 1[].{id 1, reminderDetails 2}, maxReminders 2}`.
  - `ReminderDetails = {date 1{year, month, day}, time 2{hour, minute, second, millisecond}, repeatMode 3 (0 bir kez, 1 her gün, 5 haftalık, 7 aylık, 8 yıllık), repeatFlags 4 (haftalıkta gün bayrağı), title 5}`. Gadgetbridge tarih/saati **UTC** yazıyor ve yorumda bundan emin olmadığını söylüyor [KOD] `X/XiaomiPreferences.java:81-91`, `X/services/XiaomiScheduleService.java:318-333`.
  - Ekle `Command{17,15}` `createReminder(14)`; düzenle `Command{17,17}` `editReminder(15)` = `{id 1, reminderDetails 2}`; sil `Command{17,18}` `deleteReminder(17).{id 1[]}`.
  - Başlık uzunluğu: Gadgetbridge 20 karakter varsayıyor, doğrulanmamış [KOD] `XD/XiaomiCoordinator.java:446-449`.
  - AstroBox'a göre hatırlatıcılar aslında **yapılacaklar**: `reminder_data` ayrıca `truncated 6, source 7, status 8, update_time 9, sub_list 10[]{id 1, status 2, content 3, truncated 4}` taşıyor; bant `Command{17,20}` `reminder_mark(18)` ile "yapıldı" işaretini telefona bildirir, `17,21` ile listeyi ister, `17,19` toplu senkron [AB] `ABP/wear_clock.proto:132-173`. Bu kısımlar Gadgetbridge'de yok.
- **Beyan:** runtime (slot sayısı bant cevabından) [KOD] `XD/XiaomiCoordinator.java:452-454`.
- **iOS:** sorunsuz; istenirse EventKit Anımsatıcılar'dan beslenebilir (izin gerekir).
- **Efor / risk:** S / düşük (UTC/yerel saat bantta doğrulanmalı).

### 5.4 Takvim senkronu

- **Ne yapar:** Yaklaşan etkinlikleri bantın takvim ekranına yazar; bant hatırlatır.
- **Yön:** telefon → bant.
- **Mesaj:** `Command{12,1}` → `Command.calendar(14).calendarSync(2).{event 1[].{title 1, description 2, location 3, start 4 (Unix sn), end 5 (Unix sn), allDay 6, notifyMinutesBefore 7}, disabled 2}` [KOD] `P/xiaomi/wear_calendar.proto:6-22`, `X/services/XiaomiCalendarService.java:43-47`, `:87-149`.
  - Her seferinde **tam liste** gider (ekleme/silme yok); kapatmak için `disabled 2 = true`.
  - AstroBox'ta bant `Command{12,2}` ile listeyi kendisi isteyebiliyor; `12,0` tek etkinlik gönderimi [AB] `ABP/wear_calendar.proto:7-32`.
  - Gadgetbridge en fazla 50 etkinlik varsayıyor (doğrulanmamış) ve aynı liste değişmediyse göndermiyor (`:47`, `:130-133`).
- **Beyan:** statik `true` [KOD] `XD/XiaomiCoordinator.java:325-327`.
- **iOS:** EventKit tam erişim izni (iOS 17'de `requestFullAccessToEvents`), `EKEventStoreChanged` bildirimi. Her bağlantıda gönderilir; arka plan gerekmez.
- **Efor / risk:** S–M / düşük.

### 5.5 Dünya saati

- **Ne yapar:** Bantın dünya saati ekranındaki şehirler.
- **Yön:** telefon → bant.
- **Mesaj:** GET `Command{17,10}`, SET `Command{17,11}` → `Command.schedule(19).worldClocks(11).{worldClock 1[] (string)}`; proto yorumu silme için `17,13` diyor [KOD] `P/xiaomi/wear_clock.proto:26-29`, `:98-100`, `X/services/XiaomiScheduleService.java:404-437`.
  - Değerler saat dilimi adı değil, Xiaomi şehir kodu: Gadgetbridge yalnız iki tanesini biliyor, `Europe/Lisbon → "C173"`, `Australia/Sydney → "C151"` (`:95-99`).
  - AstroBox: `17,11` tek şehir ekleme `world_clock_id(12)` (string), `17,12` tek silme, `17,13` hepsini silme; sonuç `world_clock_result(13)`: 0 başarı, 1 id desteklenmiyor, 2 sınır aşıldı [AB] `ABP/wear_clock.proto:14-18`, `:110-112`. Örnek `["C173"]`: `08 11 10 0b 9a 01 08 5a 06 0a 04 43 31 37 33`.
- **Beyan:** **yok**: `getWorldClocksSlotCount() = 0`, ayar ekranı gizli [KOD] `XD/XiaomiCoordinator.java:462-478`, `:589-591`.
- **iOS:** sorun kod tablosu: üç kaynağın hiçbirinde tam liste yok. Kullanıcı bantta birkaç şehir ekleyip Freeband GET ile okuyarak kod biriktirebilir; `id desteklenmiyor` cevabı yanlış kodu ayıklar.
- **Efor / risk:** M / orta (kod tablosu yok).

### 5.6 Uyku modu programı

- **Ne yapar:** Bantın uyku modunu (ekran/bildirim kısıtları) belirli saatlerde otomatik açar.
- **Yön:** telefon → bant.
- **Mesaj:** GET `Command{17,8}`, SET `Command{17,9}` → `Command.schedule(19).sleepMode(9).{enabled 1 (zorunlu), schedule 2{start 1{hour, minute}, end 2{hour, minute}, unknown3 3 = 0}}` [KOD] `P/xiaomi/wear_clock.proto:65-74`, `X/services/XiaomiScheduleService.java:623-663`.
  - AstroBox aynı alanı `work_and_rest(9){source 1 (0 yok, 1 MIUI, 2 elle), data 2{bedtime 1, getup_time 2, remind_bed 3 (sint32)}}` olarak tanımlıyor [AB] `ABP/wear_clock.proto:92-108`. Gadgetbridge'in `enabled = true` yazması kabloda `source = 1` demek; `unknown3` büyük olasılıkla "yatma hatırlatması" dakikası [TAHMİN].
- **Beyan:** runtime (`FEAT_SLEEP_MODE_SCHEDULE`) [KOD] `XD/XiaomiCoordinator.java:620-622`.
- **iOS:** sorunsuz. iOS'un Uyku Odağı programı okunamaz [iOS]; kullanıcı Freeband'de ayarlar.
- **Efor / risk:** S / düşük.

## 6. Hava durumu

- **Ne yapar:** Bantın hava durumu ekranını ve kadran komplikasyonlarını doldurur: anlık durum, günlük ve saatlik tahmin, birden fazla konum, °C/°F.
- **Yön:** telefon → bant; bant ekranı açılınca bant → telefon güncelleme ister.
- **Mesajlar:** [KOD] `P/xiaomi/wear_weather.proto:6-97`, `X/services/XiaomiWeatherService.java:67-78`
  - Anlık `Command{10,0}` → `weather(12).current(1).{metadata 1, weatherCondition 2 (Xiaomi kodu), temperature 3, humidity 4, wind 5, uv 6, aqi 7, warning 8{warning 1[].{type 1, level 2, title 3, description 4, id 5}}, pressure 9 (float)}` (`:304-328`).
    - `metadata = {publicationTimestamp 1 ("yyyy-MM-dd'T'HH:mm:ss+03:00", iki noktalı ofset), cityName 2 (""), locationName 3, locationKey 4 ("accu:<sayı>"), isCurrentLocation 5}` (`:260-280`, `:680-686`).
    - `WeatherUnitValue = {unit 1 (string), value 2 (sint32)}`: sıcaklık `"℃"` ile tam sayı °C; nem `"%"`; rüzgâr `unit` = yön derecesi (string), `value` = Beaufort; UV `""`; AQI `"Unknown"` (`:313-321`).
  - Günlük `Command{10,1}` → `weather(12).forecast(2).{metadata 1, entries 2{entry 1[].{aqi 1, conditionRange 2{from 1, to 2}, temperatureRange 3{from 1 = en yüksek, to 2 = en düşük}, temperatureSymbol 4, sunriseSunset 5{sunrise 1, sunset 2 (ISO)}, wind 6}}}`; ilk giriş bugün, en fazla 1 + 6 gün (`:330-387`).
  - Saatlik `Command{10,2}` aynı mesaj; her giriş `temperatureRange{from 0, to = sıcaklık}`, `conditionRange{from 0, to = kod}`, `wind`; en fazla 23 saat (`:389-418`).
  - Bant → telefon `Command{10,3}` güncelleme isteği, `weather(12).location(5).{code 1, name 2}` (`:522-562`).
  - Konumlar: GET `Command{10,5}` → `locations(4).{location 1[].{code 1, name 2}}` ya da `status = 1` (tek konum destekli); sıralama `Command{10,6}` `locations(4)`; ekle `Command{10,7}` `location(5)`; sil `Command{10,8}` `locations(4)` (`:289-298`, `:437-488`, `:584-678`). Gadgetbridge en fazla 5 konum gönderiyor (`:440-450`).
  - Tercihler `Command{10,10}` → `weather(12).prefs(6).{temperatureScale 1 (1 °C, 2 °F), weatherWarningsEnabled 2 (0 desteklenmiyor, 1 açık, 2 kapalı)}` (`:498-520`).
  - Durum kodları 0–33 (0 açık, 1 bulutlu, 2 kapalı, 3 sağanak, 4 fırtına, 7 hafif yağmur, 8 orta yağmur, 14 hafif kar, 18 sis...) [KOD] `XD/XiaomiWeatherConditions.java:27-60`; OpenWeatherMap kodlarından eşleme `:63-`.
  - **Tip uyuşmazlığı:** `WeatherUnitValue.value` Gadgetbridge'de `sint32`, AstroBox'ta (`KeyValue`) `int32` [KOD] `P/xiaomi/wear_weather.proto:40-43`, [AB] `ABP/wear_common.proto:565-568`. Sıfırın altındaki sıcaklıkta fark belirgin. Gadgetbridge'inki sahada çalışan yol; Freeband `sint32` yazmalı ve ilk kışta eksi değerle doğrulamalı. Aralıklar (`WeatherRange`) ikisinde de `sint32`.
  - Uyarılar: Gadgetbridge boş liste yolluyor (`X/services/XiaomiWeatherService.java:322`); dolu `warning` göndermek yeni ve denenmemiş. AstroBox'ta ayrıca `Command{10,4}` basınç (`pressure(3)` float) [AB] `ABP/wear_weather.proto:9-30`, `:83-94`.
- **Beyan:** statik `true`; çoklu konum runtime (`FEAT_MULTIPLE_WEATHER_LOCATIONS`) [KOD] `XD/XiaomiCoordinator.java:529-531`, `X/services/XiaomiWeatherService.java:420-422`.
- **iOS:**
  - Veri: WeatherKit (ücretli geliştirici hesabı, yetki ve "Apple Weather" atfı ister) ya da Open-Meteo (anahtarsız, ücretsiz) [iOS/WEB, denenmedi].
  - Konum: CoreLocation "kullanırken" izni + önemli konum değişikliği, ya da kullanıcının seçtiği şehir. Konum izni istemeden şehir seçimi de yeter.
  - Zamanlama: her bağlantıda anlık + günlük + saatlik gönder. Bantın `Command{10,3}` isteği tutulan oturum ister; yoksa bant son gönderilen veriyi gösterir. `BGAppRefreshTask` ile periyodik gönderim mümkün ama bantla kısa bir oturum açmak gerekir [iOS, TAHMİN: arka plan görevinde BLE bağlantısının yetişmesi].
- **Efor / risk:** M / düşük. Mi Fitness olmadan bantta hava ekranı boş kalır; görünür değeri yüksek.

## 7. Müzik kontrolü ve çalan parça

- **Ne yapar:** Bantta çalan parça, sanatçı, ilerleme ve ses düzeyi; oynat/duraklat/önceki/sonraki/ses tuşları.
- **Yön:** iki yönlü.
- **Mesaj:** [KOD] `P/xiaomi/wear_media.proto:6-25`, `X/services/XiaomiMusicService.java:36-50`, `:64-164`
  - bant → `Command{18,0}` "bilgi ver" isteği.
  - telefon → `Command{18,1}` → `music(20).musicInfo(1).{state 1 (zorunlu; 0 yok, 1 çalıyor, 2 duraklatıldı), volume 2 (0–100), track 4, artist 5, position 6 (sn), duration 7 (sn)}`.
  - bant → `Command{18,2}` → `music(20).mediaKey(2).{key 1 (0 oynat, 1 duraklat, 3 önceki, 4 sonraki, 5 ses), volume 2 (ses tuşunda hedef düzey)}`.
  - AstroBox adları: `player_info(1){state 1 (0 yok, 1 çalıyor, 2 duraklatıldı, 3 durdu, 10 izin yok), volume 2, player_name 3, song_title 4, song_artist 5, current_position 6, duration 7}`, `player_control(2){command 1 (0 oynat, 1 duraklat, 2 dur, 3 önceki, 4 sonraki, 5 ses), volume 2}`. Şarkı sözü, sarma ya da çalma listesi gezintisi yok [AB] `ABP/wear_media.proto:17-98`. `state 10` bantta "izin yok" göstermek için iOS'ta işe yarayabilir.
- **Beyan:** statik `true` [KOD] `XD/XiaomiCoordinator.java:441-443`.
- **iOS:** zayıf. Başka uygulamaların çalan medyası okunamaz ve kontrol edilemez; `MPMusicPlayerController.systemMusicPlayer` yalnız Apple Music uygulamasını görür ve kontrol eder; ses düzeyi programla ayarlanamaz [iOS]. Bant iOS'ta medya kontrolünü AMS ile kendisi yapıyor olabilir, o zaman Freeband'e gerek yok [TAHMİN]. Tuş olayları tutulan oturum ister.
- **Efor / risk:** M / düşük; değer düşük (yalnız Apple Music).

## 8. Kullanıcı bilgisi ve hedefler

### 8.1 Kullanıcı bilgisi ve günlük hedefler

- **Ne yapar:** Boy, kilo, doğum tarihi, cinsiyet, maksimum nabız ve adım/kalori/ayakta/hareket hedefleri. Kalori, mesafe ve nabız bölgeleri bunlara göre hesaplanır.
- **Yön:** telefon → bant.
- **Mesaj:** `Command{8,0}` → `Command.health(10).userInfo(1).{height 1 (cm), weight 2 (float kg), birthday 3 (YYYYMMDD sayı), gender 4 (1 erkek, 2 kadın), maxHeartRate 5, goalCalories 6, goalSteps 7, goalStanding 9 (saat), goalMoving 11 (dk)}` [KOD] `P/xiaomi/wear_fitness.proto:53-63`, `X/services/XiaomiHealthService.java:344-387`. Gadgetbridge maksimum nabzı yaştan hesaplıyor (`:355-361`) ve her bağlantıda gönderiyor (`:267`).
- **Beyan:** statik (her Xiaomi).
- **iOS:** form ya da HealthKit'ten okuma (boy, kilo, doğum tarihi, cinsiyet; izin gerekir).
- **Efor / risk:** S / düşük.

### 8.2 Hedef bildirimi, ikincil hedef, vitality

- Hedefe ulaşınca titreşim: GET `Command{8,21}`, SET `Command{8,22}` → `health(10).goalNotification(13).{enabled 1, unknown2 2 = 1}` [KOD] `X/services/XiaomiHealthService.java:389-420`, `P/xiaomi/wear_fitness.proto:128-131`. Beyan runtime (`FEAT_GOAL_NOTIFICATION`).
- İkincil hedef (ayakta süre ya da hareket süresi): GET `Command{8,42}`, SET `Command{8,43}` → `health(10).goalsConfig(38).{currentGoals 1[].{id 1}, supportedGoals 2[].{id 1}}`; id 1 adım?, 2 kalori?, 3 hareket süresi, 4 ayakta süre [KOD] `X/services/XiaomiHealthService.java:422-480`, `P/xiaomi/wear_fitness.proto:182-193`. Beyan runtime (`FEAT_GOAL_SECONDARY`). Not: proto yorumu `7,43` diyor, kod `8,43`.
- Vitality skoru gösterimi: GET `Command{8,35}`, SET `Command{8,36}` → `health(10).vitalityScore(14).{sevenDay 1, dailyProgress 2}` [KOD] `X/services/XiaomiHealthService.java:482-516`.
- **iOS:** sorunsuz. **Efor / risk:** S / düşük.

## 9. Sağlık ayarları

Hepsi telefon → bant, GET/SET çifti, arka plan gerektirmez. Gadgetbridge hepsini her bağlantıda GET'liyor [KOD] `X/services/XiaomiHealthService.java:257-275`. Beyanlar statik (`supportsStressMeasurement`, `supportsSpo2`, `supportsHeartRateMeasurement` hepsi `true`) ve runtime (`FEAT_STRESS`, `FEAT_SPO2`, `FEAT_INACTIVITY`) [KOD] `XD/XiaomiCoordinator.java:344-352`, `:481-488`, `:610-619`.

### 9.1 Sürekli nabız, nabız uyarıları, uyku tespiti

- **Mesaj:** GET `Command{8,10}`, SET `Command{8,11}` → `Command.health(10).heartRate(8).{disabled 1, interval 2 (dk; 0 akıllı, 1, 10, 30), alarmHighEnabled 3, alarmHighThreshold 4 (100–150), advancedMonitoring 5{enabled 1 (zorunlu)}, unknown7 7 = 1, heartRateAlarmLow 8{alarmLowEnabled 1, alarmLowThreshold 2 (40/45/50)}, breathingScore 9, irregularRhythmAlert 10, sleepRespiratoryRate 11}` [KOD] `P/xiaomi/wear_fitness.proto:92-112`, `X/services/XiaomiHealthService.java:565-659`.
  - Kapalı = `disabled 1 = true`; akıllı = `interval 0`.
  - `advancedMonitoring` Gadgetbridge'de "uyku tespiti için nabız" ayarı (`:579`, `:634-635`).
  - `breathingScore`, `irregularRhythmAlert`, `sleepRespiratoryRate`: 0 = bu bantta yok, 1 açık, 2 kapalı. Bant 0 dönmüşse SET'te **gönderilmemeli** (`:583-586`, `:644-649`).
  - Seçenekler: kapalı, akıllı, 1, 10, 30 dk [KOD] `XD/XiaomiCoordinator.java:746-755`.
- **Efor / risk:** S / düşük (pil etkisi kullanıcıya söylenmeli: 1 dk aralık pili hızlı tüketir).

### 9.2 SpO2

- **Mesaj:** GET `Command{8,8}`, SET `Command{8,9}` → `Command.health(10).spo2(7).{unknown1 1 = 1, mode 2 (0 kapalı, 1 yalnız uykuda, 2 tüm gün), alarmLow 4{alarmLowEnabled 1, alarmLowThreshold 2 (90/85/80)}}` [KOD] `P/xiaomi/wear_fitness.proto:69-90`, `X/services/XiaomiHealthService.java:518-563`.
  - Band 10 notu: "yalnız uykuda" (1) kabloda geçerli ama ne bantta ne Xiaomi uygulamasında gösteriliyor; bantta kapalı gibi görünür [KOD] `P/xiaomi/wear_fitness.proto:71-76`.
- **Efor / risk:** S / düşük.

### 9.3 Stres

- **Mesaj:** GET `Command{8,14}`, SET `Command{8,15}` → `Command.health(10).stress(10).{allDayTracking 1, relaxReminder 2{enabled 1, unknown2 2 = 0}}` [KOD] `P/xiaomi/wear_fitness.proto:123-136`, `X/services/XiaomiHealthService.java:711-741`.
- **Efor / risk:** S / düşük.

### 9.4 Hareketsizlik (ayağa kalk) hatırlatıcısı

- **Mesaj:** GET `Command{8,12}`, SET `Command{8,13}` → `Command.health(10).standingReminder(9).{enabled 1, start 2{hour, minute}, end 3, dnd 4, dndStart 6, dndEnd 7}` [KOD] `P/xiaomi/wear_fitness.proto:114-121`, `X/services/XiaomiHealthService.java:661-709`.
- **Efor / risk:** S / düşük.

### 9.5 Uyku tespiti

Ayrı bir "uyku tespiti" komutu yok. Uyku davranışını etkileyenler: nabız ayarındaki `advancedMonitoring`, `breathingScore`, `sleepRespiratoryRate` (9.1), SpO2 modu (9.2) ve uyku modu programı (5.6). Uyku verisinin kendisi aktivite dosyalarıyla gelir (`docs/ACTIVITY.md` §6.3–6.4, §8).

### 9.6 Canlı ve tek seferlik ölçüm

- Canlı istatistik: başlat `Command{8,45}`, durdur `Command{8,46}`, bant her saniye `Command{8,47}` `health(10).realTimeStats(39).{steps 1, calories 2, unknown3 3, heartRate 4, unknown5 5, standingHours 6}` [KOD] `P/xiaomi/wear_fitness.proto:218-225`, `X/services/XiaomiHealthService.java:1019-1027`.
- Tek seferlik nabız: Gadgetbridge aynı akışı açıp ilk `heartRate > 10` gelince kapatıyor (`:992-996`, `:1045-1050`).
- **Freeband'de var** [FB] `FB/Band/BandLink.swift:247-251`, `:307-315`, durdurma `:452`.

### 9.7 Cihaz durumu: takılı mı, şarjda mı, uyuyor mu

- **Ne yapar:** Bantın bilekte olup olmadığı, şarj durumu, kullanıcının uykuda olup olmadığı, aktivite durumu.
- **Yön:** telefon → bant (GET), bant → telefon (değişince itme).
- **Mesaj:** [KOD] `P/xiaomi/wear_system.proto:81-85`, `:319-338`, `X/services/XiaomiSystemService.java:765-868`
  - GET `Command{2,78}` → `system(4).basicDeviceState(48).{isCharging 1, batteryLevel 2, isWorn 3, isUserAsleep 4, activityState 5{activityType 1, currentActivityState 2}}`.
  - Bant → `Command{2,79}` → `system(4).deviceState(49).{chargingState 1 (1 şarjda, 2 değil), wearingState 2 (1 takılı, 2 değil), sleepState 3 (1 uyku, 2 uyanık), warningState 4, activityState 5}`.
  - Pil: `Command{2,1}` → `system(4).power(2).battery(1).{level 1, state 2 (1 şarjda, 2/3 normal), lastCharge 3{state 1, timestampSeconds 2}}` [KOD] `P/xiaomi/wear_system.proto:88-101`, `X/services/XiaomiSystemService.java:370-405`. **Freeband'de seviye var**, `state` ve `lastCharge` okunmuyor.
  - AstroBox'a göre `2,79` itmesinin 4. alanı `waring` (sic): 1 nabız yüksek, 2 nabız düşük, 3 aktifken yüksek, 4 aktifken düşük; şarj alanı 1 başladı, 2 bıraktı, 3 doldu. Yani bant nabız alarmlarını telefona da bildiriyor [AB] `ABP/wear_system.proto:597-639`. Ek itmeler: `2,97` pil durumu (`battery_status(63)`), `2,91` uyarı durumu (`alert_status(58){battery 1, temperature 2, storage 3, ota 4, ..., wear 7}`, GET `2,90`) [AB] `:118-120`, `:691-732`.
- **Beyan:** runtime (`FEAT_DEVICE_ACTIONS`, bant `2,78`'e cevap verirse) [KOD] `X/services/XiaomiSystemService.java:774-779`.
- **iOS:** GET kısa oturumla; değişiklik bildirimi (`2,79`) tutulan oturum ister. Freeband'de "bant takılı değil / şarjda / uyuyor" göstermek ve Freeband'in 24 saat kadranındaki boş saatleri açıklamak için kullanışlı.
- **Efor / risk:** S / düşük.

## 10. Ekran ve sistem ayarları

Gadgetbridge bu bölümün yarısını uygulamıyor. AstroBox'ın protoları Xiaomi yazılımının kendi nanopb şemalarından türetilmiş, adlar güvenilir [AB] `ABP/clean_nanopb.py`; ama AstroBox kodu bunların çoğunu göndermiyor, id → yük eşlemesi adlardan çıkarım. Gadgetbridge'in protosunda aynı alan numarası geçiyorsa bu ikinci, bağımsız bir doğrulama sayılır ("GB# teyit").

Hepsi telefon → bant, kısa oturumla yapılır. AstroBox `System` id listesi `ABP/wear_system.proto:41-131`, yük alanları `:133-197`.

### 10.1 Bileği kaldırınca ekran

- **Mesaj:** GET `Command{2,24}`, SET `Command{2,25}` → `Command.system(4).wrist_screen(7).{timing_mode 1 (0 tüm gün açık, 1 zamanlı, 2 kapalı, 3 akıllı), start_time 2{hour 1, minute 2}, end_time 3, sensitivity 4 (0 yok, 1 standart, 2 yüksek)}` [AB] `ABP/wear_system.proto:23-29`, `:67-68`, `:297-309`. Gadgetbridge protosu aynı alanı `raiseToWake 7 {mode 1 (0 tüm gün, 1 zamanlı, 2 kapalı), start 2, end 3}` olarak biliyor (GB# teyit) ama göndermiyor [KOD] `P/xiaomi/wear_system.proto:19-20`, `:118-122`.
  - Örnek, tüm gün + standart hassasiyet: `08 02 10 19 22 06 3a 04 08 00 20 01` (şifrelemeden önce).
- **Beyan:** yok (Gadgetbridge uygulamıyor).
- **Efor / risk:** S / düşük–orta (önce GET'le gerçek değerleri gör).

### 10.2 Rahatsız etmeyin (DND)

- **Mesaj:** GET `Command{2,22}`, SET `Command{2,23}` → `Command.system(4).timing_setting(11).{timing_mode 1 (0 tüm gün açık, 1 zamanlı, 2 kapalı, 3 akıllı), start_time 2, end_time 3, repeat_days 4 (bit maskesi), timestamp 5}` [AB] `ABP/wear_system.proto:65-66`, `:144`, `:289-295`. Gadgetbridge protosu alan 11'i `dndStatus{status 1: 0 açık, 2 kapalı}` olarak biliyor (GB# teyit) [KOD] `P/xiaomi/wear_system.proto:28-29`, `:205-207`; Gadgetbridge yalnız bantın kendi gönderdiği `2,23`'ü logluyor, yani kullanıcı bantta DND'yi değiştirince bant telefona haber veriyor [KOD] `X/services/XiaomiSystemService.java:91`, `:177-179`.
  - Örnek, 22:00–07:00 zamanlı: `08 02 10 17 22 10 5a 0e 08 01 12 04 08 16 10 00 1a 04 08 07 10 00`.
  - Telefonla senkron bayrağı: `Command{2,15}` `system(4).system_setting(35).dnd_mode(2).{sync_with_phone 1}` [AB] `ABP/wear_system.proto:749-813`; Gadgetbridge adı `miscSettingSet(35).dndSync(2){enabled 1}` [KOD] `P/xiaomi/wear_system.proto:213-227`.
- **Beyan:** yok.
- **iOS:** elle DND ayarı S. iPhone'un Odak durumunu banta yansıtmak için `INFocusStatusCenter` yalnız "odak açık mı" bilgisini izinle verir, değişince uygulamayı uyandırmaz [iOS]; tam senkron mümkün değil, uygulama açıldıkça güncellenebilir.
- **Efor / risk:** S / düşük.

### 10.3 Ekran gece modu

- **Mesaj:** GET `Command{2,10}`, SET `Command{2,11}` → `Command.system(4).night_mode(23).{mode 1 (1 kapalı, 2 gün batımında, 3 zamanlı), start_time 2, end_time 3}` [AB] `ABP/wear_system.proto:58-59`, `:156`, `:260-271`. Eşleme adlardan çıkarım [TAHMİN].
- **Beyan:** yok. **Efor / risk:** S / orta (doğrulanmamış eşleme).

### 10.4 Parlaklık, ekran zaman aşımı, AOD

- **Parlaklık ve ekran zaman aşımı için hiçbir kaynakta alan yok.** AstroBox'taki tek `brightness`, gösterge LED'i (`system_setting.indicator_light{brightness 1}`) ve fabrika modu (`Factory` type 13, id 5) [AB] `ABP/wear_system.proto:776-778`, `ABP/wear_factory.proto:24`, `:45`. Fabrika komutları son kullanıcıya göre değil.
- **AOD:** GET `Command{2,65}`, SET `Command{2,66}` tanımlı, yük mesajı yok; `timing_setting(11)` olması muhtemel (`SMART_ON` AOD'a uyuyor) [AB] `ABP/wear_system.proto:106-107`, [TAHMİN]. Önce yüksüz GET gönderip cevabın iç etiketine bakmak gerek.
- **Efor / risk:** AOD S (yakalamadan sonra) / orta; parlaklık ve zaman aşımı yapılamaz.

### 10.5 Ekran öğeleri, uygulama sırası, kısayollar

- **Uygulama listesi ve sırası:** GET `Command{2,29}`, SET `Command{2,30}` → `Command.system(4).displayItems(10).{displayItem 1[].{code 1, name 2, disabled 3, isSettings 4, unknown5 5 (= 1), inMoreSection 6}}` [KOD] `P/xiaomi/wear_system.proto:25-26`, `:136-147`, `X/services/XiaomiSystemService.java:544-672`. Liste sırası = bantta görünme sırası. AstroBox adları `app_list(10).list[]{id 1, name 2, hidden 3, persist 4, can_more 5, in_more 6}` (GB# teyit) [AB] `ABP/wear_system.proto:72-73`, `:399-411`.
  - Ayarlar öğesi (`isSettings = 1`) hep etkin kalmalı; Gadgetbridge zorla ekliyor (`X/services/XiaomiSystemService.java:572-574`, `:596-598`).
  - SET'te tüm öğeler gider: önce etkinler sırayla, sonra `disabled = true` olanlar (`:603-615`).
  - Proto yorumu set için `2,39` diyor, kod `2,30` kullanıyor; `39` antrenman türleri (`P/xiaomi/wear_system.proto:25`, `:31`).
- **Liste/ızgara düzeni:** GET `Command{2,31}`, SET `Command{2,41}` → `app_layout(18).{layout 1 (1 liste, 2 ızgara, 4 yazılı ızgara), support_layouts 2}` [AB] `ABP/wear_system.proto:74-75`, `:413-423`.
- **Tuş kısayolları:** SET `2,32/33/34`, GET `2,35/36/37`, desteklenenler `2,38` → `shortcut(12).{type 1 (0 yok, 1 ses, 2 işlev, 3 spor), sub_type 2}` [AB] `ABP/wear_system.proto:76-82`, `:425-440`.
- **Beyan:** ekran öğeleri runtime (`FEAT_DISPLAY_ITEMS`) [KOD] `XD/XiaomiCoordinator.java:597-599`; düzen ve kısayollar yok.
- **iOS:** sürükle-bırak liste arayüzü. **Efor / risk:** M / düşük.

### 10.6 Widget'lar

- **Gadgetbridge'in kullandığı sürüm (v2):** GET `Command{2,51}` → `system(4).widgetScreens(28).{widgetScreen 1[].{id 1 (1'den), layout 2 (256 bölünmüş, 512 uzun), widgetPart 3[].{type 1 (1 küçük, 2 geniş, 3 uzun), function 2, id 3, title 4, subType 5, appId 6, unknown7 7}}, isFullList 2 (1 = tüm listeyi yaz), widgetsCapabilities 3{minWidgets 1, maxWidgets 2, supportedLayoutStyles 3 (bantlarda 768)}}`; SET `Command{2,52}` aynı mesaj; kullanılabilir parçalar `Command{2,53}` → `widgetParts(29).{widgetPart 1[]}` [KOD] `P/xiaomi/wear_system.proto:47-50`, `:167-203`, `X/services/XiaomiSystemService.java:870-915`. Gadgetbridge ham protobuf'u saklayıp geri yolluyor (`:873-874`, `:889-914`).
- AstroBox iki sürüm daha tanımlıyor: v1 `2,26/27/28` (`widget(8)`, `widget_list(9)`) ve v3 `2,83/84/85` (`widget_v3(53){builtin_widgets 1[]{id 1, name 2}, min_count 2, max_count 3}`, `widget_v3_supported_list(54)`) [AB] `ABP/wear_system.proto:69-71`, `:125-127`, `:311-360`. Band 10'un hangisini kullandığı bilinmiyor; önce `2,85`, sonra `2,51` denenmeli.
- **Beyan:** runtime (`FEAT_WIDGETS`, bant parça listesi dönerse) [KOD] `XD/XiaomiCoordinator.java:757-760`.
- **Efor / risk:** M / orta (sürüm belirsiz, düzen kuralları).

### 10.7 Dil

- **Mesaj:** `Command{2,6}` → `Command.system(4).language(20).{code 1}`, küçük harf `dil_ülke`, ör. `"tr_tr"` [KOD] `P/xiaomi/wear_system.proto:44-45`, `:153-155`, `X/services/XiaomiSystemService.java:289-316`. Listede `tr_TR` var [KOD] `XD/XiaomiCoordinator.java:707-739`.
- **Beyan:** statik. **iOS:** `Locale.current` → `"tr_tr"`. **Efor / risk:** S / düşük.

### 10.8 Birimler ve 12/24 saat

- **Metrik/emperyal birim için hiçbir kaynakta alan yok** [AB, KOD]. Tek birim ayarı hava sıcaklığı: `Command{10,10}` `weather(12).prefs(6).{temperatureScale 1 (1 °C, 2 °F)}` (bölüm 6). Mesafe biriminin dil/bölgeye bağlı olması muhtemel [TAHMİN].
- 12/24 saat: saat komutundaki `isNot24hour 4` (bölüm 5.1); AstroBox adı `is_12_hours` [AB] `ABP/wear_system.proto:232-237`.
- **iOS:** `Locale.current.measurementSystem`, `DateFormatter.dateFormat(fromTemplate: "j", ...)`. **Efor / risk:** S / düşük.

### 10.9 Ekran kilidi şifresi

- **Mesaj:** GET `Command{2,9}`, SET `Command{2,21}` → `Command.system(4).password(19).{state 1 (1 kapalı, 2 açık; AstroBox'ta 3 = açık ve zorunlu), password 2 (6 rakam, düz metin), unknown3 3}` [KOD] `P/xiaomi/wear_system.proto:38-39`, `:247-251`, `X/services/XiaomiSystemService.java:407-452`, `XD/XiaomiCoordinator.java:741-744`; [AB] `ABP/wear_system.proto:247-258`. Kapatırken de şifre alanı dolu gönderilmeli (proto2 `required`).
- **Beyan:** runtime (`FEAT_PASSWORD`). **Efor / risk:** S / orta (kullanıcı kendini bantın dışında bırakabilir).

### 10.10 Takma modu, güç modu, bağlantı kopma uyarısı

- **Takma modu:** `Command{2,15}` → `system(4).miscSettingSet(35).wearingMode(3).{mode 1 (0 bilek, 1 klips/"pebble", 2 kolye)}`; bant değişikliği `Command{2,42}` ile bildirir [KOD] `P/xiaomi/wear_system.proto:213-234`, `X/services/XiaomiSystemService.java:454-515`. Beyan runtime (`FEAT_WEAR_MODE`); Gadgetbridge notu: değer bantta en az bir kez değiştirilmeden okunamıyor [KOD] `XD/XiaomiCoordinator.java:578-582`.
- Aynı `system_setting(35)` mesajında AstroBox'a göre başka alanlar da var [AB] `ABP/wear_system.proto:749-813`:
  - `wear_setting 3{wear_mode 1, hybrid_mode 2{power_mode 1 (0 performans, 1 güç tasarrufu, 2 süper tasarruf), lack_feature 2}}`: güç tasarrufu modunu telefondan açmak [TAHMİN, denenmedi].
  - `disconnect_reminder 4{alert 1}`: telefonla bağlantı kopunca bant titresin.
  - `notificaton_setting 1{auto_screen 1, only_lockscreen 2, only_wear 3}` (bölüm 3.7).
  - GET `Command{2,14}` `system_setting_request(34){items 1}`; Gadgetbridge DND senkronu için `items = 2` yolluyor, `items`'ın bit maskesi mi alan numarası mı olduğu belirsiz [KOD] `P/xiaomi/wear_system.proto:209-211`.
- **Efor / risk:** S / düşük–orta.

### 10.11 Telefonun sessiz modu

- Bant `Command{2,43}` ile telefonun zil durumunu sorar; telefon `Command{2,44}` `system(4).phoneSilentModeSet(37).{phoneSilentMode 1{silent 1}}` döner; bantta değiştirilince `Command{2,45}` gelir [KOD] `X/services/XiaomiSystemService.java:738-763`, `P/xiaomi/wear_system.proto:57-61`, `:253-263`.
- **iOS:** zil/sessiz anahtarı okunamaz ve ayarlanamaz [iOS]. Yapılamaz; soru gelirse cevap vermemek ya da `silent = false` dönmek.

## 11. Kamera uzaktan kumandası

- **Ne yapar:** Bantta "Kamera" uygulamasını açar; bantın düğmesi telefonun deklanşörü olur.
- **Yön:** telefon → bant (aç/kapat ayarı). Deklanşör sinyalinin kendisi protobuf değil.
- **Mesaj:** GET `Command{2,7}`, SET `Command{2,8}` → `Command.system(4).camera(15).{enabled 1 (zorunlu)}` [KOD] `P/xiaomi/wear_system.proto:41-42`, `:149-151`, `X/services/XiaomiSystemService.java:517-542`. AstroBox aynı id'leri `GET_HID_STATUS = 7`, `SET_HID_STATUS = 8`, aynı alanı `hid_status 15 {enable 1}` olarak adlandırıyor [AB] `ABP/wear_system.proto:54-55`, `:148`, `:243-245`. Yani bu ayar bantın **Bluetooth HID** (klavye/medya tuşu) rolünü açıyor; deklanşör, telefonun HID üzerinden aldığı bir tuş (büyük olasılıkla ses-açma) [TAHMİN].
- **Beyan:** runtime (`FEAT_CAMERA_REMOTE`, bant `2,7`'ye cevap verirse) [KOD] `XD/XiaomiCoordinator.java:677-679`.
- **iOS:** Ayarı açmak S. Deklanşör iOS'ta **Freeband'den bağımsız** çalışmalı: HID aksesuarı iOS'a sistem düzeyinde bağlanır ve ses-açma tuşu Kamera uygulamasında deklanşördür [iOS]. CoreBluetooth HID servisini (`1812`) uygulamalara göstermediği için bunu GATT taramasından anlayamayız; `findings.md` §6'daki tabloda yok [ÖLÇÜM + iOS]. Freeband kendi kamera ekranında ses tuşunu dinleyebilir, ama gerek yok.
- **Efor / risk:** S (ayar) / orta (iOS'un HID'yi kabul edip etmediği denenmeli).

## 12. Antrenmanlar

### 12.1 Telefon GPS'i ile dış mekân antrenmanı

- **Ne yapar:** Bant koşu/yürüyüş/bisiklet başlatınca konumu telefondan ister; mesafe, hız ve rota telefon GPS'iyle hesaplanır.
- **Yön:** iki yönlü.
- **Akış:** [KOD] `X/services/XiaomiHealthService.java:743-876`, `P/xiaomi/wear_fitness.proto:143-216`
  1. bant → `Command{8,30}` `health(10).workoutOpenWatch(25).{sport 1 (1 açık hava koşu, 2 yürüyüş, 3 doğa yürüyüşü, 4 trekking, 5 patika koşusu, 6 açık hava bisiklet), supportedVersions 2, mainSport 3}`.
  2. telefon, ilk konum gelince → `Command{8,30}` `health(10).workoutOpenReply(26).{code 1 (0 tamam, 1 meşgul, 3 izin yok, 5 konum doğruluğu yetersiz, 7 pil düşük...), selectedVersion 2 (= 2), gpsAccuracy 3 (0 düşük, 1 orta, 2 yüksek, 10 bilinmiyor)}`. Konum yoksa `code 3`, `gpsAccuracy 10` (`:760-775`). Bant bu cevap gelmeden antrenmanı açmıyor (`P/xiaomi/wear_fitness.proto:170-180`).
  3. bant → `Command{8,26}` `health(10).workoutStatusWatch(20).{timestamp 1, sportInfo 2{tzOffsetQuarterHours 1 (sint32)}, sport 3, status 4 (0 başladı, 1 duraklatıldı, 2 sürdü, 3 bitti), activityFileIds 5, supportedVersions 6}`. Yeni yazılımlarda `Command{8,29}` `workoutStatusWatchV2(24).{status 1 (0 başladı, 1 sürdü, 2 duraklatıldı, 3 bitti), timestamp 2, sport 3{type 1}}` de var; AstroBox bu alanları farklı yorumluyor, yakalamayla doğrulanmalı (§16.3).
  4. başladıktan sonra her konumda telefon → `Command{8,48}` `health(10).workoutLocation(40).{unknown1 1 (Gadgetbridge 2), timestamp 2 (sn), longitude 3 (double), latitude 4 (double), altitude 5 (double), speed 6 (float m/s), bearing 7 (float), horizontalAccuracy 8, verticalAccuracy 9}`. Gadgetbridge doğruluk alanlarını göndermiyor (`:859-865`).
  5. `status 3` gelince konumu durdur.
  - Band 10 notu: HyperOS 3.2.x başladıktan kısa süre sonra `workoutOpenWatch` göndermeyi kesiyor; GPS'i yalnız `status 3` durdurmalı, zaman aşımı değil [KOD] `X/services/XiaomiHealthService.java:783-797`.
- **Beyan:** statik (her Xiaomi'de "GPS'i banda gönder" ayarı) [KOD] `XD/XiaomiCoordinator.java:636-639`.
- **iOS:** en ağır özelliklerden biri. Antrenman boyunca (saatlerce, ekran kapalı) tutulan BLE oturumu + CoreLocation sürekli konum: `location` ve `bluetooth-central` arka plan modları, "Her zaman" ya da arka plan konum göstergesiyle "Kullanırken" izni [iOS]. Pil tüketimi iki radyo için yüksek. Fitness uygulaması olduğu için App Store gerekçesi var.
- **Efor / risk:** L / orta (yeniden bağlanma antrenman ortasında, konum izni).

### 12.2 Canlı antrenman istatistiği

- **Ne yapar:** Bantta açık antrenman varken nabız, kalori, adım ve mesafeyi saniyede bir telefona yollar.
- **Yön:** bant → telefon.
- **Mesaj:** `Command{8,50}` → `health(10).workoutStatsWatch(42).{heartRate 1, calories 2 (antrenman başından), steps 3, distance 4 (m)}`; daha yüksek alan numaraları var, çözülmemiş [KOD] `P/xiaomi/wear_fitness.proto:256-263`, `X/services/XiaomiHealthService.java:120-122`, `:245-247`.
- **Beyan:** yok (Gadgetbridge yalnız Sleep as Android için okuyor).
- **iOS:** tutulan oturum gerekir. iPhone'da Live Activity / Dinamik Ada ile canlı antrenman ekranı yapılabilir [iOS].
- **Efor / risk:** M (tutulan oturumdan sonra) / düşük.

### 12.3 Telefondan başlatılan antrenman ve ham sensör akışı

- **Ne yapar:** Telefon bantta gizli bir "antrenman" açar; bant ~100 Hz ivmeölçer/jiroskop örneklerini ve canlı nabzı telefona akıtır. Telefon antrenman ekranındaki süre/nabız/kalori/mesafe değerlerini kendisi gönderir.
- **Yön:** iki yönlü.
- **Akış:** [KOD] `X/services/XiaomiSleepAsAndroidManager.java:52-75`, `:129-240`, `:342-404`, `P/xiaomi/wear_fitness.proto:227-254`
  1. Önce eski antrenmanı kapat: `Command{8,26}` `workoutStatusWatch(20).{timestamp 1, sportInfo 2{tzOffsetQuarterHours 1}, sport 3 = 810, status 4 = 3, supportedVersions 6 = 3}`, 500 ms bekle.
  2. Gerekirse canlı istatistik `Command{8,45}`, sonra aynı mesaj `status 4 = 0`.
  3. Bant `Command{8,30}` sorar, telefon `workoutOpenReply{code 0, selectedVersion 2, gpsAccuracy 2}` döner.
  4. Telefon saniyede bir `Command{8,49}` `health(10).workoutStatsPhone(41).{durationSeconds 1, heartRate 2 (bilinmiyorsa 255), calories 3, distance 4}`; akış durursa bant ekranı boşaltır.
  5. Bant `Command{8,53}` `health(10).rawSensorBatch(15).{accel 5[].{timestamp 1 (uint64), x 2, y 3, z 4 (float, m/s²)}, gyro 6[]}` yollar; her paket 10 ivme + 10 jiroskop örneği.
  6. 24 sn'de bir `status 0` tekrarı (keepalive); 30 sn paket gelmezse yeniden kur. Kapatma: `8,46`, `status 1`, 500 ms sonra `status 3`.
  - `sport 810` AstroBox'ta `MOTION_SENSING_GAME` (`:52`).
- **Beyan:** statik (`supportsSleepAsAndroid`, ivmeölçer dahil) [KOD] `XD/XiaomiCoordinator.java:501-516`.
- **iOS:** Sleep as Android yok, ama ham ivme Freeband'in kendi uyku analizi, akıllı alarm ya da tekrar sayımı için kullanılabilir. Bütün gece tutulan oturum, pil ve bantta görünür bir antrenman yan etkisi [TAHMİN] demek.
- **Efor / risk:** L / yüksek (pil, deneysel).

### 12.4 Antrenman türleri ve kayıtlı antrenmanlar

- Bantın desteklediği spor türleri: GET `Command{2,39}` → `system(4).workoutTypes(14).{workoutType 1[].{type 1, unknown2 2}, unknown2 2}` [KOD] `X/services/XiaomiSystemService.java:674-686`, `P/xiaomi/wear_system.proto:31-32`, `:157-165`. Gadgetbridge yalnız okuyor; AstroBox'ta `GET_SPORT_OPTION 39` / `SET_SPORT_OPTION 40`, yük `sport_option_list(14){list 1[]{sport_type 1, show 2}, shortcut_sport_type 2}`; yani banttaki antrenman listesinde hangi türlerin görüneceği (ve büyük olasılıkla sırası) yazılabiliyor [AB] `ABP/wear_system.proto:83-84`, `:442-451`.
- Bitmiş antrenmanların özet/detay/GPS dosyaları aktivite kanalından gelir: `docs/ACTIVITY.md` §3.1, §6.6.

## 13. Dosya yükleme: kadran, hızlı uygulama, ikon, firmware

### 13.1 Yükleme protokolü (DataUpload / Mass, type 22)

Kadran, RPK, bildirim ikonu ve firmware aynı yolu kullanır. Önce türe özgü "hazırlık" komutu (13.2–13.5), sonra:

1. **Hazırlık:** telefon → `Command{22,0}` → `Command.dataUpload(24).dataUploadRequest(1).{type 1, md5sum 2 (16 bayt, tüm dosyanın MD5'i), size 3 (tüm dosya boyu)}` [KOD] `P/xiaomi/wear_mass.proto:6-17`, `X/services/XiaomiDataUploadService.java:106-130`. AstroBox adları: `mass(24).prepare_request(1){data_type 1, data_id 2, data_length 3, support_compress_mode 4}` [AB] `ABP/wear_mass.proto:22-27`, `ABC/device/xiaomi/components/mass.rs:331-352`.
2. **Cevap:** `dataUpload(24).dataUploadAck(2).{md5sum 1, errno 2 (0 hazır), resumePosition 4, chunkSize 5}` [KOD] `P/xiaomi/wear_mass.proto:19-24`. AstroBox: `prepare_response(2){data_id 1, prepare_status 2, select_compress_mode 3, remained_data_length 4, expected_slice_length 5}`; durum kodları 0 hazır, 1 meşgul, 2 zaten var, 3 yer yok, 4 pil düşük, 5 sürüm düşürme, 6 desteklenmiyor, 7 sayı sınırı, 8 ağ hatası, 255 hata [AB] `ABP/wear_mass.proto:29-35`, `ABP/wear_common.proto:17-28`. `chunkSize` yoksa Gadgetbridge 2048 alıyor [KOD] `X/services/XiaomiDataUploadService.java:83-87`; AstroBox 0'da iptal ediyor [AB] `mass.rs:507-509`.
3. **Veri** düz metin **kanal 2** (Data, opcode 1) üzerinden [KOD] `X/XiaomiBleProtocolV2.java:236-246`, `X/XiaomiSppPacketV2.java:283-290`, `:362-374`:

   | Ofset | Boy | Alan |
   |---|---|---|
   | 0 | 1 | `0x00` (sıkıştırma yok) |
   | 1 | 1 | tür |
   | 2 | 16 | tüm dosyanın MD5'i |
   | 18 | 4 | uzunluk, u32 LE |
   | 22 | n | dosya baytları (`resumePosition`'dan itibaren) |
   | son | 4 | yukarıdaki her baytın CRC32'si (zlib), u32 LE |

   [KOD] `X/services/XiaomiDataUploadService.java:132-155`, [AB] `ABC/device/xiaomi/packet/mass.rs:82-110`.
   - Bu tampon parçalara bölünür; her parça `total u16 LE | index u16 LE (1'den) | dilim` ve her parça ayrı bir SPP v2 data paketi.
   - **Parça boyu iki kaynakta farklı:** Gadgetbridge dilim = `chunkSize − 4` [KOD] `X/services/XiaomiDataUploadService.java:154-165`; AstroBox dilim = `expected_slice_length − 6`, çünkü kanal ve opcode baytlarını da sayıyor [AB] `mass.rs:523-531`, `:616-639`. Freeband küçük olanı (`− 6`) kullanmalı; ikisinde de çalışır.
   - **Devam (resume):** AstroBox'ta uzunluk alanı ve CRC yalnız kalan kısmı kapsar, parça numarası 1'den yeniden başlar [AB] `mass.rs:89-110`, `:454-461`. Gadgetbridge uzunluğa tüm boyu yazıyor (`:146`); ikisi çelişiyor, ilk sürümde resume kullanılmamalı.
4. **Akış kontrolü:** Gadgetbridge'in BLE V2 yolu parçaları beklemeden kuyruğa yazıyor (`X/XiaomiBleProtocolV2.java:236-246`; SPP V2'de 32'lik pencere var, `X/XiaomiSppV2SendWindow.java`). AstroBox en fazla 32 onaylanmamış çerçeve tutuyor, ACK kümülatif, NAK "şu seq'ten tekrar gönder", 500 ms'de bir zaman aşımı kontrolü, 3 denemeden sonra iptal [AB] `ABC/device/xiaomi/sar/mod.rs:27`, `:58-61`, `:330-380`, `:509-560`. BLE yazma boyu 244 bayt [AB] `ABC/device/xiaomi/config.rs:1-14`.
   - Freeband bugün yalnız gelen pakete ACK atıyor, gelen ACK/NAK'ı işlemiyor [FB] `FB/Band/BandLink.swift:512-528` (gelen veri paketine ACK `:519-521`; NACK yalnız loglanıyor `:522-523`; gelen ACK yok sayılıyor `:524-525`). Yükleme için seq takibi, 32'lik pencere ve NAK'ta yeniden gönderme eklenmeli; `canSendWriteWithoutResponse` ile pompalama zaten var (`:505-510`, `:648-650`).
5. **Bitiş:** bant ayrı bir "ham veri bitti" mesajı göndermiyor; son parça onaylanınca yükleme biter, sonuç türe özgü mesajla gelir (aşağıda) [AB] `mass.rs:698-709`.

Tür kodları [KOD] `X/services/XiaomiDataUploadService.java:47-50`, [AB] `ABC/device/xiaomi/packet/mass.rs:12-20`:

| Tür | Anlam | Hazırlık |
|---|---|---|
| 16 | kadran | `Command{4,4}` |
| 32 | firmware | `Command{2,5}` |
| 48 | kadran arka plan resmi (yalnız AstroBox) | `Command{4,11}`, Mass hazırlığı yok |
| 50 | bildirim ikonu | `Command{7,15}` |
| 52 | müzik dosyası (yalnız AstroBox) | Media |
| 53 | kadran yazı tipi (yalnız AstroBox) | `Command{4,11}`, Mass hazırlığı yok |
| 64 | hızlı uygulama (RPK) | `Command{20,1}` |

- **iOS:** BLE V2'de veri kanalı aynı `005F` yazma karakteristiği; ek izin gerekmez. Büyük dosyalar (kadran yüzlerce KB, firmware MB'lar) uygulama önde ve ekran açıkken yüklenmeli; arka plana geçince iOS işi askıya alabilir [iOS]. Mi Fitness kapalı olmalı.
- **Efor / risk:** L (bir kez; sonra 13.2–13.4 bunun üstünde M) / orta.

### 13.2 Kadranlar

- **Ne yapar:** Yüklü kadranları listeler, aktif kadranı değiştirir, siler, yeni kadran yükler. AstroBox ayrıca fotoğraflı kadran düzenleme yapıyor.
- **Yön:** telefon → bant.
- **Mesajlar:** [KOD] `P/xiaomi/wear_watch_face.proto:6-43`, `X/services/XiaomiWatchfaceService.java:44-49`, `:72-262`; [AB] `ABP/wear_watch_face.proto:9-38`
  - Liste `Command{4,0}` → `watchface(6).watchfaceList(1).{watchface 1[].{id 1 (sayısal string), name 2, active 3, canDelete 4, unknown5 5, unknown6 6, unknown11 11}}`. AstroBox `WatchFaceItem` daha fazla alan biliyor (`version_code`, `can_edit`, `support_image_format`, ...) [AB] `ABP/wear_watch_face.proto:78-103`.
  - Aktif yap `Command{4,1}` → `watchface(6).watchfaceId(2)` (string); cevap `ack 4` / `success 4` (bool).
  - Sil `Command{4,2}` → `watchfaceId(2)`. Gadgetbridge yerleşik (`canDelete = false`) ve aktif kadranı silmeyi reddediyor (`:168-199`).
  - Yükle: `Command{4,4}` → `watchface(6).watchfaceInstallStart(6).{id 1, size 2}` (AstroBox `prepare_info(6){id 1, size 2, version_code 3 = 65536}`) → bant `installStatus(5)` / `prepare_status(5)` 0 → yükleme türü 16 → bant `Command{4,5}` `install_result(7){id, code: 0 doğrulama hatası, 1 kurulum hatası, 2 başarı, 3 zaten kullanımda}` [AB] `ABP/wear_watch_face.proto:15`, `:136-149`, `ABC/device/xiaomi/components/install.rs:469-487`, `:219-237`. Gadgetbridge sonucu beklemiyor, yükleme bitince aktif yapıp listeyi istiyor (`X/services/XiaomiWatchfaceService.java:241-263`).
  - Yalnız AstroBox'ta: desteklenen komplikasyonlar `Command{4,10}`, düzenleme `Command{4,11}` `edit_request(12)` → `edit_response(13){..., expected_slice_length}`, sonra resim (tür 48) ya da yazı tipi (tür 53) yüklemesi, sonuç `4,12` / `4,13` [AB] `ABP/wear_watch_face.proto:187-239`, `ABC/device/watchface.rs:419-525`.
- **Dosya biçimi:** `.bin`, `5A A5` ile başlar; Gadgetbridge id'yi `0x28`'den, adı `0x68`'den okuyor [KOD] `XD/XiaomiFWHelper.java:388-440`; AstroBox sihirli baytı `5a a5 34 12` olarak, id'yi ofset 34'ten başlayan 24 baytta 9 ya da 12 haneli ilk dizi olarak arıyor ve `.mwz` zip paketlerini de açıyor [AB] `ABC/device/xiaomi/resutils.rs:9`, `:75-167`, `:1191-1194`. Gadgetbridge'in "v3" kadran biçimi (`00 00 06 07 00 02 00 01`) id çıkarmıyor, yani yükleme komutu boş id ile giderdi [KOD] `XD/XiaomiFWHelper.java:55`, `:442-461`.
- **Beyan:** statik (`supportsWatchfaceManagement`) [KOD] `XD/XiaomiCoordinator.java:275-292`. Band 10 / 10 Pro için önizleme boyutu tanımlı değil; ekran 212 × 520 / 336 × 480.
- **iOS:**
  - **Liste + aktif kadranı değiştirme + silme:** kısa oturum, dosya aktarımı yok. Hızlı kazanım.
  - **Yükleme:** 13.1 altyapısı, kullanıcı `.bin`/`.mwz` dosyasını Dosyalar'dan seçer (`UIDocumentPickerViewController`). Kadran kaynağı ve telif kullanıcıya ait. Yanlış model için yapılmış kadranı bantın reddetmesi beklenir (`code 0`) [TAHMİN].
- **Efor / risk:** liste/değiştir/sil S / düşük; yükleme M (13.1'in üstüne) / orta.

### 13.3 Hızlı uygulamalar (RPK)

- **Ne yapar:** Bantta çalışan Vela "quick app"leri listeler, yükler, siler, başlatır; telefondaki uygulamayla mesajlaşmalarını sağlar (bölüm 16.2).
- **Yön:** telefon → bant; mesajlaşma iki yönlü.
- **Mesajlar:** [KOD] `P/xiaomi/wear_thirdparty_app.proto:6-35`, `X/services/XiaomiRpkService.java:47-166`; [AB] `ABP/wear_thirdparty_app.proto:9-53`, `ABC/device/xiaomi/components/thirdparty_app.rs:35-207`
  - Liste `Command{20,0}` → `rpk(22).rpkList(1).{rpkInfo 1[].{id 1 (paket adı), sha 2 (bytes), unknown3 3, unknown4 4, name 5}}`. AstroBox adları: `app_item_list(1).list[]{package_name 1, fingerprint 2, version_code 3, can_remove 4, app_name 5}`.
  - Yükle `Command{20,1}` → `rpk(22).rpkInfo(2).{id 1 (paket adı), unknown2 2 (versionCode), size 3}` → bant aynı subtype ile `rpkInstallStart(3).{cmd 1}` (AstroBox: `install_response(3){prepare_status 1, expected_slice_length 2}`) 0 → yükleme türü 64 → bant `Command{20,2}` kurulum sonucu (`install_result(4){code 0 başarı, 1 hata, 2 doğrulama hatası, ...}`). AstroBox `version_code` olarak sabit 114514 yolluyor [AB] `ABC/device/xiaomi/components/install.rs:489-511`.
  - Sil `Command{20,3}` → `rpk(22).rpkDel(5).{id 1, sha 2}`; parmak izi listeden alınır.
  - Başlat (yalnız AstroBox) `Command{20,4}` → `thirdparty_app(22).launch_info(6){basic_info 1{package_name 1, fingerprint 2}, uri 2}`; ör. `hap://app/<paket>/pages/index` ya da boş [AB] `ABC/device/res_pack.rs:397-399`.
- **Dosya biçimi:** zip; Gadgetbridge `manifest.json`'dan `package`, `name`, `versionName`, `versionCode` okuyor [KOD] `XD/XiaomiFWHelper.java:370-386`.
- **Beyan:** statik (`supportsAppsManagement`, `supportsInstalledAppManagement`) [KOD] `XD/XiaomiCoordinator.java:275-287`. Not: Gadgetbridge'de `CMD_RPK_SET = 1` ile `CMD_RPK_INSTALL = 1` çakışıyor; başlatma yok (`X/services/XiaomiRpkService.java:49-53`).
- **iOS:** liste/sil/başlat S; yükleme 13.1 üzerine M.
- **Efor / risk:** S–M / orta.

### 13.4 Bildirim ikonu yükleme

Bölüm 3.4'teki akış; tür 50. AstroBox adlarıyla: `Command{7,15}` `notification(9).app_icon_request(14){package_name 1, support_compress_mode 2}` → `app_icon_response(15){prepare_status, support_image_format, expected_max_size, select_compress_mode, expected_slice_length}` → Mass hazırlığı + tür 50; sonuç beklenmiyor [AB] `ABC/device/xiaomi/components/install.rs:99-110`, `:539-554`, `ABP/wear_notification.proto:177-190`.

### 13.5 Firmware güncelleme

- **Ne yapar:** Bantın yazılımını telefondan günceller.
- **Mesaj:** `Command{2,5}` → `system(4).firmwareInstallRequest(16).{unknown1 1 = 0, unknown2 2 = 0, version 3, md5 4 (küçük harf hex string)}` → `firmwareInstallResponse(17).{status 1}` 0 → yükleme türü 32 [KOD] `X/services/XiaomiSystemService.java:954-974`, `:162-173`. AstroBox: `prepare_ota_request(16){force 1 = true, type 2 = 0 (ALL), firmware_version 3, file_md5 4, change_log 5, file_url 6, file_size 7}` → ilk `prepare_ota_response(17){prepare_status 1, expected_slice_length 2, min_battery 3, progress 4}` başla izni, ikinci aynı mesaj sonuç; ilerleme yalnız Mass ACK'lerinden [AB] `ABP/wear_system.proto:458-489`, `ABC/device/xiaomi/components/install.rs:292-303`, `:418-426`, `:513-537`.
- **Dosya biçimi:** Gadgetbridge yalnız Mi Band 8 Pro başlığını tanıyor, Band 10 firmware'ini geçersiz sayar [KOD] `XD/XiaomiFWHelper.java:463-471`. AstroBox ≥ 1 MB, `vela_ap.bin` içeren OTA zip'i ya da artımlı paket bekliyor, model kontrolü yok [AB] `ABC/device/xiaomi/resutils.rs:320-433`.
- **Beyan:** statik `supportsFlashing = true` [KOD] `XD/XiaomiCoordinator.java:260-262`.
- **iOS:** teknik olarak 13.1 ile aynı. Firmware dosyasının kaynağı Xiaomi'nin OTA sunucusu (hesap gerekir); yanlış dosya ya da yarıda kesilen yükleme bantı bozabilir.
- **Efor / risk:** M / **yüksek**. Önerim: yapma; güncellemeler için ara sıra Mi Fitness kullan (`findings.md` §9.2 madde 6).

## 14. Cihaz bilgisi ve firmware sürümü

- **Ne yapar:** Seri numarası, firmware sürümü, model.
- **Yön:** telefon → bant (GET).
- **Mesaj:** `Command{2,2}` → `system(4).deviceInfo(3).{serialNumber 1, firmware 2, unknown3 3, model 4}` [KOD] `P/xiaomi/wear_system.proto:103-108`, `X/services/XiaomiSystemService.java:357-368`. AstroBox'ta `unknown3` = `imei 3`, ayrıca `product_device 5` [AB] `ABP/wear_system.proto:224-230`.
- **Beyan:** statik; Gadgetbridge her bağlantıda ilk iş istiyor (`X/services/XiaomiSystemService.java:133`).
- **Depolama** (yalnız AstroBox): GET `Command{2,62}` → `system(4).storage_info(44).{used 1 (uint64), total 2 (uint64)}` [AB] `ABP/wear_system.proto:114`, `:888-891`, `ABC/device/xiaomi/components/info.rs:67-115`. Kadran/uygulama yüklemeden önce yer kontrolü için.
- **iOS:** sorunsuz. Firmware sürümü hata ayıklama, destek ve yazılım farklarını (ör. HyperOS 3.2.x GPS davranışı, bölüm 12.1) izlemek için kayda değer. GATT `180A`'da sürüm yok, yalnız bu yoldan okunur (`findings.md` §2).
- **Efor / risk:** S / düşük.

## 15. Kişiler

- **Ne yapar:** Banta sık kullanılan kişi listesi; bant bir numaranın adını sorarsa cevap.
- **Yön:** iki yönlü.
- **Mesaj:** [KOD] `P/xiaomi/wear_contact.proto:6-19`, `X/services/XiaomiPhonebookService.java:43-49`, `:55-167`
  - Liste `Command{21,7}` → `phonebook(23).contactList(4).{contactInfo 1[].{displayName 1, phoneNumber 2}}`; Gadgetbridge 10 kişi varsayıyor, "doğrulanmadı" diye not düşmüş (`:149`).
  - bant → `Command{21,2}` `phonebook(23).requestedPhoneNumber(2)` → telefon `Command{21,3}` `phonebook(23).contactInfo(3).{displayName 1, phoneNumber 2}`.
  - `Command{21,5}` (liste ekle) tanımlı, kullanılmıyor.
  - AstroBox: liste `21,4` GET, `21,5` ekle, `21,6` sil, `21,7` senkron; `contact_info_list(4){list 1, current_segment 2, total_segment 3}`, yani uzun liste parçalı gider; proto'da üst sınır ya da "favori" bayrağı yok [AB] `ABP/wear_contact.proto:33-43`.
  - **Acil durum kişisi** (yalnız AstroBox): GET `Command{21,0}`, SET `Command{21,1}` → `contact(23).emergency_contact(1).{enabled 1, contact_info 2{name 1, number 2}}`, tek kişi [AB] `ABP/wear_contact.proto:8-9`, `:45-48`. Düşme/SOS yardımı (`21,8`–`21,11`) SMS'e dayanıyor, iOS'ta yapılamaz.
- **Beyan:** **yok.** `getContactsSlotCount` varsayılan 0, Xiaomi bunu değiştirmiyor; ayar ekranı hiçbir Xiaomi cihazında görünmüyor [KOD] `GB/devices/AbstractDeviceCoordinator.java:1032-1034`, `XD/XiaomiCoordinator.java:674-676`.
- **iOS:** `CNContactStore` (Kişiler izni). Numara sorgusu tutulan oturum ister ve iOS'ta arayan adı zaten ANCS ile gidiyor [iOS]. Bantın kişi listesiyle ne yaptığı (arama başlatma? Band 10'da hoparlör/mikrofon yok) belirsiz [TAHMİN].
- **Efor / risk:** S–M / orta (belirsiz kullanım); değer düşük.

## 16. Gadgetbridge'in ötesi ve bilinmeyenler

### 16.1 Ağ vekili: bantta internet

- **Ne yapar:** Telefon, bant için bir IP yönlendiricisi gibi davranır; bantın TCP/UDP bağlantıları telefonun internetinden çıkar.
- **Yön:** iki yönlü, protobuf dışında ham IP paketleri.
- **Akış:** [AB]
  1. Auth'tan hemen sonra telefon → `Command{2,92}` → `system(4).network_status(59).{capability 1 = 2}`. Değer `2` açıklamasız sabit [AB] `ABC/device.rs:290-300`, `ABC/device/xiaomi/components/network/native/mod.rs:110-121`, `:167-181`, `ABP/wear_system.proto:124`, `:191`, `:734-736`.
  2. Bant aynı bağlantı üzerinde **kanal 7** (Network), opcode 1 (düz metin) ile ham IPv4 paketleri yollar: `a5 a5 | 03 | seq | len | crc16 | 07 01 <IPv4 paketi>`; MTU 800 [AB] `ABC/device/xiaomi/packet/v2/layer2.rs:17`, `:46`, `ABC/device/xiaomi/config.rs:125`. Kanal 7 paketlerine ACK atılmaz [AB] `ABC/device/xiaomi/sar/mod.rs:467-473`.
  3. Bant önce DHCP ister; telefon cevaplar: bant 10.1.10.2, ağ geçidi 10.1.10.1, /24, DNS 223.5.5.5 ve 119.29.29.29 (Çin'deki genel çözücüler; Freeband kendininkini vermeli) [AB] `ABC/device/xiaomi/components/network/native/dhcp.rs:8-11`, `:41-157`. AstroBox'ın DHCP cevabındaki kaynak/hedef IP'leri RFC'ye göre ters görünüyor ama bant kabul ediyor (`:113-118`); ilk sürümde aynen taklit edilmeli.
  4. Telefon paketleri kullanıcı alanında bir TCP/IP yığınından (AstroBox: `ipstack`) geçirip her akışı sıradan bir soket olarak açar: TCP → `TcpStream`, UDP → akış başına soket, ICMP echo yerelde cevaplanır, IPv6 atılır [AB] `native/mod.rs:294-412`.
  - `System` id 82 `REQUEST_NETWORK_PROXY` (`network_proxy_request(52){type 1 = PAN}`) tanımlı ama AstroBox ne gönderiyor ne işliyor [AB] `ABP/wear_system.proto:123`, `:667-677`.
  - Bantın interneti ne için kullandığı kaynakta yazmıyor (hava, asistan, uygulama mağazası kendi protobuf tiplerine sahip). AstroBox'ta pcap yakalama seçeneği tam bunu bulmak için var [AB] `native/mod.rs:482-523`.
- **Beyan:** Gadgetbridge'de yok.
- **iOS:** NetworkExtension gerekmez; telefon akışları normal soket olarak açar. Ama Swift'te hazır bir kullanıcı alanı TCP/IP yığını yok: AstroBox'ın Rust kodu (AGPL) ya da lwIP/smoltcp köprüsü gerekir. Tutulan oturum ve arka planda soket ömrü [iOS]. Bantın iOS eşlikçisinde bu özelliği açıp açmadığı (`device_type = IOS`) doğrulanmadı.
- **Efor / risk:** L / yüksek (gizlilik: bant adına keyfi trafik; ne için kullanıldığı bilinmiyor). Önce pcap ile ne konuştuğu görülmeli.

### 16.2 Hızlı uygulamayla mesajlaşma (telefon ↔ bant uygulaması)

- **Ne yapar:** Bantta yüklü bir quick app ile telefondaki uygulama arasında serbest biçimli bayt mesajları. Freeband için en ilginç kapı: bantta Freeband'in kendi ekranı (ör. bugünkü özet, hub verisi, kısayol tetikleyici) yazılıp telefonla konuşturulabilir.
- **Yön:** iki yönlü.
- **Mesajlar:** [AB] `ABP/wear_thirdparty_app.proto:9-53`, `ABC/device/xiaomi/components/thirdparty_app.rs:35-122`, `:139-207`
  - bant → `Command{20,6}` `thirdparty_app(22).basic_info(5).{package_name 1, fingerprint 2}`: "telefondaki karşı uygulama çalışıyor mu?".
  - telefon → `Command{20,7}` `thirdparty_app(22).app_status(8).{basic_info 1, status 2 (1 bağlı, 2 bağlı değil, 3 yüklü değil)}`. Bu cevap gelmezse bant uygulaması telefonu yok sayar.
  - telefon → `Command{20,8}` `thirdparty_app(22).message_content(9).{basic_info 1{package_name 1, fingerprint 2}, content 2 (bytes)}`. `fingerprint` listeden (`Command{20,0}`) alınır [AB] `ABC/device/thirdparty_app.rs:76-96`.
  - bant → `Command{20,9}` aynı `message_content(9)`.
  - İçerik uygulamaya özgü; AstroBox'ın kendi bant uygulaması UTF-8 metin ve JSON kullanıyor, mesaj başına 18 000 karaktere kadar [AB] `ABC/device/res_pack.rs:26-27`, `:334-353`.
- **Beyan:** Gadgetbridge'de yok.
- **iOS:** mesajlaşma tutulan oturum ister (bant tarafı istediği an yazar). Bant tarafındaki uygulamayı yazmak ayrı bir iş: Xiaomi Vela JS quick app SDK'sı, bölüm 13.3 ile yükleme [TAHMİN: SDK erişimi ve imza gereksinimi doğrulanmadı].
- **Efor / risk:** L (bant uygulaması + yükleme + oturum) / orta.

### 16.3 AstroBox'ta tanımlı, Gadgetbridge'de olmayan sağlık komutları

AstroBox `FitnessID` listesi 0–91 [AB] `ABP/wear_fitness.proto:22-114`, yükler `:116-182`. AstroBox bunların hiçbirini kodda kullanmıyor; id → yük eşlemesi adlardan çıkarım [TAHMİN]. Alan numaraları Gadgetbridge'in `Health` alanlarıyla birebir aynı, yani aynı mesaja eklenebilir. Freeband için anlamlı olanlar:

| Id | Ad | Yük (`health(10)` altında) | Freeband için |
|---|---|---|---|
| 44 | `GET_BASIC_DATA` | `basic_data(39){steps 1, calories 2, distance 3, heart_rate 4, intensity 5, valid_stand 6}` (`:365-372`) | Canlı akış açmadan bugünkü toplamları tek seferde okumak; `8,45` yerine daha ucuz senkron. S, denenmeli. |
| 7 | `REQUEST_USER_PROFILE` | bant sorar; cevap `user_profile(1)`, AstroBox `UserProfile` alan 16–23 tıbbi kimlik (ad, kan grubu, acil kişi, alerji...) (`:185-216`) | Tıbbi kimlik kartı bantta. Gadgetbridge 16 ve 21–23 zorunlu alanlarını göndermiyor ve kullanıcı bilgisi yine de çalışıyor, yani bant eksikleri tolere ediyor. M. |
| 20, 37–40 | kadın sağlığı | `women_health(34)`, `forcast_on(35)`, `reminder_list(36)`, `section_list(12)` (`:674-729`) | Döngü takibi ve hatırlatma. M, alanlar çözülmeli. |
| 41 | `SYNC_SLEEP_RESULT` | `sleep_result(37){section_list 1, animal 2}` (`:318-346`) | Telefonun hesapladığı uyku sonucunu banta yazmak. M. |
| 56 | `MOTION_INTERACT` | `motion_interact(46){vibrate_level 1}` (`:773-775`) | Başka bir titreşim ilkeli olabilir. Denenmeli. |
| 57–60 | navigasyon rotaları | `navi_route_list(47)`, `navi_route_add_reqeust(48){navi_route 1{id, name, distance}, route_size 2}` → `(49){id, prepare_status, expected_slice_length}` → dosya → `(55)` sonuç (`:777-811`) | GPX rotası banta. Rota dosyası Mass ile gidiyor ama tür kodu ve biçimi bilinmiyor. L. |
| 61/62, 63/69 | uyku düzenliliği, uyku bozukluğu hatırlatıcısı | `sleep_regularity(58){on 1, measure_period 2}`, `sleep_disorder(59){reminder 1, times 2[]}` (`:813-821`) | S, bantta varsa. |
| 16–19 | tansiyon/EKG hatırlatıcısı | `measure_reminder(11)` (`:731-745`) | Band 10'da EKG/tansiyon yok [TAHMİN]. |
| 26 (telefon gönderir) | antrenman başlat | `sport_request(20){timestamp 1, timezone 2, sport_type 3, state 4 (0 başla, 1 duraklat, 2 sürdür, 3 dur), ..., sport_target_list 7, ...}` → `sport_response(21)` (`:438-475`) | Bölüm 12.3'ün resmî karşılığı: telefondan hedefli antrenman. M–L. |
| 83/84 | uzaktan kontrol | `phone_control_data(66){user_role 1, remote_control 2, vibrate_level 3}`, `wear_control_data(67){key_event 1}` (`:879-887`) | Bant tuşunu telefona bağlamak? Anlamı belirsiz. |
| 86–88 | antrenman planı | `training(68)`; `Training.Plan` oneof'tan ulaşılamıyor (`:889-931`) | Belirsiz. |

Ayrıca System altında **küçük alışkanlıklar** (su içme hatırlatıcısı dahil) `Command{2,48}` ekle/güncelle, `2,49` senkron, `2,50` sil; `small_habit(24)` … `small_habit_type_list(27)` [AB] `ABP/wear_system.proto:85-87`, `:157-160`, `:491-544`.

Uyumsuzluklar (bantta doğrulanmalı):
- `Command{8,29}`: Gadgetbridge `{status 1, timestamp 2, sport 3{type 1}}` okuyor, AstroBox `SportStatus{sport_type 1, timestamp 2, timezone 3, duration 4, paused 5, ...}` diyor [AB] `ABP/wear_fitness.proto:411-424`, `P/xiaomi/wear_fitness.proto:207-216`.
- Ham sensör: Gadgetbridge `accel 5, gyro 6` ("Band 10 kabloda bunu yolluyor" notuyla), AstroBox `accel 1, gyro 2` [KOD] `P/xiaomi/wear_fitness.proto:237-242`, [AB] `ABP/wear_fitness.proto:764-767`. Gadgetbridge'inki sahada görülmüş.
- Saat dilimi ofseti: AstroBox `int32`, Gadgetbridge `sint32` (zigzag) [AB] `ABP/wear_common.proto:546`, [KOD] `P/xiaomi/wear_common.proto:23-28`. Sıfır dışındaki her değerde farklı bayt çıkar: Türkiye (+3 saat = 12 çeyrek) `int32` ile `0x0C`, `sint32` ile `0x18` (zigzag 24). Gadgetbridge'in yolu sahada çalışan yol; Freeband `sint32` kullanmalı.

### 16.4 GNSS (type 16)

- `REQUEST_ONLINE 0`, `REQUEST_OFFLINE 1`, `SEND_GPS_INFO 2`, `REQUEST_GPS_INFO 3`; `Data{type 1 (AGPS 1, BEIDOU 2, GALILEO 3), source 2, days 3, need_gps_info 4, expected_slice_length 5}`, `GpsInfo{timestamp 1, longitude 2, latitude 3, altitude 4}` [AB] `ABP/wear_gnss.proto:7-41`.
- Dahilî GPS'li cihazlar için yardımlı GNSS (efemeris dosyası + telefonun konumu) gibi görünüyor [TAHMİN]. AstroBox ve Gadgetbridge kullanmıyor. Band 10 / 10 Pro'da dahilî GPS olduğuna dair kaynakta bilgi yok; bant bu tipte istek yollarsa ortaya çıkar.

### 16.5 Diğer protolar

[AB] Tek satırlık değerlendirme:

| Tip | Proto | Ne | Freeband için |
|---|---|---|---|
| 14 | `ABP/wear_aivs.proto` | XiaoAI / LLM sesli asistan | Kendi konuşma ve LLM arka ucunu gerektirir; düşük. |
| 19 | `ABP/wear_alexa.proto` | Alexa | Yalnız Alexa'lı global yazılım; düşük. |
| 5 | `ABP/wear_nfc.proto` | ulaşım/kapı/banka kartları | NFC'li Çin sürümleri; ilgisiz. |
| 9 | `ABP/wear_lpa.proto` | eSIM | eSIM yok; ilgisiz. |
| 11 | `ABP/wear_stock.proto` | borsa widget'ı | Bantta widget varsa küçük bir ekstra. |
| 13 | `ABP/wear_factory.proto` | fabrika testleri, sensör kaydı, parlaklık | Son kullanıcıya değil; riskli. |
| 15 | `ABP/wear_market.proto` | APK kurulumu (Wear OS saatler) | Bantta RPK kullanılıyor; ilgisiz. |
| 23 | `ABP/wear_interconnection.proto` | telefon durumu, TV/ses kontrolü, ev cihazları, oyun modu | Ağla ilgisi yok; çoğu Xiaomi ekosistemine özgü. |
| 18 | `ABP/wear_media.proto` id 3–19 | bantta müzik kütüphanesi: şarkı yükleme (Mass tür 52), çalma listeleri | Band 10'da hoparlör yok [TAHMİN]; düşük. |

### 16.6 Auth sonrası gelen bilinmeyen `Command{2,110}`

- Ölçüm: auth'tan hemen sonra, pil isteğinin cevabından önce bant istenmeden şifreli `Command{type 2, subtype 110}` yolladı, 64 bayt [ÖLÇÜM] `out/auth-ios-20261013-232031.json`, `findings.md` §6.1. İçerik kaydedilmedi.
- Gadgetbridge'de `System` için 110 yok (en büyük 79) [KOD] `X/services/XiaomiSystemService.java:76-103`. AstroBox'ın `SystemID` listesi 98'de bitiyor, 110 yok; ABP ve ABC'deki tek "110" `SportType DRIVING` [AB] `ABP/wear_system.proto:41-131`, `ABP/wear_common.proto:73`. `System` yük alanları 64'e kadar (`ABP/wear_system.proto:133-197`).
- Benzer bant-kendiliğinden mesajlar: `REPORT_BASIC_STATUS 79`, `REPORT_BATTERY_STATUS 97`, `REPORT_ALERT_STATUS 91`, `REPORT_SYSTEM_SETTING 42` [AB] `ABP/wear_system.proto:101`, `:116-120`. 110 büyük olasılıkla yeni yazılımda eklenmiş bir durum raporu ya da bantın telefondan bir şey istemesi [TAHMİN].
- AstroBox auth sonrası yalnız `Command{2,92}` (ağ durumu) yolluyor [AB] `ABC/device.rs:290-300`. Freeband bunu göndermediği için 110'un "ağ yok" ya da eşlikçi durumu sorusu olması mümkün [TAHMİN].
- **Yapılacak:** Freeband çözülmüş gövdeyi hex olarak loglasın ve genel protobuf çözücüyle alan ağacını yazsın. Gövde `08 02 10 6e 22 <uzunluk>` ile başlamalı; ardından gelen varint `system(4)` içindeki alanı verir (alan = etiket >> 3). 64 ve altıysa bilinen bir yük: ör. `8a 03` = 49 `report_basic_status`, `fa 03` = 63 `battery_status`, `ba 03` = 55 `ota_progress`. 64'ün üstündeyse yeni bir yük. `system` yerine `a0 06` (alan 100, `status`/`error_code`) da gelebilir [AB] `ABP/wear.proto:77`. Cevap vermemek şimdilik zararsız görünüyor: pil cevabı ve canlı akış normal geldi [ÖLÇÜM].
- **Efor / risk:** S (loglama) / düşük.

## 17. Hızlı kazanımlar

Sıralama ölçütü: önce kullanıcıya görünen değer, sonra efor. İlk dokuzu bugünkü "bağlan, gönder, bırak" modeliyle yapılır; tutulan oturum, arka plan modu ya da dosya aktarımı gerektirmez. Hepsi Mi Fitness kapalıyken çalışır.

1. **Saat ve saat dilimi senkronu** (`Command{2,3}`, §5.1, S). Mi Fitness bırakılınca bantın saatini ve saat dilimini (yaz saati, seyahat) düzelten tek şey bu olur; aktivite dosyalarının zaman damgaları da buna dayanıyor. Her bağlantıda otomatik gönderilmeli.
2. **Alarmlar** (`Command{17,0/1/2/4}`, §5.2, S). Bantın en çok kullanılan özelliklerinden biri; saf CRUD, iPhone'u uyandırmadan bilekte sessiz alarm.
3. **Hava durumu** (`Command{10,0/1/2}` + `10,10`, §6, M). Mi Fitness olmadan bantın hava ekranı ve kadran komplikasyonları boş kalır; Open-Meteo ve kullanıcının seçtiği şehirle konum izni bile gerekmez.
4. **Kullanıcı bilgisi ve hedefler** (`Command{8,0}`, §8.1, S). Kalori, mesafe ve nabız bölgeleri bu değerlerle hesaplanıyor; Freeband'in grafiklerindeki sayıları doğru yapar.
5. **Sağlık ayarları ekranı** (`8,10/11`, `8,8/9`, `8,14/15`, `8,12/13`, §9, her biri S). Sürekli nabız aralığı, yüksek/düşük nabız alarmı, SpO2, stres ve hareketsizlik hatırlatıcısı aynı GET → değiştir → SET kalıbıyla; Freeband'in topladığı verinin miktarını ve kalitesini doğrudan belirler.
6. **Takvim senkronu** (`Command{12,1}`, §5.4, S–M). EventKit'ten yaklaşan etkinlikleri tek bir tam liste olarak yazmak; bantta yaklaşan toplantı ve hatırlatma, tek yeni izin.
7. **Cihaz bilgisi ve durumu** (`2,2`, `2,78`, `2,1` ayrıntısı, `2,62`, §9.7, §14, S). Firmware sürümü, "takılı değil / şarjda / uyuyor", son şarj zamanı ve boş alan; hem kullanıcıya hem hata ayıklamaya yarar, Freeband'in 24 saat kadranındaki boş saatleri açıklar.
8. **Kadranı değiştir** (`Command{4,0}` + `4,1`, §13.2, S). Yüklü kadranları listeleyip telefondan değiştirmek; yükleme altyapısı olmadan görünür bir "kontrol" özelliği.
9. **Rahatsız etmeyin ve bileği kaldırınca ekran** (`2,22/23`, `2,24/25`, §10.1–10.2, S). Gece gürültüsünü ve pil tüketimini doğrudan etkileyen iki ayar; alan numaraları iki kaynakta teyitli ama Gadgetbridge göndermediği için önce GET ile bantta doğrulanmalı.
10. **Kısayollar / App Intents ile bildirim ve titreşim** (`7,0`, `2,18`, isteğe bağlı `2,59`; §3.1, §4.1, §4.3, S). Var olan komutlara App Intent eklemek; iOS Otomasyonları Freeband'i arka planda çalıştırıp banta bildirim ya da titreşim gönderebilir (zamanlayıcı bitti, eve vardın, hub uyarısı). Tek ek: `bluetooth-central` arka plan modunu bildirmek.

Bunlarla birlikte yapılması ucuz olan geliştirici işi: `Command{2,110}` ve auth'taki `device_capability` değerlerinin ham loglanması (§16.6, §1.2).

Sonraki büyük adım "tutulan oturum" (bölüm 1.3): `bluetooth-central` arka plan modu ve state restoration. Bu bir kez yapılınca telefonu bul (§4.2), canlı antrenman (§12.2), bantın hava isteği (§6) ve bildirim olayları (§3.2–3.3) birlikte açılır.
