# M2 – VP8L dekóder: részletes terv

| | |
|---|---|
| **Cél** | Veszteségmentes WebP-képek dekódolása tiszta Swiftben |
| **Kiadás** | 0.2.0 |
| **Állapot** | Helyben kész, az első CI-futásra vár |
| **Normatív forrás** | RFC 9649, 3. fejezet |
| **Alapszabály** | A kód a szabványból készül, más könyvtárakból nem veszünk át kódot ([ADR 0003](../adr/0003-implementation-sources.md)) |

## 1. Hatókör

**Benne van:**

- Egyszerű (`VP8L`) és kiterjesztett (`VP8X` + `VP8L`) állóképek dekódolása.
- Mind a négy transzformáció, a color cache, az LZ77 és a meta prefix kódok.
- Kimeneti formátumok: RGBA8, BGRA8, RGB8, BGR8, egyenes és premultiplied alfával.
- Dekódolás saját tömbbe vagy a hívó pufferébe.
- Erőforrás-korlátok.

**Nincs benne:** VP8 (M3), ALPH (M3), animáció (M4), inkrementális dekódolás. Ezekre a dekóder egyértelmű `unsupportedFeature` hibát ad.

## 2. Kész-feltételek

- [x] A libwebp-készlet minden veszteségmentes fájlja pixelre egyezik a `dwebp` kimenetével.
- [x] A véletlen paraméterekkel készített `cwebp`-fájlok pixelre egyeznek a `dwebp` kimenetével.
- [x] Minden hibás bemenetre hibát ad vagy érvényes képet, összeomlás nélkül.
- [x] A fuzzerek a teszt ideje alatt nem találnak hibát.
- [x] Az ASan és TSan futások tiszták.
- [x] A sebesség eléri a libwebp 50%-át a referenciaképen, vagyis legalább 37 Mpx/s.
- [x] A dekóder bináris mérete rögzítve van, és a 400 KB-os kereten belül marad.
- [ ] A CI minden platformon zöld.

## 3. Publikus API

```swift
// Egyszerű dekódolás
let image = try WebPDecoder.decode(bytes)

// Beállításokkal
var options = WebPDecodingOptions()
options.pixelFormat = .bgra8
options.alphaMode = .premultiplied
options.limits.maximumPixelCount = 50_000_000
let image = try WebPDecoder.decode(bytes, options: options)

// A hívó pufferébe, tömb-allokáció nélkül
let info = try WebPDecoder.decode(span, into: output, bytesPerRow: stride, options: options)
```

| Típus | Feladat |
|---|---|
| `WebPDecoder` | Dekódoló belépési pontok |
| `WebPDecodingOptions` | Pixelformátum, alfa-mód, korlátok |
| `WebPDecodingLimits` | Pixel- és memóriakorlát |
| `WebPPixelFormat` | Bővíthető struct, nem enum |
| `WebPAlphaMode` | Egyenes vagy premultiplied alfa |
| `WebPImage` | Dekódolt kép és elrendezése |

A `WebPError.Kind` három új értéket kap: `unsupportedFeature`, `limitExceeded`, `invalidOutputBuffer`.

## 4. Modulok

```text
RasterWebPCore     Konténer, közös típusok, hibák
      ▲
RasterWebPDecoder  Dekóder
      ▲
RasterWebP         Gyűjtő-termék
```

A `Core` `package` szintű API-val adja át a bitfolyam helyét a dekódernek. A forró ciklusok teljesen a dekóder modulban maradnak.

```text
Sources/RasterWebPDecoder/
├── API/        Publikus típusok és belépési pontok
├── Lossless/   Bitolvasó, prefix kódok, entrópia-dekódolás, transzformációk
└── Color/      Pixelformátum-konverzió és premultiplikáció
```

## 5. Adatfolyam

```text
bájtok → konténer → VP8L fejléc → transzformációk beolvasása
       → color cache és meta prefix kódok → prefix kód csoportok
       → entrópia-dekódolás a pixelpufferbe
       → inverz transzformációk helyben, fordított sorrendben
       → pixelformátum-konverzió helyben
```

**A memóriaterv központi eleme:** négybájtos kimenetnél minden lépés ugyanabban a pufferben fut, ezért nincs teljes méretű munkapéldány. Köztes puffer csak akkor kell, ha a hívó pufferének sortávja vagy igazítása nem teszi lehetővé a helybeni feldolgozást.

## 6. Komponensek

### 6.1 Bitolvasó

- 64 bites ablak, LSB-first olvasás a szabvány szerint.
- Az utántöltés egyetlen 8 bájtos, nem igazított olvasás, ami legalább 56 érvényes bitet garantál.
- Az adat végén bájtonkénti lassú út, majd virtuális nullabitek.
- A csonkolást nem bitenként, hanem soronként és a kép végén ellenőrizzük a túlolvasott bitek számából.

### 6.2 Prefix kódok

- A kódhosszakból kanonikus kód készül, a teljes bináris fa ellenőrzése **a tábla írása előtt** történik.
- Kétszintű keresőtábla: a gyökér legfeljebb 8 bites, a hosszabb kódok másodlagos táblába kerülnek.
- A gyökérméret a kód leghosszabb szavához igazodik, így az egyszimbólumos kód egyetlen bejegyzés.
- Bejegyzés: 32 bit, felső 16 bit szimbólum vagy eltolás, alsó 8 bit kódhossz.
- A csoportok egyetlen lapos táblában élnek.
- A meta képben nem hivatkozott csoportokat ellenőrizzük, de táblát nem építünk nekik.

### 6.3 Entrópia-dekódolás

- A teljes állapot helyi változókban él a forró ciklusban.
- Gyors út arra az esetre, ha a piros, kék és alfa kód egyszimbólumos.
- A prefix csoport csak blokkhatáron frissül.
- A color cache beszúrása késleltetett és kötegelt, a szabvány szerinti sorrendet megtartva.
- A backward reference külön ágakat kap: egy pixel ismétlése, átfedés nélküli másolás, átfedő másolás.

### 6.4 Inverz transzformációk

| Transzformáció | Megvalósítás |
|---|---|
| Predictor | Soronként, blokkonként egy módhoz tartozó ciklus |
| Color | Blokkonként előre kibontott szorzók |
| Subtract green | Vektorizálható ciklus |
| Color indexing | 256 elemű tábla, helybeni kibontás hátulról előre |

A szabvány által nem definiált 14-es és 15-ös prediktor a kompatibilitás miatt fekete előrejelzést ad.

### 6.5 Pixelformátumok

- A belső formátum a szabvány szerinti ARGB `UInt32`.
- BGRA8 little-endian gépen nem igényel munkát.
- RGBA8 csatornacsere, RGB8 és BGR8 előrefelé tömörítés.
- A premultiplikáció pontos, kerekített 255-tel osztás.

## 7. Biztonsági invariánsok

1. Prefix tábla csak érvényes, teljes kódhosszakból épülhet.
2. Backward reference nem mutathat a kép eleje elé, és nem nyúlhat túl a kép végén.
3. Színindex és color cache index mindig a tábla méretén belül marad.
4. Minden méretszámítás túlcsordulás-ellenőrzött, 32 bites platformon is.
5. Az allokációk előtt érvényesülnek a pixel- és memóriakorlátok.
6. A csonkolt bemenet soronként észlelhető, így nem pazarol korlátlan munkát.
7. Minden `unsafe` használat szerepel a [`docs/unsafe-audit.md`](../unsafe-audit.md) fájlban.

## 8. Tesztterv

| Réteg | Tartalom |
|---|---|
| Egységtesztek | Bitolvasó, prefix kód építés, érvénytelen fák, pixelkonverziók |
| Transzformációk | Minden prediktor összevetése a szabvány egyszerű, külön megírt változatával |
| Bitfolyam-tesztek | Kézzel írt VP8L-folyamok a hibás esetekre |
| Konformancia | Pixel-hash a teljes veszteségmentes készletre |
| Differenciális | Véletlen képek, `cwebp`-paraméterek, összevetés a `dwebp`-vel |
| Robusztusság | Csonkolás, bitforgatás, véletlen mutációk |
| Fuzzing | Általános dekóder-fuzzer és struktúra-tudatos VP8L-fuzzer |

## 9. Teljesítményterv

1. Először a helyesség készül el bounds-checkelt `Span` hozzáféréssel.
2. Utána a valódi képeken mérünk, és profil alapján optimalizálunk.
3. Ellenőrzés nélküli hozzáférés csak legalább 3%-os mért nyereségnél kerül be.
4. SIMD csak legalább 20%-os mért nyereségnél kerül be.
5. Az eredmények a [`docs/performance`](../performance/m2-vp8l-decoder.md) mappába kerülnek.

## 10. Megvalósítási sorrend

1. `Core` bővítése, modulok és publikus API.
2. Bitolvasó és prefix kódok, tesztekkel.
3. Entrópia-dekódolás és képszerkezet.
4. Inverz transzformációk.
5. Pixelformátumok és belépési pontok.
6. Konformancia, differenciális és robusztussági tesztek.
7. Fuzzerek.
8. Mérés és optimalizálás.
9. Dokumentáció és teljes ellenőrzés.
