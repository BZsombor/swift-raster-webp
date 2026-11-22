# Bővített összehasonlító mérés: terv

| | |
|---|---|
| **Cél** | A swift-raster-webp összevetése több nyelv WebP-dekódereivel, sebességben, memóriában és más, a fejlesztőknek fontos számokban, diagramokkal |
| **Állapot** | Elfogadva 2026-11-22-én, az 1–4. szakasz megvalósítva. Eredmények: [comparison.md](comparison.md) |
| **Alapszabály** | Őszinte, reprodukálható mérés. Ha egy versenytárs valamiben jobb nálunk, azt is közöljük |

## 1. Kiket mérünk

A mérésnek csak ott van értelme, ahol **saját implementáció** dolgozik. Ami csak a libwebp-t csomagolja be, az a libwebp-t méri még egyszer, egy kis többletköltséggel.

### 1.1 Első kör

| Könyvtár | Nyelv | Miért érdekes | Megjegyzés |
|---|---|---|---|
| libwebp 1.6.0 | C | A referencia, kézzel írt NEON/SSE kóddal | Már mérjük |
| Apple ImageIO | Objective-C/C | A Swift-fejlesztők legkézenfekvőbb alternatívája | Csak macOS-en, valószínűleg libwebp-alapú |
| image-webp 0.2.4 | Rust | Biztonságos, SIMD nélküli Rust, az `image` crate dekódere | Már mérjük |
| zenwebp | Rust | Az image-webp gyorsított forkja, SIMD-del, saját állítása szerint a libwebp-nél csak kb. 1,4-szer lassabb | Erős versenytárs, a licencét ellenőrizni kell |
| golang.org/x/image/webp | Go | A Go hivatalos kiegészítő könyvtára | Veszteséges képnél YCbCr-t ad vissza, ezt RGBA-ra kell alakítani |
| ImageSharp | C# (.NET) | A legelterjedtebb menedzselt .NET képkönyvtár | A 3.1.12-es verziót mérjük, mert a későbbiek fordításkor kereskedelmi licenckulcsot kérnek |
| jwebp vagy TwelveMonkeys | Java | Tisztán Java dekóderek | A TwelveMonkeys-nek egy fórumbejegyzés szerint színhibái vannak veszteséges képeknél, a jwebp az image-webp Java-portja |

### 1.2 Második kör, ha az első bevált

| Könyvtár | Miért | Mit kell tisztázni |
|---|---|---|
| Wuffs | Memóriabiztos nyelv, C-re fordul, nagyon gyors | Úgy tűnik, csak a veszteségmentes formátumot tudja |
| libwebp WebAssembly-ben (`@jsquash/webp`) | A JavaScript-világ valójában ezt használja | A mi Wasm-buildünkkel ugyanabban a futtatóban, Node.js-ben érdemes összevetni |

### 1.3 Amit kihagyunk, és miért

| Kihagyott | Ok |
|---|---|
| libwebp-burkolók: Pillow, sharp, SDWebImageWebPCoder, Kingfisher, a Rust `webp` crate, webp4j, Imazen.WebP | A libwebp-t mérnék még egyszer |
| Tisztán JavaScriptben írt dekóder | Nincs teljes értékű, a talált egyetlen csak veszteségmentes képet tud |
| Kereskedelmi könyvtárak, például a JDeli | Licencfeltételek, és a forráskód sem ellenőrizhető |
| Böngészők beépített dekódere | Nem mérhető ugyanúgy, a böngésző mindig a libwebp-t vagy a rendszerét használja |

## 2. Mit mérünk

### 2.1 Érdemes

| Mérőszám | Mit mutat | Hogyan |
|---|---|---|
| **Sebesség nagy képen** | Áteresztőképesség, Mpx/s | 24 Mpx-es fotó: q75, q90, q75 alfával, veszteségmentes |
| **Idő kis képen** | Képenkénti költség, ami a webes és mobil felhasználásban számít (ikonok, bélyegképek) | 256×256-os képek, a képenkénti idő mikroszekundumban |
| **Többletmemória** | Mennyi memóriát kér a dekóder a bemeneten és a kimeneten felül | Csúcs-RSS külön folyamatban, levonva ugyanannak a programnak a dekódolás nélküli értékét |
| **Pontosság** | Ugyanazt a képet adja-e, mint a libwebp | A libwebp tesztkorpuszának 131 fájljából hány egyezik pixelre a `dwebp` kimenetével |
| **Bináris méret** | Mennyit hízik tőle egy alkalmazás | Csak a natívan fordított nyelveknél (Swift, C, Rust, Go), statikus és strippelt programon |
| **Funkciók** | Mit tud egyáltalán | Táblázat: veszteségmentes, veszteséges, alfa, animáció, metaadatok, korlátok, függőségek, platformok |

### 2.2 Nem érdemes, legalábbis most

| Mérőszám | Ok |
|---|---|
| Többszálú sebesség | A mi dekóderünk egyszálas, és a legtöbb versenytárs is. Ha később lesz többszálú módunk, külön mérjük |
| Kódolási sebesség | Még nincs enkóderünk, az M5 után |
| Energiafogyasztás | Nehezen mérhető megbízhatóan, és nagyjából a futási időt követi |
| Hidegindítás a JIT-es nyelveknél | Csak lábjegyzetként: a Java és a .NET első dekódolása lassabb, de a felhasználók tartósan futó programban dekódolnak |

## 3. Módszer

### 3.1 Közös mérőszabályok

- **Minden könyvtárhoz egy kis mérőprogram** a saját nyelvén, közös parancssori felülettel. Az eredményt soronként JSON-ként írja ki: könyvtár, verzió, fájl, legjobb és medián idő, kimeneti formátum, pixel-hash.
- **Bemelegítés, majd 20 futás.** A JIT-es nyelvek (Java, .NET) miatt 3 bemelegítő futás jön előtte. A diagramon a medián szerepel, a legjobb idő a részletes táblázatban.
- **Mindenki ugyanazt a munkát végzi:** WebP-bájtokból RGBA-pixeleket a memóriában. Ahol a könyvtár mást ad (a Go YCbCr-t, az image-webp átlátszatlan képnél RGB-t), ott az RGBA-ra alakítás is a mért időbe számít, és ezt jelöljük.
- **Egy szál.** Ahol a könyvtár többszálúsítana, kikapcsoljuk.
- **Pixel-ellenőrzés.** Ha egy könyvtár kimenete eltér a libwebp-étől, a diagramon jelöljük, de nem zárjuk ki.
- **Rögzített verziók** zárfájlokkal (`Cargo.lock`, `go.sum`, és így tovább), a méréssel együtt eltároljuk a dátumot, a gépet és az operációs rendszert.

### 3.2 Környezet

A Go, a .NET, a Java és a Node nincs telepítve a gépeden. Hogy ne maradjon utánuk semmi, ezek **Dockerben** futnak.

| Környezet | Kik | Miért |
|---|---|---|
| **Linux aarch64, Docker az M5-ön** (fő eredmény) | Mindenki az ImageIO kivételével | Egy helyen, azonos feltételekkel mérhető minden nyelv, és a végén a konténer és a kép is törölhető |
| **macOS natívan** (kiegészítő) | swift-raster-webp, libwebp, ImageIO | Az Apple-fejlesztőket ez érdekli, és az ImageIO csak itt fut |
| **Linux x86-64, a szervered** (opcionális) | Ugyanaz a Docker-csomag | Megmutatja, hogyan teljesítünk Intel/AMD gépen, ahol a libwebp SSE-kódja fut |

A Docker egy virtuális gépben fut a Macen, de a processzormunka szinte natív sebességű. A két környezet számait sosem keverjük egy diagramon.

### 3.3 Memória mérése

- Minden mérés külön folyamatban fut, egyetlen dekódolással.
- A csúcs-RSS-ből levonjuk ugyanannak a programnak a dekódolás nélküli csúcs-RSS-ét, és a bemenet, illetve a kimenet méretét.
- A szemétgyűjtős nyelveknél (Go, Java, .NET) a szám zajosabb, és a futtatókörnyezet beállításaitól is függ. Ezt a diagram alatt jelezzük.

## 4. Vizualizáció

- **Vízszintes oszlopdiagramok SVG-ben,** egy szkript generálja a mérési JSON-ból. Az SVG éles marad, a GitHub megjeleníti, és nem kell hozzá külső szolgáltatás.
- **Világos és sötét változat** `<picture>` elemmel, így a GitHub sötét témájában is jól látszik.
- **Kiemelés:** a mi oszlopunk színes, a többi szürke. Az oszlopok sebesség szerint rendezve, a pontos érték az oszlop végén.
- **A README-be három diagram kerül:** veszteséges sebesség, veszteségmentes sebesség, többletmemória. A többi az összehasonlító oldalra.
- **A pontos számok** egy összecsukható táblázatban maradnak a diagramok alatt.

A Mermaid-diagram is szóba jött, mert a GitHub beépítetten rajzolja. De nem lehet benne egy oszlopot kiemelni, és a sötét témát sem lehet szabályozni, ezért az SVG a jobb választás.

Egy diagram így nézne ki (vázlat):

```text
Veszteséges dekódolás, q75 (Mpx/s, több a jobb)

libwebp (C)               ████████████████████████████  149
swift-raster-webp (Swift) ████████████████████  106
zenwebp (Rust)            ██████████████████  ?
image-webp (Rust)         ██████████████  74
ImageSharp (C#)           ████████████  ?
x/image/webp (Go)         ██████████  ?
```

## 5. Reprodukálhatóság és takarítás

- **Egy helyen minden:** a mérőprogramok a `Benchmarks/Comparison/` mappába kerülnek, nyelvenként egy almappával és egy Dockerfile-lal.
- **Egy szkript futtat mindent:** a `Scripts/compare-decoders.sh` bővül. Felépíti a Docker-képet, lefuttatja a méréseket, kiírja a JSON-t, és legenerálja a diagramokat.
- **Takarítás:** a szkript a végén törli a konténert, a Docker-képet és az ideiglenes mappákat. A gépeden csak a repóban követett fájlok maradnak. A Rust-mérésnél bevált módszer (saját `CARGO_HOME`) a többi nyelvre is érvényes.
- **Az eredmények a repóba kerülnek** (`docs/performance/results/`), a diagramokkal együtt, így a README sosem mutat olyat, ami nincs dokumentálva.

## 6. Megvalósítási sorrend

| Szakasz | Tartalom | Ellenőrzés |
|---|---|---|
| 1 | Közös mérőkeret, JSON-formátum, diagramgenerátor a mostani három könyvtárra | Az SVG-k helyesen jelennek meg a GitHubon, világos és sötét témában |
| 2 | Go, .NET, Java és zenwebp mérőprogram Dockerben | Minden könyvtár lefut, a pixel-hash-ek ki vannak értékelve |
| 3 | Memória, kis képek, pontosság a korpuszon, bináris méret, funkciótáblázat | Minden szám reprodukálható a szkripttel |
| 4 | macOS-kiegészítő az ImageIO-val | Külön diagram, nem keverve |
| 5 | Opcionális: Wasm-kör, x86-64 a szerveren | Csak ha az első négy szakasz kész |

## 7. Kockázatok

| Kockázat | Kezelés |
|---|---|
| Egy versenytárs (főleg a zenwebp) gyorsabb nálunk | Közöljük. A hitelesség többet ér egy szép diagramnál, és jó célt ad a további optimalizáláshoz |
| Egy könyvtár licence tiltja a teljesítményadatok közlését | A beépítés előtt minden licencet átnézünk |
| A JIT és a szemétgyűjtés zajossá teszi a számokat | Bemelegítés, 20 futás, medián, és a zajosabb számok jelölése |
| A Docker-kép nagy, és sokáig épül | Egyszer épül fel egy mérési körhöz, és a végén törlődik |
| Egy könyvtár egy képtípust nem tud | A diagramon „nem támogatott” felirat jelenik meg, nem üres hely |

## 8. Döntések

### K1 – Melyik környezet legyen a fő eredmény?

**Javaslat:** a Linux-Docker az M5-ön, mert ott minden nyelv azonos feltételekkel fut. A macOS-mérés kiegészítő, az ImageIO miatt.

### K2 – Melyik Java-dekódert mérjük?

**Javaslat:** mindkettőt. A TwelveMonkeys az elterjedtebb, a jwebp pedig az újabb és teljesebb.

### K3 – Mérjük-e a zenwebp-et, ha a licence AGPL?

**Javaslat:** igen, ha a licence nem tiltja a teljesítményadatok közlését. Mi nem terjesztjük a kódját, csak egy mérőprogramban használjuk, amely nem kerül a csomagba.

### K4 – Legyen-e Wasm-kör és x86-64-es mérés?

**Javaslat:** később, az 5. szakaszban, ha az első négy kész.
