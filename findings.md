# Xiaomi Smart Band 10 için yerel iOS companion uygulaması: fizibilite bulguları

Durum: **Faz 1, 2 ve 3 tamam. iPhone'dan BLE V2 üzerinden auth yapıldı ve pil şifreli kanaldan okundu (2026-10-13).** AstroBox atıfları `vendor/astrobox-Core` ve `vendor/astrobox-Pb` sığ klonlarından.
Tarih: 2026-10-13
Kaynak: Gadgetbridge `master`, commit `d4bd8367` (2026-10-12), `vendor/Gadgetbridge` altında sığ klon.

Kısaltmalar (tüm atıflar bu kökten göreli, `dosya:satır`):

- `X/` = `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/`
- `XD/` = `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/devices/xiaomi/`
- `W/` = `XD/watches/`
- `P/` = `GBProtobufGenerator/src/main/proto/`

İşaretler: **[KOD]** Gadgetbridge kaynağında doğrulandı. **[WEB]** dış kaynak, URL verildi. **[ÖLÇÜM]** kullanıcının kendi bilekliğinde ölçüldü, log `out/` altında. **[TAHMİN]** doğrulanmadı, çıkarım.

---

## 1. Hüküm

**iOS'ta YAPILABİLİR. Band 10 Pro'nun BLE V2 kanalını (`FE95` → `005E`/`005F`) açtığı kullanıcının kendi bilekliğinde, iPhone'dan doğrulandı.** [ÖLÇÜM] `out/gatt-ios-20261013-230635.json`, bölüm 6. **Faz 3 PoC da başarılı:** BandProbe, Mi Fitness'ın key'iyle `device_type=IOS` göndererek auth yaptı ve pili (`Command{type=2, subtype=1}`) şifreli kanaldan okudu: %46, uçtan uca yaklaşık 1 saniye. [ÖLÇÜM] `out/auth-ios-20261013-232031.json`. Protokol tarafında temel bir engel kalmadı; kalan iş veri kanalları (aktivite, uyku, nabız) ve uygulama.

Dayanaklar:

1. Gadgetbridge'de Band 10'un kullandığı protokolün (SPP v2 çerçeveleme + aynı auth) **birebir BLE GATT üzerinden** taşındığı çalışan bir yol zaten var: `XiaomiBleProtocolV2`, servis `0xFE95`, karakteristikler `0x005E` (RX, notify) ve `0x005F` (TX, write). Gadgetbridge'de şu an yalnızca Mi Band 9 Active bu yolu kullanıyor. [KOD] `X/XiaomiUuids.java:28-31`, `X/XiaomiBleProtocolV2.java:64-97`, `X/XiaomiBleProtocolV2.java:346-354`
2. **AstroBox** (App Store'da yayımlanmış iOS uygulaması, Band 9/9 Pro/10'u destekliyor) iOS'ta tam olarak bu yolu kullanıyor: `fe95` / `005f` TX / `005e` RX, ve BLE bağlantısında auth adım 3'te `CompanionDevice.device_type = IOS (1)` gönderiyor. Gadgetbridge aynı alana `0` (ANDROID) yazıyor. [WEB+KOD, kendim doğruladım] `AstroBox-NG-Module-Core/src/constants.rs:1-3`, `AstroBox-NG-Module-Core/src/device/xiaomi/components/auth.rs:285-287`, `AstroBox-NG-Module-Pb/protos/xiaomi/wear_account.proto:101-110`; Gadgetbridge tarafı `X/XiaomiAuthService.java:224-225`
3. Band 10 ile iPhone'dan CoreBluetooth üzerinden BLE V2 auth yapan en az iki bağımsız açık kaynak proje var: `LordierClaw/blueband-map` (Apache-2.0, "Xiaomi Smart Band 10 only", "hardware-confirmed" POC'ye dayanıyor) ve `matheusdanoite/my-band` (lisanssız, Band 10'da donanımda doğrulandığını iddia ediyor). Band 9 için `ireescc277-dotcom/band9-rust-ios` (Rust çekirdek + Swift). [WEB] https://github.com/LordierClaw/blueband-map, https://github.com/matheusdanoite/my-band, https://github.com/ireescc277-dotcom/band9-rust-ios
4. Gadgetbridge'in kendi yorumu da bunu öngörüyor: "auth'un son adımında iOS cihazı olduğumuzu söylersek büyük olasılıkla iki bağlantı türünü de destekliyor". [KOD] `W/RedmiWatch4Coordinator.java:52-56`
5. Yalnızca iPhone'u olan biri için auth key, iOS Dosyalar uygulamasındaki Mi Fitness klasöründen alınabiliyor (Band 10'da test edilmiş). Bölüm 7.

Açık riskler:

1. Gadgetbridge Band 10 ve 10 Pro'yu `BT_CLASSIC` olarak sabitlemiş ve kendi takipçisinde Band 10 için BLE/iOS modu tartışması yok; BLE kanıtı Gadgetbridge'den değil üçüncü parti iOS projelerinden geliyor. [KOD] `W/MiBand10Coordinator.java:47-48`, `W/MiBand10ProCoordinator.java:46-47`
2. ~~Band 10 Pro BLE üzerinden hiçbir yerde doğrulanmadı.~~ Çözüldü: iPhone'dan `FE95/005E/005F` görüldü (bölüm 6), auth ve şifreli komut çalıştı (bölüm 6.1). Gadgetbridge #6248 günlüğü RFCOMM. [WEB] https://codeberg.org/Freeyourgadget/Gadgetbridge/issues/6248
3. Gadgetbridge'de BLE V2 yolunu kullanan tek cihazda (Band 9 Active) aktivite çekme bozuk olarak işaretli; band9-rust-ios ise Band 9'da aktivite senkronunun çalıştığını söylüyor. Aktivite kanalı BLE'de ayrıca test edilmeli. [KOD] `W/MiBand9ActiveCoordinator.java:31-36`
4. Mi Fitness ile **aynı anda** çalışmak pratik değil: oturum ve sıra numaraları bağlantı başına tek, ve senkronize edilen aktivite dosyası ACK'lenince bileklikten siliniyor (bölüm 5.4). Uygulama Mi Fitness'ın yerine geçmeli. AstroBox da bağlanmadan önce Mi Fitness'ın tamamen kapatılmasını istiyor. [WEB] https://abox.run/docs/usage/connection
5. Mi Fitness iOS'un BLE mi MFi/iAP2 mi kullandığına dair doğrudan kanıt (Info.plist) bulunamadı; dolaylı kanıtların hepsi BLE'yi gösteriyor. [TAHMİN]

## 2. Model ve firmware

**Doğrulandı: Xiaomi Smart Band 10 Pro.** iPhone'dan okunan cihaz adı `Xiaomi Smart Band 10 Pro D9B9`, aşağıdaki 10 Pro regex'ine uyuyor. [ÖLÇÜM] `out/gatt-ios-20261013-230635.json`

Ayırt etme yolu reklam (advertisement) adı; Gadgetbridge iki modeli tam olarak bu adla ayırıyor:

| Model | Reklam adı regex'i | Kaynak |
|---|---|---|
| Smart Band 10 | `^Xiaomi Smart Band 10 [0-9A-F]{4}$` | `W/MiBand10Coordinator.java:38` |
| Smart Band 10 Pro | `^Xiaomi Smart Band 10 Pro [0-9A-F]{4}$` | `W/MiBand10ProCoordinator.java:37` |

**Faz 2 sonucu (2026-10-13).**

- iPhone Bluetooth'u kapalıyken bileklik **isim yayınlamıyor**; reklamda yalnız `FE95` service data var, `local_name` boş. Yani yukarıdaki regex'lerle model ayırt edilemedi. [ÖLÇÜM] `out/scan.log`
- Service data (11 bayt): `13 59 a1 73 cd b9 d9 78 cc 25 20`; 5. bayt her yayında artıyor (`cd`, `cf`, `d0`). [ÖLÇÜM] MiBeacon olarak okunursa: frame control `0x5913` (sürüm 5, MAC içeriyor, şifresiz), ürün ID `0x73A1`, sayaç, ters sırada MAC. Ürün ID'si `vendor/` altındaki kaynaklarda geçmiyor. [TAHMİN, MiBeacon düzeni kaynakta doğrulanmadı] Destekleyen ölçüm: cihaz adının son eki `D9B9`, service data'nın son baytlarındaki `b9 d9` ile (ters sırada) aynı, yani reklamda MAC olduğu tahmini tutarlı. [ÖLÇÜM]
- Reklam `kCBAdvDataIsConnectable = 1`. [ÖLÇÜM]

Not: kullanıcının referans verdiği #6248 sorunundan sonra Band 10 Pro için bir coordinator eklenmiş (`W/MiBand10ProCoordinator.java`), deneysel ve `BT_CLASSIC`. [KOD]

Firmware GATT'tan okunamıyor: `0x180A` servisinde yalnız `2A50` (PnP ID) var; model, firmware ve seri numarası karakteristikleri yok. [ÖLÇÜM] Firmware ancak auth sonrası `System/DeviceInfo` protobuf komutuyla (type 2, subtype 2) alınabilir. [KOD] `X/services/XiaomiSystemService.java:76-79`, `P/xiaomi/wear_system.proto:103-108`

## 3. Transport bulguları

### 3.1 Gadgetbridge transport'u nasıl seçiyor

- Coordinator `getConnectionType()` döndürür. Varsayılan `BLE`. [KOD] `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/devices/AbstractBLEDeviceCoordinator.java:21-23`
- `XiaomiSupport` bu değere göre `XiaomiBleSupport` ya da `XiaomiSppSupport` kurar. `BOTH` ise kullanıcı ayarı (`PREF_FORCE_CONNECTION_TYPE`) okunur, ayar yoksa BLE seçilir. [KOD] `X/XiaomiSupport.java:143-156`, `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/util/preferences/DevicePrefs.java:140-151`
- Ayar ekranı yalnızca `BOTH` olan cihazlarda gösterilir. [KOD] `XD/XiaomiCoordinator.java:549-560`
- **Firmware sürümüne göre seçim yok.** Seçim tamamen modele (coordinator) göre sabit. Kullanıcının bahsettiği "firmware'e göre BLE/Classic" ifadesi kodda bir koşul olarak yer almıyor. [KOD]

Modellere göre durum:

| Cihaz | ConnectionType | Kaynak |
|---|---|---|
| Mi Band 8, 8 Active, 9 Active | BLE (varsayılan) | override yok, `W/MiBand9ActiveCoordinator.java` |
| Mi Band 8 Pro, 9, 9 Pro, **10, 10 Pro** | BT_CLASSIC | `W/MiBand9Coordinator.java:48-49`, `W/MiBand9ProCoordinator.java:48-49`, `W/MiBand10Coordinator.java:47-48`, `W/MiBand10ProCoordinator.java:46-47` |
| Redmi Watch 3, 3 Active, Watch S1, S1 Active | BOTH | `W/RedmiWatch3Coordinator.java:37-38`, `W/XiaomiWatchS1Coordinator.java:41-43` |
| Redmi Watch 4, 5, 6, Move | BT_CLASSIC + "iOS dersek muhtemelen BLE de olur" yorumu | `W/RedmiWatch4Coordinator.java:52-56` |

### 3.2 Üç taşıma katmanı

**BLE V1** (Mi Band 8 kuşağı): `0xFE95` altında `0051` (komut okuma), `0052` (komut yazma), `0053` (aktivite), `0055` (veri yükleme). Kendi parçalama (chunking) şeması, mesaj başına AES-CCM. [KOD] `X/XiaomiUuids.java:40-46`, `X/XiaomiCharacteristicV1.java:443-446`, `X/XiaomiCharacteristicV1.java:389`. Çerçeve düzeni, şifreleme ve Xiaomi Watch S1 Active ölçümü: [`docs/BLE-V1.md`](docs/BLE-V1.md).

**BLE V2** (Mi Band 9 Active): `0xFE95` altında `005E` RX/notify, `005F` TX/write. İçinden SPP v2 paketleri akar. `XiaomiBleSupport` önce V1 karakteristiklerini arar, bulamazsa V2'yi dener. [KOD] `X/XiaomiUuids.java:28-31`, `X/XiaomiBleSupport.java:64-83`

**SPP (RFCOMM, Bluetooth Classic)**: UUID `0x1101`. Önce V1 çerçeveyle sürüm sorulur; cevabın ilk baytı `>= 2` ise SPP v2'ye geçilir. Band 9/10 ailesi burada v2'ye geçiyor. [KOD] `X/XiaomiUuids.java:26`, `X/XiaomiSppSupport.java:74-82`, `X/XiaomiSppSupport.java:263-285`

Kritik gözlem: **BLE V2, SPP v2 ile aynı paket formatını ve aynı auth'u kullanıyor** (`XiaomiBleProtocolV2` doğrudan `XiaomiSppPacketV2` sınıfını kullanıyor). Band 10'un bir `FE95/005E/005F` GATT kanalı açtığı görülürse, protokol tarafında yeni bir şey çözmek gerekmiyor. [KOD] `X/XiaomiBleProtocolV2.java:87-94`, `X/XiaomiBleProtocolV2.java:313-343`

### 3.3 iOS açısından anlamı

- RFCOMM/SPP üçüncü parti iOS uygulamasına kapalı (yalnızca MFi + ExternalAccessory). Band 10 sadece SPP konuşuyorsa iOS'ta **imkânsız**.
- `FE95` SIG tarafından Xiaomi'ye atanmış 16-bit bir UUID; CoreBluetooth'un engellediği servisler (HID vb.) arasında değil. AstroBox iOS'ta bu servise `bluest` (CoreBluetooth sarmalayıcısı) ile bağlanıyor, yani engel yok. [WEB] https://github.com/AstralSightStudios/AstroBox-NG-Module-Bluetooth
- Bileklik iPhone ile sistem düzeyinde zaten bağlıysa yeni uygulama `retrieveConnectedPeripherals(withServices: [FE95])` ile aynı çevre birimi yeniden eşleme yapmadan alabilir. [TAHMİN, band9-rust-ios README'si "sistem ya da Mi Fitness tarafından zaten bağlanmış FE95 çevre birimlerini" listelediğini söylüyor] **Doğrulandı:** BandProbe `retrieveConnectedPeripherals(withServices: [FE95, 180A, 180F])` ile bilekliği yeniden eşlemeden aldı ve GATT'ını okudu. [ÖLÇÜM] `probe-ios/BandProbe/Probe.swift`
- macOS'taki bleak de CoreBluetooth kullandığı için Mac'in iyi bir vekil olacağı düşünülmüştü. Ama bileklik eşleşmemiş Mac'ten bağlantı kabul etmedi (bölüm 6); bu bileklikte testler iPhone'dan yapılmalı. [ÖLÇÜM]

## 4. Auth ve şifreleme özeti

### 4.1 Auth key

- 16 bayt (32 hex karakter, isteğe bağlı `0x` öneki). Kısa gelirse sıfırla doldurulur. [KOD] `X/XiaomiAuthService.java:303-321`
- Eski düz metin cihazlarda auth key yerine sayısal kullanıcı ID'si kullanılıyor; Band 10 şifreli yolu kullanır. [KOD] `XD/XiaomiCoordinator.java:103-104`, `X/XiaomiAuthService.java:103-115`
- Key, bileklik Mi Fitness ile eşlenirken Xiaomi sunucusu tarafından üretilir ve hesaba bağlanır. Yeniden eşleme (unbind/bind, fabrika ayarı) key'i değiştirir. [WEB, bölüm 7]

### 4.2 Bağlantı başlangıcı (BLE V2)

1. MTU 512 iste, `005E` için notify aç. [KOD] `X/XiaomiBleProtocolV2.java:81-85`
2. `005F`'ye SessionConfig `START_SESSION_REQUEST` (opcode 1, seq 0) yaz. Payload sabit TLV'ler: sürüm `01.00.00`, maks çerçeve `0xFC00`, TX penceresi 32, zaman aşımı 10000 ms. [KOD] `X/XiaomiBleProtocolV2.java:87-94`, `X/XiaomiSppPacketV2.java:157-184`
3. Saatten SessionConfig gelince şifreli el sıkışma başlar. [KOD] `X/XiaomiBleProtocolV2.java:316-320`

### 4.3 El sıkışma (komut type 1)

| Adım | Yön | Protobuf | Kaynak |
|---|---|---|---|
| 1 | telefon → saat | `Command{type=1, subtype=26, auth.appVerify{nonce=16 rastgele bayt}}` | `X/XiaomiAuthService.java:93-101`, `:250-267`, `P/xiaomi/wear_account.proto:29-35` |
| 2 | saat → telefon | `subtype=26, auth.deviceVerify{nonce, hmac}` | `X/XiaomiAuthService.java:130-149`, `P/xiaomi/wear_account.proto:37-40` |
| 3 | telefon → saat | `subtype=27, auth.appConfirm{encryptedNonces, encryptedDeviceInfo}` | `X/XiaomiAuthService.java:205-248`, `P/xiaomi/wear_account.proto:42-45` |
| 4 | saat → telefon | `subtype=27` gelirse auth tamam, bundan sonra trafik şifreli | `X/XiaomiAuthService.java:152-161` |

Auth komutları her zaman `Authentication` kanalında, **düz metin** opcode ile gider (kanal 1, opcode 1). [KOD] `X/XiaomiBleProtocolV2.java:227-231`, `X/XiaomiSppPacketV2.java:362-374`

### 4.4 Anahtar türetme

`computeAuthStep3Hmac` aslında standart **HKDF-SHA256** (RFC 5869):

- salt = `phoneNonce(16) || watchNonce(16)`
- IKM = auth key (16)
- info = `"miwear-auth"`
- L = 64 bayt

[KOD] `X/XiaomiAuthService.java:269-301` (PRK = HMAC(salt, key) satır 278-279; T(n) = HMAC(PRK, T(n-1) || info || n) satır 290-299). HKDF olduğu benim çıkarımım ama matematiksel olarak birebir aynı; CryptoKit'teki `HKDF<SHA256>` ile doğrulanabilir.

64 baytın bölünmesi [KOD] `X/XiaomiAuthService.java:206-211`:

| Bayt | Alan |
|---|---|
| 0-15 | decryptionKey (saat → telefon) |
| 16-31 | encryptionKey (telefon → saat) |
| 32-35 | decryptionNonce |
| 36-39 | encryptionNonce |

Doğrulamalar:

- Saatin HMAC'i: `HMAC-SHA256(decryptionKey, watchNonce || phoneNonce)` == `deviceVerify.hmac`, değilse key yanlış. [KOD] `X/XiaomiAuthService.java:218-222`
- Telefonun kanıtı: `encryptedNonces = HMAC-SHA256(encryptionKey, phoneNonce || watchNonce)`. [KOD] `X/XiaomiAuthService.java:233`
- `encryptedDeviceInfo = AES-CCM(encryptionKey, nonce12 = encryptionNonce(4) || 0u32 || 0u32 (LE), tag 4 bayt)` ile şifrelenmiş `CompanionDevice{unknown1=0, phoneApiLevel, phoneName, unknown3=224, region}`. [KOD] `X/XiaomiAuthService.java:178-189`, `:224-234`, `:344-374`, `P/xiaomi/wear_account.proto:18-24`
- `CompanionDevice.unknown1` aslında `device_type` enum'ı: `ANDROID=0, IOS=1, VELA=2, OTHER=15`. Gadgetbridge `0` gönderiyor; AstroBox BLE'de `1` (IOS) gönderiyor. iOS uygulaması `1` göndermeli. [KOD] `P/xiaomi/wear_account.proto:19`, `X/XiaomiAuthService.java:224-225`; [WEB+KOD] `AstroBox-NG-Module-Pb/protos/xiaomi/wear_account.proto:101-110`, `AstroBox-NG-Module-Core/src/device/xiaomi/components/auth.rs:285-287`

### 4.5 Auth sonrası çerçeveleme ve şifreleme (SPP v2 / BLE V2)

Çerçeve (little-endian) [KOD] `X/XiaomiSppPacketV2.java:461-470`, `:472-552`:

```
a5 a5 | type(4 bit) | seq(u8) | payload_len(u16) | crc16(u16) | payload
```

- Tipler: 0 NACK, 1 ACK, 2 SessionConfig, 3 Data. [KOD] `X/XiaomiSppPacketV2.java:32-41`
- CRC: CRC-16/ARC, yalnızca payload üzerinde. [KOD] `X/XiaomiSppPacketV2.java:439-451`
- Data payload: `channel(4 bit) | opcode(u8) | body`. Kanallar: 1 protobuf, 2 data, 5 activity. Opcode: 1 düz, 2 şifreli. [KOD] `X/XiaomiSppPacketV2.java:282-290`, `:396-403`
- Protobuf ve Activity kanalları şifreli, Data ve Auth düz. [KOD] `X/XiaomiSppPacketV2.java:362-374`
- Gelen her Data paketine ACK gönderilir. [KOD] `X/XiaomiBleProtocolV2.java:321-330`
- Şifre: **AES-128-CTR, IV = key**, her mesajda sayaç baştan başlıyor (aynı keystream tekrar kullanılıyor; Gadgetbridge yazarının yorumu "I wish I was kidding"). Giden: encryptionKey, gelen: decryptionKey. [KOD] `X/XiaomiAuthService.java:376-402`

BLE V1 farkı: mesaj başına AES-CCM, nonce = `nonce4 || 0 || sayaç`, 4 bayt tag. [KOD] `X/XiaomiAuthService.java:178-202`, `X/XiaomiCharacteristicV1.java:443-446`

### 4.6 iOS'ta kriptografi

- HKDF, HMAC-SHA256: CryptoKit'te hazır.
- AES-CTR: CryptoKit'te yok, CommonCrypto `kCCModeCTR` ile var.
- AES-CCM: Apple framework'lerinde yok; ya CryptoSwift ya da AES-ECB (CommonCrypto) üzerine ~80 satırlık CCM yazılır. Yalnızca auth adım 3'te bir kez gerekiyor (V2 yolunda).

## 5. Protobuf mesajları

Şema: `P/xiaomi.proto` (kök `Command`) ve `P/xiaomi/*.proto`. Her mesaj `Command{type, subtype, ...}` zarfında. [KOD] `P/xiaomi.proto:22-45`

### 5.1 Sağlık (type 8, `Health`)

`Health` alanları [KOD] `P/xiaomi/wear_fitness.proto:7-51`; subtype sabitleri [KOD] `X/services/XiaomiHealthService.java:91-123`.

| Subtype | Anlam | Mesaj |
|---|---|---|
| 0 | kullanıcı bilgisi yaz | `UserInfo` (`wear_fitness.proto:53-63`) |
| 1 | bugünün aktivite dosya listesi | istek `ActivitySyncRequestToday`, cevap `activityRequestFileIds` (bytes) |
| 2 | geçmiş aktivite dosya listesi | cevap `activityRequestFileIds` |
| 3 | tek dosya iste | `activityRequestFileIds` = 7 baytlık dosya ID'si |
| 5 | dosya ACK (bileklikten siler) | `activitySyncAckFileIds` |
| 8 / 9 | SpO2 ayarı oku / yaz | `SpO2` (`wear_fitness.proto:69-90`) |
| 10 / 11 | nabız ayarı oku / yaz | `HeartRate` (`wear_fitness.proto:92-112`) |
| 14 / 15 | stres ayarı oku / yaz | `Stress` (`wear_fitness.proto:123-126`) |
| 45 / 46 / 47 | canlı istatistik başlat / durdur / olay | `RealTimeStats{steps, calories, heartRate, standingHours}` (`wear_fitness.proto:218-225`) |
| 26, 29, 30, 48-50 | antrenman durumu, konum, canlı antrenman | `WorkoutStatusWatch`, `WorkoutOpenWatch`, `WorkoutLocation`, `WorkoutStatsWatch` |

Akış [KOD] `X/services/XiaomiHealthService.java:907-990`: subtype 1 → dosya ID listesi (7'nin katı) → subtype 2 → her dosya için subtype 3 → dosya içeriği **Activity kanalında** parça parça gelir → subtype 5 ile ACK.

### 5.2 Aktivite dosyaları (protobuf değil, ikili format)

- Dosya ID'si 7 bayt: `ts(u32 LE) | tz(i8, 15 dk) | version(u8) | flags(type<<7 | subtype<<2 | detailType)`. [KOD] `X/activity/XiaomiActivityFileId.java:92-123`
- Parça: `total(u16) | num(u16) | veri`; birleşik dosyanın son 4 baytı CRC32. [KOD] `X/activity/XiaomiActivityFileFetcher.java:91-133`
- Tip/alt tip tablosu ve parser seçimi [KOD] `X/activity/XiaomiActivityFileId.java:237-311`, `X/activity/XiaomiActivityParser.java:85-133`:

| Veri | Dosya (type/subtype/detail) | Parser |
|---|---|---|
| Adım, nabız, stres, SpO2, kalori, mesafe (dakikalık) | ACTIVITY / DAILY (0x00) / DETAILS | `X/activity/impl/DailyDetailsParser.java` |
| Günlük özet (adım, HR min/max/dinlenik, SpO2 min/max, stres, vitality, training load) | ACTIVITY / DAILY / SUMMARY | `X/activity/impl/DailySummaryParser.java` |
| Uyku evreleri | ACTIVITY / SLEEP_STAGES (0x03) | `X/activity/impl/SleepStagesParser.java` |
| Uyku detayları (derin/hafif/REM/uyanık) | ACTIVITY / SLEEP (0x08) | `X/activity/impl/SleepDetailsParser.java` |
| Elle ölçümler (HR, SpO2, stres) | ACTIVITY / MANUAL_SAMPLES (0x06) | `X/activity/impl/ManualSamplesParser.java` |
| Antrenman özet / detay / GPS | SPORTS / * / SUMMARY, DETAILS, GPS_TRACK | `WorkoutSummaryParser`, `WorkoutDetailsParser`, `WorkoutGpsParser` |

### 5.3 Sistem (type 2, `System`)

Pil subtype 1 (`Power.battery.level`), cihaz bilgisi subtype 2 (`DeviceInfo{serialNumber, firmware, model}`). Faz 3 PoC'si için en basit okuma: `Command{type=2, subtype=1}`. [KOD] `X/services/XiaomiSystemService.java:76-79`, `:110`, `P/xiaomi/wear_system.proto:8-14`, `:88-108`

### 5.4 Mi Fitness ile bir arada yaşama

- ACK edilen aktivite dosyası bileklikten silinir; Gadgetbridge bunu ayarla kapatabiliyor (`keep_activity_data_on_device`). Kendi uygulaman ACK atmazsa Mi Fitness de veriyi alır, ama o zaman bileklik dolabilir. [KOD] `X/activity/XiaomiActivityFileFetcher.java:147-150`, `X/XiaomiPreferences.java:93-96`
- **Ölçüm (2026-10-13):** BandProbe testi bitince arka planda 005E'ye abone kalmıştı. Bu sırada açılan Mi Fitness "senkronize ediliyor" dedi, sonra "senkronizasyon tamamlanmadı". BandProbe süreci sonlandırılıp Mi Fitness yeniden açılınca hemen senkronize oldu. [ÖLÇÜM] Olası sebep: BandProbe gelen her veri paketine kendi ACK'ini gönderiyordu, yani Mi Fitness'ın oturumuna karışıyordu. [TAHMİN] Düzeltme: BandProbe v4, iş bitince 005E aboneliğini kapatıp bağlantıyı bırakıyor ve aktif oturum dışında hiçbir pakete cevap vermiyor. Ders: iOS'ta aynı bilekliği iki uygulama paylaşabilir, ama 005E'yi aynı anda yalnız bir uygulama dinleyip cevaplamalı.
- Oturum (SessionConfig, sıra numaraları, oturum anahtarları) bağlantı başına tek. iOS'ta iki uygulama aynı çevre birime bağlanabilir ama aynı `005E/005F` kanalında iki ayrı oturum yürütemez. [TAHMİN, mimariden çıkarım]

## 6. Keşfedilen GATT tablosu

iPhone'dan, BandProbe test uygulamasıyla (`probe-ios/`) okundu, 2026-10-13. Yalnız servis/karakteristik keşfi ve pil okuması; yazma ve bildirim açma yok. [ÖLÇÜM] `out/gatt-ios-20261013-230635.json`

| Servis | Karakteristik | Özellikler | Anlam | Kaynak |
|---|---|---|---|---|
| `FE95` | `0050` | read | Bilinmiyor; Gadgetbridge'in UUID listesinde yok | [ÖLÇÜM] |
| `FE95` | `005E` | write-without-response, notify (CCCD `2902`) | **V2 RX** | `X/XiaomiUuids.java:30` |
| `FE95` | `005F` | write-without-response, notify (CCCD `2902`) | **V2 TX** | `X/XiaomiUuids.java:31` |
| `FDAB` | `0001` read; `0002`, `0003` write-without-response + notify; `0004` read + notify | Xiaomi Proximity Unlock Service | `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/btle/BleNamesResolver.java:583` |
| `180F` | `2A19` | read, notify | Pil, **%46** okundu | standart |
| `180A` | `2A50` | read | Yalnız PnP ID (okunmadı) | standart |
| `180D` | `2A37` | notify | Standart Heart Rate Measurement | standart |
| `1B7E8251-2877-41C3-B46E-CF057C562023` | `8AC32D3F-5CB9-4D44-BEC2-EE689169F626` | write-without-response, notify | Bilinmiyor; `vendor/` altında geçmiyor | [ÖLÇÜM] |

Çıkarımlar:

- **BLE V2 yolu var, V1 yok** (`0051/0052/0053/0055` görünmüyor). Gadgetbridge'in Band 9 Active için kullandığı yol bu bileklikte de açık. [ÖLÇÜM]
- `005F` yalnız write-without-response destekliyor; iOS'ta `.withoutResponse` ile ve `maximumWriteValueLength(for: .withoutResponse)` boyunda parçalayarak yazılmalı. Gadgetbridge de parçalı yazıyor. [ÖLÇÜM] `X/XiaomiBleProtocolV2.java:357`
- `180D/2A37` standart nabız servisi. Bildirim açılırsa Xiaomi auth'u olmadan canlı nabız verebilir; bileklikte "nabız yayını" ayarı açıkken akıyor olabilir. Bildirim açmak CCCD'ye yazma demek, Faz 2'de denenmedi. [TAHMİN]
- Mac'ten (eşleşmemiş merkez) bağlantı iki kez zaman aşımına uğradı: 20 sn ve 60 sn, reklam bağlanılabilir (`kCBAdvDataIsConnectable = 1`) olduğu hâlde. iPhone (eşleşmiş) ise bağlandı. Bileklik bağlantıyı büyük olasılıkla yalnız eşleşmiş cihazdan kabul ediyor. [ÖLÇÜM] `out/gatt.log`, `out/gatt-try2.log`; sebep [TAHMİN]
- iPhone Bluetooth'u açıkken bileklik reklam yapmıyor; nRF Connect gibi tarayıcılarda görünmüyor. Uygulama onu taramayla değil `retrieveConnectedPeripherals` ile bulmalı. [ÖLÇÜM]

### 6.1 Faz 3: auth ve şifreli pil okuması (iPhone, 2026-10-13)

BandProbe (`probe-ios/`) iOS'un bağlı tuttuğu bilekliği `retrieveConnectedPeripherals` ile aldı. Mi Fitness kapalıydı. [ÖLÇÜM] `out/auth-ios-20261013-232031.json`

| Zaman | Yön | Olay |
|---|---|---|
| 23:20:30 | → | `005E` bildirimi açıldı; `005F` yazma boyu 512 bayt |
| 23:20:30 | → | SessionConfig START, seq 0 |
| 23:20:30 | ← | SessionConfig opcode 2 (START_SESSION_RESPONSE) |
| 23:20:30 | → | auth adım 1, telefon nonce'u (`Command{1, 26}`) |
| 23:20:30 | ← | bileklik nonce'u ve HMAC; HMAC Mi Fitness key'iyle **doğru** |
| 23:20:30 | → | auth adım 3 (`Command{1, 27}`), CompanionDevice `device_type=IOS`, `device_name="BandProbe"`, `app_capability=0xFFFFFFFF` |
| 23:20:31 | ← | `Command{1, 27}`: auth onaylandı |
| 23:20:31 | → | şifreli `Command{2, 1}` (pil) |
| 23:20:31 | ← | istenmeden gelen şifreli `Command{2, 110}`, 64 bayt, işlenmedi |
| 23:20:31 | ← | şifreli `Command{2, 1}`: `system.power.battery.level = 46` |

Çıkarımlar:

- Bölüm 4'teki auth ve şifreleme özeti bu bileklikte birebir doğru: HKDF `miwear-auth`, `device_type=IOS`, AES-CCM ile CompanionDevice, ardından AES-CTR (IV = key). [ÖLÇÜM]
- Aynı ölçülen pil değeri standart `180F/2A19`'dan da okunmuştu (%46), yani şifreli kanalın çözümü doğru. [ÖLÇÜM]
- `Command{type=2, subtype=110}`: Gadgetbridge'in `X/` altında değeri 110 olan bir sabit yok (`grep '= 110;'` boş). İçeriği henüz incelenmedi, anlamı bilinmiyor. [ÖLÇÜM + KOD]
- Protokol kodu (`probe-ios/BandProbe/MiProtocol.swift`) Mac'te bağımsız bir Python uygulamasıyla 13 test vektörüne karşı doğrulandı (`probe-ios/tests/protocol/`). Key okuyucu sentetik Mi Fitness önbellekleriyle test edildi (`probe-ios/tests/keystore/`).
- Key (yöntem #1) cihaz içinde okundu: kullanıcı Dosyalar'dan Mi Fitness klasörünü seçti, uygulama `VirtualDevice_registerList/manifest.sqlite`'ı buldu, key yalnız telefonun Keychain'ine yazıldı. Mac'e gelmedi. [ÖLÇÜM]
- Referans araç (`xiaomi-band-ios-export`) yalnız `registerList_de` kaydını ve `inline_data`'yı okuyor. Önbellek YYKVStorage biçiminde: kayıt adı sunucu bölgesine göre değişebilir ve büyük değerler `data/<filename>` dosyasına yazılır. BandProbe ikisini de arıyor. [KOD: `schemas/manifest.sql` şeması; bölge/dosya davranışı TAHMİN, ilk denemede `registerList_de` + inline okuması key bulamadı]

### 6.2 Canlı istatistik: bugünkü adım ve anlık nabız (iPhone, 2026-10-13)

BandProbe v0.3 auth'tan hemen sonra şifreli `Command{type=8, subtype=45}` gönderiyor. Bileklik ardından düzenli olarak `Command{8, 47}` yolluyor; içinde `health.realTimeStats{steps 1, calories 2, heartRate 4, standingHours 6}` var. Durdurma komutu `Command{8, 46}`. [KOD] `X/services/XiaomiHealthService.java:115-117`, `P/xiaomi.proto:30` (`health = 10`), `P/xiaomi/wear_fitness.proto:43` (`realTimeStats = 39`), `:218-225`

- Kullanıcı kendi bilekliğinde doğruladı: adım, nabız, pil ve kalori canlı geliyor, adım yürürken artıyor. [ÖLÇÜM, kullanıcı gözlemi; ham değerler kaydedilmedi]
- Nabız ilk birkaç olayda ≤10 geliyor, yani henüz ölçülmemiş; Gadgetbridge de bu değerleri atlıyor. [KOD] `X/services/XiaomiHealthService.java:1046`
- Canlı mod bileklikte sürekli nabız ölçümü açtığı için BandProbe akışı 120 sn sonra ya da uygulama arka plana geçince `8/46` ile durduruyor ve kanalı bırakıyor. [TASARIM]
- Bu yol aktivite dosyası çözmeden "bugünkü toplam + canlı nabız" veriyor. Geçmiş dakika verisi ve uyku için yine bölüm 5.1-5.2'deki dosya akışı gerekiyor.

Gadgetbridge'in beklediği UUID'ler (karşılaştırma için):

| UUID | Anlam | Kaynak |
|---|---|---|
| `0000fe95-...` | Xiaomi servisi (V1 ve V2) | `X/XiaomiUuids.java:29`, `:40` |
| `0000005e-...` | V2 RX (notify) | `X/XiaomiUuids.java:30` |
| `0000005f-...` | V2 TX (write) | `X/XiaomiUuids.java:31` |
| `00000051/52/53/55-...` | V1 komut/aktivite/yükleme | `X/XiaomiUuids.java:42-45` |
| `00001101-...` | SPP (Classic, GATT'ta görünmemeli) | `X/XiaomiUuids.java:26` |

## 7. Yalnızca iPhone'u olan biri için auth key seçenekleri

Ortak kural: Mi Fitness'ta unbind/bind yapmak ya da bilekliği fabrika ayarlarına döndürmek key'i değiştirir. [WEB] https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/

| # | Yöntem | Yalnız iPhone ile? | Durum |
|---|---|---|---|
| 1 | **iOS Dosyalar → Bu iPhone'da → Mi Fitness** klasörünü sıkıştırıp Mac'e AirDrop'la. Key: `MHWCahe/<uid>/VirtualDevice_registerList/manifest.sqlite` içinde, `registerList_de` girdisindeki binary plist'te `encryptKey` alanı (32 hex karakter). | **Evet**, jailbreak yok | **Band 10'da test edilmiş** (`artyomxx/xiaomi-band-ios-export`, README'ye göre MIT). AstroBox destek belgeleri de aynı yolu "Yöntem 3 (iOS)" olarak veriyor. [WEB] https://github.com/artyomxx/xiaomi-band-ios-export, https://github.com/AstralSightStudios/AstroBoxSkills |
| 2 | `huami-token --method xiaomi`: Xiaomi hesabına `sid=miothealth` ile girip `POST https://hlth.io.mi.com/app/v1/source/get_source_list` çağırıyor; bağlı giyilebilirleri auth key ile döndürüyor. | Evet, telefonsuz | Kodda var (MIT), ama **captcha/e-posta 2FA isteyen hesaplarda kırılıyor** (açık issue #84). Band 9/10 için key döndürdüğü doğrulanmadı. [WEB] https://github.com/argrento/huami-token, https://github.com/argrento/huami-token/issues/84 |
| 3 | AstroBox'ın uygulama içi Xiaomi girişi | Evet | Key'i AstroBox içinde kullanıyor; dışarı aktarılıp aktarılamadığı doğrulanmadı. [WEB] https://github.com/AstralSightStudios/AstroBox-NG-Module-Account |
| 4 | Xiaomi Cloud Tokens Extractor (MIoT API) | Evet | Mi Fitness giyilebilirleri için **doğrulanmadı**. [WEB] https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor |
| 5 | Android Mi Fitness günlükleri / root'lu Android veritabanı | Hayır | Yalnız Android; modele göre tutarsız. [WEB] https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/ |
| 6 | iOS Mi Fitness trafiğini MITM ile dinlemek | — | Sertifika sabitleme (pinning) nedeniyle başarısız raporu var. [WEB] https://habr.com/en/articles/1057044/ |

**Gerçekçi yol: #1.** Bilgisayar bile gerekmeyebilir: iOS uygulaması `UIDocumentPickerViewController` ile kullanıcıya `Mi Fitness/.../manifest.sqlite` dosyasını seçtirip key'i cihazda okuyabilir. [TAHMİN, denenmedi]

Uyarı: Mi Fitness klasörü sağlık önbelleği gibi başka kişisel veriler de içeriyor; yalnızca yerelde tutulmalı, depoya girmemeli (`.gitignore` zaten `vendor/`, `out/`, `.env` hariç tutuyor).

## 8. Lisans

**Gadgetbridge: AGPL-3.0-or-later.** [KOD] `LICENSE:1-2`; dosya başlıkları ör. `W/MiBand10Coordinator.java:1-16` ("either version 3 of the License, or (at your option) any later version").

Swift'e port edip yayımlarsan (hukuki görüş değildir):

1. **Kodu satır satır çevirmek türev eserdir.** Dağıtırsan bütün uygulama AGPLv3 (ya da sonrası) olmalı, kaynak kodu sağlanmalı, telif bildirimleri korunmalı. AGPL'in ağ maddesi (§13) yerel bir uygulama için pratikte devreye girmiyor.
2. **Yalnız kendi cihazına kendi hesabınla kurmak dağıtım değildir**, yükümlülük doğurmaz.
3. **App Store sorunlu.** Apple'ın kullanım kuralları AGPL'in "ek kısıtlama getirilemez" maddesiyle (§10) çelişiyor; VLC 2011'de tam olarak bu şikâyet üzerine App Store'dan kaldırıldı ve ancak lisansını değiştirip (MPLv2) 2013'te döndü. Gadgetbridge'in yüzlerce katkıcısı var, lisans izni almak pratikte imkânsız. [WEB] https://www.engadget.com/2011-01-09-the-gpl-the-app-store-and-you.html, https://images.videolan.org/press/ios2out.html
4. **Temiz oda (clean-room) yolu:** Protokol gerçekleri (UUID'ler, çerçeve düzeni, CRC tipi, HKDF parametreleri, protobuf alan numaraları) birlikte çalışabilirlik için gereken işlevsel bilgilerdir ve genelde telifle korunmaz; AB 2009/24/EC Madde 6 ve ABD DMCA 1201(f) birlikte çalışabilirlik için tersine mühendisliğe izin veriyor. Bu belge gibi bir spesifikasyondan, Gadgetbridge kodunu kopyalamadan yazılan bir uygulama istediğin lisansla yayımlanabilir. Gadgetbridge'in `.proto` dosyalarını aynen kopyalamak yerine alanları spesifikasyondan yeniden yazmak daha güvenli. [TAHMİN, hukuki yorum]
5. Diğer kaynakların lisansları:

| Proje | Lisans | Ne anlama geliyor |
|---|---|---|
| AstroBox-NG (Core, Pb, Bluetooth, Account) | AGPL-3.0 + ek atıf şartı (README "Additional Terms") | Gadgetbridge ile aynı kısıt + atıf |
| LordierClaw/blueband-map | Apache-2.0 | Kod alınabilir, App Store ile uyumlu |
| artyomxx/xiaomi-band-ios-export | MIT (README) | Key çıkarma mantığı alınabilir |
| matheusdanoite/my-band, band9-rust-ios, b-nnett/goose | Lisans dosyası yok = tüm hakları saklı | Yalnızca fikir kaynağı, kod kopyalanmamalı |

## 9. iOS uygulaması planı

### 9.1 Mimari

- **BLE katmanı Swift'te kalmalı:** CoreBluetooth, `bluetooth-central` arka plan modu, state restoration, `retrieveConnectedPeripherals(withServices: [FE95])`. Arka planda çalışma ve yeniden bağlanma Apple API'lerine sıkı bağlı; bunu Rust'a taşımanın faydası yok.
- **Protokol çekirdeği: Rust mantıklı, ama şart değil.** Önerim, Goose ve band9-rust-ios'taki gibi I/O içermeyen (sans-IO) bir Rust çekirdeği: içeri bayt girer, dışarı çerçeve/komut/olay çıkar. Çekirdekte çerçeveleme, CRC-16/ARC, CRC32, HKDF + AES-CCM + AES-CTR, protobuf ve aktivite dosyası parser'ları bulunur.
  - Lehte: RustCrypto'da `ccm`/`ctr`/`hkdf` hazır (Apple framework'lerinde CCM yok, CTR yalnız CommonCrypto'da). Parser'lar fiddly ikili formatlar; Mac'te yakalanmış dosyalarla birim test ve fuzz yapmak kolay. Aynı çekirdek bir Mac CLI'sında da kullanılabilir.
  - Aleyhte: xcframework, iki hedef (cihaz + simülatör), UniFFI ya da C köprüsü (Goose JSON-over-C kullanıyor). Yalnız iOS hedefleniyorsa saf Swift (swift-protobuf + CryptoKit + CommonCrypto + ~80 satır CCM) daha az iş.
  - Karar kuralı: Mac/Linux aracı da istiyorsan Rust; yalnız iPhone uygulaması istiyorsan Swift.
- Depolama: yerel SQLite (GRDB) ya da SwiftData; isteğe bağlı HealthKit'e yazma (adım, nabız, uyku, SpO2).

### 9.2 Sıra

1. **Faz 2, tamam:** iPhone'dan (BandProbe) salt okunur GATT taraması yapıldı, `FE95/005E/005F` görüldü. Mac'ten bağlantı kabul edilmedi.
2. **Key, tamam:** Yöntem #1 cihaz içinde uygulandı; key yalnız iPhone Keychain'inde (bölüm 6.1).
3. **Faz 3 PoC, tamam (bölüm 6.1):** Mac bağlanamadığı için iPhone'da, BandProbe'un üzerine Swift ile yazıldı. Adımlar: SessionConfig → auth (`device_type=IOS`) → pil (`Command{type=2, subtype=1}`). Bu sırada Mi Fitness kapalı olmalı; aynı kanalda iki oturum yürümez (bölüm 5.4).
4. **Aktivite:** bugünün dosya listesi → bir `DailyDetails` dosyası → parse. Başlangıçta **ACK gönderme**, böylece veri bileklikte kalır ve Mi Fitness'tan bir şey çalınmaz.
5. **iOS MVP:** bağlan, auth, pil, canlı nabız (subtype 45/47), aktivite senkronu, yerel veritabanı.
6. **Mi Fitness'tan çıkış kararı:** Mi Fitness yüklü ve arka planda açıkken yeniden bağlanıp oturumu ve veriyi alır; kalıcı kullanım için Mi Fitness'ı kaldırmak ya da "Uygulamayı Boşalt" demek gerekir (unbind yapmadan, key aynı kalır). Firmware güncellemeleri için ara sıra Mi Fitness'a dönmek gerekebilir. [TAHMİN]

### 9.3 Bilinmeyenler

- ~~Band 10 Pro'nun BLE V2 açıp açmadığı.~~ Açıyor (bölüm 6), auth `device_type=IOS` ile kabul edildi (bölüm 6.1).
- `Command{2, 110}` mesajının anlamı.
- ~~BandProbe oturumundan sonra Mi Fitness'ın sorunsuz yeniden bağlanıp senkronize olduğu.~~ Oluyor, ama yalnız BandProbe kanalı bıraktıktan sonra (bölüm 5.4).
- `FE95/0050` karakteristiğinin ve `1B7E8251-…` servisinin işlevi.
- `180D` nabız bildiriminin auth olmadan akıp akmadığı.
- iOS bildirimlerinin (ANCS) Mi Fitness olmadan da çalışıp çalışmadığı; ANCS sistem düzeyinde olduğu için büyük olasılıkla çalışır. [TAHMİN]
- Saat/saat dilimi, kullanıcı bilgisi ve hava durumu gibi telefonun düzenli göndermesi gereken verilerin eksikliğinde bilekliğin davranışı. [TAHMİN]
