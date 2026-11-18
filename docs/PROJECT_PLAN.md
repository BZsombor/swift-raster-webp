# swift-raster-webp – Projektterv

| | |
|---|---|
| **Állapot** | Az M1 kiadva 0.1.0 verzióként, a következő az M2 (VP8L dekóder) |
| **Dátum** | 2026-11-18 |
| **Cél** | Könnyű, gyors, tisztán Swiftben írt, cross-platform WebP-kodek |
| **Nagyobb kép** | A `raster` képfeldolgozó könyvtár első építőköve |

A dokumentumban minden döntés státuszt kap:

- **Elfogadva:** már megállapodtunk benne.
- **Javasolt:** a kutatás és a mérések alapján ezt ajánlom, jóváhagyásra vár.
- **Nyitott:** a te döntésedet igényli (lásd [18. fejezet](#18-nyitott-kérdések)).

---

## 1. Vízió és célok

### 1.1 Küldetés

A kutatás során nem találtam tisztán Swiftben írt WebP-megoldást. A megtalált csomagok a libwebp C-könyvtárat csomagolják be, a rendszerszintű ImageIO pedig csak Apple-platformon érhető el. A `swift-raster-webp` ezt a hiányt pótolja: egyetlen, függőségmentes csomag, amely minden Swift-platformon ugyanúgy viselkedik.

### 1.2 Prioritások

Ha két cél ütközik, a sorrend dönt:

1. **Helyesség és biztonság.** Hibás vagy rosszindulatú fájl soha nem okozhat memóriahibát.
2. **Sebesség.** A dekódolás a libwebp közelében legyen.
3. **Könnyűség.** Kicsi bináris, kevés memória, nulla függőség.
4. **Kényelmes API.** Egyszerű alapeset, de elérhető a nulla másolásos út is.
5. **Tömörítési arány.** Az enkódernél fontos, de az 1.0-ban nem cél a libwebp legjobb szintjének elérése.

### 1.3 Az 1.0 hatóköre

| Funkció | 1.0 | Később |
|---|---|---|
| RIFF-konténer, metaadat-lekérdezés | Igen | |
| VP8L (veszteségmentes) dekódolás | Igen | |
| VP8 (veszteséges) dekódolás, ALPH | Igen | |
| Animáció dekódolása | Igen | |
| ICC, EXIF, XMP olvasása | Igen | |
| VP8L (veszteségmentes) kódolás | Igen | |
| ICC, EXIF, XMP írása | Igen | |
| VP8 (veszteséges) kódolás | | 1.x |
| Animáció kódolása | | 1.x |
| Inkrementális (streaming) dekódolás | | 1.x, az API nem zárhatja ki |
| Beépített többszálúság | | Mérés után dönthető el |
| Átméretezés, vágás dekódolás közben | | A `raster` feladata |

### 1.4 Nem célok

- C, C++ vagy assembly kód a csomagban.
- A libwebp API-jának másolása.
- Embedded Swift támogatás az 1.0-ban. A magot úgy írjuk, hogy később ne legyen akadály, de nem vállaljuk.
- Big-endian platform hivatalos támogatása. A kód endian-semleges lesz, de nem tesztelünk rá folyamatosan.

---

## 2. Helyzetkép

| Megoldás | Nyelv | Mit tud | Tanulság számunkra |
|---|---|---|---|
| **libwebp 1.6.0** | C, SIMD | Mindent | Teljesítmény- és helyességi referencia |
| **image-webp 0.2.4** (Rust) | Tiszta Rust, `unsafe` nélkül | Teljes dekódolás, veszteségmentes kódolás | A legközelebbi minta, a README szerint a libwebp sebességének 70–100%-a |
| **Swift-WebP, webp.swift, WebPKit** | Swift + libwebp | Burkolók | C-függőség, nem a mi kategóriánk |
| **Apple ImageIO** | Rendszer | Csak Apple-platform | Nem cross-platform |

**Fontos pontosítás az `image-webp`-ről:** a kiadott 0.2.4-es verzió valóban csak veszteségmentesen kódol, de a `main` ágon már megjelent egy veszteséges enkóder is (kb. 1500 sor). A következő kiadásukkal tehát a Rust-oldali funkcionalitás bővülhet. A saját ütemtervünket ez nem borítja fel, de a [18. fejezetben](#18-nyitott-kérdések) döntési pontként szerepel.

**A várható kódmennyiség** az `image-webp` alapján:

| Rész | Rust sorok |
|---|---:|
| Veszteségmentes dekóder | 1 775 |
| Veszteséges dekóder és közös részek | 4 780 |
| Konténer, API, animáció | 1 583 |
| Veszteségmentes enkóder | 978 |
| **Az 1.0-nak megfelelő összesen** | **kb. 9 100** |

---

## 3. Mérhető célok

A célok számszerűek, és a CI vagy a kiadási folyamat ellenőrzi őket.

### 3.1 Dekódolási sebesség

Referencia: Apple M5, egy szál, libwebp 1.6.0, RGBA kimenet, 11158 × 2156 pixeles (24 Mpx) természetes kép.

| Kép | libwebp (mért) | M2/M3 belépő cél (50%) | 1.0 cél (70%) | Törekvés (90%) |
|---|---:|---:|---:|---:|
| Veszteséges, q75 | 149 Mpx/s | 75 Mpx/s | 105 Mpx/s | 134 Mpx/s |
| Veszteséges, q90 | 99 Mpx/s | 50 Mpx/s | 69 Mpx/s | 89 Mpx/s |
| Veszteségmentes | 75 Mpx/s | 37 Mpx/s | 52 Mpx/s | 67 Mpx/s |

### 3.2 Bináris méret

Referencia a Homebrew-s arm64 libwebp: `libwebpdecoder` 188 KB, teljes `libwebp` 352 KB.

| Termék | Cél (hozzáadott méret, strippelve) |
|---|---:|
| Csak dekóder | legfeljebb 400 KB |
| Dekóder és enkóder | legfeljebb 800 KB |

A Foundation elhagyása önmagában is sokat számít: egy statikusan linkelt, strippelt Linux-program **5,5 MB** Foundation nélkül és **11,5 MB** vele (Swift 6.2.4, aarch64).

### 3.3 Memória

- **Veszteséges dekódolás:** a kimeneti pufferen felül legfeljebb a szélességgel arányos munkamemória (néhány macroblock-sor), nem a teljes kép YUV-másolata.
- **Veszteségmentes dekódolás:** a transzformációk helyben, a kimeneti pufferben futnak, a kiegészítő memória a Huffman-táblákra és a transzformációs adatokra korlátozódik.
- **Allokációk:** képenként előre kiszámolt, kevés nagy allokáció. A forró ciklusokban nincs allokáció.

### 3.4 Minőség

- A teljes libwebp tesztkészlet átmegy, bit-pontos eredménnyel.
- Legalább 90%-os sorlefedettség a dekóderben.
- Folyamatos fuzzing, nyitott crash nélkül minden kiadásnál.
- Nulla külső függőség a könyvtár termékeiben.

---

## 4. Mérési eredmények

A terv technikai döntéseit eldobható prototípusokkal ellenőriztem, a projekten kívül. Ezek mikrobenchmarkok, ezért az **arányokat** érdemes nézni, nem az abszolút számokat. A zaj körülbelül ±4%.

Környezet: Apple M5. A macOS-mérés Swift 6.4.2-vel, a Linux-mérés Dockerben, Swift 6.2.4-gyel, aarch64-en futott.

### 4.1 Bitolvasás és Huffman-dekódolás (millió szimbólum/s)

| Megvalósítás | macOS, 6.4.2 | Linux, 6.2.4 |
|---|---:|---:|
| Unsafe pointer (referencia) | 451 | 423 |
| `RawSpan` + ellenőrzés nélküli olvasás | 450 | 413 |
| `Span`, ellenőrzés nélkül | 433 | 416 |
| **`Span`, bounds checkkel** | **441** | **369** |
| `Array`, wrapping aritmetika | 422 | 376 |
| `Array`, ellenőrzött aritmetika | 437 | 321 |
| **Állapot `final class` tulajdonságaiban** | **189** | **294** |

**Következtetések:**

- A dekóder állapotát soha nem tartjuk osztályban a forró ciklusban. Ez a legdrágább hiba, macOS-en **2,4-szeres** lassulás.
- A bounds-checkelt `Span` a pointerhez képest macOS-en 2%-ot, Linuxon 13%-ot veszített. A két mérés operációs rendszerben és fordítóverzióban is eltér, ezért a különbség oka még nem különíthető el.

### 4.2 Pixeltranszformáció: inverz subtract-green (millió pixel/s)

| Megvalósítás | macOS, 6.4.2 | Linux, 6.2.4 |
|---|---:|---:|
| `Array`, ellenőrzött aritmetika | 7 724 | 7 319 |
| `Array`, wrapping aritmetika | 9 728 | 9 264 |
| `MutableSpan`, bounds checkkel | 10 241 | 9 365 |
| `MutableSpan`, ellenőrzés nélkül | 9 885 | 8 933 |
| Unsafe pointer | 9 964 | 8 991 |
| Standard könyvtári `SIMD8<UInt32>` | 12 958 | 10 528 |

**Következtetések:**

- A wrapping műveletekkel (`&+`, `&>>`) írt változat kb. 20%-kal gyorsabb volt az ellenőrzött aritmetikásnál.
- Ennél az egyszerű ciklusnál a `MutableSpan` bounds checkjének nem volt mérhető ára.

### 4.3 YUV → RGBA konverzió (millió pixel/s, sima bemenet)

| Megvalósítás | macOS, 6.4.2 | Linux, 6.2.4 | Szorzó a skalárhoz |
|---|---:|---:|---:|
| Skalár | 1 510 | 1 285 | 1× |
| Standard könyvtári `SIMD8<Int32>` | 2 064 | 1 821 | 1,4× |
| **NEON intrinsic Swiftből** | **5 611** | **4 507** | **3,5–3,7×** |

Mindhárom változat bit-pontosan ugyanazt az eredményt adta.

**Következtetés:** ahol telítő aritmetika és 16 bites szorzás kell, a hordozható `SIMD` típusok korlátozottak. A natív intrinsicek itt nagy előnyt adnak (lásd [D7 döntés](#51-döntési-napló)).

### 4.4 További ellenőrzött tények

| Kérdés | Eredmény |
|---|---|
| `Span` használható régebbi Apple OS-en? | Igen. macOS 13-as célra is lefordul, ha pointerből származtatjuk. |
| `Array.span` használható? | Csak macOS 26-tól, tehát a könyvtárban **tilos**. |
| `InlineArray` használható? | Csak macOS 26-tól, tehát a könyvtárban **tilos**. |
| `OutputSpan`-os tömbinicializálás | macOS 13-as célra is lefordul. |
| NEON-intrinsicek Linuxon is elérhetők? | Igen, aarch64-en működtek. |
| Minden intrinsic hívható Swiftből? | **Nem.** A C-makróként definiáltak hiányoznak, például `vld1_u8`, `_mm_shuffle_epi32`, `_mm_slli_si128`. |
| Összetett SIMD-kifejezések fordítása | Swift 6.2 típusellenőrzője feladta őket, ezért lépésekre bontva, explicit típusokkal írjuk. |
| Többszálúság haszna a libwebp-ben | q75: 22%, q90: 11%, veszteségmentes: 0%. |

**Amit nem sikerült megmérni:**

- Az `image-webp` sebességét nem mértem le ezen a gépen, a 70–100%-os adat a projekt saját állítása.
- A libwebp SIMD nélküli sebességét nem tudtam izolálni, mert ezen az arm64-es buildben a `-noasm` kapcsolónak nem volt hatása.
- Az x86-64, Windows, Android és WebAssembly teljesítmény még mérésre vár. Az [M1 mérföldkő](#m1--alapok) ezt pótolja.

---

## 5. Technikai alapdöntések

### 5.1 Döntési napló

| # | Téma | Döntés | Státusz |
|---|---|---|---|
| D1 | Függőségek | Nulla külső függőség a könyvtárban | Elfogadva |
| D2 | Foundation | Tilos a kodek-célokban | Elfogadva |
| D3 | Nyelvi mód | Swift 6, strict concurrency | Elfogadva |
| D4 | Implementáció alapja | Kizárólag az RFC 9649 és az RFC 6386 alapján írunk kódot, más könyvtárak csak referenciák ([ADR 0003](adr/0003-implementation-sources.md)) | Elfogadva |
| D5 | Licenc | Apache-2.0 | Elfogadva |
| D6 | Minimum Swift | **Swift 6.3** | Elfogadva (K2) |
| D7 | SIMD-stratégia | Skalár → `SIMD` → izolált intrinsic kernelek | Elfogadva (K1) |
| D8 | Bemeneti típus | `Span<UInt8>` az alap, `[UInt8]` kényelmi overload | Elfogadva |
| D9 | Memóriabiztonság | `.strictMemorySafety()`, az `unsafe` csak auditált kernelekben | Elfogadva |
| D10 | Hibakezelés | Typed throws, sticky EOF a bitolvasókban | Elfogadva |
| D11 | Többszálúság | Az 1.0-ban nincs belső szálkezelés, az API `Sendable` | Elfogadva |
| D12 | Modulok | Külön dekóder és enkóder termék ([ADR 0001](adr/0001-module-structure.md)) | Elfogadva |
| D13 | Build-beállítások | Nincs `unsafeFlags` | Elfogadva |
| D14 | Platformminimum | macOS 13, iOS 16, tvOS 16, watchOS 9, visionOS 1 | Elfogadva |

### 5.2 Teljesítményszabályok

Ezek a szabályok a forró kódra (bitolvasás, Huffman, transzformációk, predikció, szűrés, színkonverzió) kötelezőek.

**Állapot és adatszerkezetek**

1. A forró állapot helyi változóban vagy `inout` structban él, soha nem osztályban.
2. A belső dekóder-típusok `~Copyable` structok, így véletlen másolás nem történhet.
3. Forró ciklusban nincs `any` típus, closure, protokoll-dispatch, `String` vagy allokáció.
4. A táblák laposak, egy allokációban vannak. Tömbök tömbje tilos.
5. Globális táblát a ciklus előtt helyi változóba emelünk, hogy a lusta inicializálás ellenőrzése ne fusson minden iterációban.

**Memória-hozzáférés**

6. Az alapértelmezés a bounds-checkelt `Span` és `MutableSpan`.
7. Ellenőrzés nélküli hozzáférés csak akkor megengedett, ha a benchmark legalább 3%-os nyereséget mutat a teljes dekódolásban, és a kód mellett komment bizonyítja az indexek érvényességét.
8. Az `Array.span` és az `InlineArray` tilos a [4.4 fejezetben](#44-további-ellenőrzött-tények) leírt elérhetőség miatt.
9. Többbájtos olvasás mindig `loadUnaligned` és `UInt32(littleEndian:)` párossal történik, ami gyors és endian-semleges.

**Aritmetika**

10. A kernelekben wrapping műveleteket használunk (`&+`, `&-`, `&*`, `&<<`, `&>>`).
11. A külső adatból származó méreteket viszont mindig ellenőrzött aritmetikával, 64 biten számoljuk. A WebAssembly 32 bites, ott az `Int(UInt32)` összeomolhat.

**Inlining és specializáció**

12. A kis primitívek `@inline(always)` jelölést kapnak (SE-0496, Swift 6.3-tól).
13. A nagy függvényeket nem kényszerítjük inline-ra, mert az a bináris méretet növeli.
14. A generikus kódot a hívási határon belül tartjuk, a forró útvonal modulhatárt nem lép át.
15. A sok pixelformátumot konkrét, sor-szintű függvények kezelik, nem generikus pixelenkénti absztrakció.

**Olvashatóság**

16. Az összetett SIMD-kifejezéseket lépésekre bontjuk, explicit típusannotációval.

### 5.3 SIMD-stratégia

A kernelek három szinten készülnek, és magasabb szintre csak mérés után lépünk:

| Szint | Eszköz | Mikor |
|---|---|---|
| **1. Skalár** | Sima Swift, wrapping műveletek | Mindig kötelező, ez a referencia és a fallback |
| **2. Hordozható SIMD** | `SIMD8`, `SIMD16` stb. | Ha legalább 20% nyereséget hoz |
| **3. Natív intrinsic** | NEON, SSE2 a `_Builtin_intrinsics` modulból | Csak ha a sebességcél másképp nem érhető el |

Szabályok a 3. szinthez:

- Külön fájlban, `#if arch(arm64) && canImport(...)` alatt él.
- Bit-pontos egyezést tesztelünk a skalár változattal.
- x86-64-en csak SSE2-t használunk, mert az az alapkészlet, így nincs szükség futásidejű CPU-felismerésre.
- A `_Builtin_intrinsics` aláhúzásos, nem hivatalosan stabil modul, ezért a skalár fallback mindig lefordul és tesztelt marad.

Várható jelöltek a 3. szintre: YUV-konverzió, fancy upsampling, loop filter, inverz DCT.

### 5.4 Fordítási beállítások

- Nincs `unsafeFlags`. Egy könyvtár ne írja elő a felhasználó buildjének viselkedését.
- Az `-Ounchecked` ezért nem opció. Amit az adna, azt a kód szintjén, célzottan érjük el.
- `.strictMemorySafety()` be van kapcsolva, így minden `unsafe` használat látható és kereshető.

---

## 6. Kodek-architektúra

A kódot a WebP-szabványok alapján írjuk. A más nyelvű könyvtárakat (libwebp, `image-webp`) csak referenciaként használjuk: megnézzük, ők hogyan oldottak meg egy problémát, és összevetjük velük az eredményeinket, de kódot, táblát vagy konstanst nem veszünk át, és nem portolunk belőlük. Az alábbi táblázatok „Forrás” oszlopa azt jelöli, hol láttunk példát az adott általános technikára. A részletes szabály az [ADR 0003](adr/0003-implementation-sources.md) dokumentumban van.

### 6.1 Közös elvek

```text
bemeneti bájtok
     │
     ▼
RIFF-parser ──► chunk-tartományok (másolás nélkül)
     │
     ├─► VP8L dekóder ──────────────────────┐
     ├─► VP8 dekóder ──► YUV ──► upsampling ├─► pixelformátum ──► kimeneti puffer
     └─► ALPH dekóder ──────────────────────┘
```

- A bemenetet soha nem másoljuk. A parser csak tartományokat ad vissza.
- A kimeneti puffert a hívó is adhatja, így a teljes dekódolás allokációmentes lehet a kimenet szempontjából.
- A hibákat a bitolvasók „ragadós” EOF-jelzője gyűjti. Nem bitenként ellenőrzünk, hanem sor- vagy macroblock-szinten, ahogy a libwebp és az `image-webp` is teszi.

### 6.2 VP8L dekóder

| Terület | Technika | Forrás |
|---|---|---|
| Bitolvasó | 64 bites ablak, 32 bites utántöltés, `loadUnaligned` | libwebp |
| Huffman | Kétszintű tábla, 8 bites gyökér, egyetlen lapos allokáció | libwebp |
| Gyorsítás | Csomagolt tábla rövid kódokra, triviális literál és triviális kód ága | libwebp |
| **Validálás** | **Előbb a kódhosszak teljes ellenőrzése, csak utána táblaépítés** | CVE-2023-4863 tanulsága |
| Color cache | Szorzó-hash, kötegelt beszúrás | libwebp |
| Backward ref | Átfedő másolás gyors ágakkal a kis távolságokra | libwebp |
| Transzformációk | Helyben, fordított sorrendben, blokkonkénti prediktor-választással | image-webp |
| Alpha | 8 bites optimalizált út, ha csak a zöld csatorna hordoz adatot | libwebp |

### 6.3 VP8 dekóder

| Terület | Technika | Forrás |
|---|---|---|
| Bool decoder | 56 bites ablak, `leadingZeroBitCount` normalizálás | libwebp |
| EOF-kezelés | Macroblockonként összesített ellenőrzés | image-webp |
| Pipeline | Soronkénti feldolgozás: parse → rekonstrukció → késleltetett szűrés → kimenet | libwebp |
| Munkaterület | 32 bájtos sortávú blokk, SIMD-barát elrendezés | libwebp |
| IDCT | Együttható-szám szerinti változatok (csak DC, 3 együttható, teljes) | libwebp |
| Loop filter | Szegmensenként előre számolt erősségek, 16 pixeles kötegek | libwebp |
| Upsampling | A `dwebp` alapértelmezett fancy upsamplingjével bit-pontos | libwebp |
| Színkonverzió | Önálló megvalósítás, a kimenete bit-pontosan egyezik a libwebp-vel | libwebp |

A soronkénti pipeline a memóriacél kulcsa: a munkamemória a szélességgel arányos, nem a képterülettel.

### 6.4 Animáció

- Iterátor-alapú API, egyszerre egy képkocka.
- Vászon-kompozíció a blend és dispose szabályok szerint.
- Legfeljebb két vászonnyi puffer.
- A keyframe-felismerés gyorsítja a kompozíciót.

### 6.5 VP8L enkóder

Három erőfeszítési szint, mindegyik determinisztikus kimenettel:

| Szint | Cél | Eszközök |
|---|---|---|
| `fast` | Sebesség, alapértelmezett | Subtract-green, egyszerű prediktor, hash-alapú LZ77 |
| `balanced` | Jó arány | Prediktor- és színtranszformáció, color cache |
| `best` | Kis méret | Palettafelismerés, több jelölt kipróbálása, meta-Huffman |

Az enkóder célja az 1.0-ban: a `balanced` szint a `cwebp -lossless -z 3` méretének 110%-án belül maradjon. Ezt az M5 elején pontosítjuk mért adatok alapján.

---

## 7. Biztonság

A képdekóderek a támadók kedvelt célpontjai. A **CVE-2023-4863** a libwebp Huffman-táblaépítésében volt: a kód előbb írt a táblába, és csak utána derült ki, hogy a kód érvénytelen. A hibát aktívan kihasználták.

### 7.1 Fenyegetési modell

Minden bemenetet megbízhatatlannak tekintünk. A garanciánk:

- Bármilyen bemenetre a dekóder vagy helyes eredményt, vagy `WebPError` hibát ad.
- Nincs crash, memóriahiba, végtelen ciklus vagy korlátlan allokáció.

### 7.2 Védelmi rétegek

1. **Biztonságos alapértelmezés:** bounds-checkelt `Span` mindenhol, ahol a mérés nem indokol mást.
2. **`unsafe` audit:** minden `unsafe` blokk mellett komment írja le az invariánst, a kódjegyzékük a `docs/unsafe-audit.md` fájlban van.
3. **Validálás írás előtt:** Huffman-kódok, méretek és táblahatárok ellenőrzése minden írás előtt.
4. **Erőforrás-korlátok:** beállítható pixel-, memória- és képkockalimit, biztonságos alapértékekkel.
5. **Dekompressziós bomba elleni védelem:** a kimeneti méretet a fejléc alapján, allokáció előtt ellenőrizzük.
6. **Folyamatos fuzzing** és sanitizer-futások ([10. fejezet](#10-tesztelési-stratégia)).

### 7.3 Alapértelmezett korlátok (tervezet)

| Korlát | Alapérték | Formátum maximuma |
|---|---:|---:|
| Pixelszám képkockánként | 256 Mpx | kb. 268 Mpx (VP8L/VP8) |
| Vászonterület animációnál | 256 Mpx | 2³² |
| Képkockaszám | 65 536 | Nincs |
| Összes dekódolt pixel animációnál | 4 Gpx | Nincs |

---

## 8. Publikus API (tervezet)

Az API-t az M1-ben véglegesítjük, a lenti minta az irányt mutatja.

```swift
import RasterWebP

// 1. Metaadat, dekódolás nélkül
let info = try WebPImageInfo(parsing: bytes)
print(info.width, info.height, info.hasAlpha, info.isAnimated)

// 2. Egyszerű dekódolás
let image = try WebPDecoder.decode(bytes)            // RGBA8, [UInt8] tárolással

// 3. Beállításokkal
var options = WebPDecodingOptions()
options.pixelFormat = .bgra8
options.alpha = .premultiplied
options.limits.maximumPixelCount = 50_000_000
let thumbnail = try WebPDecoder.decode(bytes, options: options)

// 4. Nulla másolás: a hívó puffere
try WebPDecoder.decode(span, into: &outputSpan, bytesPerRow: stride, options: options)

// 5. Animáció
var animation = try WebPAnimationDecoder(bytes)
while let frame = try animation.nextFrame() {
    show(frame.pixels, duration: frame.durationMilliseconds)
}

// 6. Kódolás
let encoded = try WebPEncoder.encodeLossless(
    pixels, width: 640, height: 480, format: .rgba8, effort: .balanced
)
```

### API-alapelvek

- **Haladó fokozatosság:** egy sor az alapeset, a részletek opcionálisak.
- **Foundation nélkül:** a bemenet `Span<UInt8>` vagy `[UInt8]`.
- **Kiterjeszthető típusok:** az opciók structok, a hibák bővítése nem törhet forráskódot.
- **`Sendable`:** minden publikus értéktípus az, így a felhasználó párhuzamosíthat.
- **Determinizmus:** azonos bemenet és beállítások mellett azonos kimenet minden platformon.

### Opcionális integrációk

A mag érintetlen marad, az integrációk külön termékek. Package trait helyett azért választunk külön terméket, mert a traitek a teljes függőségi gráfban egyesülnek, így egy másik csomag akaratlanul is behúzhatná a Foundationt.

| Termék | Tartalom | Mikor |
|---|---|---|
| `RasterWebPFoundation` | `Data` és `URL` kényelmi API | M5 |
| `RasterWebPCoreGraphics` | `CGImage` konverzió Apple-platformon | M5 |
| Raster-adapter | A `raster` képtípusaihoz | A `raster` indulásakor |

---

## 9. Projektstruktúra

```text
swift-raster-webp/
├── Package.swift
├── README.md, LICENSE, CHANGELOG.md
├── CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md
├── .spi.yml                    # Swift Package Index és DocC
├── .swift-format
├── .github/workflows/          # CI, sanitizerek, fuzz, benchmark
│
├── Sources/
│   ├── RasterWebP/             # Gyűjtő-termék: dekóder + enkóder
│   ├── RasterWebPCore/         # Konténer, közös típusok, hibák, táblák
│   │   ├── Container/
│   │   ├── Types/
│   │   └── Tables/
│   ├── RasterWebPDecoder/
│   │   ├── API/
│   │   ├── Lossless/           # Bitolvasó, Huffman, color cache, transzformációk
│   │   ├── Lossy/              # Bool decoder, predikció, IDCT, loop filter
│   │   ├── Alpha/
│   │   ├── Animation/
│   │   ├── Color/              # YUV, upsampling, pixelformátumok
│   │   └── Kernels/            # Scalar/, SIMD/, NEON/, SSE2/
│   └── RasterWebPEncoder/
│       ├── API/
│       ├── Lossless/
│       └── Container/
│
├── Tests/
│   ├── RasterWebPCoreTests/
│   ├── RasterWebPDecoderTests/
│   ├── RasterWebPEncoderTests/
│   └── ConformanceTests/       # Golden hash-ek a referenciakészlethez
│
├── Benchmarks/                 # Külön csomag, saját függőségekkel
├── Fuzz/                       # libFuzzer-célok és futtató szkript
├── Tools/                      # Külön csomag: korpuszkezelés, összehasonlítás
├── Examples/                   # Parancssori és alkalmazás-példák
└── docs/
    ├── PROJECT_PLAN.md
    ├── adr/                    # Architektúra-döntések
    ├── performance/            # Mérési eredmények verziónként
    └── unsafe-audit.md
```

### Miért így?

- **A `Benchmarks` és a `Tools` külön csomag, a `Fuzz` saját szkripttel fordul.** Így a fejlesztői függőségek soha nem kerülnek a felhasználók függőségi gráfjába.
- **A dekóder és az enkóder külön modul.** A legtöbb alkalmazásnak csak dekóder kell, így a bináris kisebb marad.
- **A forró kód nem lép át modulhatárt.** A Swiftben a modulhatár optimalizálási határ is, ezért a `Core` csak konténert, típusokat és táblákat tartalmaz.
- **A felosztást mérés igazolja.** Az [ADR 0001](adr/0001-module-structure.md) szerint a külön modulok kisebb binárist adnak, és az `@inlinable` primitívek nem lassítanak.

---

## 10. Tesztelési stratégia

### 10.1 Tesztrétegek

| Réteg | Mit ellenőriz | Mikor fut |
|---|---|---|
| **Egységtesztek** | Bitolvasó, Huffman, transzformációk, kernelek | Minden PR, minden platform |
| **Kernel-ekvivalencia** | A SIMD- és skalár-változat bit-pontos egyezése | Minden PR |
| **Konformancia** | 131 WebP-fájl a libwebp tesztkészletéből | Minden PR |
| **Differenciális** | Eredmény a `dwebp`-vel összevetve, véletlen `cwebp`-paraméterekkel | Éjszaka |
| **Oda-vissza** | Saját enkóder → `dwebp` és saját dekóder, pixelre egyezik | Minden PR |
| **Robusztusság** | Csonkolás minden bájtnál, bitforgatások | Minden PR, rövid változat |
| **Fuzzing** | libFuzzer + AddressSanitizer | Éjszaka |
| **Sanitizerek** | ASan, TSan | Minden PR, Linux |
| **Teljesítmény** | Sebesség, allokáció, bináris méret | Minden PR, trendkövetés |

### 10.2 Konformancia minden platformon

A `dwebp` nem fut minden platformon, ezért **golden hash** módszert használunk:

1. Egy eszköz macOS-en vagy Linuxon a rögzített libwebp-verzióval kiszámítja minden tesztkép dekódolt pixeleinek hash-ét.
2. A hash-ek bekerülnek a repóba.
3. Minden platformon csak a saját dekóder fut, és a hash-t hasonlítja össze.

A hash-t a tesztkód tartalmazza, Foundation nélkül, így WebAssemblyn és Androidon is fut.

**A tesztkészlet tartalma** (`libwebp-test-data`):

| Csoport | Fájl |
|---|---:|
| VP8 tesztvektorok (`vp80-*`) | 56 |
| Veszteségmentes vektorok (`lossless_vec_*`) | 32 |
| Alpha-változatok | 17 |
| Egyéb élesetek | 26 |
| **Összesen** | **131** |

A készletből 96 fájlhoz saját referencia-MD5 is tartozik. A szándékosan hibás fájloknál az elvárt eredmény a tiszta hibajelzés.

A készlet repójában nincs licencfájl, ezért **nem másoljuk be**. A CI egy rögzített commitról tölti le. A repóba csak saját készítésű, kis tesztfájlok kerülnek.

### 10.3 Platformmátrix

| Platform | Architektúra | Build | Tesztek futnak | Hol |
|---|---|:-:|:-:|---|
| macOS | arm64 | Igen | Igen | Helyben és CI |
| iOS Simulator | arm64 | Igen | Igen | Helyben és CI |
| tvOS, watchOS, visionOS | arm64 | Igen | Csak build | CI |
| Linux (Ubuntu) | x86-64 | Igen | Igen | CI |
| Linux (Ubuntu) | aarch64 | Igen | Igen | Helyben (Docker) és CI |
| Linux statikus SDK (musl) | x86-64 | Igen | Csak build | CI |
| Windows | x86-64 | Igen | Igen | CI |
| Android | aarch64, x86-64 | Igen | Cél, az első CI-futás igazolja | CI |
| WebAssembly (WASI) | wasm32 | Igen | Igen | Helyben (Docker) és CI |

A 32 bites viselkedést a WebAssembly fedi le, ezért ott a tesztek futtatása kiemelten fontos.

### 10.4 Fuzzing

- **Eszköz:** libFuzzer, Linuxon, AddressSanitizerrel.
- **Célok:** konténer, VP8L, VP8, ALPH, animáció és a teljes dekóder.
- **Struktúra-tudatos fuzzing:** külön generátor készít érvényes VP8L-fejlécet szándékosan hibás Huffman-kódokkal. A CVE-2023-4863-at a sima mutációs fuzzing éppen azért nem találta meg, mert több feltételnek kell egyszerre teljesülnie.
- **Korpusz:** a talált érdekes bemenetek regressziós tesztté válnak.
- **Hosszú táv:** jelentkezés az OSS-Fuzz programba, amely támogatja a Swift-projekteket.

---

## 11. CI/CD

A CI alapja a hivatalos `swiftlang/github-workflows` újrahasznosítható workflow Linuxra, Windowsra, Androidra és a statikus Linux SDK-ra. Az Apple-platformok és a WebAssembly saját jobot kapnak, mert a hivatalos macOS- és iOS-jobok saját futtatókat igényelnek.

| Workflow | Trigger | Feladat |
|---|---|---|
| `ci.yml` | PR, push | Build és teszt a teljes mátrixon |
| `quality.yml` | PR | `swift format lint`, API-törés figyelés, dokumentáció-build |
| `sanitizers.yml` | PR | ASan, TSan |
| `performance.yml` | PR | Benchmark, az M2-től binárisméret-ellenőrzés is |
| `fuzz.yml` | Éjszaka | Fuzzing, a korpusz gyorsítótárazása |
| `differential.yml` | Éjszaka, az M2-től | Összevetés a legfrissebb libwebp-vel |
| `release.yml` | Tag, az első kiadástól | Ellenőrzés és kiadási jegyzet |

**Kötelező a merge-hez:** build és teszt minden platformon, formázás, sanitizerek, nincs nem szándékos API-törés (`swift package diagnose-api-breaking-changes`).

A workflow-kat commit-hash-re rögzítjük, így külső változás nem törheti el váratlanul a CI-t.

---

## 12. Teljesítmény-munkafolyamat

1. **Először mérünk.** Optimalizálás csak benchmarkkal alátámasztva kerül be.
2. **Korpusz.** Fotó, grafika, képernyőkép, átlátszó kép és animáció, több méretben, szabad licencű forrásokból. A korpusz a repón kívül él, a letöltő szkript rögzített hash-ekkel ellenőrzi.
3. **Eszköz.** A `package-benchmark` a különálló `Benchmarks` csomagban.
4. **Metrikák.** Mpx/s, utasításszám, csúcsmemória, allokációszám, bináris méret.
5. **CI-regresszió.** A felhős gépek zajosak, ezért a CI az **utasításszámot** figyeli macOS-en, mert Linux-konténerben ez a metrika nem érhető el ([ADR 0002](adr/0002-verification-tooling.md)). A falióra-időt a referenciagépen, kiadás előtt mérjük.
6. **Küszöbök.** 3% feletti utasításszám-romlás vagy 5% feletti binárisméret-növekedés magyarázatot igényel a PR-ben.
7. **Eredmények.** Minden kiadás mérései a `docs/performance/` mappába kerülnek, összevetve a libwebp-vel.

---

## 13. Fejlesztői élmény és terjesztés

### Hogyan használják a fejlesztők?

```swift
// Package.swift
.package(url: "https://github.com/BZsombor/swift-raster-webp.git", from: "1.0.0")

// Csak dekóder
.product(name: "RasterWebPDecoder", package: "swift-raster-webp")

// Dekóder és enkóder
.product(name: "RasterWebP", package: "swift-raster-webp")
```

### Dokumentáció

- **README:** 30 másodperces bevezető, telepítés, példa, platformtáblázat, teljesítményadatok.
- **DocC:** minden publikus API dokumentált, a Swift Package Index hosztolja.
- **Útmutatók:** dekódolás, animáció, memóriakezelés, biztonságos beállítások, migráció libwebp-burkolókról.
- **Példák:** parancssori `webpinfo`-szerű eszköz, SwiftUI-alkalmazás, szerveroldali konverzió, WebAssembly-demó.

### Közzététel

- Swift Package Index regisztráció, a platformkompatibilitási jelvényekkel.
- Bejelentés a Swift Forums „Related Projects” kategóriában az első használható verziónál (M2).
- Benchmark-összevetés publikálása a libwebp-vel, a módszertannal együtt.

---

## 14. Verziózás és közösség

### Verziózás

- **Szemantikus verziózás.** A 0.x verziókban az API még változhat, az 1.0-tól stabil.
- **Kiadási terv:** minden mérföldkő egy 0.x kiadás.
- **Swift-támogatás:** az aktuális és az előző két fő Swift-verzió. A minimum emelése minor verziót igényel.
- **Változásnapló:** `CHANGELOG.md`, Keep a Changelog formátumban.

### Hozzájárulás

- **`CONTRIBUTING.md`:** fejlesztői környezet, tesztelés, teljesítményszabályok.
- **PR-követelmények:** tesztek, benchmark a forró kódhoz, dokumentáció a publikus API-hoz.
- **ADR-ek:** a jelentős technikai döntések a `docs/adr/` mappába kerülnek.
- **`SECURITY.md`:** privát hibajelentés GitHub Security Advisory-n keresztül.
- **Kezdőknek szóló feladatok:** `good first issue` címkével.
- **Licenc:** a hozzájárulások az Apache-2.0 feltételei szerint kerülnek be, külön CLA nélkül.

---

## 15. Jogi kérdések

| Téma | Helyzet | Teendő |
|---|---|---|
| Saját kód | Apache-2.0 | `LICENSE` a repó gyökerében |
| Más implementációk (libwebp, `image-webp`) | Saját licenceik | Csak referenciák, kódot nem másolunk és nem portolunk belőlük |
| Táblák és konstansok | Az RFC-kből származnak | Forrásmegjelölés a kódban |
| VP8 szabadalmak | A Google jogdíjmentes licencet ad a saját WebM-implementációira | Az M3 előtt érdemes pontosan átnézni a feltételeket egy független implementációra nézve |
| Tesztadatok | A `libwebp-test-data` licence nem egyértelmű | Nem terjesztjük, csak letöltjük a CI-ban |
| Benchmark-korpusz | Csak szabad licencű képek | Forrás és licenc dokumentálása |
| A „Raster” név | A Swift Package Indexen már létezik `Raster` nevű csomag (`alexito4/Raster`, SwiftUI-renderelés) | Lásd K3 |

Ez a fejezet műszaki összefoglaló, nem jogi tanács.

---

## 16. Mérföldkövek

A méret relatív becslés (S, M, L, XL). A mérföldköveknek nincs határidejük, akkor zárulnak, ha minden teljesítési feltételük teljesül.

### M1 – Alapok

**Méret: M** · **Kiadás: 0.1.0**

- Csomagszerkezet, licenc, README, formázás, CI a teljes mátrixon.
- RIFF-parser és `WebPImageInfo`.
- Golden hash-eszköz, korpusz-letöltő, benchmark- és fuzz-keretrendszer.
- Validáló prototípusok: modulfelosztás, x86-64 és WebAssembly mérések, a `Span` költsége fordítóverziónként, a benchmark-eszköz utasításszám-mérése a CI-ban, a tesztfuttatás igazolása Androidon és WebAssemblyn.

**Kész, ha:**

- [x] A CI minden platformon zöld.
- [x] A parser a teljes tesztkészlet metaadatait helyesen olvassa, a `webpinfo`-val összevetve.
- [x] A csonkolási és bitforgatási tesztek átmennek.
- [x] Az ADR-ek rögzítik a validáló prototípusok eredményét.

Az x86-64-es és a WebAssembly-teljesítmény mérése az M2-re marad, mert addig nincs mérhető dekóder-kód.

### M2 – VP8L dekóder

**Méret: L** · **Kiadás: 0.2.0**

- Bitolvasó, Huffman, color cache, LZ77, négy transzformáció.
- Pixelformátumok és alpha-kezelés.
- Publikus dekódolási API első változata.

**Kész, ha:**

- [ ] A 32 `lossless_vec` és a többi veszteségmentes fájl pixelre egyezik.
- [ ] A sebesség eléri a libwebp 50%-át.
- [ ] A VP8L-fuzzer 24 órát fut hiba nélkül.
- [ ] Az első publikus bejelentés elkészül.

### M3 – VP8 dekóder és alpha

**Méret: XL** · **Kiadás: 0.3.0**

- Bool decoder, fejlécek, predikció, IDCT, loop filter.
- Soronkénti pipeline, fancy upsampling, YUV-konverzió.
- ALPH-chunk, alpha-szűrők.
- Az első SIMD-kernelek mérés alapján.

**Kész, ha:**

- [ ] Az 56 `vp80` vektor és az alpha-fájlok bit-pontosan egyeznek a `dwebp` kimenetével.
- [ ] A sebesség eléri a libwebp 50%-át.
- [ ] A memóriahasználat megfelel a [3.3 fejezetnek](#33-memória).

### M4 – Kiterjesztett funkciók

**Méret: M** · **Kiadás: 0.4.0**

- Animáció dekódolása, kompozíció.
- ICC, EXIF, XMP olvasása.
- Erőforrás-korlátok teljes körű érvényesítése.

**Kész, ha:**

- [ ] Az animációk képkockánként egyeznek a libwebp `anim_decode` kimenetével.
- [ ] A teljes tesztkészlet átmegy minden platformon.
- [ ] A hibás animációkra vonatkozó fuzzing tiszta.

### M5 – VP8L enkóder és 1.0

**Méret: L** · **Kiadás: 0.5.0, 1.0.0-rc, 1.0.0**

- Veszteségmentes enkóder három erőfeszítési szinttel.
- Metaadatok írása.
- Foundation- és CoreGraphics-integráció.
- Teljesítményhangolás a 70%-os célig.
- API-felülvizsgálat, teljes dokumentáció, biztonsági audit.

**Kész, ha:**

- [ ] Minden enkóder-kimenet érvényes a `dwebp` szerint, és pixelre visszaáll.
- [ ] Minden [3. fejezetbeli](#3-mérhető-célok) cél teljesül.
- [ ] Legalább egy külső projekt kipróbálta az RC-t.
- [ ] A publikus API dokumentációja teljes.

### M6 – 1.0 után

**Méret: XL**

- Veszteséges enkóder.
- Animáció kódolása.
- Inkrementális dekódolás.
- Opcionális többszálúság, ha a mérések indokolják.
- Beépítés a `raster` könyvtárba.

---

## 17. Kockázatok

| Kockázat | Valószínűség | Hatás | Kezelés |
|---|---|---|---|
| A Swift-kód nem éri el a sebességcélt | Közepes | Magas | Korai mérések, háromszintű SIMD, célok felülvizsgálata M2 után |
| A `_Builtin_intrinsics` modul változik | Közepes | Közepes | Izolált kernelek, mindig működő skalár fallback |
| Fordítóverziók közti teljesítménykülönbség | Magas | Közepes | Benchmark több Swift-verzión, a minimum verzió megfontolt megválasztása |
| Memóriahiba az `unsafe` kernelekben | Alacsony | Magas | Kevés `unsafe`, audit, sanitizerek, fuzzing |
| Android vagy WebAssembly tesztfuttatás akadozik | Közepes | Közepes | M1-ben igazoljuk, tartalék: külön tesztfuttató program |
| Bit-pontossági eltérések a libwebp-től | Közepes | Közepes | Azonos képletek, köztes YUV-összevetés a hibakereséshez |
| A VP8 mérete elhúzza a projektet | Közepes | Közepes | A VP8L már önmagában kiadható érték, részkiadások |
| Az API túl korán merevedik be | Alacsony | Közepes | 0.x szakasz, RC-időszak, korai felhasználók |
| Egyszemélyes fenntartás | Magas | Magas | Jó dokumentáció, ADR-ek, automatizálás, korai közösségépítés |

---

## 18. Nyitott kérdések

Mind a hat kérdést 2026-11-18-án lezártuk.

### K1 – Megengedjük-e a natív SIMD-intrinsiceket?

A NEON a mérésben **3,5–3,7-szeres** gyorsulást adott a skalárhoz képest, a hordozható `SIMD` csak 1,4-szereset. Az intrinsicek a `_Builtin_intrinsics` modulból jönnek: a repóban nem lesz C-kód, de ez a modul nem hivatalosan stabil.

**Döntés:** igen, szigorúan izolált kernelekben, csak ott, ahol a sebességcél másképp nem érhető el, és mindig működő skalár fallbackkel.

### K2 – Mi legyen a minimum Swift-verzió?

**Döntés: Swift 6.3.** Ebben jelent meg az `@inline(always)` és az első hivatalos Android SDK, a jelenlegi 6.4 mellett pedig ez az előző fő verzió. A Swift 6.2 típusellenőrzője ráadásul a prototípus több összetett kifejezését sem tudta lefordítani.

### K3 – Milyen GitHub-fiók és név alatt induljon?

A `swift-raster-webp` névvel nem találtam ütközést, de a Swift Package Indexen már van `Raster` nevű csomag, ami a későbbi fő könyvtárnál zavart vagy modulnév-ütközést okozhat.

**Döntés:** a repó a személyes fiók alatt indul: `github.com/BZsombor/swift-raster-webp`. A modulok neve `RasterWebP…`. A fő könyvtár modulnevét a `raster` indulásakor döntjük el. Ha később több repó vagy több karbantartó lesz, a repó átköltöztethető egy szervezethez.

### K4 – Mikor jöjjön a veszteséges enkóder?

Az `image-webp` `main` ágán már van ilyen, tehát a Rust-paritáshoz később szükség lesz rá.

**Döntés:** maradjon az 1.0 után, mert jóval nagyobb munka, mint a dekóderek, és az 1.0-t jelentősen késleltetné.

### K5 – Legyen-e naptári ütemterv?

**Döntés:** nem. A projektnek nincs időkerete és határideje, a mérföldkövek sorrendben, a teljesítési feltételeik alapján zárulnak.

### K6 – Milyen nyelvű legyen a projekt dokumentációja?

**Döntés:** a publikus anyagok (README, DocC, kódkommentek, issue-k) angolul, hogy a nemzetközi közösség is használhassa. Ez a terv a közös munkához maradhat magyarul.

---

## 19. Források

**Specifikációk**

- [RFC 9649 – WebP Image Format](https://www.rfc-editor.org/rfc/rfc9649.html)
- [RFC 6386 – VP8 Data Format and Decoding Guide](https://www.rfc-editor.org/rfc/rfc6386.html)

**Referencia-implementációk és tesztadatok**

- [libwebp](https://chromium.googlesource.com/webm/libwebp)
- [libwebp-test-data](https://chromium.googlesource.com/webm/libwebp-test-data)
- [image-webp (Rust)](https://github.com/image-rs/image-webp)

**Swift**

- [SE-0447 – Span](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md)
- [SE-0450 – Package traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)
- [SE-0496 – @inline(always)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0496-inline-always.md)
- [Swift hivatalos CI-workflow-k](https://github.com/swiftlang/github-workflows)
- [Swift SDK for Android](https://www.swift.org/blog/exploring-the-swift-sdk-for-android/)
- [libFuzzer-integráció Swiftben](https://github.com/swiftlang/swift/blob/main/docs/libFuzzerIntegration.md)
- [OSS-Fuzz Swift-útmutató](https://google.github.io/oss-fuzz/getting-started/new-project-guide/swift-lang/)
- [package-benchmark](https://github.com/ordo-one/package-benchmark)

**Biztonság és jog**

- [The WebP 0day – a CVE-2023-4863 elemzése](https://blog.isosceles.com/the-webp-0day/)
- [WebM szabadalmi licenc](https://www.webmproject.org/license/additional/)
