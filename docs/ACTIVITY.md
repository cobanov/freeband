# Aktivite geçmişi: bileklik kayıtlı veriyi nasıl teslim ediyor

Xiaomi Smart Band 10 / 10 Pro (BLE V2 / SPP V2 paket katmanı) için, Freeband'in Swift tarafında uygulanacak aktivite dosyası akışının bayt düzeyinde tarifi. Kaynak: `vendor/Gadgetbridge`, commit `d4bd8367`. Arka plan için `findings.md` bölüm 4–6.

Referans uygulama ve test vektörleri: `ios/tests/activity/activity_ref.py` ve `ios/tests/activity/fixtures/` (bölüm 11).

## 0. Kısaltmalar ve etiketler

| Kısaltma | Yol |
|---|---|
| `X/` | `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/` |
| `P/` | `GBProtobufGenerator/src/main/proto/` |
| `XD/` | `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/devices/xiaomi/` |
| `GB/` | `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/` |
| `T/` | `app/src/test/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/activity/` |

- **[KOD]**: Gadgetbridge kaynağında doğrudan görülen davranış, `dosya:satır` ile.
- **[TEST]**: Gadgetbridge test dosyasında assert edilen değer.
- **[TAHMİN]**: Kaynaktan çıkarım; kodda açıkça yazmıyor.
- **[ÖNERİ]**: Freeband için tasarım tavsiyesi; Gadgetbridge'in yaptığı şey değil.
- **[ÖLÇÜM]**: Freeband'in gerçek bir cihazda gözlediği davranış.

Bütün çok baytlı alanlar aksi yazılmadıkça **little-endian**. Tek istisna, uyku detay dosyasındaki evre paketlerinin uzunluk alanı ve içerikleri (bölüm 6.3.3): onlar **big-endian**.

## 1. Kısa akış

```
telefon (kanal 1, protobuf, şifreli)                bileklik
  Command{8,1, health.activitySyncRequestToday{0}} →
                                                   ← Command{8,1, health.activityRequestFileIds = N×7 bayt}
  Command{8,2}                                     →
                                                   ← Command{8,2, health.activityRequestFileIds = M×7 bayt}
  her dosya için, sırayla, bir seferde bir tane:
  Command{8,3, health.activityRequestFileIds = 7 baytlık id} →
                                                   ← kanal 5 (Activity) veri paketleri:
                                                     [total u16][num u16][parça]  ×total
                                                     birleşik dosya = id(7) | pad(1) | gövde | CRC32(4)
  (Gadgetbridge burada Command{8,5} ile ACK atar ve dosya bileklikten silinir. Freeband ATMAYACAK.)
```

- Liste istekleri ve dosya isteği protobuf kanalında (kanal 1) gider; dosyanın kendisi protobuf değildir, **kanal 5** üzerinden ikili parçalar hâlinde gelir. [KOD] `X/XiaomiBleProtocolV2.java:58-60`, `X/services/XiaomiHealthService.java:907-955`
- Bileklik "bitti" diye ayrı bir mesaj göndermez. Bir dosyanın bittiği, `num == total` olan parçadan anlaşılır; bütün senkronun bittiği, kuyruğun boşalmasından anlaşılır. [KOD] `X/activity/XiaomiActivityFileFetcher.java:106-109`, `:222-236`

## 2. İstek akışı

### 2.1 Zarf ve alan numaraları

Her mesaj `Command` zarfında. Alanlar: `type = 1` (uint32, zorunlu), `subtype = 2`, `health = 10` (`Health` mesajı), `status = 100`. [KOD] `P/xiaomi.proto:22-24`, `:30`, `:44`

Sağlık komutlarının `type` değeri 8. [KOD] `X/services/XiaomiHealthService.java:91`

Aktiviteyle ilgili `Health` alanları [KOD] `P/xiaomi/wear_fitness.proto:7-14`, `:65-67`:

| Alan | No | Tür | Kullanım |
|---|---|---|---|
| `activityRequestFileIds` | 2 | bytes | subtype 1/2 cevabında N×7 baytlık liste; subtype 3 isteğinde tek 7 baytlık id |
| `activitySyncAckFileIds` | 3 | bytes | subtype 5 (ACK) isteğinde 7 baytlık id |
| `activitySyncRequestToday` | 5 | `ActivitySyncRequestToday` | subtype 1 isteği |
| `ActivitySyncRequestToday.unknown1` | 1 | uint32 | Gadgetbridge `0` gönderir |

Subtype sabitleri: `CMD_ACTIVITY_FETCH_TODAY = 1`, `CMD_ACTIVITY_FETCH_PAST = 2`, `CMD_ACTIVITY_FETCH_REQUEST = 3`, `CMD_ACTIVITY_FETCH_ACK = 5`. [KOD] `X/services/XiaomiHealthService.java:93-97`

Proto2 kullanıldığı için açıkça set edilmiş `0` değeri de kabloya yazılır (`unknown1 = 0` gerçekten `08 00` olarak gider). [KOD] `P/xiaomi.proto:1`

### 2.2 Dört istek, bayt bayt

Aşağıdaki baytlar şifrelemeden önceki protobuf gövdesi. Örnek id: `00 F1 53 65 04 00 01` (bölüm 3). Hesap: `activity_ref.py` ile aynı kurala göre elle kodlandı.

| Subtype | Anlam | Protobuf | Bayt (hex) | Kaynak |
|---|---|---|---|---|
| 1 | bugünün dosya listesi | `Command{type:8, subtype:1, health{activitySyncRequestToday{unknown1:0}}}` | `08 08 10 01 52 04 2A 02 08 00` | [KOD] `X/services/XiaomiHealthService.java:907-919` |
| 2 | geçmiş dosya listesi | `Command{type:8, subtype:2}` (health yok) | `08 08 10 02` | [KOD] `:921-929` |
| 3 | tek dosya iste | `Command{type:8, subtype:3, health{activityRequestFileIds: id}}` | `08 08 10 03 52 09 12 07 <id 7 bayt>` | [KOD] `:931-942` |
| 5 | ACK, dosyayı sil | `Command{type:8, subtype:5, health{activitySyncAckFileIds: id}}` | `08 08 10 05 52 09 1A 07 <id 7 bayt>` | [KOD] `:944-955` |

- `ActivitySyncRequestToday.unknown1`: Gadgetbridge yorumu "official app sends 0, but sometimes 1?" [KOD] `X/services/XiaomiHealthService.java:914-915`; proto yorumu bunu "0=normal sync, 1=force/full sync" olabilir diye tahmin ediyor. [KOD] `P/xiaomi/wear_fitness.proto:66`. Anlamı doğrulanmamış; Freeband `0` göndermeli. [ÖNERİ]
- **Subtype 5 gönderilmeyecek.** Gadgetbridge her dosyayı CRC doğrulandıktan hemen sonra, parse etmeden önce ACK'liyor, yeter ki `keep_activity_data_on_device` kapalı olsun (varsayılan kapalı). [KOD] `X/activity/XiaomiActivityFileFetcher.java:147-151`, `X/XiaomiPreferences.java:93-96`. Ayarın açıklaması: "Do not mark activities as synced on the device. Useful if Gadgetbridge is used together with other apps. This may cause the watch to run out of space and/or stop syncing properly." [KOD] `app/src/main/res/values/strings.xml:1276-1277`

### 2.3 Cevaplar

- Subtype 1 ve 2'ye bileklik aynı subtype ile `Command{8, 1|2, health{activityRequestFileIds}}` döner. Örnek iki id'li cevap: `08 08 10 01 52 10 12 0E <id1> <id2>`. [KOD] `X/services/XiaomiHealthService.java:187-190`
- Liste uzunluğu 7'nin katı değilse Gadgetbridge listeyi tamamen atar. [KOD] `:958-961`
- `ts == 0 && version == 0` olan id'ler (yer tutucu) atlanır. [KOD] `:971-974`, [TEST] `T/XiaomiActivityFileIdTest.java:85-89`
- Liste boş olabilir (`health` alanı yok ya da `activityRequestFileIds` boş). Gadgetbridge bunu 0 id olarak işler. [KOD] `:957-981` (protobuf'ın boş varsayılanı) [TAHMİN: boş listenin gerçek kablo biçimi]
- Subtype 3 ve 5 için protobuf cevabı beklenmiyor: `handleCommand` içinde 3 ve 5 için `case` yok; gelirse "Unknown health command" log'u düşer. [KOD] `X/services/XiaomiHealthService.java:183-253`. Bileklik gerçekten bir şey dönüyor mu, kaynaktan anlaşılmıyor. [TAHMİN] Swift tarafı beklenmeyen `{8,3}` / `{8,5}` mesajlarını sessizce yok saymalı. [ÖNERİ]

### 2.4 Dosya içeriği: kanal 5 ve şifreleme

- Veri paketi gövdesi: `channel (alt 4 bit) | opcode (u8) | payload`. Kanal sabitleri: `CHANNEL_PROTOBUF = 1`, `CHANNEL_DATA = 2`, `CHANNEL_ACTIVITY = 5` ("encrypted" yorumu ile). Opcode: `1` düz, `2` şifreli. [KOD] `X/XiaomiSppPacketV2.java:283-290`, `:376-394`
- Telefon tarafından gönderimde `Activity` kanalı `OPCODE_SEND_ENCRYPTED` alır. [KOD] `X/XiaomiSppPacketV2.java:362-374`
- **Alımda çözme, paketin kendi opcode'una göre yapılır**: opcode 2 ise `decryptV2`, değilse ham gövde. Bu, protobuf kanalıyla aynı fonksiyon: AES-128-CTR, anahtar = IV = `decryptionKey`, sayaç her pakette baştan. [KOD] `X/XiaomiSppPacketV2.java:409-415`, `X/XiaomiAuthService.java:385-402`. Yani evet, kanal 5 de protobuf'la **aynı AES-CTR** ile şifreli; her kanal-5 veri paketi bağımsız çözülür.
- Çözülen her kanal-5 paketinin gövdesi **tam olarak bir parçadır** (bölüm 4); doğrudan `XiaomiActivityFileFetcher.addChunk`'a verilir. [KOD] `X/XiaomiBleProtocolV2.java:60`, `:178-185`, `:321-327`
- Taşıma katmanı ACK'i (çerçeve tipi 1) kanal ayırt etmeden her gelen veri paketine gönderilir; bu, dosya silen subtype-5 ACK'iyle **aynı şey değil** ve gönderilmesi gerekir. [KOD] `X/XiaomiBleProtocolV2.java:328-329`. Freeband bunu zaten yapıyor: `ios/Freeband/Band/BandLink.swift:340-342`.
- Freeband şu an kanal 1 dışındaki paketleri atıyor (`guard channel == 1`), `ios/Freeband/Band/BandLink.swift:351-362`. Kanal 5 için ayrı bir dal gerekiyor; çözme kısmı (`opcode == 2` → `MiCrypto.ctr`) aynen kullanılabilir.
- Gadgetbridge Band 10 / 10 Pro'yu SPP V2 (BT Classic) üzerinden konuşturuyor [KOD] `XD/watches/MiBand10Coordinator.java:46-49`, `XD/watches/MiBand10ProCoordinator.java:45-48`. BLE V2 yolu da aynı `XiaomiSppPacketV2` paket sınıfını kullandığından [KOD] `X/XiaomiBleProtocolV2.java:313`, çerçevenin üstündeki akış (kanal 5, opcode, parça formatı) iki taşımada aynı. Freeband'in BLE V2 üzerinde auth ve şifreli protobuf'u bu bileklikte zaten çalışıyor (findings bölüm 6.1).

### 2.5 Sıralama, zamanlama, tamamlanma

Gadgetbridge'in yaptığı [KOD]:

1. `onFetchRecordedData` → subtype 1 gönder. `X/services/XiaomiHealthService.java:901-905`
2. Subtype 1 cevabı gelince: id'leri kuyruğa ekle, "geçmiş cevabı bekleniyor" bayrağını kaldır, kuyruğu hemen işlemeye başla ve **aynı anda** subtype 2'yi gönder. `:977-985`
3. Subtype 2 cevabı gelince: id'leri kuyruğa ekle, bayrağı indir, kuyruk boşaldıysa beklemedeki işi sürdür. `:986-989`, `X/activity/XiaomiActivityFileFetcher.java:194-198`
4. Kuyruk bir `PriorityQueue`; aynı id iki kez eklenmez. `X/activity/XiaomiActivityFileFetcher.java:60`, `:200-208`. Sıralama `compareTo`: zaman damgası, timezone, type, subtype, detay tipinin getirme sırası (SUMMARY 0, DETAILS 1, GPS_TRACK 2, diğer 3), version. `X/activity/XiaomiActivityFileId.java:143-153`, `:323-332`. Özet önce gelir ki antrenman detayı/GPS parse edilirken özet hazır olsun (`:324-325`).
5. **Bir seferde tek dosya**: kuyruğun başını al, subtype 3 gönder, 5 sn zaman aşımı kur. `X/activity/XiaomiActivityFileFetcher.java:222-243`
6. Her parça geldiğinde zaman aşımı silinir; son parça değilse yeniden 5 sn kurulur. `:91-109`, `:82-89`
7. Son parça (`num == total`) gelince: uzunluk ≥ 13 ve CRC kontrolü, ham baytı diske yaz, (ACK), parser'ı çalıştır, sıradakini iste. Hata olursa da (kısa dosya, CRC hatası, parser yok, parse istisnası) sıradakine geçer. `:111-174`
8. Zaman aşımında tamponu atıp sıradakine geçer; tekrar denemez. `:84-88`
9. Kuyruk boş ve geçmiş cevabı beklenmiyorsa senkron biter. `:228-236`, `:181-192`

Freeband için [ÖNERİ]:

- Gadgetbridge'in 2. adımdaki paralelliği (dosya aktarımı sürerken subtype 2 göndermek) gereksiz risk. Önce subtype 1, cevap; sonra subtype 2, cevap; sonra listeyi birleştir, tekilleştir, sırala ve dosyaları tek tek iste.
- 5 sn zaman aşımını koru, ama bir kez yeniden dene; ikinci zaman aşımında o dosyayı bu senkron için atla.
- Bileklik "gönderecek bir şey kalmadı" demediği için ilerleme göstergesi, istenen id sayısı üzerinden hesaplanmalı.

### 2.6 ACK atmamanın sonuçları

- Dosyalar bileklikte kalır; her senkronda aynı id'ler yine listelenir. Daha önce alınmış ve CRC'si doğru saklanmış id'ler için subtype 3'ü tekrar göndermemek gerekir. [TAHMİN, ACK'in silme anlamından çıkarım; `strings.xml:1276-1277`]
- "Bugün" listesindeki günlük detay dosyası gün içinde büyüyor olabilir: id aynı kalıp içerik uzayabilir. Bugünün listesindeki dosyalar her senkronda yeniden çekilmeli ve eski kopyanın yerine yazılmalı. [TAHMİN; Gadgetbridge her seferinde ACK'leyip sildiği için bu durumu hiç görmüyor]
- Mi Fitness aynı dosyaları ACK'leyip silebilir; Freeband'in listesi ile isteği arasında dosya kaybolursa istek zaman aşımına düşer. Bu normal akış sayılmalı. [TAHMİN]
- Bileklik dolarsa senkron bozulabilir (Gadgetbridge uyarısı). Mi Fitness'ın periyodik çalışması bu riski azaltır. [KOD] `strings.xml:1277`, [TAHMİN]
- **Redmi Watch 5 Active (firmware 2.2.105):** ACK'lenmemiş dosyaların hepsi "bugün" listesinde geliyor; geçmiş listesi boş. Saat istekleri geç ve sırasız cevaplayabiliyor: bir dosyanın içeriği, sonra istenen başka bir dosya beklenirken geliyor. Saat bazen bir bağlantıda dosya isteklerine hiç cevap vermiyor. [ÖLÇÜM] Bu yüzden dosya, beklenen id'ye göre değil içeriğin ilk 7 baytındaki id'ye göre saklanır; Gadgetbridge de id'yi içerikten okuyor [KOD] `X/activity/XiaomiActivityFileFetcher.java:142`. Cevap gelmeyen dosya bir kez daha istenir, yine gelmezse atlanır ve kalan dosyalar için yeni bağlantı açılır. [ÖNERİ]

## 3. Dosya kimliği (7 bayt)

[KOD] `X/activity/XiaomiActivityFileId.java:92-101` (yazma), `:109-124` (okuma)

| Bayt | Alan | Tür | Not |
|---|---|---|---|
| 0–3 | `ts` | u32 LE | Unix saniye, UTC (bölüm 7). Java `int` olarak okunuyor; Swift `UInt32` kullanmalı. |
| 4 | `tz` | i8 | 15 dakikalık bloklar ("15 min blocks", `:111`); işaretli: `0xF4` = −12 = UTC−3 |
| 5 | `version` | u8 | Dosya biçiminin sürümü; parser seçimini belirler |
| 6 | `flags` | u8 | `type << 7 \| subtype << 2 \| detailType` |

`flags` ayrıştırma [KOD] `:113-121`:

- `type = (flags >> 7) & 1`
- `subtype = (flags & 0x7F) >> 2` (5 bit, 0–31)
- `detailType = flags & 0x03`

Test vektörleri [TEST] `T/XiaomiActivityFileIdTest.java:49-60`, `:62-83`:

- `21F328650403A0` → ts 1697182497, tz 4, version 3, SPORTS, FREESTYLE (8), DETAILS
- `21F3286504008C` → ts 1697182497, tz 4, version 0, SPORTS, subtype 3, DETAILS; tekrar kodlayınca aynı bayt
- `00000000000000` → yer tutucu (`ts == 0 && version == 0`)

Not: `testEncode` (`:34-47`) yapıcıya aralık dışı değerler veriyor (type 3, detailType 8) ve maskelemeyen `toBytes` tesadüfen `8C` üretiyor. Swift kodlayıcısı alanları maskelemeli (`type & 1`, `subtype & 0x1F`, `detail & 3`); o testin girdisi taklit edilmemeli.

### 3.1 Sabitler

`Type` [KOD] `X/activity/XiaomiActivityFileId.java:237-241`:

| Kod | Ad |
|---|---|
| 0 | `ACTIVITY` |
| 1 | `SPORTS` |

`Subtype` [KOD] `:263-282` (ACTIVITY için anlam; SPORTS için antrenman türü, yorum `:116-118`):

| Type | Kod | Ad | Parser |
|---|---|---|---|
| ACTIVITY | 0x00 | `ACTIVITY_DAILY` | DETAILS → `DailyDetailsParser`, SUMMARY → `DailySummaryParser` |
| ACTIVITY | 0x03 | `ACTIVITY_SLEEP_STAGES` | DETAILS → `SleepStagesParser` |
| ACTIVITY | 0x06 | `ACTIVITY_MANUAL_SAMPLES` | DETAILS → `ManualSamplesParser` |
| ACTIVITY | 0x08 | `ACTIVITY_SLEEP` | **her detay tipi** → `SleepDetailsParser` |
| SPORTS | 0x01 | `SPORTS_OUTDOOR_RUNNING` | antrenman parser'ları |
| SPORTS | 0x02 | `SPORTS_OUTDOOR_WALKING_V1` | 〃 |
| SPORTS | 0x03 | `SPORTS_TREADMILL` | 〃 |
| SPORTS | 0x06 | `SPORTS_OUTDOOR_CYCLING_V2` | 〃 |
| SPORTS | 0x07 | `SPORTS_INDOOR_CYCLING` | 〃 |
| SPORTS | 0x08 | `SPORTS_FREESTYLE` | 〃 |
| SPORTS | 0x09 | `SPORTS_POOL_SWIMMING` | 〃 |
| SPORTS | 0x0B | `SPORTS_ELLIPTICAL` | 〃 |
| SPORTS | 0x0D | `SPORTS_ROWING` | 〃 |
| SPORTS | 0x0E | `SPORTS_JUMP_ROPING` | 〃 |
| SPORTS | 0x10 | `SPORTS_HIIT` | 〃 |
| SPORTS | 0x16 | `SPORTS_OUTDOOR_WALKING_V2` | 〃 (Band 9 Active koşuyu da bununla yazıyor, [TEST] `T/impl/WorkoutSummaryParserTest.java:299-301`) |
| SPORTS | 0x17 | `SPORTS_OUTDOOR_CYCLING` | 〃 |

Parser seçimi [KOD] `X/activity/XiaomiActivityParser.java:83-137`. SPORTS dosyaları detay tipine göre: SUMMARY → `WorkoutSummaryParser`, GPS_TRACK → `WorkoutGpsParser`, DETAILS → `WorkoutDetailsParser`.

`DetailType` [KOD] `:306-311`:

| Kod | Ad | Getirme sırası (`:323-332`) |
|---|---|---|
| 0 | `DETAILS` | 1 |
| 1 | `SUMMARY` | 0 |
| 2 | `GPS_TRACK` | 2 |
| 3 | (tanımsız) | 3 |

## 4. Parça birleştirme ve CRC

### 4.1 Parça başlığı

Her çözülmüş kanal-5 paketi [KOD] `X/activity/XiaomiActivityFileFetcher.java:91-109`:

| Bayt | Alan | Tür |
|---|---|---|
| 0–1 | `total` | u16 LE: dosyanın toplam parça sayısı |
| 2–3 | `num` | u16 LE: bu parçanın sırası, **1'den başlar** |
| 4– | veri | dosyanın sıradaki kesiti |

u16 okuması little-endian: [KOD] `GB/service/btle/BLETypeConversions.java:209-211`

Kurallar [KOD]:

- `num == 1` tamponu sıfırlar (`:97-100`).
- Veri, başlık atılarak tampona eklenir (`:104`).
- `num == total` dosyayı kapatır (`:106-112`).
- Gadgetbridge sıra atlamayı, tekrarı ya da `total` değişimini **kontrol etmiyor**. [KOD] `:91-112`. Freeband bunları hata saymalı: beklenen `num` gelmezse tamponu at, dosyayı başarısız say. [ÖNERİ; referans parser bunu yapıyor]
- Parça boyutu hakkında kaynakta sabit yok. Çerçevenin üst sınırı SessionConfig'teki `0xFC00` [KOD, findings 4.2]; parçalar BLE bildirimlerine bölünüp çerçeve katmanında birleşiyor, yani parça = bir çerçeve. [KOD] `X/XiaomiBleProtocolV2.java:111-176`

### 4.2 Birleşik dosya ve CRC

```
0      7     8                      n-4      n
| id(7) | pad | gövde (tipe özgü)    | crc32 LE |
```

- Minimum uzunluk 13 bayt (7 + 1 + en az 1 + 4); daha kısası atılır. [KOD] `X/activity/XiaomiActivityFileFetcher.java:114-119`
- CRC, **son 4 bayt hariç bütün dosya** üzerinden (id ve pad dahil) hesaplanır ve son 4 bayttaki u32 LE değerle karşılaştırılır. [KOD] `:121-133`, `GB/service/btle/BLETypeConversions.java:229-231`
- Algoritma `java.util.zip.CRC32`, yani standart CRC-32 (ISO-HDLC / IEEE 802.3 / zlib): polinom `0x04C11DB7`, yansıtılmış hâli `0xEDB88320`, başlangıç `0xFFFFFFFF`, giriş ve çıkış yansıtılmış, son XOR `0xFFFFFFFF`. Kontrol değeri: `"123456789"` → `CBF43926`. [KOD] `GB/util/CheckSums.java:36`, `:105-109`
- 13 gerçek antrenman dosyası ve 3 gerçek manuel ölçüm paketi bu tanımla doğrulandı (bölüm 11). [TEST]
- `data[7]` (pad) 0 değilse Gadgetbridge yalnızca uyarır, parse etmeye devam eder. [KOD] `:135-140`
- Dosyanın ilk 7 baytı id'dir; Gadgetbridge parser'ı bu baytlardan seçer, istenen id ile karşılaştırmaz. [KOD] `:142-153`. Freeband gelen id'yi istenen id ile karşılaştırmalı; farklıysa dosyayı yine sakla ama uyar. [ÖNERİ]
- `fixAndWrap` ve 13 baytlık GPS "placeholder" mantığı Gadgetbridge'in kendi eski disk kayıtları ve iç mekân antrenmanları için; kablodaki biçimle ilgisi yok. [KOD] `X/activity/XiaomiActivityParser.java:143-171`, `X/activity/XiaomiActivityFileFetcher.java:163-166`

## 5. Ortak gövde araçları

Gövde, pad'den sonra başlar (dosyada ofset 8). Aşağıdaki "gövde ofseti" hep bu noktaya göredir.

### 5.1 Geçerlilik bitmap'i (MSB önce)

`validData(header, i)`: `i`. alan, `header[i / 8]` baytının `7 − (i % 8)` numaralı bitiyle geçerli sayılır. Yani alan 0 ilk baytın en yüksek biti. [KOD] `X/activity/XiaomiActivityParser.java:139-141`, [TEST] `T/impl/DailySummaryParserTest.java:204-229`. `DailySummary` ve `SleepDetails` bunu kullanır.

### 5.2 Nibble grupları (yalnız `DailyDetails`)

[KOD] `X/activity/impl/XiaomiComplexActivityParser.java:49-115`

- Dosya başında bir kez okunan başlıkta **her grup için bir nibble** var. Grup `g`'nin nibble'ı `header[g / 2]` baytının, `g` çiftse üst 4 biti, tekse alt 4 biti. (`:83-90`)
- Nibble bitleri: `0x8` grup kayıtta **var**; `0x4` slot 0 geçerli; `0x2` slot 1 geçerli; `0x1` slot 2 geçerli. (`:59-67`, `:104-110`)
- Grup yoksa kayıtta **hiç bayt kaplamaz**. Varsa genişliği kadar (8 / 16 / 32 bit) little-endian okunur, değeri geçersiz olsa bile. (`:59-66`, `:70-81`)
- Grup değeri içinden alan çıkarma: `get(start, n)`, `start` **en yüksek bitten** sayılır: `(value >> (width − start − n)) & ((1 << n) − 1)`. (`:112-115`)
- Başlık bütün kayıtlar için ortak; kayıt boyu bu yüzden çoğunlukla sabit, ama bölüm 6.1'deki "ek bayt" bayrağı kayda göre değişebilir.

## 6. Dosya türleri

Bütün parser'lar `XiaomiActivityFileId.version`'a göre dallanır. Desteklenmeyen sürüm → Gadgetbridge dosyayı parse etmez (ham kopya diske yazılmış kalır). [KOD] `X/activity/XiaomiActivityFileFetcher.java:145`

### 6.1 Günlük detay (ACTIVITY / DAILY 0x00 / DETAILS) — dakikalık adım, nabız, stres, SpO2, kalori, mesafe

[KOD] `X/activity/impl/DailyDetailsParser.java:50-178`

Başlık boyu (`:51-67`):

| Sürüm | Başlık (bayt) | Nibble | Kullanılan grup |
|---|---|---|---|
| 1, 2 | 4 | 8 | 0–6 |
| 3 | 5 | 10 | 0–8 |
| 4 | 6 | 12 | 0–10 |

Düzen: gövde = `başlık | kayıt*`; CRC hariç tutulur (`:70`). Kayıtlar gövde bitene kadar okunur (`:88`).

Kayıt (her biri bir dakika) — grupları sırayla, yalnız nibble'ında `0x8` olanlar okunur (`:98-173`):

| Grup | Genişlik | Sürüm | İçerik | Geçerlilik | Birim |
|---|---|---|---|---|---|
| g0 | 16 | ≥1 | bit 15: bilinmiyor; bit 14: **ek bayt bayrağı**; bit 13–0: **adım** | slot 1 → bayrak, slot 2 → adım | adım/dakika (en fazla 16383) |
| g1 | 8 | ≥1 | bit 7–6: bilinmiyor ("activity type?"); bit 5–0: **aktif kalori** | slot 1 | [TAHMİN] kcal/dakika |
| g2 | 8 | ≥1 | bilinmiyor | — | — |
| g3 | 16 | ≥1 | **mesafe** (tüm 16 bit) | slot 0 | metre (Gadgetbridge ×100 ile cm saklar, `:122`) |
| g4 | 8 | ≥1 | **nabız** | slot 0 | bpm |
| g5 | 8 | ≥1 | **energy** (body energy) | slot 0 | [TAHMİN] 0–100 |
| g6 | 16 | ≥1 | bilinmiyor | — | — |
| g7 | 8 | ≥3 | **SpO2** | slot 0 | % |
| g8 | 8 | ≥3 | **stres**; `255` = değer yok (`:155`) | slot 0 | 0–100 |
| ek | 8 | ≥1 | g0'daki bayrak 1 ise **tam bu noktada** 1 bayt; anlamı bilinmiyor (`:162-165`) | — | — |
| g9 | 16 | ≥4 | "light value" (Gadgetbridge parse etmiyor, `:167-169`) | [TAHMİN] slot 0 | bilinmiyor |
| g10 | 16 | ≥4 | "body momentum" (Gadgetbridge parse etmiyor, `:171-172`) | [TAHMİN] slot 0 | bilinmiyor |

- Ek bayt **v1/v2'de g6'dan sonra, v3/v4'te g8'den sonra ve g9'dan önce** gelir. Bayrak yalnız g0 varsa ve slot 1 geçerliyse okunur; yoksa 0 sayılır. (`:97-103`, `:162-165`)
- Tüm gruplar varken kayıt boyu: v1/v2 10, v3 12, v4 16 bayt; ek bayt varsa +1.
- Zaman: kayıt `i`'nin zamanı `fileId.ts + 60·i` saniye. (`:84-85`, `:92`, `:177`)
- Geçersiz alan Gadgetbridge'de `NOT_MEASURED` (−1) ya da null kalır (`:93-95`).
- Değer filtreleri (okumada, parse'ta değil): nabız grafikte 10–250 arası geçerli [KOD] `GB/activities/HeartRateUtils.java:24-25`, `:66-68`; SpO2 ve stres `0` ise yok sayılır [KOD] `XD/XiaomiSpo2SampleProvider.java:62`, `XD/XiaomiStressSampleProvider.java:62`; energy `<= 0` yok sayılır [KOD] `XD/XiaomiBodyEnergySampleProvider.java:36`.
- Aktif kalori okunurken ×1000 ile çarpılıyor, yani ham değer kcal, gösterilen birim cal. [KOD] `XD/XiaomiSampleProvider.java:116-120`, birim [TAHMİN]
- Gövde ortasında bir kayıt yarım kalırsa Gadgetbridge'de `BufferUnderflowException` olur ve dosyanın hiçbir kaydı kaydedilmez (`addChunk`'taki `catch`, `X/activity/XiaomiActivityFileFetcher.java:170-172`). Freeband tam kayıtları tutup kalan baytı raporlamalı. [ÖNERİ]

### 6.2 Günlük özet (ACTIVITY / DAILY 0x00 / SUMMARY)

[KOD] `X/activity/impl/DailySummaryParser.java:55-96` (slot tablosu), `:147-185` (decode)

| Sürüm | Bitmap (bayt) | Slot sayısı | Gövde boyu (bitmap hariç) | Cihaz notu (`:152-157`) |
|---|---|---|---|---|
| 3 | 3 | 21 (0–20) | 41 | "Smart Band 8 Active" |
| 4 | 3 | 21 (0–20) | 41 | "Mi Band 9 Active" |
| 5 | 4 | 32 (0–31) | 57 | "Mi Band 10 and later" |

**Gerçek Band 10 Pro (2026-10-14) [GERÇEK]:** iki v5 dosyası da gövdede bitmap'ten sonra **53 bayt** taşıyor, yani slot 29'da bitiyor; bitmap'te 30 ve 31 bitleri de kapalı. Gadgetbridge sabit 32 slot okuyor ve bu dosyada taşardı. Freeband: slot 21'den (v3/v4 kümesinin sonu) sonra gövde bir slot sınırında biterse kalan slotlar `nil`, hata yok.

Düzen: gövde = `bitmap | slot0 | slot1 | …`. **Her slot, bit'i kapalı olsa da boyu kadar tüketilir**; bit yalnız değerin kullanılıp kullanılmayacağını söyler (`:48-54`, `:182-184`). Bitmap bölüm 5.1'deki MSB-önce kural. Dosyada bir kayıt var; zamanı `fileId.ts`, timezone `fileId.tz` olarak saklanır (`:178-180`).

| Slot | Gövde ofseti* | Boy | Alan | Birim / not |
|---|---|---|---|---|
| 0 | 0 | 4 | `steps` | adım |
| 1 | 4 | 2 | `activeCalories` | [TAHMİN] kcal |
| 2 | 6 | 1 | ayrılmış | — |
| 3 | 7 | 1 | `hrResting` | bpm |
| 4 | 8 | 1 | `hrMax` | bpm |
| 5 | 9 | 4 | `hrMaxTs` | [TAHMİN] Unix saniye |
| 6 | 13 | 1 | `hrMin` | bpm |
| 7 | 14 | 4 | `hrMinTs` | [TAHMİN] Unix saniye |
| 8 | 18 | 1 | `hrAvg` | bpm |
| 9 | 19 | 1 | `stressAvg` | 0–100 |
| 10 | 20 | 1 | `stressMax` | 〃 |
| 11 | 21 | 1 | `stressMin` | 〃 |
| 12 | 22 | 3 | `standing` | 24 bitlik LE bitmap: bit `h` = saat `h`–`h+1` arası ayakta (`:71-75`) |
| 13 | 25 | 2 | `calories` | [TAHMİN] kcal |
| 14 | 27 | 2 | `recoveryHours` | saat |
| 15 | 29 | 1 | ayrılmış | — |
| 16 | 30 | 1 | `spo2Max` | % |
| 17 | 31 | 4 | `spo2MaxTs` | [TAHMİN] Unix saniye |
| 18 | 35 | 1 | `spo2Min` | % |
| 19 | 36 | 4 | `spo2MinTs` | [TAHMİN] Unix saniye |
| 20 | 40 | 1 | `spo2Avg` | % |
| 21 | 41 | 2 | `trainingLoadDay` | v5 |
| 22 | 43 | 2 | `trainingLoadWeek` | v5 |
| 23 | 45 | 1 | `trainingLoadLevel` | v5 |
| 24 | 46 | 1 | `vitalityIncreaseLight` | v5 |
| 25 | 47 | 1 | `vitalityIncreaseModerate` | v5 |
| 26 | 48 | 1 | `vitalityIncreaseHigh` | v5 |
| 27 | 49 | 2 | `vitalityCurrent` | v5 |
| 28 | 51 | 1 | ayrılmış | v5 |
| 29 | 52 | 1 | ayrılmış | v5 |
| 30 | 53 | 2 | ayrılmış | v5 |
| 31 | 55 | 2 | ayrılmış | v5 |

\* Gövde ofseti bitmap'ten sonrasına göre. Dosyada mutlak ofset = 8 + bitmap boyu + gövde ofseti. Slot 27 ofseti 49 ve standing ofseti 22, Gadgetbridge testindeki hesapla aynı [TEST] `T/impl/DailySummaryParserTest.java:240`, `:258`.

Tüm alanlar işaretsiz. Gadgetbridge `steps` ve zaman damgalarını Java `int` (işaretli) okuyor; Swift `UInt32` kullanmalı. Gadgetbridge bu parser'da CRC'yi gövdeden düşmüyor, sadece sabit sayıda slot okuyor (`:166-184`).

### 6.3 Uyku detayı (ACTIVITY / SLEEP 0x08 / her detay tipi)

[KOD] `X/activity/impl/SleepDetailsParser.java:52-301`. Yorum: "Seems to come both as DetailType.DETAILS (version 2) and DetailType.SUMMARY (version 4, 5)" (`:53`).

#### 6.3.1 Sabit kısım

Bitmap boyu: v1–v4 1 bayt, v5 2 bayt (`:55-69`). Bitmap indeksi (`headerIdx`) yalnız sürümde var olan alanlar için ilerler (`:71-72`).

| Sıra | Alan | Tür | Bitmap indeksi (v1-2 / v3 / v4 / v5) | Okuma koşulu |
|---|---|---|---|---|
| 1 | `isAwake` | u8 (0/1) | 0 | **her zaman** okunur (`:84-85`) |
| 2 | `bedTime` | u32 | 1 | her zaman (`:87-88`) |
| 3 | `wakeupTime` | u32 | 2 | her zaman (`:90-91`) |
| 4 | `sleepQuality` | u8 | — / — / 3 / 3 | v≥4 ve bit açıksa; **bit kapalıysa bayt yok** (`:93-99`) |
| 5 | bilinmeyen | 9 bayt | — / — / — / (4–8 arası) | v5, her zaman (`:123-124`) |
| 6 | `bedTime2` | u32 | 〃 | v5, her zaman; "around ~30 min before bedTime" (`:125`) |
| 7 | `wakeupTime2` | u32 | 〃 | v5, her zaman; "== wakeupTime" (`:126`) |
| 8 | nabız örnekleri | blok | 3 / 3 / 4 / 9 | bit açıksa (`:130-147`) |
| 9 | SpO2 örnekleri | blok | 4 / 4 / 5 / 10 | bit açıksa (`:149-166`) |
| 10 | horlama örnekleri | blok | — / 5 / 6 / 11 | v≥3 ve bit açıksa (`:168-187`) |
| 11 | evre paketleri | akış | — | gövde sonuna kadar (`:196-301`) |

v5'te bilinmeyen 9 bayt + iki u32 için indeks 5 ilerler (`:127`).

**Sürüm 6 [GERÇEK, tek dosya: Band 10 Pro, 2026-10-14; Gadgetbridge'de yok]:**

- Bitmap **3 bayt** (`DF FF FC`: 0–21 arası bitler, 2 hariç, açık). `wakeupTime` bit 2 kapalıyken de dolu geldi; v5'teki gibi her zaman okunur.
- `isAwake`, `bedTime`, `wakeupTime`, `sleepQuality`, 9 bilinmeyen bayt, `bedTime2`, `wakeupTime2`: v5 ile aynı yerde ve aynı anlamda. 9 baytın düzeni `u8 | u32 | u32` gibi duruyor: u32'ler `bedTime − bedTime2` ve `wakeupTime − bedTime2` saniyesine eşit çıktı. [TAHMİN]
- Ardından **24 bilinmeyen bayt** (u16/u32 karışık küçük sayılar ve bir zaman damgası). Ham saklanıyor (`v6_unknown_hex`).
- Sonra v5'teki sırayla nabız, SpO2 ve horlama blokları. Gerçek dosyada nabız ve SpO2 60 sn aralıklı, "ölçüm yok" örnekleri **0**; horlama 600 sn aralıklı ve örnekler **u16** (v3–v5'te float32). Üçünden sonra akış tam olarak ilk sihirli değerde başlıyor.
- Yeni alanların bitmap indeksleri bilinmiyor; bloklar v5 indeksleriyle (9, 10, 11) okunuyor. Freeband ve referans parser bunu doğruluyor: bloklar bittiğinde sıradaki 4 bayt sihirli değer değilse (ya da blok taşarsa) üç blok da atılıyor (`blocks_error`), akış blokların başından taranıyor. Böylece evreler kaybolmuyor. [ÖNERİ]

Örnek bloğu (`:133-145`, `:152-164`, `:172-184`):

| Alan | Tür | Not |
|---|---|---|
| `unit` | i16 | "Time unit (i.e sample rate)"; [TAHMİN] saniye |
| `count` | i16 | örnek sayısı |
| `firstRecordTime` | u32 | yalnız `count > 0` **ve** v≥2 ise; v1'de `bedTime` kabul edilir |
| örnekler | `count` × u8 (nabız, SpO2) ya da `count` × float32 LE (horlama) | örnek `i` zamanı = `firstRecordTime + unit·i` |

Gadgetbridge nabız/SpO2/horlama örneklerini atlıyor, kaydetmiyor (`:142-144`, `:161-163`, `:181-183`). Freeband bunları uyku sırasındaki nabız/SpO2 için kullanabilir. [ÖNERİ]

#### 6.3.2 Evre paketleri

Akış, 17 baytlık başlığı olan paketlerden oluşur. Başlık **sihirli değerle** aranır: her konumda u32 LE okunur, `0xFFFCFAFB` değilse bir bayt ileri kayılır. Kablodaki sıra `FB FA FC FF`. Arama, kalan bayt ≥ 17 olduğu sürece sürer. (`:197-199`, `:377-386`)

| Ofset | Alan | Tür |
|---|---|---|
| 0 | sihirli değer | `FB FA FC FF` |
| 4 | `headerLen` | u8, "this seems to always be 17" (`:202`); Gadgetbridge yok sayıyor |
| 5 | `ts` | **i64 LE** (`:206`) |
| 13 | `parity` | u8, "sum of stage bit count should be uneven" (`:207`) |
| 14 | `type` | u8 |
| 15 | `dataLen` | **u16 big-endian** (`:209`) |
| 17 | veri | `dataLen` bayt, içeriği **big-endian** (`:227-230`) |

- Tip 2, 3, 9, 12, 13, 14, 15'te veri **yok**; `dataLen` alanı bayrak sayılıyor ve atlanmıyor. (`:221-225`)
- **Tip 18 ve 19 da verisiz** [GERÇEK, v6]: `dataLen` 1 ama sıradaki paket hemen başlıyor. Bunlar listede olmasa bir sonraki paketin başı atlanır. Gerçek dosyada ayrıca 10, 11 ve 20 (veri uzunluğu `dataLen` kadar) ve 101 (4 bayt) tipleri var; anlamları bilinmiyor. Bu kuralla 231 paketlik dosyada atlanan ve artan bayt sıfır.
- **Gece birden çok kez gönderiliyor** [GERÇEK, v6]: aynı `ts` (`bedTime`) ile bir ara tip-16/17 çifti (gece ortasında, o ana kadarki evreler) ve uyanınca son çift geliyor; son tip-17, ilkini önek olarak içeriyor. Evreler birleştirilirse çakışır. Freeband her `ts` için **son** tip-17 paketini kullanıyor (`nightStages`), dakikalar son tip-16'dan.
- Bilinen tipler: 0 `acc_unk`, 1 `ppg_unk` (RR aralıkları), 2 `fall_asleep`, 3 `wake_up`, 12/13 `switch_ts_unk`, 16 özet, 17 evreler. (`:211-219`)
- `ts` birimi karışık: "sometimes in seconds and other times in nanoseconds. Message types 16 and 17 are in seconds" (`:204-205`). Tip 1 için Gadgetbridge `ts`'i **milisaniye** gibi kullanıyor (`:235-240`). [TAHMİN: tip 1'in birimi kesin değil]

Tip 17, evreler (`:284-299`): `dataLen / 2` tane u16 BE kelime. Her kelime:

- `stage = word >> 12` (üst 4 bit)
- `minutes = word & 0x0FFF`
- İlk evrenin başlangıcı `ts` (saniye). Evre `i`'nin süresi kendi `minutes` değeri; bir sonrakinin başlangıcı `önceki başlangıç + minutes·60`.

Tip 16, özet (`:250-283`), 13 bayt, BE:

| Ofset | Alan | Tür |
|---|---|---|
| 0 | `sleep_index` (üst nibble), `wake_count` (alt nibble) | u8 |
| 1 | `sleep_duration` | u16 |
| 3 | `wake_duration` | u16 |
| 5 | `light_duration` | u16 |
| 7 | `rem_duration` | u16 |
| 9 | `deep_duration` | u16 |
| 11 | bayraklar: Gadgetbridge `has_rem = (b >> 4) == 1`, `has_stage = (b >> 2) == 1` | u8 |
| 12 | `unk_duration_minutes` ("Could probably be an awake duration after sleep") | u8 |

Süreler [TAHMİN] dakika (uyku evresi dosyasındaki "total sleep duration in minutes" yorumuyla tutarlı, `X/activity/impl/SleepStagesParser.java:71`). Bayrak yorumu şüpheli: `(b >> 2) == 1` yalnız `b` 4–7 iken doğru, `has_rem` bitiyle birlikte hiç doğru olamaz. Ham baytı saklayın. Bir dosyada birden fazla tip-16 olabilir; Gadgetbridge yalnız sonuncusunu saklıyor (`:280-283`).

Tip 1, RR aralıkları (`:232-249`): her bayt bir aralık, birim 10 ms. Gadgetbridge ilk paketin `ts`'ini ilk atım sayıyor ve sürüklenme 30 sn'yi aşarsa `ts`'e yeniden eşitliyor. Band 9 notu: RR verisi ~10 dakikalık gruplar hâlinde, RTC zaman damgasında birkaç saniyelik kayma var (`:101-111`).

Gadgetbridge evre paketlerinde `BufferUnderflowException`'ı yakalar ve o ana kadarkini saklar (`:193-196`, `:302-305`). Bu parser CRC'yi gövdeden düşmüyor; `remaining >= 17` koşulu yüzünden pratikte fark etmiyor. Referans parser CRC'yi düşüyor.

#### 6.3.3 Uyku oturumu

Bkz. bölüm 8.

### 6.4 Uyku evreleri (ACTIVITY / SLEEP_STAGES 0x03 / DETAILS)

[KOD] `X/activity/impl/SleepStagesParser.java:49-123`. Yalnız **sürüm 2** (`:50-53`). Bitmap yok. CRC gövdeden düşülür (`:56`).

| Gövde ofseti | Boy | Alan | Tür / not |
|---|---|---|---|
| 0 | 7 | bilinmiyor | "first 2 bytes: always FF FF" (`:63-69`); [TAHMİN] ilk iki bayt bir geçerlilik bitmap'i olabilir |
| 7 | 2 | `sleepDuration` | i16, "total sleep duration in minutes" (`:71-72`) |
| 9 | 4 | `bedTime` | u32 Unix saniye; "real" uyku başlangıcı, ilk evre değişiminden sonra olabilir (`:73-74`) |
| 13 | 4 | `wakeupTime` | u32 Unix saniye (`:75-76`) |
| 17 | 3 | bilinmiyor | (`:78-81`) |
| 20 | 2 | `deepSleepDuration` | i16 dakika [TAHMİN birim] (`:83-84`) |
| 22 | 2 | `lightSleepDuration` | i16 (`:85-86`) |
| 24 | 2 | `REMDuration` | i16 (`:87-88`) |
| 26 | 2 | `wakeDuration` | i16 (`:89-90`) |
| 28 | 1 | bilinmiyor | (`:111-112`) |
| 29 | 5·n | evre değişimleri | her biri `time` u32 + `phase` u8 (`:113-123`) |

- `bedTime`, `wakeupTime` ya da `sleepDuration` 0 ise dosya "veri yok" sayılır ve hiçbir şey kaydedilmez (`:94-97`).
- `phase` baytı **dönüştürülmeden** saklanır (`:117-121`); okumada 2 derin, 3 hafif, 4 REM, 5 uyanık diye yorumlanır (bölüm 8). Bu kodlamanın bileklikten aynen geldiği Gadgetbridge'in varsayımı. [KOD + TAHMİN]
- Her evre bir sonraki değişime kadar sürer; son evrenin bitişi `wakeupTime`. [TAHMİN, `XD/XiaomiSampleProvider.java:198-266`'daki üst üste bindirme mantığından]

### 6.5 Elle ölçümler (ACTIVITY / MANUAL_SAMPLES 0x06 / DETAILS)

[KOD] `X/activity/impl/ManualSamplesParser.java:49-194`. Tip sabitleri: `TYPE_HR = 0x11`, `TYPE_SPO2 = 0x12`, `TYPE_STRESS = 0x13`, `TYPE_TEMPERATURE = 0x44`. [KOD] `XD/XiaomiManualSampleProvider.java:36-39`

**Sürüm 1** (Mi Band 9 Active; `:123-194`): CRC düşülür; pad **0 olmak zorunda**; ardından `0xFF` başlık baytı; sonra 6 baytlık kayıtlar, kalan uzunluk 6'nın katı ve > 0 olmalı.

| Ofset | Boy | Alan |
|---|---|---|
| 0 | 4 | `timestamp` u32 Unix saniye |
| 4 | 1 | tip: `0x02` → SpO2 (`0x12`), `0x03` → stres (`0x13`); başka değer → dosya reddedilir |
| 5 | 1 | değer u8; `0` ya da `> 100` → dosya reddedilir |

[TEST] `T/impl/ManualSamplesParserTest.java:34-87`: `EFB9856AF4011800FFEFB9856A0261511E4648` → SpO2 97, ts 1787148783; stres 40 ve 27 paketleri; başlık, tip ve aralık dışı değer mutasyonları reddediliyor.

**Sürüm 2** (`:58-121`): başlık yok, kayıtlar hemen başlar.

| Alan | Tür |
|---|---|
| `timestamp` | u32 Unix saniye |
| `type` | u8 |
| değer | `0x11`/`0x12`/`0x13` → u8; `0x44` → u32 (gerçekte iki u16, `:95-98`) |

- Değeri `0` olan kayıt atlanır (`:106-108`).
- Bilinmeyen tip → **parse durur**, dosyanın tamamı başarısız sayılır, çünkü kayıt boyu bilinmiyor (`:100-104`). Kan basıncı TODO (`:99`).
- FIXME: "the type is actually composed of 2 nibbles that define the data length + type" (`:86-88`). Örneklerde üst nibble bayt sayısına uyuyor (`0x1x` → 1 bayt, `0x44` → 4 bayt). [TAHMİN] Bilinmeyen tipte üst nibble kadar bayt atlayıp devam etmek denenebilir, ama doğrulanmadı.
- Sıcaklık: `(value & 0xFFFF) / 100` °C. [KOD] `XD/XiaomiTemperatureSampleProvider.java:108`. Üst 16 bitin anlamı bilinmiyor.
- Kaynak yorumundaki örnek kayıtlar (`:72-77`): `8A90A965 12 63` SpO2 99; `9698A965 13 1C` stres 28; `E79CA965 44 5A0E0000` 36,74 °C.

### 6.6 Antrenman özeti (SPORTS / * / SUMMARY) — kapsam dışı

Küçük değil: `X/activity/impl/WorkoutSummaryParser.java` 1122 satır, 13 antrenman türünün her biri için ayrı sürüm tablosu ve alan listesi. Bu belgede ve referans parser'da yalnız zarf (id, pad, CRC) ele alınıyor. Özet:

- Gövde = `bitmap (türe ve sürüme göre 3–13 bayt) | alanlar`; alan listesi `XiaomiSimpleActivityParser.Builder` ile kuruluyor. [KOD] `X/activity/impl/WorkoutSummaryParser.java:204-279`, `X/activity/impl/XiaomiSimpleActivityParser.java:228-285`
- Gadgetbridge burada bitmap'i **uygulamıyor**; her alan koşulsuz okunuyor (FIXME). [KOD] `X/activity/impl/XiaomiSimpleActivityParser.java:94-101`
- Çoğu tür `TIME_START` u32, `TIME_END` u32, `ACTIVE_SECONDS` u32 ile başlıyor; açık hava yürüyüş v2 ve açık hava bisiklet önce u16 `XIAOMI_WORKOUT_TYPE` taşıyor. [KOD] `:303-306`, `:498-502`, `:614-618`
- Gerçek dosyalar fikstürde duruyor (bölüm 11), ileride Swift'te yazılırsa hazır.

## 7. Zaman damgası ve saat dilimi

- Dosya id'sindeki `ts` ve dosya içindeki bütün u32 zaman damgaları **Unix saniye, UTC**. Gadgetbridge bunları doğrudan `new Date(ts * 1000L)` ile kullanıyor, saat dilimi eklemiyor. [KOD] `X/activity/XiaomiActivityFileId.java:123`, `X/activity/impl/SleepDetailsParser.java:119-120`, `X/activity/impl/SleepStagesParser.java:100-101`, `:120`, `X/activity/impl/ManualSamplesParser.java:113`, `:187`
- Doğrulama: 12 gerçek antrenman dosyasında `ts + tz·15 dk` ile bulunan yerel tarih, Gadgetbridge testindeki sabit adında yazan tarihle aynı (ör. `OUTDOOR_RUN_V5_30SEP`: UTC 23:14, tz −12 → yerel 30 Eylül 20:14). [TEST] `T/impl/WorkoutSummaryParserTest.java:299-301`; kontrol fikstürde.
- `tz`: işaretli i8, 15 dakikalık birim. [KOD] `X/activity/XiaomiActivityFileId.java:111`. Aynı birim, yaz saati dahil, antrenman protobuf'ında da var. [KOD] `P/xiaomi/wear_fitness.proto:154-158`
- Gadgetbridge `tz`'yi örnek zamanlarına **uygulamıyor**; yalnız günlük özette saklıyor. [KOD] `X/activity/impl/DailySummaryParser.java:180`. Freeband de zamanları UTC olarak saklamalı, gün sınırını `tz` ile hesaplamalı. [ÖNERİ]
- Günlük detay kayıtları `ts + 60·i`. [KOD] `X/activity/impl/DailyDetailsParser.java:177`
- Günlük detay ve günlük özet dosyalarının `ts`'si büyük olasılıkla yerel gün başı (ya da dosyanın başladığı dakika). Kaynakta yazmıyor. [TAHMİN] Swift kodu bunu varsaymamalı; kayıt zamanı her zaman `ts + 60·i`.
- Uyku evre paketlerinde `ts` i64; tip 16/17 saniye, tip 1 milisaniye gibi işleniyor (bölüm 6.3.2).

## 8. Uyku evreleri ve oturum sınırları

İki ayrı kodlama var.

**Uyku detay dosyası, tip-17 paketindeki ham kod** → Gadgetbridge'in saklama kodu [KOD] `X/activity/impl/SleepDetailsParser.java:388-403`:

| Ham | Anlam | Saklanan |
|---|---|---|
| 0 | uyanık | 5 |
| 1 | hafif | 3 |
| 2 | derin | 2 |
| 3 | REM | 4 |
| 4 | uyku değil | 0 |
| diğer | N/A | 1 |

**Saklanan kod** (ve uyku evreleri dosyasındaki `phase` baytı) → anlam [KOD] `XD/XiaomiSampleProvider.java:180-188`:

| Kod | Anlam |
|---|---|
| 2 | derin (`DEEP_SLEEP`) |
| 3 | hafif (`LIGHT_SLEEP`) |
| 4 | REM (`REM_SLEEP`) |
| 5 | uyanık (`AWAKE_SLEEP`) |
| diğer | bilinmiyor |

Oturum sınırları:

- Bir oturum, dosya başlığındaki `bedTime`–`wakeupTime` aralığı. Gadgetbridge uyku kaydının anahtarı `bedTime`. [KOD] `X/activity/impl/SleepDetailsParser.java:118-121`, `:272-273`
- Aynı gece için birden fazla dosya gelebilir: "Samples for the same sleep will always have the same bedtime (timestamp), but we might get multiple bedtimes until the user wakes up". Aynı `bedTime`'a sahip kayıtlardan `wakeupTime`'ı daha geç olan kazanır, eskisi yok sayılır. [KOD] `X/activity/impl/SleepDetailsParser.java:324-334`, `X/activity/impl/SleepStagesParser.java:134-144`
- Evre zaman çizelgesi, tip-17 kelimelerinin süreleri birikerek kurulur (bölüm 6.3.2). Evre örneği olmayan oturumlarda Gadgetbridge grafikte `bedTime`'dan `wakeupTime`'a kadar hafif uyku boyar. [KOD] `XD/XiaomiSampleProvider.java:208-211`, `:255-266`
- `isAwake`: Gadgetbridge yorumu "0/1 - more correctly this would be !isSleepFinish" (`X/activity/impl/SleepDetailsParser.java:84`). Hangi değerin "uyku bitti" demek olduğu net değil. [TAHMİN] Ham değeri saklayın; oturumun kapandığına `wakeupTime` geçmişteyse ve aynı `bedTime` için daha yeni dosya gelmiyorsa karar verin.
- Gün içi kısa uykular için ayrı bir işaret kaynakta yok; tip-16'daki `sleep_index` bir oturum sayacı olabilir. [TAHMİN]

## 9. Band 9 / 10 sınıfı hangi sürümleri gönderir

| Dosya | Gadgetbridge'in desteklediği sürümler | Kaynaktaki cihaz ipucu | Band 10 / 10 Pro için beklenti |
|---|---|---|---|
| DailyDetails | 1, 2, 3, 4 (`DailyDetailsParser.java:53-67`) | yok | **v4** [GERÇEK, Band 10 Pro] |
| DailySummary | 3, 4, 5 | v3 "Smart Band 8 Active", v4 "Mi Band 9 Active", v5 "Mi Band 10 and later" (`DailySummaryParser.java:152-157`) | **v5**, 30 slot [GERÇEK, Band 10 Pro] |
| SleepDetails | 1–5 | v2 DETAILS, v4/v5 SUMMARY (`SleepDetailsParser.java:53`); Band 9 FW 2.3.93 RR notu (`:101`) | **v6, SUMMARY** [GERÇEK, Band 10 Pro]; Gadgetbridge v6'yı tanımıyor |
| SleepStages | 2 | yok | belirsiz; hiç gelmeyebilir [TAHMİN] |
| ManualSamples | 1, 2 | v1 "Mi Band 9 Active" (`ManualSamplesParser.java:130`) | **v2** [GERÇEK, Band 10 Pro] |
| Antrenman özeti | türe göre 1–11 | açık hava bisiklet v8 "Smart Band 10 Pro" (`WorkoutSummaryParser.java:605`, test `:211`), v6 "Smart Band 10" (test `:248`) | kapsam dışı |
| Antrenman detayı | türe göre | `SPORTS_OUTDOOR_CYCLING v5 (Smart Band 10 Pro)` (`WorkoutDetailsParser.java:567`) | kapsam dışı |

Not: "Mi Band 9 Active", Band 9 / 10'dan farklı bir platform; v1 manuel ölçüm ve v4 günlük özet o cihaza özgü olabilir. [TAHMİN] Band 10 ve 10 Pro kodlayıcıları deneysel işaretli. [KOD] `XD/watches/MiBand10Coordinator.java:51-54`, `XD/watches/MiBand10ProCoordinator.java:40-43`

**Swift tarafı hangi sürümün geldiğini sabit kodlamamalı**: her dosyada `version` okunup tabloya bakılmalı, bilinmeyen sürüm ham olarak saklanmalı (bölüm 10).

## 10. Swift uygulamasının savunmacı ele alması gerekenler

1. **Kanal 5 yönlendirmesi.** `BandLink.decode` şu an `channel == 1` dışını atıyor (`ios/Freeband/Band/BandLink.swift:360`). Kanal 5'i opcode'a göre çözüp parça birleştiriciye verin; taşıma ACK'ini her pakete göndermeye devam edin.
2. **Subtype 5 asla gönderilmesin.** Kodda bu subtype için yardımcı bile olmasın ki yanlışlıkla çağrılmasın. [ÖNERİ]
3. **Ham dosyayı önce saklayın.** CRC doğruysa id + tüm bayt diske, sonra parse. Gadgetbridge de parse'tan önce yazıyor (`X/activity/XiaomiActivityFileFetcher.java:145`). Parser sonradan düzelirse yeniden işlenebilir.
4. **Parça sırası.** `num` 1'den başlar; beklenmeyen `num` / `total` gelirse dosyayı at. 5 sn sessizlikte zaman aşımı, bir yeniden deneme.
5. **Gelen id = istenen id** mi kontrol edin; değilse uyarıp yine de gelen id'ye göre saklayın.
6. **Tekilleştirme.** Liste içinde ve iki liste arasında aynı id gelebilir (Gadgetbridge #4305, `X/activity/XiaomiActivityFileFetcher.java:200-208`). Hepsi sıfır id'leri atın.
7. **ACK yok → hep aynı liste.** Daha önce CRC'si doğru alınmış geçmiş dosyaları atlayın; bugünün listesindekileri yeniden çekip büyümüşse güncelleyin. [TAHMİN]
8. **Bilinmeyen `version` / tip.** Hata değil; ham sakla, "desteklenmiyor" işaretle. SPORTS dosyaları da listede gelecek.
9. **İşaretlilik.** `ts` u32 (Java'da `int`, 2038 sonrası taşar); `tz` i8; uyku evrelerindeki süreler Gadgetbridge'de i16 (`getShort`), negatif gelirse geçersiz sayın; uyku detayındaki örnek `unit`/`count` de `getShort` (`X/activity/impl/SleepDetailsParser.java:133-134`), `count < 0` → bloğu bozuk sayın.
10. **DailyDetails.** Başlık maskesi dosya başına; ek bayt bayrağı yüzünden kayıt boyu değişebilir; son kısmi kayıtta durun, önceki kayıtları kaybetmeyin. Stres 255 = yok; nabız 0 = ölçülmemiş [TAHMİN]; v4'ün son iki 16 bitlik grubunun anlamı belirsiz.
11. **SleepDetails.** Sihirli değerle senkronlanan akış: arada çöp bayt olabilir. Tip-1 `ts` birimi belirsiz; tip-16 bayrak yorumu şüpheli; v5'in 9 bilinmeyen baytı ve `bedTime2` saklanmalı. Bir paketin `dataLen`'i kalan bayttan büyükse orada durun.
12. **SleepStages.** Yalnız v2 biliniyor; `bedTime == 0` vb. "veri yok".
13. **ManualSamples v2.** Bilinmeyen tipte durun (uzunluk bilinmiyor); nibble-uzunluk hipotezi yalnız deneysel. `0x44`'ün üst 16 biti bilinmiyor.
14. **Pad baytı ≠ 0.** Uyar, devam et; v1 manuel ölçümde ise dosyayı reddet (Gadgetbridge öyle yapıyor, `X/activity/impl/ManualSamplesParser.java:142-146`).
15. **CRC.** zlib `crc32` ile aynı; iOS'ta `libz` ya da ~10 satırlık tablo yeterli. CRC hatalı dosyayı parse etmeyin (Gadgetbridge de etmiyor, `:124-133`).
16. **Mi Fitness ile aynı anda.** 005E'yi aynı anda yalnız bir uygulama dinlemeli (findings 5.4). Senkron sırasında Mi Fitness açılırsa paketler karışır.

## 11. Referans parser ve fikstürler

```
cd ios/tests/activity
python3 -I activity_ref.py --selftest            # 54/54 vaka
python3 -I fixtures/make_fixtures.py              # fikstürleri yeniden üretir (vendor/Gadgetbridge gerekir)
python3 -I activity_ref.py parse DOSYA.bin        # tek dosya → JSON
python3 -I activity_ref.py assemble p1.bin p2.bin # çözülmüş kanal-5 parçaları → JSON
python3 -I activity_ref.py fileid 21F328650403A0  # id ya da id listesi
```

`activity_ref.py` yalnız stdlib kullanıyor ve bu belgeden yazıldı; Gadgetbridge kodunun çevirisi değil. CRC'yi kendi tablosuyla hesaplıyor, selftest bunu `zlib.crc32` ile karşılaştırıyor.

| Fikstür | Kaynak | İçerik |
|---|---|---|
| `gb_fileid.json` | [TEST] `T/XiaomiActivityFileIdTest.java` | id çözme, tekrar kodlama, sıfır id |
| `gb_manual_samples_v1.json` | [TEST] `T/impl/ManualSamplesParserTest.java:34-87` | 3 **gerçek** Band 9 Active paketi (CRC'li) ve 3 ret vakası; mutasyondan sonra CRC yeniden hesaplandı ki ret içerikten gelsin |
| `gb_daily_summary.json` | [TEST] `T/impl/DailySummaryParserTest.java` | Gadgetbridge'in bellekte kurduğu girdiler bayt bayt yeniden üretildi (CRC'siz); beklenenler testin assert'leri |
| `gb_workout_summary_blobs.json` | [TEST] `T/impl/WorkoutSummaryParserTest.java` | 13 **gerçek** antrenman özeti dosyası: id, CRC ve yerel tarih kontrolü; içerik parse edilmiyor |
| `synthetic.json` | **SENTETİK**, `make_fixtures.py` | DailyDetails v2/v3/v4, SleepDetails v2/v5/v6 (v6: gerçek dosyanın biçiminde, değerler uydurma; bir de blokları hizalanmayan v6), 30 slotluk DailySummary v5, SleepStages v2, ManualSamples v2 (kayıtlar kaynak yorumundan), CRC kontrol değeri, gerçek bir dosyanın 3 parçaya bölünüp birleştirilmesi, bozuk parça, sıra dışı parça, id listesi ve getirme sırası |

Gadgetbridge test ağacında **günlük detay, uyku detayı ve uyku evreleri için hiç gerçek veri yok**; bunlar için yalnız sentetik fikstür var. Sentetik dosyalar bu belgedeki düzenle `make_fixtures.py` içinde, parser'dan bağımsız olarak paketlendi; beklenen değerler paketlenen değerler. Yani iki uygulamanın birbirine uyduğunu gösteriyorlar, bilekliğin gerçekten böyle gönderdiğini değil. İlk gerçek Band 10 dosyaları geldiğinde (`activity_ref.py parse` ile) bu bölümler doğrulanmalı.

### 11.1 Gerçek Band 10 Pro dosyaları (2026-10-14)

İlk gerçek dosyalar, uygulamanın veritabanından alındı (12 dosya: 8 DailyDetails v4, 2 DailySummary v5, 1 ManualSamples v2, 1 SleepDetails v6). Hepsinin CRC'si doğru ve hepsi hem referans parser'da hem Swift'te hatasız çözülüyor. Uyku dosyasında son tip-16 özetindeki hafif/derin/REM/uyanık dakikaları, son tip-17 paketindeki evre sürelerinin toplamıyla birebir aynı; ham evre kodu eşlemesi (bölüm 8) doğrulandı.

Sağlık verisi oldukları için repoda değiller (`out/`, gitignored). Kendi dosyalarınızı denemek için: `python3 -I activity_ref.py parse DOSYA.bin`.

Not: SwiftData/Core Data, harici depolamaya izin verilen `Data` alanını SQLite'ta bir işaret baytıyla saklıyor (`0x01` = satır içi, ardından veri). Veritabanından dosya çıkarırken bu ilk bayt atılmalı; protokolün parçası değil.

Selftest'in hataları yakaladığı da denendi: bitmap bit sırası, nibble slot sırası, zaman kayması, paket uzunluğunun endian'ı, `tz` işareti ve ek bayt atlanması gibi tek satırlık bozulmaların her biri en az bir vakayı düşürüyor.
