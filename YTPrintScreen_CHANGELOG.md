# YTPrintScreen – CHANGELOG

## 1.95
- SmartTrim nyní před porovnáním s naučenými rozměry vyhodnocuje poměr stran hrubě nalezeného kandidáta.
- Jako nejsilnější nápovědu používá existující profilový `FSCUT_Ratio`; není zaveden nový konfigurační parametr.
- Pokud je hrubý kandidát blízko očekávanému poměru stran, SmartTrim smí bezpečně zmenšit pouze jednu osu, maximálně o 10 %, aby odstranil připojený UI pás.
- Profilový poměr stran má vyšší prioritu než obecné běžné poměry videí a obrázků (např. 2.39:1, 2.35:1, 2:1, 1.85:1, 16:9, 4:3, 1:1 a portrétní varianty).
- Při korekci podle profilového poměru se SmartTrim snaží zachovat hranu, která odpovídá známé geometrii `FSCUT_X/Y/W/H`; tím lze např. ponechat správný horní okraj videa a odstranit pouze spodní UI pás.
- Ratio assist probíhá před porovnáním s naučenými rozměry, takže dříve chybně naučený rozměr nemá přednost před silnějším profilovým poměrem stran.
- Log nově zapisuje `SmartTrim ratio assist | MATCH/NO MATCH`, původní a cílový poměr, výsledný rozměr a použitou kotvu.
- INI se v této verzi nemění.

## 1.94
- Rozšířen diagnostický log capture pipeline, AutoTrim a SmartTrim.
- Log nyní zapisuje zdrojový a výsledný rozměr bitmapy, vybranou pipeline, surové hranice AutoTrimu, detekovanou barvu pozadí a jistotu rohů.
- SmartTrim loguje počet naučených rozměrů, kandidátní rozměr a stav edge cleanupu včetně případů, kdy se hrana nezměnila.
- Inicializace logu zapisuje základní runtime údaje jedním blokem, aby při diagnostice nezůstal pouze první řádek.
- Algoritmus ořezu se v této verzi nemění; cílem verze je získat přesná data pro opravu progress baru na spodní hraně.

# YTPrintScreen – Changelog

## 1.93
- SmartTrim dostal závěrečnou bezpečnou očistu hran pro úzké černé UI / letterbox pásy, které mohou zůstat připojené k jinak správně nalezenému obrazu.
- Očista umí odstranit i několik barevných řádků nebo sloupců na úplném okraji před černým pásem, typicky červenou progress linku videopřehrávače.
- Detekce je záměrně konzervativní: černý pás musí tvořit alespoň tři souvislé řádky/sloupce a minimálně 90 % vzorků musí být skutečně velmi tmavých.
- Kontrola se provádí jen v úzké oblasti u nalezené hrany (maximálně 8 % rozměru, nejvýše 64 px), aby tmavá scéna uvnitř obrazu nebyla považována za UI.
- Edge cleanup se používá pouze ve vrstvě `SmartTrim`; běžný `AutoTrim` a pevný `FSCUT` zůstávají beze změny.
- Do logu se při zásahu zapisuje geometrie kandidáta před a po `SmartTrim edge cleanup`.

## 1.92
- Zavedena obecná pipeline architektura pro zpracování screenshotu: CLI pouze vybírá preset, zatímco konkrétní profil určuje pořadí vrstev.
- Přidány děděné parametry `DefaultPipeline` a `CapturePipeline`; hodnoty z `[Common]` může libovolný profil přepsat.
- Spuštění bez parametru používá `DefaultPipeline`; nový parametr `capture` používá `CapturePipeline`.
- Původní CLI parametr `fscut` zůstává kvůli zpětné kompatibilitě jako alias pro `capture`.
- Každý běh nyní nejprve pořídí fullscreen bitmapu monitoru. Jednotlivé vrstvy z ní následně vytvářejí výsledný obraz, takže fallback má vždy k dispozici nepoškozený originál.
- Pipeline podporuje vrstvy `Fullscreen`, `FSCUT`, `AutoTrim`, `SmartTrim` a `FSCUTFallback`.
- `SmartTrim` už není závislý na tom, že před ním musí proběhnout pevný FSCUT; může analyzovat celý fullscreen obraz a hledat obsah libovolného poměru stran.
- `FSCUTFallback` se použije pouze tehdy, když předchozí `SmartTrim` nebo `AutoTrim` neprovedl bezpečný ořez; při úspěchu inteligentního trimu se pevný výřez přeskočí.
- `AutoTrimTolerance` zůstává jediným parametrem citlivosti inteligentního trimu a zapisuje se v procentech.
- `[Common]` používá `DefaultPipeline="Fullscreen"` a `CapturePipeline="FSCUT"`, čímž zachovává dosavadní chování běžných profilů.
- `[ChatGPT]` přepisuje `CapturePipeline` na `SmartTrim,FSCUTFallback`; bez parametru nadále používá fullscreen.
- `[QuickN]` používá `SmartTrim,FSCUTFallback` jako `DefaultPipeline` i `CapturePipeline`, protože samotný fullscreen výstup zde nedává praktický smysl.
- Pro QuickN je aktivována stejná `AutoTrimTolerance=3` a jeho `MatchURL` nyní rozpoznává obě domény `quickn.quickbreaknews.com` a `tasty.ezyfoodies.com`.
- Log nově explicitně zapisuje vybraný preset, definici pipeline, úspěch/odmítnutí SmartTrimu a případné použití `FSCUT fallback`.

## 1.91
- Přidána volitelná vrstva `SmartTrim`, řízená parametrem `SmartTrim=1/0` s děděním `[Common] -> profil`.
- `SmartTrim` používá stejnou procentní toleranci jako `AutoTrimTolerance`; nevzniká nový parametr citlivosti.
- Při zapnutém `SmartTrim` se spolehlivě rozpoznané výsledné rozměry automaticky ukládají do stavového souboru `YTPrintScreen_SmartTrim.ini` odděleně pro každý profil.
- Ukládá se skutečná dvojice šířka × výška a počet potvrzených výskytů, takže při porovnání je k dispozici rozměr i odvozený poměr stran.
- Učit databázi smějí pouze silné detekce se shodou alespoň tří rohů pozadí; nejisté případy mohou znalost použít, ale nemohou ji samy učit.
- Pokud rozměr navržený AutoTrimem leží v `AutoTrimTolerance` od naučeného rozměru současně šířkou, výškou i poměrem stran, SmartTrim použije naučený rozměr jako silnější vodítko.
- Při více vhodných naučených rozměrech rozhoduje geometrická podobnost a četnost předchozích spolehlivých výskytů.
- SmartTrim je ve vzorovém INI zatím aktivován pouze v profilu `[ChatGPT]`; ostatní profily zůstávají beze změny.
- Pokud `AutoTrimTolerance` chybí, je nulová nebo záporná, AutoTrim i SmartTrim zůstávají neaktivní bez ohledu na hodnotu `SmartTrim`.

## 1.90
- Přidán volitelný `AutoTrim` pro automatické odstranění mrtvé plochy kolem skutečného obrazu po pořízení screenshotu / FSCUT.
- AutoTrim se aktivuje jediným parametrem `AutoTrimTolerance`; hodnota se zapisuje přímo v procentech.
- `AutoTrimTolerance > 0` funkci zapíná a současně určuje povolenou barevnou odchylku pozadí; chybějící, nulová nebo záporná hodnota funkci vypíná.
- Pozadí se odhaduje z barevné shody rohů obrazu. Pokud není alespoň dvojice rohů dostatečně podobná, AutoTrim se z bezpečnostních důvodů nepoužije.
- Hrany se nehledají pixel po pixelu přes celý řádek/sloupec, ale pomocí vzorkování; cílem je nízká režie i při Full HD obrazu.
- Řádek nebo sloupec se považuje za mrtvou zónu, pokud alespoň 75 % vzorků odpovídá zjištěnému pozadí. Tím se tolerují drobné UI prvky, text nebo ikony v jinak prázdné ploše.
- Při hledání skutečného obsahu se tolerují až dvě jednotlivé rušivé linky; hranice je potvrzena třemi po sobě jdoucími řádky/sloupci s obsahem.
- Po AutoTrim zůstává zachován skutečný poměr stran výsledného obrázku a následující PowerPoint positioning (`Fullscreen` i `[Position:*]`) pracuje už s oříznutým obrazem.
- Přidána bezpečnostní pojistka: pokud by detekovaný obsah byl podezřele malý, trim se zahodí a použije se původní bitmapa.
- Pro první praktický test je `AutoTrimTolerance=3` aktivováno pouze v profilu `[ChatGPT]`. Ostatní profily zůstávají beze změny a AutoTrim je v nich vypnutý.

## 1.89
- Opravena drobná logická chyba po vložení screenshotu do červené mezery mezi slidy.
- Slide vytvořený přes `ExecuteMso("SlideNew")` v insertion pointu je nyní považován za finální cílový slide.
- Po vložení obrázku do takto vytvořeného slidu se už automaticky nevytváří další prázdný slide za ním.
- Dosavadní chování pro již existující prázdný slide zůstává zachováno: pokud screenshot začne na existujícím čistém slidu, skript může nadále zajistit další čistý slide.

## 1.88
- Do produkčního skriptu byla přenesena prakticky ověřená logika pro červenou mezeru mezi slidy v PowerPointu.
- Pokud `win.View.Slide` není dostupný, skript nejprve ověří stav `Selection.Type=0` a `ActivePane.ViewType=11`.
- Jen při této kombinaci se stav považuje za platnou vybranou mezeru mezi slidy.
- Nový slide se vytváří přes ověřený Office control ID `ExecuteMso("SlideNew")`, takže PowerPoint sám respektuje aktuální insertion point.
- Před a po vložení se kontroluje počet slidů; musí vzniknout právě jeden nový slide.
- Nový slide se identifikuje porovnáním unikátních `SlideID` před a po vložení.
- Novému slidu se nastaví prázdný layout a skript se na něj pokusí přepnout.
- Pokud není aktivní slide ani platná mezera mezi slidy, stav zůstává chybou a žádný slide se nevytváří.
- Pokud byl slide vytvořen z mezery, `PowerPointAutoSlide=1` už nevytváří další zbytečný slide.
- Stejná logika funguje i při `PowerPointAutoSlide=0`, protože při vybrané mezeře musí nejprve vzniknout cílový slide.

## 1.87
- Vrácena produkční logika PowerPointu na poslední stabilní stav před experimenty s detekcí mezery mezi slidy.
- Experimenty 1.84–1.86 s `View.Slide`, `ActivePane.ViewType` a `ExecuteMso("NewSlide")` se pro detekci červeného insertion pointu neosvědčily.
- Důvod: v Normal View PowerPoint přes COM nevystavuje thumbnail pane tak, jak jsme předpokládali; `Pane.ViewType` zde není spolehlivý indikátor vybrané mezery.
- Detekce mezery mezi slidy se nyní zkoumá odděleně pomocí Windows UI Automation v diagnostickém skriptu `PPGapUIADiagnostic_v1.00.ahk`.
- Produkční skript při chybějícím aktivním slidu opět skončí chybou a s prezentací dále nemanipuluje.

## 1.86
- Produkční kód pro detekci mezery mezi slidy byl vrácen před neúspěšné experimenty 1.84/1.85 a nahrazen novým řešením.
- Průzkum ukázal, že PowerPoint COM přímo poskytuje `DocumentWindow.ActivePane` a `Pane.ViewType`; není tedy nutné odhadovat konkrétní čísla slidů ani analyzovat obrazovku.
- Pokud není dostupný `win.View.Slide`, skript ověří, zda je aktivní levý thumbnail/outline pane (`ppViewThumbnails=11` nebo `ppViewOutline=6`).
- Jen v tomto kontextu se použije vlastní PowerPoint příkaz `ExecuteMso("NewSlide")`, který zná aktuální insertion point mezi slidy.
- Přesný nový slide se neurčuje přes `win.View.Slide`, ale porovnáním unikátních `SlideID` před a po vložení.
- Pokud není aktivní slide ani thumbnail/outline pane, stav se považuje za chybu a žádný slide se nevytváří na konci prezentace.
- Po vytvoření slidu se na něj skript pokusí explicitně přepnout.
- Řešení je obecné: nezávisí na číslech konkrétních slidů ani na jejich pozici v prezentaci.

## 1.85
- Zpřesněna logika PowerPointu pro stav, kdy není dostupný aktivní slide.
- Pokud je vybraná platná mezera mezi slidy, nový slide se stále vytvoří přes `CommandBars.ExecuteMso("NewSlide")` v aktuálním insertion pointu.
- Odstraněn fallback, který při neúspěchu vytvářel nový slide na konci prezentace.
- Pokud není vybrán ani konkrétní slide ani platná mezera mezi slidy, skript skončí chybou a žádný slide úmyslně nevytváří na konci prezentace.
- Po úspěšném vytvoření slidu v insertion pointu se na něj PowerPoint explicitně přepne.
- Před a po příkazu `NewSlide` se kontroluje počet slidů, aby skript ověřil, že PowerPoint skutečně nový slide vytvořil.

## 1.84
- Opravena práce s PowerPointem v situaci, kdy není vybrán konkrétní slide, ale insertion point / mezera mezi slidy.
- Pokud `win.View.Slide` není dostupný, skript automaticky vytvoří nový prázdný slide a screenshot vloží do něj.
- Nejprve se používá `CommandBars.ExecuteMso("NewSlide")`, aby PowerPoint zachoval aktuální místo vložení mezi slidy.
- Nově vytvořenému slidu se vynutí prázdný layout.
- Pokud vytvoření přes PowerPoint UI příkaz selže, použije se bezpečný fallback: nový prázdný slide na konci prezentace.
- Toto chování platí i při `PowerPointAutoSlide=0`, protože bez aktivního slidu není kam obrázek vložit.
- Při `PowerPointAutoSlide=1` se nově vytvořený slide považuje za čistý slide a nevytváří se před vložením další zbytečný slide.

## 1.83
- Sjednocena konvence názvů parametrů v sekcích `[Position:*]`: jednotky nejsou součástí názvu.
- `LeftCm` → `Left`.
- `TopCm` → `Top`.
- `MaxWidthCm` → `MaxWidth`.
- `MaxHeightCm` → `MaxHeight`.
- `StackGapCm` → `StackGap`.
- `PositionTolerance` zůstává beze změny.
- Všechny uvedené hodnoty jsou nadále v centimetrech; jednotka je pouze v komentáři INI.
- Stejná konvence byla promítnuta do AHK: lokální proměnné už neobsahují jednotku a konverzní helper je `ToPowerPointPoints()`.
- Pokud `PositionTolerance` v sekci neexistuje, používá se automaticky `0`.

## 1.82
- Parametr `RemoveEmptyPlaceTolerance` byl nahrazen obecnějším `PositionTolerance`.
- `PositionTolerance` se používá pro rozpoznání objektů náležejících ke stejné definované pozici.
- Pokud `PositionTolerance` chybí nebo je `0`, mazání placeholderů i automatické skládání obrázků jsou vypnuté.
- Přidán parametr `StackGapCm`; pokud chybí, používá se výchozí hodnota `0.3` cm.
- Pokud už ve stejné pozici existuje jeden nebo více obrázků, nový obrázek se vloží pod nejnižší z nich.
- Svislá pozice nového obrázku je `spodní okraj nejnižšího obrázku + StackGapCm`.
- `Match` existujících obrázků používá jejich vodorovnou pozici v rámci `PositionTolerance` a bere pouze obrázky od základní cílové pozice směrem dolů.
- Prázdný textový kontejner se nadále maže pouze tehdy, pokud je skutečně prázdný a jeho levý horní roh odpovídá výsledné poloze nového obrázku v rámci `PositionTolerance`.

## 1.81
- Přidán parametr příkazové řádky `--position=Název`, který přebíjí `PowerPointPosition` z INI.
- `Fullscreen` je vestavěná platná pozice; ostatní pozice se hledají v sekcích `[Position:*]`.
- Názvy pozic jsou case-insensitive.
- Pokud pozice z `--position` neexistuje, override se ignoruje, zachová se pozice z INI a chyba se zapíše pouze do logu.
- Přidán parametr `RemoveEmptyPlaceTolerance` do pozičních sekcí; hodnota je v centimetrech a `0` funkci vypíná.
- Po napozicování obrázku může skript odstranit prázdný textový kontejner, jehož levý horní roh leží v nastavené toleranci od levého horního rohu vloženého obrázku.
- Kontejner s reálným textem se nemaže.
- Do `[Position:SizeRight]` přidáno `RemoveEmptyPlaceTolerance=0.2`.
- Do distribuovaného INI byla doplněna chybějící sekce `[Position:SizeRight]`.

## 1.80
- Přidán parametr `PowerPointAutoSlide`.
- Výchozí hodnota v `[Common]` je `PowerPointAutoSlide=1`, takže zůstává dosavadní logika čistého slidu.
- Při `PowerPointAutoSlide=0` se screenshot vloží přímo do aktuálního slidu a jako nejvyšší vrstva.
- Přidán parametr `PowerPointPosition`.
- Výchozí `PowerPointPosition="Fullscreen"` zachovává dosavadní chování maximálního vyplnění slidu se zachováním poměru stran.
- Přidány obecné poziční sekce `[Position:<název>]`.
- Přidána sekce `[Position:SizeRight]` podle logiky skriptu `PPSizeRightElement.ahk`.
- `SizeRight` používá `LeftCm`, `TopCm`, `MaxWidthCm` a `MaxHeightCm`, zachovává aspect ratio a užší obrázek horizontálně centruje v cílové oblasti.
- Profil `[QuickN]` nyní přepisuje `PowerPointAutoSlide=0` a `PowerPointPosition="SizeRight"`.
- Pozicování obrázků nastavuje při zamčeném aspect ratio pouze šířku; výšku dopočítává PowerPoint.

## 1.72
- Upřesněna logika `--profile:Název` pro profily navázané na alias v `[Targets]`.
- `--profile:VLC` nejprve omezí kandidáty pouze na proces `vlc.exe`.
- Pokud existuje jen jedno vhodné okno procesu, použije se rovnou.
- Pokud existuje více oken stejného procesu a profil obsahuje `MatchTitle` a/nebo `MatchURL`, použijí se pouze jako preferenční upřesnění.
- Pokud `Match*` najdou shodu, vybere se první odpovídající okno v Z-orderu.
- Pokud `Match*` nic nenajdou, není to chyba; použije se první okno procesu v Z-orderu.
- `MatchTitle` a `MatchURL` tedy nejsou při `--profile` povinné, pokud existuje stejnojmenný alias v `[Targets]`.

## 1.71
- Opravena logika parametru `--profile:Název`.
- Pokud název profilu odpovídá aliasu v `[Targets]`, skript vybírá přímo podle procesu a nevyžaduje shodu `MatchTitle` / `MatchURL`.
- `--profile:VLC` tedy hledá okna procesu `vlc.exe` a použije první v Z-orderu, tedy nejvýše položené vhodné okno.
- `MatchTitle` / `MatchURL` profilu zůstávají zachovány pro běžný automatický výběr bez `--profile`.
- Pokud profil nemá alias v `[Targets]`, `--profile` nadále používá standardní `MatchTitle` / `MatchURL`.

## 1.70
- Přidán parametr příkazové řádky `--profile:Název`.
- Při vynuceném profilu se nepoužije aktivní okno ani běžná priorita profilů; skript prohledá pouze okna odpovídající zadanému profilu.
- Pokud profilu odpovídá více oken, vybere se první v Z-orderu, tedy okno umístěné nejvýše.
- Pokud profil v INI neexistuje, nemá `MatchTitle`/`MatchURL`, nebo nebylo nalezeno vhodné okno, skript zobrazí srozumitelnou chybu.
- Profil `Others` nelze vynutit pomocí `--profile`.
- Parametr `fscut` nyní ihned po spuštění krátce pípne, aby tlačítko v Companionu poskytlo okamžitou zvukovou odezvu.
- Do vzorového INI přidán povolený proces `vlc.exe` a profil `[VLC]`.
- Poslední platný uživatelský INI byl zachován jako základ; doplněny také parametry `Output` a `FileFormat` zavedené ve verzi 1.60.

## 1.60
- Hlavička AHK zkrácena na aktuální funkce, použití a odkaz na `YTPrintScreen_CHANGELOG.md`; historie verzí zůstává pouze v Markdown changelogu.
- Přidán konfigurační parametr `Output` s hodnotami `PowerPoint` a `File`.
- Přidán `FileFormat` s podporou `PNG`, `JPG` a `JPEG`.
- Při `Output="File"` se zobrazí standardní dialog Uložit jako.
- Navržený název souboru se odvozuje z titulku cílového okna; neplatné znaky se odstraní a fallback je `printscreen`.
- Ukládání na disk používá systémové GDI+ a zachovává přesný rozměr screenshotu/výřezu.
- DevTools fallback je nově chráněn `try/catch`.
- Pokud je lokální DevTools endpoint nedostupný, zobrazí se dialog s instrukcí k povolení Remote DevTools a s kopírovatelnou adresou `chrome://inspect/#remote-debugging`.
- Poslední platná uživatelská konfigurace QuickN/ChatGPT/YouTube byla zachována a rozšířena pouze o nové parametry výstupu.

## 1.55
- Odstraněn nefunkční UIA focus fallback z verze 1.54.
- Primární čtení URL zůstává přes Windows UI Automation bez zásahu do adresního řádku.
- Pokud UIA vrátí pouze relativní cestu, Chrome profil může použít fallback přes lokální Chrome DevTools endpoint 127.0.0.1:9222.
- DevTools fallback čte seznam page targetů z /json a pokusí se aktivní okno spárovat podle titulku.
- Pokud je nalezena shoda, použije se úplná URL targetu; žádné ovládání DOM ani trvalé připojení se neprovádí.
- Přidáno diagnostické logování DevTools fallbacku.
- Založen externí YTPrintScreen_CHANGELOG.md; hlavička skriptu se od dalších verzí drží stručná.

## 1.54
- Přidán bezpečný UI Automation fallback pro získání celé URL v Chrome.
- Pokud adresní řádek ve steady-state vrátí jen relativní cestu, skript si uloží aktuálně fokusovaný UIA prvek.
- Poté přes UI Automation krátce nastaví focus přímo na adresní řádek, znovu přečte jeho Value a původní focus obnoví.
- Nepoužívá Ctrl+L, clipboard ani psaní do adresního řádku.
- Chrome při aktivním adresním řádku typicky obnoví skrytou doménu a vrátí úplnou URL.
- Rozšířeno logování o hodnotu před a po UIA focus fallbacku.

## 1.53
- Opraveno čtení URL přes Windows UI Automation.
- Adresní řádek se nyní hledá jako kombinace AcceleratorKey="Ctrl+L" AND ControlType=Edit.
- Tím se zabrání záměně za jiné UIA prvky stránky, které mohou vracet jen relativní cestu.
- Pokud UIA vrátí pouze relativní cestu bez domény, hodnota se odmítne a zapíše do logu.
- Do logu se zapisuje i Name a AutomationId nalezeného adresního řádku pro další diagnostiku.

## 1.52
- Opraveno škálování vloženého obrázku v PowerPointu.
- Po zapnutí LockAspectRatio se již nenastavuje současně Width i Height.
- Skript nyní mění pouze šířku a výšku nechá dopočítat PowerPoint podle skutečného poměru stran obrázku.
- Tím se odstraní deformace a dvojité škálování zejména u nestandardních poměrů jako 2,39:1.

## 1.51
- Rozšířeno diagnostické logování fullscreen akcí.
- Před zapnutím i vypnutím fullscreen se zapisuje profil, výsledná hodnota AutoFullscreen, skutečně odesílaná klávesa a zdroj nastavení.
- Log rozlišuje INI, CLI:afs a CLI:noafs; usnadňuje diagnostiku rozdílu mezi "f" a "{F11}".

## 1.50
- Přidána sekce [Targets] s explicitním seznamem procesů, jejichž okna smí skript zpracovat.
- Aktivní okno z povoleného procesu má vždy přednost před automatickým výběrem.
- Profil aktivního cílového okna se pouze určí; bez shody se použije Others.
- Automatický výběr podle [Profiles] Order se použije jen pokud aktivní okno není povolený cíl.
- Odstraněn pevně zakódovaný seznam prohlížečů.

## 1.41
- FSCUT_Ratio nyní podporuje desetinnou tečku i desetinnou čárku.
- Hodnoty jako "2.39:1" a "2,39:1" jsou rovnocenné.
- Desetinná čárka se před vyhodnocením automaticky normalizuje na tečku.

## 1.40
- Přidán parametr AutoFullscreen do INI s děděním Common -> profil.
- [Common] může mít AutoFullscreen=0, zatímco konkrétní profily jej mohou přepsat na 1.
- Parametr příkazové řádky "afs" vždy vynutí fullscreen bez ohledu na INI.
- Přidán parametr "noafs", který naopak fullscreen vždy zakáže bez ohledu na INI.
- Přidán parametr FSCUT_Ratio ve formátu "šířka:výška", výchozí hodnota je "16:9".
- FSCUT_Ratio lze přepsat v jednotlivých profilech; FSCUT_H se vždy dopočítá až po sloučení konfigurace.
- Přidána validace poměru stran a logování výsledného nastavení fullscreen i FSCUT.

## 1.32
- Opraveno párování MatchURL pro Chrome: UI Automation vrací URL typicky bez protokolu https://.
- MatchURL v INI proto může bezpečně pracovat přímo s doménou vrácenou adresním řádkem.
- Přidáno explicitní logování neúspěšného MatchURL, aby bylo vidět URL i použitý regulární výraz.

## 1.31
- MatchTitle a MatchURL jsou výhradně identifikační parametry profilu a nikdy se nedědí z Common.
- Každý profil uvedený v [Profiles] Order musí obsahovat alespoň MatchTitle nebo MatchURL.
- Profil bez MatchTitle i MatchURL se zapíše jako chyba do logu a při výběru okna se ignoruje.
- Profil Others je jediná povolená výjimka a zůstává implicitním fallbackem.

## 1.30
- Přidána identifikace profilů podle URL přes Windows UI Automation (COM), bez klikání do adresního řádku.
- Přidána konfigurační hodnota MatchURL s podporou regulárních výrazů.
- Pokud profil obsahuje MatchTitle i MatchURL, musí odpovídat obě podmínky.
- URL se načítá pouze tehdy, když ji daný profil skutečně potřebuje.
- Přidáno podrobné logování načtené URL a výsledku párování profilu.
- YouTube nadále používá rychlou identifikaci podle titulku okna.

## 1.20
- Konfigurace přesunuta do externího souboru YTPrintScreen.ini.
- Přidány prioritní profily cílových stránek podle regulárního výrazu MatchTitle.
- Profily se vyhodnocují podle [Profiles] Order; Others je implicitní fallback s nejnižší prioritou.
- Hodnoty profilu přepisují stejnojmenné hodnoty z [Common].
- Fullscreen je řízen společnou hodnotou FullscreenKey; YouTube používá "f", ostatní standardně "{F11}".
- Odstraněna nepotřebná logika výpočtu bodu pro kliknutí do videa.
- FSCUT_H se vždy dopočítá po načtení konfigurace z FSCUT_W v poměru 16:9.
- Časování a pozice kurzoru jsou načítány z INI.

## 1.14
- Přidány konstanty FSCUT_X, FSCUT_Y, FSCUT_W, FSCUT_H na začátek skriptu.
- Parametr fscut používá pevný FullHD výřez 1920×1080.

## 1.13
- Přidán parametr fscut.
- Pokud je skript spuštěn s parametrem fscut, uloží se do schránky pouze výřez z fullscreen screenshotu.

**Verze 1.00 až 1.12 nebyly zdokumentovány.**
