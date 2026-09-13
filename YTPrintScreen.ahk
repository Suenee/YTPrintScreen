#Requires AutoHotkey v2.0
#SingleInstance Force

/*
YTPrintScreen.ahk
Aktuální verze: 1.95

Skript pořídí screenshot z aktivního nebo automaticky vybraného cílového okna.
Chování se řídí souborem YTPrintScreen.ini.

Použití:
- bez parametrů         = použije DefaultPipeline aktivního profilu
- capture               = použije CapturePipeline aktivního profilu a krátce zvukově potvrdí spuštění
- fscut                 = kompatibilní alias pro capture
- afs                   = vynutí automatický fullscreen
- noafs                 = zakáže automatický fullscreen
- --profile:Název       = omezí výběr na proces z [Targets]; Match* pouze preferuje shodu, jinak rozhodne Z-order
- --position=Název      = vynutí pozici obrázku v PowerPointu; názvy nejsou citlivé na velikost písmen
- číslo monitoru        = volitelné ruční určení monitoru

Aktuální funkce:
- prioritní profily podle MatchTitle / MatchURL
- seznam povolených procesů v [Targets]
- explicitní výběr profilu z příkazové řádky
- URL přes Windows UI Automation, při neúplné URL fallback přes Chrome DevTools
- automatický fullscreen podle profilu
- profilové pipeline pro vrstvené zpracování screenshotu
- konfigurovatelný pevný FSCUT a poměr stran
- volitelný AutoTrim mrtvých okrajů podle barevné tolerance
- volitelný SmartTrim, který kombinuje kontrast, očekávané poměry stran a dříve rozpoznané rozměry
- SmartTrim odstraňuje i úzké černé UI pásy na hranách včetně překrývající progress linky
- bezpečný FSCUTFallback při neúspěšném inteligentním trimu
- výstup do PowerPointu nebo do obrazového souboru
- volitelná automatická správa čistých slidů v PowerPointu
- konfigurovatelné pozice obrázku v PowerPointu přes sekce [Position:*]
- PNG a JPEG při ukládání na disk
- rozšířený diagnostický log YTPrintScreen.log včetně detailů capture pipeline, AutoTrim a SmartTrim

Kompletní historie změn:
YTPrintScreen_CHANGELOG.md
*/

CONFIG_FILE := A_ScriptDir "\YTPrintScreen.ini"

; Nouzové výchozí hodnoty nutné ještě před načtením konfigurace.
DEBUG_MODE := "single"
LOG_FILE := A_ScriptDir "\YTPrintScreen.log"

; Hodnoty načtené později z konfigurace.
ACTIVATION_WAIT := 300
ACTIVATION_TIMEOUT := 2000
FULLSCREEN_WAIT := 1200
HIDE_CONTROLS_WAIT := 4000
CLIPBOARD_WAIT := 300
POWERPOINT_WAIT := 300
HIDE_MOUSE_OFFSET_X := 20
HIDE_MOUSE_OFFSET_Y := 20
FULLSCREEN_KEY := "{F11}"
AUTO_FULLSCREEN := false
FSCUT_X := 0
FSCUT_Y := 0
FSCUT_W := 1920
FSCUT_H := 1080
FSCUT_RATIO := "16:9"
AUTO_TRIM_TOLERANCE := 0
SMART_TRIM_FILE := A_ScriptDir "\YTPrintScreen_SmartTrim.ini"
OUTPUT_MODE := "PowerPoint"
FILE_FORMAT := "PNG"
POWERPOINT_AUTO_SLIDE := true
POWERPOINT_POSITION := "Fullscreen"

; Parametry příkazové řádky.
; Hodnota -1 znamená, že příkazová řádka AutoFullscreen nepřebíjí.
auto_fullscreen_override := -1
forced_monitor := 0
forced_profile := ""
forced_position := ""
requested_pipeline_preset := "Default"
capture_cli_alias := ""

for arg in A_Args {
    arg_lower := StrLower(arg)

    if (arg_lower = "afs") {
        auto_fullscreen_override := 1
    } else if (arg_lower = "noafs") {
        auto_fullscreen_override := 0
    } else if (arg_lower = "capture" || arg_lower = "fscut") {
        requested_pipeline_preset := "Capture"
        capture_cli_alias := arg_lower
    } else if RegExMatch(arg, "i)^--position=(.+)$", &position_match) {
        forced_position := Trim(position_match[1])

        if (forced_position = "") {
            MsgBox "Parametr --position vyžaduje název pozice.", "AHK chyba", "Iconx"
            ExitApp
        }
    } else if RegExMatch(arg, "i)^--profile:(.+)$", &profile_match) {
        forced_profile := Trim(profile_match[1])

        if (forced_profile = "") {
            MsgBox "Parametr --profile vyžaduje název profilu.", "AHK chyba", "Iconx"
            ExitApp
        }
    } else if (forced_monitor = 0 && IsInteger(arg)) {
        forced_monitor := Integer(arg)
    }
}

; Okamžitá zvuková odezva pro zpracovaný capture z Companionu.
if (requested_pipeline_preset = "Capture")
    SoundBeep(1000, 80)

if !FileExist(CONFIG_FILE) {
    MsgBox "Chybí konfigurační soubor:`n`n" CONFIG_FILE, "AHK chyba", "Iconx"
    ExitApp
}

common_config := LoadIniSection("Common")
ApplyEarlyCommonConfig(common_config)
InitLog()

profile_order := GetProfileOrder()
target_processes := GetTargetProcesses()

if (target_processes.Count = 0)
    ErrorExit("Sekce [Targets] neobsahuje žádný povolený proces.")

selected_profile := ""

if (forced_profile != "") {
    target := FindTargetWindowByProfile(
        forced_profile,
        forced_monitor,
        target_processes,
        &selected_profile
    )

    if !target
        ErrorExit("Pro profil [" forced_profile "] nebylo nalezeno žádné vhodné okno.")
} else {
    target := FindBestTargetWindow(
        forced_monitor,
        profile_order,
        target_processes,
        &selected_profile
    )

    if !target
        ErrorExit("Nebylo nalezeno žádné použitelné okno z procesů povolených v [Targets].")
}

profile_config := LoadIniSection(selected_profile)
active_config := MergeConfig(common_config, profile_config)
ApplyRuntimeConfig(active_config)
ApplyCommandLineOverrides()

Log("Vybraný profil: " selected_profile)

if (forced_profile != "")
    Log("Výběr profilu z CLI: " forced_profile)
Log("FullscreenKey: " FULLSCREEN_KEY)
Log("AutoFullscreen: " (AUTO_FULLSCREEN ? "ano" : "ne"))
Log("FSCUT konfigurace | X=" FSCUT_X " | Y=" FSCUT_Y " | W=" FSCUT_W " | H=" FSCUT_H " | Ratio=" FSCUT_RATIO)
Log("AutoTrim | Tolerance=" AUTO_TRIM_TOLERANCE "% | Enabled=" (AUTO_TRIM_TOLERANCE > 0 ? "ano" : "ne"))
selected_pipeline := GetPipelineForPreset(active_config, requested_pipeline_preset)
Log("Pipeline | Preset=" requested_pipeline_preset " | Definition=" selected_pipeline)
if (capture_cli_alias != "") {
    alias_note := (capture_cli_alias = "fscut") ? " | legacy alias pro capture" : ""
    Log("Pipeline | CLI=" capture_cli_alias alias_note)
}
Log("Výstup | Mode=" OUTPUT_MODE " | FileFormat=" FILE_FORMAT)
Log("PowerPoint | AutoSlide=" (POWERPOINT_AUTO_SLIDE ? "1" : "0")
    " | Position=" POWERPOINT_POSITION)

fullscreen_source := "INI"
if (auto_fullscreen_override = 1)
    fullscreen_source := "CLI:afs"
else if (auto_fullscreen_override = 0)
    fullscreen_source := "CLI:noafs"

Log("Fullscreen konfigurace | PROFILE=" selected_profile
    " | AutoFullscreen=" (AUTO_FULLSCREEN ? "1" : "0")
    " | Key=" FULLSCREEN_KEY
    " | Source=" fullscreen_source)

InitLog() {
    global DEBUG_MODE, LOG_FILE

    if (DEBUG_MODE = "single") {
        try FileDelete(LOG_FILE)
    }

    ; Úvod zapisujeme jedním zápisem, aby diagnostika nezůstala jen na prvním řádku.
    if (DEBUG_MODE != "off") {
        try {
            header := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | === Start skriptu ===`r`n"
            header .= FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | Log | Mode=" DEBUG_MODE " | File=" LOG_FILE "`r`n"
            header .= FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | Runtime | AHK=" A_AhkVersion " | OS=" A_OSVersion " | Script=" A_ScriptFullPath "`r`n"
            FileAppend(header, LOG_FILE, "UTF-8")
        } catch as e {
            MsgBox "Nelze inicializovat log:`n`n" LOG_FILE "`n`n" e.Message, "AHK chyba", "Iconx"
        }
    }
}

Log(msg) {
    global DEBUG_MODE, LOG_FILE

    if (DEBUG_MODE = "off")
        return

    FileAppend(
        FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | " msg "`r`n",
        LOG_FILE,
        "UTF-8"
    )
}

ErrorExit(msg) {
    Log("CHYBA: " msg)
    MsgBox msg, "AHK chyba", "Iconx"
    ExitApp
}

IsInteger(value) {
    return RegExMatch(value, "^\d+$")
}

IsAbsolutePath(path) {
    return RegExMatch(path, "i)^[A-Z]:\\") || SubStr(path, 1, 2) = "\\"
}

StripIniInlineComment(value) {
    quote_char := Chr(34)
    in_quotes := false
    result := ""

    Loop StrLen(value) {
        ch := SubStr(value, A_Index, 1)

        if (ch = quote_char) {
            in_quotes := !in_quotes
            result .= ch
            continue
        }

        if (ch = ";" && !in_quotes)
            break

        result .= ch
    }

    return Trim(result)
}

UnquoteIniValue(value) {
    quote_char := Chr(34)
    value := Trim(value)

    if (StrLen(value) >= 2
        && SubStr(value, 1, 1) = quote_char
        && SubStr(value, -1) = quote_char) {
        return SubStr(value, 2, StrLen(value) - 2)
    }

    return value
}

NormalizeIniValue(value) {
    return UnquoteIniValue(StripIniInlineComment(value))
}

LoadIniSection(section_name) {
    global CONFIG_FILE

    config := Map()

    try section_text := IniRead(CONFIG_FILE, section_name)
    catch
        return config

    if (section_text = "")
        return config

    Loop Parse section_text, "`n", "`r" {
        line := Trim(A_LoopField)

        if (line = "")
            continue

        separator_pos := InStr(line, "=")
        if !separator_pos
            continue

        key := Trim(SubStr(line, 1, separator_pos - 1))
        raw_value := SubStr(line, separator_pos + 1)
        config[key] := NormalizeIniValue(raw_value)
    }

    return config
}

MergeConfig(common_config, profile_config) {
    result := Map()

    for key, value in common_config
        result[key] := value

    for key, value in profile_config
        result[key] := value

    return result
}

GetConfigText(config, key, default_value := "") {
    if config.Has(key)
        return config[key]

    return default_value
}

GetConfigNumber(config, key, default_value) {
    if !config.Has(key)
        return default_value

    value := config[key]

    if !IsNumber(value)
        ErrorExit("Konfigurační hodnota '" key "' není číslo: " value)

    return value + 0
}


GetConfigBool(config, key, default_value := false) {
    if !config.Has(key)
        return default_value

    value := StrLower(Trim(config[key]))

    if (value = "1" || value = "true" || value = "yes" || value = "on")
        return true

    if (value = "0" || value = "false" || value = "no" || value = "off")
        return false

    ErrorExit("Konfigurační hodnota '" key "' musí být 0/1, true/false, yes/no nebo on/off: " config[key])
}

CalculateCropHeight(width, ratio_text) {
    ; Podporujeme českou desetinnou čárku i desetinnou tečku.
    ratio_text := StrReplace(Trim(ratio_text), ",", ".")

    if !RegExMatch(ratio_text, "^\s*(\d+(?:\.\d+)?)\s*:\s*(\d+(?:\.\d+)?)\s*$", &match)
        ErrorExit("Neplatný FSCUT_Ratio: " ratio_text ". Použij například 16:9, 2.39:1 nebo 2,39:1.")

    ratio_w := match[1] + 0
    ratio_h := match[2] + 0

    if (ratio_w <= 0 || ratio_h <= 0)
        ErrorExit("FSCUT_Ratio musí obsahovat kladné hodnoty: " ratio_text)

    return Round(width * ratio_h / ratio_w)
}

ApplyCommandLineOverrides() {
    global AUTO_FULLSCREEN, auto_fullscreen_override
    global POWERPOINT_POSITION, forced_position

    if (auto_fullscreen_override != -1) {
        AUTO_FULLSCREEN := (auto_fullscreen_override = 1)

        if AUTO_FULLSCREEN
            Log('Příkazová řádka: "afs" přebíjí AutoFullscreen z INI -> zapnuto.')
        else
            Log('Příkazová řádka: "noafs" přebíjí AutoFullscreen z INI -> vypnuto.')
    }

    if (forced_position != "") {
        resolved_position := ResolvePowerPointPositionName(forced_position)

        if (resolved_position != "") {
            POWERPOINT_POSITION := resolved_position
            Log("PowerPoint pozice přepsána z CLI | Position=" POWERPOINT_POSITION)
        } else {
            Log("CHYBA KONFIGURACE: CLI pozice [" forced_position "] neexistuje. "
                "Používám PowerPointPosition=" POWERPOINT_POSITION ".")
        }
    }
}

ApplyEarlyCommonConfig(common_config) {
    global DEBUG_MODE, LOG_FILE, A_ScriptDir

    DEBUG_MODE := StrLower(GetConfigText(common_config, "DebugMode", "single"))
    log_name := GetConfigText(common_config, "LogFile", "YTPrintScreen.log")

    if IsAbsolutePath(log_name)
        LOG_FILE := log_name
    else
        LOG_FILE := A_ScriptDir "\" log_name
}

ApplyRuntimeConfig(config) {
    global ACTIVATION_WAIT, ACTIVATION_TIMEOUT, FULLSCREEN_WAIT
    global HIDE_CONTROLS_WAIT, CLIPBOARD_WAIT, POWERPOINT_WAIT
    global HIDE_MOUSE_OFFSET_X, HIDE_MOUSE_OFFSET_Y, FULLSCREEN_KEY, AUTO_FULLSCREEN
    global FSCUT_X, FSCUT_Y, FSCUT_W, FSCUT_H, FSCUT_RATIO, AUTO_TRIM_TOLERANCE
    global OUTPUT_MODE, FILE_FORMAT
    global POWERPOINT_AUTO_SLIDE, POWERPOINT_POSITION

    ACTIVATION_WAIT := GetConfigNumber(config, "ActivationWait", 300)
    ACTIVATION_TIMEOUT := GetConfigNumber(config, "ActivationTimeout", 2000)
    FULLSCREEN_WAIT := GetConfigNumber(config, "FullscreenWait", 1200)
    HIDE_CONTROLS_WAIT := GetConfigNumber(config, "HideControlsWait", 4000)
    CLIPBOARD_WAIT := GetConfigNumber(config, "ClipboardWait", 300)
    POWERPOINT_WAIT := GetConfigNumber(config, "PowerPointWait", 300)

    HIDE_MOUSE_OFFSET_X := GetConfigNumber(config, "HideMouseOffsetX", 20)
    HIDE_MOUSE_OFFSET_Y := GetConfigNumber(config, "HideMouseOffsetY", 20)

    FULLSCREEN_KEY := GetConfigText(config, "FullscreenKey", "{F11}")
    AUTO_FULLSCREEN := GetConfigBool(config, "AutoFullscreen", false)

    FSCUT_X := GetConfigNumber(config, "FSCUT_X", 0)
    FSCUT_Y := GetConfigNumber(config, "FSCUT_Y", 0)
    FSCUT_W := GetConfigNumber(config, "FSCUT_W", 1920)
    FSCUT_RATIO := GetConfigText(config, "FSCUT_Ratio", "16:9")
    FSCUT_H := CalculateCropHeight(FSCUT_W, FSCUT_RATIO)
    AUTO_TRIM_TOLERANCE := GetConfigNumber(config, "AutoTrimTolerance", 0)
    OUTPUT_MODE := GetConfigText(config, "Output", "PowerPoint")
    FILE_FORMAT := StrUpper(GetConfigText(config, "FileFormat", "PNG"))
    POWERPOINT_AUTO_SLIDE := GetConfigBool(config, "PowerPointAutoSlide", true)
    POWERPOINT_POSITION := GetConfigText(config, "PowerPointPosition", "Fullscreen")

    if (StrLower(OUTPUT_MODE) != "powerpoint" && StrLower(OUTPUT_MODE) != "file")
        ErrorExit("Neplatná hodnota Output: " OUTPUT_MODE ". Povolené hodnoty jsou PowerPoint nebo File.")

    if (FILE_FORMAT != "PNG" && FILE_FORMAT != "JPG" && FILE_FORMAT != "JPEG")
        ErrorExit("Neplatná hodnota FileFormat: " FILE_FORMAT ". Povolené hodnoty jsou PNG, JPG nebo JPEG.")
}

GetPipelineForPreset(config, preset_name) {
    if (StrLower(preset_name) = "default")
        pipeline_text := GetConfigText(config, "DefaultPipeline", "Fullscreen")
    else if (StrLower(preset_name) = "capture")
        pipeline_text := GetConfigText(config, "CapturePipeline", "FSCUT")
    else
        ErrorExit("Neznámý pipeline preset: " preset_name)

    pipeline_text := Trim(pipeline_text)
    if (pipeline_text = "")
        ErrorExit("Pipeline pro preset " preset_name " je prázdná.")

    ValidatePipeline(pipeline_text)
    return pipeline_text
}

ValidatePipeline(pipeline_text) {
    valid_layers := Map(
        "fullscreen", true,
        "fscut", true,
        "autotrim", true,
        "smarttrim", true,
        "fscutfallback", true
    )

    layer_count := 0
    for raw_layer in StrSplit(pipeline_text, ",") {
        layer := StrLower(Trim(raw_layer))
        if (layer = "")
            continue

        layer_count += 1
        if !valid_layers.Has(layer)
            ErrorExit("Neznámá vrstva pipeline: " raw_layer ".")
    }

    if (layer_count = 0)
        ErrorExit("Pipeline neobsahuje žádnou platnou vrstvu.")
}

GetProfileOrder() {
    profiles_config := LoadIniSection("Profiles")
    order_text := GetConfigText(profiles_config, "Order", "")
    result := []

    if (order_text = "")
        return result

    for profile_name in StrSplit(order_text, ",") {
        profile_name := Trim(profile_name)

        if (profile_name != "" && StrLower(profile_name) != "others")
            result.Push(profile_name)
    }

    return result
}

GetTargetProcesses() {
    targets_config := LoadIniSection("Targets")
    result := Map()

    for target_name, process_name in targets_config {
        process_name := StrLower(Trim(process_name))
        if (process_name != "")
            result[process_name] := target_name
    }
    return result
}


GetTargetProcessByAlias(alias_name) {
    targets_config := LoadIniSection("Targets")

    for target_name, process_name in targets_config {
        if (StrLower(target_name) = StrLower(alias_name))
            return StrLower(Trim(process_name))
    }

    return ""
}

IsTargetProcess(proc, target_processes) {
    return target_processes.Has(StrLower(proc))
}

IsIgnoredWindowClass(cls) {
    return cls = "Shell_TrayWnd"
        || cls = "Progman"
        || cls = "WorkerW"
        || cls = "ApplicationFrameWindow"
}

GetMonitorFromWindow(hwnd) {
    mon_count := MonitorGetCount()
    WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)

    best_monitor := 1
    best_area := -1

    Loop mon_count {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)

        overlap_left := Max(wx, ml)
        overlap_top := Max(wy, mt)
        overlap_right := Min(wx + ww, mr)
        overlap_bottom := Min(wy + wh, mb)

        overlap_w := overlap_right - overlap_left
        overlap_h := overlap_bottom - overlap_top

        area := 0
        if (overlap_w > 0 && overlap_h > 0)
            area := overlap_w * overlap_h

        if (area > best_area) {
            best_area := area
            best_monitor := A_Index
        }
    }

    Log("Monitor podle okna | HWND=" hwnd " | monitor=" best_monitor " | plocha=" best_area)
    return best_monitor
}

GetMonitorBounds(mon_num, &ml, &mt, &mr, &mb) {
    mon_count := MonitorGetCount()

    if (mon_num < 1 || mon_num > mon_count)
        ErrorExit("Zadaný monitor neexistuje. Monitor: " mon_num ", počet monitorů: " mon_count)

    MonitorGet(mon_num, &ml, &mt, &mr, &mb)
    Log("Souřadnice monitoru " mon_num " | L=" ml " T=" mt " R=" mr " B=" mb)
}


;==============================================================================
; WINDOWS UI AUTOMATION
;
; Používá nativní COM rozhraní Windows UI Automation.
; Adresní řádek se pouze čte - skript do něj nekliká, nepřesouvá focus,
; neposílá Ctrl+L a nepoužívá clipboard.
;==============================================================================

class UiInterface {
    __New(ptr) {
        if !ptr
            throw Error("UI Automation vrátil nulový ukazatel.")

        this.Ptr := ptr
    }

    __Delete() {
        if this.Ptr
            ObjRelease(this.Ptr)
    }
}

class UiVariant {
    __New(vt := unset, value := unset) {
        ; VARIANT má na 64bit Windows velikost 24 B.
        this.Buffer := Buffer(24, 0)
        this.Ptr := this.Buffer.Ptr

        if !IsSet(vt)
            return

        NumPut("UShort", vt, this.Buffer, 0)

        switch vt {
            case 8: ; VT_BSTR
                bstr := DllCall(
                    "OleAut32\SysAllocString",
                    "WStr", value,
                    "Ptr"
                )
                NumPut("Ptr", bstr, this.Buffer, 8)

            case 3: ; VT_I4
                NumPut("Int", value, this.Buffer, 8)

            case 11: ; VT_BOOL
                NumPut("Short", value ? -1 : 0, this.Buffer, 8)

            default:
                throw Error("Nepodporovaný VARIANT typ: " vt)
        }
    }

    GetValue() {
        vt := NumGet(this.Buffer, 0, "UShort")

        switch vt {
            case 0:
                return ""

            case 8:
                bstr := NumGet(this.Buffer, 8, "Ptr")
                return bstr ? StrGet(bstr, "UTF-16") : ""

            case 3:
                return NumGet(this.Buffer, 8, "Int")

            case 11:
                return NumGet(this.Buffer, 8, "Short") != 0

            default:
                return ""
        }
    }

    __Delete() {
        DllCall("OleAut32\VariantClear", "Ptr", this.Ptr)
    }
}

class UiElement extends UiInterface {
    FindFirst(condition, scope := 4) {
        found_ptr := 0

        hr := ComCall(
            5,
            this,
            "UInt", scope,
            "Ptr", condition.Ptr,
            "Ptr*", &found_ptr,
            "HRESULT"
        )

        if (hr < 0 || !found_ptr)
            return ""

        return UiElement(found_ptr)
    }

    GetCurrentPropertyValue(property_id) {
        value := UiVariant()

        hr := ComCall(
            10,
            this,
            "Int", property_id,
            "Ptr", value.Ptr,
            "HRESULT"
        )

        if (hr < 0)
            return ""

        return value.GetValue()
    }
}

GetUiAutomation() {
    static automation := ""

    if IsObject(automation)
        return automation

    automation := ComObject(
        "{E22AD333-B25F-460C-83D0-0581107395C9}",
        "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}"
    )

    return automation
}

UiElementFromHandle(hwnd) {
    automation := GetUiAutomation()
    element_ptr := 0

    hr := ComCall(
        6,
        automation,
        "Ptr", hwnd,
        "Ptr*", &element_ptr,
        "HRESULT"
    )

    if (hr < 0 || !element_ptr)
        return ""

    return UiElement(element_ptr)
}



UiCreatePropertyCondition(property_id, value, variant_type := 8) {
    automation := GetUiAutomation()
    variant := UiVariant(variant_type, value)
    condition_ptr := 0

    hr := ComCall(
        23,
        automation,
        "Int", property_id,
        "Ptr", variant.Ptr,
        "Ptr*", &condition_ptr,
        "HRESULT"
    )

    if (hr < 0 || !condition_ptr)
        return ""

    return UiInterface(condition_ptr)
}

UiCreateAndCondition(condition1, condition2) {
    automation := GetUiAutomation()
    condition_ptr := 0

    ; IUIAutomation::CreateAndCondition = vtable index 25.
    hr := ComCall(
        25,
        automation,
        "Ptr", condition1.Ptr,
        "Ptr", condition2.Ptr,
        "Ptr*", &condition_ptr,
        "HRESULT"
    )

    if (hr < 0 || !condition_ptr)
        return ""

    return UiInterface(condition_ptr)
}

HasUrlHost(url) {
    ; Přijmeme doménu, IPv4, localhost nebo variantu s protokolem.
    ; Relativní cesta typu /article/... záměrně neprojde.
    url := Trim(url)

    if (url = "")
        return false

    return RegExMatch(
        url,
        "i)^(?:https?://)?(?:localhost|(?:\d{1,3}\.){3}\d{1,3}|(?:[a-z0-9-]+\.)+[a-z]{2,})(?::\d+)?(?:/|$)"
    )
}



ShowRemoteDevToolsError() {
    static shown := false

    if shown
        return

    shown := true
    devtools_url := "chrome://inspect/#remote-debugging"

    dlg := Gui("+AlwaysOnTop", "YTPrintScreen – nelze identifikovat stránku")
    dlg.SetFont("s10", "Segoe UI")
    dlg.AddText(
        "w500",
        "Nelze jednoznačně identifikovat aktuální stránku.`n`n"
        "Povolte v prohlížeči Remote DevTools a poté spusťte skript znovu."
    )
    dlg.AddText("xm y+12", "Adresa nastavení:")
    dlg.AddEdit("xm w500 ReadOnly", devtools_url)

    copy_button := dlg.AddButton("xm y+14 w110", "Kopírovat")
    ok_button := dlg.AddButton("x+10 w90 Default", "OK")

    copy_button.OnEvent("Click", CopyRemoteDevToolsUrl.Bind(devtools_url))
    ok_button.OnEvent("Click", (*) => dlg.Destroy())
    dlg.OnEvent("Close", (*) => dlg.Destroy())
    dlg.OnEvent("Escape", (*) => dlg.Destroy())

    dlg.Show()
    WinWaitClose("ahk_id " dlg.Hwnd)
}

CopyRemoteDevToolsUrl(devtools_url, *) {
    A_Clipboard := devtools_url
}

GetChromeDevToolsTargets() {
    ; Lokální Chrome DevTools endpoint.
    ; Server musí běžet na 127.0.0.1:9222.
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.SetTimeouts(300, 300, 300, 300)
        http.Open("GET", "http://127.0.0.1:9222/json", false)
        http.Send()

        if (http.Status != 200)
            throw Error("DevTools endpoint vrátil HTTP " http.Status ".")

        json := http.ResponseText
        return ParseDevToolsTargets(json)

    } catch as e {
        Log("CDP fallback | DevTools endpoint není dostupný: " e.Message)
        throw e
    }
}

ParseDevToolsTargets(json) {
    ; Pro /json potřebujeme pouze title, type a url.
    ; AHK nemá vestavěný JSON parser, proto zde parsujeme jednotlivé objekty
    ; konzervativně z jednoduchého DevTools seznamu.
    targets := []
    pos := 1

    while RegExMatch(
        json,
        's)\{(.*?)(?:\}\s*,\s*\{|\}\s*\])',
        &obj_match,
        pos
    ) {
        obj_text := obj_match[1]

        target_type := JsonExtractString(obj_text, "type")
        target_title := JsonExtractString(obj_text, "title")
        target_url := JsonExtractString(obj_text, "url")

        if (target_type = "page" && target_url != "") {
            item := Map()
            item["title"] := target_title
            item["url"] := target_url
            targets.Push(item)
        }

        pos := obj_match.Pos + obj_match.Len - 1
    }

    ; Fallback pro případ, že regexp výše kvůli formátu nic nenajde.
    if (targets.Length = 0) {
        pos := 1
        while RegExMatch(json, 's)\{(.*?)\}', &simple_match, pos) {
            obj_text := simple_match[1]

            target_type := JsonExtractString(obj_text, "type")
            target_title := JsonExtractString(obj_text, "title")
            target_url := JsonExtractString(obj_text, "url")

            if (target_type = "page" && target_url != "") {
                item := Map()
                item["title"] := target_title
                item["url"] := target_url
                targets.Push(item)
            }

            pos := simple_match.Pos + simple_match.Len
        }
    }

    Log("CDP fallback | počet page targetů=" targets.Length)
    return targets
}

JsonExtractString(json_object, key) {
    pattern := '"' key '"\s*:\s*"((?:\\.|[^"\\])*)"'

    if !RegExMatch(json_object, pattern, &match)
        return ""

    value := match[1]

    ; Základní JSON unescape pro hodnoty, které zde potřebujeme.
    value := StrReplace(value, '\/', '/')
    value := StrReplace(value, '\"', '"')
    value := StrReplace(value, '\\', '\')

    return value
}

NormalizeWindowTitleForMatch(title) {
    ; Chrome přidává na konec titulku " - Google Chrome".
    title := RegExReplace(title, '\s*-\s*Google Chrome\s*$', '')
    title := RegExReplace(title, '\s*-\s*Chromium\s*$', '')
    return Trim(title)
}

GetUrlFromChromeDevTools(hwnd) {
    try {
        window_title := WinGetTitle("ahk_id " hwnd)
    } catch {
        return ""
    }

    normalized_window_title := NormalizeWindowTitleForMatch(window_title)
    targets := GetChromeDevToolsTargets()

    if (targets.Length = 0)
        return ""

    ; 1) Přesná shoda titulku stránky.
    for item in targets {
        if (item["title"] = normalized_window_title) {
            Log("CDP fallback | přesná shoda titulku | TITLE=" item["title"] " | URL=" item["url"])
            return item["url"]
        }
    }

    ; 2) Tolerantní shoda pro případy drobného rozdílu titulku.
    for item in targets {
        if (item["title"] != "" && (
            InStr(normalized_window_title, item["title"])
            || InStr(item["title"], normalized_window_title)
        )) {
            Log("CDP fallback | tolerantní shoda titulku | WINDOW=" normalized_window_title
                " | TARGET=" item["title"] " | URL=" item["url"])
            return item["url"]
        }
    }

    Log("CDP fallback | nepodařilo se jednoznačně spárovat aktivní okno s page targetem"
        " | WINDOW TITLE=" normalized_window_title)

    return ""
}

GetBrowserUrl(hwnd) {
    ; UIA_ControlTypePropertyId      = 30003
    ; UIA_NamePropertyId             = 30005
    ; UIA_AcceleratorKeyPropertyId   = 30006
    ; UIA_AutomationIdPropertyId     = 30011
    ; UIA_ValueValuePropertyId       = 30045
    ; UIA_EditControlTypeId          = 50004
    ; TreeScope_Descendants          = 4

    try {
        root := UiElementFromHandle(hwnd)

        if !IsObject(root) {
            Log("UIA URL | HWND=" hwnd " | nepodařilo se získat kořen okna.")
            return ""
        }

        accelerator_condition := UiCreatePropertyCondition(30006, "Ctrl+L", 8)
        edit_condition := UiCreatePropertyCondition(30003, 50004, 3)

        if !IsObject(accelerator_condition) || !IsObject(edit_condition) {
            Log("UIA URL | HWND=" hwnd " | nepodařilo se vytvořit podmínky adresního řádku.")
            return ""
        }

        address_condition := UiCreateAndCondition(accelerator_condition, edit_condition)

        if !IsObject(address_condition) {
            Log("UIA URL | HWND=" hwnd " | nepodařilo se vytvořit kombinovanou podmínku adresního řádku.")
            return ""
        }

        address_bar := root.FindFirst(address_condition, 4)

        if !IsObject(address_bar) {
            Log("UIA URL | HWND=" hwnd " | adresní řádek Ctrl+L + Edit nebyl nalezen.")
            return ""
        }

        url := Trim(address_bar.GetCurrentPropertyValue(30045))
        element_name := Trim(address_bar.GetCurrentPropertyValue(30005))
        automation_id := Trim(address_bar.GetCurrentPropertyValue(30011))

        Log("UIA AddressBar | HWND=" hwnd
            " | Name=" element_name
            " | AutomationId=" automation_id
            " | Value=" url)

        if HasUrlHost(url) {
            Log("UIA URL | HWND=" hwnd " | URL=" url)
            return url
        }

        Log("UIA URL | HWND=" hwnd
            " | hodnota neobsahuje doménu, zkouším CDP fallback | Value=" url)

        try {
            cdp_url := GetUrlFromChromeDevTools(hwnd)
        } catch as e {
            Log("CDP URL | HWND=" hwnd " | fallback selhal: " e.Message)
            ShowRemoteDevToolsError()
            return ""
        }

        if HasUrlHost(cdp_url) {
            Log("CDP URL | HWND=" hwnd " | URL=" cdp_url)
            return cdp_url
        }

        Log("UIA/CDP URL | HWND=" hwnd
            " | nepodařilo se získat úplnou URL.")
        return ""

    } catch as e {
        Log("UIA/CDP URL | HWND=" hwnd " | CHYBA=" e.Message)
        return ""
    }
}

GetCandidateTargetWindows(forced_monitor, target_processes) {
    candidates := []
    for hwnd in WinGetList() {
        try {
            if !DllCall("IsWindowVisible", "ptr", hwnd)
                continue
            proc := WinGetProcessName("ahk_id " hwnd)
            cls := WinGetClass("ahk_id " hwnd)
            title := WinGetTitle("ahk_id " hwnd)
            if !IsTargetProcess(proc, target_processes)
                continue
            if IsIgnoredWindowClass(cls)
                continue
            if (title = "")
                continue
            if (forced_monitor > 0 && GetMonitorFromWindow(hwnd) != forced_monitor)
                continue

            item := Map("hwnd", hwnd, "title", title, "proc", proc)
            candidates.Push(item)
            Log("Nalezen cílový proces | HWND=" hwnd " | PROC=" proc " | TITLE=" title)
        } catch as e {
            Log("Přeskočeno okno: " e.Message)
        }
    }
    return candidates
}

GetWindowItem(hwnd) {
    try {
        return Map(
            "hwnd", hwnd,
            "title", WinGetTitle("ahk_id " hwnd),
            "proc", WinGetProcessName("ahk_id " hwnd)
        )
    } catch {
        return ""
    }
}

MatchWindowToProfile(item, profile_name) {
    profile_config := LoadIniSection(profile_name)
    match_title := GetConfigText(profile_config, "MatchTitle", "")
    match_url := GetConfigText(profile_config, "MatchURL", "")

    if (match_title = "" && match_url = "") {
        Log("CHYBA KONFIGURACE: Profil [" profile_name "] nemá MatchTitle ani MatchURL. Profil se ignoruje.")
        return false
    }

    if (match_title != "") {
        try {
            if !RegExMatch(item["title"], match_title)
                return false
        } catch as e {
            Log("Neplatný MatchTitle v profilu " profile_name ": " match_title " | " e.Message)
            return false
        }
    }

    if (match_url != "") {
        if !item.Has("url")
            item["url"] := GetBrowserUrl(item["hwnd"])
        if (item["url"] = "") {
            Log("Profil " profile_name " | URL se nepodařilo načíst | TITLE=" item["title"])
            return false
        }
        try {
            if !RegExMatch(item["url"], match_url) {
                Log("MatchURL bez shody | PROFILE=" profile_name " | URL=" item["url"] " | REGEX=" match_url)
                return false
            }
        } catch as e {
            Log("Neplatný MatchURL v profilu " profile_name ": " match_url " | " e.Message)
            return false
        }
    }
    return true
}

DetectWindowProfile(item, profile_order) {
    for profile_name in profile_order {
        if MatchWindowToProfile(item, profile_name)
            return profile_name
    }
    return "Others"
}


ValidateForcedProfile(profile_name) {
    if (StrLower(profile_name) = "others")
        ErrorExit("Profil [Others] nelze použít s parametrem --profile.")

    profile_config := LoadIniSection(profile_name)

    if (profile_config.Count = 0)
        ErrorExit("Profil [" profile_name "] nebyl v INI nalezen.")

    ; U --profile může profil odpovídat přímo aliasu v [Targets].
    ; V tom případě je proces základním výběrovým kritériem a Match*
    ; jsou pouze volitelné upřesnění při více oknech stejného procesu.
    target_process := GetTargetProcessByAlias(profile_name)

    if (target_process != "")
        return

    ; Pokud alias v [Targets] neexistuje, musí mít profil běžné Match*.
    match_title := GetConfigText(profile_config, "MatchTitle", "")
    match_url := GetConfigText(profile_config, "MatchURL", "")

    if (match_title = "" && match_url = "")
        ErrorExit("Profil [" profile_name "] nemá odpovídající položku v [Targets] ani MatchTitle/MatchURL.")
}

FindTargetWindowByProfile(profile_name, forced_monitor, target_processes, &selected_profile) {
    ValidateForcedProfile(profile_name)

    ; Pokud název profilu odpovídá aliasu v [Targets], --profile nejprve
    ; omezí kandidáty pouze na daný proces.
    target_process := GetTargetProcessByAlias(profile_name)

    candidates := GetCandidateTargetWindows(forced_monitor, target_processes)

    if (target_process != "") {
        process_candidates := []

        for item in candidates {
            if (StrLower(item["proc"]) = target_process)
                process_candidates.Push(item)
        }

        if (process_candidates.Length = 0) {
            Log("Vynucený profil z CLI nenalezl okno požadovaného procesu"
                " | PROFILE=" profile_name
                " | PROC=" target_process)
            return 0
        }

        ; Pokud existuje jen jedno okno daného procesu, není co upřesňovat.
        if (process_candidates.Length = 1) {
            selected_profile := profile_name

            Log("Výběr okna: vynucený profil, jediné okno procesu"
                " | PROFILE=" profile_name
                " | PROC=" process_candidates[1]["proc"]
                " | TITLE=" process_candidates[1]["title"])

            return process_candidates[1]["hwnd"]
        }

        profile_config := LoadIniSection(profile_name)
        match_title := GetConfigText(profile_config, "MatchTitle", "")
        match_url := GetConfigText(profile_config, "MatchURL", "")

        ; Match* jsou při --profile pouze preferenční filtr.
        ; Pokud něco uloví, vezme se první shoda v Z-orderu.
        if (match_title != "" || match_url != "") {
            for item in process_candidates {
                if MatchWindowToProfile(item, profile_name) {
                    selected_profile := profile_name

                    Log("Výběr okna: vynucený profil, Match* upřesnění"
                        " | PROFILE=" profile_name
                        " | PROC=" item["proc"]
                        " | TITLE=" item["title"])

                    return item["hwnd"]
                }
            }

            Log("Vynucený profil: Match* nic nenašel, používám Z-order fallback"
                " | PROFILE=" profile_name
                " | PROC=" target_process)
        }

        ; Fallback: první okno daného procesu v Z-orderu.
        selected_profile := profile_name

        Log("Výběr okna: vynucený profil, Z-order fallback"
            " | PROFILE=" profile_name
            " | PROC=" process_candidates[1]["proc"]
            " | TITLE=" process_candidates[1]["title"])

        return process_candidates[1]["hwnd"]
    }

    ; Pokud profil nemá stejnojmenný alias v [Targets], zůstává standardní
    ; chování podle MatchTitle / MatchURL.
    for item in candidates {
        if MatchWindowToProfile(item, profile_name) {
            selected_profile := profile_name

            Log("Výběr okna: vynucený profil podle Match*"
                " | PROFILE=" profile_name
                " | PROC=" item["proc"]
                " | TITLE=" item["title"])

            return item["hwnd"]
        }
    }

    Log("Vynucený profil z CLI nenalezl vhodné okno | PROFILE=" profile_name)
    return 0
}

FindBestTargetWindow(forced_monitor, profile_order, target_processes, &selected_profile) {
    ; Explicitní volba uživatele má přednost.
    try {
        active_hwnd := WinGetID("A")
        active_item := GetWindowItem(active_hwnd)
        if IsObject(active_item)
            && IsTargetProcess(active_item["proc"], target_processes)
            && !IsIgnoredWindowClass(WinGetClass("ahk_id " active_hwnd))
            && active_item["title"] != "" {

            selected_profile := DetectWindowProfile(active_item, profile_order)
            Log("Výběr okna: aktivní okno uživatele | HWND=" active_hwnd
                " | PROC=" active_item["proc"] " | PROFILE=" selected_profile
                " | TITLE=" active_item["title"])
            return active_hwnd
        }
    } catch as e {
        Log("Aktivní okno nelze použít jako cíl: " e.Message)
    }

    ; Jinak automatický výběr podle priority profilů.
    candidates := GetCandidateTargetWindows(forced_monitor, target_processes)
    if (candidates.Length = 0)
        return 0

    for profile_name in profile_order {
        for item in candidates {
            if MatchWindowToProfile(item, profile_name) {
                selected_profile := profile_name
                Log("Výběr okna: automaticky podle priority | PROFILE=" profile_name
                    " | PROC=" item["proc"] " | TITLE=" item["title"])
                return item["hwnd"]
            }
        }
    }

    selected_profile := "Others"
    Log("Výběr okna: automatický fallback Others | PROC=" candidates[1]["proc"]
        " | TITLE=" candidates[1]["title"])
    return candidates[1]["hwnd"]
}


CreateFSCUTBitmap(source_hbm, &error_message) {
    global FSCUT_X, FSCUT_Y, FSCUT_W, FSCUT_H

    error_message := ""

    if !GetHBitmapSize(source_hbm, &source_width, &source_height) {
        error_message := "Nelze zjistit rozměr zdrojové bitmapy."
        return 0
    }

    if (FSCUT_X < 0 || FSCUT_Y < 0 || FSCUT_W <= 0 || FSCUT_H <= 0) {
        error_message := "Neplatná geometrie FSCUT."
        return 0
    }

    if (FSCUT_X + FSCUT_W > source_width || FSCUT_Y + FSCUT_H > source_height) {
        error_message := "FSCUT přesahuje zdrojovou bitmapu " source_width "x" source_height "."
        return 0
    }

    cropped_hbm := CropHBitmap(source_hbm, FSCUT_X, FSCUT_Y, FSCUT_W, FSCUT_H)
    if !cropped_hbm {
        error_message := "Nepodařilo se vytvořit pevný FSCUT."
        return 0
    }

    Log("FSCUT | X=" FSCUT_X " | Y=" FSCUT_Y " | W=" FSCUT_W " | H=" FSCUT_H)
    return cropped_hbm
}

CloneHBitmap(source_hbm) {
    if !GetHBitmapSize(source_hbm, &width, &height)
        return 0

    return CropHBitmap(source_hbm, 0, 0, width, height)
}

ExecuteCapturePipeline(full_hbm, pipeline_text, profile_name, &result_method) {
    global AUTO_TRIM_TOLERANCE

    if GetHBitmapSize(full_hbm, &pipeline_width, &pipeline_height)
        Log("Pipeline | START | PROFILE=" profile_name " | definition=" pipeline_text " | source=" pipeline_width "x" pipeline_height)
    else
        Log("Pipeline | START | PROFILE=" profile_name " | definition=" pipeline_text " | source=unknown")

    result_method := "Fullscreen"
    current_hbm := CloneHBitmap(full_hbm)
    if !current_hbm {
        DllCall("DeleteObject", "Ptr", full_hbm)
        return 0
    }

    intelligent_attempted := false
    intelligent_succeeded := false

    for raw_layer in StrSplit(pipeline_text, ",") {
        layer := StrLower(Trim(raw_layer))
        if (layer = "")
            continue

        if (layer = "fullscreen") {
            Log("Pipeline | Fullscreen | bez ořezu")
            result_method := "Fullscreen"
            continue
        }

        if (layer = "fscut") {
            fixed_hbm := CreateFSCUTBitmap(full_hbm, &fscut_error)
            if !fixed_hbm {
                Log("Pipeline | FSCUT selhal | " fscut_error)
                DllCall("DeleteObject", "Ptr", current_hbm)
                DllCall("DeleteObject", "Ptr", full_hbm)
                return 0
            }

            DllCall("DeleteObject", "Ptr", current_hbm)
            current_hbm := fixed_hbm
            result_method := "FSCUT"
            intelligent_attempted := false
            intelligent_succeeded := false
            continue
        }

        if (layer = "autotrim" || layer = "smarttrim") {
            intelligent_attempted := true
            use_smart_trim := (layer = "smarttrim")
            before_hbm := current_hbm
            current_hbm := ApplyAutoTrim(
                current_hbm,
                AUTO_TRIM_TOLERANCE,
                use_smart_trim,
                profile_name
            )
            intelligent_succeeded := (current_hbm != before_hbm)

            if intelligent_succeeded {
                result_method := use_smart_trim ? "SmartTrim" : "AutoTrim"
                Log("Pipeline | " result_method " | úspěch")
            } else {
                Log("Pipeline | " (use_smart_trim ? "SmartTrim" : "AutoTrim") " | odmítnuto / beze změny")
            }
            continue
        }

        if (layer = "fscutfallback") {
            if (intelligent_attempted && intelligent_succeeded) {
                Log("Pipeline | FSCUTFallback přeskočen | předchozí inteligentní trim uspěl")
                continue
            }

            fallback_hbm := CreateFSCUTBitmap(full_hbm, &fallback_error)
            if !fallback_hbm {
                Log("Pipeline | FSCUTFallback selhal | " fallback_error)
                continue
            }

            DllCall("DeleteObject", "Ptr", current_hbm)
            current_hbm := fallback_hbm
            result_method := "FSCUT fallback"
            Log("Pipeline | FSCUTFallback | použit pevný výřez")
            continue
        }
    }

    if GetHBitmapSize(current_hbm, &result_width, &result_height)
        Log("Pipeline | END | method=" result_method " | result=" result_width "x" result_height)
    else
        Log("Pipeline | END | method=" result_method " | result=unknown")

    DllCall("DeleteObject", "Ptr", full_hbm)
    return current_hbm
}

CaptureMonitorBitmap(ml, mt, mw, mh, &error_message) {
    error_message := ""

    hdc_screen := DllCall("GetDC", "ptr", 0, "ptr")
    if !hdc_screen {
        error_message := "GetDC selhalo."
        return 0
    }

    hdc_mem := DllCall("CreateCompatibleDC", "ptr", hdc_screen, "ptr")
    if !hdc_mem {
        DllCall("ReleaseDC", "ptr", 0, "ptr", hdc_screen)
        error_message := "CreateCompatibleDC selhalo."
        return 0
    }

    hbm := DllCall("CreateCompatibleBitmap", "ptr", hdc_screen, "int", mw, "int", mh, "ptr")
    if !hbm {
        DllCall("DeleteDC", "ptr", hdc_mem)
        DllCall("ReleaseDC", "ptr", 0, "ptr", hdc_screen)
        error_message := "CreateCompatibleBitmap selhalo."
        return 0
    }

    old := DllCall("SelectObject", "ptr", hdc_mem, "ptr", hbm, "ptr")

    ok := DllCall("BitBlt"
        , "ptr", hdc_mem
        , "int", 0
        , "int", 0
        , "int", mw
        , "int", mh
        , "ptr", hdc_screen
        , "int", ml
        , "int", mt
        , "uint", 0x00CC0020)

    DllCall("SelectObject", "ptr", hdc_mem, "ptr", old)
    DllCall("DeleteDC", "ptr", hdc_mem)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdc_screen)

    if !ok {
        DllCall("DeleteObject", "ptr", hbm)
        error_message := "BitBlt selhalo."
        return 0
    }

    return hbm
}

GetHBitmapSize(hbm, &width, &height) {
    width := 0
    height := 0

    bitmap_info := Buffer(A_PtrSize = 8 ? 32 : 24, 0)
    result := DllCall(
        "gdi32\GetObjectW",
        "Ptr", hbm,
        "Int", bitmap_info.Size,
        "Ptr", bitmap_info.Ptr,
        "Int"
    )

    if !result
        return false

    width := NumGet(bitmap_info, 4, "Int")
    height := Abs(NumGet(bitmap_info, 8, "Int"))
    return (width > 0 && height > 0)
}

GetHBitmapPixels32(hbm, width, height, &pixel_buffer) {
    pixel_buffer := Buffer(width * height * 4, 0)

    bitmap_header := Buffer(40, 0)
    NumPut("UInt", 40, bitmap_header, 0)
    NumPut("Int", width, bitmap_header, 4)
    NumPut("Int", -height, bitmap_header, 8)
    NumPut("UShort", 1, bitmap_header, 12)
    NumPut("UShort", 32, bitmap_header, 14)
    NumPut("UInt", 0, bitmap_header, 16)

    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    if !hdc
        return false

    try {
        lines := DllCall(
            "gdi32\GetDIBits",
            "Ptr", hdc,
            "Ptr", hbm,
            "UInt", 0,
            "UInt", height,
            "Ptr", pixel_buffer.Ptr,
            "Ptr", bitmap_header.Ptr,
            "UInt", 0,
            "Int"
        )
    } finally {
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    }

    return (lines = height)
}

GetPixelRgb(pixel_buffer, width, x, y) {
    offset := ((y * width) + x) * 4
    blue := NumGet(pixel_buffer, offset, "UChar")
    green := NumGet(pixel_buffer, offset + 1, "UChar")
    red := NumGet(pixel_buffer, offset + 2, "UChar")
    return [red, green, blue]
}

ColorDistanceSquared(color_a, color_b) {
    dr := color_a[1] - color_b[1]
    dg := color_a[2] - color_b[2]
    db := color_a[3] - color_b[3]
    return dr * dr + dg * dg + db * db
}

AverageCornerColor(pixel_buffer, width, height, left, top, right, bottom) {
    red_sum := 0
    green_sum := 0
    blue_sum := 0
    sample_count := 0

    step_x := Max(1, Floor((right - left + 1) / 4))
    step_y := Max(1, Floor((bottom - top + 1) / 4))

    y := top
    while (y <= bottom) {
        x := left
        while (x <= right) {
            color := GetPixelRgb(pixel_buffer, width, x, y)
            red_sum += color[1]
            green_sum += color[2]
            blue_sum += color[3]
            sample_count += 1
            x += step_x
        }
        y += step_y
    }

    if (sample_count = 0)
        return [0, 0, 0]

    return [
        Round(red_sum / sample_count),
        Round(green_sum / sample_count),
        Round(blue_sum / sample_count)
    ]
}

DetectAutoTrimBackground(pixel_buffer, width, height, tolerance_percent, &corner_match_count := 0) {
    patch_size := Max(4, Min(16, Floor(Min(width, height) / 30)))
    max_x := width - 1
    max_y := height - 1

    corner_colors := [
        AverageCornerColor(pixel_buffer, width, height, 0, 0, patch_size - 1, patch_size - 1),
        AverageCornerColor(pixel_buffer, width, height, width - patch_size, 0, max_x, patch_size - 1),
        AverageCornerColor(pixel_buffer, width, height, 0, height - patch_size, patch_size - 1, max_y),
        AverageCornerColor(pixel_buffer, width, height, width - patch_size, height - patch_size, max_x, max_y)
    ]

    cluster_percent := Max(tolerance_percent * 2, 2)
    cluster_threshold_squared := 3 * 255 * 255 * ((cluster_percent / 100) ** 2)

    best_index := 0
    best_count := 0

    for index, color in corner_colors {
        match_count := 0

        for other_color in corner_colors {
            if (ColorDistanceSquared(color, other_color) <= cluster_threshold_squared)
                match_count += 1
        }

        if (match_count > best_count) {
            best_count := match_count
            best_index := index
        }
    }

    corner_match_count := best_count

    ; Bez shody alespoň dvou rohů není pozadí dostatečně jednoznačné.
    if (best_count < 2)
        return 0

    reference_color := corner_colors[best_index]
    red_sum := 0
    green_sum := 0
    blue_sum := 0
    cluster_count := 0

    for color in corner_colors {
        if (ColorDistanceSquared(reference_color, color) <= cluster_threshold_squared) {
            red_sum += color[1]
            green_sum += color[2]
            blue_sum += color[3]
            cluster_count += 1
        }
    }

    return [
        Round(red_sum / cluster_count),
        Round(green_sum / cluster_count),
        Round(blue_sum / cluster_count)
    ]
}

IsAutoTrimBackgroundRow(pixel_buffer, width, y, background_color, threshold_squared) {
    ; Sampling drží analýzu rychlou i pro Full HD. Řádek je považován za pozadí,
    ; pokud alespoň 75 % vzorků odpovídá barvě mrtvé zóny.
    sample_step := Max(1, Floor(width / 180))
    sample_count := 0
    background_count := 0

    x := 0
    while (x < width) {
        color := GetPixelRgb(pixel_buffer, width, x, y)
        sample_count += 1

        if (ColorDistanceSquared(color, background_color) <= threshold_squared)
            background_count += 1

        x += sample_step
    }

    return sample_count > 0 && (background_count / sample_count >= 0.75)
}

IsAutoTrimBackgroundColumn(pixel_buffer, width, height, x, background_color, threshold_squared) {
    sample_step := Max(1, Floor(height / 180))
    sample_count := 0
    background_count := 0

    y := 0
    while (y < height) {
        color := GetPixelRgb(pixel_buffer, width, x, y)
        sample_count += 1

        if (ColorDistanceSquared(color, background_color) <= threshold_squared)
            background_count += 1

        y += sample_step
    }

    return sample_count > 0 && (background_count / sample_count >= 0.75)
}

FindAutoTrimBoundary(pixel_buffer, width, height, side, background_color, threshold_squared) {
    ; Dvě jednotlivé rušivé linky uvnitř mrtvé zóny ještě nezastaví hledání.
    required_content_run := 3
    content_run := 0

    if (side = "top") {
        index := 0
        while (index < height) {
            if IsAutoTrimBackgroundRow(pixel_buffer, width, index, background_color, threshold_squared)
                content_run := 0
            else
                content_run += 1

            if (content_run >= required_content_run)
                return Max(0, index - required_content_run + 1)

            index += 1
        }
        return 0
    }

    if (side = "bottom") {
        index := height - 1
        while (index >= 0) {
            if IsAutoTrimBackgroundRow(pixel_buffer, width, index, background_color, threshold_squared)
                content_run := 0
            else
                content_run += 1

            if (content_run >= required_content_run)
                return Min(height - 1, index + required_content_run - 1)

            index -= 1
        }
        return height - 1
    }

    if (side = "left") {
        index := 0
        while (index < width) {
            if IsAutoTrimBackgroundColumn(pixel_buffer, width, height, index, background_color, threshold_squared)
                content_run := 0
            else
                content_run += 1

            if (content_run >= required_content_run)
                return Max(0, index - required_content_run + 1)

            index += 1
        }
        return 0
    }

    index := width - 1
    while (index >= 0) {
        if IsAutoTrimBackgroundColumn(pixel_buffer, width, height, index, background_color, threshold_squared)
            content_run := 0
        else
            content_run += 1

        if (content_run >= required_content_run)
            return Min(width - 1, index + required_content_run - 1)

        index -= 1
    }

    return width - 1
}


IsMostlyBlackRow(pixel_buffer, width, left, right, y) {
    ; Detekce je úmyslně přísná: SmartTrim má odstranit jen skutečně černý
    ; UI / letterbox pás, nikoliv tmavou část fotografie nebo videa.
    sample_step := Max(1, Floor((right - left + 1) / 180))
    sample_count := 0
    black_count := 0
    black_limit := 32

    x := left
    while (x <= right) {
        color := GetPixelRgb(pixel_buffer, width, x, y)
        sample_count += 1

        if (color[1] <= black_limit && color[2] <= black_limit && color[3] <= black_limit)
            black_count += 1

        x += sample_step
    }

    return sample_count > 0 && (black_count / sample_count >= 0.90)
}

IsMostlyBlackColumn(pixel_buffer, width, top, bottom, x) {
    sample_step := Max(1, Floor((bottom - top + 1) / 180))
    sample_count := 0
    black_count := 0
    black_limit := 32

    y := top
    while (y <= bottom) {
        color := GetPixelRgb(pixel_buffer, width, x, y)
        sample_count += 1

        if (color[1] <= black_limit && color[2] <= black_limit && color[3] <= black_limit)
            black_count += 1

        y += sample_step
    }

    return sample_count > 0 && (black_count / sample_count >= 0.90)
}

FindSmartTrimBlackEdgeBoundary(pixel_buffer, width, height, left, top, right, bottom, side) {
    ; Hledá pouze úzký černý pás bezprostředně u hrany již nalezeného obsahu.
    ; Několik vnějších řádků/sloupců může mít jinou barvu (typicky červená
    ; progress linka), ale za nimi musí následovat souvislý černý pás.
    max_outer_noise := 5
    required_black_run := 3

    if (side = "top" || side = "bottom") {
        span := bottom - top + 1
        max_scan := Min(64, Max(8, Round(span * 0.08)))
        index := (side = "top") ? top : bottom
        step := (side = "top") ? 1 : -1
        limit := (side = "top") ? Min(bottom, top + max_scan - 1) : Max(top, bottom - max_scan + 1)
        outer_noise := 0
        black_run := 0
        black_found := false

        while ((step > 0 && index <= limit) || (step < 0 && index >= limit)) {
            if IsMostlyBlackRow(pixel_buffer, width, left, right, index) {
                black_found := true
                black_run += 1
            } else if !black_found {
                outer_noise += 1
                if (outer_noise > max_outer_noise)
                    return (side = "top") ? top : bottom
            } else {
                if (black_run >= required_black_run)
                    return index
                return (side = "top") ? top : bottom
            }

            index += step
        }

        return (side = "top") ? top : bottom
    }

    span := right - left + 1
    max_scan := Min(64, Max(8, Round(span * 0.08)))
    index := (side = "left") ? left : right
    step := (side = "left") ? 1 : -1
    limit := (side = "left") ? Min(right, left + max_scan - 1) : Max(left, right - max_scan + 1)
    outer_noise := 0
    black_run := 0
    black_found := false

    while ((step > 0 && index <= limit) || (step < 0 && index >= limit)) {
        if IsMostlyBlackColumn(pixel_buffer, width, top, bottom, index) {
            black_found := true
            black_run += 1
        } else if !black_found {
            outer_noise += 1
            if (outer_noise > max_outer_noise)
                return (side = "left") ? left : right
        } else {
            if (black_run >= required_black_run)
                return index
            return (side = "left") ? left : right
        }

        index += step
    }

    return (side = "left") ? left : right
}

ApplySmartTrimEdgeCleanup(pixel_buffer, width, height, &left, &top, &right, &bottom) {
    original_left := left
    original_top := top
    original_right := right
    original_bottom := bottom

    Log("SmartTrim edge cleanup | START"
        " | source=" width "x" height
        " | candidate=" original_left "," original_top "-" original_right "," original_bottom)

    ; Svislé hrany vyhodnotíme z původního kandidáta.
    new_top := FindSmartTrimBlackEdgeBoundary(
        pixel_buffer, width, height,
        left, top, right, bottom,
        "top"
    )
    new_bottom := FindSmartTrimBlackEdgeBoundary(
        pixel_buffer, width, height,
        left, top, right, bottom,
        "bottom"
    )

    if (new_top > top)
        top := new_top
    if (new_bottom < bottom)
        bottom := new_bottom

    ; Vodorovné hrany už používají případně očištěnou výšku.
    new_left := FindSmartTrimBlackEdgeBoundary(
        pixel_buffer, width, height,
        left, top, right, bottom,
        "left"
    )
    new_right := FindSmartTrimBlackEdgeBoundary(
        pixel_buffer, width, height,
        left, top, right, bottom,
        "right"
    )

    if (new_left > left)
        left := new_left
    if (new_right < right)
        right := new_right

    if (left != original_left || top != original_top
        || right != original_right || bottom != original_bottom) {
        Log("SmartTrim edge cleanup | CHANGED"
            " | before=" original_left "," original_top "-" original_right "," original_bottom
            " | after=" left "," top "-" right "," bottom)
        return true
    }

    Log("SmartTrim edge cleanup | NO CHANGE"
        " | candidate=" left "," top "-" right "," bottom)
    return false
}

CropHBitmap(hbm, left, top, width, height) {
    source_dc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    destination_dc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")

    if !source_dc || !destination_dc {
        if source_dc
            DllCall("DeleteDC", "Ptr", source_dc)
        if destination_dc
            DllCall("DeleteDC", "Ptr", destination_dc)
        return 0
    }

    source_old := DllCall("SelectObject", "Ptr", source_dc, "Ptr", hbm, "Ptr")
    screen_dc := DllCall("GetDC", "Ptr", 0, "Ptr")

    if !screen_dc {
        DllCall("SelectObject", "Ptr", source_dc, "Ptr", source_old)
        DllCall("DeleteDC", "Ptr", source_dc)
        DllCall("DeleteDC", "Ptr", destination_dc)
        return 0
    }

    destination_hbm := DllCall(
        "CreateCompatibleBitmap",
        "Ptr", screen_dc,
        "Int", width,
        "Int", height,
        "Ptr"
    )
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen_dc)

    if !destination_hbm {
        DllCall("SelectObject", "Ptr", source_dc, "Ptr", source_old)
        DllCall("DeleteDC", "Ptr", source_dc)
        DllCall("DeleteDC", "Ptr", destination_dc)
        return 0
    }

    destination_old := DllCall("SelectObject", "Ptr", destination_dc, "Ptr", destination_hbm, "Ptr")

    ok := DllCall(
        "BitBlt",
        "Ptr", destination_dc,
        "Int", 0,
        "Int", 0,
        "Int", width,
        "Int", height,
        "Ptr", source_dc,
        "Int", left,
        "Int", top,
        "UInt", 0x00CC0020
    )

    DllCall("SelectObject", "Ptr", destination_dc, "Ptr", destination_old)
    DllCall("SelectObject", "Ptr", source_dc, "Ptr", source_old)
    DllCall("DeleteDC", "Ptr", destination_dc)
    DllCall("DeleteDC", "Ptr", source_dc)

    if !ok {
        DllCall("DeleteObject", "Ptr", destination_hbm)
        return 0
    }

    return destination_hbm
}


GetSmartTrimSectionName(profile_name) {
    ; Každý profil se učí samostatně, aby jeden web neovlivňoval jiný.
    safe_name := RegExReplace(profile_name, "[^A-Za-z0-9_-]", "_")
    if (safe_name = "")
        safe_name := "Others"
    return "Profile:" safe_name
}

LoadSmartTrimSizes(profile_name) {
    global SMART_TRIM_FILE

    sizes := []
    if !FileExist(SMART_TRIM_FILE)
        return sizes

    section_name := GetSmartTrimSectionName(profile_name)

    try section_text := IniRead(SMART_TRIM_FILE, section_name)
    catch
        return sizes

    for line in StrSplit(section_text, "`n", "`r") {
        line := Trim(line)
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue

        separator_pos := InStr(line, "=")
        if !separator_pos
            continue

        key := Trim(SubStr(line, 1, separator_pos - 1))
        value := Trim(SubStr(line, separator_pos + 1))

        if !RegExMatch(key, "i)^Size_(\d+)x(\d+)$", &match)
            continue
        if !IsNumber(value)
            continue

        width := Integer(match[1])
        height := Integer(match[2])
        count := Max(1, Integer(value))

        if (width > 0 && height > 0)
            sizes.Push(Map("width", width, "height", height, "count", count))
    }

    return sizes
}

LearnSmartTrimSize(profile_name, width, height) {
    global SMART_TRIM_FILE

    if (width <= 0 || height <= 0)
        return

    section_name := GetSmartTrimSectionName(profile_name)
    key := "Size_" width "x" height
    current_count := 0

    try current_count := IniRead(SMART_TRIM_FILE, section_name, key, 0) + 0
    catch
        current_count := 0

    new_count := Max(0, current_count) + 1

    try {
        IniWrite(new_count, SMART_TRIM_FILE, section_name, key)
        Log("SmartTrim learn | PROFILE=" profile_name
            " | size=" width "x" height
            " | count=" new_count)
    } catch as e {
        Log("SmartTrim learn selhal | PROFILE=" profile_name " | " e.Message)
    }
}

FindSmartTrimSize(profile_name, candidate_width, candidate_height, source_width, source_height, tolerance_percent) {
    if (tolerance_percent <= 0)
        return 0

    known_sizes := LoadSmartTrimSizes(profile_name)
    if (known_sizes.Length = 0)
        return 0

    tolerance_ratio := tolerance_percent / 100
    best := 0
    best_score := 1.0e9

    for item in known_sizes {
        known_width := item["width"]
        known_height := item["height"]

        if (known_width > source_width || known_height > source_height)
            continue

        width_diff := Abs(candidate_width - known_width) / known_width
        height_diff := Abs(candidate_height - known_height) / known_height

        candidate_ratio := candidate_width / candidate_height
        known_ratio := known_width / known_height
        ratio_diff := Abs(candidate_ratio - known_ratio) / known_ratio

        ; Používá se existující AutoTrimTolerance. Oba rozměry musí být blízko
        ; naučené velikosti a poměr stran přidává další jistotu.
        if (width_diff > tolerance_ratio || height_diff > tolerance_ratio)
            continue
        if (ratio_diff > tolerance_ratio)
            continue

        ; Při podobné geometrii má přednost častěji potvrzený rozměr.
        frequency_bonus := Min(item["count"], 100) * 0.0001
        score := width_diff + height_diff + ratio_diff - frequency_bonus

        if (score < best_score) {
            best_score := score
            best := item
        }
    }

    return best
}

ParseRatioValue(ratio_text) {
    ratio_text := StrReplace(Trim(ratio_text), ",", ".")
    if !RegExMatch(ratio_text, "^\\s*(\\d+(?:\\.\\d+)?)\\s*:\\s*(\\d+(?:\\.\\d+)?)\\s*$", &match)
        return 0

    ratio_w := match[1] + 0
    ratio_h := match[2] + 0
    if (ratio_w <= 0 || ratio_h <= 0)
        return 0

    return ratio_w / ratio_h
}

GetSmartTrimPreferredRatios() {
    global FSCUT_RATIO

    ratios := []
    profile_ratio := ParseRatioValue(FSCUT_RATIO)
    if (profile_ratio > 0)
        ratios.Push(Map("ratio", profile_ratio, "name", "profile:" FSCUT_RATIO, "profile", true))

    common_ratios := [
        Map("ratio", 2.39, "name", "2.39:1"),
        Map("ratio", 2.35, "name", "2.35:1"),
        Map("ratio", 2.00, "name", "2:1"),
        Map("ratio", 1.85, "name", "1.85:1"),
        Map("ratio", 16 / 9, "name", "16:9"),
        Map("ratio", 3 / 2, "name", "3:2"),
        Map("ratio", 4 / 3, "name", "4:3"),
        Map("ratio", 1.0, "name", "1:1"),
        Map("ratio", 4 / 5, "name", "4:5"),
        Map("ratio", 3 / 4, "name", "3:4"),
        Map("ratio", 2 / 3, "name", "2:3"),
        Map("ratio", 9 / 16, "name", "9:16")
    ]

    for item in common_ratios {
        duplicate := false
        for existing in ratios {
            if (Abs(existing["ratio"] - item["ratio"]) / item["ratio"] < 0.005) {
                duplicate := true
                break
            }
        }
        if !duplicate
            ratios.Push(Map("ratio", item["ratio"], "name", item["name"], "profile", false))
    }

    return ratios
}

ApplySmartTrimRatioAssist(&left, &top, &right, &bottom, source_width, source_height, tolerance_percent) {
    global FSCUT_X, FSCUT_Y, FSCUT_W, FSCUT_H

    current_width := right - left + 1
    current_height := bottom - top + 1
    if (current_width <= 0 || current_height <= 0)
        return false

    current_ratio := current_width / current_height
    max_ratio_diff := Max(0.02, Min(0.08, (tolerance_percent / 100) * 2))
    max_dimension_cut := 0.10
    best := 0
    best_score := 1.0e9

    for item in GetSmartTrimPreferredRatios() {
        target_ratio := item["ratio"]
        ratio_diff := Abs(current_ratio - target_ratio) / target_ratio
        if (ratio_diff > max_ratio_diff)
            continue

        ; Varianta A: zachovat šířku a zmenšit pouze výšku.
        target_height := Round(current_width / target_ratio)
        if (target_height > 0 && target_height <= current_height) {
            cut_ratio := (current_height - target_height) / current_height
            if (cut_ratio <= max_dimension_cut) {
                score := ratio_diff + cut_ratio
                if item["profile"]
                    score -= 0.10
                if (score < best_score) {
                    best_score := score
                    best := Map(
                        "axis", "height",
                        "width", current_width,
                        "height", target_height,
                        "ratio", target_ratio,
                        "name", item["name"],
                        "profile", item["profile"]
                    )
                }
            }
        }

        ; Varianta B: zachovat výšku a zmenšit pouze šířku.
        target_width := Round(current_height * target_ratio)
        if (target_width > 0 && target_width <= current_width) {
            cut_ratio := (current_width - target_width) / current_width
            if (cut_ratio <= max_dimension_cut) {
                score := ratio_diff + cut_ratio
                if item["profile"]
                    score -= 0.10
                if (score < best_score) {
                    best_score := score
                    best := Map(
                        "axis", "width",
                        "width", target_width,
                        "height", current_height,
                        "ratio", target_ratio,
                        "name", item["name"],
                        "profile", item["profile"]
                    )
                }
            }
        }
    }

    if !IsObject(best) {
        Log("SmartTrim ratio assist | NO MATCH"
            " | candidate=" current_width "x" current_height
            " | ratio=" Round(current_ratio, 4))
        return false
    }

    original_left := left
    original_top := top
    original_right := right
    original_bottom := bottom
    anchor := "center"

    anchor_tolerance_x := Max(8, Round(source_width * 0.02))
    anchor_tolerance_y := Max(8, Round(source_height * 0.02))

    if (best["axis"] = "height") {
        target_height := best["height"]
        expected_top := FSCUT_Y
        expected_bottom := FSCUT_Y + FSCUT_H - 1
        top_matches_profile := Abs(top - expected_top) <= anchor_tolerance_y
        bottom_matches_profile := Abs(bottom - expected_bottom) <= anchor_tolerance_y

        if (best["profile"] && top_matches_profile && !bottom_matches_profile) {
            bottom := top + target_height - 1
            anchor := "top/profile"
        } else if (best["profile"] && bottom_matches_profile && !top_matches_profile) {
            top := bottom - target_height + 1
            anchor := "bottom/profile"
        } else if (top > 0 && bottom >= source_height - 1) {
            bottom := top + target_height - 1
            anchor := "top/content"
        } else if (top <= 0 && bottom < source_height - 1) {
            top := bottom - target_height + 1
            anchor := "bottom/content"
        } else {
            center_y := (top + bottom) / 2
            top := Round(center_y - (target_height - 1) / 2)
            top := Max(0, Min(top, source_height - target_height))
            bottom := top + target_height - 1
        }
    } else {
        target_width := best["width"]
        expected_left := FSCUT_X
        expected_right := FSCUT_X + FSCUT_W - 1
        left_matches_profile := Abs(left - expected_left) <= anchor_tolerance_x
        right_matches_profile := Abs(right - expected_right) <= anchor_tolerance_x

        if (best["profile"] && left_matches_profile && !right_matches_profile) {
            right := left + target_width - 1
            anchor := "left/profile"
        } else if (best["profile"] && right_matches_profile && !left_matches_profile) {
            left := right - target_width + 1
            anchor := "right/profile"
        } else if (left > 0 && right >= source_width - 1) {
            right := left + target_width - 1
            anchor := "left/content"
        } else if (left <= 0 && right < source_width - 1) {
            left := right - target_width + 1
            anchor := "right/content"
        } else {
            center_x := (left + right) / 2
            left := Round(center_x - (target_width - 1) / 2)
            left := Max(0, Min(left, source_width - target_width))
            right := left + target_width - 1
        }
    }

    left := Max(0, left)
    top := Max(0, top)
    right := Min(source_width - 1, right)
    bottom := Min(source_height - 1, bottom)

    Log("SmartTrim ratio assist | MATCH"
        " | raw=" current_width "x" current_height
        " | rawRatio=" Round(current_ratio, 4)
        " | preferred=" best["name"]
        " | result=" (right - left + 1) "x" (bottom - top + 1)
        " | anchor=" anchor
        " | bounds=" original_left "," original_top "-" original_right "," original_bottom
        " -> " left "," top "-" right "," bottom)

    return (left != original_left || top != original_top
        || right != original_right || bottom != original_bottom)
}

ApplySmartTrimSize(&left, &top, &right, &bottom, source_width, source_height, known_size) {
    target_width := known_size["width"]
    target_height := known_size["height"]

    current_center_x := (left + right) / 2
    current_center_y := (top + bottom) / 2

    new_left := Round(current_center_x - (target_width - 1) / 2)
    new_top := Round(current_center_y - (target_height - 1) / 2)

    new_left := Max(0, Min(new_left, source_width - target_width))
    new_top := Max(0, Min(new_top, source_height - target_height))

    left := new_left
    top := new_top
    right := left + target_width - 1
    bottom := top + target_height - 1
}

ApplyAutoTrim(hbm, tolerance_percent, smart_trim, profile_name) {
    Log("AutoTrim | START | PROFILE=" profile_name
        " | smart=" (smart_trim ? "1" : "0")
        " | tolerance=" tolerance_percent "%")

    if (tolerance_percent <= 0) {
        Log("AutoTrim | SKIP | tolerance <= 0")
        return hbm
    }

    if !GetHBitmapSize(hbm, &width, &height) {
        Log("AutoTrim přeskočen: nelze zjistit rozměr bitmapy.")
        return hbm
    }

    Log("AutoTrim | source=" width "x" height)

    if (width < 20 || height < 20) {
        Log("AutoTrim přeskočen: bitmapa je příliš malá.")
        return hbm
    }

    if !GetHBitmapPixels32(hbm, width, height, &pixel_buffer) {
        Log("AutoTrim přeskočen: nelze načíst pixely bitmapy.")
        return hbm
    }

    corner_match_count := 0
    background_color := DetectAutoTrimBackground(pixel_buffer, width, height, tolerance_percent, &corner_match_count)
    if IsObject(background_color)
        Log("AutoTrim | background=RGB(" background_color[1] "," background_color[2] "," background_color[3] ") | cornerConfidence=" corner_match_count "/4")
    else
        Log("AutoTrim | background=UNRESOLVED | cornerConfidence=" corner_match_count "/4")

    if !IsObject(background_color) {
        Log("AutoTrim: pozadí není dostatečně jednoznačné, výřez se nemění.")
        return hbm
    }

    threshold_squared := 3 * 255 * 255 * ((tolerance_percent / 100) ** 2)

    top := FindAutoTrimBoundary(pixel_buffer, width, height, "top", background_color, threshold_squared)
    bottom := FindAutoTrimBoundary(pixel_buffer, width, height, "bottom", background_color, threshold_squared)
    left := FindAutoTrimBoundary(pixel_buffer, width, height, "left", background_color, threshold_squared)
    right := FindAutoTrimBoundary(pixel_buffer, width, height, "right", background_color, threshold_squared)

    Log("AutoTrim | raw boundaries"
        " | L=" left " | T=" top " | R=" right " | B=" bottom)

    trimmed_width := right - left + 1
    trimmed_height := bottom - top + 1

    if smart_trim {
        ApplySmartTrimRatioAssist(
            &left,
            &top,
            &right,
            &bottom,
            width,
            height,
            tolerance_percent
        )

        trimmed_width := right - left + 1
        trimmed_height := bottom - top + 1

        known_sizes_for_log := LoadSmartTrimSizes(profile_name)
        Log("SmartTrim | PROFILE=" profile_name
            " | candidate=" trimmed_width "x" trimmed_height
            " | learnedEntries=" known_sizes_for_log.Length)

        known_size := FindSmartTrimSize(
            profile_name,
            trimmed_width,
            trimmed_height,
            width,
            height,
            tolerance_percent
        )

        if IsObject(known_size) {
            raw_width := trimmed_width
            raw_height := trimmed_height

            ApplySmartTrimSize(&left, &top, &right, &bottom, width, height, known_size)
            trimmed_width := right - left + 1
            trimmed_height := bottom - top + 1

            Log("SmartTrim match | PROFILE=" profile_name
                " | raw=" raw_width "x" raw_height
                " | learned=" known_size["width"] "x" known_size["height"]
                " | count=" known_size["count"]
                " | result=" trimmed_width "x" trimmed_height)
        } else {
            Log("SmartTrim | PROFILE=" profile_name
                " | pro " trimmed_width "x" trimmed_height " nebyla nalezena blízká naučená velikost.")
        }
    }

    if smart_trim {
        ApplySmartTrimEdgeCleanup(
            pixel_buffer,
            width,
            height,
            &left,
            &top,
            &right,
            &bottom
        )

        trimmed_width := right - left + 1
        trimmed_height := bottom - top + 1
    }

    ; Bezpečnostní pojistka proti chybnému rozpoznání téměř celé bitmapy jako pozadí.
    if (trimmed_width < Max(10, Round(width * 0.10))
        || trimmed_height < Max(10, Round(height * 0.10))) {
        Log("AutoTrim odmítnut: nalezený obsah je podezřele malý.")
        return hbm
    }

    if (left = 0 && top = 0 && right = width - 1 && bottom = height - 1) {
        Log("AutoTrim: žádná mrtvá zóna nenalezena.")
        return hbm
    }

    cropped_hbm := CropHBitmap(hbm, left, top, trimmed_width, trimmed_height)
    if !cropped_hbm {
        Log("AutoTrim selhal při vytvoření oříznuté bitmapy; používám původní obraz.")
        return hbm
    }

    Log((smart_trim ? "SmartTrim" : "AutoTrim") " | SUCCESS"
        " | tolerance=" tolerance_percent "%"
        " | source=" width "x" height
        " | crop=" left "," top "-" right "," bottom
        " | result=" trimmed_width "x" trimmed_height
        " | cornerConfidence=" corner_match_count "/4")

    ; SmartTrim se učí pouze ze silných detekcí. Nejistý výsledek může
    ; předchozí znalost využít, ale nesmí jí znehodnotit databázi.
    if (smart_trim && corner_match_count >= 3)
        LearnSmartTrimSize(profile_name, trimmed_width, trimmed_height)

    DllCall("DeleteObject", "Ptr", hbm)
    return cropped_hbm
}

PutHBitmapOnClipboard(hbm) {
    if !DllCall("OpenClipboard", "ptr", 0)
        return "OpenClipboard selhalo."

    DllCall("EmptyClipboard")

    if !DllCall("SetClipboardData", "uint", 2, "ptr", hbm) {
        DllCall("CloseClipboard")
        return "SetClipboardData selhalo."
    }

    ; Po úspěšném SetClipboardData vlastní bitmapu systém.
    DllCall("CloseClipboard")
    return ""
}

SanitizeFileName(name) {
    name := Trim(name)

    ; Odstranit běžné suffixy prohlížečů.
    name := RegExReplace(name, "\s*-\s*Google Chrome\s*$", "")
    name := RegExReplace(name, "\s*-\s*Brave\s*$", "")
    name := RegExReplace(name, "\s*-\s*Microsoft Edge\s*$", "")
    name := RegExReplace(name, "\s*-\s*Mozilla Firefox\s*$", "")

    ; Windows nepovoluje tyto znaky v názvu souboru.
    name := RegExReplace(name, '[<>:"/\\|?*\x00-\x1F]', "_")
    name := RegExReplace(name, "\s+", " ")
    name := Trim(name, " .")

    if (StrLen(name) > 100)
        name := SubStr(name, 1, 100)

    return name
}

BuildSuggestedFileName(window_title, profile_name, file_format) {
    base_name := SanitizeFileName(window_title)

    if (base_name = "" && profile_name != "" && StrLower(profile_name) != "others")
        base_name := SanitizeFileName(profile_name)

    if (base_name = "")
        base_name := "printscreen"

    extension := (file_format = "JPG" || file_format = "JPEG") ? ".jpg" : ".png"
    return base_name extension
}

EnsureImageExtension(path, default_format) {
    SplitPath(path, , , &extension)

    extension := StrLower(extension)

    if (extension = "png" || extension = "jpg" || extension = "jpeg")
        return path

    if (default_format = "JPG" || default_format = "JPEG")
        return path ".jpg"

    return path ".png"
}

GetEncoderClsid(extension) {
    extension := StrLower(extension)

    if (extension = "png")
        clsid_text := "{557CF406-1A04-11D3-9A73-0000F81EF32E}"
    else if (extension = "jpg" || extension = "jpeg")
        clsid_text := "{557CF401-1A04-11D3-9A73-0000F81EF32E}"
    else
        throw Error("Nepodporovaný formát obrázku: " extension)

    clsid := Buffer(16, 0)

    hr := DllCall(
        "ole32\CLSIDFromString",
        "WStr", clsid_text,
        "Ptr", clsid.Ptr,
        "HRESULT"
    )

    if (hr < 0)
        throw Error("Nepodařilo se převést CLSID obrazového encoderu.")

    return clsid
}

SaveHBitmapToImageFile(hbm, file_path) {
    SplitPath(file_path, , , &extension)

    if (extension = "")
        throw Error("Výstupní soubor nemá příponu.")

    startup_input := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, startup_input, 0)

    gdiplus_token := 0

    status := DllCall(
        "gdiplus\GdiplusStartup",
        "Ptr*", &gdiplus_token,
        "Ptr", startup_input.Ptr,
        "Ptr", 0,
        "UInt"
    )

    if (status != 0)
        throw Error("GDI+ se nepodařilo inicializovat. Status: " status)

    try {
        bitmap_ptr := 0

        status := DllCall(
            "gdiplus\GdipCreateBitmapFromHBITMAP",
            "Ptr", hbm,
            "Ptr", 0,
            "Ptr*", &bitmap_ptr,
            "UInt"
        )

        if (status != 0 || !bitmap_ptr)
            throw Error("GDI+ nedokázalo převést screenshot na obraz. Status: " status)

        try {
            encoder_clsid := GetEncoderClsid(extension)

            status := DllCall(
                "gdiplus\GdipSaveImageToFile",
                "Ptr", bitmap_ptr,
                "WStr", file_path,
                "Ptr", encoder_clsid.Ptr,
                "Ptr", 0,
                "UInt"
            )

            if (status != 0)
                throw Error("GDI+ nedokázalo uložit obrázek. Status: " status)
        } finally {
            DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap_ptr)
        }
    } finally {
        DllCall("gdiplus\GdiplusShutdown", "Ptr", gdiplus_token)
    }
}

SaveBitmapWithDialog(hbm, window_title, profile_name) {
    global FILE_FORMAT

    suggested_name := BuildSuggestedFileName(window_title, profile_name, FILE_FORMAT)
    default_path := A_ScriptDir "\" suggested_name

    filter := "Obrázky (*.png; *.jpg; *.jpeg)"
    selected_path := FileSelect(
        "S",
        default_path,
        "Uložit screenshot",
        filter
    )

    if (selected_path = "") {
        Log("Uložení souboru zrušeno uživatelem.")
        return false
    }

    selected_path := EnsureImageExtension(selected_path, FILE_FORMAT)

    try {
        SaveHBitmapToImageFile(hbm, selected_path)
    } catch as e {
        ErrorExit("Nepodařilo se uložit screenshot.`n`n" e.Message)
    }

    Log("Screenshot uložen do souboru: " selected_path)
    return true
}


ResolvePowerPointPositionName(position_name) {
    global CONFIG_FILE

    position_name := Trim(position_name)

    if (StrLower(position_name) = "fullscreen")
        return "Fullscreen"

    ; Názvy pozic jsou case-insensitive. Vracíme skutečný název sekce z INI.
    try section_names := IniRead(CONFIG_FILE)
    catch
        return ""

    Loop Parse section_names, "`n", "`r" {
        section_name := Trim(A_LoopField)

        if RegExMatch(section_name, "i)^Position:(.+)$", &match) {
            candidate := Trim(match[1])
            if (StrLower(candidate) = StrLower(position_name))
                return candidate
        }
    }

    return ""
}

IsPictureShape(shape) {
    ; msoLinkedPicture = 11
    ; msoPicture       = 13
    try {
        return (shape.Type = 11 || shape.Type = 13)
    } catch {
        return false
    }
}

IsEmptyTextContainer(shape) {
    try {
        if !shape.HasTextFrame
            return false

        text_value := shape.TextFrame.TextRange.Text
        text_value := StrReplace(text_value, Chr(13), "")
        text_value := StrReplace(text_value, Chr(10), "")
        text_value := StrReplace(text_value, Chr(11), "")

        return (Trim(text_value) = "")
    } catch {
        return false
    }
}

StackImageBelowExistingPictures(slide, image_shape, position_config, position_name) {
    ; Pokud parametr chybí nebo je 0, skládání se nepoužije.
    position_tolerance := GetConfigNumber(position_config, "PositionTolerance", 0)

    if (position_tolerance <= 0)
        return 0

    stack_gap := GetConfigNumber(position_config, "StackGap", 0.3)

    if (stack_gap < 0)
        stack_gap := 0

    tolerance_pt := ToPowerPointPoints(position_tolerance)
    gap_pt := ToPowerPointPoints(stack_gap)

    image_name := image_shape.Name
    base_left := image_shape.Left
    base_top := image_shape.Top

    lowest_bottom := 0
    found_count := 0

    ; Hledáme obrázky ve stejném sloupci, od cílové pozice směrem dolů.
    ; Pokud jich je více, nový obrázek skončí až pod nejnižším z nich.
    Loop slide.Shapes.Count {
        candidate := slide.Shapes(A_Index)

        try {
            if (candidate.Name = image_name)
                continue
        }

        if !IsPictureShape(candidate)
            continue

        try {
            delta_left := Abs(candidate.Left - base_left)

            if (delta_left > tolerance_pt)
                continue

            ; Obrázek musí začínat alespoň přibližně v cílové pozici
            ; nebo níže. Tím nevstupují do hry obrázky nad tímto layoutem.
            if (candidate.Top < base_top - tolerance_pt)
                continue

            candidate_bottom := candidate.Top + candidate.Height

            if (found_count = 0 || candidate_bottom > lowest_bottom)
                lowest_bottom := candidate_bottom

            found_count += 1
        }
    }

    if (found_count > 0) {
        old_top := image_shape.Top
        image_shape.Top := lowest_bottom + gap_pt

        Log("PowerPoint stack | Position=" position_name
            " | FoundPictures=" found_count
            " | OldTopPt=" Round(old_top, 2)
            " | NewTopPt=" Round(image_shape.Top, 2)
            " | StackGap=" stack_gap
            " | PositionTolerance=" position_tolerance)

        return found_count
    }

    Log("PowerPoint stack | Position=" position_name
        " | žádný obrázek ve stejné pozici nenalezen"
        " | PositionTolerance=" position_tolerance)

    return 0
}

RemoveEmptyPlaceholdersAtImagePosition(slide, image_shape, position_config, position_name) {
    ; PositionTolerance je společná tolerance pro práci s objekty v cílové pozici.
    ; Pokud parametr chybí nebo je 0, funkce je vypnutá.
    position_tolerance := GetConfigNumber(position_config, "PositionTolerance", 0)

    if (position_tolerance <= 0)
        return 0

    tolerance_pt := ToPowerPointPoints(position_tolerance)
    image_left := image_shape.Left
    image_top := image_shape.Top
    image_name := image_shape.Name
    removed := 0

    ; Procházíme odzadu, protože při mazání se kolekce Shapes přečísluje.
    index := slide.Shapes.Count

    while (index >= 1) {
        candidate := slide.Shapes(index)

        try {
            if (candidate.Name = image_name) {
                index -= 1
                continue
            }
        }

        if IsEmptyTextContainer(candidate) {
            try {
                delta_left := Abs(candidate.Left - image_left)
                delta_top := Abs(candidate.Top - image_top)

                if (delta_left <= tolerance_pt && delta_top <= tolerance_pt) {
                    Log("PowerPoint | mažu prázdný textový kontejner"
                        " | Position=" position_name
                        " | Shape=" candidate.Name
                        " | DeltaLeftPt=" Round(delta_left, 2)
                        " | DeltaTopPt=" Round(delta_top, 2)
                        " | PositionTolerance=" position_tolerance)

                    candidate.Delete()
                    removed += 1
                }
            }
        }

        index -= 1
    }

    if (removed = 0)
        Log("PowerPoint | prázdný textový kontejner v cílové pozici nenalezen"
            " | Position=" position_name
            " | PositionTolerance=" position_tolerance)

    return removed
}

ToPowerPointPoints(value) {
    ; Hodnoty pozičních parametrů jsou v centimetrech.
    return value * 28.3464567
}

ApplyPowerPointPosition(shape, slide, pres, position_name) {
    position_lower := StrLower(Trim(position_name))

    if (position_lower = "" || position_lower = "fullscreen") {
        ApplyPowerPointFullscreenPosition(shape, pres)
        return
    }

    resolved_position := ResolvePowerPointPositionName(position_name)

    if (resolved_position = "")
        ErrorExit("Chybí sekce [Position:" position_name "] v INI.")

    position_config := LoadIniSection("Position:" resolved_position)
    ApplyPowerPointCustomPosition(shape, resolved_position, position_config)

    ; Pokud už ve stejné pozici existují obrázky, nový se vloží
    ; až pod nejnižší z nich.
    StackImageBelowExistingPictures(slide, shape, position_config, resolved_position)

    ; Prázdný textový kontejner se hledá až ve výsledné pozici obrázku.
    RemoveEmptyPlaceholdersAtImagePosition(slide, shape, position_config, resolved_position)
}

ApplyPowerPointFullscreenPosition(shape, pres) {
    slide_w := pres.PageSetup.SlideWidth
    slide_h := pres.PageSetup.SlideHeight

    orig_w := shape.Width
    orig_h := shape.Height

    if (orig_w <= 0 || orig_h <= 0)
        ErrorExit("Vložený obrázek má neplatné rozměry.")

    scale := Min(slide_w / orig_w, slide_h / orig_h)

    shape.LockAspectRatio := -1
    shape.Width := orig_w * scale
    shape.Left := (slide_w - shape.Width) / 2
    shape.Top := (slide_h - shape.Height) / 2

    Log("PowerPoint position | Mode=Fullscreen"
        " | OrigW=" Round(orig_w, 2)
        " | OrigH=" Round(orig_h, 2)
        " | Scale=" Round(scale, 4)
        " | FinalW=" Round(shape.Width, 2)
        " | FinalH=" Round(shape.Height, 2))
}

ApplyPowerPointCustomPosition(shape, position_name, position_config) {
    left := GetConfigNumber(position_config, "Left", 0)
    top := GetConfigNumber(position_config, "Top", 0)
    max_width := GetConfigNumber(position_config, "MaxWidth", 0)
    max_height := GetConfigNumber(position_config, "MaxHeight", 0)

    if (max_width <= 0 || max_height <= 0)
        ErrorExit("Sekce [Position:" position_name "] musí mít kladné MaxWidth a MaxHeight.")

    target_left := ToPowerPointPoints(left)
    target_top := ToPowerPointPoints(top)
    max_w := ToPowerPointPoints(max_width)
    max_h := ToPowerPointPoints(max_height)

    orig_w := shape.Width
    orig_h := shape.Height

    if (orig_w <= 0 || orig_h <= 0)
        ErrorExit("Vložený obrázek má neplatné rozměry.")

    scale := Min(max_w / orig_w, max_h / orig_h)

    shape.LockAspectRatio := -1
    shape.Width := orig_w * scale

    final_w := shape.Width

    if (final_w < max_w)
        shape.Left := target_left + ((max_w - final_w) / 2)
    else
        shape.Left := target_left

    shape.Top := target_top

    Log("PowerPoint position | Mode=" position_name
        " | Left=" left
        " | Top=" top
        " | MaxWidth=" max_width
        " | MaxHeight=" max_height
        " | FinalW=" Round(shape.Width, 2)
        " | FinalH=" Round(shape.Height, 2))
}


GetPowerPointSlideIds(pres) {
    slide_ids := Map()

    Loop pres.Slides.Count {
        slide := pres.Slides(A_Index)
        slide_ids[slide.SlideID] := true
    }

    return slide_ids
}

FindNewPowerPointSlide(pres, existing_ids) {
    new_slide := ""
    new_slide_count := 0

    Loop pres.Slides.Count {
        slide := pres.Slides(A_Index)

        if !existing_ids.Has(slide.SlideID) {
            new_slide := slide
            new_slide_count += 1
        }
    }

    if (new_slide_count = 1 && IsObject(new_slide))
        return new_slide

    Log("PowerPoint | nový slide nelze jednoznačně identifikovat"
        " | NewSlideCount=" new_slide_count)

    return ""
}

IsPowerPointGapSelected(win) {
    try {
        selection_type := win.Selection.Type
        pane_view_type := win.ActivePane.ViewType
    } catch as e {
        Log("PowerPoint | nelze zjistit stav výběru mezery"
            " | Detail=" e.Message)
        return false
    }

    ; Prakticky ověřený stav PowerPointu při vybrané červené mezeře:
    ; Selection.Type = 0 a ActivePane.ViewType = 11.
    is_gap := (selection_type = 0 && pane_view_type = 11)

    Log("PowerPoint | kontrola mezery"
        " | Selection.Type=" selection_type
        " | ActivePane.ViewType=" pane_view_type
        " | IsGap=" (is_gap ? "1" : "0"))

    return is_gap
}

CreatePowerPointSlideAtGap(ppt, win, pres) {
    if !IsPowerPointGapSelected(win)
        ErrorExit("Není vybrán žádný slide ani platná mezera mezi slidy.")

    existing_ids := GetPowerPointSlideIds(pres)
    slide_count_before := pres.Slides.Count

    try {
        ; Office control ID prakticky ověřené samostatným testem.
        ; PowerPoint vloží nový slide přesně na aktivní červenou insertion line.
        ppt.CommandBars.ExecuteMso("SlideNew")
    } catch as e {
        ErrorExit("Nepodařilo se vytvořit slide ve vybrané mezeře mezi slidy.`n`nDetail: " e.Message)
    }

    Sleep(250)

    slide_count_after := pres.Slides.Count

    if (slide_count_after != slide_count_before + 1) {
        ErrorExit(
            "PowerPoint nevytvořil právě jeden nový slide.`n`n"
            "Před: " slide_count_before "`n"
            "Po: " slide_count_after
        )
    }

    new_slide := FindNewPowerPointSlide(pres, existing_ids)

    if !IsObject(new_slide)
        ErrorExit("Nový slide vznikl, ale nepodařilo se jej jednoznačně identifikovat.")

    try {
        new_slide.Layout := 12
    }

    try {
        win.View.GotoSlide(new_slide.SlideIndex)
    }

    Log("PowerPoint | vytvořen nový slide ve vybrané mezeře"
        " | SlideIndex=" new_slide.SlideIndex
        " | SlideID=" new_slide.SlideID)

    return new_slide
}

InsertClipboardImageToPowerPoint() {
    global POWERPOINT_WAIT, POWERPOINT_AUTO_SLIDE, POWERPOINT_POSITION

    try {
        ppt := ComObjActive("PowerPoint.Application")
    } catch {
        ErrorExit("PowerPoint není otevřený.")
    }

    try {
        win := ppt.ActiveWindow
        pres := ppt.ActivePresentation
    } catch {
        ErrorExit("Nepodařilo se získat aktivní okno nebo prezentaci PowerPointu.")
    }

    slide_created_from_gap := false

    try {
        slide := win.View.Slide
    } catch {
        ; Pokud není dostupný aktivní slide, může být vybraná červená mezera
        ; mezi slidy. Tento stav je před vytvořením slidu explicitně ověřen.
        slide := CreatePowerPointSlideAtGap(ppt, win, pres)
        slide_created_from_gap := true
    }

    started_on_blank_slide := false

    if POWERPOINT_AUTO_SLIDE {
        try {
            if slide_created_from_gap {
                ; Slide vytvořený z červené mezery je už cílový nový slide.
                ; Po vložení obrázku se proto NESMÍ automaticky zakládat další
                ; prázdný slide za ním.
                started_on_blank_slide := false
            } else if (slide.Shapes.Count = 0) {
                ; Původní chování: pokud uživatel stál na existujícím čistém
                ; slidu, po vložení se zajistí další čistý slide.
                started_on_blank_slide := true
            } else {
                current_index := slide.SlideIndex
                slide := pres.Slides.Add(current_index + 1, 12)
                win.View.GotoSlide(slide.SlideIndex)
            }
        } catch as e {
            ErrorExit("Nepodařilo se připravit slide.`n`nDetail: " e.Message)
        }
    } else {
        Log("PowerPoint AutoSlide vypnuto | vkládám do aktuálního slidu " slide.SlideIndex)
    }

    try {
        ppt.Activate()
        Sleep(POWERPOINT_WAIT)

        shape_range := slide.Shapes.PasteSpecial(1)
        shape := shape_range.Item(1)

        ; Screenshot má být vždy nejvyšší vrstva.
        shape.ZOrder(0)

        ApplyPowerPointPosition(shape, slide, pres, POWERPOINT_POSITION)

    } catch as e {
        ErrorExit("Nepodařilo se vložit obrázek do PowerPointu.`n`nDetail: " e.Message)
    }

    return started_on_blank_slide
}

EnsureBlankSlideAfterActive() {
    try {
        ppt := ComObjActive("PowerPoint.Application")
        win := ppt.ActiveWindow
        current_slide := win.View.Slide
        pres := ppt.ActivePresentation

        current_index := current_slide.SlideIndex

        if (current_index < pres.Slides.Count) {
            next_slide := pres.Slides.Item(current_index + 1)

            if (next_slide.Shapes.Count = 0) {
                win.View.GotoSlide(next_slide.SlideIndex)
                return
            }
        }

        new_slide := pres.Slides.Add(current_index + 1, 12)
        win.View.GotoSlide(new_slide.SlideIndex)
    } catch as e {
        ErrorExit("Screenshot byl vložen, ale nepodařilo se zajistit další prázdný slide.`n`nDetail: " e.Message)
    }
}

ActivateTarget(target) {
    global ACTIVATION_WAIT, ACTIVATION_TIMEOUT

    WinActivate("ahk_id " target)

    timeout_seconds := Max(ACTIVATION_TIMEOUT / 1000, 0.1)
    if !WinWaitActive("ahk_id " target, , timeout_seconds)
        ErrorExit("Nepodařilo se aktivovat prohlížeč.")

    Sleep(ACTIVATION_WAIT)
}

ToggleFullscreen(target) {
    global FULLSCREEN_KEY, FULLSCREEN_WAIT

    ActivateTarget(target)
    Send(FULLSCREEN_KEY)
    Sleep(FULLSCREEN_WAIT)
}

HideControls(target) {
    global HIDE_MOUSE_OFFSET_X, HIDE_MOUSE_OFFSET_Y, HIDE_CONTROLS_WAIT

    WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " target)

    x := wx + HIDE_MOUSE_OFFSET_X
    y := wy + HIDE_MOUSE_OFFSET_Y

    Log("Schování ovládání podle okna | X=" x " | Y=" y)

    MouseMove(x, y, 0)
    Sleep(HIDE_CONTROLS_WAIT)
}

; ===== Hlavní běh skriptu =====

target_title := WinGetTitle("ahk_id " target)

if (forced_monitor > 0)
    monitor_num := forced_monitor
else
    monitor_num := GetMonitorFromWindow(target)

GetMonitorBounds(monitor_num, &ml, &mt, &mr, &mb)

Log("Vybrané okno: " target_title)
Log("Vybraný monitor: " monitor_num)
Log("Pipeline runtime | Preset=" requested_pipeline_preset " | Definition=" selected_pipeline)

ActivateTarget(target)

if AUTO_FULLSCREEN {
    Log("Fullscreen akce | ACTION=ON"
        " | PROFILE=" selected_profile
        " | AutoFullscreen=1"
        " | Key=" FULLSCREEN_KEY
        " | Source=" fullscreen_source)
    ToggleFullscreen(target)
} else {
    Log("Fullscreen akce | ACTION=SKIP"
        " | PROFILE=" selected_profile
        " | AutoFullscreen=0"
        " | Key=" FULLSCREEN_KEY
        " | Source=" fullscreen_source)
}

HideControls(target)

mw := mr - ml
mh := mb - mt

Log("Pořizuji fullscreen screenshot monitoru | W=" mw " | H=" mh)

full_hbm := CaptureMonitorBitmap(ml, mt, mw, mh, &capture_error)

if !full_hbm
    ErrorExit("Nepodařilo se udělat screenshot.`n`n" capture_error)

hbm := ExecuteCapturePipeline(full_hbm, selected_pipeline, selected_profile, &capture_method)
if !hbm
    ErrorExit("Nepodařilo se zpracovat screenshot podle pipeline " selected_pipeline ".")

Log("Capture result | Method=" capture_method)

if AUTO_FULLSCREEN {
    Log("Fullscreen akce | ACTION=OFF"
        " | PROFILE=" selected_profile
        " | AutoFullscreen=1"
        " | Key=" FULLSCREEN_KEY
        " | Source=" fullscreen_source)
    ToggleFullscreen(target)
}

output_mode_lower := StrLower(OUTPUT_MODE)

if (output_mode_lower = "powerpoint") {
    clipboard_error := PutHBitmapOnClipboard(hbm)

    if (clipboard_error != "") {
        DllCall("DeleteObject", "ptr", hbm)
        ErrorExit("Nepodařilo se uložit screenshot do schránky.`n`n" clipboard_error)
    }

    ; Po úspěšném vložení do clipboardu již bitmapu vlastní systém.
    hbm := 0

    Log("Screenshot uložen do schránky.")
    Sleep(CLIPBOARD_WAIT)

    Log("Vkládám do PowerPointu.")

    insert_started_on_blank_slide := InsertClipboardImageToPowerPoint()

    if insert_started_on_blank_slide
        EnsureBlankSlideAfterActive()

} else if (output_mode_lower = "file") {
    try {
        SaveBitmapWithDialog(hbm, target_title, selected_profile)
    } finally {
        if hbm
            DllCall("DeleteObject", "ptr", hbm)
    }
}

Log("Hotovo.")
ExitApp
