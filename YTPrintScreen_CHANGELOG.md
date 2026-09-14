# YTPrintScreen – CHANGELOG

## 1.96
- Profil ChatGPT používá pro `capture` / legacy `fscut` pipeline `FSCUT,SmartTrim`.
- Nejprve se použije bezpečný pevný výřez podle geometrie `FSCUT_*`; SmartTrim následně dočistí okolí až k hranám skutečného obrázku a zachová jeho skutečný poměr stran.
- Změna nahrazuje dočasné nastavení `CapturePipeline="FSCUT"`, které u obrázků jiného poměru stran ponechávalo uvnitř výsledku okolní UI ChatGPT.
- QuickN a ostatní profily se nemění.

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

**Verze 1.00 až 1.12 nebyly zdokumentovány.**
