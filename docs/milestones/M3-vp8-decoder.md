# M3 – VP8 dekóder és alfa-csatorna: részletes terv

| | |
|---|---|
| **Cél** | Veszteséges WebP-képek dekódolása tiszta Swiftben, átlátszósággal együtt |
| **Kiadás** | 0.3.0 |
| **Állapot** | Kiadva 0.3.0 verzióként 2026-11-21-én, a négy fuzzer 24 órás hibamentes futása után |
| **Normatív források** | RFC 6386 (VP8), RFC 9649 2.7.1.2 (ALPH) |
| **Alapszabály** | A kód a szabványból készül, más könyvtárakból nem veszünk át kódot ([ADR 0003](../adr/0003-implementation-sources.md)) |

Ez a projekt legnagyobb mérföldköve. A VP8 kulcskép-dekódolása körülbelül fele akkora munka, mint az egész eddigi projekt, ezért a munkát ellenőrizhető szakaszokra bontjuk ([12. fejezet](#12-megvalósítási-sorrend)).

## 1. Hatókör

**Benne van:**

- Egyszerű (`VP8 `) és kiterjesztett (`VP8X` + `ALPH` + `VP8 `) állóképek.
- A VP8 kulcsképek teljes dekódolása: szegmensek, mindkét loop filter, több token-partíció, minden predikciós mód.
- Az `ALPH` chunk minden változata: tömörítetlen és VP8L-tömörítésű adat, mind a négy szűrő.
- A meglévő kimeneti formátumok, alfa-módok, korlátok és a hívó pufferébe dekódolás.

**Nincs benne:**

- VP8 interframe-ek. A WebP csak kulcsképet használ, ezért ezeket hibaként jelezzük.
- Animáció (M4) és inkrementális dekódolás.
- Dithering. A libwebp alapértelmezésben sem használja.

## 2. Kész-feltételek

- [x] A libwebp-készlet mind a 88 veszteséges fájlja pixelre egyezik a `dwebp` kimenetével, a 18 alfás is.
- [x] Az 56 `vp80` tesztvektor YUV-síkjai bitre egyeznek a `dwebp -yuv` kimenetével. *(Mind a 88 veszteséges fájlé egyezik.)*
- [x] A véletlen paraméterekkel készített `cwebp`-fájlok pixelre egyeznek a `dwebp` kimenetével. *(4400 kép, ebből kb. 2200 veszteséges, 0 eltérés.)*
- [x] Minden hibás bemenetre hibát ad vagy érvényes képet, összeomlás nélkül.
- [x] A fuzzerek, köztük egy új, VP8-ra szabott fuzzer, a teszt ideje alatt nem találnak hibát.
- [x] Az ASan és TSan futások tiszták.
- [x] A sebesség eléri a libwebp 50%-át: q75-ön legalább 75 Mpx/s, q90-en legalább 50 Mpx/s. *(Mért érték: 104 és 75 Mpx/s, a libwebp 71 és 78%-a.)*
- [x] A munkamemória a képszélességgel arányos, nem a képterülettel. *(Egy 24 Mpx-es képnél kb. 7 MB, alfával is.)*
- [x] A dekóder teljes mérete a 400 KB-os kereten belül marad. *(Mért érték: 200 KB a konténerrel együtt.)*
- [x] A CI minden platformon zöld. *(macOS, iOS, tvOS, watchOS, visionOS, Linux, Windows, Android és WebAssembly.)*

## 3. Források és jogi háttér

### 3.1 Mit tekintünk szabványnak

Az RFC 6386 szerint a bitfolyamot a csatolt referencia-forráskód határozza meg, és ellentmondás esetén a kód számít helyesnek. Ezért:

- **A prózából és a táblázatokból implementálunk.** Ezek írják le az algoritmusokat C-szerű részletekkel.
- **A csatolt referenciakódot csak ellentmondás vagy kétértelműség feloldására olvassuk.** Nem portoljuk, mert BSD-licencű, és az ADR 0003 is tiltja az implementációk átvételét.
- **A táblázatokat szkript emeli ki az RFC szövegéből**, ahogy az M2 távolságtábláját is. Egy elgépelést a konformancia-tesztek azonnal kimutatnak.

### 3.2 Színkonverzió és felskálázás

Egyik RFC sem írja elő, hogyan lesz a YUV-ból RGB, és hogyan nő a fél felbontású színinformáció teljes felbontásúvá. Ezért:

- **Színkonverzió:** a BT.601 szabvány együtthatóiból, fixpontos aritmetikával számolunk. A pontosságot úgy választjuk meg, hogy az eredmény bitre egyezzen a `dwebp`-vel, és ezt a tesztek ellenőrzik.
- **Felskálázás:** a széles körben használt bilineáris „fancy” felskálázás, amely a `dwebp` alapértelmezése is.
- **Ez az ADR 0003 kompatibilitási szabálya:** a megfigyelhető kimenet egyezik, a kódot önállóan írjuk.
- **Levezetés:** az együtthatók és az eltolások eredetét az [ADR 0004](../adr/0004-yuv-to-rgb-conversion.md) rögzíti, az RFC belső ellentmondásait pedig az [ADR 0005](../adr/0005-rfc-6386-discrepancies.md).

### 3.3 Szabadalmak

| Forrás | Tartalom |
|---|---|
| Google IETF-nyilatkozata (2011) | Jogdíjmentes licenc minden implementálónak, feltételek nélkül |
| VP8 Patent Cross-License | Jogdíjmentes licenc az RFC 6386 szerinti VP8-ra, független implementációkra is. Csak elfogadással érvényes, és kölcsönös licencet kér |
| Google és az MPEG LA megállapodása (2013) | 11 szabadalomtulajdonos jogait a Google továbbadhatja a VP8 felhasználóinak, a független implementációknak is |

Ez műszaki összefoglaló, nem jogi tanács. A cross-license elfogadásáról lásd a K1 kérdést.

## 4. Publikus API

Az API nem változik. A veszteséges és az alfás képek eddig `unsupportedFeature` hibát adtak, mostantól dekódolhatók. A `WebPError` új részletes okokat kap a VP8-hibákra.

## 5. Modulok és fájlok

```text
Sources/RasterWebPDecoder/
├── Lossy/
│   ├── BoolDecoder.swift          Aritmetikai dekóder, RFC 6386 7. fejezet
│   ├── FrameHeader.swift          Kulcskép-fejléc, szegmensek, szűrő, kvantálás
│   ├── VP8Constants.swift         Kis rögzített értékek: módok, sávok, cikcakk-sorrend
│   ├── VP8Tables.swift            Az RFC-ből szkripttel kiemelt táblázatok
│   ├── LossyDecoder.swift         Partíciók, módok, tokenek, soronkénti pipeline
│   ├── Transforms.swift           Inverz WHT és DCT
│   ├── Prediction.swift           16x16, 4x4 és színpredikció
│   ├── LoopFilter.swift           Egyszerű és normál szűrő, skalár változat
│   └── LoopFilter+Vectors.swift   Ugyanez 16 szegmensre egyszerre, SIMD-del
├── Alpha/
│   └── AlphaDecoder.swift         ALPH chunk, szűrők, VP8L-alapú dekódolás
├── Color/
│   └── YUVConversion.swift        Felskálázás és YUV → RGB
└── Support/
    ├── Span+Vectors.swift         Határ-ellenőrzött vektoros betöltés és tárolás
    └── SIMD+Lanewise.swift        Elágazásmentes minimum, maximum és vágás
```

A megvalósítás közben a tervezett `Partitions`, `MacroblockModes` és `Coefficients` fájlok a `LossyDecoder.swift`-be kerültek, mert ugyanazt az állapotot használják.

## 6. Adatfolyam és memória

```text
bitfolyam → fejléc → makroblokk-sor dekódolása (módok + együtthatók)
          → predikció + inverz transzformáció → szűretlen sor
          → késleltetett loop filter → kész YUV-sorok
          → felskálázás + színkonverzió → kimeneti sorok
```

A memóriaterv kulcsa, hogy **soronként haladunk**:

- **Makroblokk-sorok:** egyszerre csak néhány 16 pixel magas sor van a memóriában. Az intra-predikció a szűretlen szomszédokat használja, a szűrő pedig egy sorral később fut.
- **Kontextusok:** a felső szomszédok módjai és pixelei makroblokkonként tárolódnak, a méretük a szélességgel arányos.
- **Kimenet:** a színkonverzió a kész sorokat egyenesen a kimeneti pufferbe írja.
- **Alfa helyben:** négybájtos kimenetnél az alfa-síkot a VP8L-dekóder magába a kimeneti pufferbe dekódolja, majd a csatornát a helyére mozgatjuk. Utána a VP8 csak a színcsatornákat írja, így az alfa nem igényel külön teljes méretű puffert.

## 7. Komponensek

### 7.1 Bool decoder (RFC 6386, 7. fejezet)

- 64 bites ablak, nagy blokkokban utántöltve.
- A normalizálás `leadingZeroBitCount` alapú, nem bitenkénti ciklus.
- A bitfolyam végét makroblokkonként ellenőrizzük, nem minden bitnél. A végén virtuális nullabitek jönnek, ahogy a VP8L-bitolvasónál.

### 7.2 Fejléc és partíciók (9. fejezet)

- A keretcímke, a kezdőkód és a méretek ellenőrzése a Core-ban már megvan.
- Az első partícióból: színtér, clamping, szegmensek, szűrő, partíciószám, kvantálási indexek, valószínűség-frissítések, skip-valószínűség.
- A token-partíciók méreteit a chunk határain belül ellenőrizzük.
- A felskálázási bitek csak tájékoztató jellegűek, ezeket figyelmen kívül hagyjuk.

### 7.3 Makroblokk-fejléc és módok (11. fejezet)

- Szegmensazonosító, skip-jelzés, 16x16-os luma-mód vagy 16 darab 4x4-es al-mód, színmód.
- A 4x4-es módok valószínűsége a felső és a bal szomszéd módjától függ. Ezt sorpufferben és egy 4 elemű bal oldali kontextusban tartjuk.

### 7.4 Együtthatók (13. fejezet)

- Token-fa dekódolás sáv, kontextus és pozíció szerinti valószínűségekkel.
- A nulla utáni tokennél nincs blokkvég-ellenőrzés, ahogy a szabvány előírja.
- A kiegészítő bitek kategóriánkénti valószínűségekkel jönnek.
- Blokkonként jelöljük, hány nem nulla együttható van. Ebből választjuk ki a megfelelő inverz transzformációt.

### 7.5 Dekvantálás és inverz transzformációk (14. fejezet)

- Szegmensenként előre kiszámolt szorzók.
- Inverz WHT a 16x16-os módok DC-együtthatóihoz.
- Inverz DCT két változatban: csak DC és teljes. Mindegyik bitre egyezik a szabvánnyal. A kevés együtthatós változatra a vektoros teljes transzformáció mellett nem volt szükség.

### 7.6 Predikció (12. fejezet)

- 16x16: DC, V, H, TM. 4x4: tíz mód. Szín 8x8: DC, V, H, TM.
- A kép szélén a szabvány rögzített határértékeit (127 és 129) használjuk.
- A 4x4-es blokkok a jobb felső szomszéd pixeleit a sor feletti makroblokkból veszik, a szabvány külön szabálya szerint.
- A munkaterület egy kis, SIMD-barát blokk, amelyben a szomszédok is helyet kapnak.

### 7.7 Loop filter (15. fejezet)

- Egyszerű és normál szűrő, makroblokk- és belső élekre.
- Szegmensenként és módonként előre kiszámolt erősségek és küszöbök.
- A kihagyott, együttható nélküli makroblokkok belső éleit nem szűrjük, ahogy a szabvány előírja.
- Nulla erősségnél a szűrőt teljesen kihagyjuk.

### 7.8 Színkonverzió és felskálázás

- Két egymást követő színsorból számolunk egy-egy kimeneti sorpárt, a kép szélein a szélső értékeket ismételve.
- A pixelformátum-kezelés és a premultiplikáció ugyanaz, mint az M2-ben.

### 7.9 Alfa (RFC 9649, 2.7.1.2)

- **Tömörítetlen adat:** a bájtok közvetlenül az alfa-síkba kerülnek.
- **VP8L-tömörítés:** a meglévő dekóder fejléc nélküli módja dekódolja, és a zöld csatornát használjuk.
- **Szűrők:** vízszintes, függőleges és gradiens szűrő a szabvány határszabályaival.
- **Előfeldolgozási bitek:** csak tájékoztató jellegűek, a dekódolásra nincsenek hatással.

## 8. Táblázatok

| Táblázat | RFC 6386 fejezet | Méret |
|---|---|---|
| Alapértelmezett együttható-valószínűségek | 13.5 | 4 × 8 × 3 × 11 |
| Együttható-frissítési valószínűségek | 13.4 | 4 × 8 × 3 × 11 |
| Kulcskép luma- és színmód-valószínűségek | 11.2, 11.4 | kicsi |
| 4x4-es mód valószínűségei szomszédonként | 11.5 | 10 × 10 × 9 |
| DC- és AC-kvantálási táblák | 14.1 | 2 × 128 |
| Fák, sávok, cikcakk-sorrend, kiegészítő bitek | 8, 13 | kicsi |

Mindegyik egy-egy szkripttel kerül ki az RFC szövegéből, generált Swift-fájlba, forrásmegjelöléssel.

## 9. Biztonsági invariánsok

1. A partíciók mérete és a makroblokkok száma a fejléc alapján, allokáció előtt ellenőrzött.
2. A bool decoder soha nem olvas a partíciója végén túl. A túlolvasott biteket számoljuk, és a sor végén hibát jelzünk.
3. Minden táblaindex a valószínűségi és kvantálási táblák határain belül marad, ezt korlátozott indexek garantálják.
4. A predikció és a szűrő csak a munkaterület határain belül dolgozik, a kép szélein rögzített határértékekkel.
5. A méretszámítások túlcsordulás-ellenőrzöttek, 32 bites platformon is.

## 10. Tesztterv

| Réteg | Tartalom |
|---|---|
| Egységtesztek | Bool decoder saját bool kódolóval, táblák alakja, fák |
| Transzformációk | WHT és DCT összevetése a szabvány egyszerű, külön megírt változatával |
| Predikció és szűrő | Minden mód és szűrőtípus, a széleken is |
| YUV-konformancia | Síkonkénti hash a `dwebp -yuv` kimenetéből, így a VP8-mag hibái elkülönülnek a színkonverzióétól |
| RGBA-konformancia | Pixel-hash a teljes veszteséges készletre |
| Alfa | Mind a négy szűrő, mindkét tömörítés, saját generált fájlokkal |
| Differenciális | Véletlen képek, a `-q`, `-m`, `-sns`, `-f`, `-sharpness`, `-strong`, `-segments` és `-alpha_*` kapcsolók véletlen értékeivel |
| Robusztusság | Csonkolás, bitforgatás, véletlen mutációk |
| Fuzzing | A meglévő dekóder-fuzzer, plusz egy új VP8-fuzzer, amely saját bool kódolóval érvényes fejléceket és mélyre jutó adatokat készít |

A mért sorlefedettség a teljes tesztkészlettel: a dekóder fájljai 98,7–100%-osak, a projektterv 90%-os célja felett.

## 11. Teljesítményterv

| Kép | libwebp (mért, NEON-nal) | M3 belépő cél (50%) | Elért |
|---|---:|---:|---:|
| q75 | 149 Mpx/s | 75 Mpx/s | 104 Mpx/s (71%) |
| q90 | 99 Mpx/s | 50 Mpx/s | 75 Mpx/s (78%) |

- A libwebp itt erősen használ NEON-utasításokat, ezért ez nehezebb cél, mint a VP8L volt.
- Először skalár kód készül bounds-checkelt hozzáféréssel, utána profil alapján optimalizálunk.
- Natív SIMD csak az elfogadott szabály szerint jöhet: elkülönített fájlban, skalár tartalékkal, és csak ha a mérés indokolja. A valószínű jelöltek az inverz DCT, a loop filter, a predikció és a színkonverzió.
- **Eredmény:** natív SIMD-re nem volt szükség. A célt a standard könyvtár hordozható SIMD-típusai bőven elérték. A lépéseket és a tanulságokat a [teljesítmény-dokumentum](../performance/m3-vp8-decoder.md) rögzíti.

## 12. Megvalósítási sorrend

Minden szakasz végén van egy ellenőrizhető pont, így a hibák nem halmozódnak.

| Szakasz | Tartalom | Ellenőrzés |
|---|---|---|
| 1 | Táblák kiemelése, bool decoder, fejléc | A tesztvektorok fejlécei helyesen olvashatók |
| 2 | Módok, együtthatók, dekvantálás, transzformációk, predikció | Szűrő nélkül bitre egyezik a `dwebp -nofilter -yuv` kimenetével |
| 3 | Loop filter | Bitre egyezik a `dwebp -yuv` kimenetével |
| 4 | Felskálázás és színkonverzió, soronkénti pipeline | RGBA-konformancia |
| 5 | Alfa | Az alfás fájlok konformanciája |
| 6 | Robusztusság, fuzzerek, differenciális teszt | Hibamentes futás |
| 7 | Mérés és optimalizálás | A sebességcélok |
| 8 | Dokumentáció és teljes ellenőrzés | Minden kész-feltétel |

## 13. Kockázatok

| Kockázat | Kezelés |
|---|---|
| A skalár Swift nem éri el a 75 Mpx/s-ot | Profil alapú optimalizálás, utána célzott NEON/SSE2-kernelek |
| Elgépelés a nagy táblázatokban | Szkriptes kiemelés az RFC-ből, YUV-szintű konformancia |
| A színkonverzió nem bitre egyezik | A YUV-szintű teszt elkülöníti, a pontosságot mérés alapján hangoljuk |
| A szabvány prózája és kódja eltér | Ilyenkor a referenciakód viselkedését követjük, saját kóddal, és rögzítjük az ADR-ben |
| Bonyolult soronkénti pipeline | A 2–3. szakaszban egyszerűbb, teljes képes változat készül, és csak az egyezés után térünk át a soronkéntire |

## 14. Döntések

A négy kérdésben 2026-11-19-én elfogadtuk a javaslatokat.

### K1 – Elfogadod-e a VP8 Patent Cross-License-et?

A fejlesztéshez nem szükséges, és a Google IETF-nyilatkozata feltétel nélküli jogdíjmentes licencet ígér. A cross-license a projekt tulajdonosának és a felhasználóknak is kifejezett, jogilag erősebb védelmet adna, cserébe kölcsönös licencet kér.

**Döntés:** a kódolást ez nem akadályozza. Az 1.0 előtt döntünk róla, szükség esetén jogi tanácsadóval.

### K2 – Hogyan használjuk az RFC 6386 csatolt referenciakódját?

**Döntés:** csak ellentmondás feloldására olvassuk, nem portoljuk, ahogy a 3.1 fejezet leírja.

### K3 – Pontosan a `dwebp`-vel egyező színkonverziót célozzunk?

**Döntés:** igen. Így minden veszteséges fájl bitre ellenőrizhető. Egy gyorsabb, de eltérő kimenetű mód később opcióként jöhet.

### K4 – Hol készüljön az M3?

**Döntés:** külön ágon (`m3-vp8-decoder`), hogy a `main` a 0.2.0 kiadásig és utána is kiadható maradjon. Az M3 pull requesttel kerül a `main`-be, amikor minden kész-feltétel teljesül.
