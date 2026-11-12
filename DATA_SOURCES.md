# DATA_SOURCES

Everything ROVA shows comes from the sources below. Each endpoint here was
called from this machine and the responses recorded; nothing is quoted from
documentation alone.

Investigated on **2026-11-12**, Istanbul time.

---

## 1. İETT fleet service — live vehicle positions ✅ WORKING

| | |
|---|---|
| Endpoint | `https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx` |
| WSDL | same URL + `?WSDL` |
| Protocol | SOAP 1.1, `document/literal`, namespace `http://tempuri.org/` |
| Method | `GetHatOtoKonum_json` |
| Credentials | **none required** (see note on `AuthHeader` below) |
| Catalogue entry | `sefer-gerceklesme-web-servisi` on data.ibb.gov.tr |

### The parameter name is wrong in the official PDF

İETT's *Web Service Usage Document v1.5* documents the parameter as `HatNo`.
The actual WSDL declares:

```xml
<s:element name="GetHatOtoKonum_json">
  <s:complexType><s:sequence>
    <s:element maxOccurs="1" minOccurs="0" name="HatKodu" type="s:string"/>
  </s:sequence></s:complexType>
</s:element>
```

Sending `HatNo` returns `soap:Fault — Object reference not set to an instance
of an object`. **`HatKodu` is correct.** This cost an hour; it is written down
here so it costs nobody else one.

### AuthHeader is declared but not enforced

The binding declares an optional SOAP header:

```xml
<soap:header message="tns:GetHatOtoKonum_jsonAuthHeader" part="AuthHeader" use="literal"/>
```

Requests sent **without** any header succeed. ROVA sends none. If İETT begins
enforcing it, the required credentials would have to be requested from İETT
Büyük Veri ve İş Zekâsı Müdürlüğü; ROVA does not attempt to work around it.

### Request

```xml
<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
               xmlns:tns="http://tempuri.org/">
  <soap:Body>
    <tns:GetHatOtoKonum_json><tns:HatKodu>146</tns:HatKodu></tns:GetHatOtoKonum_json>
  </soap:Body>
</soap:Envelope>
```

with `Content-Type: text/xml; charset=utf-8` and
`SOAPAction: "http://tempuri.org/GetHatOtoKonum_json"`.

### Response — captured verbatim, 2026-11-12 04:30 Istanbul

```json
[{"kapino":"B-1887","boylam":"28.66874","enlem":"41.06737","hatkodu":"146",
  "guzergahkodu":"146_G_D6038","hatad":"BOĞAZKÖY / BAHÇEŞEHİR - BAKIRKÖY",
  "yon":"BOĞAZKÖY SON DURAK","son_konum_zamani":"2026-11-12 04:30:54",
  "yakinDurakKodu":"128071"}]
```

| Field | Meaning | Notes |
|---|---|---|
| `kapino` | vehicle door number | the real İETT vehicle identifier |
| `enlem` / `boylam` | latitude / longitude | **strings**, WGS84, dot decimal |
| `hatkodu` | line code | matches `SHATKODU` from the network service |
| `guzergahkodu` | route variant | **identical format to GTFS `route_code`** — this is the join that makes route matching possible |
| `hatad` | line name | |
| `yon` | direction, as a terminus name | not a `D`/`G` flag |
| `son_konum_zamani` | source timestamp | `yyyy-MM-dd HH:mm:ss`, **Europe/Istanbul (UTC+3)** |
| `yakinDurakKodu` | nearest stop code | İETT's own nearest-stop guess |

An empty array `[]` is a normal answer when no vehicle of that line is running.

### Measured behaviour

* **Update interval: ~60 s.** Polling line 146 every 30 s for 12 minutes gave
  distinct `son_konum_zamani` values at gaps of **53, 63, 63, 67 s**.
  Polling faster than this buys nothing.
* **Latency: 160–450 ms.**
* **Stationary vehicles still report** — a bus idling at its terminus emits a
  fresh timestamp with an unchanged position. ROVA therefore distinguishes
  *fresh data* from *movement*.
* **Coordinate validation is required** — the feed can emit placeholder values;
  ROVA rejects anything outside 40.5–41.9 N / 27.0–30.5 E.

### Rate limit — and how it actually fails ⚠️

The usage document says **"A maximum of 100 requests can be sent to this
service in an hour."** That is real and enforced by a Layer7 gateway.

Over-quota requests return **HTTP 500** with:

```xml
<soapenv:Fault>
  <faultcode>soapenv:Server</faultcode>
  <faultstring>Policy Falsified</faultstring>
  <faultactor>https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx</faultactor>
  <detail>
    <l7:policyResult status="Rate limit exceeded."
       xmlns:l7="http://www.layer7tech.com/ws/policy/fault"/>
  </detail>
</soapenv:Fault>
```

The `l7:policyResult` detail states the cause in plain words — captured
verbatim above on 2026-11-12 at 05:00 Istanbul.

This was observed first-hand during development after combined polling from
the backend, a measurement script and the test suite exceeded the ceiling.
Both ROVA clients now detect `Policy Falsified`, stop calling for **10
minutes**, and surface *"Live location unavailable"* rather than a stale
countdown.

Transient `HTTP 503` responses also occur (roughly 1 in 20 under normal load);
both clients retry once after 1.5 s without spending a second budget slot.

**ROVA's budget policy**

| Caller | Policy |
|---|---|
| iPhone app | sliding window capped at 70 req/h; watched line every 60 s, other lines every 600 s |
| Backend | ingestion **off by default** (`INGEST_ENABLED=false`) because it shares the same public IP as the phone; capped at 40 req/h when enabled |

---

## 2. İETT network service — stops and lines ✅ WORKING

| | |
|---|---|
| Endpoint | `https://api.ibb.gov.tr/iett/UlasimAnaVeri/HatDurakGuzergah.asmx` |
| Methods used | `GetDurak_json` (all stops), `GetHat_json` (all lines) |
| Credentials | none |
| Operations available | `GetDurak_{XML,csv,json}`, `GetGaraj_*`, `GetHat_*` |

`GetDurak_json` with an empty `DurakKodu` returns the full stop list
(**15 141 usable stops**, 3.7 MB) in ~3 s:

```json
{"SDURAKKODU":100022,"SDURAKADI":"OKTAY RIFAT CADDESİ",
 "KOORDINAT":"POINT (28.6952349999764 41.004605000554)",
 "ILCEADI":"Esenyurt","SYON":"BOGAZKÖY","AKILLI":"YOK",
 "FIZIKI":"AÇIK","DURAK_TIPI":"İETTBAYRAK","ENGELLIKULLANIM":"Uygun Degil"}
```

Coordinates are **WKT `POINT (lon lat)`** — longitude first. Turkish
characters are correct UTF-8 here.

`GetHat_json` returns **782 lines** with name, length and scheduled trip
duration.

This service is the authoritative source for stop names and positions; the
GTFS export is not (see below).

**Note:** this service does *not* expose route→stop sequences. The
`HatDurakGuzergah` WSDL only offers `Durak`, `Garaj` and `Hat`. Stop sequences
come from GTFS.

---

## 3. İBB Open Data — İETT GTFS ✅ WORKING

| | |
|---|---|
| Catalogue | `https://data.ibb.gov.tr/api/3/action/package_show?id=iett-gtfs-verisi` |
| Files | `agency, calendar, routes, stops, trips` (CSV) + `stop_times.zip` |
| Size | `stop_times.txt` = 150 MB, 6 155 692 rows |
| Last published | 2026-03-16; `calendar` valid to 2026-12-31 |
| Licence | İBB Open Data Portal terms |

Used for what the SOAP services do not provide: **route stop sequences and
timetables**.

### Quirks that must be handled

1. **Mixed delimiters.** `routes/stops/trips/calendar` are `;`-separated with a
   BOM. `stop_times.txt` is `,`-separated.
2. **Double-encoded Turkish text** in `routes.csv` and `trips.csv`
   (`BOĞAZKÖY` → `BOÄAZKÃ–Y`). The bytes are UTF-8 of a cp1252/latin-1
   misreading, and the two codecs are *mixed within one string*, so the fix has
   to be applied character by character (`tools/build_bundle.py: fix_mojibake`).
   ROVA sidesteps the problem where it can by taking stop and line names from
   the SOAP service instead.
3. **Thousand-separated decimals** in `stops.csv`: `stop_lat` arrives as
   `410.191.700.005.564`. ROVA ignores these columns entirely and uses the
   SOAP `KOORDINAT` field.
4. **Sparse `stop_times`.** Only timepoints carry a time; intermediate stops
   have empty `arrival_time`. ROVA takes the median observed offset per stop
   index across up to 400 trips of a pattern, then interpolates the gaps by
   inter-stop distance.
5. **No `shapes.txt`** in the İETT feed, so there is no road geometry for bus
   legs. (The separate `public-transport-gtfs-data` package *does* ship shapes,
   but for metro/ferry/minibus, not İETT buses.)

### `route_code` ↔ `guzergahkodu`

`routes.csv` carries `route_code` in the form `142_G_D0`, which is exactly the
`guzergahkodu` the live fleet service returns. This single correspondence is
what lets ROVA match a live vehicle to a specific route variant and therefore
to a specific stop sequence.

---

## 4. Sources investigated and NOT used

| Source | Status |
|---|---|
| **GTFS-Realtime for İETT** | Not published. No GTFS-RT resource exists in the İBB catalogue (578 datasets searched) and no endpoint was found. |
| `api.ibb.gov.tr/iett/ibb/ibb.asmx` | Reachable. Offers `DurakDetay_GYY`, `HatServisi_GYY`, `DurakDetay_GYY_wYonAdi`. Stop-level arrival info; not needed once live positions are available. |
| `api.ibb.gov.tr/iett/UlasimAnaVeri/PlanlananSeferSaati.asmx` | Planned departure times — GTFS already covers this more completely. |
| `api.ibb.gov.tr/iett/UlasimDinamikVeri/Duyurular.asmx` | Service announcements. A `transit_alerts` table exists for it; not wired into the UI in v1. |
| `api.ibb.gov.tr/iett/AracOzellik.asmx` | Vehicle attributes (accessibility, model). Not needed for ETA. |
| `GetFiloAracKonum_json` | Also on the fleet service, but fleet-wide rather than per line, and the document attributes it to a third party (Akyolbil). `GetHatOtoKonum_json` is the right granularity and cheaper against the quota. |
| `tkmservices.ibb.gov.tr` | Live ASP.NET Web API host, but no documented İETT bus-location route; returned 404 for the paths tried. Not used. |
| **Metrobüs live positions** | **Available**, under the route-variant line codes — not under `34`/`34A`. Measured 2026-11-13 over two hours: `34BZ` 93 vehicles, `34G` 86, `34C` 50, while `34` and `34A` held 3–5 between them. An earlier note in this file claimed Metrobüs publishes nothing; that was generalised from sampling only `34`/`34A` at a quiet moment and was wrong. |
| Nominatim / OSM geocoding | Returned nothing for "Şafak Residence". Apple's `MKLocalSearch` resolved it exactly; that is what ROVA uses. |

---

## 5. Verified journey coordinates

Resolved with `MKLocalSearch` (Apple Maps data) over an Istanbul region, then
cross-checked against the İETT stop network.

| Place | Coordinate | Verification |
|---|---|---|
| **Şafak Residence** | `41.016013, 28.683227` | Apple returned the POI with address *İnönü, Adile Naşit Blv. No:37 D:1, 34513 Esenyurt İstanbul*. The nearest İETT stop is **ADİLE NAŞİT CADDESİ** (code 130661) at **108 m** — the same street as the resolved address. |
| **Avcılar Metrobüs** | `40.985755, 28.724028` | Apple returned *İETT Avcılar Metrobüs Otobüs Durağı, D-100 Kuzey Bağlantısı, 34320 Avcılar*. İETT stop **AVCILAR METROBÜS** (code 101452) is **6 m** away. |

Both are asserted in `ios/ROVATests/ROVATests.swift`, so a bad edit to the
configuration fails the test suite.

---

## 6. Terms of use

The İBB Open Data Portal publishes these datasets and services for public
reuse. ROVA:

* sends no credentials and bypasses no access control;
* identifies itself with a `User-Agent` of `ROVA/1.0 (personal transit client)`;
* stays below the published 100 requests/hour ceiling by design, and stops
  calling entirely when the gateway signals over-quota;
* stores no personal data and transmits none to İETT beyond the line code.

## Metrobüs

Checked 2026-11-12 against `GetHatOtoKonum_json`: lines **34** and **34A**
return a valid response with **zero vehicle positions**. The Metrobüs is
operated by İETT but its fleet does not publish positions through this service,
and no other İBB endpoint was found that does.

ROVA therefore treats any Metrobüs leg as timetable-only and says so in the
trip card. It is not shown as live, and no vehicle is invented for it.
