# Freeband veri sözleşmesi (v1)

> **2026-11-14:** hesap sunucusu (REST API, web paneli, davet) kaldırıldı; kimse kullanmıyordu. Bu belgede yalnız veri sözleşmesi (`freeband.v1` gövdeleri) geçerli: uygulamanın telefondan gönderdiği webhook'lar ve CSV/JSON dışa aktarma aynı gövdeleri kullanıyor. Uç noktaları, kimlik doğrulamayı ve paneli anlatan bölümler artık tarihî.

Uygulama, webhook'lar ve Cloudflare hub aynı JSON biçimini kullanır. Zamanlar ISO 8601 UTC (`2026-10-13T20:59:41Z`).

Sözleşme `freeband.v1` içinde yalnız **ekleyerek** büyür: yeni tür, yeni olay ya da yeni isteğe bağlı alan gelebilir; var olan alanın anlamı değişmez. Alıcılar (hub ve webhook sunucuları) **tanımadıkları türleri ve alanları yok sayar**, gövdeyi reddetmez.

## Örnek (sample) türleri

| `type` | Alanlar | Anlamı | Yazma kuralı |
|---|---|---|---|
| `live` | `steps`, `calories`, `heart_rate`, `standing_hours?` | Bandın canlı istatistik olayı (Health 8/47). `steps` ve `calories` o güne ait **kümülatif** toplam; `heart_rate` anlık, 0 ise ölçülmedi. | ekle ya da yok say |
| `battery` | `level` | Pil yüzdesi (System 2/1). | ekle ya da yok say |
| `minute` | `steps`, `heart_rate?`, `spo2?`, `stress?`, `active_calories?`, `distance_m?` | Aktivite dosyasından bir dakika. `ts` dakikanın başı. | üzerine yaz |
| `sleep` | `end`, `is_nap`, `minutes`, `wake_count`, `efficiency`, `stages`, `hr_min`, `spo2_avg`, `spo2_min`, `hrv_rmssd?` | Bir uyku oturumu. `ts` yatış, `end` kalkış. | üzerine yaz |
| `score` | `date`, `sleep`, `recovery`, `strain`, `rhr`, `hrv_rmssd`, `confidence`, `contributors`, `algo` | Uygulamanın o gün için hesapladığı skorlar. `ts` o günün yerel gece yarısı. | üzerine yaz |

`?` ile işaretli alanlar ölçülmediyse gönderilmez (ya da `null` gönderilir). İşaretsiz alanlar her zaman vardır; aşağıda "null olabilir" denenler ölçülmediyse `null` olur.

Bir kullanıcının birden fazla bandı olabilir (ör. Band 10 ve Band 10 Pro). Her gövde tek bir banda aittir ve `device.id` ile tanımlanır. Her örnek `(device.id, type, ts)` ile tekildir:

- `live` ve `battery`: aynı üçlü tekrar gelirse yok sayılır (ilk değer kalır).
- `minute`, `sleep`, `score`: aynı üçlü tekrar gelirse **son yazan kazanır**; satırın tamamı yenisiyle değişir (yeni gövdede olmayan isteğe bağlı alan silinir). Değişmeden gelen satır tekrar sayılır. Uygulama bir günü ya da geceyi yeniden çözdüğünde aynı `ts` ile yeniden gönderir.

### `minute`

Yalnız boş olmayan dakikalar gönderilir (adım > 0 ya da en az bir ölçüm var). Bir gövdede en fazla bir günün dakikaları önerilir (en fazla 1440 örnek).

| Alan | Tür | Aralık |
|---|---|---|
| `ts` | zaman | dakika başı, saniye ve milisaniye 0 |
| `steps` | tam sayı | 0–1000 |
| `heart_rate?` | tam sayı, bpm | 30–220 |
| `spo2?` | tam sayı, % | 70–100 |
| `stress?` | tam sayı | 1–100 |
| `active_calories?` | tam sayı, kcal | 0–100 |
| `distance_m?` | tam sayı, metre | 0–1000 |

```json
{ "type": "minute", "ts": "2026-10-13T07:42:00Z", "steps": 112, "heart_rate": 96, "spo2": 97, "stress": 34, "active_calories": 6, "distance_m": 84 }
```

### `sleep`

Gece, uyanılan güne (`end`'in yerel gününe) aittir. Kimlik `ts` (yatış) olduğu için uygulama aynı oturumu hep aynı `ts` ile göndermeli.

| Alan | Tür | Aralık |
|---|---|---|
| `ts` | zaman | yatış |
| `end` | zaman | kalkış; `ts`'den sonra, en fazla 24 saat sonra |
| `is_nap` | boolean | kısa uyku (şekerleme) mi |
| `minutes` | `{ "deep", "light", "rem", "awake" }` | her biri 0–1440 tam sayı dakika, toplamı en fazla 1440 |
| `wake_count` | tam sayı | 0–255 |
| `efficiency` | tam sayı, % | 0–100 |
| `stages` | `[[offset_min, stage, dur_min], …]` | `offset_min` yatıştan bu yana dakika (sıralı), `stage` `deep`, `light`, `rem` ya da `awake`, `dur_min` ≥ 1; evre oturumun dışına taşamaz; en fazla 1440 evre; evre yoksa `[]` |
| `hr_min` | tam sayı, bpm | 30–220, null olabilir |
| `spo2_avg` | sayı, % | 70–100 (ondalık olabilir), null olabilir |
| `spo2_min` | tam sayı, % | 70–100, `spo2_avg`'den büyük olamaz, null olabilir |
| `hrv_rmssd?` | sayı, ms | 1–300 (ondalık olabilir); yalnız RR varsa |

```json
{
  "type": "sleep", "ts": "2026-10-12T20:41:00Z", "end": "2026-10-13T04:12:00Z", "is_nap": false,
  "minutes": { "deep": 82, "light": 241, "rem": 96, "awake": 32 },
  "wake_count": 3, "efficiency": 93,
  "stages": [[0, "light", 14], [14, "deep", 38], [52, "light", 61], [113, "rem", 22]],
  "hr_min": 48, "spo2_avg": 96.4, "spo2_min": 91, "hrv_rmssd": 42
}
```

### `score`

| Alan | Tür | Aralık |
|---|---|---|
| `ts` | zaman | `date` gününün telefonun saat dilimindeki gece yarısı, UTC olarak (İstanbul'da `2026-10-13` için `2026-10-12T21:00:00Z`); UTC gece yarısından en fazla 14 saat önce, 12 saat sonra |
| `date` | `YYYY-MM-DD` | telefonun yerel günü |
| `sleep` | tam sayı | 0–100, null olabilir (süre yoksa skor yok) |
| `recovery` | tam sayı | 0–100, null olabilir |
| `strain` | sayı | 0–21 (ondalık olabilir), null olabilir |
| `rhr` | tam sayı, bpm | 30–220, null olabilir |
| `hrv_rmssd` | sayı, ms | 1–300, null olabilir |
| `confidence` | `{ "sleep", "recovery", "strain" }` | her biri `high`, `medium`, `low` ya da `none` |
| `contributors` | dizi | en fazla 32 katkı (aşağıda) |
| `algo` | metin | algoritma sürümü, en fazla 40 karakter, `A–Z a–z 0–9 . _ / + -` (ör. `freeband-score/1`) |

Katkı nesnesi: `key` gerekli (küçük harfli ad, en fazla 32 karakter, `a–z 0–9 _`, ör. `duration`, `hrv`, `rhr`); diğerleri isteğe bağlı: `score` (`sleep`, `recovery` ya da `strain`), `weight` (0–100), `value` (kendi biriminde ham değer ya da `null`), `unit` (en fazla 12 karakter, ör. `min`, `ms`, `bpm`, `%`), `subscore` (0–100 ya da `null`), `baseline` (14 günlük bazal, `value` ile aynı birimde, ya da `null`), `note` (en fazla 120 karakter, ör. güven gerekçesi "RR yok"). Bilinmeyen katkı alanları atılır.

```json
{
  "type": "score", "ts": "2026-10-12T21:00:00Z", "date": "2026-10-13",
  "sleep": 82, "recovery": 64, "strain": 11.4, "rhr": 54, "hrv_rmssd": 41.5,
  "confidence": { "sleep": "high", "recovery": "medium", "strain": "low" },
  "contributors": [
    { "score": "sleep", "key": "duration", "weight": 35, "value": 431, "unit": "min", "subscore": 88, "baseline": 418 },
    { "score": "recovery", "key": "hrv", "weight": 40, "value": null, "subscore": null, "note": "RR yok" }
  ],
  "algo": "freeband-score/1"
}
```

### Geçerli ölçüm aralıkları

Nabız **30–220** bpm, SpO2 **70–100** %, stres **1–100**. `minute`, `sleep` ve `score` bu aralığın dışını kabul etmez. `live.heart_rate` geriye uyum için 0–250 kabul edilir (0 = ölçülmedi), ama hub'ın özetleri ve paneli yalnız 30–220 arasını nabız sayar.

## Gönderim gövdesi (uygulama → hub, uygulama → webhook)

```json
{
  "schema": "freeband.v1",
  "event": "sync.completed",
  "device": {
    "id": "5B0E2C9A-4C7D-4F57-9A39-2D2B1D9E8A10",
    "name": "Xiaomi Smart Band 10 Pro D9B9",
    "model": "band10pro",
    "app_version": "0.4 (8)",
    "tz": "Europe/Istanbul"
  },
  "sent_at": "2026-10-13T21:00:02Z",
  "summary": {
    "date": "2026-10-13",
    "steps": 8421,
    "calories": 312,
    "heart_rate_last": 74,
    "battery": 46
  },
  "samples": [
    { "type": "live", "ts": "2026-10-13T20:59:41Z", "steps": 8421, "calories": 312, "heart_rate": 74, "standing_hours": 9 },
    { "type": "battery", "ts": "2026-10-13T20:59:40Z", "level": 46 },
    { "type": "minute", "ts": "2026-10-13T20:58:00Z", "steps": 12, "heart_rate": 74 }
  ]
}
```

- `event`:
  - `sync.completed`: bandın bekleyen bütün dosyaları okundu.
  - `sync.partial`: senkron yarıda kaldı (ör. "20 dosyadan 12'si"). Gövdedeki örnekler geçerlidir ve saklanır; kalanı sonraki senkronda gelir. Bu senkron başarılı sayılmaz. `minute`/`sleep`/`score` üzerine yazıldığı için aynı veriyi tekrar göndermek güvenlidir.
  - `ping`: yalnız webhook testi.
- `device.id`: uygulamanın her bant için bir kez ürettiği rastgele UUID (bandın MAC'i ya da seri numarası değil). `device.model`: `band10` ya da `band10pro`.
- `summary.date` cihazın saat dilimindeki gün.
- Bir gövdede en fazla 5000 örnek, en fazla 512 KB. Bir günün dakikaları (en fazla 1440) bir gövdeye sığar; birden çok gün için birden çok gövde gönderin.

## Webhook imzası

Her istek şu başlıklarla gelir:

| Başlık | Değer |
|---|---|
| `Content-Type` | `application/json` |
| `X-Freeband-Event` | `sync.completed`, `sync.partial` ya da `ping` |
| `X-Freeband-Delivery` | rastgele UUID |
| `X-Freeband-Signature` | `sha256=<hex>`: gövdenin HMAC-SHA256'sı, anahtar webhook'un gizli değeri |

Alıcı imzayı ham gövde üzerinden doğrulamalı. Uygulama webhook'ları yalnız `https://` adreslere gönderir. Aynı örnek birden çok kez gelebilir: alıcı `(device.id, type, ts)` ile tekilleştirmeli; `minute`, `sleep` ve `score` için son geleni saklamalı.

## Hub API

Taban adres: `https://freeband.cobanov.dev` (geliştirmede `http://localhost:8787`). Kimlik doğrulama `Authorization: Bearer fb_<token>`.

| Yöntem | Yol | Açıklama |
|---|---|---|
| `POST` | `/v1/accounts` | Yeni hesap. Gövde `{ "device_name": "...", "tz": "Europe/Istanbul", "invite": "..." }`; `invite` sunucu yöneticisinin verdiği davet kodudur (yanlışsa `403 invalid_invite`). Cevap `{ "account_id", "token", "web_url" }`; token yalnız bir kez döner. IP başına sınırlı. |
| `GET` | `/v1/me` | Hesap bilgisi, tür başına kayıt sayıları (`samples: { live, battery, minute, sleep, score, total }`) ve bilinen cihazlar (`devices: [{ id, name, model, last_seen }]`). |
| `POST` | `/v1/ingest` | Gönderim gövdesi (yukarıda). Cevap `{ "accepted", "duplicates" }`; hub'ın tanımadığı türde örnek varsa `"ignored"` da gelir. `accepted` yeni ya da değişen satır sayısı, `duplicates` değişmeden gelenler. En az bir satır yazıldıysa hub'ın doğruladığı gövde, gövdenin `event`'iyle hesabın sunucu webhook'larına iletilir (tanınmayan türler iletilmez). |
| `GET` | `/v1/samples?device=&type=live&from=&to=&limit=` | Canlı ve pil örnekleri, zamana göre artan, en fazla 5000. `device` verilmezse tüm cihazlar; her örnek `device_id` taşır. |
| `GET` | `/v1/minutes?device=&from=&to=&limit=&after=` | Dakikalar, `ts`'ye göre artan. Varsayılan 1440, en fazla 5000. |
| `GET` | `/v1/sleep?device=&from=&to=&limit=&after=` | Uyku oturumları; `from`/`to` **kalkış zamanına** (`end`) uygulanır, sıra da `end`'e göredir. Varsayılan 100, en fazla 1000. |
| `GET` | `/v1/scores?device=&from=YYYY-MM-DD&to=YYYY-MM-DD&limit=&after=` | Günlük skorlar, kendi `date` alanına göre (iki uç dahil). Varsayılan 366, en fazla 1000. |
| `GET` | `/v1/days?device=&from=YYYY-MM-DD&to=YYYY-MM-DD` | Cihaz başına günlük özet (aşağıda); hesabın saat dilimine göre. |
| `GET` | `/v1/export.csv` · `/v1/export.json` | `from`/`to`/`device`/`type` ile dışa aktarma (aşağıda). |
| `GET` `POST` `DELETE` | `/v1/webhooks`, `/v1/webhooks/:id` | Sunucu webhook'ları (en fazla 5; yalnız https). Oluştururken gizli değer bir kez döner. `POST /v1/webhooks/:id/test` ping gönderir. |
| `POST` | `/v1/token/rotate` | Yeni token, eskisi hemen geçersiz. Kullanıcı yenisini uygulamada **Ayarlar → Web erişimi → API anahtarını gir** alanına yapıştırır. |
| `DELETE` | `/v1/account` | Hesabı ve tüm veriyi (örnekler, dakikalar, uyku, skorlar, bantlar, webhook'lar, oturumlar) kalıcı siler. |
| `POST` | `/v1/session` | Web paneli girişi: gövde `{ "token" }`, cevap HttpOnly oturum çerezi. `DELETE` çıkış. |

Ortak parametreler:

- `from`/`to` (`/v1/samples`, `/v1/minutes`, `/v1/sleep`, dışa aktarma): ISO 8601 zaman (`from` dahil, `to` hariç) ya da hesabın saat dilimine göre `YYYY-MM-DD` gün (iki uç dahil). `/v1/scores` ve `/v1/days` yalnız `YYYY-MM-DD` alır.
- `device`: bant kimliği (büyük/küçük harf fark etmez). Verilmezse hesabın bütün bantları.
- Sayfalama (`/v1/minutes`, `/v1/sleep`, `/v1/scores`): cevap `{ "<liste>": [...], "has_more": bool, "next": "…" | null }`. Sonraki sayfa için aynı isteği `after=<next>` ile tekrarla. `next` opaktır; birden çok bant aynı zamanı paylaşsa da satır atlamaz, tekrarlamaz.
- Liste öğeleri gönderim gövdesindeki örnek biçimindedir, artı `device_id`.

### Günlük özet (`/v1/days`)

```json
{ "date": "2026-10-13", "device_id": "5B0E…", "steps": 8421, "calories": 312,
  "heart_rate_min": 52, "heart_rate_max": 131, "heart_rate_avg": 74, "battery_last": 46,
  "sleep_minutes": 419, "nap_minutes": 35,
  "score": { "sleep": 82, "recovery": 64, "strain": 11.4, "rhr": 54, "hrv_rmssd": 41.5,
             "confidence": { "sleep": "high", "recovery": "medium", "strain": "low" }, "algo": "freeband-score/1" } }
```

- `steps`: canlı örneklerin günlük kümülatif en büyüğü ile dakika adımlarının toplamından büyük olanı.
- `calories`: canlı örneklerden. `battery_last`: günün son pil örneği.
- `heart_rate_min/max/avg`: canlı örnekler ve dakikalar; yalnız 30–220 bpm sayılır.
- `sleep_minutes`: o yerel günde **biten** gece uykularının (şekerleme değil) derin + hafif + REM dakikaları. `nap_minutes`: aynı kural, şekerlemeler. Yalnız veri varsa gelir.
- `score`: telefonun o `date` için gönderdiği skor (katkılar `/v1/scores`'ta). Yalnız varsa gelir.
- Herhangi bir kaynakta verisi olan gün listede yer alır; hiç verisi olmayan gün yer almaz. Varsayılan aralık bugün dahil son 14 gün, en fazla 366 gün.

### Dışa aktarma

- `export.json` her türü içerir: `samples` (live, battery), `minutes`, `sleep`, `scores`; öğeler okuma uç noktalarındakiyle aynı. `type` verilirse yalnız o tür dolu gelir.
- `export.csv` düz tablodur, dosya başına bir tablo: varsayılan (ya da `type=live`/`battery`) canlı ve pil örnekleri (`device_id,type,ts,steps,calories,heart_rate,standing_hours,level`); `type=minute`, `type=sleep`, `type=score` o türün kendi sütunlarıyla gelir. `stages` ve `contributors` hücreleri JSON metnidir (RFC 4180'e göre tırnaklı).
- Skorlar dışa aktarmada `ts`'ye göre, uyku `end`'e göre süzülür. Tek seferde toplam en fazla 200 000 satır; fazlası için aralığı böl.

Web sayfaları: `/` (tanıtım ve giriş), `/login#token=...` (uygulamadaki "Web paneli aç" bağlantısı; token URL parçasında kalır, sunucuya gitmez, sayfa onu `POST /v1/session` ile çereze çevirir), `/app` (panel), `/docs` (API belgesi), `/privacy` (gizlilik).

## Güvenlik kuralları

- Token: `fb_` + 32 rastgele baytın base64url'i. D1'de yalnız SHA-256 özeti tutulur.
- Hesaplar birbirinin verisini göremez; her sorgu `account_id` ile sınırlı. Aynı `device.id` iki hesapta iki ayrı banttır.
- Oturum çerezi `HttpOnly; Secure; SameSite=Strict`, 30 gün.
- Gövde boyutu, örnek sayısı, alan aralıkları doğrulanır (ör. `live.heart_rate` 0–250, `level` 0–100, yeni türlerde yukarıdaki aralıklar, `ts` ±2 gün geleceğe kadar); bilinen bir türde tek bir geçersiz alan bütün gövdeyi `400 invalid_body` ile reddeder.
- Webhook hedefi yalnız `https://`, hub'ın kendi alan adına izin yok, 5 sn zaman aşımı.
- Sağlık verisi: kullanıcı "Web erişimi"ni açmadıkça hiçbir şey hub'a gitmez; `DELETE /v1/account` her şeyi siler.
