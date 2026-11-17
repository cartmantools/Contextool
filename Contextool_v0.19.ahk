#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent()

; =====================================================================
;  CONTEXTOOL  -  V0.19
;  - Open the menu with your shortcut (default: Ctrl+Shift+F9)
;  - Menu content (top to bottom):
;      Pins         (anything you pin: files, apps, folders - at the top
;                    or at the bottom, your choice in Settings > Pins)
;      Symbols      (one entry, symbols open on the side)
;      Tools        (color picker, sticky note, text from screen, QR / barcode,
;                    screenshot to clipboard, Google image search,
;                    font from screen) - choose / reorder them in Settings > Tools
;      Launch Box   (apps, files and websites, opens on the side)
;      Quick Access (folders, opens on the side)
;  - Snippets with formatted text (Settings > Snippets): type a trigger like ;hello then
;    Space / Tab / Enter. {{variable}} values are asked first.
;  - Everything is managed from the tray icon (green "H") -> Settings:
;      Symbols / Pins / Quick Access / Launch Box / Tools / Snippets / APIs / General
;    (double-click on the tray icon also opens Settings)
;  - Your settings and sticky notes are saved in
;    Documents\AHK SETTINGS\Contextool  (they survive script updates)
;  - Nothing else is created next to this script (icons and the barcode reader
;    are in the "data" folder inside the same Documents folder)
; =====================================================================

;@Ahk2Exe-SetName Contextool
;@Ahk2Exe-SetDescription Contextool
;@Ahk2Exe-SetVersion 0.19.0.0
;@Ahk2Exe-SetCompanyName Ahcene

; Default shortcut (you can change it any time in Settings > General)
OpenHotkeys := ["^RButton"]      ; shortcuts that open the menu (default: Ctrl + right click); several can be active

; How symbols are inserted:
;   "Type"  = types the symbol (fast, works almost everywhere)
;   "Paste" = uses the clipboard (try this if "Type" fails in some app)
InsertMode := "Type"

; Language used to read text from the screen (tool "Text from screen").
; "" = automatic (your Windows languages). Or a language code like "fr-FR", "en-US"
OcrLanguage := ""


; ------------------------- do not edit below -------------------------

ApiKeys := Map("whatfontis", "", "groq", "")     ; your API keys (set in Settings > APIs)
AppVersion := "V0.19"
; Your settings and notes are kept in Documents, so they survive script updates
SettingsDir := A_MyDocuments "\AHK SETTINGS\Contextool"
ConfigFile := SettingsDir "\Contextool.settings.txt"
NotesFile := SettingsDir "\notes.txt"
DataDir := SettingsDir "\data"                  ; icons and the barcode reader (can be recreated)
IconDir := DataDir "\icons_v5"
IconStyle := "color"     ; menu icons: "color" (original colors), "white" or "black"
noSaveNotes := false     ; true while restarting after a restore
ZxingDir := DataDir "\zxing"

Items := Map("S", [], "A", [], "F", [], "P", [])   ; S = symbols, A = Launch Box (apps/files), F = Quick Access (folders), P = pins
ThemedGuis := Map()      ; windows that follow the Windows dark / light theme
TextColors := Map()      ; special text colors (tab labels)
Exempt := Map()          ; controls that keep their own colors
BrushCache := Map()
ApiEdits := []
LvFrames := Map()        ; list -> its rounded frame
paused := false         ; true while Contextool is paused (shortcut and snippets off)
PinPos := "top"          ; pins shown "top" (before Symbols) or "bottom" (after Quick Access)
Snippets := []           ; snippets: {trigger, text (plain), rtf (formatted text, "" = plain only)}
SnipBuf := ""            ; what you are typing (to detect a snippet trigger)
prevWin := 0
currentMenu := ""
settingsGui := ""
menuOpen := false
reopen := false
HK_BASE := 0x4B31        ; first id of the shortcuts registered with Windows
HkCounter := 0
ActiveHk := Map()        ; shortcut -> {kind: "reg" (Windows hotkey) or "ahk" (AutoHotkey hook), id}
trigKind := ""           ; how the menu was asked: "reg", "ahk"

toolBusy := false        ; true while a tool (picker, OCR...) is working
pickCancel := false      ; set by Esc / right click while picking
pickClick := false       ; set by a left click while picking
pickRight := false       ; set by a right click while picking
gdipToken := 0
selHwnds := Map()        ; windows that show the crosshair cursor while selecting
Notes := []              ; the sticky notes that are on screen
IconData := Map()        ; menu icons (PNG, base64)
toolsRefreshing := false
ToolPrefs := []          ; order and on/off of the tools (saved in the settings file)
ToolOrderDefault := ["picker", "note", "ocr", "qr", "shot", "lens", "fontid", "stt", "rec"]
ToolDefs := Map()        ; every tool that exists
ToolDefs["picker"] := {title: "Color picker", icon: "picker", fn: ColorPicker, desc: "Pick a color on the screen, its hex code is copied"}
ToolDefs["note"] := {title: "Sticky note", icon: "note", fn: NewNote, desc: "Always-on-top notes you can move and resize"}
ToolDefs["ocr"] := {title: "Text from screen (OCR)", icon: "ocr", fn: OcrTool, desc: "Read the text of a screen area"}
ToolDefs["qr"] := {title: "QR code / barcode reader", icon: "qr", fn: QrTool, desc: "Read a QR code or barcode of a screen area"}
ToolDefs["shot"] := {title: "Screenshot to clipboard", icon: "shot", fn: ScreenshotTool, desc: "Copy a screen area to the clipboard, no file saved"}
ToolDefs["lens"] := {title: "Search image on Google", icon: "lens", fn: LensTool, desc: "Select a screen area and search it with Google Lens"}
ToolDefs["stt"] := {title: "Speech to text (Groq)", icon: "stt", fn: SttTool, desc: "Dictate: speak, press Stop, the text is typed at your cursor (API key: Settings > APIs)"}
ToolDefs["rec"] := {title: "Screen recording", icon: "rec", fn: RecTool, desc: "Record a screen area with the Windows recorder (Win+Shift+R)"}
ToolDefs["fontid"] := {title: "Font from screen (WhatFontIs)", icon: "fontid", fn: FontIdTool, desc: "Select a screen area to identify its font (API key: Settings > APIs)"}


; ============================ where the settings live ============================

; Version written in a settings file ("" if none)
PeekVersion(file) {
    try {
        for line in StrSplit(FileRead(file, "UTF-8"), "`n", "`r") {
            parts := StrSplit(line, "`t")
            if (parts.Length >= 2 && parts[1] = "V")
                return parts[2]
        }
    }
    return ""
}

; The old start-with-Windows shortcut had another name: replace it by the new one
MigrateStartupLink() {
    old := A_Startup "\MyContextMenu.lnk"
    if FileExist(old) {
        try FileDelete(old)
        try FileCreateShortcut(A_ScriptFullPath, A_Startup "\Contextool.lnk", A_ScriptDir)
    }
}

; Runs first at start-up: finds / imports the saved settings
SettingsStartup() {
    if (!DirExist(SettingsDir)) {
        ; renamed program: take over everything from the old "ContextMenu" settings folder
        oldDir := A_MyDocuments "\AHK SETTINGS\ContextMenu"
        if DirExist(oldDir) {
            try DirCopy(oldDir, SettingsDir, 0)
            oldCfg := SettingsDir "\ContextMenu.settings.txt"
            if (FileExist(oldCfg) && !FileExist(ConfigFile))
                try FileMove(oldCfg, ConfigFile)
            try DirCreate(SettingsDir)
            return
        }
        ; very first time with this system: take over the old files that sit next to the script
        try DirCreate(SettingsDir)
        legacy := A_ScriptDir "\ContextMenu.settings.txt"
        if FileExist(legacy)
            try FileCopy(legacy, ConfigFile, 0)
        legacyNotes := A_ScriptDir "\ContextMenu_data\notes.txt"
        if FileExist(legacyNotes)
            try FileCopy(legacyNotes, NotesFile, 0)
        return
    }
    if (!FileExist(ConfigFile))
        return
    saved := PeekVersion(ConfigFile)
    if (saved = AppVersion)
        return                               ; same version: load silently
    msg := "The script is now " AppVersion (saved != "" ? " (your settings were saved by " saved ")" : "") ".`n`n"
        . "Restore your previous settings?`n`n"
        . "Yes = restore them (recommended)`n"
        . "No = start with new settings (the old ones are backed up first)"
    if (MsgBox(msg, "Contextool", "YesNo Icon? T60") = "No") {
        BackupSettings("before-fresh-start")
        try FileDelete(ConfigFile)
    }
}

; Copies the settings and the notes into Backups\<date>. Returns the folder ("" on failure)
BackupSettings(tag := "") {
    dir := SettingsDir "\Backups\" FormatTime(, "yyyy-MM-dd_HHmmss") (tag != "" ? "_" tag : "")
    try {
        DirCreate(dir)
        if FileExist(ConfigFile)
            FileCopy(ConfigFile, dir "\Contextool.settings.txt", 1)
        if FileExist(NotesFile)
            FileCopy(NotesFile, dir "\notes.txt", 1)
        return dir
    } catch {
        return ""
    }
}


; ============================ saved lists ============================

; Path of a Windows folder (Downloads, Pictures...), even if the user moved it
KnownFolder(guid, fallback) {
    try {
        id := Buffer(16)
        DllCall("ole32\CLSIDFromString", "wstr", guid, "ptr", id)
        p := 0
        if (DllCall("shell32\SHGetKnownFolderPath", "ptr", id, "uint", 0, "ptr", 0, "ptr*", &p) = 0) {
            r := StrGet(p, "UTF-16")
            DllCall("ole32\CoTaskMemFree", "ptr", p)
            return r
        }
    }
    return fallback
}

LoadConfig() {
    global OpenHotkeys, PinPos, IconStyle
    hSeen := false
    if !FileExist(ConfigFile) {
        ; first launch (new user): start with a few default items
        for sym in StrSplit("É È À Ç € © ° → ✓ •", " ")
            Items["S"].Push({val: sym, label: ""})
        Items["P"].Push({val: KnownFolder("{374DE290-123F-4565-9164-67BD64C9EAC4}", EnvGet("USERPROFILE") "\Downloads"), label: "Downloads"})
        Items["P"].Push({val: "https://www.youtube.com", label: "YouTube"})
        Items["A"].Push({val: A_WinDir "\System32\notepad.exe", label: "Notepad"})
        Items["A"].Push({val: A_WinDir "\System32\calc.exe", label: "Calculator"})
        Items["A"].Push({val: "https://www.youtube.com", label: "YouTube"})
        Items["F"].Push({val: KnownFolder("{33E28130-4E1E-4676-835A-98395C3BC3BB}", EnvGet("USERPROFILE") "\Pictures"), label: "Pictures"})
        Snippets.Push({trigger: ";hello", text: "Hello my friend {{name}} what's app !", rtf: ""})
        SaveConfig()
        return
    }
    try {
        text := FileRead(ConfigFile, "UTF-8")
        for line in StrSplit(text, "`n", "`r") {
            if (line = "")
                continue
            parts := StrSplit(line, "`t")
            if (parts.Length < 2)
                continue
            if (parts[1] = "H") {
                if (parts[2] != "") {
                    if (!hSeen) {
                        OpenHotkeys := []
                        hSeen := true
                    }
                    OpenHotkeys.Push(parts[2])
                }
                continue
            }
            if (parts[1] = "I") {
                if (parts[2] = "color" || parts[2] = "white" || parts[2] = "black")
                    IconStyle := parts[2]
                continue
            }
            if (parts[1] = "L") {
                PinPos := (parts[2] = "bottom") ? "bottom" : "top"
                continue
            }
            if (parts[1] = "N") {
                if (parts.Length >= 3 && parts[2] != "")
                    Snippets.Push({trigger: parts[2], text: UnescNote(parts[3]), rtf: (parts.Length >= 4) ? UnescNote(parts[4]) : ""})
                continue
            }
            if (parts[1] = "K") {
                if (parts.Length >= 3 && ApiKeys.Has(parts[2]))
                    ApiKeys[parts[2]] := UnprotectText(parts[3])
                else if (parts.Length = 2)
                    ApiKeys["whatfontis"] := UnprotectText(parts[2])     ; key saved by an older version
                continue
            }
            if (parts[1] = "T") {
                ToolPrefs.Push({id: parts[2], on: !(parts.Length >= 3 && parts[3] = "0"), name: (parts.Length >= 4 ? parts[4] : "")})
                continue
            }
            if (!Items.Has(parts[1]))
                continue   ; also skips old lines from previous versions
            lbl := (parts.Length >= 3) ? parts[3] : ""
            Items[parts[1]].Push({val: parts[2], label: lbl})
        }
    }
}

SaveConfig() {
    text := "V`t" AppVersion "`n"
    for hk in OpenHotkeys
        text .= "H`t" hk "`n"
    for id, val in ApiKeys {
        if (Trim(val) != "")
            text .= "K`t" id "`t" ProtectText(Trim(val)) "`n"
    }
    text .= "L`t" PinPos "`n"
    text .= "I`t" IconStyle "`n"
    for sn in Snippets
        text .= "N`t" sn.trigger "`t" EscNote(sn.text) "`t" EscNote(sn.rtf) "`n"
    for kind in ["S", "A", "F", "P"] {
        for it in Items[kind] {
            text .= kind "`t" it.val "`t" it.label "`n"
        }
    }
    for tp in ToolPrefs
        text .= "T`t" tp.id "`t" (tp.on ? 1 : 0) "`t" tp.name "`n"
    try {
        DirCreate(SettingsDir)
        f := FileOpen(ConfigFile, "w", "UTF-8-RAW")
        f.Write(text)
        f.Close()
    } catch as e {
        MsgBox("Could not save your settings:`n" ConfigFile "`n`n" e.Message, "Contextool", "Iconx")
    }
}


; Name shown for a tool: your own name if you renamed it, else the default one
ToolTitle(tp) => (tp.name != "") ? tp.name : ToolDefs[tp.id].title

; Asks for a new name. Returns "" if cancelled, otherwise {name: "..."} (empty name = back to default)
AskName(prompt, current) {
    r := InputBox(prompt, "Contextool - Rename", "w420 h160", current)
    if (r.Result != "OK")
        return ""
    return {name: Trim(RegExReplace(r.Value, "[\t\r\n]+", " "))}
}

; Keeps only known tools, adds new ones at the end (switched on)
FixToolPrefs() {
    global ToolPrefs
    fixed := []
    seen := Map()
    for tp in ToolPrefs {
        if (ToolDefs.Has(tp.id) && !seen.Has(tp.id)) {
            fixed.Push(tp)
            seen[tp.id] := 1
        }
    }
    for id in ToolOrderDefault {
        if (!seen.Has(id))
            fixed.Push({id: id, on: true, name: ""})
    }
    ToolPrefs := fixed
}


; ============================== helpers ==============================

Esc(s) => StrReplace(s, "&", "&&")

; The "$" makes the shortcut work even while the menu is open
HotName(hk) => (InStr(hk, "$") ? hk : "$" hk)

NameOf(path, noExt := true) {
    p := RTrim(path, "\")
    SplitPath(p, &file, , , &base)
    n := noExt ? base : file
    return (n = "") ? path : n
}

; Makes native menus follow the Windows theme (dark / light)
ApplyMenuTheme() {
    try {
        uxtheme := DllCall("GetModuleHandle", "str", "uxtheme", "ptr")
        SetPreferredAppMode := DllCall("GetProcAddress", "ptr", uxtheme, "ptr", 135, "ptr")
        FlushMenuThemes := DllCall("GetProcAddress", "ptr", uxtheme, "ptr", 136, "ptr")
        DllCall(SetPreferredAppMode, "int", 1)   ; 1 = follow system theme
        DllCall(FlushMenuThemes)
    }
}

; Splits "^+F9" into modifiers ("^+") and key ("F9")
SplitHotkey(hk, &mods, &k) {
    mods := ""
    k := hk
    while (StrLen(k) > 1 && InStr("^+!#$~*<>", SubStr(k, 1, 1))) {
        mods .= SubStr(k, 1, 1)
        k := SubStr(k, 2)
    }
}

; "^+F9" -> "Ctrl+Shift+F9"
HotkeyText(hk) {
    SplitHotkey(hk, &mods, &k)
    out := ""
    Loop Parse, mods {
        if (A_LoopField = "^")
            out .= "Ctrl+"
        else if (A_LoopField = "+")
            out .= "Shift+"
        else if (A_LoopField = "!")
            out .= "Alt+"
        else if (A_LoopField = "#")
            out .= "Win+"
    }
    if (k = "RButton")
        k := "Right click"
    else if (k = "MButton")
        k := "Middle click"
    return out k
}

; Refuses shortcuts that would block normal typing or clicking
IsSafeHotkey(hk) {
    if RegExMatch(hk, "i)LButton")
        return false
    SplitHotkey(hk, &mods, &k)
    if (k = "RButton")
        return RegExMatch(mods, "[\^!#]")          ; right click only together with Ctrl / Alt / Win
    if RegExMatch(mods, "[\^!#]")
        return true
    return RegExMatch(k, "i)^(F\d{1,2}|XButton[12]|MButton|Browser_\w+|Media_\w+|Launch_\w+|Volume_\w+)$")
}

; Writes a base64 text into a file (used for the menu icons)
Base64ToFile(b64, file) {
    n := 0
    if (!DllCall("crypt32\CryptStringToBinaryW", "str", b64, "uint", 0, "uint", 1, "ptr", 0, "uint*", &n, "ptr", 0, "ptr", 0))
        throw Error("Bad base64 data")
    buf := Buffer(n)
    DllCall("crypt32\CryptStringToBinaryW", "str", b64, "uint", 0, "uint", 1, "ptr", buf, "uint*", &n, "ptr", 0, "ptr", 0)
    f := FileOpen(file, "w")
    f.RawWrite(buf, n)
    f.Close()
}

; The program icon (tray icon and settings window) comes from the data below
SetAppIcon() {
    pa := DataDir "\tray_active_v1.ico"
    pp := DataDir "\tray_paused_v1.ico"
    if (!FileExist(pa))
        try Base64ToFile(IcoB64, pa)
    if (!FileExist(pp))
        try Base64ToFile(IcoPausedB64, pp)
    SetTrayState()
}

; Green icon while Contextool works, red icon while it is paused
SetTrayState() {
    path := DataDir (paused ? "\tray_paused_v1.ico" : "\tray_active_v1.ico")
    if FileExist(path)
        try TraySetIcon(path)
    A_IconTip := paused ? "Contextool (paused)" : "Contextool"
}

TogglePause(*) {
    global paused
    if (paused) {
        for hk in OpenHotkeys {
            if (!ActivateHotkey(hk, 5)) {
                MsgBox("The shortcut (" HotkeyText(hk) ") could not be turned on again.", "Contextool", "Iconx")
                return
            }
        }
        paused := false
        A_TrayMenu.Rename("Resume Contextool", "Pause Contextool")
    } else {
        DeactivateAllHotkeys()
        paused := true
        A_TrayMenu.Rename("Pause Contextool", "Resume Contextool")
    }
    SetTrayState()
}

; Gives a window the program icon (title bar and taskbar)
SetWinIcon(g) {
    path := DataDir "\tray_active_v1.ico"
    if (!FileExist(path))
        return
    for pair in [[0, 16], [1, 32]] {
        px := Round(pair[2] * A_ScreenDPI / 96)
        h := DllCall("LoadImage", "ptr", 0, "str", path, "uint", 1, "int", px, "int", px, "uint", 0x10, "ptr")
        if (h)
            DllCall("SendMessage", "ptr", g.Hwnd, "uint", 0x80, "ptr", pair[1], "ptr", h)   ; WM_SETICON
    }
}

; Returns the path of the icon file that best fits the wanted size ("" if impossible)
IconFile(name, size) {
    px := 32
    for p in [16, 20, 24, 32] {
        if (p >= size) {
            px := p
            break
        }
    }
    key := name "_" IconStyle
    if (!IconData.Has(key))
        key := name "_color"
    if (!IconData.Has(key))
        return ""
    path := IconDir "\" key "_" px ".png"
    if (!FileExist(path)) {
        try {
            DirCreate(IconDir)
            Base64ToFile(IconData[key][px], path)
        } catch {
            return ""
        }
    }
    return path
}

SetMenuIcon(m, title, name, size) {
    f := IconFile(name, size)
    if (f != "")
        try m.SetIcon(title, f, 1, size)
}


; ================================ menu ================================

ShowMenu(*) {
    global prevWin, currentMenu, menuOpen, reopen, trigKind, menuSel
    kind := trigKind
    trigKind := ""

    if (menuOpen || toolBusy)
        return

    active := WinExist("A")  ; remember where the symbol must be typed
    if (active && active != A_ScriptHwnd)
        prevWin := active

    Loop {
        reopen := false
        if (kind = "reg") {
            for key in ["Ctrl", "Shift", "Alt", "LWin", "RWin"]
                KeyWait(key, "T1")   ; let the shortcut keys be released first
        } else {
            ; mouse shortcut (Ctrl + right click): Ctrl may still be held, do not let it change what is typed later
            ReleaseMods()
        }

        ApplyMenuTheme()
        menuSel := SplitSelection(GetSelectedPaths(prevWin))      ; files / folders selected in Explorer (or on the desktop)
        currentMenu := BuildMenu()
        CoordMode("Menu", "Screen")
        menuOpen := true
        try {
            currentMenu.Show()   ; opens at the mouse pointer
        } finally {
            menuOpen := false
        }

        ; The shortcut was pressed again while the menu was open:
        ; the menu was closed, so open a new one at the new mouse position.
        if (!reopen)
            break
        Sleep(30)
    }
}

; Re-applies the Windows theme just before each (sub)menu opens, so the symbols
; submenu gets the same dark / light look as the main menu
MenuPopupOpening(wParam, lParam, msg, hwnd) {
    ApplyMenuTheme()
}

; Called by Windows when the shortcut is pressed (also while the menu is open)
HotkeyArrived(wParam, lParam, msg, hwnd) {
    global reopen, trigKind
    found := false
    for hk, info in ActiveHk {
        if (info.id = wParam)
            found := true
    }
    if (!found)
        return
    if (toolBusy)
        return 0
    if (menuOpen) {
        reopen := true
        DllCall("EndMenu")           ; closes the open menu
    } else {
        trigKind := "reg"
        SetTimer(ShowMenu, -1)
    }
    return 0
}

; Used by the shortcuts that need AutoHotkey's own hook (mouse buttons)
HookTrigger(*) {
    global trigKind
    trigKind := "ahk"
    ShowMenu()
}

; Turns the shortcut on. Returns true if it worked.
ActivateHotkey(hk, tries := 1) {
    global ActiveHk, HkCounter
    if (ActiveHk.Has(hk))
        return true
    SplitHotkey(hk, &mods, &k)
    vk := 0
    try vk := GetKeyVK(k)
    if (vk && !RegExMatch(k, "i)button|wheel")) {
        m := 0x4000                  ; MOD_NOREPEAT
        if InStr(mods, "!")
            m |= 0x1
        if InStr(mods, "^")
            m |= 0x2
        if InStr(mods, "+")
            m |= 0x4
        if InStr(mods, "#")
            m |= 0x8
        id := HK_BASE + HkCounter
        HkCounter += 1
        Loop tries {
            if DllCall("RegisterHotKey", "ptr", A_ScriptHwnd, "int", id, "uint", m, "uint", vk) {
                ActiveHk[hk] := {kind: "reg", id: id}
                return true
            }
            Sleep(100)               ; the previous copy of the script may still be closing
        }
    }
    ; Fallback (mouse buttons, or a shortcut that Windows refuses):
    ; works, but cannot reopen the menu while it is open.
    try {
        Hotkey(HotName(hk), HookTrigger, "On T2")
        ActiveHk[hk] := {kind: "ahk", id: 0}
        return true
    }
    return false
}

; Turns one shortcut off
DeactivateHotkey(hk) {
    global ActiveHk
    if (!ActiveHk.Has(hk))
        return
    info := ActiveHk[hk]
    if (info.kind = "reg")
        DllCall("UnregisterHotKey", "ptr", A_ScriptHwnd, "int", info.id)
    else
        try Hotkey(HotName(hk), "Off")
    ActiveHk.Delete(hk)
}

DeactivateAllHotkeys() {
    keys := []
    for hk, info in ActiveHk
        keys.Push(hk)
    for hk in keys
        DeactivateHotkey(hk)
}

menuSel := {files: [], folders: []}

; Paths selected in the window that was active when the menu was asked (Explorer window or desktop)
GetSelectedPaths(hwnd) {
    paths := []
    if (!hwnd)
        return paths
    static shell := ""
    cls := ""
    try cls := WinGetClass("ahk_id " hwnd)
    if (cls = "CabinetWClass" || cls = "ExploreWClass") {
        try {
            if (!IsObject(shell))
                shell := ComObject("Shell.Application")      ; created once, then reused (faster)
            for w in shell.Windows {
                try {
                    if (w.HWND != hwnd)
                        continue
                    found := []
                    for it in w.Document.SelectedItems
                        found.Push(it.Path)
                    if (found.Length) {              ; (with tabs, the tab that has a selection)
                        paths := found
                        break
                    }
                }
            }
        }
    } else if (cls = "Progman" || cls = "WorkerW") {
        paths := DesktopSelection()
    }
    return paths
}

; The desktop cannot be asked directly: copy the selection (Ctrl+C) and read the list of files, then put the clipboard back
DesktopSelection() {
    paths := []
    ; nothing selected on the desktop? then do nothing (no delay)
    try {
        lv := ControlGetHwnd("SysListView321", "ahk_class Progman")
    } catch {
        try lv := ControlGetHwnd("SysListView321", "ahk_class WorkerW")
    }
    if (IsSet(lv) && lv && DllCall("SendMessageW", "ptr", lv, "uint", 0x1032, "ptr", 0, "ptr", 0, "ptr") = 0)   ; LVM_GETSELECTEDCOUNT
        return paths
    saved := ClipboardAll()
    A_Clipboard := ""
    Send("^c")
    if (ClipWait(0.25, 1) && DllCall("OpenClipboard", "ptr", 0)) {
        h := DllCall("GetClipboardData", "uint", 15, "ptr")       ; CF_HDROP = list of files
        if (h) {
            n := DllCall("shell32\DragQueryFileW", "ptr", h, "uint", 0xFFFFFFFF, "ptr", 0, "uint", 0, "uint")
            Loop n {
                len := DllCall("shell32\DragQueryFileW", "ptr", h, "uint", A_Index - 1, "ptr", 0, "uint", 0, "uint")
                buf := Buffer((len + 1) * 2, 0)
                DllCall("shell32\DragQueryFileW", "ptr", h, "uint", A_Index - 1, "ptr", buf, "uint", len + 1)
                paths.Push(StrGet(buf, "UTF-16"))
            }
        }
        DllCall("CloseClipboard")
    }
    A_Clipboard := saved
    return paths
}

; Splits real paths into folders and files (anything else, like "This PC", is ignored)
SplitSelection(paths) {
    r := {files: [], folders: []}
    for p in paths {
        if (p = "" || !FileExist(p))
            continue
        if (InStr(FileExist(p), "D"))
            r.folders.Push(p)
        else
            r.files.Push(p)
    }
    return r
}

; Menu entry "Add to Launch Box" / "Add to Quick Access"
AddSelected(kind, paths, *) {
    added := 0
    for p in paths {
        dup := false
        for it in Items[kind] {
            if (StrLower(RTrim(it.val, "\")) = StrLower(RTrim(p, "\"))) {
                dup := true
                break
            }
        }
        if (!dup) {
            Items[kind].Push({val: p, label: ""})
            added += 1
        }
    }
    if (added)
        SaveConfig()
    where := (kind = "A") ? "Launch Box" : "Quick Access"
    ToolTip(added ? "Added to " where : "Already in " where)
    SetTimer(() => ToolTip(), -1800)
}

BuildMenu() {
    m := Menu()
    size := Round(16 * A_ScreenDPI / 96)
    state := {needSep: false, added: 0}

    ; ---- what is selected in Explorer / on the desktop: offer to add it ----
    if (menuSel.files.Length) {
        ttl := "Add to Launch Box" (menuSel.files.Length > 1 ? " (" menuSel.files.Length ")" : "")
        m.Add(ttl, AddSelected.Bind("A", menuSel.files))
        SetMenuIcon(m, ttl, "launch", size)
        state.needSep := true
    }
    if (menuSel.folders.Length) {
        ttl := "Add to Quick Access" (menuSel.folders.Length > 1 ? " (" menuSel.folders.Length ")" : "")
        m.Add(ttl, AddSelected.Bind("F", menuSel.folders))
        SetMenuIcon(m, ttl, "folder", size)
        state.needSep := true
    }
    if (state.needSep) {
        m.Add()
        state.needSep := false
    }

    ; ---- Pins at the top (setting: Settings > Pins) ----
    if (PinPos = "top")
        AddPinsToMenu(m, size, state)

    ; ---- Symbols (one entry with an arrow, the symbols open on the side) ----
    if (Items["S"].Length) {
        sub := Menu()
        seenS := Map()
        for s in Items["S"] {
            title := (s.label = "") ? s.val : s.val "   " s.label
            title := UniqueTitle(seenS, title)
            ; one single column (a second column would lose the dark / light theme)
            sub.Add(Esc(title), InsertSymbol.Bind(s.val))
        }
        if (state.needSep)
            m.Add()
        m.Add("Symbols", sub)
        SetMenuIcon(m, "Symbols", "symbols", size)
        state.needSep := true
        state.added += 1
    }

    ; ---- Tools (the ones that are ticked in Settings > Tools, in that order) ----
    firstTool := true
    seenT := Map()
    for tp in ToolPrefs {
        if (!tp.on || !ToolDefs.Has(tp.id))
            continue
        if (firstTool && state.needSep)
            m.Add()
        firstTool := false
        td := ToolDefs[tp.id]
        title := UniqueTitle(seenT, Esc(ToolTitle(tp)))
        m.Add(title, td.fn)
        SetMenuIcon(m, title, td.icon, size)
        state.needSep := true
        state.added += 1
    }

    ; ---- Launch Box (apps and files, opens on the side) ----
    if (Items["A"].Length) {
        sub := Menu()
        seenA := Map()
        for a in Items["A"] {
            title := UniqueTitle(seenA, Esc(a.label != "" ? a.label : DefaultName("A", a)))
            sub.Add(title, OpenApp.Bind(a.val))
            SetPathIcon(sub, title, a.val, size)
        }
        if (state.needSep)
            m.Add()
        m.Add("Launch Box", sub)
        SetMenuIcon(m, "Launch Box", "launch", size)
        state.needSep := true
        state.added += 1
    }

    ; ---- Quick Access (folders, opens on the side) ----
    if (Items["F"].Length) {
        sub := Menu()
        seenF := Map()
        for d in Items["F"] {
            title := UniqueTitle(seenF, Esc(d.label != "" ? d.label : NameOf(d.val, false)))
            sub.Add(title, OpenFolder.Bind(d.val))
            SetFolderIcon(sub, title, d.val, size)
        }
        if (state.needSep)
            m.Add()
        m.Add("Quick Access", sub)
        SetMenuIcon(m, "Quick Access", "folder", size)
        state.needSep := true
        state.added += 1
    }

    ; ---- Pins at the bottom ----
    if (PinPos != "top")
        AddPinsToMenu(m, size, state)

    if (state.added = 0)
        m.Add("Nothing to show - open Settings", ShowSettings)
    return m
}

; Pinned items (files, apps or folders) are listed directly in the menu
AddPinsToMenu(m, size, state) {
    if (!Items["P"].Length)
        return
    if (state.needSep && PinPos != "top")
        m.Add()
    seenP := Map()
    for p in Items["P"] {
        title := UniqueTitle(seenP, Esc(p.label != "" ? p.label : DefaultName("P", p)))
        m.Add(title, OpenPin.Bind(p.val))
        SetPathIcon(m, title, p.val, size)
        state.added += 1
    }
    state.needSep := true
    if (PinPos = "top")
        m.Add()
    state.needSep := false
}

; Icon of a path: folder icon for a folder, the program icon for a file / shortcut
SetPathIcon(m, title, path, size) {
    if IsUrl(path) {
        f := FaviconFile(path)
        if FileExist(f) {
            try m.SetIcon(title, f, 1, size)
        } else {
            SetTimer(FetchFavicon.Bind(path), -300)     ; fetch it in the background for next time
            try m.SetIcon(title, "shell32.dll", 14, size)
        }
        return
    }
    if DirExist(path) {
        SetFolderIcon(m, title, path, size)
        return
    }
    iconFile := path
    if (StrLower(SubStr(path, -4)) = ".lnk") {
        try {
            FileGetShortcut(path, &target)
            if (target != "")
                iconFile := target
        }
    }
    try m.SetIcon(title, iconFile, 1, size)
}

; A menu cannot hold two entries with the same name (upper / lower case counts as the same,
; so "e" and "E" would merge). Adds invisible trailing spaces to make each name unique.
UniqueTitle(seen, title) {
    key := StrLower(title)
    n := seen.Has(key) ? seen[key] : 0
    seen[key] := n + 1
    if (n = 0)
        return title
    loop n
        title .= " "
    return title
}

; Uses the folder's real icon (custom icon if it has one), else the standard folder icon
SetFolderIcon(m, title, path, size) {
    file := "shell32.dll"
    num := 4
    try {
        sfi := Buffer(A_PtrSize + 8 + 520 + 160, 0)
        if DllCall("shell32\SHGetFileInfoW", "str", path, "uint", 0, "ptr", sfi, "uint", sfi.Size, "uint", 0x1000, "ptr") {
            f := StrGet(sfi.Ptr + A_PtrSize + 8, 260, "UTF-16")
            i := NumGet(sfi, A_PtrSize, "int")
            if (f != "") {
                file := f
                num := (i >= 0) ? i + 1 : i
            }
        }
    }
    try
        m.SetIcon(title, file, num, size)
    catch
        try m.SetIcon(title, "shell32.dll", 4, size)
}


; ============================== actions ==============================

InsertSymbol(text, *) {
    if (prevWin && WinExist("ahk_id " prevWin)) {
        WinActivate("ahk_id " prevWin)
        WinWaitActive("ahk_id " prevWin, , 1)
    }
    Sleep(50)
    if (InsertMode = "Paste") {
        saved := ClipboardAll()
        A_Clipboard := text
        if ClipWait(1) {
            Send("^v")
            Sleep(200)
        }
        A_Clipboard := saved
    } else {
        SendText(text)
    }
}

OpenApp(path, *) {
    if IsUrl(path) {
        try Run(path)
        return
    }
    try {
        SplitPath(path, , &dir)
        Run('"' path '"', dir)
    } catch as e {
        MsgBox("Could not open this application:`n" path "`n`n" e.Message, "Contextool", "Iconx")
    }
}

; ---------------- websites in the Launch Box ----------------

IsUrl(v) => RegExMatch(v, "i)^(https?://|www\.)\S+$")

NormalizeUrl(v) => RegExMatch(v, "i)^www\.") ? "https://" v : v

; "https://www.youtube.com/watch?v=1" -> "youtube.com"
UrlHost(u) => RegExMatch(u, "i)^https?://([^/:?#]+)", &m) ? RegExReplace(m[1], "i)^www\.", "") : u

FaviconFile(u) => DataDir "\favicons\" RegExReplace(UrlHost(u), "[^\w.-]", "_") ".png"

; Downloads the small icon of a website into the data folder (once). Returns true if the icon is there
FetchFavicon(u) {
    f := FaviconFile(u)
    if FileExist(f)
        return true
    try {
        DirCreate(DataDir "\favicons")
        Download("https://www.google.com/s2/favicons?domain=" UrlHost(u) "&sz=64", f)
        fo := FileOpen(f, "r")
        magic := fo.ReadUInt()
        fo.Close()
        if (magic = 0x474E5089)          ; a real PNG file
            return true
        FileDelete(f)
    } catch {
        try FileDelete(f)
    }
    return false
}

OpenPin(path, *) {
    if (IsUrl(path) || !DirExist(path))
        OpenApp(path)               ; websites and files (OpenApp handles both)
    else
        OpenFolder(path)
}

OpenFolder(path, *) {
    try {
        if !DirExist(path)
            throw Error("Folder not found.")
        Run('explorer.exe "' path '"')
    } catch as e {
        MsgBox("Could not open this folder:`n" path "`n`n" e.Message, "Contextool", "Iconx")
    }
}


; ============================== tools: common ==============================

; While a tool is picking something on screen, the mouse buttons and Esc are
; captured, so nothing is clicked in the programs behind.
GrabInput(on) {
    for k in ["*LButton", "*RButton", "*Esc"] {
        try {
            if (on)
                Hotkey(k, GrabKey, "On")
            else
                Hotkey(k, "Off")
        }
    }
}

GrabKey(name) {
    global pickCancel, pickClick, pickRight
    if (name = "*LButton") {
        pickClick := true      ; left click
    } else {
        pickCancel := true     ; Esc or right click = cancel
        if (name = "*RButton")
            pickRight := true  ; (the color picker uses the right click for the palette)
    }
}

; Lets the user drag a rectangle on the screen.
; Returns {x, y, w, h} (screen pixels) or false if cancelled.
SelectRegion() {
    global pickCancel, pickClick, selHwnds
    pickCancel := false
    pickClick := false
    CoordMode("Mouse", "Screen")
    CoordMode("ToolTip", "Screen")
    vx := SysGet(76)
    vy := SysGet(77)
    vw := SysGet(78)
    vh := SysGet(79)
    bt := Max(2, Round(2 * A_ScreenDPI / 96))

    ov := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale")
    ov.BackColor := "000000"
    ov.Show("NA x" vx " y" vy " w" vw " h" vh)
    WinSetTransparent(80, "ahk_id " ov.Hwnd)
    selHwnds[ov.Hwnd] := 1

    edges := []
    Loop 4 {
        e := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale")
        e.BackColor := "00B7FF"
        e.Show("NA x-100 y-100 w1 h1")
        selHwnds[e.Hwnd] := 1
        edges.Push(e)
    }
    OnMessage(0x20, SetCrossCursor)    ; WM_SETCURSOR

    rect := false
    try {
        KeyWait("LButton")
        GrabInput(true)
        pickClick := false
        ToolTip("Drag to select an area  -  Esc to cancel")
        t0 := A_TickCount
        started := false
        Loop {
            if (pickCancel || A_TickCount - t0 > 90000)
                break
            if (pickClick || GetKeyState("LButton", "P")) {
                started := true
                break
            }
            Sleep(10)
        }
        if (started) {
            MouseGetPos(&sx, &sy)
            cx := sx
            cy := sy
            while (GetKeyState("LButton", "P") && !pickCancel) {
                MouseGetPos(&cx, &cy)
                x1 := Min(sx, cx)
                y1 := Min(sy, cy)
                w := Abs(cx - sx)
                h := Abs(cy - sy)
                ToolTip(w " x " h)
                edges[1].Move(x1, y1, w + bt, bt)
                edges[2].Move(x1, y1 + h, w + bt, bt)
                edges[3].Move(x1, y1, bt, h + bt)
                edges[4].Move(x1 + w, y1, bt, h + bt)
                Sleep(10)
            }
            if (!pickCancel)
                rect := {x: Min(sx, cx), y: Min(sy, cy), w: Abs(cx - sx), h: Abs(cy - sy)}
        }
    } finally {
        ToolTip()
        OnMessage(0x20, SetCrossCursor, 0)
        for e in edges
            e.Destroy()
        ov.Destroy()
        selHwnds.Clear()
        GrabInput(false)
    }
    return rect
}

SetCrossCursor(wParam, lParam, msg, hwnd) {
    if (selHwnds.Has(hwnd)) {
        DllCall("SetCursor", "ptr", DllCall("LoadCursor", "ptr", 0, "ptr", 32515, "ptr"))   ; IDC_CROSS
        return 1
    }
}

; Saves a part of the screen as a PNG file (scale = enlargement factor). Returns true if OK.
CaptureToFile(x, y, w, h, file, scale := 1) {
    global gdipToken
    if (!gdipToken) {
        DllCall("LoadLibrary", "str", "gdiplus")
        si := Buffer(24, 0)
        NumPut("uint", 1, si)
        tok := 0
        DllCall("gdiplus\GdiplusStartup", "ptr*", &tok, "ptr", si, "ptr", 0)
        gdipToken := tok
    }
    dw := w * scale
    dh := h * scale
    hdcScr := DllCall("GetDC", "ptr", 0, "ptr")
    hdc := DllCall("CreateCompatibleDC", "ptr", hdcScr, "ptr")
    hbm := DllCall("CreateCompatibleBitmap", "ptr", hdcScr, "int", dw, "int", dh, "ptr")
    old := DllCall("SelectObject", "ptr", hdc, "ptr", hbm, "ptr")
    DllCall("SetStretchBltMode", "ptr", hdc, "int", 4)       ; HALFTONE
    DllCall("StretchBlt", "ptr", hdc, "int", 0, "int", 0, "int", dw, "int", dh
        , "ptr", hdcScr, "int", x, "int", y, "int", w, "int", h, "uint", 0x40CC0020)
    DllCall("SelectObject", "ptr", hdc, "ptr", old)
    pBmp := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hbm, "ptr", 0, "ptr*", &pBmp)
    clsid := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid)
    status := 1
    if (pBmp) {
        status := DllCall("gdiplus\GdipSaveImageToFile", "ptr", pBmp, "wstr", file, "ptr", clsid, "ptr", 0)
        DllCall("gdiplus\GdipDisposeImage", "ptr", pBmp)
    }
    DllCall("DeleteObject", "ptr", hbm)
    DllCall("DeleteDC", "ptr", hdc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScr)
    return (status = 0)
}

; Runs a PowerShell script (written to a temp file) and waits for it. Returns true if it finished.
RunPs(name, script, params, timeoutMs := 120000) {
    ps1 := A_Temp "\ctxmenu_" name ".ps1"
    try FileDelete(ps1)
    f := FileOpen(ps1, "w", "UTF-8")
    f.Write(script)
    f.Close()
    pid := 0
    Run('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' ps1 '" ' params, , "Hide", &pid)
    t0 := A_TickCount
    while (ProcessExist(pid)) {
        if (A_TickCount - t0 > timeoutMs) {
            try ProcessClose(pid)
            return false
        }
        Sleep(60)
    }
    return true
}

; Small window with a result that can be copied (or not)
ShowResult(title, text, info := "", url := "") {
    g := Gui("+AlwaysOnTop", title)
    g.SetFont("s10", "Segoe UI")
    if (info != "")
        g.Add("Text", "w520", info)
    shown := StrReplace(StrReplace(text, "`r`n", "`n"), "`n", "`r`n")
    ed := g.Add("Edit", "w520 r9 Multi", shown)
    btn := g.Add("Button", "w160 Default", "Copy to clipboard")
    btn.OnEvent("Click", (*) => CopyResult(ed, btn))
    if (url != "") {
        b2 := g.Add("Button", "x+10 w120", "Open link")
        b2.OnEvent("Click", (*) => Run(url))
    }
    b3 := g.Add("Button", "x+10 w90", "Close")
    b3.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    ThemeGui(g)
    g.Show()
}

CopyResult(ed, btn) {
    A_Clipboard := ed.Value
    btn.Text := "Copied"
}


; ============================== tool: color picker ==============================

ColorPicker(*) {
    global toolBusy, pickCancel, pickClick, pickRight
    if (toolBusy)
        return
    toolBusy := true
    pickCancel := false
    pickClick := false
    pickRight := false
    g := ""
    hg := ""
    ctrlPick := false
    rightPick := false
    hdcSrc := 0
    hdcDst := 0
    picked := false
    hex := ""
    try {
        KeyWait("LButton")
        CoordMode("Mouse", "Screen")
        CoordMode("Pixel", "Screen")
        CoordMode("ToolTip", "Screen")
        sc := A_ScreenDPI / 96
        cell := Max(1, Round(11 * sc))       ; size of one zoomed pixel
        area := 11 * cell                    ; zoom area: 11 x 11 screen pixels
        swH := Round(14 * sc)                ; color bar
        lblH := Round(26 * sc)               ; hex text
        totalH := area + swH + lblH + Round(3 * sc)

        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale")
        g.BackColor := "1F1F1F"
        g.SetFont("s10 cFFFFFF", "Consolas")
        lbl := g.Add("Text", "x0 y" (area + swH + Round(3 * sc)) " w" area " h" lblH " Center", "")
        g.Show("NA x-3000 y-3000 w" area " h" totalH)
        hg := MakePickerHint()

        hdcSrc := DllCall("GetDC", "ptr", 0, "ptr")
        hdcDst := DllCall("GetDC", "ptr", g.Hwnd, "ptr")
        DllCall("SetStretchBltMode", "ptr", hdcDst, "int", 3)      ; COLORONCOLOR (sharp pixels)
        rc := Buffer(16, 0)
        hbrWhite := DllCall("GetStockObject", "int", 0, "ptr")
        hbrBlack := DllCall("GetStockObject", "int", 4, "ptr")

        GrabInput(true)
        pickClick := false
        lastX := -99999
        lastY := -99999
        lastHex := ""
        t0 := A_TickCount
        Loop {
            if (pickCancel || A_TickCount - t0 > 90000) {
                if (pickRight) {
                    ; right click: palette of the color under the mouse
                    rightPick := true
                    MouseGetPos(&mx, &my)
                    hex := Format("#{:06X}", PixelGetColor(mx, my) + 0)
                }
                break
            }
            MouseGetPos(&mx, &my)
            col := PixelGetColor(mx, my) + 0
            hex := Format("#{:06X}", col)
            if (pickClick || GetKeyState("LButton", "P")) {
                picked := true
                ctrlPick := GetKeyState("Ctrl", "P")
                break
            }
            if (mx != lastX || my != lastY) {
                PlacePicker(g, mx, my, area, totalH, sc)
                PlaceHint(hg, g)
                lastX := mx
                lastY := my
            }
            ; zoomed view of the pixels around the mouse
            DllCall("StretchBlt", "ptr", hdcDst, "int", 0, "int", 0, "int", area, "int", area
                , "ptr", hdcSrc, "int", mx - 5, "int", my - 5, "int", 11, "int", 11, "uint", 0x00CC0020)
            ; frame around the pixel that will be picked
            NumPut("int", 5 * cell, "int", 5 * cell, "int", 6 * cell, "int", 6 * cell, rc)
            DllCall("FrameRect", "ptr", hdcDst, "ptr", rc, "ptr", hbrBlack)
            NumPut("int", 5 * cell + 1, "int", 5 * cell + 1, "int", 6 * cell - 1, "int", 6 * cell - 1, rc)
            DllCall("FrameRect", "ptr", hdcDst, "ptr", rc, "ptr", hbrWhite)
            ; color bar
            bgr := ((col & 0xFF) << 16) | (col & 0xFF00) | ((col >> 16) & 0xFF)
            br := DllCall("CreateSolidBrush", "uint", bgr, "ptr")
            NumPut("int", 0, "int", area, "int", area, "int", area + swH, rc)
            DllCall("FillRect", "ptr", hdcDst, "ptr", rc, "ptr", br)
            DllCall("DeleteObject", "ptr", br)
            if (hex != lastHex) {
                lbl.Text := hex
                lastHex := hex
            }
            Sleep(15)
        }
    } finally {
        if (picked)
            KeyWait("LButton", "T2")
        if (rightPick)
            KeyWait("RButton", "T2")
        GrabInput(false)
        if (IsObject(hg))
            hg.Destroy()
        if (hdcDst)
            DllCall("ReleaseDC", "ptr", g.Hwnd, "ptr", hdcDst)
        if (hdcSrc)
            DllCall("ReleaseDC", "ptr", 0, "ptr", hdcSrc)
        if (IsObject(g))
            g.Destroy()
        toolBusy := false
    }
    if (picked && ctrlPick) {
        A_Clipboard := CmykText(hex)
        ToolTip("Copied CMYK of " hex)
        SetTimer(() => ToolTip(), -1800)
    } else if (picked) {
        A_Clipboard := hex
        ToolTip("Copied " hex)
        SetTimer(() => ToolTip(), -1800)
    } else if (rightPick) {
        ToolTip("Opening Coolors with " hex)
        SetTimer(() => ToolTip(), -1800)
        try Run("https://coolors.co/" SubStr(hex, 2))
    }
}

; Small bubble next to the picker that explains the secret shortcuts
MakePickerHint() {
    hg := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale")
    hg.BackColor := "2B2B2B"
    hg.MarginX := 12
    hg.MarginY := 9
    hg.SetFont("s9 cFFFFFF", "Segoe UI")
    hg.Add("Text", "Section", "Left click`nCtrl + left click`nRight click`nEsc")
    hg.Add("Text", "ys x+18", "Copy HEX`nCopy CMYK`nMatching color palette`nCancel")
    hg.Show("NA x-3000 y-3000 AutoSize")
    return hg
}

; Puts the bubble right under the picker (above it if there is no room)
PlaceHint(hg, g) {
    g.GetPos(&gx, &gy, &gw, &gh)
    hg.GetPos(, , &hw, &hh)
    b := A_ScreenHeight
    r := A_ScreenWidth
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (gx >= ml && gx < mr && gy >= mt && gy < mb) {
            b := mb
            r := mr
            break
        }
    }
    x := gx
    y := gy + gh + 6
    if (y + hh > b)
        y := gy - hh - 6
    if (x + hw > r)
        x := r - hw - 4
    hg.Move(x, y)
}

; RGB color ("#RRGGBB") -> text with the 4 CMYK values, one per line
CmykText(hex) {
    r := Integer("0x" SubStr(hex, 2, 2)) / 255
    gr := Integer("0x" SubStr(hex, 4, 2)) / 255
    b := Integer("0x" SubStr(hex, 6, 2)) / 255
    k := 1 - Max(r, gr, b)
    if (k >= 1) {
        c := 0
        m := 0
        y := 0
    } else {
        c := (1 - r - k) / (1 - k)
        m := (1 - gr - k) / (1 - k)
        y := (1 - b - k) / (1 - k)
    }
    return "C : " Round(c * 100) "%`r`nM : " Round(m * 100) "%`r`nY : " Round(y * 100) "%`r`nK : " Round(k * 100) "%"
}

; Puts the magnifier next to the mouse (and keeps it on the screen)
PlacePicker(g, mx, my, w, h, sc) {
    off := Round(24 * sc)
    l := 0
    t := 0
    r := A_ScreenWidth
    b := A_ScreenHeight
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (mx >= ml && mx < mr && my >= mt && my < mb) {
            l := ml
            t := mt
            r := mr
            b := mb
            break
        }
    }
    x := mx + off
    y := my + off
    if (x + w > r)
        x := mx - off - w
    if (y + h > b)
        y := my - off - h
    g.Move(x, y)
}


; ============================== tool: sticky notes ==============================

NewNote(*) {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    sc := A_ScreenDPI / 96
    note := CreateNote("", mx + 12, my + 12, Round(280 * sc), Round(220 * sc), true)
    SaveNotes()
}

; Creates a sticky note. todo = to-do list mode, mini = shown as a small icon, cidx = color number of its icon
CreateNote(text, x, y, w, h, activate := false, todo := false, mini := false, cidx := -1) {
    global Notes
    sc := A_ScreenDPI / 96
    ; keep the note on the screen
    vx := SysGet(76)
    vy := SysGet(77)
    vw := SysGet(78)
    vh := SysGet(79)
    if (x < vx - 40 || y < vy - 10 || x > vx + vw - 80 || y > vy + vh - 80) {
        x := vx + 80
        y := vy + 80
    }
    w := Max(w, Round(170 * sc))
    h := Max(h, Round(110 * sc))
    if (cidx < 0)
        cidx := NoteNextColor()
    barH := Round(26 * sc)
    LoadRichEdit()

    dark := IsDarkTheme()
    bg := dark ? "202020" : "FFFFFF"
    g := Gui("+AlwaysOnTop +Resize +ToolWindow -DPIScale +MinSize" Round(170 * sc) "x" Round(110 * sc), "Note")
    g.BackColor := bg
    g.SetFont("s9", "Segoe UI")
    bTodo := g.Add("Text", "x" Round(8 * sc) " y" Round(5 * sc) " w" Round(80 * sc) " h" Round(18 * sc) " +0x100", "☑ To-do")
    bMin := g.Add("Text", "x" (w - Round(88 * sc)) " y" Round(5 * sc) " w" Round(80 * sc) " h" Round(18 * sc) " +0x100 Right", "– Reduce")
    ed := g.Add("Custom", "ClassRICHEDIT50W x0 y" barH " w" w " h" (h - barH) " +0x4 +0x40 +0x1000 +0x100 -E0x200")
    note := {gui: g, ed: ed, bTodo: bTodo, bMin: bMin, todo: todo, mini: mini, cidx: cidx, w: w, h: h, barH: barH, icon: "", pic: "", busy: false, retodo: ""}
    note.retodo := NoteApplyTodo.Bind(note)
    Notes.Push(note)

    SendMessage(0xD3, 3, 10 | (10 << 16), ed)       ; EM_SETMARGINS: a little space left and right
    SendMessage(0x445, 0, 1, ed)                    ; EM_SETEVENTMASK: tell me when the text changes
    ed.OnCommand(0x300, (*) => NoteChanged(note))   ; EN_CHANGE
    bTodo.OnEvent("Click", (*) => NoteToggleTodo(note))
    bMin.OnEvent("Click", (*) => NoteMinimize(note))
    g.OnEvent("Size", NoteResized.Bind(note))
    g.OnEvent("Close", NoteClose.Bind(note))
    SetDarkTitle(g, dark)
    NoteSetText(note, text)
    ApplyNoteTheme(note)

    if (mini) {
        NoteShowIcon(note, x, y)
    } else if (activate) {
        ; a NEW note takes the keyboard focus, so you can type right away
        g.Show("x" x " y" y " w" w " h" h)
        FocusNote(note)
        SetTimer(FocusNote.Bind(note), -150)      ; second try, in case Windows refused the first one
    } else
        g.Show("NA x" x " y" y " w" w " h" h)      ; notes restored at start-up stay quiet
    return note
}

FocusNote(note) {
    try {
        WinActivate("ahk_id " note.gui.Hwnd)
        note.ed.Focus()
    }
}

; ---------------- note text and to-do list ----------------

NoteGetText(note) {
    t := ""
    try t := ControlGetText(note.ed)
    return StrReplace(StrReplace(t, "`r`n", "`n"), "`r", "`n")
}

NoteSetText(note, text) {
    note.busy := true
    try ControlSetText(StrReplace(StrReplace(text, "`r`n", "`n"), "`n", "`r`n"), note.ed)
    note.busy := false
}

; Character format of the text: scope 4 = all the text, 1 = the selection
NoteFmt(ed, scope, mask, effects, color, size := 0, face := "") {
    cf := Buffer(92, 0)
    NumPut("uint", 92, cf, 0)
    NumPut("uint", mask, cf, 4)
    NumPut("uint", effects, cf, 8)
    NumPut("int", size, cf, 12)
    NumPut("uint", color, cf, 20)
    if (face != "")
        StrPut(face, cf.Ptr + 26, 32, "UTF-16")
    DllCall("SendMessageW", "ptr", ed.Hwnd, "uint", 0x444, "ptr", scope, "ptr", cf)    ; EM_SETCHARFORMAT
}

NoteSetSel(note, s, e) {
    DllCall("SendMessageW", "ptr", note.ed.Hwnd, "uint", 0xB1, "ptr", s, "ptr", e)     ; EM_SETSEL
}

; Look of the whole text: Segoe UI 11, color of the Windows theme, no strike-through
NoteBaseFormat(note) {
    fg := IsDarkTheme() ? 0xF2F2F2 : 0x1A1A1A
    NoteFmt(note.ed, 4, 0x20000000 | 0x80000000 | 0x40000000 | 0x8, 0, fg, 220, "Segoe UI")
    NoteFmt(note.ed, 0, 0x20000000 | 0x80000000 | 0x40000000 | 0x8, 0, fg, 220, "Segoe UI")   ; and for the text typed later
}

; Draws the strike-through (and grey color) on every line that starts with a ticked box
NoteApplyTodo(note) {
    if (note.busy)
        return
    note.busy := true
    try {
        ed := note.ed
        selS := 0
        selE := 0
        DllCall("SendMessageW", "ptr", ed.Hwnd, "uint", 0xB0, "ptr", StrPtr(""), "ptr", 0)
        DllCall("SendMessageW", "ptr", ed.Hwnd, "uint", 0xB0, "uint*", &selS, "uint*", &selE, "ptr")   ; EM_GETSEL
        DllCall("SendMessageW", "ptr", ed.Hwnd, "uint", 0xB, "ptr", 0, "ptr", 0)                         ; no redraw while working
        NoteBaseFormat(note)
        if (note.todo) {
            fg := IsDarkTheme() ? 0xF2F2F2 : 0x1A1A1A
            pos := 0
            for line in StrSplit(NoteGetText(note), "`n") {
                len := StrLen(line)
                if (len > 0 && SubStr(line, 1, 1) = "☑") {
                    NoteSetSel(note, pos, pos + len)
                    NoteFmt(ed, 1, 0x8 | 0x40000000, 0x8, 0x8C8C8C)
                }
                pos += len + 1
            }
        }
        NoteSetSel(note, selS, selE)
        DllCall("SendMessageW", "ptr", ed.Hwnd, "uint", 0xB, "ptr", 1, "ptr", 0)
        ed.Redraw()
    }
    note.busy := false
}

NoteChanged(note) {
    if (note.busy)
        return
    ScheduleNoteSave()
    if (note.todo)
        SetTimer(note.retodo, -500)      ; text typed on a ticked line gets the line-through too
}

; Switches the note between normal text and to-do list
NoteToggleTodo(note) {
    note.todo := !note.todo
    if (note.todo) {
        out := ""
        for line in StrSplit(NoteGetText(note), "`n") {
            if (line != "" && !RegExMatch(line, "^[☐☑]"))
                line := "☐ " line
            out .= (A_Index > 1 ? "`n" : "") line
        }
        if (Trim(out, " `t`n") = "")
            out := "☐ "
        NoteSetText(note, out)
    }
    NoteApplyTodo(note)
    NoteSetSel(note, 0x7FFFFFFF, 0x7FFFFFFF)     ; cursor at the end
    NoteStripColors(note)
    ScheduleNoteSave()
    try note.ed.Focus()
}

; Colors of the two little buttons on top of the note
NoteStripColors(note) {
    dark := IsDarkTheme()
    muted := dark ? "A8A8A8" : "5A5A5A"
    accent := dark ? "5CA8FF" : "0A64C8"
    try {
        note.bTodo.SetFont("c" (note.todo ? accent : muted))
        note.bMin.SetFont("c" muted)
        note.bTodo.Text := note.bTodo.Text
        note.bMin.Text := note.bMin.Text
    }
}

; A click on the box at the start of a line ticks / unticks it. Returns true if the click was used.
NoteTickClick(note, lParam) {
    x := lParam & 0xFFFF
    if (x > 32767)
        x -= 65536
    y := (lParam >> 16) & 0xFFFF
    if (y > 32767)
        y -= 65536
    ed := note.ed
    pt := Buffer(8, 0)
    NumPut("int", x, pt, 0)
    NumPut("int", y, pt, 4)
    idx := DllCall("SendMessageW", "ptr", ed.Hwnd, "uint", 0xD7, "ptr", 0, "ptr", pt, "ptr")     ; EM_CHARFROMPOS
    pos := 0
    for line in StrSplit(NoteGetText(note), "`n") {
        len := StrLen(line)
        if (idx >= pos && idx <= pos + len) {
            mark := SubStr(line, 1, 1)
            if ((mark != "☐" && mark != "☑") || idx - pos > 1)
                return false
            p2 := Buffer(8, 0)
            DllCall("SendMessageW", "ptr", ed.Hwnd, "uint", 0xD6, "ptr", p2, "ptr", pos + 1)       ; EM_POSFROMCHAR
            if (x > NumGet(p2, 0, "int") + Round(6 * A_ScreenDPI / 96))
                return false
            NoteSetSel(note, pos, pos + 1)
            DllCall("SendMessageW", "ptr", ed.Hwnd, "uint", 0xC2, "ptr", 1, "ptr", StrPtr(mark = "☑" ? "☐" : "☑"))   ; EM_REPLACESEL
            NoteApplyTodo(note)
            ScheduleNoteSave()
            return true
        }
        pos += len + 1
    }
    return false
}

; Mouse button pressed anywhere in one of our windows
NoteClick(wParam, lParam, msg, hwnd) {
    for n in Notes {
        if (n.todo && !n.mini && n.ed.Hwnd = hwnd) {
            if (NoteTickClick(n, lParam)) {
                try n.ed.Focus()
                return 0
            }
            return
        }
        if (n.mini && IsObject(n.icon) && (hwnd = n.icon.Hwnd || (IsObject(n.pic) && hwnd = n.pic.Hwnd))) {
            SetTimer(NoteIconDown.Bind(n), -1)
            return 0
        }
    }
}

; Enter in a to-do note starts a new task
NoteFocusedTodo() {
    h := WinExist("A")
    for n in Notes {
        if (n.todo && !n.mini && n.gui.Hwnd = h)
            return n
    }
    return false
}

NoteTodoFocused(*) {
    return !!NoteFocusedTodo()
}

NoteEnterKey(*) {
    n := NoteFocusedTodo()
    if (!IsObject(n)) {
        Send("{Enter}")
        return
    }
    DllCall("SendMessageW", "ptr", n.ed.Hwnd, "uint", 0xC2, "ptr", 1, "ptr", StrPtr("`r☐ "))   ; EM_REPLACESEL
    NoteApplyTodo(n)
}

; ---------------- note reduced to a small icon ----------------

; First color number (0-7) that no other note uses
NoteNextColor() {
    used := Map()
    for n in Notes
        used[n.cidx] := true
    Loop 8 {
        if (!used.Has(A_Index - 1))
            return A_Index - 1
    }
    return Mod(Notes.Length, 8)
}

; Draws the note icon with another color (hue turned by an angle). Returns true if the file was written.
HueRotatePng(src, dst, deg) {
    if (!EnsureGdip())
        return false
    pSrc := 0
    DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", src, "ptr*", &pSrc)
    if (!pSrc)
        return false
    w := 0
    h := 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", pSrc, "uint*", &w)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", pSrc, "uint*", &h)
    pDst := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &pDst)
    pG := 0
    pIA := 0
    status := 1
    if (pDst) {
        DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", pDst, "ptr*", &pG)
        DllCall("gdiplus\GdipGraphicsClear", "ptr", pG, "uint", 0xFFFFFFFF)      ; soft edges blend with white
        a := deg * 3.14159265358979 / 180
        c := Cos(a)
        s := Sin(a)
        A3 := [[0.213 + c * 0.787 - s * 0.213, 0.213 - c * 0.213 + s * 0.143, 0.213 - c * 0.213 - s * 0.787]
            , [0.715 - c * 0.715 - s * 0.715, 0.715 + c * 0.285 + s * 0.140, 0.715 - c * 0.715 + s * 0.715]
            , [0.072 - c * 0.072 + s * 0.928, 0.072 - c * 0.072 - s * 0.283, 0.072 + c * 0.928 + s * 0.072]]
        m := Buffer(100, 0)
        Loop 3 {
            r := A_Index
            Loop 3
                NumPut("float", A3[r][A_Index], m, ((r - 1) * 5 + (A_Index - 1)) * 4)
        }
        NumPut("float", 1, m, (3 * 5 + 3) * 4)
        NumPut("float", 1, m, (4 * 5 + 4) * 4)
        DllCall("gdiplus\GdipCreateImageAttributes", "ptr*", &pIA)
        DllCall("gdiplus\GdipSetImageAttributesColorMatrix", "ptr", pIA, "int", 0, "int", 1, "ptr", m, "ptr", 0, "int", 0)
        DllCall("gdiplus\GdipDrawImageRectRectI", "ptr", pG, "ptr", pSrc, "int", 0, "int", 0, "int", w, "int", h
            , "int", 0, "int", 0, "int", w, "int", h, "int", 2, "ptr", pIA, "ptr", 0, "ptr", 0)
        clsid := Buffer(16, 0)
        DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid)
        ; pixels that were see-through in the original get the "see-through" color (the icon window hides it)
        Loop h {
            yy := A_Index - 1
            Loop w {
                xx := A_Index - 1
                argb := 0
                DllCall("gdiplus\GdipBitmapGetPixel", "ptr", pSrc, "int", xx, "int", yy, "uint*", &argb)
                if (((argb >> 24) & 0xFF) < 110)
                    DllCall("gdiplus\GdipBitmapSetPixel", "ptr", pDst, "int", xx, "int", yy, "uint", 0xFF010203)
            }
        }
        status := DllCall("gdiplus\GdipSaveImageToFile", "ptr", pDst, "wstr", dst, "ptr", clsid, "ptr", 0)
    }
    if (pIA)
        DllCall("gdiplus\GdipDisposeImageAttributes", "ptr", pIA)
    if (pG)
        DllCall("gdiplus\GdipDeleteGraphics", "ptr", pG)
    if (pDst)
        DllCall("gdiplus\GdipDisposeImage", "ptr", pDst)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pSrc)
    return (status = 0)
}

EnsureGdip() {
    global gdipToken
    if (gdipToken)
        return true
    DllCall("LoadLibrary", "str", "gdiplus")
    si := Buffer(24, 0)
    NumPut("uint", 1, si)
    tok := 0
    DllCall("gdiplus\GdiplusStartup", "ptr*", &tok, "ptr", si, "ptr", 0)
    gdipToken := tok
    return !!tok
}

; Path of the note icon (original yellow one for color 0, other hues for the next notes)
NoteIconFile(cidx, px) {
    src := IconDir "\note_color_" px ".png"
    if (!FileExist(src)) {
        try {
            DirCreate(IconDir)
            Base64ToFile(IconData["note_color"][px], src)
        } catch {
            return ""
        }
    }
    angles := [0, 180, 100, 290, 240, 320, 140, 30]
    dst := IconDir "\noteicon_" cidx "_" px ".png"
    if (FileExist(dst))
        return dst
    ok := false
    try ok := HueRotatePng(src, dst, angles[Mod(cidx, 8) + 1])
    return ok ? dst : src
}

NoteMakeIcon(note) {
    sc := A_ScreenDPI / 96
    want := Round(30 * sc)
    px := 32
    for p in [20, 24, 32] {
        if (p >= want) {
            px := p
            break
        }
    }
    ig := Gui("-Caption +AlwaysOnTop +ToolWindow -DPIScale", "Note")
    ig.BackColor := "010203"
    f := NoteIconFile(note.cidx, px)
    if (f != "")
        note.pic := ig.Add("Picture", "x0 y0 w" px " h" px, f)
    try WinSetTransColor("010203", ig)
    note.icon := ig
    note.iconPx := px
}

NoteShowIcon(note, x, y) {
    if (!IsObject(note.icon))
        NoteMakeIcon(note)
    note.mini := true
    note.icon.Show("NA x" x " y" y " w" note.iconPx " h" note.iconPx)
}

NoteMinimize(note) {
    note.gui.GetPos(&x, &y)
    note.gui.GetClientPos(, , &w, &h)
    note.w := w
    note.h := h
    note.gui.Hide()
    NoteShowIcon(note, x, y)
    SaveNotes()
}

NoteExpand(note) {
    note.icon.GetPos(&x, &y)
    vx := SysGet(76)
    vy := SysGet(77)
    vw := SysGet(78)
    vh := SysGet(79)
    x := Max(vx, Min(x, vx + vw - note.w - 20))
    y := Max(vy, Min(y, vy + vh - note.h - 60))
    note.icon.Hide()
    note.mini := false
    note.gui.Show("x" x " y" y " w" note.w " h" note.h)
    FocusNote(note)
    SetTimer(FocusNote.Bind(note), -150)
    SaveNotes()
}

; Left button pressed on the icon: drag moves it, a simple click opens the note
NoteIconDown(note) {
    if (!note.mini)
        return
    note.icon.GetPos(&x0, &y0)
    DllCall("SendMessageW", "ptr", note.icon.Hwnd, "uint", 0xA1, "ptr", 2, "ptr", 0)    ; WM_NCLBUTTONDOWN on the title area = drag
    note.icon.GetPos(&x1, &y1)
    if (Abs(x1 - x0) < 4 && Abs(y1 - y0) < 4)
        NoteExpand(note)
    else
        SaveNotes()
}

; True when Windows apps use the dark theme
IsDarkTheme() {
    try {
        return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme") = 0
    }
    return false
}

; Dark (or light) title bar for a window
SetDarkTitle(g, dark) {
    v := dark ? 1 : 0
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 20, "int*", v, "int", 4)
}

; Gives an existing note the colors of the current Windows theme
ApplyNoteTheme(note) {
    dark := IsDarkTheme()
    bg := dark ? "202020" : "FFFFFF"
    try {
        note.gui.BackColor := bg
        SendMessage(0x443, 0, Integer("0x" bg), note.ed)       ; EM_SETBKGNDCOLOR
        SetDarkTitle(note.gui, dark)
        NoteApplyTodo(note)
        NoteStripColors(note)
    }
}

; Windows told us that its settings changed (maybe light <-> dark)
ThemeChanged(wParam, lParam, msg, hwnd) {
    SetTimer(RecolorNotes, -400)
}

RecolorNotes() {
    for n in Notes
        ApplyNoteTheme(n)
}

NoteResized(note, g, minMax, w, h) {
    if (minMax = -1)
        return
    sc := A_ScreenDPI / 96
    note.ed.Move(0, note.barH, w, h - note.barH)
    note.bMin.Move(w - Round(88 * sc))
    note.w := w
    note.h := h
    ScheduleNoteSave()
}

; The note is deleted when its window is closed (asks first if it contains text)
NoteClose(note, g) {
    global Notes
    if (Trim(NoteGetText(note), " `t`n") != "") {
        if (MsgBox("Delete this note?", "Contextool", "YesNo Icon? Owner" g.Hwnd) != "Yes")
            return true            ; true = keep the window
    }
    for i, n in Notes {
        if (n.gui.Hwnd = g.Hwnd) {
            Notes.RemoveAt(i)
            break
        }
    }
    try note.icon.Destroy()
    SetTimer(SaveNotes, -100)
}

NoteMoved(wParam, lParam, msg, hwnd) {
    for n in Notes {
        if (n.gui.Hwnd = hwnd || (IsObject(n.icon) && n.icon.Hwnd = hwnd)) {
            ScheduleNoteSave()
            return
        }
    }
}

ScheduleNoteSave() {
    SetTimer(SaveNotes, -700)
}

EscNote(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, "`r", "")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return s
}

UnescNote(s) {
    out := ""
    i := 1
    n := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if (c = "\" && i < n) {
            d := SubStr(s, i + 1, 1)
            if (d = "n")
                out .= "`n"
            else if (d = "t")
                out .= "`t"
            else
                out .= d
            i += 2
        } else {
            out .= c
            i += 1
        }
    }
    return out
}

SaveNotes() {
    text := ""
    for n in Notes {
        try {
            if (n.mini && IsObject(n.icon)) {
                n.icon.GetPos(&x, &y)
                w := n.w
                h := n.h
            } else {
                n.gui.GetPos(&x, &y)
                n.gui.GetClientPos(, , &w, &h)
            }
            text .= x "`t" y "`t" w "`t" h "`t" EscNote(NoteGetText(n)) "`t" (n.todo ? 1 : 0) "`t" (n.mini ? 1 : 0) "`t" n.cidx "`n"
        }
    }
    try {
        DirCreate(SettingsDir)
        f := FileOpen(NotesFile, "w", "UTF-8-RAW")
        f.Write(text)
        f.Close()
    }
}

LoadNotes() {
    if (!FileExist(NotesFile))
        return
    text := ""
    try text := FileRead(NotesFile, "UTF-8")
    for line in StrSplit(text, "`n", "`r") {
        if (line = "")
            continue
        p := StrSplit(line, "`t")
        if (p.Length < 5 || !IsInteger(p[1]) || !IsInteger(p[2]) || !IsInteger(p[3]) || !IsInteger(p[4]))
            continue
        todo := (p.Length >= 6 && p[6] = "1")
        mini := (p.Length >= 7 && p[7] = "1")
        cidx := (p.Length >= 8 && IsInteger(p[8])) ? Integer(p[8]) : -1
        CreateNote(UnescNote(p[5]), Integer(p[1]), Integer(p[2]), Integer(p[3]), Integer(p[4]), false, todo, mini, cidx)
    }
}

ExitHandler(reason, code) {
    if (!noSaveNotes)
        SaveNotes()
}


; ============================== tool: text from screen (OCR) ==============================

OcrTool(*) {
    global toolBusy
    if (toolBusy)
        return
    toolBusy := true
    try {
        r := SelectRegion()
        if (!r)
            return
        if (r.w < 4 || r.h < 4) {
            MsgBox("The selected area is too small.", "Contextool", "Icon!")
            return
        }
        Sleep(250)                       ; let the screen redraw without the selection
        png := A_Temp "\ctxmenu_ocr.png"
        out := A_Temp "\ctxmenu_ocr.txt"
        try FileDelete(png)
        try FileDelete(out)
        scale := (Max(r.w, r.h) <= 900) ? 2 : 1      ; bigger pictures take longer, so only small areas are enlarged
        if (!CaptureToFile(r.x, r.y, r.w, r.h, png, scale)) {
            MsgBox("Could not capture this area of the screen.", "Contextool", "Iconx")
            return
        }
        ToolTip("Reading text... (a few seconds)")
        RunPs("ocr", PsOcrScript(), '-Image "' png '" -Out "' out '" -Lang "' OcrLanguage '"', 120000)
        ToolTip()
        text := ""
        if FileExist(out)
            text := Trim(FileRead(out, "UTF-8"), " `t`r`n")
        try FileDelete(png)
        if (text = "") {
            MsgBox("The text reader did not answer. Please try again.", "Contextool", "Iconx")
        } else if (SubStr(text, 1, 6) = "ERROR:") {
            code := SubStr(text, 7)
            if (code = "NOENGINE")
                MsgBox("Windows has no text recognition (OCR) language available.`n`nAdd one in: Settings > Time & language > Language & region > Add a language (with 'Optical character recognition').", "Contextool", "Iconx")
            else
                MsgBox("The text reader failed:`n" code, "Contextool", "Iconx")
        } else if (text = "EMPTY") {
            MsgBox("No text was found in this area.", "Contextool", "Icon!")
        } else {
            ShowResult("Text from screen", text, "Text found in the selected area. Edit it if needed, then copy it (or not).")
        }
    } finally {
        ToolTip()
        toolBusy := false
    }
}

; Runs a tiny PowerShell once, hidden, a few seconds after start-up: Windows (and antivirus) then
; already know PowerShell + the text-recognition parts, which makes the first real OCR much faster
OcrWarmUp() {
    try Run('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Runtime.WindowsRuntime; $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]"', , "Hide")
}

PsOcrScript() {
    s := "
    (
param([string]$Image, [string]$Out, [string]$Lang)
$ErrorActionPreference = 'Stop'
function Save($t) { [System.IO.File]::WriteAllText($Out, $t, (New-Object System.Text.UTF8Encoding($false))) }
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $null = [Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
  $opName = 'IAsyncOperation' + [char]96 + '1'
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq $opName })[0]
  function Await($op, $type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $task.Wait(-1) | Out-Null
    $task.Result
  }
  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Image)) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $engine = $null
  if ($Lang) { try { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($Lang)) } catch { } }
  if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
  if (-not $engine) {
    try {
      $first = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | Select-Object -First 1
      if ($first) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($first) }
    } catch { }
  }
  if (-not $engine) { Save 'ERROR:NOENGINE'; exit }
  $result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
  $lines = @()
  foreach ($l in $result.Lines) { $lines += $l.Text }
  $text = ($lines -join [Environment]::NewLine)
  if ($text.Trim().Length -eq 0) { Save 'EMPTY' } else { Save $text }
} catch { Save ('ERROR:' + $_.Exception.Message) }
    )"
    return s
}


; ============================== tool: QR code / barcode reader ==============================

QrTool(*) {
    global toolBusy
    if (toolBusy)
        return
    toolBusy := true
    try {
        r := SelectRegion()
        if (!r)
            return
        if (r.w < 8 || r.h < 8) {
            MsgBox("The selected area is too small.", "Contextool", "Icon!")
            return
        }
        Sleep(250)
        png := A_Temp "\ctxmenu_qr.png"
        out := A_Temp "\ctxmenu_qr.txt"
        try FileDelete(png)
        try FileDelete(out)
        if (!CaptureToFile(r.x, r.y, r.w, r.h, png, 1)) {
            MsgBox("Could not capture this area of the screen.", "Contextool", "Iconx")
            return
        }
        first := !DirExist(ZxingDir "\pkg")
        ToolTip(first ? "Reading code... (first use: downloading the reader, please wait)" : "Reading code...")
        RunPs("qr", PsQrScript(), '-Image "' png '" -Out "' out '" -Dir "' ZxingDir '"', 180000)
        ToolTip()
        text := ""
        if FileExist(out)
            text := Trim(FileRead(out, "UTF-8"), " `t`r`n")
        try FileDelete(png)
        if (text = "") {
            MsgBox("The code reader did not answer. Please try again.", "Contextool", "Iconx")
        } else if (SubStr(text, 1, 6) = "ERROR:") {
            code := SubStr(text, 7)
            if (code = "DOWNLOAD")
                MsgBox("The barcode reader could not be downloaded (internet needed the first time).`nPlease check your connection and try again.", "Contextool", "Iconx")
            else
                MsgBox("The code reader failed:`n" code, "Contextool", "Iconx")
        } else if (text = "EMPTY") {
            MsgBox("No QR code or barcode was found in this area.`nTry to select a bit more around the code.", "Contextool", "Icon!")
        } else {
            nl := InStr(text, "`n")
            fmt := Trim(SubStr(text, 1, nl - 1), " `r")
            content := Trim(SubStr(text, nl + 1), " `t`r`n")
            link := ""
            if RegExMatch(content, "i)^https?://\S+$")
                link := content
            ShowResult("QR code / barcode", content, "Type: " fmt, link)
        }
    } finally {
        ToolTip()
        toolBusy := false
    }
}

PsQrScript() {
    s := "
    (
param([string]$Image, [string]$Out, [string]$Dir)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Save($t) { [System.IO.File]::WriteAllText($Out, $t, (New-Object System.Text.UTF8Encoding($false))) }
function Find-Dll {
  $all = @(Get-ChildItem -Path $Dir -Recurse -Filter 'zxing.dll' -ErrorAction SilentlyContinue)
  foreach ($pref in @('net48', 'net47', 'net461', 'net45', 'net40', 'net35', 'net20')) {
    foreach ($f in $all) { if ($f.Directory.Name -eq $pref) { return $f.FullName } }
  }
  return $null
}
try {
  $dll = Find-Dll
  if (-not $dll) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $zip = Join-Path $Dir 'zxing.zip'
    $ok = $false
    foreach ($u in @('https://www.nuget.org/api/v2/package/ZXing.Net/0.16.11', 'https://www.nuget.org/api/v2/package/ZXing.Net/0.16.9')) {
      try { Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing; $ok = $true; break } catch { }
    }
    if (-not $ok) { Save 'ERROR:DOWNLOAD'; exit }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dest = Join-Path $Dir 'pkg'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
    Remove-Item $zip -Force
    $dll = Find-Dll
  }
  if (-not $dll) { Save 'ERROR:Reader files not found'; exit }
  Add-Type -AssemblyName System.Drawing
  [void][System.Reflection.Assembly]::LoadFrom($dll)
  $reader = New-Object ZXing.BarcodeReader
  $reader.AutoRotate = $true
  $reader.Options.TryHarder = $true
  $reader.Options.TryInverted = $true
  $src = New-Object System.Drawing.Bitmap($Image)
  $found = $null
  foreach ($scale in @(1, 2, 3)) {
    if ($scale -eq 1) { $bmp = $src } else { $bmp = New-Object System.Drawing.Bitmap($src, [int]($src.Width * $scale), [int]($src.Height * $scale)) }
    $res = $null
    try { $res = $reader.DecodeMultiple($bmp) } catch { }
    if (-not $res) { try { $one = $reader.Decode($bmp); if ($one) { $res = @($one) } } catch { } }
    if ($res) { $found = $res; break }
  }
  if (-not $found) { Save 'EMPTY'; exit }
  $fmts = @()
  $texts = @()
  foreach ($r in $found) { $fmts += [string]$r.BarcodeFormat; $texts += [string]$r.Text }
  $nl = [Environment]::NewLine
  Save (($fmts -join ', ') + $nl + ($texts -join ($nl + $nl)))
} catch { Save ('ERROR:' + $_.Exception.Message) }
    )"
    return s
}


; ============================== tool: screenshot to clipboard ==============================

ScreenshotTool(*) {
    global toolBusy
    if (toolBusy)
        return
    toolBusy := true
    try {
        r := SelectRegion()
        if (!r)
            return
        if (r.w < 2 || r.h < 2)
            return
        Sleep(250)                       ; let the screen redraw without the selection
        err := CaptureToClipboard(r.x, r.y, r.w, r.h)
        if (err = "") {
            ToolTip("Screenshot copied to the clipboard (" r.w " x " r.h ", nothing was saved)")
            SetTimer(() => ToolTip(), -2200)
        } else {
            MsgBox("Could not copy the screenshot to the clipboard.`n`n" err, "Contextool", "Iconx")
        }
    } finally {
        toolBusy := false
    }
}

; Puts a part of the screen on the clipboard as an image (no file is written).
; Returns "" when it worked, otherwise a text describing the problem.
CaptureToClipboard(x, y, w, h) {
    hdcScr := DllCall("GetDC", "ptr", 0, "ptr")
    hdc := DllCall("CreateCompatibleDC", "ptr", hdcScr, "ptr")
    bi := Buffer(40, 0)                          ; 24-bit bitmap
    NumPut("uint", 40, bi, 0)
    NumPut("int", w, bi, 4)
    NumPut("int", h, bi, 8)
    NumPut("ushort", 1, bi, 12)
    NumPut("ushort", 24, bi, 14)
    bits := 0
    hbm := DllCall("CreateDIBSection", "ptr", hdcScr, "ptr", bi, "uint", 0, "ptr*", &bits, "ptr", 0, "uint", 0, "ptr")
    err := ""
    if (!hbm || !bits) {
        err := "Could not create the image (error " A_LastError ")."
    } else {
        old := DllCall("SelectObject", "ptr", hdc, "ptr", hbm, "ptr")
        DllCall("BitBlt", "ptr", hdc, "int", 0, "int", 0, "int", w, "int", h
            , "ptr", hdcScr, "int", x, "int", y, "uint", 0x40CC0020)
        DllCall("SelectObject", "ptr", hdc, "ptr", old)

        ; copy the pixels into a global memory block: header + pixels (clipboard format CF_DIB)
        stride := ((w * 24 + 31) // 32) * 4
        size := stride * h
        hMem := DllCall("GlobalAlloc", "uint", 0x42, "uptr", 40 + size, "ptr")   ; GMEM_MOVEABLE | GMEM_ZEROINIT
        if (!hMem) {
            err := "Not enough memory for this screenshot."
        } else {
            pMem := DllCall("GlobalLock", "ptr", hMem, "ptr")
            NumPut("uint", 40, pMem, 0)
            NumPut("int", w, pMem, 4)
            NumPut("int", h, pMem, 8)
            NumPut("ushort", 1, pMem, 12)
            NumPut("ushort", 24, pMem, 14)
            NumPut("uint", 0, pMem, 16)
            NumPut("uint", size, pMem, 20)
            DllCall("RtlMoveMemory", "ptr", pMem + 40, "ptr", bits, "uptr", size)
            DllCall("GlobalUnlock", "ptr", hMem)

            opened := false
            Loop 20 {
                if (DllCall("OpenClipboard", "ptr", A_ScriptHwnd)) {
                    opened := true
                    break
                }
                Sleep(50)
            }
            if (!opened) {
                err := "The clipboard is busy (another program is using it). Please try again."
                DllCall("GlobalFree", "ptr", hMem)
            } else {
                DllCall("EmptyClipboard")
                res := DllCall("SetClipboardData", "uint", 8, "ptr", hMem, "ptr")   ; CF_DIB
                lastErr := A_LastError
                DllCall("CloseClipboard")
                if (!res) {
                    err := "Windows refused the image (error " lastErr ")."
                    DllCall("GlobalFree", "ptr", hMem)
                } else if (!DllCall("IsClipboardFormatAvailable", "uint", 8)) {
                    err := "The image was not kept by the clipboard (another program may have replaced it)."
                }
            }
        }
        DllCall("DeleteObject", "ptr", hbm)
    }
    DllCall("DeleteDC", "ptr", hdc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScr)
    return err
}


; ============================== tool: Google image search (Lens) ==============================
; The picture is sent by YOUR browser (a small local page posts it to Google Lens),
; so Google sees your normal browser session and cookies.

LensTool(*) {
    global toolBusy
    if (toolBusy)
        return
    toolBusy := true
    try {
        r := SelectRegion()
        if (!r)
            return
        if (r.w < 8 || r.h < 8) {
            MsgBox("The selected area is too small.", "Contextool", "Icon!")
            return
        }
        Sleep(250)
        png := A_Temp "\ctxmenu_lens.png"
        html := A_Temp "\ctxmenu_lens.html"
        try FileDelete(png)
        try FileDelete(html)
        if (!CaptureToFile(r.x, r.y, r.w, r.h, png, 1)) {
            MsgBox("Could not capture this area of the screen.", "Contextool", "Iconx")
            return
        }
        b64 := FileToBase64(png)
        try FileDelete(png)
        if (b64 = "") {
            MsgBox("Could not prepare the image.", "Contextool", "Iconx")
            return
        }
        try {
            f := FileOpen(html, "w", "UTF-8-RAW")
            f.Write(LensPage(b64))
            f.Close()
            Run(html)
            SetTimer(DeleteLater.Bind(html), -90000)   ; the page holds your picture: remove it afterwards
        } catch as e {
            MsgBox("Could not open the Google Lens page:`n" e.Message, "Contextool", "Iconx")
        }
    } finally {
        toolBusy := false
    }
}

DeleteLater(file) {
    try FileDelete(file)
}

; Small web page that sends the picture to Google Lens as soon as it opens
LensPage(b64) {
    h := "<!doctype html><html><head><meta charset=utf-8><title>Google Lens</title></head>"
    h .= "<body style='margin:0;height:100vh;display:grid;place-items:center;background:rgb(32,33,36);color:rgb(232,234,237);font:16px Segoe UI,Arial,sans-serif'>"
    h .= "<div>Sending the image to Google Lens...</div>"
    h .= "<form id=f method=post enctype=multipart/form-data action='https://lens.google.com/v3/upload'>"
    h .= "<input type=file name=encoded_image id=i hidden></form>"
    h .= "<script>var b=atob('" b64 "'),a=new Uint8Array(b.length);"
    h .= "for(var k=0;k<b.length;k++)a[k]=b.charCodeAt(k);"
    h .= "var dt=new DataTransfer();dt.items.add(new File([a],'image.png',{type:'image/png'}));"
    h .= "document.getElementById('i').files=dt.files;document.getElementById('f').submit();</script></body></html>"
    return h
}

FileToBase64(file) {
    try {
        buf := FileRead(file, "RAW")
        len := 0
        DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", buf.Size, "uint", 0x40000001, "ptr", 0, "uint*", &len)
        out := Buffer(len * 2 + 2, 0)
        DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", buf.Size, "uint", 0x40000001, "ptr", out, "uint*", &len)
        return StrGet(out, len, "UTF-16")
    } catch {
        return ""
    }
}


; ============================== tool: font from a screen area (WhatFontIs) ==============================

FontIdTool(*) {
    global toolBusy
    if (toolBusy)
        return
    if (Trim(ApiKeys["whatfontis"]) = "") {
        if (MsgBox("This tool needs your free WhatFontIs API key.`n`nOpen the Settings now and paste it in the tab 'APIs'?", "Contextool", "YesNo Icon?") = "Yes")
            ShowSettings()
        return
    }
    toolBusy := true
    try {
        r := SelectRegion()
        if (!r)
            return
        if (r.w < 8 || r.h < 8) {
            MsgBox("The selected area is too small.", "Contextool", "Icon!")
            return
        }
        Sleep(250)
        png := A_Temp "\ctxmenu_font.png"
        out := A_Temp "\ctxmenu_font.txt"
        try FileDelete(png)
        try FileDelete(out)
        if (!CaptureToFile(r.x, r.y, r.w, r.h, png, 1)) {
            MsgBox("Could not capture this area of the screen.", "Contextool", "Iconx")
            return
        }
        if (FileGetSize(png) > 4500000) {
            try FileDelete(png)
            MsgBox("The selected area is too big for the font service (5 MB max).`nSelect a smaller area, just a few clear letters.", "Contextool", "Icon!")
            return
        }
        ToolTip("Looking for the font...")
        RunPs("fontid", PsFontIdScript(), '-Image "' png '" -Out "' out '" -Key "' Trim(ApiKeys["whatfontis"]) '"', 90000)
        ToolTip()
        text := ""
        if FileExist(out)
            text := Trim(FileRead(out, "UTF-8"), " `t`r`n")
        try FileDelete(png)
        if (text = "") {
            MsgBox("The font service did not answer. Please try again.", "Contextool", "Iconx")
        } else if (SubStr(text, 1, 6) = "ERROR:") {
            code := Trim(SubStr(text, 7))
            hint := ""
            if (RegExMatch(code, "^(401|403)"))
                hint := "`n`nYour API key may be wrong. Check your key in Settings > APIs."
            else if (RegExMatch(code, "^429"))
                hint := "`n`nThe daily limit of the free API (200 requests) is reached. Try again tomorrow."
            MsgBox("The font service returned an error:`n" code hint, "Contextool", "Iconx")
        } else {
            rows := []
            for line in StrSplit(text, "`n", "`r") {
                p := StrSplit(line, "`t")
                if (p.Length >= 1 && Trim(p[1]) != "")
                    rows.Push({name: p[1], type: (p.Length >= 2 ? p[2] : ""), url: (p.Length >= 3 ? p[3] : ""), site: (p.Length >= 4 ? p[4] : "")})
            }
            if (rows.Length = 0)
                MsgBox("No font was found.`nTry to select a few clear, large letters.", "Contextool", "Icon!")
            else
                ShowFontResults(rows)
        }
    } finally {
        ToolTip()
        toolBusy := false
    }
}

ShowFontResults(rows) {
    g := Gui("+AlwaysOnTop", "Font from screen")
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "w560", "Closest fonts found (best first). Double-click a font to open its page.")
    lv := g.Add("ListView", "w560 r6 -Multi", ["Font", "Type", "Site"])
    lv.ModifyCol(1, 300)
    lv.ModifyCol(2, 90)
    lv.ModifyCol(3, 150)
    DarkHeader(g, lv)
    for r in rows
        lv.Add("", r.name, r.type, r.site)
    lv.Modify(1, "Select Focus")
    b1 := g.Add("Button", "w150 Default", "Copy font name")
    b2 := g.Add("Button", "x+10 w130", "Open page")
    b3 := g.Add("Button", "x+10 w90", "Close")

    CopyName(*) {
        n := lv.GetNext()
        if (n) {
            A_Clipboard := rows[n].name
            b1.Text := "Copied"
        }
    }
    OpenPage(*) {
        n := lv.GetNext()
        if (n && rows[n].url != "")
            Run(rows[n].url)
    }
    b1.OnEvent("Click", CopyName)
    b2.OnEvent("Click", OpenPage)
    b3.OnEvent("Click", (*) => g.Destroy())
    lv.OnEvent("DoubleClick", OpenPage)
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    ThemeGui(g)
    g.Show()
}

PsFontIdScript() {
    s := "
    (
param([string]$Image, [string]$Out, [string]$Key)
$ErrorActionPreference = 'Stop'
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Image))
  $e = { param($v) [Net.WebUtility]::UrlEncode([string]$v) }
  $body = 'API_KEY=' + (& $e $Key) + '&IMAGEBASE64=1&urlimagebase64=' + (& $e $b64) + '&limit=5&mode=fast&FREEFONTS=0&NOTTEXTBOXSDETECTION=1'
  $r = Invoke-WebRequest -Uri 'https://www.whatfontis.com/api2/' -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 80
  $txt = [string]$r.Content
  $lines = @()
  try {
    $data = $txt | ConvertFrom-Json
    foreach ($d in @($data)) {
      if ($d.title) { $lines += ([string]$d.title + [char]9 + [string]$d.type + [char]9 + [string]$d.url + [char]9 + [string]$d.site) }
    }
  } catch { }
  if ($lines.Count -gt 0) {
    Set-Content -Path $Out -Value ($lines -join [char]10) -Encoding UTF8
  } else {
    $short = $txt.Substring(0, [Math]::Min(200, $txt.Length))
    Set-Content -Path $Out -Value ('ERROR:Unexpected answer ' + $short) -Encoding UTF8
  }
} catch {
  $code = ''
  try { $code = [string][int]$_.Exception.Response.StatusCode } catch { }
  $msg = $_.Exception.Message
  if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
  Set-Content -Path $Out -Value ('ERROR:' + $code + ' ' + $msg) -Encoding UTF8
}
    )"
    return s
}


; ============================ settings window ============================

ShowSettings(*) {
    global settingsGui
    try {
        if (IsObject(settingsGui) && WinExist("ahk_id " settingsGui.Hwnd)) {
            settingsGui.Show()
            return
        }
    }

    th := ThemeColors()
    DropLists.Clear()
    g := Gui("+E0x10", "Contextool - Settings")
    g.OnEvent("DropFiles", SettingsDrop)
    SetWinIcon(g)
    g.SetFont("s10", "Segoe UI")

    ; ---- header: logo, name, subtitle ----
    logo := DataDir "\tray_active_v1.ico"
    if FileExist(logo)
        try g.Add("Picture", "x20 y16 w36 h36", logo)
    g.SetFont("s15 bold")
    g.Add("Text", "x66 y12 w400", "Contextool")
    g.SetFont("s9 norm")
    sub := g.Add("Text", "x67 y40 w400", "Context menu for Windows")
    TextColors[sub.Hwnd] := th.dimB
    g.SetFont("s10")

    ; ---- tab strip: blocks, the active one in green ----
    names := ["Symbols", "Pins", "Quick Access", "Launch Box", "Tools", "Snippets", "APIs", "General"]
    tabBg := th.dark ? "242424" : "EFEFEF"
    tabFg := th.dark ? "CFCFCF" : "333333"
    want := []
    total := 0
    for nm in names {
        want.Push(StrLen(nm) * 7.2 + 24)
        total += want[A_Index]
    }
    gap := 4
    scale := (620 - gap * (names.Length - 1)) / total
    labels := []
    x := 20
    for i, nm in names {
        w := (i = names.Length) ? 640 - x : Round(want[i] * scale)
        t := g.Add("Text", "x" x " y66 w" w " h34 Center +0x200 +0x100 Background" tabBg, nm)
        t.SetFont("c" tabFg)
        Exempt[t.Hwnd] := true
        labels.Push(t)
        x += w + gap
    }
    line := g.Add("Text", "x20 y112 w620 h1 Background" th.line)
    Exempt[line.Hwnd] := true

    seen := Map()
    for hwnd, c in g
        seen[hwnd] := true
    groups := []
    for kind in ["S", "P", "F", "A"] {
        BuildTab(g, kind)
        groups.Push(GrabNew(g, seen))
    }
    BuildToolsTab(g)
    groups.Push(GrabNew(g, seen))
    BuildSnippetsTab(g)
    groups.Push(GrabNew(g, seen))
    BuildApiTab(g)
    groups.Push(GrabNew(g, seen))
    BuildGeneralTab(g)
    groups.Push(GrabNew(g, seen))

    SelectTab(i, *) {
        for j, grp in groups {
            for c in grp {
                c.Visible := (j = i)
                if (LvFrames.Has(c.Hwnd))
                    try LvFrames[c.Hwnd].ctl.Visible := (j = i)
            }
        }
        for j, lb in labels {
            if (j = i) {
                lb.Opt("+Background" th.accent)
                lb.SetFont("c0F0F0F bold")
            } else {
                lb.Opt("+Background" tabBg)
                lb.SetFont("c" tabFg " norm")
            }
            lb.Redraw()
        }
        if (i = 7)
            RemaskApiKeys()
    }
    for i, lb in labels
        lb.OnEvent("Click", SelectTab.Bind(i))

    ; every tab was built for a top at y45: move the contents below the header and the tab strip
    for grp in groups {
        for c in grp {
            c.GetPos(&cx, &cy)
            c.Move(cx, cy + 73)
        }
    }

    ; ---- footer ----
    fline := g.Add("Text", "x20 y470 w620 h1 Background" th.line)
    Exempt[fline.Hwnd] := true
    credit := g.Add("Text", "x20 y490 w300", StrLower(AppVersion) "  -  by Ahcene")
    TextColors[credit.Hwnd] := th.dimB
    closeBtn := g.Add("Text", "x530 y482 w110 h34 Center +0x200 +0x100 Background" th.accent, "Close")
    closeBtn.SetFont("c0F0F0F bold")
    Exempt[closeBtn.Hwnd] := true
    closeBtn.OnEvent("Click", (*) => g.Destroy())

    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    settingsGui := g
    ThemeGui(g)
    SelectTab(1)
    g.Show("w660 h530")
}

; Controls created since the last call (the content of one tab)
GrabNew(g, seen) {
    list := []
    for hwnd, c in g {
        if (!seen.Has(hwnd)) {
            seen[hwnd] := true
            list.Push(c)
        }
    }
    return list
}


; ---------------- theme: the windows follow Windows dark / light like the menu and the notes ----------------

ToBGR(hex) => ((Integer("0x" SubStr(hex, 1, 2))) | (Integer("0x" SubStr(hex, 3, 2)) << 8) | (Integer("0x" SubStr(hex, 5, 2)) << 16))

ThemeColors() {
    dark := IsDarkTheme()
    if (dark)
        t := {bg: "161616", fg: "F2F2F2", ctl: "1F1F1F", dim: "9A9A9A", line: "2E2E2E", accent: "4DFF7F"}
    else
        t := {bg: "FFFFFF", fg: "1A1A1A", ctl: "FFFFFF", dim: "6B6B6B", line: "E2E2E2", accent: "4DFF7F"}
    t.dark := dark
    t.bgB := ToBGR(t.bg)
    t.fgB := ToBGR(t.fg)
    t.ctlB := ToBGR(t.ctl)
    t.dimB := ToBGR(t.dim)
    t.accentB := ToBGR(t.accent)
    key := dark ? "d" : "l"
    if (!BrushCache.Has(key))
        BrushCache[key] := {bg: DllCall("CreateSolidBrush", "uint", t.bgB, "ptr"), ctl: DllCall("CreateSolidBrush", "uint", t.ctlB, "ptr")}
    t.brBg := BrushCache[key].bg
    t.brCtl := BrushCache[key].ctl
    return t
}

SetWinTheme(hwnd, name, sub := 0) {
    try {
        if (sub = 0)
            DllCall("uxtheme\SetWindowTheme", "ptr", hwnd, "str", name, "ptr", 0)
        else
            DllCall("uxtheme\SetWindowTheme", "ptr", hwnd, "str", name, "str", sub)
    }
}

; Gives a window the colors of the current Windows theme (call it before g.Show())
ThemeGui(g) {
    th := ThemeColors()
    ThemedGuis[g.Hwnd] := th
    g.BackColor := th.bg
    SetDarkTitle(g, th.dark)
    ; lists: rounded corners with a thin rounded frame drawn behind them (the Windows border would look broken)
    lists := []
    for hwnd, c in g {
        if (c.Type = "ListView")
            lists.Push(c)
    }
    r := Round(10 * A_ScreenDPI / 96)
    for c in lists {
        ok := false
        if (LvFrames.Has(c.Hwnd)) {
            info := LvFrames[c.Hwnd]           ; still the frame of this window? (window handles can be reused)
            ok := DllCall("IsWindow", "ptr", info.h) && DllCall("GetParent", "ptr", info.h, "ptr") = g.Hwnd
        }
        if (!ok) {
            c.Opt("-E0x200 -Border")                 ; no Windows border
            c.GetPos(&cx, &cy, &cw, &ch)
            fr := g.Add("Text", "x" (cx - 1) " y" (cy - 1) " w" (cw + 2) " h" (ch + 2) " +0x4000000")
            Exempt[fr.Hwnd] := true
            LvFrames[c.Hwnd] := {ctl: fr, h: fr.Hwnd}
            DllCall("SetWindowPos", "ptr", fr.Hwnd, "ptr", 1, "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x13)   ; behind everything
            fr.Visible := c.Visible
        }
        fr := LvFrames[c.Hwnd].ctl
        fr.Opt("+Background" th.line)
        RoundCtl(fr.Hwnd, r + 2)
        RoundCtl(c.Hwnd, r)
        fr.Redraw()
    }
    if (!th.dark)
        return
    for hwnd, c in g {
        switch c.Type {
            case "Edit", "DDL", "DropDownList", "ComboBox", "Hotkey", "ListBox":
                SetWinTheme(hwnd, "DarkMode_CFD")
            case "Button":
                SetWinTheme(hwnd, "DarkMode_Explorer")
            case "CheckBox", "Radio":
                SetWinTheme(hwnd, "", "")
            case "ListView":
                SendMessage(0x1001, 0, th.ctlB, c)      ; background
                SendMessage(0x1024, 0, th.fgB, c)       ; text
                SendMessage(0x1026, 0, th.ctlB, c)      ; text background
                SetWinTheme(hwnd, "DarkMode_Explorer")
        }
    }
}

; Rounded corners for a control (region in real pixels)
RoundCtl(hwnd, r) {
    rc := Buffer(16)
    DllCall("GetWindowRect", "ptr", hwnd, "ptr", rc)
    w := NumGet(rc, 8, "int") - NumGet(rc, 0, "int")
    h := NumGet(rc, 12, "int") - NumGet(rc, 4, "int")
    rgn := DllCall("CreateRoundRectRgn", "int", 0, "int", 0, "int", w + 1, "int", h + 1, "int", r, "int", r, "ptr")
    DllCall("SetWindowRgn", "ptr", hwnd, "ptr", rgn, "int", 1)
}

; In dark mode the Windows list header would show black text: hide it and write the titles ourselves
; (call right after the columns are created and sized)
DarkHeader(g, lv) {
    th := ThemeColors()
    if (!th.dark)
        return
    sc := A_ScreenDPI / 96
    n := lv.GetCount("Col")
    titles := []
    widths := []
    Loop n {
        titles.Push(lv.GetText(0, A_Index))
        widths.Push(SendMessage(0x101D, A_Index - 1, 0, lv))     ; LVM_GETCOLUMNWIDTH
    }
    lv.GetPos(&x, &y, &w, &h)
    hh := Round(22 * sc)
    lv.Opt("-Hdr")
    lv.Move(, y + hh, , h - hh)
    cx := x + Round(2 * sc)
    for i, t in titles {
        lb := g.Add("Text", "x" Round((cx + 6 * sc) / sc) " y" Round(y / sc) " w" Round((widths[i] - 6 * sc) / sc) " h" Round(hh / sc) " +0x200", t)
        TextColors[lb.Hwnd] := th.dimB
        cx += widths[i]
    }
}

; Text and box colors of the themed windows (WM_CTLCOLOR...)
CtlColor(wParam, lParam, msg, hwnd) {
    if (!ThemedGuis.Has(hwnd) || Exempt.Has(lParam))
        return
    th := ThemedGuis[hwnd]
    special := TextColors.Has(lParam)
    if (!th.dark && !special)
        return
    isEdit := (msg = 0x133 || msg = 0x134)
    DllCall("SetTextColor", "ptr", wParam, "uint", special ? TextColors[lParam] : th.fgB)
    DllCall("SetBkColor", "ptr", wParam, "uint", isEdit ? th.ctlB : th.bgB)
    return isEdit ? th.brCtl : th.brBg
}

; ---------------- tabs: symbols / apps / folders ----------------

DropLists := Map()

; Files / folders dropped on the Settings window are added to the tab that is open (Pins, Quick Access, Launch Box)
SettingsDrop(g, ctrl, files, x, y) {
    kind := ""
    lv := ""
    for k, l in DropLists {
        try {
            if (l.Visible) {
                kind := k
                lv := l
                break
            }
        }
    }
    if (kind = "")
        return
    added := 0
    skipped := 0
    for p in files {
        isDir := InStr(FileExist(p), "D")
        if ((kind = "F" && !isDir) || (kind = "A" && isDir)) {
            skipped += 1
            continue
        }
        dup := false
        for it in Items[kind] {
            if (StrLower(RTrim(it.val, "\")) = StrLower(RTrim(p, "\"))) {
                dup := true
                break
            }
        }
        if (dup)
            continue
        Items[kind].Push({val: p, label: ""})
        added += 1
    }
    if (added) {
        SaveConfig()
        RefreshList(kind, lv, Items[kind].Length)
    }
    msg := added ? added " added" : "Nothing added"
    if (skipped)
        msg .= (kind = "F") ? " (Quick Access takes folders only)" : " (Launch Box takes files and apps only)"
    ToolTip(msg)
    SetTimer(() => ToolTip(), -2200)
}

; Builds the content of one tab:
; S = symbols, P = pins (files, apps, folders), F = Quick Access (folders), A = Launch Box (apps, files)
BuildTab(g, kind) {
    if (kind = "S")
        cols := ["Symbol", "Description (optional)"]
    else
        cols := ["Name", "Path"]

    lv := g.Add("ListView", "x25 y45 w610 h200 -Multi", cols)
    if (kind != "S")
        DropLists[kind] := lv            ; files can be dropped on the settings window to add them
    if (kind = "S") {
        lv.ModifyCol(1, 90)
        lv.ModifyCol(2, 480)
    } else {
        lv.ModifyCol(1, 170)
        lv.ModifyCol(2, 410)
    }
    DarkHeader(g, lv)

    g.Add("Button", "x25 y255 w90", "Move up").OnEvent("Click", (*) => MoveEntry(kind, lv, -1))
    g.Add("Button", "x120 y255 w90", "Move down").OnEvent("Click", (*) => MoveEntry(kind, lv, 1))
    g.Add("Button", "x215 y255 w90", "Remove").OnEvent("Click", (*) => RemoveEntry(kind, lv))
    g.Add("Button", "x310 y255 w90", "Rename").OnEvent("Click", (*) => RenameEntry(kind, lv))
    if (kind = "P") {
        g.Add("Button", "x405 y255 w90", "Edit").OnEvent("Click", (*) => EditEntry(kind, lv))
        lv.OnEvent("DoubleClick", (ctrl, row) => EditEntry(kind, ctrl))
    } else {
        lv.OnEvent("DoubleClick", (ctrl, row) => RenameEntry(kind, ctrl))
    }

    if (kind = "S") {
        g.Add("Text", "x25 y300", "Symbol")
        g.Add("Text", "x125 y300", "Description (optional)")
        e1 := g.Add("Edit", "x25 y320 w90")
        e2 := g.Add("Edit", "x125 y320 w380")
        g.Add("Button", "x515 y318 w120", "Add symbol").OnEvent("Click", (*) => AddEntry(kind, lv, e1, e2))
    } else if (kind = "P") {
        g.Add("Text", "x25 y283", "Name (optional)")
        g.Add("Text", "x155 y283", "File, application, folder or website")
        e1 := g.Add("Edit", "x25 y303 w120")
        e2 := g.Add("Edit", "x155 y303 w250")
        g.Add("Button", "x410 y301 w75", "File...").OnEvent("Click", (*) => BrowseEntry("A", e2))
        g.Add("Button", "x490 y301 w80", "Folder...").OnEvent("Click", (*) => BrowseEntry("F", e2))
        g.Add("Button", "x575 y301 w60", "Pin").OnEvent("Click", (*) => AddEntry(kind, lv, e1, e2))
        g.Add("Text", "x25 y342", "Pins are shown:")
        r1 := g.Add("Radio", "x140 y340", "At the top of the menu (before Symbols)")
        r2 := g.Add("Radio", "x400 y340", "At the bottom (after Quick Access)")
        if (PinPos = "bottom")
            r2.Value := 1
        else
            r1.Value := 1
        r1.OnEvent("Click", (*) => SetPinPos("top"))
        r2.OnEvent("Click", (*) => SetPinPos("bottom"))
    } else {
        g.Add("Text", "x25 y300", "Name (optional)")
        g.Add("Text", "x155 y300", (kind = "A") ? "Application, file or website (https://...)" : "Folder")
        e1 := g.Add("Edit", "x25 y320 w120")
        e2 := g.Add("Edit", "x155 y320 w320")
        g.Add("Button", "x480 y318 w85", "Browse...").OnEvent("Click", (*) => BrowseEntry(kind, e2))
        g.Add("Button", "x570 y318 w65", "Add").OnEvent("Click", (*) => AddEntry(kind, lv, e1, e2))
    }

    RefreshList(kind, lv)
}

; Window to change the name and the target of a pin
EditEntry(kind, lv) {
    row := lv.GetNext()
    if (!row) {
        MsgBox("Click an item in the list first.", "Contextool", "Icon!")
        return
    }
    it := Items[kind][row]
    g := Gui("+AlwaysOnTop +Owner" settingsGui.Hwnd, "Contextool - Edit pin")
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "w500", "Name (optional):")
    en := g.Add("Edit", "w500", it.label)
    g.Add("Text", "w500", "File, application, folder or website:")
    ep := g.Add("Edit", "w500", it.val)
    g.Add("Button", "w90", "File...").OnEvent("Click", (*) => BrowseEntry("A", ep))
    g.Add("Button", "x+10 w90", "Folder...").OnEvent("Click", (*) => BrowseEntry("F", ep))
    g.Add("Button", "x+120 w100 Default", "Save").OnEvent("Click", (*) => SaveEdit(g, kind, lv, row, en, ep))
    g.Add("Button", "x+10 w90", "Cancel").OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    ThemeGui(g)
    g.Show()
}

SaveEdit(g, kind, lv, row, en, ep) {
    val := Trim(ep.Value, ' `t"')
    if (val = "") {
        MsgBox("Choose a path or type a website first.", "Contextool", "Icon!")
        return
    }
    isWeb := IsUrl(val)
    if (isWeb)
        val := NormalizeUrl(val)
    else if (!FileExist(val)) {
        if (MsgBox("This path does not exist:`n" val "`n`nSave it anyway?", "Contextool", "YesNo Icon?") != "Yes")
            return
    }
    it := Items[kind][row]
    it.val := val
    it.label := Trim(en.Value)
    SaveConfig()
    if (isWeb) {
        ToolTip("Getting the website icon...")
        FetchFavicon(val)
        ToolTip()
    }
    RefreshList(kind, lv, row)
    g.Destroy()
}

SetPinPos(pos) {
    global PinPos
    PinPos := pos
    SaveConfig()
}

; Name shown by default for an entry
DefaultName(kind, it) => IsUrl(it.val) ? UrlHost(it.val) : NameOf(it.val, (kind != "F" && !DirExist(it.val)))

RefreshList(kind, lv, selectRow := 0) {
    lv.Delete()
    for it in Items[kind] {
        if (kind = "S")
            lv.Add(, it.val, it.label)
        else
            lv.Add(, (it.label != "") ? it.label : DefaultName(kind, it), it.val)
    }
    if (selectRow > 0)
        lv.Modify(selectRow, "Select Focus Vis")
}

AddEntry(kind, lv, e1, e2) {
    if (kind = "S") {
        val := Trim(e1.Value)
        lbl := Trim(e2.Value)
        if (val = "") {
            MsgBox("Type a symbol first.", "Contextool", "Icon!")
            return
        }
    } else {
        lbl := Trim(e1.Value)
        val := Trim(e2.Value, ' `t"')
        if (val = "") {
            MsgBox("Choose a path first (use Browse...).", "Contextool", "Icon!")
            return
        }
        isWeb := ((kind = "A" || kind = "P") && IsUrl(val))
        if (isWeb)
            val := NormalizeUrl(val)
        exists := isWeb ? true : (kind = "F") ? DirExist(val) : FileExist(val)
        if (!exists) {
            if (MsgBox("This path does not exist:`n" val "`n`nAdd it anyway?", "Contextool", "YesNo Icon?") != "Yes")
                return
        }
    }
    Items[kind].Push({val: val, label: lbl})
    SaveConfig()
    if ((kind = "A" || kind = "P") && IsUrl(val)) {
        ToolTip("Getting the website icon...")
        FetchFavicon(val)
        ToolTip()
    }
    RefreshList(kind, lv, Items[kind].Length)
    e1.Value := ""
    e2.Value := ""
}

RenameEntry(kind, lv) {
    row := lv.GetNext()
    if (!row) {
        MsgBox("Click an item in the list first.", "Contextool", "Icon!")
        return
    }
    it := Items[kind][row]
    if (kind = "S")
        r := AskName("New description for the symbol " it.val " (empty = none):", it.label)
    else
        r := AskName("New name (empty = use the default name):", (it.label != "") ? it.label : DefaultName(kind, it))
    if (!IsObject(r))
        return
    it.label := r.name
    SaveConfig()
    RefreshList(kind, lv, row)
}

RemoveEntry(kind, lv) {
    row := lv.GetNext()
    if (!row) {
        MsgBox("Click an item in the list first.", "Contextool", "Icon!")
        return
    }
    Items[kind].RemoveAt(row)
    SaveConfig()
    RefreshList(kind, lv, Min(row, Items[kind].Length))
}

MoveEntry(kind, lv, dir) {
    row := lv.GetNext()
    if (!row)
        return
    newRow := row + dir
    arr := Items[kind]
    if (newRow < 1 || newRow > arr.Length)
        return
    tmp := arr[row]
    arr[row] := arr[newRow]
    arr[newRow] := tmp
    SaveConfig()
    RefreshList(kind, lv, newRow)
}

BrowseEntry(kind, edit) {
    if (kind = "A")
        p := FileSelect(1, , "Choose an application or a file")
    else
        p := DirSelect(, 3, "Choose a folder")
    if (p != "")
        edit.Value := p
}

; ---------------- tab: tools ----------------

BuildToolsTab(g) {
    lv := g.Add("ListView", "x25 y45 w610 h200 -Multi Checked", ["Tool", "What it does"])
    lv.ModifyCol(1, 210)
    lv.ModifyCol(2, 380)
    DarkHeader(g, lv)
    g.Add("Button", "x25 y255 w90", "Move up").OnEvent("Click", (*) => MoveTool(lv, -1))
    g.Add("Button", "x120 y255 w90", "Move down").OnEvent("Click", (*) => MoveTool(lv, 1))
    g.Add("Button", "x215 y255 w90", "Rename").OnEvent("Click", (*) => RenameTool(lv))
    lv.OnEvent("DoubleClick", (ctrl, row) => RenameTool(ctrl))
    g.Add("Text", "x25 y300 w610", "Tick a tool to show it in the menu, untick it to hide it.`nUse Move up / Move down to change the order of the tools in the menu,`nand Rename (or double-click a tool) to change its name.")
    lv.OnEvent("ItemCheck", ToolChecked)
    RefreshTools(lv)
}

RefreshTools(lv, selectRow := 0) {
    global toolsRefreshing
    toolsRefreshing := true
    lv.Delete()
    for tp in ToolPrefs {
        td := ToolDefs[tp.id]
        lv.Add(tp.on ? "Check" : "", ToolTitle(tp), td.desc)
    }
    toolsRefreshing := false
    if (selectRow > 0)
        lv.Modify(selectRow, "Select Focus Vis")
}

ToolChecked(lv, item, checked) {
    if (toolsRefreshing)
        return
    ToolPrefs[item].on := checked ? true : false
    SaveConfig()
}

RenameTool(lv) {
    row := lv.GetNext()
    if (!row)
        return
    tp := ToolPrefs[row]
    r := AskName("New name for this tool (empty = back to '" ToolDefs[tp.id].title "'):", ToolTitle(tp))
    if (!IsObject(r))
        return
    tp.name := r.name
    SaveConfig()
    RefreshTools(lv, row)
}

MoveTool(lv, dir) {
    row := lv.GetNext()
    if (!row)
        return
    newRow := row + dir
    if (newRow < 1 || newRow > ToolPrefs.Length)
        return
    tmp := ToolPrefs[row]
    ToolPrefs[row] := ToolPrefs[newRow]
    ToolPrefs[newRow] := tmp
    SaveConfig()
    RefreshTools(lv, newRow)
}

; ============================== tool: screen recording (native Windows) ==============================
; Opens the screen recorder built into Windows (Snipping Tool, shortcut Win+Shift+R):
; choose the area, press Start, and the video is saved by Windows (Videos > Captures).

RecTool(*) {
    Sleep(250)                       ; let the menu close first
    Send("#+r")
}


; Types a text at the cursor of a window by pasting it (works the same in Notepad, Word, browsers...)
PasteText(text, target := 0) {
    if (target && WinExist("ahk_id " target)) {
        WinActivate("ahk_id " target)
        WinWaitActive("ahk_id " target, , 1)
        Sleep(120)
    }
    saved := ClipboardAll()
    A_Clipboard := ""
    A_Clipboard := text
    if ClipWait(2) {
        ReleaseMods()
        Sleep(50)
        Send("+{Insert}")          ; same as Ctrl+V, but does not depend on the keyboard layout
        Sleep(800)
    }
    A_Clipboard := saved
}


; ============================== tool: speech to text (Groq Whisper) ==============================
; Records with the Windows microphone (built-in, nothing to install), sends the sound to
; Groq (Whisper) and pastes the text where your cursor was.

Mci(cmd) => DllCall("winmm\mciSendStringW", "wstr", cmd, "ptr", 0, "uint", 0, "ptr", 0, "uint")

SttTool(*) {
    global toolBusy
    if (toolBusy)
        return
    if (Trim(ApiKeys["groq"]) = "") {
        if (MsgBox("This tool needs your free Groq API key.`n`nOpen the Settings now and paste it in the tab 'APIs'?", "Contextool", "YesNo Icon?") = "Yes")
            ShowSettings()
        return
    }
    toolBusy := true
    target := prevWin
    wav := A_Temp "\ctxmenu_stt.wav"
    out := A_Temp "\ctxmenu_stt.txt"
    try FileDelete(wav)
    try FileDelete(out)
    recording := false
    try {
        Mci("close ctxrec")
        if (Mci("open new type waveaudio alias ctxrec") != 0) {
            MsgBox("Could not open the microphone.`nCheck that a microphone is connected and allowed in Windows privacy settings.", "Contextool", "Iconx")
            return
        }
        Mci("set ctxrec time format ms bitspersample 16 channels 1 samplespersec 16000 alignment 2 bytespersec 32000")
        if (Mci("record ctxrec") != 0) {
            MsgBox("Could not start the recording.`nCheck your microphone.", "Contextool", "Iconx")
            return
        }
        recording := true

        g := Gui("+AlwaysOnTop +ToolWindow", "Contextool - Speech to text")
        g.SetFont("s10", "Segoe UI")
        txt := g.Add("Text", "w230", "Recording...  0:00")
        state := {r: ""}
        g.Add("Button", "w100 Default", "Stop").OnEvent("Click", (*) => state.r := "stop")
        g.Add("Button", "x+10 w100", "Cancel").OnEvent("Click", (*) => state.r := "cancel")
        g.OnEvent("Close", (*) => state.r := "cancel")
        g.OnEvent("Escape", (*) => state.r := "cancel")
        ThemeGui(g)
        g.Show("AutoSize")
        t0 := A_TickCount
        while (state.r = "") {
            sec := (A_TickCount - t0) // 1000
            txt.Text := "Recording...  " Format("{}:{:02}", sec // 60, Mod(sec, 60))
            if (sec >= 600)
                state.r := "stop"
            Sleep(100)
        }
        g.Destroy()
        Mci("stop ctxrec")
        if (state.r = "stop")
            Mci('save ctxrec "' wav '"')
        Mci("close ctxrec")
        recording := false
        if (state.r != "stop" || !FileExist(wav))
            return

        ToolTip("Transcribing...")
        RunPs("stt", PsSttScript(), '-Wav "' wav '" -Out "' out '" -Key "' Trim(ApiKeys["groq"]) '"', 120000)
        ToolTip()
        text := ""
        if FileExist(out)
            text := Trim(FileRead(out, "UTF-8"), " `t`r`n")
        if (text = "") {
            MsgBox("The speech service did not answer. Please try again.", "Contextool", "Iconx")
        } else if (SubStr(text, 1, 6) = "ERROR:") {
            code := Trim(SubStr(text, 7))
            hint := ""
            if (RegExMatch(code, "^(401|403)"))
                hint := "`n`nYour API key may be wrong. Check your key in Settings > APIs."
            else if (RegExMatch(code, "^429"))
                hint := "`n`nThe free limit of Groq is reached. Try again in a moment."
            MsgBox("The speech service returned an error:`n" code hint, "Contextool", "Iconx")
        } else if (text = "EMPTY") {
            MsgBox("No speech was heard. Try again, closer to the microphone.", "Contextool", "Icon!")
        } else {
            PasteText(text, target)
        }
    } finally {
        if (recording) {
            Mci("stop ctxrec")
            Mci("close ctxrec")
        }
        ToolTip()
        try FileDelete(wav)
        toolBusy := false
    }
}

PsSttScript() {
    s := "
    (
param([string]$Wav, [string]$Out, [string]$Key)
$ErrorActionPreference = 'Stop'
function Save($t) { [System.IO.File]::WriteAllText($Out, $t, (New-Object System.Text.UTF8Encoding($false))) }
try {
  $hdr = Join-Path $env:TEMP 'ctxmenu_stt_h.txt'
  $body = Join-Path $env:TEMP 'ctxmenu_stt_b.txt'
  [System.IO.File]::WriteAllText($hdr, ('Authorization: Bearer ' + $Key), (New-Object System.Text.UTF8Encoding($false)))
  $code = & curl.exe -s -S -o $body -w '%{http_code}' -H ('@' + $hdr) -F ('file=@' + $Wav) -F 'model=whisper-large-v3-turbo' -F 'response_format=text' 'https://api.groq.com/openai/v1/audio/transcriptions'
  Remove-Item $hdr -Force -ErrorAction SilentlyContinue
  $txt = ''
  if (Test-Path $body) { $txt = [System.IO.File]::ReadAllText($body, [System.Text.Encoding]::UTF8); Remove-Item $body -Force -ErrorAction SilentlyContinue }
  if ([string]$code -eq '200') {
    if ($txt.Trim().Length -eq 0) { Save 'EMPTY' } else { Save $txt }
  } else {
    $short = $txt.Substring(0, [Math]::Min(200, $txt.Length))
    Save ('ERROR:' + $code + ' ' + $short)
  }
} catch { Save ('ERROR:' + $_.Exception.Message) }
    )"
    return s
}


; ---------------- tab: snippets ----------------

BuildSnippetsTab(g) {
    lv := g.Add("ListView", "x25 y45 w610 h200 -Multi", ["Trigger", "Text"])
    lv.ModifyCol(1, 140)
    lv.ModifyCol(2, 450)
    DarkHeader(g, lv)
    g.Add("Button", "x25 y255 w90", "Add").OnEvent("Click", (*) => SnippetEditor(0, lv))
    g.Add("Button", "x120 y255 w90", "Edit").OnEvent("Click", (*) => EditSnippet(lv))
    g.Add("Button", "x215 y255 w90", "Remove").OnEvent("Click", (*) => RemoveSnippet(lv))
    lv.OnEvent("DoubleClick", (ctrl, row) => EditSnippet(ctrl))
    g.Add("Text", "x25 y295 w610", "Type the trigger (for example `;hello) in any app, then press Space, Tab or Enter.`nThe text can be formatted. Use {{name}} to be asked for a value.")
    RefreshSnippets(lv)
}

RefreshSnippets(lv, selectRow := 0) {
    lv.Delete()
    for sn in Snippets
        lv.Add(, sn.trigger, StrReplace(StrReplace(SubStr(sn.text, 1, 200), "`r", ""), "`n", " | "))
    if (selectRow > 0)
        lv.Modify(selectRow, "Select Focus Vis")
}

EditSnippet(lv) {
    row := lv.GetNext()
    if (!row) {
        MsgBox("Click a snippet in the list first.", "Contextool", "Icon!")
        return
    }
    SnippetEditor(row, lv)
}

RemoveSnippet(lv) {
    row := lv.GetNext()
    if (!row) {
        MsgBox("Click a snippet in the list first.", "Contextool", "Icon!")
        return
    }
    if (MsgBox("Remove the snippet " Snippets[row].trigger " ?", "Contextool", "YesNo Icon?") != "Yes")
        return
    Snippets.RemoveAt(row)
    SaveConfig()
    RefreshSnippets(lv, Min(row, Snippets.Length))
}

; Window to create (index 0) or edit a snippet (plain text with line breaks and {{variables}})
SnippetEditor(index, lv) {
    old := index ? Snippets[index] : {trigger: "", text: "", rtf: ""}
    g := Gui("+AlwaysOnTop", index ? "Contextool - Edit snippet" : "Contextool - New snippet")
    try g.Opt("+Owner" settingsGui.Hwnd)
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "w560", "Trigger (start with a symbol such as `; or //, no spaces). Example:  `;hello")
    et := g.Add("Edit", "w200", old.trigger)
    g.Add("Text", "w560", "Text to insert. Use {{variable}} for the parts to fill in:")
    ed := g.Add("Edit", "xs w560 h200 Multi WantReturn VScroll", StrReplace(StrReplace(old.text, "`r`n", "`n"), "`n", "`r`n"))
    g.Add("Button", "xs w150", "Insert a variable...").OnEvent("Click", (*) => InsertVariable(ed))
    g.Add("Button", "x+160 w100 Default", "Save").OnEvent("Click", (*) => SaveSnippet(g, index, et, ed, lv))
    g.Add("Button", "x+10 w90", "Cancel").OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    ThemeGui(g)
    g.Show()
}

; ---------------- formatted text (RichEdit) helpers ----------------

LoadRichEdit() {
    static h := 0
    if (!h)
        h := DllCall("LoadLibrary", "str", "Msftedit.dll", "ptr")
}

; Applies a character format to the selection (or to the next typed text)
RichFmt(ed, mask, effects, size := 0, color := 0) {
    cf := Buffer(92, 0)
    NumPut("uint", 92, cf, 0)
    NumPut("uint", mask, cf, 4)
    NumPut("uint", effects, cf, 8)
    NumPut("int", size, cf, 12)
    NumPut("uint", color, cf, 20)
    SendMessage(0x444, 1, cf, ed)          ; EM_SETCHARFORMAT, selection
}

; Default look of the text: Calibri 11, black (scope 4 = all the text)
RichFont(ed, scope) {
    cf := Buffer(92, 0)
    NumPut("uint", 92, cf, 0)
    NumPut("uint", 0x20000000 | 0x80000000 | 0x40000000, cf, 4)     ; face + size + color
    NumPut("int", 220, cf, 12)
    NumPut("uint", 0, cf, 20)
    StrPut("Calibri", cf.Ptr + 26, 32, "UTF-16")
    SendMessage(0x444, scope, cf, ed)
}

RichToggle(ed, bit) {
    cf := Buffer(92, 0)
    NumPut("uint", 92, cf, 0)
    SendMessage(0x43A, 1, cf, ed)          ; EM_GETCHARFORMAT, selection
    isOn := (NumGet(cf, 4, "uint") & bit) && (NumGet(cf, 8, "uint") & bit)
    RichFmt(ed, bit, isOn ? 0 : bit)
    ed.Focus()
}

; Formatted text of the box, as RTF.
; Read through the clipboard (the box copies itself as RTF), then the clipboard is put back.
; No Windows callback is used any more: that part closed the app on some PCs.
RtfOut(ed) {
    rtf := ""
    saved := ClipboardAll()
    selS := 0
    selE := 0
    DllCall("SendMessage", "ptr", ed.Hwnd, "uint", 0xB0, "uint*", &selS, "uint*", &selE, "ptr")   ; EM_GETSEL
    try {
        A_Clipboard := ""
        DllCall("SendMessage", "ptr", ed.Hwnd, "uint", 0xB1, "ptr", 0, "ptr", -1, "ptr")      ; select all
        DllCall("SendMessage", "ptr", ed.Hwnd, "uint", 0x301, "ptr", 0, "ptr", 0, "ptr")      ; WM_COPY
        fmt := DllCall("RegisterClipboardFormatW", "wstr", "Rich Text Format", "uint")
        opened := false
        Loop 20 {
            if DllCall("OpenClipboard", "ptr", 0) {
                opened := true
                break
            }
            Sleep(20)
        }
        if (opened) {
            h := DllCall("GetClipboardData", "uint", fmt, "ptr")
            if (h) {
                pt := DllCall("GlobalLock", "ptr", h, "ptr")
                if (pt) {
                    rtf := StrGet(pt, DllCall("GlobalSize", "ptr", h, "uptr"), "cp0")
                    DllCall("GlobalUnlock", "ptr", h)
                }
            }
            DllCall("CloseClipboard")
        }
    }
    DllCall("SendMessage", "ptr", ed.Hwnd, "uint", 0xB1, "ptr", selS, "ptr", selE, "ptr")     ; selection back
    A_Clipboard := saved
    p := InStr(rtf, Chr(0))
    if (p)
        rtf := SubStr(rtf, 1, p - 1)
    return (SubStr(rtf, 1, 5) = "{\rtf") ? rtf : ""
}

; Loads RTF into the box (EM_SETTEXTEX reads RTF directly, no callback needed)
RtfIn(ed, rtf) {
    buf := Buffer(StrPut(rtf, "cp0"), 0)
    StrPut(rtf, buf, "cp0")
    st := Buffer(8, 0)                      ; SETTEXTEX: flags = ST_DEFAULT, codepage = CP_ACP
    DllCall("SendMessage", "ptr", ed.Hwnd, "uint", 0x461, "ptr", st.Ptr, "ptr", buf.Ptr, "ptr")
}

; Text -> RTF text (for the values typed in the variable form)
RtfEsc(v) {
    out := ""
    v := StrReplace(v, "`r`n", "`n")
    loop parse v {
        c := A_LoopField
        o := Ord(c)
        if (c = "\")
            out .= "\\"
        else if (c = "{")
            out .= "\{"
        else if (c = "}")
            out .= "\}"
        else if (c = "`n")
            out .= "\par "
        else if (c = "`t")
            out .= "\tab "
        else if (o > 126) {
            if (o > 0xFFFF) {
                o -= 0x10000
                out .= "\u" ((0xD800 | (o >> 10)) - 65536) "?\u" ((0xDC00 | (o & 0x3FF)) - 65536) "?"
            } else
                out .= "\u" (o > 32767 ? o - 65536 : o) "?"
        } else
            out .= c
    }
    return out
}

; RTF text -> normal text (\'e9, \u233?)
RtfDecode(t) {
    out := ""
    pos := 1
    while (RegExMatch(t, "\\'([0-9a-fA-F]{2})|\\u(-?\d+)\??", &m, pos)) {
        out .= SubStr(t, pos, m.Pos - pos)
        if (m[1] != "") {
            b := Buffer(1)
            NumPut("uchar", Integer("0x" m[1]), b)
            out .= StrGet(b, 1, "cp1252")
        } else {
            n := Integer(m[2])
            out .= Chr(n < 0 ? n + 65536 : n)
        }
        pos := m.Pos + m.Len
    }
    return out SubStr(t, pos)
}

; Converts RTF to {html, text} (the clipboard gets RTF + HTML + plain text so every app finds what it likes)
RtfConvert(rtf) {
    colors := [""]
    if (RegExMatch(rtf, "s)\{\\colortbl(.*?)\}", &mc)) {
        pos := 1
        while (RegExMatch(mc[1], "\\red(\d+)\\green(\d+)\\blue(\d+);", &c, pos)) {
            colors.Push(Format("#{:02X}{:02X}{:02X}", Integer(c[1]), Integer(c[2]), Integer(c[3])))
            pos := c.Pos + c.Len
        }
    }
    html := ""
    plain := ""
    buf := ""
    stack := []
    stt := {b: 0, i: 0, u: 0, fs: 0, cf: 0, skip: 0, uc: 1}
    Flush() {
        if (buf = "")
            return
        plain .= buf
        if (!stt.skip) {
            sty := ""
            if (stt.b)
                sty .= "font-weight:bold;"
            if (stt.i)
                sty .= "font-style:italic;"
            if (stt.u)
                sty .= "text-decoration:underline;"
            if (stt.fs)
                sty .= "font-size:" (stt.fs / 2) "pt;"
            if (stt.cf && colors.Has(stt.cf + 1) && colors[stt.cf + 1] != "")
                sty .= "color:" colors[stt.cf + 1] ";"
            h := StrReplace(StrReplace(StrReplace(buf, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")
            html .= (sty != "") ? "<span style=`"" sty "`">" h "</span>" : h
        }
        buf := ""
    }
    Cur() => {b: stt.b, i: stt.i, u: stt.u, fs: stt.fs, cf: stt.cf, skip: stt.skip, uc: stt.uc}
    i := 1
    n := StrLen(rtf)
    while (i <= n) {
        ch := SubStr(rtf, i, 1)
        if (ch = "{") {
            Flush()
            stack.Push(stt)
            stt := Cur()
            i++
        } else if (ch = "}") {
            Flush()
            if (stack.Length)
                stt := stack.Pop()
            i++
        } else if (ch = "\") {
            nx := SubStr(rtf, i + 1, 1)
            if (nx = "\" || nx = "{" || nx = "}") {
                if (!stt.skip)
                    buf .= nx
                i += 2
            } else if (nx = "'") {
                if (!stt.skip) {
                    bb := Buffer(1)
                    NumPut("uchar", Integer("0x" SubStr(rtf, i + 2, 2)), bb)
                    buf .= StrGet(bb, 1, "cp1252")
                }
                i += 4
            } else if (nx = "*") {
                Flush()
                stt.skip := 1
                i += 2
            } else if (nx = "~") {
                if (!stt.skip)
                    buf .= Chr(160)
                i += 2
            } else if (RegExMatch(rtf, "A)\\([a-zA-Z]+)(-?\d+)? ?", &w, i)) {
                wd := w[1]
                par := (w[2] = "") ? "" : Integer(w[2])
                i += w.Len
                if (wd = "u") {
                    if (!stt.skip)
                        buf .= Chr(par < 0 ? par + 65536 : par)
                    Loop stt.uc {
                        if (SubStr(rtf, i, 2) = "\'")
                            i += 4
                        else
                            i += 1
                    }
                } else if (wd = "par" || wd = "line") {
                    Flush()
                    if (!stt.skip) {
                        html .= "<br>"
                        plain .= "`r`n"
                    }
                } else if (wd = "tab") {
                    if (!stt.skip)
                        buf .= "`t"
                } else if (wd = "fonttbl" || wd = "colortbl" || wd = "stylesheet" || wd = "info" || wd = "pict" || wd = "header" || wd = "footer") {
                    Flush()
                    stt.skip := 1
                } else if (wd = "b" || wd = "i" || wd = "ul" || wd = "fs" || wd = "cf" || wd = "ulnone" || wd = "plain" || wd = "uc") {
                    Flush()
                    if (wd = "b")
                        stt.b := (par = "" || par != 0)
                    else if (wd = "i")
                        stt.i := (par = "" || par != 0)
                    else if (wd = "ul")
                        stt.u := (par = "" || par != 0)
                    else if (wd = "ulnone")
                        stt.u := 0
                    else if (wd = "fs")
                        stt.fs := par
                    else if (wd = "cf")
                        stt.cf := par
                    else if (wd = "uc")
                        stt.uc := par
                    else if (wd = "plain") {
                        stt.b := 0, stt.i := 0, stt.u := 0, stt.cf := 0
                    }
                }
            } else
                i += 2
        } else {
            if (ch != "`r" && ch != "`n" && !stt.skip)
                buf .= ch
            i++
        }
    }
    Flush()
    html := RegExReplace(html, "(<br>)+$")
    plain := RTrim(plain, "`r`n")
    return {html: "<div style=`"white-space:pre-wrap`">" html "</div>", text: plain}
}

; Puts RTF + HTML + text on the clipboard, pastes, then restores the old clipboard
PasteRich(rtf, html, text) {
    saved := ClipboardAll()
    A_Clipboard := ""
    opened := false
    Loop 15 {
        if (DllCall("OpenClipboard", "ptr", 0)) {
            opened := true
            break
        }
        Sleep(30)
    }
    if (opened) {
        DllCall("EmptyClipboard")
        SetClip(13, text, "UTF-16")
        SetClip(DllCall("RegisterClipboardFormatW", "wstr", "Rich Text Format", "uint"), rtf, "cp0")
        pre := "<html><body>`r`n<!--StartFragment-->"
        post := "<!--EndFragment-->`r`n</body></html>"
        u8 := (x) => StrPut(x, "UTF-8") - 1
        hdr := "Version:0.9`r`nStartHTML:{1:010d}`r`nEndHTML:{2:010d}`r`nStartFragment:{3:010d}`r`nEndFragment:{4:010d}`r`n"
        hl := u8(Format(hdr, 0, 0, 0, 0))
        sf := hl + u8(pre)
        ef := sf + u8(html)
        SetClip(DllCall("RegisterClipboardFormatW", "wstr", "HTML Format", "uint"), Format(hdr, hl, ef + u8(post), sf, ef) pre html post, "UTF-8")
        DllCall("CloseClipboard")
        ReleaseMods()
        Sleep(50)
        Send("+{Insert}")
        Sleep(900)
    }
    A_Clipboard := saved
}

SetClip(fmt, str, enc) {
    cnt := StrPut(str, enc)
    bytes := (enc = "UTF-16") ? cnt * 2 : cnt
    hMem := DllCall("GlobalAlloc", "uint", 0x42, "uptr", bytes, "ptr")
    p := DllCall("GlobalLock", "ptr", hMem, "ptr")
    StrPut(str, p, cnt, enc)
    DllCall("GlobalUnlock", "ptr", hMem)
    DllCall("SetClipboardData", "uint", fmt, "ptr", hMem, "ptr")
}

InsertVariable(ed) {
    ; remember where the cursor / selection is (the text box would select everything when it gets focus back)
    selS := 0
    selE := 0
    DllCall("SendMessage", "ptr", ed.Hwnd, "uint", 0xB0, "uint*", &selS, "uint*", &selE, "ptr")   ; EM_GETSEL
    r := AskVariable(ed.Gui)
    if (!r.ok)
        return
    name := Trim(RegExReplace(r.name, "[{}=\r\n\t]", ""))
    if (name = "")
        return
    txt := "{{" name "}}"
    ed.Focus()
    DllCall("SendMessage", "ptr", ed.Hwnd, "uint", 0xB1, "ptr", selS, "ptr", selE)   ; EM_SETSEL
    DllCall("SendMessage", "ptr", ed.Hwnd, "uint", 0xC2, "ptr", 1, "ptr", StrPtr(txt))   ; EM_REPLACESEL
}

; Small window (always on top, owned by the snippet editor) asking the variable name and default value
AskVariable(owner) {
    g := Gui("+AlwaysOnTop +Owner" owner.Hwnd, "Contextool - Variable")
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "w320", "Variable name (for example name, date):")
    en := g.Add("Edit", "w320")
    res := {ok: false, name: ""}
    hwnd := g.Hwnd
    Done(*) {
        res.name := en.Value
        res.ok := true
        g.Destroy()
    }
    g.Add("Button", "w100 Default", "OK").OnEvent("Click", Done)
    g.Add("Button", "x+10 w100", "Cancel").OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    ThemeGui(g)
    g.Show()
    WinWaitClose("ahk_id " hwnd)
    return res
}

SaveSnippet(g, index, et, ed, lv) {
    trig := Trim(et.Value)
    body := StrReplace(StrReplace(ControlGetText(ed), "`r`n", "`n"), "`r", "`n")
    rtf := ""                              ; formatting is no longer used: plain text only
    if (trig = "" || RegExMatch(trig, "\s") || StrLen(trig) < 2 || RegExMatch(SubStr(trig, 1, 1), "i)[a-z0-9]")) {
        MsgBox("The trigger must start with a symbol (like `; or //), have no spaces and be at least 2 characters.`nExample: `;hello", "Contextool", "Icon!")
        return
    }
    if (Trim(body, " `t`n") = "") {
        MsgBox("Type the text of the snippet first.", "Contextool", "Icon!")
        return
    }
    for i, sn in Snippets {
        if (i != index && StrLower(sn.trigger) = StrLower(trig)) {
            MsgBox("Another snippet already uses this trigger:`n" trig, "Contextool", "Icon!")
            return
        }
    }
    if (index)
        Snippets[index] := {trigger: trig, text: body, rtf: rtf}
    else
        Snippets.Push({trigger: trig, text: body, rtf: rtf})
    SaveConfig()
    RefreshSnippets(lv, index ? index : Snippets.Length)
    g.Destroy()
}

; ---------------- snippets: typing detection and expansion ----------------

snipHook := ""
snipBusy := false

StartSnippets() {
    global snipHook
    snipHook := InputHook("V I")
    snipHook.NotifyNonText := true
    snipHook.OnChar := SnipChar
    snipHook.OnKeyDown := SnipKey
    snipHook.KeyOpt("{Backspace}{Space}{Tab}{Enter}{Left}{Right}{Up}{Down}{Home}{End}{Delete}{Esc}{PgUp}{PgDn}", "N")
    snipHook.Start()
}

SnipChar(ih, ch) {
    global SnipBuf
    if (snipBusy || toolBusy || paused)
        return
    SnipBuf := SubStr(SnipBuf . ch, -79)
}

SnipKey(ih, vk, sc) {
    global SnipBuf
    if (snipBusy || toolBusy || paused)
        return
    name := GetKeyName(Format("vk{:X}sc{:X}", vk, sc))
    if (name = "Backspace") {
        SnipBuf := SubStr(SnipBuf, 1, -1)
        return
    }
    if (name = "Space" || name = "Tab") {      ; Enter is NOT an ender (it would send the message / start the search)
        best := ""
        for sn in Snippets {
            n := StrLen(sn.trigger)
            if (n <= StrLen(SnipBuf) && StrLower(SubStr(SnipBuf, -n)) = StrLower(sn.trigger)
                && (best = "" || n > StrLen(best.trigger)))
                best := sn
        }
        SnipBuf := ""
        if (IsObject(best))
            SetTimer(ExpandSnippet.Bind(best), -40)
        return
    }
    SnipBuf := ""        ; any other key (arrows, Esc...) starts a new word
}

ExpandSnippet(sn) {
    global snipBusy, SnipBuf
    snipBusy := true
    try {
        target := WinExist("A")
        ; list the variables ({{name}} or {{name=default}}), each name once, in order
        names := []
        defs := Map()
        pos := 1
        while (RegExMatch(sn.text, "\{\{([^{}=]+?)(?:=([^{}]*))?\}\}", &m, pos)) {
            pos := m.Pos + m.Len
            nm := Trim(m[1])
            if (!defs.Has(nm)) {
                names.Push(nm)
                defs[nm] := m[2]
            }
        }
        vals := Map()
        focusCtl := 0
        try focusCtl := ControlGetFocus("ahk_id " target)
        if (names.Length) {
            vals := AskSnippetVars(names, defs)
            if (!IsObject(vals))
                return
            if (target && WinExist("ahk_id " target)) {
                WinActivate("ahk_id " target)
                WinWaitActive("ahk_id " target, , 1)
                Sleep(250)
                if (focusCtl)
                    try ControlFocus(focusCtl, "ahk_id " target)
                Sleep(100)
            }
        }
        out := ""
        pos := 1
        text := sn.text
        while (RegExMatch(text, "\{\{([^{}=]+?)(?:=([^{}]*))?\}\}", &m, pos)) {
            out .= SubStr(text, pos, m.Pos - pos)
            nm := Trim(m[1])
            out .= vals.Has(nm) ? vals[nm] : ""
            pos := m.Pos + m.Len
        }
        out .= SubStr(text, pos)
        Sleep(60)
        Send("{Backspace " (StrLen(sn.trigger) + 1) "}")      ; remove the trigger and the key that ended it
        Sleep(40)
        PasteText(StrReplace(StrReplace(out, "`r`n", "`n"), "`n", "`r`n"))      ; paste (never types Enter keys)
    } finally {
        SnipBuf := ""
        snipBusy := false
    }
}

; Small form that asks the value of each variable. Returns a Map (name -> value) or false if cancelled
AskSnippetVars(names, defs) {
    g := Gui("+AlwaysOnTop", "Contextool - Snippet")
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "w380", "Fill in the values:")
    edits := Map()
    for nm in names {
        g.Add("Text", "w380", nm)
        edits[nm] := g.Add("Edit", "w380", defs[nm])
    }
    res := {ok: false, vals: Map()}
    Collect(*) {
        for nm, e in edits
            res.vals[nm] := e.Value
        res.ok := true
        g.Destroy()
    }
    g.Add("Button", "w100 Default", "OK").OnEvent("Click", Collect)
    g.Add("Button", "x+10 w100", "Cancel").OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    ThemeGui(g)
    g.Show()
    hwnd := g.Hwnd
    WinWaitClose("ahk_id " hwnd)
    return res.ok ? res.vals : false
}


; ---------------- tab: APIs ----------------

BuildApiTab(g) {
    global ApiEdits
    ApiEdits := []
    providers := [
        {id: "whatfontis", title: "WhatFontIs  -  tool 'Font from screen'"
            , help: "Create a free account on whatfontis.com, then copy your API key."
            , url: "https://whatfontis.com/API-identify-fonts-from-image.html"}
        , {id: "groq", title: "Groq  -  tool 'Speech to text'"
            , help: "Create a free account on console.groq.com, then create an API key."
            , url: "https://console.groq.com/keys"}
    ]
    y := 48
    for pv in providers {
        AddApiRow(g, y, pv)
        y += 150
    }
}

AddApiRow(g, y, pv) {
    g.SetFont("s10 bold")
    g.Add("Text", "x25 y" y " w530", pv.title)
    g.SetFont("s10 norm")
    g.Add("Text", "x25 y" (y + 28) " w400", pv.help)
    g.Add("Button", "x430 y" (y + 22) " w125", "Get a key").OnEvent("Click", (*) => Run(pv.url))
    ed := g.Add("Edit", "x25 y" (y + 62) " w330 Password", ApiKeys[pv.id])
    chk := g.Add("Checkbox", "x365 y" (y + 66) " w70", "Show")
    stat := g.Add("Text", "x25 y" (y + 108) " w500", (ApiKeys[pv.id] != "") ? "A key is saved (hidden, and encrypted on this computer)." : "No key saved yet.")
    chk.OnEvent("Click", (*) => ShowApiKey(ed, chk))
    ApiEdits.Push({ed: ed, chk: chk})
    g.Add("Button", "x440 y" (y + 60) " w115", "Save").OnEvent("Click", (*) => SaveApiKey(pv.id, ed, stat))
}

; Applies again the hidden / shown state of the key boxes (they must be hidden unless "Show" is ticked)
RemaskApiKeys() {
    for a in ApiEdits
        ShowApiKey(a.ed, a.chk)
}

; Show / hide the key (hidden = dots)
ShowApiKey(ed, chk) {
    DllCall("SendMessage", "ptr", ed.Hwnd, "uint", 0xCC, "ptr", chk.Value ? 0 : 0x25CF, "ptr", 0)   ; EM_SETPASSWORDCHAR
    DllCall("InvalidateRect", "ptr", ed.Hwnd, "ptr", 0, "int", 1)
}

SaveApiKey(id, ed, stat) {
    ApiKeys[id] := Trim(ed.Value, " `t`r`n" Chr(34))
    ed.Value := ApiKeys[id]
    SaveConfig()
    stat.Text := (ApiKeys[id] != "") ? "Saved (hidden, and encrypted on this computer)." : "Key removed."
}

; ---- keys are stored encrypted with your Windows account (they cannot be read on another account) ----

BytesToBase64(ptr, size) {
    len := 0
    DllCall("crypt32\CryptBinaryToStringW", "ptr", ptr, "uint", size, "uint", 0x40000001, "ptr", 0, "uint*", &len)
    out := Buffer(len * 2 + 2, 0)
    DllCall("crypt32\CryptBinaryToStringW", "ptr", ptr, "uint", size, "uint", 0x40000001, "ptr", out, "uint*", &len)
    return StrGet(out, len, "UTF-16")
}

ProtectText(s) {
    if (s = "")
        return ""
    try {
        n := StrPut(s, "UTF-8") - 1
        inb := Buffer(n + 1, 0)
        StrPut(s, inb, "UTF-8")
        din := Buffer(16, 0)
        NumPut("uint", n, din, 0)
        NumPut("ptr", inb.Ptr, din, A_PtrSize)
        dout := Buffer(16, 0)
        if (DllCall("crypt32\CryptProtectData", "ptr", din, "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "uint", 0, "ptr", dout)) {
            cb := NumGet(dout, 0, "uint")
            pb := NumGet(dout, A_PtrSize, "ptr")
            b64 := BytesToBase64(pb, cb)
            DllCall("LocalFree", "ptr", pb)
            return "dp:" b64
        }
    }
    return "plain:" s
}

UnprotectText(s) {
    if (SubStr(s, 1, 6) = "plain:")
        return SubStr(s, 7)
    if (SubStr(s, 1, 3) != "dp:")
        return Trim(s)                       ; an older, unencrypted key
    try {
        b64 := SubStr(s, 4)
        n := 0
        DllCall("crypt32\CryptStringToBinaryW", "str", b64, "uint", 0, "uint", 1, "ptr", 0, "uint*", &n, "ptr", 0, "ptr", 0)
        raw := Buffer(n, 0)
        DllCall("crypt32\CryptStringToBinaryW", "str", b64, "uint", 0, "uint", 1, "ptr", raw, "uint*", &n, "ptr", 0, "ptr", 0)
        din := Buffer(16, 0)
        NumPut("uint", n, din, 0)
        NumPut("ptr", raw.Ptr, din, A_PtrSize)
        dout := Buffer(16, 0)
        if (DllCall("crypt32\CryptUnprotectData", "ptr", din, "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "uint", 0, "ptr", dout)) {
            cb := NumGet(dout, 0, "uint")
            pb := NumGet(dout, A_PtrSize, "ptr")
            txt := StrGet(pb, cb, "UTF-8")
            DllCall("LocalFree", "ptr", pb)
            return txt
        }
    }
    return ""                                ; saved on another Windows account: type the key again
}

; ---------------- tab: backup / restore ----------------

BuildGeneralTab(g) {
    BuildShortcutTab(g)
    BuildBackupTab(g)
}

BuildBackupTab(g) {
    g.Add("Text", "x345 y50 w290", "Your settings and sticky notes are saved in:")
    g.Add("Edit", "x345 y90 w290 ReadOnly", SettingsDir)
    g.Add("Button", "x345 y130 w290", "Restore from a file...").OnEvent("Click", RestoreFromFile)
    g.Add("Button", "x345 y170 w290", "Back up now").OnEvent("Click", BackupNow)
    g.Add("Button", "x345 y210 w290", "Open the settings folder").OnEvent("Click", (*) => OpenSettingsFolder())
    g.Add("Button", "x345 y250 w290", "Reset to defaults").OnEvent("Click", ResetToDefaults)
    g.Add("Text", "x345 y295 w290", "Restore: pick a settings file (for example one from the Backups folder). Your current settings are backed up first. When you update the script, your settings are found again automatically.")
}

OpenSettingsFolder() {
    try DirCreate(SettingsDir)
    Run('explorer.exe "' SettingsDir '"')
}

BackupNow(*) {
    SaveConfig()
    d := BackupSettings()
    if (d != "")
        MsgBox("Backup saved in:`n" d, "Contextool", "Iconi")
    else
        MsgBox("The backup could not be saved.", "Contextool", "Iconx")
}

RestartScript() {
    global noSaveNotes
    noSaveNotes := true     ; do not overwrite the notes that were just restored
    Reload()
}

RestoreFromFile(*) {
    try DirCreate(SettingsDir)
    f := FileSelect(1, SettingsDir, "Choose a settings file to restore", "Settings (*.txt)")
    if (f = "")
        return
    text := ""
    try text := FileRead(f, "UTF-8")
    if (!RegExMatch(text, "m)^(H|S|A|F|P|T|N|L)\t")) {
        MsgBox("This file does not look like a settings file of this menu.", "Contextool", "Iconx")
        return
    }
    if (MsgBox("Restore the settings from:`n" f "`n`nYour current settings will be backed up first.", "Contextool", "YesNo Icon?") != "Yes")
        return
    SaveConfig()
    BackupSettings("before-restore")
    text := "V`t" AppVersion "`n" RegExReplace(text, "m)^V\t[^\r\n]*(\r?\n)?", "")
    try {
        out := FileOpen(ConfigFile, "w", "UTF-8-RAW")
        out.Write(StrReplace(text, "`r`n", "`n"))
        out.Close()
    } catch as e {
        MsgBox("Could not restore the settings:`n" e.Message, "Contextool", "Iconx")
        return
    }
    SplitPath(f, , &fdir)
    notes := fdir "\notes.txt"
    if (FileExist(notes) && notes != NotesFile) {
        if (MsgBox("Also restore the sticky notes saved next to this file?", "Contextool", "YesNo Icon?") = "Yes")
            try FileCopy(notes, NotesFile, 1)
    }
    MsgBox("Settings restored. The menu will restart now.", "Contextool", "Iconi")
    RestartScript()
}

ResetToDefaults(*) {
    if (MsgBox("Reset all settings to the default ones?`n`nYour current settings are backed up first (sticky notes are kept).", "Contextool", "YesNo Icon?") != "Yes")
        return
    SaveConfig()
    BackupSettings("before-reset")
    try FileDelete(ConfigFile)
    RestartScript()
}

; ---------------- tab: shortcut ----------------

BuildShortcutTab(g) {
    g.Add("Text", "x25 y45 w300", "Active shortcuts (any of them opens the menu):")
    lb := g.Add("ListBox", "x25 y72 w300 r4")
    RefreshShortcutList(lb)
    g.Add("Button", "x25 y150 w145", "Remove selected").OnEvent("Click", (*) => RemoveShortcut(lb))
    g.Add("Button", "x180 y150 w145", "Reset").OnEvent("Click", (*) => ResetShortcut(lb))

    g.Add("Text", "x25 y215 w300", "To add a shortcut: click Detect, then hold Ctrl (or Alt, Shift, Win) and click a mouse button, or press a key.")
    g.Add("Button", "x25 y275 w300", "Detect my shortcut").OnEvent("Click", (*) => DetectShortcut(lb))

    cb := g.Add("Checkbox", "x25 y353", "Start with Windows")
    cb.Value := FileExist(A_Startup "\Contextool.lnk") ? 1 : 0
    cb.OnEvent("Click", (ctrl, *) => ToggleStartup(ctrl.Value))

    g.Add("Text", "x25 y318 w90 h24 +0x200", "Menu icons:")
    styles := ["color", "white", "black"]
    dd := g.Add("DropDownList", "x115 y318 w210", ["Original colors", "White", "Black"])
    for i, st in styles {
        if (st = IconStyle)
            dd.Value := i
    }
    if (!dd.Value)
        dd.Value := 1
    dd.OnEvent("Change", (ctrl, *) => SetIconStyle(styles[ctrl.Value]))
}

SetIconStyle(st) {
    global IconStyle
    IconStyle := st
    SaveConfig()                           ; the menu uses it the next time it opens
}

RefreshShortcutList(lb) {
    lb.Delete()
    for hk in OpenHotkeys
        lb.Add([HotkeyText(hk)])
}

; Adds a shortcut (the others stay active)
AddShortcutText(newHk, lb) {
    if (!IsSafeHotkey(newHk)) {
        MsgBox("This shortcut is not allowed because it would block normal typing or clicking.`n`nUse Ctrl, Alt or Win together with a key or a mouse button (for example Ctrl+Right click), or a function key / extra mouse button alone.", "Contextool", "Icon!")
        return
    }
    SplitHotkey(newHk, &mods, &k)
    if (StrLen(k) = 1 && RegExMatch(k, "i)[a-z0-9]") && InStr(mods, "^") && !InStr(mods, "!") && !InStr(mods, "#")) {
        if (MsgBox(HotkeyText(newHk) " is used by many programs (copy, paste, save...).`n`nUse it anyway?", "Contextool", "YesNo Icon?") != "Yes")
            return
    }
    if (AddShortcut(newHk))
        RefreshShortcutList(lb)
}

RemoveShortcut(lb) {
    i := lb.Value
    if (!i) {
        MsgBox("Click a shortcut in the list first.", "Contextool", "Icon!")
        return
    }
    if (OpenHotkeys.Length <= 1) {
        MsgBox("Keep at least one shortcut. Add another one first.", "Contextool", "Icon!")
        return
    }
    DeactivateHotkey(OpenHotkeys[i])
    OpenHotkeys.RemoveAt(i)
    SaveConfig()
    RefreshShortcutList(lb)
}

; Waits for the user to hold modifier keys and click a mouse button (or press a key), and uses it as the shortcut
DetectShortcut(lb) {
    DeactivateAllHotkeys()                     ; so that the current shortcut does not open the menu meanwhile
    InstallMouseHook()                     ; needed to see the real state of the mouse buttons
    InstallKeybdHook()
    found := ""
    cancel := {v: false}
    g := Gui("+AlwaysOnTop +ToolWindow", "Contextool - Detect")
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "w320", "Hold Ctrl (or Alt, Shift, Win) and click with a mouse button, or press a key / key combination now...")
    g.Add("Button", "w100", "Cancel").OnEvent("Click", (*) => cancel.v := true)
    g.OnEvent("Close", (*) => cancel.v := true)
    g.OnEvent("Escape", (*) => cancel.v := true)
    ThemeGui(g)
    g.Show()
    t0 := A_TickCount
    Sleep(300)
    while (!cancel.v && A_TickCount - t0 < 30000 && found = "") {
        Loop 0xFE - 0x01 {
            vk := A_Index + 1                        ; 0x02..0xFE (0x01 = left click is ignored)
            if (vk = 0x10 || vk = 0x11 || vk = 0x12 || vk = 0x5B || vk = 0x5C || (vk >= 0xA0 && vk <= 0xA5) || vk = 0x1B)
                continue                             ; modifiers and Esc
            if (!GetKeyState(Format("vk{:02X}", vk), "P"))
                continue
            mods := (GetKeyState("Ctrl", "P") ? "^" : "") (GetKeyState("Shift", "P") ? "+" : "") (GetKeyState("Alt", "P") ? "!" : "") ((GetKeyState("LWin", "P") || GetKeyState("RWin", "P")) ? "#" : "")
            names := Map(0x02, "RButton", 0x04, "MButton", 0x05, "XButton1", 0x06, "XButton2")
            key := names.Has(vk) ? names[vk] : GetKeyName(Format("vk{:02X}", vk))
            if (key = "")
                continue
            found := mods key
            KeyWait(key, "T3")
            break
        }
        Sleep(15)
    }
    g.Destroy()
    if (!paused) {
        for h in OpenHotkeys                         ; put the shortcuts back
            ActivateHotkey(h)
    }
    if (found = "")
        return
    AddShortcutText(found, lb)
}

ResetShortcut(lb) {
    DeactivateAllHotkeys()
    OpenHotkeys.Length := 0
    OpenHotkeys.Push("^RButton")
    if (!paused)
        ActivateHotkey("^RButton", 5)
    SaveConfig()
    RefreshShortcutList(lb)
}

; Adds a shortcut to the active ones; returns true if it worked
AddShortcut(newHk) {
    for h in OpenHotkeys {
        if (h = newHk)
            return true                  ; already there
    }
    if (!paused && !ActivateHotkey(newHk)) {
        MsgBox("This shortcut cannot be used (another program may already use it):`n" HotkeyText(newHk), "Contextool", "Iconx")
        return false
    }
    OpenHotkeys.Push(newHk)
    SaveConfig()
    return true
}

; ---------------- start with Windows ----------------

ToggleStartup(on) {
    lnk := A_Startup "\Contextool.lnk"
    try {
        if (on)
            FileCreateShortcut(A_ScriptFullPath, lnk, A_ScriptDir)
        else if FileExist(lnk)
            FileDelete(lnk)
    } catch as e {
        MsgBox("Could not change the startup setting:`n" e.Message, "Contextool", "Iconx")
    }
}


; ============================ menu icons (PNG data) ============================

IconData["folder_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAA9ElEQVR42qXTQS4EQRQG4K9LCZGwwsbCnsTSRiysHMIRrCTOIJG4waxtnINwADfAUiwxY6ZtXiVt0t0z+JOXdPX/v7/qvXoFlW70cT8EazjBeqzfMMAnMuqWvHH5v4LbWDTjHluzTpCxj4NwLM6L2MY7znCEUfAVnnCJFzgOcoQhvvCIVZy3nKzEA5YqLGOzUWfGK05xEYbNfhVdwm7GHq6CqDDBBnbiO0+VXXRDpBziw5b+TGKX3hvMUfu44VzIZA7kEC9MGcyN5J9IsWv9h9waVY5hqRrXNU9iivI/yijf9QxMV9wgdT2mWXjGdczC7zvfxDeZCUZ2rWcIKAAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABKElEQVR42tXUMU4DQQwF0LfLEtLR0AUkKDgDN+AuoDScgRKJhktQUlBTJog7IBqgoIIKFJIsBR5ptGQhidJgyZrV7PiP/b89fFsRPstKC1gTZBed+K5xj2mcq7P1T9AebjCKgCkmuMNOnKt+iV9rJncVQJNYE2iNJ2y3VPTDKmziILIrAkisHQzxjD6OYr/MKPjANU4jIVsYZ5nlfhngxy3/cz9LJXRwiG5GeIn3uLmPi3T7jLKTaC/Yr2LjEesZYCL6HCdZmUWLKEXQ100c3mKjhed6gV6sE7mvWatMM5/Mo2xT5cRZrtzSVlqx/Q/AYoV4RRVTYhlFs7ZK4zou8YZBNHLeqPO6iB0E1sznaxEfRWwPRbPEvRjBeZ6qNKafeGibx6XFSPFfYddf/OY+o0wAAAAASUVORK5CYII=",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAABX0lEQVR42u3WsUokQRAG4G9cucRcTZYTVBBj38HQxAfwAQQvVcTAe4FLjQxNfADBNzAQAyM5Do6LDgNPL/Gcddak5myH2WF2VwPBhp+B6pr/r66u7urM85gIFF6O0la1DzWyFj4ToxJn6GMeX7BUIfuBffxKVtMUUL9OZAnXMVmH71gM38kWgXeqhqMgukevgvuYu8JU+M9gtgbTg1J6gQf8Qx7oha0IkfXw3cYt/uAOf+N7hxucYbUq8rMhPTnWwm+nwS9FDyuSfB6jG9GWquVmHuIEu/gaP3ca8p/jEzax0bba9pLIihbRFzhNV3CAOTzW1HsXy8nqspbl308FVvG54Ydi1INWCtxG9HVE2ajkqUAnMBbZq90vHwLvU6Bfd4+PMcrT/l/gMko0j/MwDvLgPR+m4QyLq+gZWdoyF7CVtMxsyLSUF905vuF3yvEWm51VXxODni2jPCIey01+AjDOkQPB0UdeAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAABz0lEQVR42u3Xv4rUUBQG8F8yUVHwCUQEQRAU7dRGLWwsLazVTgUrfQSxEbH0JWx9AwvBQsF+EHStZEVRYdf5E5uT5ZrNJJNhZt1iLhxyyc255zvfl5Nzk2ke2Yz7pRWPHIOW9axjvffIasGnMT+CQw3Zf4/5AJNlZw7n8RKfsIlvYZv4ije4Fs8WywpeUXoFvyLTNhvhRg34IAB1WT5LhsMYRoDtkKLJxnH9gzvhWyyY8A6NJS7hZOh6sMN5hAM4FwDGuI4TAW5WBf3AW3yMZ/6pqFvhPGqhPl1/mvjenUO2yn7jSSJfNi+AabBT4lkS/F7cG4csoxar5CvxuC7H7TkzmBV8Oqf/JAF7PC2lV7jYoeE2PsT8Pl7EhnmLT1O5T+IduoDPfUu2wKMFMq+X8TRY32HgKh4kGc1CfxpnYqM+mTeVfpkCOIWbczpPW0BahNJK33FY0aFhvsweUCSUFMv+xvdpQv9trAGsAawB7BsA5V6c+Wsn7DIFMIyvYbYHwas4w5SFAu8D1VZ0xVXYVsR4l56SKxbOYmOB/t7XNiIW5FmtPx/DQ1zG0Y7/xD56w0+8xnN8aToZ5/uh+qq2nK3o5du1dzbnj+uySm/X+AuwYdu/fEPGyQAAAABJRU5ErkJggg==")
IconData["folder_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABBElEQVR42qXTvUoDQRQF4G/WCYqFldrapFKwDIiIWNrb5QEsrHwJQfQNrC1tfQQJWFtbaEqx8z9ZmxtYlyS74IFhhnvPPXN/ZlI56CaUpmOeD+QgrKCP1bC/4gqfFU5deIQyYxm32K2R+jjCsCmDXgSPKsodbOAdpzjAd/gTnnCOYcYifkJwjAIP2MExLmZc3sN+KgfdJaxX6sx4wQnOKuIp9gmvwFbGNi7DkSKLNWzGOddunvC+UOQg701JcVKOOSOWozmjivLEOS/4zxQSFmoCrVH4J4o2z3UGSqQcjyVVxtUmsIjyPwrc4y4MbVYnenaDx4w3HNY+UxOecY1xavjOjfgF3oY8YgNqCqkAAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABTklEQVR42tXUsW4TQRAG4G8vF2PRUKUKSCA5L4CEqGl4hrwCiRuKPAE9DeIh6FMnneNHACTkJkpBFVdEweejyKy0MVx0ttzwS6vTzu38M/PPzqZ2OoLkDq2/UWGpJ+oVoucYFLYfQZZinzqC3ouesI8zfMc3fI01xbMgqTvIEnZylVUc+ow38SMfSngVpE+xKKQp0aLJwWo8wWvchkPWaxnlX+AKY7wLe1VIcINTfEBTYxd7RXYlvuAQR/j0gHQv8RgnqZ2OBniLYaFRhV8ReRxkTSFHidy0nziow3AZmbYrQn/E+6LM1NGUFPINs4ZTPOoopw2yPmizuNeRRRPfZbFP1kBdaFZ2bmNUtoz/gzBtkS/VMaM26WhxrfK4LirMMfnHw9B3Cd8J5rnkY5wX47UOmvA9RkrxYme8iBHUo/w8pr8xW73Y2Xm2aTNykD+DYFMzh0o/ZgAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAABiUlEQVR42u3WPWsVQRTG8d/sRntBsAhBwYAvnYUQC2vxE9j6AQQDNiq+YIK9bap8gTQWgtY2KSSVhRC1sTKdhYXce3dtzoRxufdu9l4LCx8Yll12nv+cMzNnJrX760JVtMafyt+630+klXimOSZNBzQYkNDiIjZxOcyyvmIL3wpImuPZli+p3V9PuIT3ODuj0xfcxmfUGPcMvMYkR9DieZj/KtKWNY7o3uAafuLcjCgaHIV5hSabXcGoSFc5L6cD/DjMH+Fh/Fd1+kxwiKd4hyoDzuDUjFDHuIPXAXnZk57rEe0GPmTAHtZixFURbsIu3uIJtgNYzwGMIup7uJsBD3pG9QwvIgV1zyqqI2Wr5T7YwYVickqt4WoRXTrB8j+elwy4hfNzOjRTwIN28o8Y/TSjtKh5CaiL3C5sNk1/1ew/4N8GtN06vqSa7JcBH2OJjmI/LNNG4Xsw5MAZqkPcxFHeaJ9wA/eLIzMNNG2j0h7gFb4jpbhVVIveGvoK3kqnmC0LStEmeZJ/Az7Ebj56zbrpAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACB0lEQVR42u2XPWsUURSGn3tnNMSPLq0IEkEQtEvSaNr8gFga7GJAEEQU/PgFyUoqtbNPlSKENKnShDSKpHSxCJaBiBBY3Z2xea+cHWdmJ8tMkmIPHJi9X+97zrnn7jku3Z0kRxz5klKzxJnfXuC9gvVOa3pNEPBAou9LwFiO9UcCj+oiEWfA7wJvgGngsglFqvlvmt/W3m4dBII194FNARfJBLAFPADWDfGo5N5YSYyX+ywfBz4J/LcsztPg/jXgkcZijXcraCDb54EUmAFu6KCLJRZEwB/gAnBHVneBOeC6AIo88RPYA75rTWrvwDVjJSUp2BP4MvBC44vAx4ohPwZWgdfyfhpX3Jgad7cM+GPgg4glA+6BU6hfae1bIPJm0uW8C9n8bwHPc8C9PBOXaGS8+FJe7wXADaVemRUd4Ku+l4D3BtxV9KQ3YZwCDgKBQ2mVtH0KrAwBng3nFXsJZ4En5tAi9reA2zpgGHAb0r4suAnMV9yclJAc+inumMciHhDD2sAtAZsBMaconjOWEYERgRGBc0NgUDFSt/zDCwTapiZoWgJO277te8AXFQ0dU73WrR1hfBamDx7oAg+BH2pIfEM6JoyF0FPEpgraV1X0DLgHXB3QJ54k3gC/gB3gnUg4IHGmOfXZpqHhy59k0zAxf8uuocsXzk6KuuPU9HuugdT7r5f8C2BHnYCmKLwnAAAAAElFTkSuQmCC")
IconData["folder_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABAElEQVR42qXTsS6EQRTF8d98PiESKjQKPYlSIwqVh/AIKolnkEi8gVrjOQgP4A1QihK7OJrZ5LPW7op/cpPJ3DNncufeKUkKYjTjcqCtgiUcYLnuP+Mcbx3NsPEHIslCkqv85CbJWhLjosU2dqrjwHkW63jBEfbQr/mCe5ziUZL9JP0avSTvSe6SLCY5zu/cJpkrSeax2qmzxRMOcYL3Tt06ugabLbZwVhMFn1jBRl23Qw840PXQtFW8O6JDn/UWY1qsrY/z0XEeJMcd/jYHBTNDBlPT+CfNNOP6C0Fp67CUTrumOdjU8l8Ho3ydv3OZpClJjPhMk3jABXplwneeyBd2POXbIflN4gAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABP0lEQVR42tWVMU7DQBBF3zompKOhC0hQcAZuwF1AaTgDJRINl6CkoKYExB0QDVBQkQoUYj8KxmQVEnAiGp40Gu1Y89czs14nFSDxiXynAGpaUk4JbQHdLHYXYinWac6mE9Sk9tVLdeQntVqpt+qmilqGn7akdsLTBM9DqHJCHf5R3ciS+clKYA3YBUZRUtOvOsq/Bp6AAbAf8SJrwRtwARwBFeq6OnY2Z7Hzgb9zrJLULrAH9LKGF8Br7DwAToEqnqWpMTRDewZ2ygg8ACuZYAI6wAlwmJWZZsw1hZVAr+nhDbA67yCEWBtsmvsSb1GFr7N1YgHKrGf55Jam4I/5H4LpD/VSCYxjUS0pbva5jgtgCFzFQc4Palsjcq+A4bzraxFGkdtXU4obu2E7PkFalN8kvgP3X01s8QtoNYwm/wMLHGALnTeYVwAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAABiUlEQVR42u2WsUpcURCGv3N3SR5hK1EwAbEL+A5b2qSw9AECsU0IKZIXSGuVMo0PEMgbWIiFlYogVomF0RCIuev90swJZxd39+4uAYv8MNzLYe7/z8w5Z+YmlUAV1jCMvDa63gopBBLgFN9qHpFuQb4K7ABrQZZxBrwDLgqRNIFzOFA1qWvqpeNxqj4N367KFOvk91yiT8AWcBtZlRgAj4ET4BnwE+iNyaIBvg2VNJQO1d/qrVqHDWKtUX+pz8P3lXqtfldv1B/xvFGv1H21H75VFjifUJ5a3Qy/17bDQN1Q/5ZjD1iKFKsi3QR8BD4Db4D3UbLOhE2ugUfAC2CbFhuG+raIrGkRfaN+KTPYBVaAu5EjSmS2XmSX2tyvfFyzQB9YnvBBc49w64sGcB3R30eU5iUvBTphC5GN6y//FP8FHo6ALQbOLGgyXxY4iiNax31YxOrgPZhl4MyKY7WnpqTmvvEEeFmMzDRjWYxOewB8AL4CKU+0at6/hmkNrzvSzBYVSmF3eZP/AAkQCZqRTZteAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAB+ElEQVR42u2XsWsVQRDGf3t3iWj0L5AgCAFBSazURm1TWlhrukQQhNR2kkaCpX+JrZWdFoK1DwtjGYioxfPu9kszGzbH3b315d0zxRsYbu9uZ+fb/XZndpwkWsTRLmLGUjTeM3Ned/R31qeeFQAXrUAGeGtfAi60zP7I2vmsQBQN5xvAS+AusBJRIfv/1f6/N9vqzAgk5ZKQ9EDSb02WUtIjs8nsmUsqEjT0P1EkOUkXJY3MwViS79DKnn8lbZlt0Rx0gubxe2HLew+4brwu9yxYDpTAErBuFFXAJnDNaOo6QT+Bj8A366NAAZKe2MzKnqWP/7+OZrGtdPkjaS+iz6UC8JJqa+9HznfsW2W0lD0a6JOkV4GOMNDTxBl0OfeJ9nUEdjXsAYB3dvT6OBwDX6z9DHhreybrsaEl0NW2h+4A3wOAQ9OUuPEC2J/CeRzQBFyOA9FD4Hk0aBf6G8BNG2Aa53FIVwxgDXicaOx7QE4disd2nquWBNVchWyIbOiidsEcJeM/ywLAAsACwLkBoCHu/AkJ6QTAyKKhm4Pz4GcU6oIQ3z8Bty0vLA3kvLR647PdB3x8tb4l6UDDy4H5QlIWKqOQn68Cu8B94MqEOvFf+Ab4BXwA3gA/gs+u0mwem983j6GP0rIbaPOFsX1bcZpaop+VilNyDG78DwAVrhvXAAAAAElFTkSuQmCC")
IconData["fontid_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABYUlEQVR42o3TPWsVYRAF4Gc3N6QTQuBCMBYGDDbBqAiJtcTfYWGpFlaxsrOyshVs7PwoLPwJgiQkTUhhCpsQJCRaCCIm2WtzXn1ZbsSBZWdnzsycmZ1p/JVrmEGDz9iNDiMsYjbf+9gu/hbPAirP2wAnAmqw0cOslcrXY3iMJSzjfIIHeSZwMb6reJ6YWbiNX1jw/3ILx7hcsk+m/xb3cRNT+BHbFH7iPV5iGGYNXErPZUAHobdV9buZ93owS3iD6XH0XuBB9G28i/4UT8YFNNW0a2mxE9rtWTHF0Y1xdtUOdJlTXaSTQYx62Uc4jX5a6cc9zB9ZxAdcqGyr+FINcS+4IjcSMxxgDitZnv3Q3MOr7Ecb29e00WE+MTOlhRMcVXR3cO8fi3SURKNBqg3wML9sMof0qXdMV8L2BHeT4LBkfJQhlZ5fjzmmj5X/O+6onOUwzlXb+K3HYJjNa1L5EM1vZPBe0TnMHXYAAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABx0lEQVR42n3VTWpUURAF4O91XuevlQRBnBoXoI6cOc4KnIhEXYTLUHADkoG4hIDgMCQBZ+I0Ig0KSTAEY9SOSbeT8+T68joFBd23Tp2qWz/3Vf6XAWpUGOGXblnAHCY4w0lprLCEV9jHj+g33AmmF4W7sTW4/fguoaoT5SUeY4jPmAn4uCO77/iIKzjHDTxNwCfNNY/wCYsdBHVL27IY3yMMeuhjFnv4WVytkbOWltKLz144+k0D5KBKCe5hNQRVEWQce423eB/7bNEPg9Rrq4i8EcfLdKPAb4VjUKfl99OAXrKYC/AhDvE6/x/hGt4UmB7WcLU9PoqrPcDz4vxLtJEXweio+YU5a5/P42t0/hJcbyp75rCf35PivPndD6ZzxprulXJedHRUEI0K4jLQuF2z27hZtL4Zn1sZn5noas4mBQ5WwvHvQTjGZnHdZvaGHeMyjK0qrr2ZlRzUGcqZvCBV0m8yfFZGjnwoMmywCynfLCxnfbY7Mpwm7Qy3w7Fc4w9OcT3DOmp1tO7Y7XHRvLn4noYLrIdgN2u0g3cpdntOV2LbCXY3vutdD+xB1uckKzftgT0scAflA1td8gn4He2S+eiFT8Bfo8eGcbuBWwIAAAAASUVORK5CYII=",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACRUlEQVR42rWWT4hOURjGf/dPE1JfjWImycKfQkk2FiR2Vnb+NBs7RRlWUrKwmoWFDUXNRpmaKYnFlISFkgULJrEZJTsLyvQNI9e9Fp7z9Tjd8/kSp+537/nznud9n/Oc9/3gV8v59y0LPxnQABuBk8AmoABqjV8DZuVEbQ7VwDHgsNZlQAXMAVeADw6yFfiohfEzpU1L8y5E/DRhMw+MAFmpgQvAsNCvA0va4Adwz75Da/QeA/bbWAcYBzYAZ4BzweCFQj6Y4LNMPG1tXM7Meti5qFrSWAF8M6NqgENdpnVd268HUAs1HFQNrAX2RZQURlejfqBxQd+53rUDrNTizAAvA4cGlOQl4Kw5UQArHOAqsBd4ZhLsiKZ3wHv1d8q758BXSXtUAglU3xf/U/Q5UIBp0TCm/jb1F4BVGjuvsYkWKf/WcqMo0LQeOKJQc2CHAYxqbBg4aoDBvvib7LDdANYMapT/IZeUppyUfWlRJwGKSEVBmlUi5NyAK5Mx8fqyJQ3ELVyyRQNe7GPTtM2dAmZMbpl5vBu4CzwGvkueD4FbwBaLKDdx3FaW7bV5IR8wykq7RE3iORHlKoDjmnvkFHXt+hPRNgG8AoYEHDbvAneMxjjtfImTXTAuLccAfAJu9DmjMno3bYccvBqSN1VikzYBVJEYllvl6xm+0UW6CKxW2g6Z9YGqXWYUhu91wB7rd4DT8n7OdduvZN5siSLcgScJm7dKJ1kweg3sUtHfHBX4aTu8uGROAp81lyvil3HR/69/W34CU7eu6d9YVeEAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADDElEQVR42sWXv2sUQRTHP7t7kRA9o1gqKcRCEMQESwnWQYuLaGNnHwJ2gpArTi2UQP4BCQQbIVooWtomxGgUBAuxEC39Qe4M0du9tflOeDfZX4eEDAw39+b9mve+780O9I+IvR99NgJvnQIngPPAYdFT7bWB50C3xMAQcAmoG1mATeA18NXY2jEcat2UoTRn3hFfLcOwo90tkG/LBrIZ2JDMFQi6uVDBgYUKeuZcOlx4jgOf5UwEPAXeysuefn8BD3WKvhB6KawDN4AjRrYHjAMNINE8CXxzwtPGu+U9BOCysTONyX3dnGhN9GGFtQYc0Iy0VzQjw+/kh7W3ZoBdt3mzaB1SyGLNQL+DjMRLC9I55NOtAxhGO1Ll66j2ghLjqU77U7giR3efA5E5ZeTRLgOPFcZBxjZwDXhmdO2y4zDQNvlqe01qUsa7AxjvSmbS02XtbLoIBMAL4D5wEFj08vhXXqfAKvBF69PAWfG8Bz5K15hKLpas1bUInAJ+Ay/L0unS0zKlM2X2Zwx9xtCnDL1V0Lj6NgKT+0TCDnCLwAXgO7Ci8kqAEaNnxDSxFeAJcEyygQHfLju2CuIcxH4CLnqXTeIhuidaCPwArmRURqadWgVABV7tpiUlGHj1n1bJc1ldlyry+Kvy7pThvo1axjopOEFg+ELvIK6+y+QdCGPfgbhieLe13jL0LXN3lMnHvkeBSuu2GlHTdMPUA+AYcEt8Z4AJ7b8BPqjB3FOzCjx59Jk3J76WaVQ0DHhmC9Kz5H3ZJCbkbi4VyM8avobN46gUxVrnVcI7L7+hh4UU2CiomlHZSJwdC7zI69tZ9/sD4BVwKOPaDoEOsF6ix9rsa8VVS3P9P6ou9BtczQNZoKs0zGlSiQFuUROKMsq9Z0CX+g50jNJxMW+XdMaiEef8nzAH7lgHVuVdBFxVFDbMTeY+yx+p5os+y0eA695neQqck25XOav+W61Z4UExX+FhMl9Bj3sdRTXjZVOnuCmUZ40/FcJfxNORg033YKnyOMV8zw36OLUj93G6r8/zf72HG1/9JZMSAAAAAElFTkSuQmCC")
IconData["fontid_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABi0lEQVR42n3Tu2sUYRQF8N9sJsRKkehKfBXaGnwEBf0D7LRI7EVELXw0drGysrJIYyuILIL4wEX/BCvBFJLChURQJMhGGxE1yY7NmXVY0Asf3LnfOd899zFF1e2IHcMkCqygFx8qTGMq35/xDkWJFhZwzV97htncDfLQfcw0MPO4U1Tdzgze4DaeYws+YnVEwX7swi9cxUXsLrED6+jgvX/bSg48wnlsKzGG8dTfwg2cwgR+JDaBn3iFh2ijrHvQS80fUu88dmIRR5LxLY7iIB5gCU+xWj8w25D6MuSFdHoZZ3EXv4NZxJxaRqPbFS4E1MqpJ3WzkWTIaSUwGLkca8Sq+OONqQw5ZQBNq7AZf7Phr49ghjKn8Rr7GoDT2YNDOINPwdV2PJx2ib04iT1Z0SKEx2laK7GvKWOAA+FM1iVsYK0hdwnX/7NUa3XTy2Qr0+UXydLLVjZX+XDUbuBSHuiXmfWt/AtXQniCcyPTuIcT8b/jMvpF1e0UyTCFrQF8wbcRBW1sT6yfU/wBWeNrf+gKC9QAAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB9UlEQVR42n3VPWsVURAG4Gf3bhJj1IAgKiKY1KIiKAhaBwX/gIgfhbVY2PsX7AQhIkjETkiVXrCw8AOxEg1qwDQWaqL3JrnX5l043FwzMOw5O3PemX1nzmw1WFxQyBQaVOjij9EyiQkMsIm11lDn8DTm8Rkr+BY9WfjVWZ8q7Cs5Mx+MqkmU+7iOL1hGB7/xa0R2P/Eee7CFg7iZgDeqweLCVCL9wHGsDwE0Q/vNof3uBNiPIzXGMI7VgNUjAEotpc6Z1WCMtQWQF1UoOIu5AFRFkH7sDZbwKvbx2KsGvTh24wz3cNHOcg6Xsu4Go9ek5BdSgDqGiTheCbdPsr8arhYKnxrXsBdrLeGvCyM8wBs8zb6X51KeZ/CyyPZju6jS2CVHw6SP41P2swVFw37Qr//DTyfVV/Barsfis02a/2S2VVS0LFa3AC4D9YdTPYFjLQ1F+8ymfTrRubwbFH4wEwztTfmOtzifg/04L+PoUPZfE3yQhLbwIoCHm5DeyQSpCrAB7raRC3lXZNj6Toa+8abgopd1meGzqBFVLTNs22rQYCMvDqRZu0MVHTUc+kXxJnK2h432pjzP+PqQi15nfN3KvCv7dAYPM776GV+zeNzelAq3Y7yMQ0WL7BvxudM4XVy9dTzCHVTVDr+Av9FRsiu67RfwDxOKlT/t25xRAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACe0lEQVR42rXWO6hVRxQG4G+fc7xqEAwWgohYmAQUTJEmoiIqqE2ISaGgCIKVCMZU0cZCGwuLNBETUMTCR4KYx0UQo5VYmcaLaOWzUsSEiEYjx71t1lwWm+31FjqwmTlr1pr1z3r8c6pm9CT0UHu3o0IziEWNj7ADH6MfsgY/4lwLRFlvxcbQqzDEGH7AQ1SDMFiEy5jVgeRJh4MytmNJS/YlNmE5Hg7C+944fAw/4UUov8L5tC6jiXkzViXZTHyDBfgWe8oNFiZHf3TcYvCGON+JL48a32NxNuxFDF+ErI//k9FwEkmdFnpP03njDuoIQUlUjblY2QpJP4Wrid8ljE9i3Yu5zg5mhHLVuuaGSZbkQXyXQPTxQXZwCCtwNVXLzAjTXdyP358Fur/wPEp7Tqq+Hi5E1Z0oAoH2azxOsn8wFfuxFtsC0EusxxocCZ1HycEdfIFTXUmuUznuxq8Yjf0pKSQjITuMW/gz5aaKvQZ1TnJ73ItPh04d39843dEf4z3TewuXDFLldI1e6FQTKeTMVy00w5D1W2B6yfEwIdfWH3TQQHuUJnuWHD+bwKbpCtFO/JzKrUp7y/A7joazkUj+maCYck7Rn4+zwbLjN9gVBHUsujJX1VfBkJmXVsf6Em6mw2usi5L/EL8UB09T+2uF7QCuB/J+6DRh81sKY5t2/mv3QTEeJI4RpXh8ghwNWnPTleSCaiTQDCdJ11m3zNNzzxTDm/gU+zA7aLsw68WgkCqFsKznxctVpQdnV6Afg6oZPVlFNbzpyTyBLQFmmPrmFa5gaYfN7XD8oNzgBj6PR/+T1vt7uoMqyk2O4N/Y6wWAa/nRr97335bXv+u4hwQ+WNYAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADX0lEQVR42sWXOWhVQRSGv7tEQkxcsFRSiIUiiBEljYh10EJFGxXEVixUEEQhUaIpXEBtRdJoIZgUcSltDTEarSxEULR0IXnGaO591+YfOZnc7RHEgcubNzNnP/+ZOUE2dh8zIiDl344FMmKzEWhjHbAdWKH1THszwCNgvkJAG7AH6DK0ANPAC+CT1jKnQKCvCQwAZ4DOAuZXgPOiS7w9t3YROFdA3wCuS04IZLEmKdCvr2x01nDx8gr6fll/EYgC5cBa4L3iEwGjwCsp19Tvd+CuQvHXhV4IM7n+OLDK0DaBHmCfjE2B9cBnlwO9wDLNR4ADFVZmJWszwM0CuofAfhnZC4yE2ugyDCakdbviGku5ZSIMK77InHf07dqbMMp2WRTYbG2TyxJ9QU7CVY3UCwvi2eavxzkubea4dj2wWntBjfCEwDflFQW8FygQGSsjb20v8EBubGXMAYeAMcNrkZzQJI6L14xxE8AuCZ9vQfi8aHZ5vKycaVuIngBXheFhL46/pXUGjAMfNd8IbNGZN8Bb8eoW5BLRWl7DwAbgB/AUCGIx+wmcLYBVZkJ1ScoCnARuaX4HuK15H/A4hwfKixN++XQuioy2mUm4YWAn8AV4LnilQIfh02GK2HPVkjWiDUzyLZJjUZAUZOw7YLd32aReRje1FgJfcwpZViQnrpFQgYfdrAKCgYf/svO1FKjFyDtf9+xfGP63EefM0xILAnMu9Axx+K6id0mY+AokNd07p/msWZ81d0cV/aIkDAStCypEA6YaZl4Cduu1sxzYbPgcA3aowAypWAUePXrm9evcIPDbFaI+KQDwQfd57NXtBLgMHMmB6jZ97tVzNKfuJ1L0lNZeAqMujisVu0TzIiS89uIbermQAVMlqFkpGamTYxMv8up23v1+DXgmK5s5iGoAkxV8rMwFpbguNCeXgLrQL3Cxl2SBrtKwoEilptKVFaEoB+5NcztmvgINw7RHh+daeJD6Iyn4v80Y3LAKjEu7CDgoL0yZm8w9y+8J82XP8g7gsPcsz4Ct4u2e5eNOgUjt0pBpTA7r88cm4LQHMTyoDRqoFfWGg5IZxUbLAVlxuqQD+lXD/WVnGsAN05o1A9MdOxf6zSnmPddqc2pHYXNqk8uF49MSoDav1q5We/4HnEMLCirAKzYAAAAASUVORK5CYII=")
IconData["fontid_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABfUlEQVR42o2TPWtVQRCGn733hHRCCFy4RAsFxSYYI4Jaizb+CQtLtbDSys7KKm0gjV0SixT+BEEUbYJFUmgRREKihSCSr8fm3bAeImRgOO+Zj515d2eKSmQemAYK8AXYDAYQmAXG+f8GrAMFdaAu+K+8VlGHaol+6MU8VUG9FsNzdU69oc4kuYsO1fPxXVUXkzNGvavuqZdS9TR6W91XL3fAEJgI/wHwCLgFTAK/Y5sE/gBvgFfACOjqHVwM53FO3057nxq+H/N9n5g5dVWdOqm9JfVx8Lq6FvxSfdGPL2pJm0d5riqDPNVX4F78VY5zBjH0ncPGZvBEMxfHOV2vak04DD5s8H4vJkhn1bfquYbbHfV7c4lbiav+68kZdcBZ4CYwkxEtwBawDOyFawF+hMYRcCE505XCAbDbtPsZeMj/ZbdeepdqHfAEWEuVTWCjt0xX0u0B8CAH7FROzzKaVVZOWKZ3jf+Xer+dA7OqZ1JxG/jZ62AETMW2Ey1/AdGjuu+MGYggAAAAAElFTkSuQmCC",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB9klEQVR42n2VPWtUURCGn3Pv2V2TVQKC2Jr9AWqjYGEd9CeI+FH4E+z9C3aCIAii2NmmFywsFBEribJdElxCklXvTfa+Nu+Nw93NDgznY96ZM8zXSZIINAQykIAK+MNiWgEGgIBjYHoikZQkrUl6IWlH0qH5l6QrkpBUmJF01bIWt2PdNUkp+5WnwH1gDPwESuAQOFjg3T7wFTgLzICLwEOgAB4gaShpT9KWpFV7ETl3uCtfte6epGEB9IA+sA389kuRjjscqbDOtm302gTgi+QQXAc2bCCFRxrLM7AJfLS8b3nKQG1gZTDAE+AWy+kGcNv7yjbq7JTfdAIKCwYG3gEmwCuf7wLngdcBUwD3gHPANPvyUxACPAM+A298rr1uer0GfAjefm83yYUdY9QNeh/Y8nkUQtTFATTFKfEpnX1CXOO+Z8wc5VM8m4WMxmRVwXB8qOm6ehm41IYhlM/I5VOaN3yngANYtw3aTjmQ9N6VX7q/C0ljzdPYsmQs1t2XNMwOeukJkux+6+Hjk5f/05fgYYtdcfj6OcSi9r4MwLdmFmRVXmehrJSBI19ccLFWnYzmBb3dhOQNrFsDR22nvPP4+uZGLzy+HgE/OnW6Djz3+Go8vkbAS2DaHbC7kqbmyZIBOwm43Thg05Iv4K95EZ0xz30B/wDfZIYm+xLMowAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACZ0lEQVR42rWWO2gVURCGv7O7BA3ChQhqEEnhA1QIYmOhiHZWdj5IYycoGK1EEAurFClsFBS0EAxEEB9FQETsxEILDaJNBLGziGBIfMDN/S38z2VY9t6k0APLOWfOzM6/M/+Z2SQJoAA6/NuRAFVedIBtwFlgO1BaJuAmMFMDkdengOPWS0AbmAWuA1+BhKQkaZekeTWPKUlIqjwjqfD8qofNnKRNklJl71eAIXu/Bfwy0mXgaVjnIc9jwOEgawHjwFbgAnApI3orqSPpaEAZn6rH06Q7LmlZ0owkqhDTZOSVc/A7IG6vIqlrrLcY3td10HEIcqI6wGbgUC0kZQiXvM9hXPC68NyJDtZZOQWH14Bjq6TkJHAxgCiBwejgBnAQeB0o2HKYPgNfvN9rdG+An6b2sAmSQ/3MtJ76++3NCUXStCk35v1u7xckrbfssmUTDVRGEpHXpe9EsmxE0glJgz7fExwMWzYk6WRwmO3LfFfoQbWmZzQ42Lhau2KFWlIF5jSNwjqpn0LMfKrd1rZlZdDNdmW4I6oB6+pXDWWgPvIlWwqOl/rYKJ5lVOeA+4FuKZztB54Ad+xsAHgEPAB2hvdk/RHgoatsN8lzTuAR78tAuUn1HmdqtQpJp332ItaixXD9qYVtAnhv5KV1ZJvHIYz1svMj5qAIxlWoMQDfgLt9clTVZjUlOaMaMJp2j5c0EaBdI8Pa2H6z4UdgFLgKbHDZzpX1OTCfe2zst8AW4EDYt4DzRj+bk7xSy7zXUGdKzy972HxyOUn5Cz4A+9z0d9Qa/HRIXr1l3ga++6zwF7+LTT/979+WPxuIreZydhg4AAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADMElEQVR42sWXu2sVQRTGf7N7IyEaH1gqFmIhCKJiKWIdtEhEGzt7EewEIRGiFkr+BAkEG0EtFC1tE2J8gWAhFqKlD7xRYnL3Hgu/ieeOe3c3qOTAcPfOnPec78xMMDMc5UDB/6UeGy23ELSwEzgMbNa8aa0NPABWagwMAMeBYScL8BV4ArzX3K/IzSyYWWZmmNmEmbWtP10RX0u/fsS5qxXybdlANkMLyBT5uEYVbWqQ4o018uOK/jKQB9XADuCt9icH7gHP5FxXv1+Am9qK3yns3UJT6s8CW51sFzgIjCrYAtgNfIjpG3NpulOS3n817jg7Y2ZGJu+HXUTz8npQRdoCNmjkWqsaueOP8oNam3eFPexR4Kt1QCnraAT9roWKZFuQzoF03juAY/Rk2q9tWgs1xk3RflZd0Ud3jwO5izJP5k4At5XGtdAScBq473T9YSfWQNvtV9ulCeCojK+swfiKZI4murydrzEDAXgIXBeGp5N9XJbXBswB7/S9F9gvnpfAa+naJch1JOt1TQN7gG/AIyBUQSZ2tkkHnRG3fs7Nn3PzI25+sqJzYmarNRDc3heKMBbcNHAE+AjMCl4FMORSPuSa2CxwF9gu2eCK7w87HgWdPhX7BjiWHDZFUtFdzWXAJ+BkCTJK7bQaFFRIsGs1EAwJ/qv4GznQSFHC35R3FYbrRq2S76IiguD4siSQiO86+ViEndSBTsP0Lun7u5v/7s6OOvkenmBmQdC6pEY04bqhJQW4C7govn3AIa0/BV6pwVxTswqJPLrmjYtvEliODWHUNY/zJc0jfs8kV6xCw9NMhfx5xzfq7wNbtHcdffdDwotkf7OkFgx4XoGaLbJRRDu+8PKkb5ed7zeAx7rbdUsQtQgs1OjxNntacVNoLvwF6rK0wbWSIgs6SrM+Tapwna6qCeUlcO+609FSBxad0oNiXqrpjFXU6fP/kAt40TswJ+9y4JSy8NydZPFafkuYr7qWDwFnkmu5AQekO17L5+LLKHevojqaavAymmqgJ76O8pbzckJRXKh4Af1okP4qnkVgSrYyoBvc6zimMH2c4u5za32ceip9nIb1fp7/BIDX/n4+Zx9FAAAAAElFTkSuQmCC")
IconData["launch_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABU0lEQVR42oXTu2pUURQG4O8cz+QigxcIiJVRFBGSdMY3CClsBMG3sDZF+nQpUlhYKyiKWPkCgZgqqYKgL2CRBEYJUUaPzX9kZ8iMCzabve7r3/+qUKHFFTxAL7pxcoJt/ETVOa7gFRoMJyT4g2kc4hH24SoG2EwXfVwcc/qYw3t8TUGr+N49Uv28U8o8fuFugymcprXfwWOcXMgYVWKmmigksMYTXI++jv4ULzNqV6BG2wT1fqrP4jkunVP9G96NKusYdpL5B+7lLGIvfsP/fO2ZhJ28SdKPuR8XtpspttCMBLcB8y0e4ik+hSfDSRXrgNbgdYLXsYVrsfeKuDPjVHFoQpAWa0XiJRzgft51RhgEp39dfEjws7ybCVjdCpFuV8UybeZHNgrCtBmhXLA+XmAGy+Nw6Zwv43PaPcZRaL+LG+U2djQVQpX43MnPtAWFv3T2v9MDSsDmIWVcAAAAAElFTkSuQmCC",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABtklEQVR42pXVzWpUQRAF4O/emYkTnURQFBFEfAN/F+5URIlu3AhufRtBwQdxra7UlZgY3SkIKogbV/4rxsRkXHgaLs1kEguae29XV02dc6prGv+sxUbeR/nejm3gR52jBF/EIn5hDX+2WGs5+xjnS9ImL2fxEB9wBytoMN6ksuLbgas4iHN4VA48xTvM+X+bw3ssl41dKf9WvofoYzBl9bOGibmdHKPiaLLRdDjarjUditp+h6fCS1F7vvKV59cq4bjj1+/IX4JncA/HsJ4z60HQC99XgqKpyy1wB1GsVNF2+FrFLPbEfya8f5mEvw3+F3iTvd8JOpJ2OJ0OKPZ9SjupoXd/SKpaToJXSfYZu+Mf5HkjFMyXwK6qvXB6AA9wEk+wEC7baRX2K4V7CdqPuziKZ7gcLmdy3Ta1tiN9m2T7cB/Ho+hCYM5FuJ2T1K0rLJOiTnYJH+P/FD5X8LPqzXHd6W1gPo9zCXs7nJYzw1TZq67ezegwKgFwKskWq2Rb2SzeluFQc3ECr/GtQ0Op7joOhecma4hrOFyPr0kXXhX4MrBWqwG7hAv1gK17cFKfDQJv6l/AX0bTdZJdGpwZAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAB8ElEQVR42q3Vu2tUURAG8N/dvbtIAj4LlZSClVF7C0XwARZi0sRW7a2ttLQRC23tLFTQPyCmsRSCImJhI0pQiaL4qMxjr82ceLhcN3fJHjjscmbmm/m+c2Yu/1bH+FY3/Sky8AGOYw4HsoTFJmBV/K7hNe7jVYa5AXQ9nLe6B7icCk/VncI8PuIqnodj1VKSAiVO4g4mcDQYgScBeGIM+l+Kwm7nh2/xE/24oG5IN8ouI24qip0Xh+keVsNhJSh3Wlzwek3GJGuK30iQdKxqwVte5RDbDI5FVfmTTfs37mJ5GNMyozbIHPfgcYsC13EjpB0MSzCByez8B25G41Xh9wtHsDPuq49tbSVaxC78CRZruFbzPRdd2ou4ok2flJneRY1mN3tdF/Ao/L/F2b42CTrZPBk02BL4wwD/irNYqs2hTRkUtYBeDbwX4GfwEtvbPtOcQR18JgP/koH3oxkHo0iUM1rFLB4E+HIG3g37ZMT2R2m6lGw2QCp8xuEsefK5hQ/ZcOxmtqmIXWgCPx9PtcInTDd0fJH1Tt7daUjuD/meNn3iFgN8CYdajJOmNdc0rhOD07iHg0PAS+xu2HtxEd+DwfQoDyDJsAPvsr7532fzSlKmbADtZMOvvlbwDO9rU7aK8fImxsmLsI1l5A9l/xcnuY2/Ku1J8wAAAABJRU5ErkJggg==",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACtElEQVR42rWXvWsUQRjGf/txyZ0fEUHDNTZ2YqWCndhoQA9U/Ci18B+wtTIaC0Us7bWQNMJdgkYE/wCx8AMsLEQEERQl8ZOEeLe7Ns+GuXFnb/fu9oW52Z2bneeZ92vegX7xgIDqJBBGH6D5nOh5GtgH7LQ/GFK+AC+AlQysPiI14CbwTRPG2T4Dc4aGvfQnbSHQBloGsV820yHEA6aM94fAGSACktTmEXANuKJJT4BbwDsgHoGEB/jAbuAycEzjc8Cs6W/bgWUReVyhEz4VxoowN+SodhkBBzU2YZlolDahNQ8ZGp1BdgdoavAP8FEfdcdg/1S6WvO9MLYIE9+yV6znpAL1J1q/Z4ZhWDB5JCWcLjE24pqzIUUIRBU6ZS6BQOpqAZeUpAZlxZ/AVeCVzBuPQiACJoF7wI4Sm9qkqCqUwn3LQWLLVj3gzQCSafurvl7GkUMj5n1gs0UgUto8qZ0lhmnqUveUMR4UUXsWgWfAB+C1MqJnON93mcGWeYFHWifK8vKiBN4Ce4B1R9gEhlNNAgvAEWkiBH4AW4eJAt8AWR+QQLoi8kDgawK/K1MEoxBIclTn6/8a0NGJtgY0gCXgYg75wgRcXpsHvgic1rx6FYnIBj9ugZ81SPfGoQEXeNsCXxB4ZJVXcdkQdGnABm9Z4OcEbp6eccZmhipmPSMxPRKRVfUdEfas6PGAXcBz4BNwwjhL7HWbyisJcN5VvzVUOA4Cd50DeRtrKmfEwAWXOWYF+rsEuG+ABI6SzAMOpNVwWpJlEbhu1PLtAuBlbN0RgeW0KA0zCo8bUtEqcDvD4bIy5bYccoFRlp/S+B35QuCVKLOyxkPgPnBYRH2HeaaN9yUlsJ7ryE4XDnPUm443pM4iV7OvuvbV7KvZKFeuBNgL7M85TxLdNV+qz9Nq5fLf9fwfNJTRekPVVx4AAAAASUVORK5CYII=")
IconData["launch_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABX0lEQVR42oXTv0uVURgH8M+5nmsFYjlFri0WODi1NzT5A2novwgcHAo0mmpvcJBGBUNxdRUk3QwHjQKRhsChJSRN7B6X54XD5d488HLe97zn++M8z/ekqfImoeAenqCNpP/4gx38RcoBfoZVZFz9h6CDW/iFWXzJGME6PuJtEHT6ELRwG8uBGcthO2H+BvUS8xnm8A0PMwZxEdb+VRt7jYFwlwIzmCu7JSy+wINYb8X6BVbwuxJooeSo+lCo38EShnuon2KjV1FOsRvMZ3gUzzj2Y1/f2rTwGU9xGd8/8RWLmMBWtLfnyF1kJYq5jkm8xF7k5Kqfg2buBOFagBfwAffjf7vCpdpBqt4/YQav8S6AP3CEk0qwNO1sCDrYxDRe4X0V6wM87nKeIpHnuerrcQUeiLaKI9QXbCiifIDjmmCuqx4Fd7GN0SqlbRzieROkOqYqZZG86ehMqSL8vTnKNZj9Wum7YR0fAAAAAElFTkSuQmCC",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB10lEQVR42pXVO2sUURQH8N/MziZRo4VgEEXESiyERLSwUxEkEUEEwVYQez+B38PaUksfIJJKfEQRRAvRwk4kbHwkYtTdGQvPlcuw2awHLnN37pwz5/+Ys8W55jqUqP2N6fg9TtRYi32JusyKncETLKOHlU1WL559hNNRo6xicxL38RE3sI4CzQadpbNJXMQDnMJiEZCfYQaHser/Yjve4BOOldiGOdyKYlOo0B2xqlhTkXMbs5hOBwV+x7Ufa9woMorKKuMp8ZLU3tE6S9evrYJNdq7K5E/JE7gbNAzimUEg6ATf5wNF0W43we2GYqmLMuPrF7ZgZ5yfCN6/DMNfBv7XeB/3fkbSAezBcXzIclZH2EkVBeYyIep40XJ0dROH8BZ7MyQ26lBL1U4U3Y2HOIrHmA8uy806zBXuRNIM7oS3nuNscDmBH+N02MR+gF24hyOh6Dw+xxcxia3D1G13mAZEu9hCDIEyBsJSiPi95c2mbRsBc1ixxGk/1G8yejrhz39+rjKo+6PY0+Csl3GaaFlvIeyHRy/gJdaqLGEpFH2Hb9mLktEvY192r4jhcCmauZJzmOJFxkud0dHFNRzMfNpEh69wFYtpOBjiwSaDKaDOBryRfwF/AN/TiybqoBTBAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACF0lEQVR42q3Vz4tNYRjA8c+999xJpiaysZWVZuEPsJhSDEkyFixsqFlYSbOiNJassVEjCwmlrBQrNork14yNlfyIISVTZGbuPTbPq7fTGc5tvHU6vT+e7/M+P9/W3nJajDb6/s/ooAdFBT6GQ9gca9D6B6yM/zJmcRUvErPI4NM4s8qbj2MKk5hBuwj4joB/wHE8ivWyIbgV3tiO87iEx5hNLjoWsMO4vwoLroRHZnAUJ5KCUSzgYQTIALfPk6TE3fiPVoO8FPDFMLndIMC9ykWSW5P8HwXJj2VFeNWj+MveBLbFrfKUTd8CLmD+b5YWmWn97OAG3GpwwV5kX2elIk0K1mI4W/+Gs1F4ZZz7jq1YF/EawpqmLnqC9fgVVizjZOXsnqjSbsi1mmRakfm7VTGzk2XXftyM819jbWMTBe0s5/s1ewl+I+BfsAvvmtZKUWloSaBbgXcDPo5nGBmk+hK4Cp/I4J8z+FAUY38QF+UWLeEArgd8PoN3Yn84ZIcGUdCO7Mnhn7ATz0N5svQ23uJOTSxadQrSm7AP1wL2MeAvY76cFeMUtkTnbWXrncx1ZV2QT4fZ77Ebcxm8+oL9qMxT7xoL3lyuIB06hYM4h9c18CRTl0XdeHAuBu9ytRfBvfjymOQWjkSwN2VtuW5MxvvcKWqC3s6aX3Us4gHeVLpsGZd5Fe3kaez1qgpWAicX/sSRhvXVh99bdZjXy8dZHwAAAABJRU5ErkJggg==",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAC0UlEQVR42rWXS2sUQRSFv36YjBqjCRoC7nTlTkVxpyC6MGNQfP0A/QHuRDASHwRBXLoT1IW4UIhRCCj+AEHxASIuVARFCIiJEZmQzKPdnJKiqH5Mz0xBUz013XVOnXPr1u1gPJnEagEQAk160yKgBSRmIHbAE4GPADuATRrvtM0Br4F5B+s/ATOwCrgKnAE2dnn1c8At4LIWGQBJrJtA4NNA1Xrpjy1XyRYAg8AocBHYDhw3NseW5xcs8KfAdeCT61kJ8BDYApwHDgHjwAQwCUSBgnAI+AxsAJ4BYz0KwufAfmAR2AoshPpjFzCs+0vq+yx7Or36NOcV/R4CdttBOCqZ/wLf9FC9C/6bVtecX4QxIExCx6+W7pMeyJ9o/oZvG+Ylj6SNoEushaQ9gy8RpbVeZcVcApHkqgJnlSfysuKigvit7G11QqAJ9AN328yKa4CDRVN46ARIy/GqAbzPIWmuFfWVdgI5tvZ8CKx1CDSVNo9oZYllTUVyD1rjURHZfQReAF+Bd8AvCxxgQTa47b7Am5qn6YvyogQ+AtuA5ZRtE1lB1Q/MAAekRAz8BtaV2QWhBbKck0DqIvJQ4EsCvyMrok4IJBnShVat8Egn2hKwGpgFTmeQL0wgLWqzwB8Dx/RcpReJyAUfc8BPWKQb3VAgDXzaAZ8ReNPyPfDkkdIKuOBVB/ykVdMZwJZnMUEZBcykRcHN/RPgJfADuFFWAVO9VIAHBVduYuA7sEfZspZzigb2rgs9Hw3ngMOqXLLAXSUDgUeeksycpJuVsAKV6d4YMGMDiv5TOeDuuG/lK+on1M8Dr1wC5sVrmrAmP7PAjQ3rM+SOrLL8qMZv6oyJYk8iqqlmdz3zTR4D94B9Ihqm2DNi/Z4FpszZEmewNqokGYEU61wYLhDwP4Hb+jqq259mPkkbBSrcQLtkL7Az4zxJBP5GPe1WxVkkAD7oKvV5/g9jYNCxAe50AAAAAABJRU5ErkJggg==")
IconData["launch_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABaklEQVR42n2Tu2pVURCGv7VdiRcOGkEQKy8oEkjsTN5ALGwEwbew1sLeLoWFhbWCooiVLxBQK61E0BewUOF4kCgxn0V+YTic7cCw9prZc/ln/tXUBgisAJvAEtAYl5/ANvALaD3BV4DHQAd2/5NgDzgIfAWuA+9Rj6tTdUtdUSfqkRGdqCfUF+pntaNeVX+oXUVtI0rRM+pv9WIHloGdtPYnkMbkQGC0xCz3GEjgANwETsU+xL4DPAKmpcAA2DP1SaofBh4ARxdU/wI8nzcOcbxO5hmwGl0H3uW/8c3MDWco30/dl1c5bxTfWXWmrvW5bswwnwHXgFvAm/Bkd1EDQzn3QqQnCb4L3AdOxr9U4lqF0NJ6D0FU7xRIl9QP6uXch0CYqusV98sE3869z82n6rkQ6Xwrj2krG7lXCGMg1Ac2AR4Ch4CNRdmHQt1j6se0+139Ftq/VU+rramVpoRQdVgXshkLhT/98/8Fc51zqDoIunMAAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB3klEQVR42pWVvU9UURDFf/ftW1h010ICMRJDLO3Aj4JOCNGADY0JLX+P/4adWCoVUBH50E4KoyaExsL4CQZh2T0Ue268uVl210km9903d+bNnDN3XpAEUABtOlL3fhBpA8d+7sSQVEhC0mNJ25JOJDUlnffRps9uSZp3jCI4w1lgA/gCvAD+AgHQJZlF2zDwFLgJzAGbOPKupANJDe//RxuSDiXtSaIArgLTwCpwBNSAEqj20NJas89LYAqoR0MAml7PrYNKSCAqygSniEtk+1pmi+uvLKASO2VCf3QeAl4bhpbPtFxBBdgFllxFyNON5VbNWMyiSPA6A0aA67Y/NO4/u9VfuP73wCe/O7XTbbfDDHCQ+Bz1aCdKB5hOiGj7Q1+d1XPgDvABmEgq4bIMyVitOOgNYB24D7wBFoxl0S/DlOGKncaBV+6tt8ATYzkEnAySofzcAsaANeCuGV0AfgANl3ulG7t5hnHa5MEWgW+2fwf2TOKfrDf/QSApeOKMS3qnjuxIGvVdrSRnapKG/a70HknPPIHq0QFJDxxsOwvWbziMSPoch0McX1HuAR+B3wkMsdFXgFvGOVhrwDIwmY+vXEOyBpe277LOsgG7I+lRPmDzHuzWZ1VfwZ6/gAupf6ynjoNz4wAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACC0lEQVR42q2WO2gVQRSGv9nde5Eb8JVCrQWbGLS3UAQTwUKMTWzV3tpKSzsLbe0sVFCsBLWyEYTgg2ArYlCMooip8rj72/yzjMN63UvugcOw8/jP/Oe1EyRhKYCayUgJDAGqDPw4sAgc9BxA+A9YvOEWsAzcBd41mJIKSUi6pslILemSMYtgF50CngGfgSvAKzNSR5cEe+MkcAsYAEeBZWzpkS2f8Pd29KKZ3JTUxGAGWANeOkCMcfs0SQQ89TiTB3nT4BumXHQI8DC7SHRrPN8YiH5UdnjbUo1YWwCO+VZpykZdA24Dq6OYVgm1Otk4DTzscMEhcN2urUcZGABTyfwv4IYLT973GzgC7Ha8+sCOri5aAvYA62axBVzN9p5xlfZ8LnTJtCrxd8holkl2nQMeeP8Pz+3vYqBIcr5uWYvg9w3+HTgNrHStlSpraPFALwPvGXweeAPsHKf6InAOvpCAf0vA+y7GehwXpYw2gfPAPYOvJuCl16d8tj+OgcLZk4J/BeaAtzYemT4GPgFPWmLxd9HFvu3xrKR1d8MvkmY9XyXdMngcJN9BUmk94M78XFJjoPS4ZPAVSYdbwLvoYtqucwZzku5IOjQCvJK0t0X3Sbog6acZzKYG2rTI3BIk7ZL0Ifk1/ksuR89ULUEvkuaXywbwAviYdVk5Qd67nbz22jAkz5ZJSvME+gMwXkx9/I3NpwAAAABJRU5ErkJggg==",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAC20lEQVR42rWXu2sUURTGfzOzm5dRETSksbETKxXsxMYIGlDx1WnhP2BrIUbTKGJpr4XYCEkkRgT/ABHxARYWIoIIiiEPHyQk2d3P5ttwnczsTvZx4HJ3ztw93zfnnHvuuZEkAomAGKjSHUmAGrAOGgUEouDFELAf2GV9u/IDeAPMb8CShKTIc1nSbUmz6rx8lzQuKQkxI0mRGZWACWA0YP47dFeLEgHbgudp4KzDrEhS4oebwHUveg7cAT6lY9YCeAzsAa4Cx60fB8aApB6CHZLmJFUlPbOuG+OFMeaNuZ4DI45TVdIh63ocp06MHts8LKlmrGOSKNklw3bzX+CrXbfWgfjXZc02Pxtj0JjEqXjV/FtdqAGy/Uq4DUsFi4c2kXQKPiRvzboUIdCtqtiUQGJ3jQJXgHKBqvgLuAG8c3hr7RCoAr3AA2DnJj5qABgpWsLjVILUUrGqAB+akKyPVc99m0nkugd6TGZLikDVZfOUv0xBaPrs7m2BPini9iwCL4EvwHtgLgAHWHAY0vLI4FXbqWZleVECH4G9wErOtkmCpOoFpoCj9kQJWAS2trIL4gBkpUkBWTORxwZfNvh9hyJph4AauC72+zIw6RNtGegHZoDLDcgXJpCXtY3AnwBnvK6vG4UoDX4iBX4uIF3phAfywCdS4FMGrwZxjzLqSMseSIOPpsDPGzw8PWsZH1NsO6Y6lihoRp66cVjyPCmp5DVxsD6StFvSK0nfJJ30uyTD7rCkBdu7GHZEBIb7JU0XAM8aAzn6kMCiu6JLaQIlz2MG/bMJ8DgASXJaskjSQbd9G1qyrLwYdPZfyIg5OZ1UXv+w6vma53ngdToJ63+8ZYNLwN0m4PX6sb1B95MEbflp6+/5jEmi1N2wUZuVpS8BD4EjJhrn7Kqh4HnGBawC5CZMKYh7o6Tq932iiPz0ta+cvpq1c+USsA840OA8ETALvPX8n1fbIdCR6/k/zN6LQ0i13Q8AAAAASUVORK5CYII=")
IconData["lens_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABaElEQVR42nXTvU5VQRQF4O/ce7HTCCr+RLFDK6LRoHZaEX0FEy2N0NGYWPkQ1sYOQlBjTXwBJbGy0BgrbcSrkYoAl2OzJgwnuJOTMzN7rT1r/0xj367hRNbf8BVN9i1mcCb7H/hU/D08D6h8qwEOAmrwsYN5Ut/c4hmmcRnjlbKiYgqzuIoX4UzCHLZxDnfwEhdCHIuKnoN2FzuY7qEf4FE8wkPczg072MVehetjoqTXD/AsVvAO7/EKI9zDDQzxN6pG+U9g2X+sj9dVwTZwPb5uOpoQVBLnqhS2sn5TBS+cpkQrstqsT3bOd6uztvI5TE2Tjgw7fV+oZuOAzWAdFyuJcAVLWMN8h3wLH3Cq9LTFzU6rutbDkfjuh3NpUOU9zH9UEUpdSvu24/ud2WgH+J6oi3gbBV/wuRrjvYzw+RT0cQL+KvKepmWlYMuHPKb1yr+JB3XVyzQeC/En/nSe82kcz9lGUm7+AcRnYPSTqhG/AAAAAElFTkSuQmCC",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABxUlEQVR42qXVTW9NYRQF4Oec3qJKmkYIkYgQ6QATfgsDAyGMzUyZ+QGmBL+gczHTBGlIE0x8DZhR6iO9VHvbmqzTvD3ObSJ2snNy33ftdfZZ++NWNtsujKDCUrzLxrAd6xigX15WmMBdfMJiAJ9xIpg6DqexENxiYm5jN6pe3nIT5/EhXhcBbfuBlxjHKvbjUu4uy8U3vMNO/27jeI8vGKsxim05+ImLmMWFyFEX0ijOmmcf8+EZhckQzQX0OjK8CkGvICu1bMgrPI8UEzWWU6lfIbqOh7gW8CDnPazFy2zXEzsIFziJw0M0OodHyXgax4tsG+IjRUf8ZY2uNc4mg9I/4mDxuUNJ6tZveJJP/J0WWQrp1ULfTfF1B3lV6DRZ6FdnilZxYKvMFGILwUieL4JZiehruZstsO34jXE61tFnU2naUsPpQuMmoSmcKju9j8etrBvB9+EKbuBMS5oG+xTfszQ2GvtZR+WGVbEa1ti9Qoflln5lcUYKzdZbZKvReKPsKyHbm5le7shosMVy2IE9BQ+4lze/wUwm4z4OdfTpUTwIZgZvE3urvWDvZGv04wsZya4F+7XAzZcLturYbb3/+Qv4A1/Mh6dzNEQdAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACOElEQVR42rXWuYtUQRAG8N+bmWVXELwFRQXB3cANxEjEwNREBQUxViNlNVBDwb9BBcUDTAURRARXEDRUMDDwxEgw8cDEgz3mjYHVS/GYGTfQhp73ul5X1VdVX3UPf0bLvx9V+anQwxYcxzjaqEN+CdMBok6AahzFwXivMI8XuIjP2ckkvobB5rwZRjsJXYn4+QCdd1iLqhOCc1gZ3q9iFnPh/H4Y6yYHvXgewu4kW4GTkYWpsEsYrrHvH+T+dIC5m0MttZiJVFzAJ1zDyBAStGJ/B2Px/BHyKjuoo0CzGI3w1uAYNsf3TprtMFD08mxFBHV2sDQUR/ELD0L+GB/jWzbSjZxXA6JqY0kWTuEWVsV6BNvDYRnrcQRnsT/2SE4K2M24gwOLbhbsxZcGFZ9hQ+z5a6O2U16L4U48N0Xheom+M7Ge7uOgClt/dVoa61QyXtDXUYdunAADj5vFnEHr0lGgQetWsM2Agi+gbCXa9Rp73sT3+SQr+7r4kGTZeZYNLHCFZXifDNYpVZdTDYeOM7iXaNqk3gSeJP5/x5WgcatR6PHoo8PZQUG4pw+inNtJ7MLGIemeClsPs/B7QtccvXT+v2wQpNdHp7DrZ7PI7djcafREt3HRVImqrRRtJwFa6INOgxUj6bzpN+o+6yIrOmOZjcXBa2zDeayOTi1Kj/AtIZfeN2JninY5TgT6F7mIW4dcmTeGXJlPB+i8zVcmvMKOuPQnGgW8PaRprgewUo+5fpf+f/3b8hs1P7G9A8FQjQAAAABJRU5ErkJggg==",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAC+ElEQVR42sWXv2sUQRTHP/vDROKdBlGwiI1/gIja2qhBBU8Lf4CtYGV3jRjUcIKIiohgEQStLIyIFgpy+AMbBYmirY1lECTGu6BoLrtr8+Z4N5ndnTsJDgy7O/Pmve++975vZqC3Rax867ERWO8ZsBnYAayV8Uzm2sBTYClHsVk/BNSANdZ8C5gBZpVsd2Eo7xeBBZl09QsiFzsAmLHrBetbwDmRC22XNAoWmn7FA8CUh56zxrYJwRjwRVBFwCPgkwIXAt+Au8BP24VWCNYBJyWEqazNJKyHgARYBLYAX83iIwrdwxVMwCfKzkEdh4r6oxkZXwWMAseB3Y6kpSAZY6uvFp0fVGJXNYBMKR8W11WAl8C0PM+LXBlVM2GK3VNhiA5XDwCbmnuA7cAvUXBaFCSennC11ALazdxIFGcK1Kw8R9R3opIqsoBkMl9WhJZkXaQ90JKBGPguY2+BOvAZeAOcsv4+sVyceOTJD7ERyTuB9CFgQuLekGKE8khqxw7YC4wDm4A54JVUShw0Nd+jwCQwD1wuqKrL6rZxWSgheZBTYJ4B69WP9dUMZQIHrXS4psVYx+qLMv5cgS2i6EA72C5l3OUBA6Lmu7uGngCMF/Y7SrCrHB/wLVxhn57Y6KE0EDlKwA4EYM5DaSpyfXnAZHmUs8gYbebshFi0beZ4QNvpuxmwj1XCuVjwWrLc27uBcPsGcLuAx2asqkDY/YXKk9CxdgNwB7gmO2TXxlGlpF5w6tGg9snx6x5wEzicI6d1TSg7NT1RUWWxUrLVBiofmgVUdLWq2oyqGkBivZft96iEzdQzLWHJMjuxw2W+yZP8QyJ3bcaW2wLJ6CgnBxKPOhA4aBaLdzp2KI2RBeWFbWJokD/URzLdzPdWBbKtAbwTHkfAMeAP8FEEzdF6HrgP/C7ZB0aAE45j+U5hijmWv7d3ukmPC8Ulj4vJLQ89Z4ztWKFsyLNeQMWOBzuKZNrAVblhhUDiupyOibsGvZwOy6XD+3L6X6/nfwEktwnoY4UebgAAAABJRU5ErkJggg==")
IconData["lens_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABk0lEQVR42l3Tz4vNURgG8M/3x7BB06AxEeUPEF0bO1027JQFKymFZGOlrGZpq2xY2cgkYq9mdxdMUViYZCGEGdfCirl3vjbP5TSnvp3v+573ec5znvecqj/oZPSwPf8f8B5V4g4HsCvxZ7xF1aLGLVzxfzzCaTQYh+geDhY113Gz6g+6HpYwj/sh/IafKayiYG8UrOEqzmO2xo4k72B3mLcEOBUVNT7iOV7iIUaYrlMwha24iHM4ml3XUrhe1DWYQTvxYDmMK7iGx3gS+SdTvBjjxJPXWMDXquhCOZqQnkq8ihPxqo4iElQBKCQeD3iE3/HpRmHqBFPVhayJ2+MAyvyoyHXFmrpIdAVgEUNsxqYY9qBQ/Q9T54YtYV8WanzBsYCe5ZLdDtEIR/ACO9v0voc5fAoBvMLZwtg6X4P9OIyZtpD+I/N4g8Fd5jH+ZG2YTnRtdm1yB56mE8t4VzymdRzCnhzhcghXW7xJi+ZxKYAFnNnwmO7mqPALFzCs+oNuInMO21LwPY+pfM6zmE5uJUeu/gKaIm9CfqWx2gAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB8klEQVR42p3VO2sUURQH8N/MbhJ1FRUxJCIIitiYxkdhm97OQix8oHaCYCeifodUFoq1iOhnsEgRBEGjpYoYkYiNMYnZbGZszoTjsAp64XLunfO8//OYYnq2ltZ2dFDgZ+xhayvGUGOA5YZRhvJOPMQ7LMT+hKNJrozz8cRfwHvcxw4U3fAyg/P4GLvEj9jt9R3z6GEDE7gcvCvF9GzdC0/fMIUV/7Z6eBtw7S8xgtEwuIJLmMPFgKN5apFomegyvoadkTIJjsT5Jk4GrZNyPldxr+M+2jgr0Y9MrYbAXTzHnRAexPduGKpa0dahO0C/iLKZwhI+DMHoHK5hD97gdtAyRXkQ2zBftOqwKZFOZPAMHrX4iziGz3Gv28rtOqvCWIUbodCP+xrGI+o6HP+mXw55YpFw2p3wy5FP/qmGclRVekIn6OuQWQ/Qq+DNtZ67qZ/b6XArcwVuReeMRZSjeIonKSlwJHDVdMoiXuFUCFbJ8DjORou9xOPkuIHnRQQ00XgtEq3Tc4pwNjME5zqdN210E6Pfwi8np5Oc1K0INwJjApf1MLY3PPWHJG/wl+GwJYp+Hf1uNPczXIgO+BIRLeFqGmdNNg/hXhpfkzgQM3G1G2FfD+HT2BfKazF422sXTqSBsIIH0QRFu/V6AcN//wJ+Ad29my0Iy/6hAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACfklEQVR42rXWO6hUVxQG4O/MnOsjWGjUwoCB4ANEURCuIigXLgEloKCC2GshSoKFrWJt56Px3VhYCEKCIRaCKASC1S18INgoNoqI4AO9d2Zs1pbFdsYqbjicPWuf9dj/+tda00z+O4AO+v7f1WDQxqaP5TiIFeiGbIAzuFkFUfb7sDv2DWYwhdN4iaYNhdW4gx+HRPJqiIOyDmJ9JduBvdiMl21EeTSMT+EcPmE6oroRir1kZBDvPZhIsgX4I1D4HUfLDVbFB8fw5whMB0P2T+KpsT+BtQXLImzwES1O4QXOYyx9V69OfN9iTrzfhbzJDvqRoE+YHddbjP34Jc7b9HQTOWaqpxNw9rODeaE4Gx/wT8hv43mcZSO9gKkZcasu5gpFOBlZvxeed2ANHgRs8BO2YSEe4+9EhEFi2A1M4go0UWjfLBZsx+UwXtY97IobNqMKtUDUTbgWw+V2P+NqGJ9OuRrHxRFBdYvtTuJ4L9Evv3fihzA+Fo7HIuJfsSz2naTzVZK/tZakVqCidSfYZkTCv8DQSTjWSXkU5zNJ1k+RPk2y7Bz6uQ56lfFefHg9qnVWMlyoeCmS3K1g7dcQHcFfiSVN4vkb/BbNsJy9w1kcTk2w2FoRdbQ3Q3QgkjUeh7kam+D9RHTd+QHLswrK0uK3YWvYuFocvB0CUW5sJcr7FcUHQ3QKI9/XSS44tlVN9KpBkyu36GVbg1wHbcWKsdRvhq3+kN9FVnTmZDYWBw+xDsexKPWfGdzC6xR5JsFSbEq3nY9DEf1U6UVNDJy7I0bmpZi9bYqy5OQ/bBii8xhbysgUXXNjzNiVVQKvjYAHLsTMLvmYrod+873/tnwGAKXITFmuo9EAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADXklEQVR42sWXO2gWQRSFv9ndmJiXQRQtYiPYimjAyibGV/CBoIIIKQRtbDSlEjQqBhVML/gotVCUpDBFRAUDEkVLbewMikRNgqLm339tzsrNZHf/TUAcWHZ29+7cO2fuOXPHdY4lmBYCMf+2zfERmQ9OH9YAm4BWvU/0bRoYBio5AzvZLgH2AE3e9ylgHJgwtkR6cEAVOA+cAppznJyVTZQRSKh3A0Bvzv/TwFXgIhAA1UidGOgH+mrA11QC4iKbVuCC/A0AoVMOtAPvFUwI3AfeqI/efwZuAt8thBlLsAw4KmdV/ZtoWffK+W9gLfAxzYHNQJ3694ADNWaZFLybAgZz/hsCdgNLgQ5gONCHZjPAuKKuA9qAQ0CnmWWt5pQj9mrQmK9MsC0ptDbTAeoFXTMwCtzVvU92YQl0KhlXVQyxyzUnALxZbgU2Aj80wAkNEJdEIqtV/SWLPHFITFATujea59gkVegFkpQQsZSqLkUyMIkTKqAvejcmPr8DngPHvNnHHsRxiTz5Jh+h+rjOscQJ2tNa935gxswqMNBZ+nUB24DVwCTwWEpJBk3T5zaJ2VfpQMV5e0GebjsDfQNwGziYYf8IOCIHeXSd0wLTj4w0Y2BOo0+ExC0597N8Ftgp1gQ5S2EpOi+AdKAkg1ahnG+RLlQyuF6nILqAbtmHBRSdF0AtcUEzTGrYJcCussIVLJDHK0sM6mS34Bwo0yZLDFqV3YIQSIUhzPkpdTqSsxPi0XYkBwHrB1+KY6OGfksV8AnwwCScz4I64Kl2vSBDGa2fvwE4ye0gcB1Ybqok/2cH9JggfBaMiqJxxswdsAK4oaqoAXCRBu4GTsr4LXAto+xKA5gB9gM7gO3AKqOED43DasYecFzFCsAzYCgy9UDF9Iu2WmfyYaSAilmtxWxGLXY3jL1+mWooNM6cUcoilszzE2XQpSw1F3N+CHxxizzYnLI59M4M1mlSQoh8CY6Ezqy/lKmTGYPCBp8qC2xJxpkhfV5vgpy2AbxQqRyKRr+A1yabA22xd4CfNfaBRuBwRlneAewzZflLTHXyAbgEnNNgPbr8tg44U+NkdEX1Y1GN0Q98AsLIRNmve28BFWdLsKPIZloBXk6V0lZEKYTtgmuxh9N6HT5KHU7d/z6e/wEoPQvzA7T41wAAAABJRU5ErkJggg==")
IconData["lens_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABjUlEQVR42m2TvWqVQRCGn+8758QqauL/bxqJVsEQEe1MFeIFpFG0FC1tBKtcRGqx8yASsbbwAgxYWSjBKjbGREglOUkem3dhz4cLy87OzDs7+85Mo5K1AJyK/APYBJrcBeaA87n/BL4CDWqrrjm+3qmofbXJ/tLxeaGCuhDFqjqr3lCnEoCAUa+qt9V59VUwZ1GX1H31orqovlavBDhIFm0VEHVZHamzLdADBsAk8AR4DNzLv0fAAXBU+fWAaaBfOLimvlWnk8WKOpGX7qsP1Uu593LOqUP1BJ3UqBzXK8K21VuxjX2nkFQiDyIvBThS/0Z+XwUvmKZNXQ9TcyOf7ugPKp2VjbZSWAE+AbvAMWAihA3jN44JIRvqTIeom+ob9aP6rGos1LvqZ/VMqanqnYAHVZB6t6lOT30QzPV+lfpOzsMq1cJLE/1+bLvpDfvAVprjOfAhzfId+FYN0xEwD1wOoU8T8HdJ72VKVtbwP8O0Udn31EcqjVrSvAAcz4u/gD+dcT4HnIxuO19u/gGrIBI8r8B0swAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAACBUlEQVR42p2VzWpTURDHf/cmUWuUUsTS4kJRShfaja58EZEu/EB9AR9A36ErF0UfQCg+gwsXRShUXSi40JW2VqUmraZJfi6cWybXZKEDw0nOOTPzP//5uIVKkhNAAyiAn6HjZAo4Cgj0ge7hiVqo0+oTdUvtqF31i3pJRS1DUa+oX+NeJ2xW1ZNq0YwoK8AN4GNoCXRC67ILvAbawACYA+7E2V3Utvpdfa8eDxT/om31g7qjTpVACzgC7AB7wG1gHbgVXJYRvUhrmdYusB1+Wqgz6p66EXy+84+8DQTN2K9zWfFfqJvqrjpdAr3I1H7w+RB4DjwIFP3YbwLD0IzWsO0DvSrSknpuAkfL6otAvKZeTGgr5OerihjnoFRbsV7zb/msnknPHbGvCC8T+cMohyFwP57Ui/+/gFlgOfYbdftyTJ0ViaeZxF8ZDgbA/IQOGkE1rJonDAVexZ2DIH0YZ+vp7qh9aqeFVAoV4YtRtFnWEsdVCS2ql1UKtQ1sAZvA1UA0TCUxC1yPFtsAniZqKnpeAgvAXDO6pEir6TlFBFsZw7Pp96GPZjro1fjLyWmkINYQDoJjiOwdhLPTEak3Jnl9Jssx4FTlpxnN/Qy4CbwBPgWiH8C9NM6qbF4AHqXxNQ+cBVaB/TxgH6vbMVy7MUSXJgzYb+nedh6wRe0T0A4a/vsT8BvgUzqUfgODVQAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACdUlEQVR42rWWu2sVURDGf2d3LzeK4CMqKEYQTQojWIooCGKRxoAIYq+VEhttA/4LPkDxARaWNiKRRBC0VLG4ha9gJdiowSZRch/7WWROGI67K4geOMzs7Jkzc+b7ds4GSQAZUPJvRwBUmFICe4BzwCiQm03AdWAuSSLqZ4CTpgegD3SAa8BXICApSBqXtKDqcU8SkgqTSMpMvq7xmZe0VVIoLMtpYJNFvwV0gZ5lNWNZD9zxZfIUcMTZNgIXrApTwHTMqCOplDTpsvzbeVHSQNJDSWQOkAAsAwVwFfgC3AZaVvOqkdn6AhgyuWT2gHMsDaAu0LbjbQHOArvsfeFm7sjRT2Zm5Sx9gHXm2AZ+ArNmfwZ8tnd+k4HVPNScKgfWYI4AV4DDwCuLPAnsA95a2QC2AxPAMDAPPHZEkKPwDHAUuL8CfTNgweRxSd8SKr6UtMPWZHV7RCW3GdzGhcmdkpZs066knqRle56rCBBsr8yzaODqSiJPAGutHC0ra8tKcgzYbXrmfH4DuWlsc62AhNaZsY0awFdBzhztlKx5b+/7zla6TD85mw++YvsDwEHSekkfreYD++LjuOEwbAT5kqRHkoYT9kTwxiQ9twCStCjppqS2rfFAj0qalXTaB4gZTlRkFJw+LumQpJGKbGO3nbK9nkhaxWAxYRFJ54z9/03yxarCJzLyRwpybot9r8FTzpFBjpp5QhiZLfPGyIqW6zdVo6x4jrboM+TZGAO8A/YDl4HNrv/0gafAd5c5Th8BDrrTbgDOW/ad2IuCpL0NV+bdhivzRY3PB39lYl3zgF36YwmAD2rKA3AHWHB49NJLP/zv35ZfQKMFgwzAqlEAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADKklEQVR42sWXzYuPURTHP/d5HkYzBomyYOMPkLC18RJqhoWXslVWdrNR8tKQhCRlpVhZGIkFpclLNpSG2NpYTkrjZSbCzO/3tTlXZ67n93uuidy63fvc59xzzv3e83aDJFwrgRb/ts2SUbkfwX6sAtYDi2xd9m8SuAfMdGAcjHY+MAj0Jf8/A2PAuKMFSUFSIQlJJyVNqXM7bnSVjb7HtQtd9n+WdNToCklUQGEnHwaONcDXlwFxN5pFwCmTdwYog9nASuCtKVMCt4HXNsfW3wPXgC+zIPz9ChYDB0xY2/bKrnWnCf8BrAbeRfh2O5hu1cD7t/pdJ2dAEoVpv9CdaMy0ngcsAfYBm9wpm1ow4/Z9gfF86Qy7P0LrLR2gx6BbCDwCRmw8ZnRlgwIyT0l72zzEX9csBUhOuRlYB3w1BoeMQSsTibrWThT9FQdicJBTatzGXvfdckZVJoooI4iVdpgQkSxckChNoQ+29gwYAt4AT4GDyelbCcStDDv5ZDJKmxMkBYP2iN37MDDlTlU46Lz7bQG2AiuACeCxRUpq3DR+LwFOAB8tDsw0uU1pY7B5IalX0s0Oke6+pKVGH3JcMw2lVc3G4EOnpBETNp30H7b+wClLDa/Kh/LcABKR2OiE17WoxGCyr2MvMt0nGtb2mhBcF4535Aau4g/9eHkG02B0NCg7JwUmMpi2je6PEIiBoeywKQod7ZAJSdx2tAMCXg6xIMnt0arvOIOr84InZuVFrhsG8+2Lkq508eO41u+USNtDScuTKsvvXSbpqqTzkhZICpFgj2My1KXs8kpts/LruqRLknZ1oPO8jjg5g7Eki/XAjJt3S7XB2cNoF1esa/0uGfX7bNhK5k35HmewcmO7wUt+k1PVuEuua87l/VCkwa1KYAvAtEvNdUKVEYjSqqkydKbTq4xCphwKa03QXF9Iqnm8xO81TslJr8BzK5VLYC/wHXhlhLG0/gjcAL415IFeYH9NWb4B2OXK8hcxEMWMdULN7XTGy+hyBp/DMVtWTsthG4e6uOJ0hnd0o5kEzgFn44ssuNdxhHClwTXXx2kPMJD7OA3/+3n+E86sa7NJ0xTjAAAAAElFTkSuQmCC")
IconData["note_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABCklEQVR42pXTTUoDQRAF4K/HwY0LMaLoRtzmGiJkJy5c5xoewNt4geBRJAFXrlUU408y46YamjFDkoKim+56r7tfvU5IaDHEWcyT/9EW8ymeyrpbfEbRJvmKcQYPi40lmjW5iNoXHNY4D6IGlfVRBcEeTqs4Vc+7+yLr1lRbArsk6i0ATaFVyjevtwB39dlBtQlBG+BZZCo69g6jLMiKfi9jvAuSAfZjPMgn9BFk8Czq7sNsH3jDZRZyVJikJMiGecBRZ/0qe6KOq6UgSB3P5/cv8R3715hEAxYVHvFbqJwiS4/sxgE3JbhUeoxnfOEnch7jBMe4iNq666Z87QFOVrRxHl83/4Om3PwDAhBnI5vChy0AAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABPElEQVR42q3VO0oEQRDG8d/0Duq6qCgK3kIQPIN4AtEjGGhs4iMSDDUwNDAQLyVsauQDFR+zY1Ij47qszrIFzfTz31XV3d9kftokOprZM96qRoYU9UNsYTb6sz9AZZRHXOO4PnhUmzBqOapgbXTxiQ/0GpaPWNvFVI7pgLZip6xhDluxpo1OCsi4rEzGbGMH5qOGNqBejgos4iDqd/mbNQqwgr0ErBffh8rLBdxFozfk4hbxPcFyOJPXrs0cUt4wzFPsYx0r0d8L2FV4+aeH1YsosISNAXNuMIP032uT4R33WIsNnmLsHJvRLlPDp5YCXIZHF9it5bFMcVqvEVLxT2Vp4Qw7Ua9SJQXsMgbymhZmNb3MMBEL50P/9vph/QJ7gO0BAlsp0AtWsYjbiKb/1fzK37BfQKXOxbAkfwHQZX9FmiOfcwAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAABYElEQVR42u3WsUpcQRQG4O9eNxs1G8E2+g52goVFnkEI+wBpkgcIFr6Aha29topWVqJPoCDBB0iaQBoJSUjUXfdaeAaGkN24924T8MDcmeGc+f8zM2fOuTxIYfJSpE+BCgtYxwqe1yCt8Aun2MS3nGQRn8NoEu0cc7mT26G4xl3Ddh1YH/LtXWQGTb3vB84RlEHQysaTkBLPTBh0KNMTwf9LkEKyGmXUagBeDFk/lfetBuBX2MIJfmQ5Ldnc1CFIAFd4jY8B/DLTDdDB13zhZRj8K1X0ot+IdW/xJXbwMzJohV3M5Hf8WIKkX8Y0vme6QfSHaKeaUNYpIviN2QAa4DZ0+1jL5lXZoFrlO2vjAN2Yl+lOEsFNeDKu9CMc9/AmMIocKxEcx7j3yKKS7qMTx9L9G3i+3XmcjVFUlvAKO+FYMSwr5EX/Bd5hNSKkGPHI3uNTHJE/HtnI6Kj9ezJM7gHkVaxr8NJ5SAAAAABJRU5ErkJggg==",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAABuElEQVR42u2Xv0oDQRDGf7e5RCuxELEyT2CrXSxE1IgQBVt7wXfxOcRWDGohWMUXMF1QazubmNwfm9ljEi7mz+3GJgPLpdjM981+szOzMGgl/NsARqB+GyABKsAOsOmQUAx8Aq9AT2ENgAMcA20g9bTaQH0IM4vyUFilwrjveMXiOwEONHYALAMd2dD3eALWd0cwsxSoqchTz8ti1LQOVXU8vs3KXNUEgqEb4dsyPMM/24LAgsCCQOjBZ6qKTZ5Fap9zArE0mNIEQS+5JpAIcAS0pP/HI/aF0pozuyjYCW2DeQS25p0D9tifgSMV9UqOfxt9AHwBaegg4YyMWVcCvg5cA7tAWTWfRL594FwImKISRPJtKaDbMVKd6BLg4gSQhANYBfaUDEZF3gMawINIFrssRJZIRc16RkkUAWcCHurbYTwUIZ1wVvNToCngUV4pTv+oXEWTswHc54FrAh/C1ji6lgHwI+DNUeB6Ppt1LLd7b8TXGvANdIH9SWqNkdUFLsVZKPpFU6xEJaGN/Glc5HlS1IG3GUrxnfx/A9iepsrmPU7L8jitTvA4TcXHO/CS46vY03keQ84v6QcMdd5r/wYAAAAASUVORK5CYII=")
IconData["note_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABD0lEQVR42pXTsUrEUBAF0JNsEMRGBEEbsbDZ2i/Y3kJE/8Da1kps/BIrewsbf2FbQXS1UVsVC5HdJDbz4BFXyA4MTBju3Dd3bop2PCrQYoitqAt/o83qBzyjqKJxinMs6xefOMFl0Y5HQ9xFo/mHPY8GA3xgp8J21ih7sJfx6hVslqijUegfSbemXBDYHaJaANAEa7pSvciAefoMUPYZ0Ab4MTLtX+Or6sl8ET5ZDeAghryXPcATnOEKL3gNF+4mJ3Zt2rXuBOs4iu8aB7hNGqRTNtl+3f1r/ER/HzdxgFmJe0wzlYvI3CNLQXCYg5Mtn3CMt2CZRqZ6FuA9XOdgKLLfeQ0bc7T4DtESYZM3fwFK4k5yFbpS5wAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABRklEQVR42q3VP24TQRTH8c+OVxDjQJQq4hQoBQegQjlBFDq3KaBOEwwVQlSkoIOCAokD5Ba5Qg6QKgbhCGTvpHkjLZZl7Vp+0tPM7Mz77rz585sqX73QsocY6Wd/8Lc0aqSov8UJnqAKX2c5/Bd+4F0BNpjg3GZ2ELEZk4Qhxlhg3vpzV59H7Bg7NR4FdBADqp4zHETMEKMUkG1ZTrZsWwfWm6a2op43BS5iI4pV7cltAiywWcCaKKd9N6WJ8gOeYi9u1R52cYhp3TPNjzjDSzyL701Av3cF5jgNDT7hCJdLY37iBqlryhX+4RbPA/47+i5wHO2cel61FOCMx/iC163rl1Ps1l2sx6KjIAzwGadRb8o5TAH7Fh11SwuLlyweROB+6N+bZVhbYN9H+9UKgS0KNIu+r7huncH/xKXq8QQUdV6sW+R75hpjew0no9cAAAAASUVORK5CYII=",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAABaElEQVR42u3Wz0pWQRjH8c+Mxz+FXoHRRbgQDCLcdANBunPjIu8gvAMR7R7aFtG6qF1LN92ChOjCAq3Q7J02z4lBfF9533M2QQMPc848zPc353lm5jmpHKxCQtFvSyhNBV/Ec6xgNsbHaQU/8BE7+IbUhPMePuF+DytfxmOs4iyH8nbALzDoaBdYwjOUHKoPwjmN3NGaYD0SA2Iw95jgHIvtFTpU6b/AvytQcHXbFdN0gKch86fqvukAP8UePuDs2oVZ4kSPLdACTuOu+Rzghco3wDyOJ8nB7wC+CPgmvoQd4RDn2MUd5GbCTfEOc9iP1dehexvCl0h5giICP3EXMxGSy/C9xpPqveQu1aqyGbzBery3ZeDvJ7d1YNx2FdvxFZ4GI9WsVuB9PP+KRN5mJfr5CMv6TfBWIEUNPYhaPDXCmuhzwF9irUrwYNhJ/hoVaAsPY4ekEYfsO06wUeXkxhCnHn5bRs79AwOycmEh0pkBAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAB40lEQVR42u2Xu0oDURCGvz3ZaBrFytKQTnwALUVsvCFR9CEEO19DsFIfRPGChWDjBcRCUDsvtQ/gZbNr8x8ZL4kJORubDBwWsif7///MnDkzUXY5gbECUCNf+4IRmxdOL3qAMWBIm0NYDXgCzoE3YaWWgP9hFlgHhnNSfwesAXseMzYumQJ2gEhk0sDgTsJ2gWngECjEAioBWwJP5BmXgwf8t7eBEeDVARkwClREJs4xAb3gijAzr7IsIin5WyqsMsbNkVan7BPP8c/WJdAl0CWQR9XLTLGpV479vuAEarrcCk2I7g1NIBVwApzp/q/V2RcDtyEJpMqnI933153MAe/2Y93zXnX/L9/36iPgGcjiAAnn1GatCnwQ2ADGgaK5fFI934FlEXBxoLhfATcC2ASWGuyvAqe2JWvXAyjhAAaASRMGZ5S/CfzQdsYu4NlHHbVvvZ0JUQIsCjy2p8PlUISsu33MF4B9gSe/leKsQeVqNzmrasN/gFsCj2LrAh3LCHgV+H49cE8gAi6AexOvdk5FSeDzwEEjcE/AAS/AilznW+ekhZWaJPTKj/4Ct/OgU4bOqUY7/fmvVdKzz3hgphnln+2xmY79mS1qOC03MZxmCuEDcPJNWFMzRpTDeO5aGXA+AGwtjYV+9bgSAAAAAElFTkSuQmCC")
IconData["note_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABFUlEQVR42pWTsUoEQRBE38wuJiaHIGgiBib3HwcmBiKaGvkPhiZ+jamBid8hiKdmpp4oitzNlEkNDOuKuw3N9tJUFd1dEyQFQMAU2HEd+B2q6gfgGQhIQtK5pE8Nj4WkU0kESVPgzsz5D/U6MtAAC2CvBXarRuT/iB5nHdiOQHIjMDzK3nIcCeyS0I4AZKuWK6UxBH37aYA4hEAGz51l/gS8twOVL4ELYGJgY5JXJO3bHLljluTv3Ga7stk+JL1JmkkKbY9Nu9Z9BDaBE/8n4Ai4LTsop8zVfN35E/Dt/iFw4wOsInAPLKstB2ftkTULHNfgYssn4Ax4scrSWeqVwQfAdQ0GCNVz3gC2enbx5adbBHPd/AFV9b+TMaq1aAAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABSklEQVR42q2Vvy4EURTGf/fuhKy1NoRCPIBSSDyDeALhERTUGlYnSgqlQiHeSKXTqCyxQjLzKXxXJpPJZmftl5zcc/99c797zzkTJFHCLNChGT6Ar9TJgGj/DNgHFoBgGwXZ3oB74Px3VEJSX/9HXxJBUht4BNb8xVZDybnVPAPrGTAHtE2kMaRW0fKeNtCJJpkWFJkypk6YTSqtxtekhHklEkL5cJMQJrKhyQq3g6aPUri9AFaBnrOqB8wDm8AgayjzEjgBdoANjxcmvQMGSFqS9OL0KWpSqrDlklYk7daseZDUlRTHlRyAb+AV2Pap3j13Dey5r9gw1aKJBXSBG+ColH6Kfq1P30deKkujrAVcAYf2ixSH0WS3nshKtTBZUjHjjYuuf8dVMoAg/YXOKXBQU2BTBRoCW8Ay8GQ11awhNPgFpOqcj7rkH6CJ7HTujTzgAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAABd0lEQVR42u3W0YrNURTH8c/+O84MhnKLvIJyoSjJMyjNA7jAE0zeQJJncE08gHgCbuQBSJKbSYiGmfNzMeuvPzlzOnPOjbJqtf97r/Z3/f9r/fdauyWBhliuNGQ0gJ/EBs5jpdbnkeArnuE2PqJJ0pKcSvImy5MXSY4laV15voXT2MJkQd3CWVxHuvq8C2U8iG5BHRXrklpQi90SE9zVyy4VOtXTfwf/roNge1aJGS0Ab1P2HxiOowXgm7iLp/j8R8FMnei5HfSATVzGywIfHdgmWMOH/eRgp4D3Cn4N70rf4y2+4A4OoZNEkldVBXdmVMnefi7JapJPA9ukxsdJxsVt3T6aCHzDYYwrJN/L9hBXBvN0i3SrgY7xCOs179vArxz0fWBe2a7f8QGuFqMNWb2DJ/X8oxI5S1PjWoVl/W/w3f9ut2UeT/J8jpZ4JsmJJPeTdMXoKrG/aUvSx/MIbuAiVqc0/f6Q3cTrCtGet5K2hGvLnnt/AsB8c+MdCHFEAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAB40lEQVR42u2XvW5TQRCFv11fEyqUClFh0eYBTElBQ4IUBQQPEYmOB0nFmyBClAKJBkiTAskuCanzACRc70lzFi3BdmzYGxqPtFpLO77nzM/OzgRJFNIDJnQrv2E0xUH0wS3gIXDfyjVkApwCX4ALYyUAJCEpen8qaazuZCxpq8QMkrJLngDvgGB2qbLro5eATeAA6AVJAVgDRsADoL0SmpqSv/0N2ADOM6OhwVOH4DnnkrGGgKIPBiaS6F6SsQY5LjjugZuTX3iR/ywrAisCKwJdVD0VxWZWOc561QlM/IT3FjB6rTaBZOAW+Oz3fzJDrwHGNQkk59Mh8Br4epM5kN3+we98tvrOlO9n6wNwBqipkHDRbdYrg98F9oBHQL94fJL3n8BLE4hNpbgfu6EJwBvgxRz9HeBT7gtreAAnHMA68LgIQywsvzD4QdkZx4p3H3fUufWORYha4LnBm/J2xA6KUOnuHPNnwL7B22mlWHMq178m54677T/ASwLfzTZWupYBODf4/izwTCAAR26V4yzFJW7FbYNvA+/ngZfDwg9g167LrXO7xEpFEmbLD68DnzaabUka/cXI9db/vydp6N+N97krFNNxvrN9D6eDBYZTOYQnwMcrnl1oxggdjOdxmQHnElKNcJUts5pfAAAAAElFTkSuQmCC")
IconData["ocr_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABWUlEQVR42qXTv2pUURAG8N/dvQmkEYwhGkREQbAKaiKLWKvPYWNnJRZpxMYnSBXII2gaa8FWIulCisSI/0BkRUXTmNxdm+/gYbEQMnC4c2a+mfnO3JnGX7mGU2jwFrvRYYxFnMn9E7aLv4fVgMrZCLANqMHWBGalVF6K4TGuYICz6CdBG/0ibuAq1hOzAHfwG5f8v9zCIS6X7FOYw5tUeBRgod+FySs8CbZF06ZZG3iHEWZwoQoWex/70bfxDJ8dV0qVXu4dbmJtgkEXBi9wPzqM2gkAHFQzUJKXJ3ys5mJUFTieLOJ1Gge38QPf8QsvMZ2uTwczwCZOtxmapYzpe3yoBqWX5xxGb/KU81jGbBtgh2G+O3jwD6ZdDnxLD8ZtGtPHQzwPzb1qWcY4wnWcC5t7STAs2VfiKIvyNPZ+9Tc2K/9P3K3noCzGiQR+Cc16nedxMvchvqL5A0fpW3l9mqezAAAAAElFTkSuQmCC",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABoklEQVR42q3Vy2oUURAG4K9nOhPMoEGEca0Bt8YL+DZeNr6Pa0FfQ0HQjSYgAREEwSsuhAQM0RiDyVzc/C0nTSdGSEHRp0/d/6qurhykIWpU+I1d3XQK85hhjJ1SWGERD7CBn+FvuBydXhiuRNbobcR2EVWdKPdwC1/wGf0ob3dkt403qWaC87iTgLebMrfwEQsdDuoWt2khtlsY9jCHAdbxqyitoXGLS+rFZj0+5poGyEUVCOZxM+VMCh2YBpI1PI5sUPTDMHg9Ly4vxPFR/LoI8iI+hk3k5YD9ocjmOs7GuMyweX8f7GAJp/HKSVNVgKsoZ4QneU5bjZoEw0cZk1I2rY8IVLWCzuJ8kvOkBcEB5f+pqCq6fWjJ1/AD74q7GzhXlPg9kzDryPxSmrLWjM0OVo4xNlcj77ewX4mPYV0M9KCI+hV3M9jjfHKbeFtgWeL310ddlLCXcz+r6/4xcOwFkr0mQI39XIyy53Y7lkM5MrMiiUlsRvGx3yg+jNInrOIlnuJixz5cwrPorMZmFh//XLDLhyzYzY4FewZVddK/gD8zUYqvMZeNSwAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACEUlEQVR42r3WO2tUURAH8N/djfiEEBEUK/FRKIIgiJ2KlZWVhYUgVoJCsLCwsfETCKYwpYX5AhpMGp+VCkIstEmlhfhCkKAxbO61cE4YkrthkejA2XOYO2de5z8zyx/qWHuqyk+FBntxCfvQRR3825gMJ+rkUI0LOBNyFXp4jTF8zEYO4GsILl93Q+lQ8q5E/KLPnVnsQDUUjOvYGtbHMR8KFjGVzoWa2M/iROINYxR7cAXXyoWZCPl0n3wO9VltNBrOTOawy1vMB68bQr343hvgUTeE3FyksMoG6lBYLVN6GPvje9WitOT8GT6EXCd01dnAlvC6SvkewcsBIfwIJ1M6u9iUDYzhWCgsNIebEcViH0MFtncSbxr3MeF/UJVwXaXiKsW3EdsTLNvuN3iXZKrQ16QIV1yq4l1msBDoWmhZP/ErakfkfgW+B4mwDT15r9cyRVUKv5zft2RgVcNrTldxD9uSF+sCpk/xGE9iPcDBiLqb4Fv23dG/zmUDsxHqqWRgJPDf1i3Pt7xhOV8MmYeZOZeUFTR8w5HUKgr/e0TRr0ctxvqRDZRwm1Tq8CpWP+qk1OS+tpS6zGywPrzqrQLnJs2GOkVX7mxO+pYuvsUh3MDOKKzSWafxOUEyQ3UXjieID8eg6cTwkkfml78Ymc8HGZnwBkdxOYZ+J3k7sUrRjMcsr5cN/Vv4lDvBP/vb8hthNrGMoB1UVwAAAABJRU5ErkJggg==",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACtklEQVR42sWXMWsVQRDHf3u3eUZ4LxJbg4WIvZhS/AQ2hghWgn6EWFgIUaMWCoKC2Bmi2CgGEcTCWqsIFoKFoJXWxrwQA8m7s5kNc+PevX2aIwvL7e3O7Mz+Z3ZmFqotp/1WkeHMuASmgGlgQuZLWesDr4Gtmo0Dfwc4DXTN+hrwAfiuaHcYMxlfE0FlTb8ldD6iQJi708C/JjIQmU5DcrWBMfT7CQo8TNhnPpgjmGAK+CrK5MBL4KNoWch3FVgUhCoQGhNMABeBA4q3AI4DZ4CB9CPAj8A8o7RbbtEBl5WcGZTte+pEKzI/LrCG3hF0siE9F9qO4h2XtRXl2D1tt1LdiDGBbFt6gHd7hJMOjFmQPcfsvFYARWhbCRwTrQtzfWO0DtgEPpu1wtDtKJCrE+YmaAyAC+LdHWW2YQiUwA1gQe3/lxyvgoQe20B1Uuw4arQ7FQlGFTlehLwBbkv0WjJ2BLgumk9Grl9d25CghDr1EnAUWBeZjr1uTn1zY7+25FXkpEKwDzgnJigSodsAngO/aiJnUgsOczMhvsf602FpPktUJPtHyMtUH2jLBM/kutWawEVqgqJlJ6zI2c176BsiYqNGDtgv1U4XuAz8NHY8LMHooDFBcLbHwCuV++uQnpSAtw5cAX4Hglm12Zw6UTjVoyHevqpCtWtAZ07xzGrv7qr024148XvJbkUku5XAWylWsyGQBzmDIMcrW/lIDgjjReCdScch7RbAJ6F1CVmyIsdHYMtqbPhlF+59Zv3CmwrFKSh9hLnOq0s17yKRzwtSW7YCC0L6CoUTQrz5H9HPlm/hf1op2dfQHwK+qaLzhZTlzpTlT+QKNZXlPeC8KctLKcvPxsryANd8QnK5l/AweTDKw8QrLRfkeynyrtPxPSUH1LU+cFfJKlIep5q5lcfpnj7P/wBUGgREDyZOYAAAAABJRU5ErkJggg==")
IconData["ocr_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABeUlEQVR42p3Tz4uPURQG8M/7/V6j2ZAfGZLkH1B+ZWFvT/ZWZmOsZGOhKKxtlDI1G00Wg7JWtmJhQRZjRsYo6SsUpcb7fm2eN7eJlFO3e8/t3HOe57nnNOZnxQ5iGxq8wWLOMMZ+7Iz/Hi/RFAxwAzN+232cxBBtEs3hQBVzEddLLmdwGQ+wEat5LPsYpzCFHziLa5gr2I413Ansv9lyFtzFaWwuqbAhiZaC6FICm6wWBU9wNbGl12AR9/AWHSaxr3os98Mg6CLgAj401S/8l5VUGcRvcQy31iFog+ARzlUCd2VdAHyveqBP3lNYrfqi6zUYV0ngOU78A3nXJxqkw55FODiOr/iCb3iMidCdSMxRPMVUwW4cSpuu4B1uB9kgdNZybkJlLw5ja0+hxSj7K5z/A+y2ovk5NMalatsLeBiYr/thSYGfOII9QTOdBKOCFxmMKziTCgvp/WGvNm4GtmgzjVFjfravsgubEvAxMOtx3oEt8Uf4hOYXKEVkjijdqO8AAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB40lEQVR42o3Vy2oUURAG4K8nnQQNRlQYwWwCgisvSEARfARfQY0Krn0Vt8pEXWXpNoIrQVxISPCG4C2IEWYTiDGJmUzPuKkOx8NkTEFzblV/naq/TnVhviWRCZQosINtg+UQxtFHF5v1QSOMj2IO37CKH/FdSPQaMb+YnK+GzVxgFGV4uY+b+I4VjOA3NgbcbgPvI5oKJ3ErHM4W5lsT4WkNZ7GVAZTZuputD+MdjmOqgVGMoR1gjQEA6ZdKI2zagTFaEyA2ikjBOG5EOFWiA71IySKexdlYnBUlOqH0J8AKnMIDw+UtFmK+ExidMii/mhGwgks4ljippV5/Tvau4wg264QvZwbw2sHlS85gIwHro4nnMfYyoqrI4QJms7NeuY/HIgmzSJz1ArAfozwlZcJcKm2c+4+jXhbVP4Az+IVPicFlnEhCXMfLBCi9+ZkgZbGMJ/QCb3AllKbxasANZ7AUeati7OMJzqNZJgU9lnj9ibtR2N2IZA0fk1ym+dvDKJP4OzEfiUJ9eADC6pt2agcldmOjGX1ue0hzqDISqrBpBsZu/VKeRk19CIbr9nUHX7M6PY1W1r6m8bh+KQXuhfK1aGH1+5wcEPJkEFA3hC08Coy9BruO20N+AWmdLmFqv1/AXzUBkXkUJD+lAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACQ0lEQVR42rXWy6vNURQH8M8+53jfkkcpI3kMiJQ8JkJKZkYGxMTIKzIwMDHxD1DugIGidBl7hJFXBlIGEiMSAyEp3TA453cMrJ9Wp9+9F7mrdnu3fnu9vuuxf8WVC9BC5f9SQb8ThwpLcQjL0A5eH+dwc8CJ+rwPO+NeQRfPMIwPKJ0QWIGHmNvgydcGAzUdxLoB3g7sxkZ86IT1k6H8Gc7jR1zu4XY619SPfRe2JN5sHMUSHMOJHEFt6FpDFJ0xcH4dK1OF01iVBUusH8Frh8fd+N79g6ROj3ujAWfJBqpQWAaUrsHy+F4alPZjPcT7uNcKXVU2MBRel4T3HDwJgYnoLrYmONuYmQ0MY1MorGkUZyKK3hiG6qq6lHh3cAMjv7D/1WiTRp3UOCU1V4l9BhaksmzsVrxNd0ro66PqDIQq5WEIj1KSmyCqobuI/an6ehPV96CxpurJe/UvEI1iQwNENSxVOr9LEZXkWCNE2bPvePOXee1nh2pcj+M65icvp0SZPsA93I91CytDtp101PvimF97M0QHYkCtTcNtCEfGSO5VPA/53sAI34btmIrLndRUvRRaG19iFC9PELZjfN8aZ0bVVfRtMMntMFC3OjyNNRa1UoQ5n7+hy8w+poVX3XHGdT/BUqXoaplZSd9vwZdYjVNYGGO7nqx38CmVZC7VRdicSnx2PDSteLwUVy6UwPkB5jXAMII94Ux3IKGPsb5B5lV+MuFFNNXhePRbyduRcbr1PD6npqsf/bP4iFIm+7flJ8xCrfRhGh7jAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADGUlEQVR42r2XPWgVQRDHf3e3iRGSiFYWwUIkvRi0EQVLsdEgWIhEsbMRRCyCxMQvIhis7AyJjSgaEcTC2hQhQgpBUbBLajVPYozv3dn8Vyb77u5dvhxY3r7bnZ3Z+c/XRjx5hKEEaLC1tEqGMwuRFnqAPqBb3zOt1YDXwJ+CgyPtbQdOAJ3B+iLwHpg3e3H6EwEpcAO4ksPs6Q4wKL56zs3qwC3gagF/DRiTnBjInCYNYEijjDormLhsT5dkpMAIkETygR7gq26RAC+BOSmX6vc7MK5b/DNhDgTdwAVgh+FNgf3ASV22AewFFrwPHBR2AFNAf4tbZiXfFoEHBXwvgFO65CFgKjam8QfMSusOYe1HuxjjFiPR3nbD26G1WaNsl40C7+kAbTJZ3ThalON0ZdQIYEFntoXfXY5J0wLz9krr1ChbBE8ELAMfg7U0hMwFIeTnYdI4DzyUWeOKFsiAm97bdX6THGccx86tZwMcFo5ryXYAR3KS0So5PhG9AUYVwxMBjgDD0nxnQQTk0RJwT3N/6wlgH/BTMqMoqAX/nZwxdRLgtxXUJMdGQVmYbQPOCIJWUWAheAb8MGHXJMdVsFAduK4itFY6Cpw19aaJ4ooHxes0eVbVB4qobqLg8zogeFqS3JqcMDabQ81/A5MbcL6sSI51wsYmRVReRqRIjk9E24HbSkTXgG8B0x7BsCuAwHv2JPDK1P688EMQjioRDQK/nA44DlzWpk9qm5zxgyFgoOT2x4DdKkB5zYqvAQPARX2bBp7Hpo3y5bczB7tpHZ7mVLcMeKtmNW7h+V5Ow8txBiuXUwP8fBx4F5TjzDSzH7Q3qlAlV8lxAUZFMR8BXzYh7uPQL1zQoUTGlC6HuVHSD2Y5+d46e2reFFmoQM1Y4YA2L28g5usFCa3PKFmzCswAK9K8X0VkzmDs2/LHCqGytrwLOBe05Zna8n7Tls94BRJgQXlgWIed1gipV+GalLyM7gKXWnRLI5KZOKPliH7LnmZLFWsAJU+z+0ZWajsib8LwcWqZt+Rxap0n0Yb5DRScFb2uKj3P/wL7zPEu4QO/QgAAAABJRU5ErkJggg==")
IconData["ocr_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABd0lEQVR42qXTPWtUURAG4OfuHgM2gh9oQhBREKzEGCWItfo7bOysxCKN2PgLrIT8BE1jLdhKxC5Y+IVRQWRFRW2Mu6+Fs3JdLEQHhjtz7pyZd+a80yVRchJ70eEFnpQNwXHMl/8Gm+gkGSS5md9lPYkkLUlX+mgmZjUJSZbr4HqSE0lWkiwmGVaCVvaRJGeSLCVZqzsLklxI8i3J0ar6N3ouyXaSYw1D7MA+PMMSrlWvXekYDQ9wo2IbulbDWsdLTLATh3uX1fkQz8vexB287Xqv8E/Sqsqg/DHO4tYMgnEhuIfLZcOkzQTA1x4HpsmnLbzu8WKC7r9bGBTDHtbg4Dw+4SO+4D7mqt25ilnBBg40LGK5aLqFV1grmINqZ7vsrlo5hFPY0ypwjFF9H+PKH9COS+FDzSCtBjPEVdwtmE9/LcvPAt9xGgcLzaVKMJpSc7WoOZXbdT7sLdNG7//nJBeT6JJMqyxgV0F8VzD767wfu8sf4T26H2l7JsPP9hhBAAAAAElFTkSuQmCC",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABzElEQVR42q2VT0scQRDFfz22K7okIoKBnBQhV00M5NuoIeD3yTUhwW/gVcFr8CQEQkIgiUgOAQUX/61m1915ubxZimFXE0xB0dNdXfW6XlfXJEkEaQIZSEAHuGa4TAITgIAe0B5YJCVJ05LeSzqWdGk9kbQkCUmFFUlPbav2Hdt3WlLKRnkNrAE/gUNgDLgELoac7gL47Gz6wCPgJVAA60hqSjqVdCBpyqeImmtat0/Z91RSswDGgQZwBFwZKUqvplEK+xw5xnh1AXghmYIJYNXp9MMegNKU7AM7tjVsSxnoetNvB0vAY+ANt8snYNvfHcfoJpfNssn+EU7zHJgJIIPC8Pw7cOC1ReAB8DHV6vDekgO5FbqAOWDXY1m7qL453AbWa7YyjwBKIc0UwEoHlEfqlPxryhGovC3lFeAc+BYcXgCzIcUz4EMIFE/+xJeyX72UtqQ9V36StKDh8sz2sfDGsW9bUjOHgm4E1F/Ahgu750xawNfAZeRvEKNqDrjA5fQ6wNu/4LEwJd0KIAM3Xphzn7sewTPhhhXmk/btAjfZzXHLNfXFD71qX6/8GmKdLgLvau1rHtgE2nc12OURDbY1pME+lJTS//4F/AGM2YYgQFcnbgAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACNUlEQVR42rWWO2sVURDHf2fviq9AiAiKlfgoFEEQxE7FysrKwkIQK0EhWFjY2PgJBFN4SwvzBTSYND4rFQQttEmlhfgIglw0Snb/FvmfOCy714t4B4YZzp55nHlukgRQADX/FxKg0kwN7AEuAnuBns8E3ALmGk5k/jxw2vcSsAK8BmaAj0BCUpK0X9KS2uGOJCSVpkgqTJ93yCxK2i4plbZ+Ddhi631g2Z5WwHzgM8j0DHA8nE0C08Bu4DJwNXv0SlIt6VTwMmLZgW13pyVVkuYkUYaEJHteOgeVY0qgw2CD7w2co4SV4YRVIVFZ6SFgn7+nFqUyPgU++F5hXXU0MGGvU4j3FPDCAn+Dh8AJ8zkCm6KBGeCoFWYYADf8iqrDUC7b2+FsAbgHzAIkN9rYoAyNk0JzJdONwLZQlq3dCrwLd5L1CajbyiwZJ1y+vyQtmzbxh6SfkvqW7TX1lSPMEzqqJ9LOOZbCsBs1RGnt+X/4943v2bF67EnOpXcFuAtsDV6sc5k+AR4Bj433gQOW7QUdme7y/Dq7GsTVZCx6Cp4MiZ7yTGmDcy0TNvMXfOdBTPLAzZTj1QO+AofDqMjn3/yKrhlVGb83+6BnA7nVAV4ah4W4aPRUHUMXDwWst1crHQ2ZS7MKcnXjNZuDvjXBt8BB4Dqww2M7T9YF4HMoyViqO4FjocQnvWgKLy/iyvzyDyvz2SgrE+ANcAS45KVfBG9nh3RrH1gKTZeX/k3gE5DSuH9bfgND4Cs4qTd5rAAAAABJRU5ErkJggg==",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAC2UlEQVR42sWXv2sUQRTHP7O3iREuEW0NFiL2YkrxL7AxRLAS9E+IhYUQNZoiAcFC7AxRbBSDCGJhrVUEC8FC0EprY05iwNw+m+/ou8nu3kbv9MGwP+bNvDff93OCmeGoBXQZLvXIyN1E0MQkMAVM6L9prgM8A35UbBzEOwqcAtrJ/AbwGvjkeMHMgpllZoaZXTWzjlXTgvhyPf2I/5Zq1m9IBpIZciDTya9o1FG7AcR1POOSUQDzQCvIByaBD7JPC3gCvJFyhZ7rwLJM8RvCnSaYAC4A+9zaAjgGnNZhu8Bh4HOEb9rBtFoC76DGqpMzbWZkDpp4ojVpPSYnjWNU6GR9Rku8o27tmObWnGOP+yiIng4wIsi2NSK827sItW5iFrTnSPrfK4BjTMmAo9K6cMpSwRuALeBdMlckfL8UaLkTtkqSxnngjmDNGiJgwPXo7dp/h5zcJQn/7j0b4ITsuJtsB3CyJBn1yMkl5DmwqBheSewIcE2a7y8JvyraBJb0Hk+9AhwBvklmCEkt+OeUO6hbif2GQTvkNEVgD3BWJugXBd4Ej4CvFZmTWIzqRiwwN+zP6IHWt6pkZA2hy/4Q8r7wDtsEDxVulSaICgR3ymLITtgjZ5BhmNdkxNpFAdgLLCgRXQK+JHY8pGR0IDGBadwDnrraX3ZyZMJFJaLLwPfojTPOc2ddBMQouNvH29fNbEy8oSaaZt2aGR8FbVd+2yVe/ErVrSipbga8ULOa9YE8yulGObmzVV5SA+L7MvAyKcex7BbAW/GGBlWyR06e2Kgq5gPwfgBxn6V+kScdSnBQ5iWLq7za3P+Q9BRRTuHuFJYq0HEoHBfz1l9kv7R9i99TTsmOT0QHgY+u6Xystjwkbfl9hVBdWz4OnEvaclNbfqasLY+FYq5BcbnV4GZ0u8E+c7FI5U7LeT0v1txuNhvWgCrqADedrMKn4ghhejn1iwd+OQ3/+3r+E3Fb9ll90QRMAAAAAElFTkSuQmCC")
IconData["picker_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABE0lEQVR42o3SvS4FYRDG8d/uOSQ6ESEoJEhwCWglGp8FolDqzjVoFRTiaqgVbkEhCpVEfCcSnA/NSN6s3eNMMpl9d+c/88y7U9PdctQitjGMRbTwiqwbXPy4gjt08IjdXuBJHGAfnwF/R3zAUBWcYRy3kfzrrRilGT5XNXeO6QC+IrkdRZoRr9BfVqAv4moiuxWxHX4TDSrhtQC20Eg6N6PoQuTVusHpLTcSBZ1Ql6GuUGk9EnbiPBDxEM94xwUGk8uWR9JGwNsF+DjAeUwkzbL0t43hA3sl8FvJhf3ZwGU8Fd6dxLpOxbmeyi7aOU7jeRxneCnAlbYUM27iMpRc9wrDbAD3OMJMIjPXo41gtGSl/7UfPpJHg6w8ARIAAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABd0lEQVR42p3UTUsVcRTH8c94b5CkJQRtjRBMctVCXLmqrS8iWru1Rbt8GfoKXLkIFyK06AkfQIkW1cIWkeBTipBQ96HNGfg7zIxOB4b7P3M53//v/M5hWprHAPpxHolztymkFaAbkY9iGT/wFS+Sy66MrJCP4XsoS5/567YHT/Aar/AlAH/Qw190sIebV8EyTEVxqqabnHuRH2Bk4BrAx2jjIgp7Ba86kW/gtE5hPoDpCmVp/jO8zapg7fh9gH18xFYUd5JWe/iGybopp7BDfMIt3MXnRFkOXih0VAvbjeXN41541cXvAL4NZa2y5a2C5bcP4n3Bw9lC/aXexwK2gzsF2BC2cY6nmMNM2fLn63E/plUGG8YmzvCoYvkv+ZZhKZbzdglsK2ATyX/tMt/SGz7gTeJVCjvFw8LgamMyTH6evBsOz35hvAksw1qsAzzDOo5w3BSWT6+PlVDUxzssxqBUeVWn8CVOsBofg9opNlGaLnn7f2D/AKYraPfGm5lQAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAABtklEQVR42q3WO2tUQRTA8d9mfUVQEyvRRhtF1l5BbISoHyGdlS9Q0YCVhX4DwQ8gWKWwEEGLdIKvgFgI2qmIKGpro+hm1+aMDMPs7s1dB4a5d+ee/3nMOWeW6cbMmL3ONNAOuvG+G7fxCqu4ga1tlHQqAgfxCcNiPsHsBA9HutvDNuzH5wD+xlrMX/HbpfXAZ7AZyyH8Dl/iuV9Y3w9Fj5oqSLG+VQEOKuFJCh5qGKNhfHckBBN4MOIQ1+L7laYebIr1WsD/VKweFntPsaWJAxtiPYQPWXgGlfAk71Yx16BO/sF7+BrCx3Emi/Uggw/wEtvbwPs4le1fLjxJ1r/O8r/TBr4xJpyL/E8zebRrXBXX4CeLvaTgfOWQbxapXW1cPXyLjCjhab2StYSzuI+L4yzP4d8DfmIC/AV2NumgqYnN4T1+YmEE/GrAn2M+C1l3VFjyeB0L4aWiwEr4syzPu00qNQEWA7AYVs1mB7qUVei64LLL4y1+YE+xn8N3NCmi2jgdkAvxfhTXced/wOENPuIA7ha5/WBaODwuoMs4jH0NL/iJYy/uZeBJd7E2d23tn0NqaK3HX3gPlNZXci+AAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACdElEQVR42rWXPWsVURCGn93r1RhNYSkSEGzyA9IEbWxsRI0KfsYUYqUgWIm/wEoLf4BgoY02GjB+koAgImIjqI0BiQgKQRDF3Nx7d23egWHZvft94LD37D1nnjlzZubMQjstADoZ/4XJiW3AY/3eBUwDE8AK8AaIpETU1s4DAa4Dv6WM9ffAvjRLVG0d9RDY5Ex/30EH6kON14EZt75yCzMUeiDQhszsLbCh5wegW8cKtnA/sAAsArPA3QQorZslZurCDwP9EYCs3pdl5tG5lYXHwCRwT+v7eh8UdC5z1L9VFAik/TSwTc7VLbE+low+8Laq+QNgD7AmZaIck6c54a2qURC65zvBBwXh5i9PgbHEsZXafRd4mBCeZ4lhAk5T8BPAeZdwogx4BDwCtlbJgmnwoYWR2qURStgRHdLcbhPwc06YCbyYcRymwJK7J2rB51J2YuF8Aei5ZOOd71UZ8+fBk/nDlDkA/Enx/FiZs1DopcEHwNmMM7TxERfnn50i/+SohXYfOKFl4euavwxsB6aAk3oWhofAFoWMwc+UgC8JXuTqTr3LAW67tHk6Bz7r4C91PxjQipSwTIqdkvf2Mrzdj49qXgy8AMbrlFodHcFeCfzmSq0gB/68LtyH1ZwssJowZ5ABf1Y1vaY53xjwyV2XAbA5MfeYgz9xF0utCtd2f1mC11TPWxuXZ59y8MWm4GaBHcB3Cb+q95PATeCLjsQy2uMm4daOS/gKsBO4BvxIKSjuKE80Bjfz9/ScAF4DuzX+CNyQFX7KR3xt2EgL5WwLbrdfgSsuvJL3ROPfclatHlS4LQO/EhkybuuDctTxBG1D/gPHRP1b7nNtjQAAAABJRU5ErkJggg==")
IconData["picker_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABVUlEQVR42oXTvWtUQRSG8d/dvRFSRoOgIMEypNEUNgFLrdROJWinJBDs/C+0ihYWVjYBLfwqU1gY0gj2IgmkCESxkDQR9+PavBeGZXcdGG4x53nm5cy51fHGBVNWJxv6mMclfMcBqs4UuMIwYB/X8RXb+d5BU0+BGyzgGv7gJU5FdhrPsV1PgOE8PuFicTZEFwPM4WxngqDCbBL0AjTpRyv5gv1xgm6KFhN3ppC2kj3cw99RwUxuvIGPuItHgQYR93A/km49Af4Q+G1x/iwJujjTpqqL2D3cxPs80ev04SRd/40au9gJN6iLeLfwDrfxpoCfYB1XcIyj1FftHDQ4hy2sjoHXMn17Y+ZEK1jKsGyl4ARP8TDwfmoHOW/KWYfHeFUM0CYe4HIB9wM25bPVWMl+gc9J8xPLI/DEv+0XDiPYSbMWA3emwW2Cb7iaxvwYkQ/9Z/0DYdddiro+H8AAAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABvklEQVR42pXVPWsUURTG8d9sJpCQCH4BicQoKFYGNI1vKAp+DCvBRqxsrCxEG7+AdjZioY02vtuIiiL4DoKVplGIqyFosrs2z8hliWa8MNw7e2b+Z+5znnO36h7f4D9HB/2s12MJP8tgmzGSZ0cDm8JVvMJLnGp4dQtYhV7WfczgdqDNOIsBznVabG+Ag7iBM5mnsJzYShIew1jdArYTN7PdI8WXjhZyDDCBsc4awAo7UEf8XmDleyu5f4KFzhra9fEi6/HM5TvNl87jBKq/AetoNI1reIxngTUFGiTBBxzKvCqwzjamA/qCAziMN9Gsn6vCldhnFP3OGrDP2I1FfMV+PM2zvzLvK83eGTLvMGwvFoqKfi+KMB7I+aJz1EVFezHtI3wK7Ftgy5jEA2yJZltTsIel+evCbxsTXA22DneTcA6vcWuV3v4D7OF07vegOwS7h82BvU1skKs3XIR+AttSxW70WSpgM9iFd4Wl/nkUbU/2y/m9gd3HpiHYihbtdSF2uIijuIOP0XUO79vAGuBETpP5dMMljOE6ZgMbaQNrNFxMQU7Gf7N4PpS01/Y4r4q/gEn8KExeFS3WevwGo6CBjuPqbAgAAAAASUVORK5CYII=",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACLElEQVR42qXVP4xMURTH8c+8nVkh8SdEQxRIJCw1CYVCxJ9NVBKFCImIPw0rShGdRLBERSUKKsVWFkvBshKiUehQEBFh0Vg7M09zXnI9M9m36yYvb+68c7/nnN8999zaj2PL/MfI0O7yrYY8myG0hp6AL8EVvMQYzmAOctTq0wDX4l1E3MJqDCOVYT22YCsmsmnA83j6MBercD/gk+G4jQlswkG0s4rwGmbhFl7jFR5haWTSCOky1MPRNjGponkL57Anfq+Mb3nsRaeRF4unGnnYbQh4nshR62DfCvvhqg6KlO8k0WZd1jbRi1FcR5ZVgP/GWhyJ6OrJhqejHd+eox+/psqgHhH1RbUsj9I7FNK0EyeFXC/CZrw4hPUK8AdYjO14GM9sXC5lUgt5JgPedZM7wftxN8qxESf3cNg1Q7oW1mF+2j7qFeA7oyLqEV0jibhRWn8Wn6IYWmUHWQIfwaISvJk4OY5LeIKbId8IrobjVjmDoiv2hcYLA36vBG8m8DHswldcK7WUvyQp/lyAIczDjqicMvwELuJZBPAtZEob4D+aZ8kGrcDJgPfGGSjDnwZ8PLSerNLbReOCjxFVT7ybGAj4aAneqtIGWmF8Gj/xOKIqIhvAhQT+Pcm6Up/JsRdrcBQfsBGbo2se6ABvV72liio6hfdRQTewL7EZivm04amDL1Gib2J+G4P4jLcVLvgpHezH+djQweiI3e7iGTl4h90dqiufKbgYfwCEPKNGS1IocQAAAABJRU5ErkJggg==",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADCklEQVR42rWXTYhOURjHf+99753x0SxESkyxUBZKMhtLVsoYYygrhiY2U8JCZG2BlIVvK4NhfDRlpnwNjRKyEQvGAkU21ChhPq73Xpv/0dPpvTPv56nb7bxzz/k955z/8z/P5H52N1OHlgMCoFDkbwGQuE5YJ3gq+EKgBWgCPgIvBP8fRFgHuFvlEaBbcNdeAXuApy6IoEpgXk9gFhMAfcBBwQt6EmAlMASsVj9fTQCBN/lfA98CxDoKG2QMNAIXgAhIgyrgCbAGGADuAu1AD7BZoMgciWuRxi2XNpKwCngbcNts/Tq9E4GyWqLAlgLPwwrgKdAM9Aoe63crwOmEmgN+V5IFOa2gBZitc4/KGJ9qjhh4WUq0WRO8AUYlrrSM8U6o54AvlWZBCnzSg3W1EuAR8AA4UIkPuPOPgH5glXbD7UI6jfBCwTcC425MUCY8BG4pAwC2Al1GG+kUqh9Qqo6b+UoSYTF4AuwEbuibmcApmVLg5X+q3y4CY9rBmBJTJgu+Q6YT6Tkt388bqN/2K7CCDygX3glcNiuJ9c0ZYJf6BRNEam7etBikXPgVY0D+LfjZBJST8t0xH/e+zQygGLwAbBc80sTW32Ope1AG9V5OF0p0XcCdYkVKmOF0kQfvBK76AvLgfeo/AVqBRcAK4DUw4ldCxQJwHt0A3AQ2mJX3lgBvBIY17pegI8XKsKwjcB+d1SQxsG0aeLuBP9bKf2kuV6QEU7ll6BUXy5Rikzq3a1PANwHXtWOPdFx/PGBSisnY7Z+r93fBgwzBWfhQBrxki7WV7BLj6zOMjeYy4A+rgWNsMxHwsPr9mrTBeHwMdBj4fcHHKoU7DeS1zbulgVHgqKCTwCwBWoFLgt/TToxXA3cBFIA5KqMBjgFfVXbtU5o1KK9RAdpRC7j157XAAhUZPcAhYC8w3ysoerVTE7WA2zSc0LsJeAYsVv8tcAL4AHwD3nmOSS0CCFSpDOqc5+lSOQmclxj9eyKlRi00YmsD1ivdhoEf5t8vd60m1LiF3r09WESgBerY/gGI2/hmq8yG6gAAAABJRU5ErkJggg==")
IconData["picker_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABQUlEQVR42o2Tu0oDURCGv90kgp2FCMZCUEHtbMVWtPFaaBB8BJ/B1kILsfZBtLb0BQQxoJWCd0G85rPILKxLNjowzMzu/8/85zAnUeliaTjAF9APTAHnwCWQoJZ5Uqjn1Svbdqc2VJISBQkgMAzMAW/AIdATSqrALTBeNjlR62rT3/atttSv8Im0ZHoC9IaCT+A7FKVAC6gAp0CzU4NKgCZDbi3XNGtyAWwCH0X5tYiLIXlV3Yo8k/2uTgeu0o3cyP3LmrQiLsQ9VTNAJeJSANaj7o24rT6oL+qx2pddNmoaoOUgrxXIu0GcVIdyw9orEMmg+qpudCA/q6NlS5Z9mFXvC6A99Ukdibqa2xGKDY7U/cjr6oH6WCB3XHnUmTjjinoSSs7+Q84ajAfhWt1Rx3Iy027k/GMaiE27KTzlFn/YD6C3W2ycozmDAAAAAElFTkSuQmCC",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABl0lEQVR42pXVv2pUURDH8bm7GzC40QXBVpGAiqlSiJWVtj6EWNtqYaePoU9gZSEWIlj4jxhBiRZioZWCRo0oirq5H5u54XDd3ZsdOJwzzJ0vc34z3FMh5rReRNR5HkXEr4j4XQZ3Y/38diFhhyLiZkS8jIiNiLi8w0PXqlr+Mt753y4humC93M/gNq7idQL+oMZfjPEWe7pgFU5mcmnbxblO/yNGvQ7xq4hYjYhBir+dGpZ54/TXImJrVoULuZ+aUlnpv09tq2mwQe5H8AFPsJ7J4+KqNd5gpZGpC/YJG9iLA3hVVNaAr5U36oK9wKiIH8RaAn8m8EE2sN8G9mfAGj0X8ail4bkyvz1vywl7jv0t2BDP8B1ncRGn28Nfztvh7NYk2BKe4htOTBn+HeAggTdyOPdNgK0n7HgRGxQyRbvCwGPcL7QqYVs41mrcxNUcVlLkC0VwKTX7iqO7gTXACndzHALncQ+b+DwPrAEOs7pbWRE8xPVsVEzSqqvCK/iCO1id1cWuVRVPwDAifhR/6Cr/LPU878M/T08vM+/WESEAAAAASUVORK5CYII=",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACFUlEQVR42qWWz6tNURTHP+fce58oPErJm5AiXXNKJsqPev+AmRFSiDs1kJlSkqlSRm/mZWCgDBSPJxkoZkjy45nJhLx778fgrf1sx/353qrV3ufss75r7f1da51dqKxCSqDbZ60ALFcIWgC1AN8G3AReAvPAZWAdIFCgjqpFaP5uj/rR/+WxulYtxwFP86a6Xt2lfgrA32on9Fe8O6cyKniprlFnwvit+jnm7Ur07XB0X6U+4pl3gKvA8ZjvjDWDi15iMh4mxnf7A9wgtxtkV6UT3z8Y1UE9wO5m0ZZ9bNvABDAH3AKGklyPca/6PjvvbmgunRjn1cmwK0cBb6pfw/iQejIjs5uBd9UX6oYEPiiLquBt9Vi2fr6ykxT9q5T/KbXHBW+Eop6O/E+adrQ1r516D0LbQBN4CGwBpiMj6sAi0Mh6TaNifwVYiGToLOXg38jLLPIFdVE9WtlVGi9kLeGUOque7VH19AL/FuBHhoA/UzcPaCnLDlITm1TfqT/Vw33ALwb4U3VTxkstlF4O0sLBMG7F80Qf8Lksz2vDelmZlftUjF+CvFqMbaAFXI8KnQa+/0PkwEazdDw19Y36Q52qRNGKyJ+oGyucDdU0OREgZ+L5gHpJvb0a8NzBa/WDulu9U+kx91YKnjt4VAGdUfepO3rUyVhaxK1iO3AtCL0BPK/cDpZ/IONK0efakrLLAdeSkeQPza/LCcxBbYAAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAC0UlEQVR42rWXu2sUURTGv5ndjWtiCksJAe3yB9gEbWxsxJgo+NZCrBQEK/EvsNLCykqwUARtVDBKlAQEERELBWOTgEQEBRXERza7Oz+bc5PjOLOP2c2By+XO3Dnfd+c8bwRoHSSSFEtqZryLJSWrG9eBQCQpKB2RtF3SsKRFSS8MfI0E0M8R2YiBS8AP/pXXwE7bGwM9EyjZiIGygZeAOw60YaNp62VgPHzfC3icQ+iuAa0ASeoPrNj8FqgAca/gu4AHwDQwCdxMAWVJ+BPjRU0QwCeAeguAPKnbnzkJqNylh8fm4aOSbkkqS6rb88jtaRclkaRfMgXdhlhioTUkqSGp0sX3mI66pJedsM1T8EbSN0klF/OdSMMwr0laklQqav8YeGW2bNCZBH95DFRNR9QteGThcy+lPMkIuSzHDOAhaalX8IPAKZdwkhzwBLgPbEznkKLgzRBGNs62IBFMtNf2Vrz+ouAnnLKg8EyOOQKBWVcnOiKQB3484yRlm08DNZdsvPM9y0rhRcHLqf2BzG7gZ4bnY5kz1IuWBLLAG8CxLBu69T5XA947In/MUTMLWFY9V0HwZds/B2wCxoBDNudVT6XBY2CDhUwAP9oF+KyBd1K6/yMQbHPdldQjbcAnHfhTYMgBhiYlbhVpaYZj5r21HG/36ynbB/AEGGx32lYESmaCHabwo2u1ojbgM0XBgdVqGDrZbTYjqWqlN9TvipXRKUm3JQ1ImpE0Iel3ut3uvL6uOV8VmLdTXbXnAynG+93JH7nCEhftLX1SOWeKvwIjbtOgefZhBz7dD/BAIAI2A59M+QV7OQpcARaAJZfRHvYL3DvhAVO+CGwBLgKfMxqKG5Yn+gLum9KazcOSnkvaaut3ki5LWpD0RdJ8qjfsXewkA9bfB/kAnHfhla4TfbvORUDkms09Fm5zkr4bx5JrSJO+32Rb3I7Ldr1el/t7kL/6x5+fRKCY2gAAAABJRU5ErkJggg==")
IconData["qr_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABdklEQVR42m3TzatOURgF8N9+nZfk1g1d+UjEQMpESoyQkoGPibEyufwlkqHERJGZDO5AQomMDA1MSBe5olw3E96uj+sYWCfb29m1az9r7fazzlrPKf6uBvuxPPUIT/1bw/DDPn4V7qMd2zdRwj/q4a9hGRwIcBUnsmeCrU7nFpfCnaz4LYPI/427mMYR3AvWVPwdnMWh8C2GTWQK8BofgtW75t9XWBngGwbp/jL16Vz6HsMGOIcXwTp+1Dl8o8ekC+myArd6+PMopYpqsnMVP/DV/2syprb4HKWaqsvOqOmkPcMS1mEvFpJ9iZEr8QQm8LhH4u08fjz1l9Qbqju7GuzBQVzJQMEZnMIafMJc3N+EKczmcxfhcKQeS9aXk8gStndxYWuwucgvKONz8HZsDtr8H1NYi4+Yx/rEOd9UOU/jQc5dzgvYh4d4E0Ub8Tz8bulwfczAX7gYZUdTv6pMHEXBjnoOtlWxLuJdzhPYjJ8xr4mSgtk/C+h3vVaK794AAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB8UlEQVR42pXVTUuUURQH8N8zToqiogjWLpBC6WVR0KYgCvwU7QI/Rh+nZYsWbYKyzNBAinYZZIugsrRMTTNHnRb9n7gNCnXg8pxz7n/O+7lToULbbxr2N60V/L/iwFnMYDWXa1jBNMZjDM4Ft9KBe4SJ2lgXnsX7Bj7lbEY3F4NdeHEIbiO6WTSqhP8Wx3ABu3HUh+eRT6AHH9HCRewF142X+IGxZpTtAFuJtoWr+VG7qCH8xDYWcn85+DaqZkctDwJuhT+KatxeJ65ZeO/GAK5HN5T7gyILSX0Yk5FHUq4/2TTwJMIO1nN2opuJw0bRvMNw08GA03iI5YzOavj7GCvqN1HgVnKW8QCnUFUdtenukHePqGFPUa5WietsSl/BtzsMVhhNWt8zpzCYOh4kYnA+9dlI97bDP8WZYEYzr99wJ8E0cTe6xXoluzCfiDbxOafelPkYPI79ogE1zUa3jZFmQh6P4hK2ilQW0oje6O+hH2+K8VpMab7WJRqOsIaTeIel8Bv4kvksaTJRtXGtvGgc0sGqGJP/pmbHyPTiSjwP5n4/W9CP2/kuFZtyA7cyu1N1U+ZiZKsY7K3i+aqbUqf5+JCmbGG4kQimsn7bcdAVfho3iwfhVTbjQ4F7H91r7Ff/+RcwlG+rGOyBPA4HWP8FI5KzrkgJxnMAAAAASUVORK5CYII=",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACVElEQVR42qXVS4iOYRQH8N/3GcbdBglFFqSUBUVyWVgKCcW4b7BTWFAKhY3N5NKQhYjEyiUbJPeQBSILw4JCLgslcpn5LJy3Tm8zZj5OPb3Pc97/ec7l+T/n4Y9UdC3VNO82vhKjhvloQv+kgw84hLthVIsxF8swIDms4RMO43YOZEky7Gj8wJRksLQL/C9My6newVS8wCV8C+BAzMMwnMCKsLmHyWjF5cCLbOZgBE5ieZHBo9hwR6zHY1zMz6Ad52PdgKeB394B/ljgLxRgoRCRzMCNWI+K8lQSJst3TMKDWI8o46slg+6wQz02DSUKNuImJqANr9ArylHtwL4xop8QEb9Bz4wvHHwNZRMGlw55ekT5ObBtneAFxWeX8N2i3Y9gWVGOpnpoWo30FqaLk+U9DgaV80VbEDQcWMJ/REsQpVrP4Vb+pVU0+DepdeKwlnTt5RKtwkr07aC37IsbXujPYXTMd+N0zDdideoO6wtva7o4tBpmJWq/TPoNoWtAc9JfzSVaH1k8x8VEw0FYhOFYh+uRRZ9Uim/BGviZ9L2zg8Yo1SnsxMTg+5NodIuD40Vtd2JIzIdjV/z7gm2xV2s+tIcR8RbMTGmOii5aw9nA9igdeEvCb+rslaqlb3uZCf8j5V7UF7cwNjZ/HeXLvaiCzRgaZXyLrek92BP7PsNRiVLt8eAcwf6g5lG8CwfHA9szmlpRlrUp4L1Jfy1n0BxcHhOjLD9xIJXxV/rXL+3TO+nbCgeVeLW+/+XRb8H90LfhCkbG/9bk8HE8oQJff2+pV34DHYbLrrjXgWEAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADbklEQVR42q2Xy29MURzHP729M1pFRYsINY1QbDwqBIl3YmUjImwoQuzs/DniERJCYiFBWRhaj9QjQqQkHrWkXlVttTOdsfkefk7uY0ad5OTce36/7zm/+3tf+DMCKh9BhXtxo8Z/qAHKWjcAOcukUQL6gG4PY58D4edXg3eStwL3tZk0u4AW89UOvxDoqQB/B5hntRYAGeChGAoJYEd7IIwToB54XgX+LhACgVPTRuA2UBThGfBdz2h/GrDM8GzS1wDsAK7oghB4Cgyl4NfpQwDokI1KQG+E/ZzNXhq+DkM7pr0y8DjB8XrFUwL2YiQsm0uH9X4Q2Ky9PHBStCjhLH5I6yFpCeAacF74v6IgjDgsI4YtwD6zf0q0tOF4Nhv8AHAhCh9UEqsxX50W5xXhozTgPPU68EN7XcaL04bDdxp8Pg4fenYEaND+OU3L22D44vxgitazmj7e3vVbgHcCFYHFCsMhoFb0cYHbTBi9MYe/Fr4ArBT+ZwR+scG/tX4QAvckWTEhkRRNNgxNIqoDnlSBvyXhAuuIc0VIS6U3gTkRqbhViSkNfwOYLY0FNRGFZW1MMSmrmPQkFCOU4VpiitF7Hx8VKuUKS2nZC+dQlxQrzBNFX4BAB1TaD6Tx1hphS3H8vgkywHb1A0GECt/JB4qeJtqBbcbDB4ETJu7rgMNax8VzFXhhnXCR8eSk+QhYIExW63GPZ0j5wI2miHOO2MuzwEXFcCEly60Sb9aodVg0t/ZHpOSPHs8IxnHWA8ulwowSyaBXz6eaet4uTN4ktIxxsHqTkp3g9R5PaDNhTsy1qvkrIqLB1fM20XKGNgx8AcZ0wWdglim/04FPohekvZG0fuCAqed54HRMPxACZ4BL5qzZ6nYma++byvOA3zck9QNbTT0PdElcPzCqifH6GVrd+Ko275/6gWpH+X/0A53OTibHx0VIvaqdyydNwAdjggGgWbZ3PINWa/tNtnoZI1iY0JQelZ37tb5SwWrUzKkOWJ5daf3AD6+eT4mr57J1o1H9T0WF9Yvpas0dTxZT0x/ox2S1Llgao2p3+X3NUHtFmacgRx3VOma0N+rxjFsnLAC7zaFJPtMN7NGlDj9Zh7q12TijyyczPZ66an9OyzJVd0RZXgKskW8Ect7LpjRPAnaa9B3Isfsm/Hs90fELRjtggw9zH3QAAAAASUVORK5CYII=")
IconData["qr_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABlUlEQVR42l3TzYuNURwH8M9z57lkqAmNRCJKLCykvKywYYfysvSymfGfSJZKNorsxMak6xbFhpTGwobFeO8qY4piukMzY+H75LinTp3n9z3P7+X7/Z5qstuDGvuwxN81i6f+rXbw9iBeYznu4LD/102cwTAmcHAAv4bxarLb249HuIpOwHM4hlXYhie4jAeocDb4pla6WMA9jOFQEi0Ea/AJjKeTDhbRrpNRAm/QS6zcJf6piFUt/EQr1V/n+3QuzYWwFs7jVWINPlvjOW6EsCMFSRfxHS9xC6dwvMAvoFdFRhjBUM6/8GOA9RGszChf06k64FJsj85V2n6BeazBbsxE+ypELsPjGivC8IGBirdxEntwF9/SwVo8zJ0dNXbl5yu4X/jgRHzwBR/D/nqMYirj9kudO9H5fRIdTcVn2Jj9ITJvRb/hoNT53YAPFvM+RrEanzGdMeYwXRc6j6Gbc6PzDPbGwm+xBesibYWdjQ+ux9+ND+ZxKT4YTtJWqvZzHkJV+mBzIWs/84pKG/A75NXppMLUH90SbwiHSDhxAAAAAElFTkSuQmCC",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAACDUlEQVR42pXVS29OURQG4Od8PW1TaVU1mDF0HyAi1CXE3NyIEL/CwO+QiET8BJNKXEMQ0TQM6j4gGgmhpdq0X9vPwNtkOyFhJyt7n3Xes/da73rXPtXY6GSFjl9jyO/ja7H+J1wroO24g1d4G3uJm9hcbLYjuJcN3C1sgWpsdLIL97EP3zGXw1ahHw8wksMfY1cD14cB3MORGqsTxQ/swUKx4RNsQ29sC75hNxaD68E4tqK/jrODduxh5sP5qFNwCPOYTbSLOBB8B1XdIHc54HbWfxsruMUmri5O7wkXR+Nbk/fLRRaS+hCO53kY3SvZ1JjGMxwKZ/PFh71JbT7cPk3xxv+Ae4SZViI4E4lMFVxO4TpOF2meKnALsSncwDl0qrHRyZKCngZXC3/hsLegq13imkVZVaw7jQ0rrI8eZ6JFkd1wMvjUinNn5PIOk7H3Eeu2YNZF5BO4nGBqXInvDgZb6MLFkF3l9JmsR3CpiHATBrE2VV1MdIPYiFbZKbPYm45ZSeVxuqMv/mtpx9eFvJ6Hmi9YqBsFmEtft3GsEG4dzk4EezzVlo1vl7dNc1RFm/33qBuS6QtvnaRcYymR9uNq5jdFp5zEeXzG2Tq3x3PsT6eU11JfumIOG4qU64gZLuBgatDdSgRncTfOrthseCo7ZQIfI6sV3If4XmCp+s9fwJrM7ULYA7kcljH9E/Gjq7omE88WAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACcklEQVR42qXWTYiWVRQH8N/z9tqoow1BiWn4tQiEiRZtS4SWYm0KajK1lRIhJG4EFw2UGwkiijEXiQuN2rVo0cemr6FCXIgQ4bRJMMiChGzM0Zk2/0cOD29vM3bggXPv/Z+Pe+7/nvs05z65DA0WDJce5qMvGt8v4KcwgVUdB1dwHN/GaCHfTjyP1cHL/O94F9+gabKDZ/H+kGzm8Di+j5PncGYI/ha2YbqfiQMx/AmfYjbje/Ak1uJlvJBsX8n6DD4LXnazA+vxUg0wGsPTeBVbU+8fcS+exliwd3Xwkx38qSQyBm2A9vBmU4ovM96IG3E2P6AUf+NRnM14fRff6xg0li5DbfqFUjCCrzCeg/oZd6fevQH2I8l+PBlfxrKKbwP8lckJ3Nc55MeS5dXCkEF4ofgTFd/S9L9oNxfafVccn14sTXu5AzfKxanyK94pF02SmcWu7LLKb5jCNHrNElpFxSypVdyJLHTYU1uFSv1+aWJ7sBsrB/SWt3LD2/mPsCn66/gg+kHsjT6N/f04fxHvDcl4B7bjiyQ1js1ZW1vYuAEPl7O4vbA/gS7i40LDsbSJddiXAA1WlOCzuFnY1sryGmCksGkSj4RqF5LhM+F4W9tJ3B99HV7L2p84El8zNUDtLduSqdR5bkAvOl70qVQADuGNLpXq6S90HM37n9LtRSvxNR6K80spX+1FTTJdkzL+gsPlPTgavz/gZBvgWpzsSk2vZ7w67bvBHyXAQTyQ8T6ciH4swaXMtwO8GS5vyTeoF71dynizrI2WSizv9CPto/9hDvjfHv2pvMdNDD/Hg1mfKQHP5wkVvOYOf1sWLf8A3ES5/Wq+8JsAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADqklEQVR42q2X12sVQRTGf7vZDSaxYX3SqFhB7GKMirHgHyBYQbD9M/rqs1iwouKDoAZ9uMSLimIEwfJgRRHsJT13k/XlGzmOe3evwYFl9s6cb87cc75TNuhsf49GCAxT28iS/Rd8AKQAkVkY1rwOaNa7HcPAa6BsZFMPHwo/vQCfOnxkbj4DOAu0FNy+DOwG3grrDp8NnAFWFuBvCf8OCN0BMXBBypMccAKslWxs1huAy1JehF8HnHfWj3T7tcAKCUTAI+CncVECjAUW6X0VsBro0P4mYCFQEeYh0JODb5W+u05gpvxSBzwDlhj/WuI8BeZqb6a5wCytxUAnsLwK8Z4A8yU7w14gNaTp1e99QJvWSsAx7QUZh1t8j+b9wHq9XwPOCY89I8o4LJbABmCPWT/u+b3acDJtBv9Dfo+z4jkvVrPea43zmvBZFqjIpNeBbhM6qfaKhsO3G3ypGj7y/AjQpPXTeqxsUwY5fR6M1nxKj4+3un5f4JVACTBPYdijqAAYEniuCdUX5vDnwleApcL3Z+DnGfxLgKCz/X0oLnQotocM0B9uryySutxfD9yW8lrwJWAzkIYmUWzTRl2Of+uAm8B2L+P1A1vFlSL8DWCnu3ygamgLS0uVYpKqmNzzK5r3vhqYVqUYvfHxgSnHgU+QgvBMvXB2aT2pMU8krhrildSikUph6v27wQxzB2Z/2ITpX2HolMfAFvUDYYYJX8mHiWeJZSpIjuFdwFGjbBRwUPOQZK4Cj20/MEfpcmmBBR6IhC/F/kEpP2xkepUDKia3HPHO+Q48Dk0YXZDySkGWWy7ZemPWXu25+VNGSv7oyfTZfqAVWCwTxkokXV49H2Pq+TJhSsaVsSFYg0nJ7uINnkxkOdA8gn6g2TP5V7kjBr4AU0z5HQ981n5F1uuzF8jqB/aael4CTlTpByLgJHDRnDUVuAs0Gn+3qSz/0Tfk9QMbTT0PpaRaPzCgB8P6CZrd+KY2b0T9wL+O9H/0A+3OTypUef1Ag0LNpeSJwAfjgh/AJPneyXQBA3n9QFY9b8wgZwIcAA7pgrGUt3gk7ADGGZkDwKW8fqDbq+ejs+q58fk4Y/p+RYXlxXi15k6m3v2rUIy9bz4sFuR8WETAHT2R1hL9M/fvBjQPGusNeDJDloQV9QN3qvDCuqEM7JBSh2/UoW6eZNzqXDbZkxllM2GgWr0m5+M0lavKhtmOlFfkd/eB2ic3uNEN7DLp23VgBCP8PA9q6BtqGr8A62A6OKa84FEAAAAASUVORK5CYII=")
IconData["qr_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABmUlEQVR42m2Tz4vNYRjFP++d751pMjUNjfxIZBZSNlIyK6Q0C8PGWtlc/hLJUmKjyE4Ws5hklMjK0sKGNEZmoozJhtsMxsfCmbzu3Kfeep5zvvWe55z3W1SABpgEBvlbXeAF/6odvr2JV7eoc26ue2oJ/7QPf1sdQD0e4JZ6Nmcm2Jg6mf56uHMVv7cV+b+Bh0AHOA08CtZU/CxwCTgZXqDdACV7CbwDPgarT80vVVhpAd+BVm5/k/lCPlqLYS3gMvA62AbfRW2rd/uYdFVFHVLv9+GvqKUkRoBRYCD9D+Ab/9coMJZVvkQpTcgh4GByLpH9ElgHtgNHgZVkX2LkMPAcdUR91kfig6wwnflr5p3VN4ca4AhwArgJzEXRReA8sBX4DCzG/d3AODCfdVdRT6nr6hl1Vr2hdoJN5Nai7gu2qA4HK73v4H3POzD/xziwDfgELAM7EudyU+XcAR6n38h5BTgGPAEWgAlgF/Aq/GHUQfVOj4G/1GuRP5X5bWViV11TD9TvYH8V6yrwIf0IsAf4GfOaKCnA/B9m+Z+jV1VNLAAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAACGklEQVR42pWVT0tUYRSHn3tnUhQVB8HaBVI49GdR0KYgCvwU7QI/Rh+nZYsWbYKy1FBBinYZpIugssY0Z5rJZnSeFp5Lb5cR8sDhPfe8v/vec37nnPdmagbIsdT4V/YS+/9wKupldVHdUfdCG+qCOqtmgbsSuEYJ90Ktq6BW1DWPpal+DW2FbyUOrKhvBuCa4VtW80ytAVvAGeAa0I3gR4HX8XwOGAa+AD3gOnAYuCHgLfALmKkWmQewB6zFejteMuEQ4DfQAdZj/2bgBbJqidx+gHthnyQF7rCMqyZfHwLGgbvhm4z9fpIFkXoNmIvnqaDrOBs1V5eC2AN1P/QgfItRlDwp3iDcgpoXbXNRfa5uR+vshP1UnUnapp7gGqHb6jP1gpplakrBUImr7gkcDid09VJcuSijiW3pwAyYBnLgJ9AK/0Tw2AcaRcpXg5+m2gltqq/US4GZVrfUH+ojtRr6OHwbaq2YlNUgtqV+Cy0mZTUOPKseJQUoglkOX0edqkbIs9FXN4B2kso6UAdGwv8EGAM+JO21EdTsAl3Umrobg35e/ahuht1Uv6vjSUSoc/6VO+lePqCCWTJmp5ZqqWVGgFtR4YnYP4opGAMexrqZTMo94AGwA8wXRVmJ8NtJY7eT66soSiEvBxSlrdbyiGAeWIrCVEI7wAJwP7kQ3gHbwOcE9yl874Gj7JS/gMlYe0ljj8fl0Af2/wAkY53gCq58qwAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACdUlEQVR42qWWTYiNYRTHf+/tMmMYNogZRRakpiwsSD4WlkJCcY2v1UwSmWyUYgobqUl0h42sZHbIBilfN8mGyMKwoCgfRWG4M/f+bf6vjrc7M3fGqVvnnOf/POc85/mf895EEkACiJElB1St143PB/AGoABMyRzwCegFHnmT/FsHbAeajcf+L8B54CGQIAlJWzWylCUtlZQYv20U/JCk5ZLIO/J+R38N3AQGbE8F1gOzgH3ADmd70Ov9wC3j8W3WAq3AXqCU3uCpIx+zvUjSQut9kqqSrtnOS3ph/NEa+EvGX483SB9vAFgJ3LM9Fyg762qNh/wNLAGe2G7N4nOZDQljlxH35AOlABqA+0AbUAHeAhNd71yN/Q3Ovs0ZvwcmRHwa4KedBWB65pFXOMtvxlaGwWOKr/kHXyftypKWBZoW6qVpIint0E2hcaJ8BM4BpUyjbQTafcson4GiiZJLxjAqImZMo2I8ogx74qggUj8fhtguYCfQVGO2nHGHp/6rwDzrJ4Ar1ruA3dZLQGf6yHs0uqwOnfwm+A/Yl5fUE/x3Yid3+havgBuBhtOAzUAL0AHc9S0mhVIMAEPWB4O/MfZBg0t1GegGFpvvzz3otpjjaW27gRnWW4DjXvsOHPFZ/TFAnC2rnCmu82CNWdQb9KIrAHAIOJ2lUnx9ZQ6q8p+SnUVNwANggQ9/5/LFWZQ405ku4wfgcPgenPS5L4GLaYAfPqTdNf1lu9njOwG+hgBdwGzbHcAF66ccHJf5b4Aec3m+f1kZBM6GMg6FtcmhEo3BX0lLlAB9fuDhPvpF4LH9FeA2MMfr/SHgM39CMZ5knH9b6pY/SOf5gQg7SeQAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADnklEQVR42q2XS29VVRTHf+f03NqWKkQQYhRbiAJOfEAwaKKiJo6cODCOTET0I/gh/BDGRzTBqHFAggIDaqnSgCFG42OggkPf1tJCubf9O+C/cWXn3HPPrazkZJ+71/rvvc5630ISphJYox3VyQ6DLwABFFYgbRTAo8CU3yOtAReBufyQ8F4af1drvKRSEpKmJZ3RYDotabsxZcDfLelsC/yspDsTPh3SkXTOAt0GcOLNG5MUGJf09RD4zyRVksrkgseAT4EeUAFfAf/4He/fAtwXZB4HZs1/BjgKdM37ElgagH8YmE8CO+zDEeB74IHg3xg43wG7zNsRFNjpvQ5wHtjXJ/C+BfZYdjoqoBA0y/59CDjovRngDfOKmsMjfsnrS7YSwMfAEeOJZ1Q1h3Us8ATwQth/07xBlGQOBvwC8F4dvhyQq3XvbfO8Fb7OAl2b9BPgkvdOe6/b4vKEPx7wM/3wVeZHgA3ef9dPlN1QE5x5HEx6fcdPjo93XVfggkE9YLfTcMlZAbBq8K6QRj+Gw38wvgs8aPyVGvzugP/pmirXCkkl6XMXiV5DIemFaliFQjQm6fwQ+FOSRmIlRNIdZgyik5JurynF0y6zg+iEpG2SilgJY2M50KeZyM3kbEMzwhVue59m9HOOL0I7LvIAGZCeytK58iW9lnWilyvwf+eBnEaCsmv95KvwVWvW7mnPA2WNCS8AJ619tMRe4KkQ4YvA6yHvx4CXva5a5hjwTQzCe0IkN9EXknYaM+r11UxmSdKkeUjaXHPOK5Kuf+Uo8L5zuDugyu2z7Ggw67J5af2tpiT/mslcJgTOI8D9NmHHhWQx6+c3h36+15iZ4MpOCLDxUJKT4uOZTBVjYGod88BU4C0DfwJXfcEfwNbQfjcBv5vftfUuRwXq5oEXQz+fAd7qMw9UwNvAB+GsbcA8MOG9v92eF/K5oWkeeDL089KX9JsHVvwQov5Wr4n+8pi3rnlgWNKNmAeOJz959muaB8bd7VJJ3gz8ElywAGyx75PMIrDSNA/U9fOJmuDsAYeB16xgx5cfyIJwFtgYZA4DHzbNA5eyfj5Z28//8/nGYPorzooYF5s8mieZ0fRVpSP2HLDfF9zbx9Tp8jN+Ku/1/GXp61a8Xg3WW8lkVmMQdoHnwqFNMTMHPO9LE37Ch6Z1S3BrctltmczYsH9OZVfN1bTlPcBDrqqlg/ej0JpvAp4N5bt0TFxcbzsuWswNrehfau1XfLgKpNAAAAAASUVORK5CYII=")
IconData["rec_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABAElEQVR42pXTvy4FQRQG8N/MXuQS0SK5SiqtqJQeQK/wGt7DC+i9i0ZNy71ESBS4u5qz19gssV/yZefMzpzznT+TfCPrRxP8E3ng/yooBRtsY71zMGGKx1iXqn7gHK/4RB0H6rCnOO04OMFRa+wXeXbZOnvBGFu4ir03TEaYFBdyj7x2/wCX2MEcI2zkkJkKianHfo/o7eUqHM9zJ7ffkPARrMpA2TA0ff39z6DUWMJypLAYsBySUlHxvk6McYfrIv8qCmk3Ctn8wfuIvoaL2HvAZivxDLeYxdQ9xXeGGxx3in2Ive4or2C1p/rPkUbZ1rpYLx7H0MeUdWSlIe1r8QURz1Br+CDgTQAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABMElEQVR42r2UPUoEQRCFv+5Z3TUUTdzcRDAxFsE7mHoJQTyBdxH0BBuIgdlGgngGcRFMDIbZnjZ5DcUwPT+62FB0013v1U9XFWx4uca56NCNQK29d/lfOpGwk8ThJBE4AM6AWQOYPFoBC2BtMAUQ2qyeAh9S6pJnYFfepKiOgSvgMJEVwFKAEqgyUkrn1oR6DXzr/hWYIosrJbzu8G6t8B6AOfBo3irgE9jzykfdkuzc530B55JS2IkMRp/5uT7SSt4WBuvGlgtDatZvulP+Qhi6COMIomhCtq0YE2Ft9j6ioDJbAHfAtrBBZ5cS/GTqKWSkks6NMXIJvJsu2koPR8DbgNa7B3bkVfrlOXAB7DeHwww4Se3TGA5OnfBi3jqHgx9Rf7nx5doGrB8wYP93/QCFa2jzicuuvgAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAABSUlEQVR42t2VMU7DQBBF39oBIlEQCipOAFwAiSvQUFCDOAKUiIoyFNRwAGpOgMQNSAM1acIJIMHO0vxFI0uOd8EuYKTRWuud+TM7M3/hr4urfOeRdnPpj4BiJavx05O6sOEAD6wDJ8C22a+KB96AO2AkkJBJDpR10W8CL3IQox/Avux75mo3gAvgDOjbIG+M4WeDTnV2DKyaQA+AVxPE0GYxUnplZAZzrTvAALg1/94VyENILxQsS+iMULcZcA0cAYV8LOnKZnWdkNJ5DlhT5q7iz/0WIEixaH6yloe1EwC6BvBdAyyb9m4VIDgcq8jVNvcWoEhkR2+I7RS41F6mISuV2bdc6cA0gSqegRXjYw94MhN9bttsADwmkN0E2DUsGhihDxwDh8G3petchLXVUJsJcK/VmVospJq2H5y87snMIsHKpv7/P/IFTQJ1/fvYDVoAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAABxUlEQVR42u2Xvy8EURDHP+/dIndEJxSoFZKjIhIiGmqtv0GtoBEKhdIfoPFnSIREJ1EikUhQSDQcOfdrVzNPXtbu7d7+iEh2kpe72/dm5jszb78zB4X8saiQ57pHO25WgEpdQEUFotNmQFuRTACVmDY+gOcAG0HBGfH85wz6NeAS+JQDrhwOWma/BpwBiyHlUz7nv4I3m+tdnMVZTWDFZ9N2vAycAMfAjA1CAcPAi2XI7XE1RfcOGBCbfeKkDBz6wL4Bk3YWVmWjnSIDHfmct6JeAK6t/RbwJb837HqNWYaSitEfBfqBPeAcqEpgGnCkLJ4pj2Mpq4x4pQZMATvWZXXCLqCTI8F1Ai5iasbLnNTyBBBLCgAFAJ3ja+jGITadk/OW2C5ZfBAJwMvAuQcMATfAJvAuINo++z/MawA8ygOVMnIFPEnUR8AccCqMqwRIR77XbcUycC/IGgnacUN0r8SZ9tH8ljg0DesBGDEBG65ekvEqaTt+BWZ9pdVWVqeBA2AXGDfBK98sVwW2pacPxiiJJ93vAtgHbkPmwqDLqAAvbCityGQTR+oyZEQNpdrKjBt2Tke1zy6dT2f5x0QleP0K+Z/yDawdrdbTE1zeAAAAAElFTkSuQmCC")
IconData["rec_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABLUlEQVR42pXTwUocQRAG4K97R0UhxFswoFdPXgUhnuYNcs/RU27e9DmCDyA+iQ8g4sGDIOQYWNcNLGFJ4s54qYFmmF3xh5+e6aK6+v+rK83rWiAbRhscRFUkN5ajHx/FuqiQIvgZH3qJCWNM4rvDorxBi3OcYTOqpdhvMMUprgopX/GE6zSv6wPcrdCfMMMnbONHHDDHfoXdwqg8YFi3f4hL7IWECh8zXqJKKnT3//9hp0gexcGL3DNnGRL+B0dloex9aIf6u/KhBBqsYb1oYYs2x5W6t9AOsIn2/sRtoX+EKuOxMCb1mIMz3OALLiL2jHHGA06iwiQC01gnuMe3MPAPvuMIx/iV5nXdvboNbA24/ztklG3t5iJVhZ6/wbeGqS18aKpiONIbXTA0TK/TG1m2ZdmWTAAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABaElEQVR42q3Uv0odQRQG8N/MvVELCaRIESu7oGBjaSQgF8s8QBqfQh9DfIkUFqKFXao0ipYWVnmCkD8kNkbj7tqclWHRe9fogWGHnfm++WbOOV+6HI08ZwyLecJgzN4GdXwnEubYfNNDROqQ5gJfD2NDjTd4j5kCqAB/x+c4tCUdoAr8ncIGq9jH6wnqjvABf4K0whLWcYivOU7ZCbLrUHDfuMY7bBaKtnCCbRxgeoiXmA+lL4qrdqO92lvM4RPWYu0mnmw2F2+YeiQk43cQreEqsMMgbXInAXqS/gvFgwKb2sX/iQdrNnvmeAphNY6weQRRU1y5bMWmbLlcVvsYogqvomN2MRXYKuYpR9WfFwv1A0OoOsUvfMQGvsX/c1yksK9F7GFhgsq9ILkqWm8OK/iCH+lyNGobfQbLmL7HHBJ+4qzjOINuclpzyPiL4x71VyaxKuyrQtP6Ydt6uYfBdqPu2lc3i0+KW+ELajvRnvInAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAABhklEQVR42tXWO2tUQRgG4Gd215guWAgBDdhJUqewEYv9AwZS2AliYRvB1hQp05gi5CdYaKNYJqS1TmWTSgTzAzQXz+7YfBOGZVdPyC7iwOHM5cz7znd756TTft8sW8eMW6/qJ3Rb7hvG05ogIaO5ovWjJPUhB8i9CvwWnmEl5tIY0IwTvMXRCEk3QJtxFtzBAe63PP0G1vEpMHKA38YL/MQuzsviZoCft4jDEDexh0P8iPk17GApxot4VSx4EBtvtMysjLu4h2/YxvNYOwurVmsXdSYEbVIrcbvAGzwN33fikN1Yu1YdlERYCP+nEbw0rUJr/hS3aRCkfyoV0yDIsyaYK7IwbYIC+DWCPJrmuSZorlADZXOKOnqJrZjr4FdYNFcT7Ee/afFcBPgXHMf4NR6FAM6HRfuQTvv9Uiwf8bClBSd4jM8BloJ8Hk9Cn94hFYIcH65h+S+x+Y4P8U5VLMZKTa/y5wDvr3HhDKsLp8j3pdjlSktSC/DBhKTIky4cNet/9VfxG6v3Zy7DRc1NAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACD0lEQVR42u3XO4sUQRAH8F/PzHn4DNXEUDBQTiM9wQeugrGBkV/ByETwkehHMDMx8StoJIIGmqiYnQiCnIYmnrq6d7tjUgPNsbs36y23IFfQzNCPqn9VV/e/OnU7HbOUwoxl5gCqKQEbTAtAGcomVZiiDTYDoEA//g9hV0sdP/AVdegYBaLM/utmXpUZH+Ay7mIBOzPvhkkd3594gzt4OQREWudc3l8XWdiv4CkWw/s0xnge9j04h2e4ELrKzOs6jJ/HYzzC8ehPqdvpJOzFR+zH6pjkHCVrmAsdx9ALHasRyXu4kc3/HvOWi0CyGMb7oShN2ObC88M4ETpXcRqvwvgggP7BPpxptgAOxqJ6E0e6WX8AO8LrF5FPa5EHVbYtZZ6E9Qb7PclxXMER3M6yvRoyb+xFNA0g/SHHb0uv4rJNVLfJaBvAfwugoeZ6FgBSXMMN0fXbAqinYLwOdlzC9SCdMq7iet28lANYbkG/bauiL+H1A5wMmq5ibC3GEroNgITX+BRoexmxtG290PUW7zPiWcJF3MTv6JvHZzxv6oFmn87iCXb/YwS+4RLeZVVRkYE8imtBxw8jUinFw6RZsIBbOBVAUos9X4lS7D4+jKgLy1ElWZWV1UWE72qUZPMtPe9GeI0pSvsxVmT2BuvpeJDlxK9okzBfvUFZPrTcr0Y8MCY9Df1pv4zqbS7YKvkLgsqSObBOM0kAAAAASUVORK5CYII=")
IconData["rec_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABHklEQVR42pWTMU4DMRBFn3eXoIAQLUEKJVS0iIqSA9BTcA3uwQXouQsNNbSQBCGQKCC7j4JZZK12I/Klke2xx/b/M5NUAgX9MKwXVRbcMIzufhljndQUL+wDO53ABMyARczzX8VMUa/VD3WpNv6iifVMvVRTnEW9UM9UUI8dRnvZuzpWJ+pd+D7VaQVMM6GKHsFa/wlwCxwAdei3WwDL4Jcy3t31FzDJgsu4uC464gwhAd9hZf5QwXqwL78rCyXQABvAKCj8FVgRX0pxyB5rgDHwBNxn/EugQj2MfK/CszpSt9Wb8L2oe21hXKmP6lxdqK8xztUH9bxTSKfqkUpeypvAVo/6b0EjT2vbFylFN5aZOP9tJoEmZe2c1klfix9oXSWcrpOA9QAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABU0lEQVR42q2VsUoDQRRFz8xGjSCCYGMqGxEEG2sR/AcbGz9C8BP8EwvBP7C2EStB/QcVRQWLoMmxeYFxTeJGc2HYYebdu+/N7H2bVKaJVjFPQDUmVqAfz5FIkWGO4CZINdFc8PtJHQSsADtAuyBSkB+Bc+CzEK2A3vc6FHVbffB3XKhLao6BuqkeqmsqqJV6FYSu+jFidCPmOISyeqS+x/qNOtcCFoHVKGGmKLWOXpzTOtABToDd2PuMI1vIIdAfI0TtAl5CaBfoBrcVoubaBdBQ9CMyrgpuGmz+BSO/2cyU8R/B3jjBSQxtUXJpxW+Wa2I9I6ulcMwpMBvcXsxTBl6B22KjP2IQWV0Cz8A+cADcx/ot8Daw3oZ618B6Z+p8uKQKbkfdU5dVyubQBraAuSHNIQFPwHWt4/xoDpO2rzTkEnNxXKaiY6dfPiObvDRN+xfwBQ7gLfMKwFFCAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAABaklEQVR42tWWMU7DQBBF/8YhikRBKKg4AXABOi5Ak4IaxBGghoaShhoOQE0fCYkjpEpDQ5pwAiBx8mj+opWVEAdsIUYaede782fXM/PHAVCd0lDN0kzGQVJW0m5mXSrBnyhI4ge3LzpJDzmVRAAi+KakU0m73hjmgCLpVdK9pH7BSWbQggUEYBsYUF7egUNAQBPIPN4CLoBzoA0EeeE2MZws0Q/vHQLrthfQBV6SQ1wDiot9YGotIzM/94AOcJesvfkgj8BXFjUWBG1hcjgeY0k3ko4l5cZYczzGv62DmAgbDm4o4IWqCi3/rn6qcBD+lCqqcEDdDlqRFqp2EAGHDnIxzUkd5CvUQDQOZuMzSVd+15A08Y1aqYOex3kJHRt8IOnZ80tJBybAtm/US8muAzytQHYjYN80k5nwZII7AY48DyldZ5K6knaWxGYk6cHPtI/MpZq6Gg6xN4Sk6UcuCSXAp2UPFP79X8Unme+wr4L9fecAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAB9klEQVR42u2XPYtTQRSGn7n36uIqdqKN1hbC2rkIigiita3+BWsL7bS0tLOx8S/YCaJgJ1qqIAhqYWGhUbLZTfLYnAnDJdF8sQHJwDCTO/e8eWfumfOek1RW2SpW3FZOoFkSseGyCNQBNitgij5chEAFDGJ+EticEuMX8BUwMCaRqIu5o/dU1CrGa+or9bc6jD6p5fWO+ly90MLKPal161l+DsXidRdru+rlwKpbI+ol9Yn6WD2bSWQmR9VvBdBwxr4bth/UjcA8EH9ySH3QIvtDPZUJoF6Nhf4CJzCIcbvY9Xn1bbG+p+7E7xvq6LqdCMdYJCxm++PAQeAe8ALYAvrhoE04o9kpm8I4LSGuJKADnAbuFt7ejHnvr4FoGUQGY67fvobieppTXYvRmsB/SyBLs6sgkIC9wK6LePBPAsvITgWOAO+AW8DPINFv4Y8ibybwuchqFtl5Ar7Erh8C54BnEXFTEBnEvJsTkhSS+TFUqjeHHPfC9rXaRFLSFKp4W+0WyvlJPaampObvdBF4Chye8wS+A1eAN0VqVhUqeQa4CfSAR3FSKUVhkg22gDvAdhBJU3zzDvASuA+8n5AXjnPGBJiKyqg03AQ2ptx5F9gZgzHO4asijR8CpFZpVrWkdBblc560PE2oDdMc12+plZFrLdiv9gfBYZ5sTc0COwAAAABJRU5ErkJggg==")
IconData["shot_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABZUlEQVR42p3TsUuWURQG8N/7vpJGBokiLhKFRktItAq52trk1hLU5OYfUGskTU7R1tJoq9gWNQVCLQ3VUJDWoJGY+X0NPhcuXxHRgcu57znnOfec55y3QYM+RnDWsezjQ+7FP4bJfH/F59w1mMPbBPbxBeNJMBT9uPJ/x+0Chg3M4lYCdvEcvaqCC5jBIW5gCVPBe401/y5X8RMX2xhGMYEuXHR/ALU4Ed94dFMCJ/ECr6o+m4CKFHsvZwxPah7+Swp4Ecs4Wb18Ck9xJ/2WKgquwxGcy1j6A+dZ9MrAOH+TxQQeZoGOwkWLd1hPXDdQ+ZnCbK8ibSS2OXzKZu5VwJJkHm8w3VbMdniIaVzPWFX9d2ljKBOYwmhbEXI/m7iKHVwJ8HT0Dxwk4UFsPVjAAwzjZUXiPK7hXoJv5n94hI94n0kdbxQ2A/yW1/Zxuer/LrZC8Dou1XswjPNJ0Fbz3sH23/boF3XoWiSjKrNYAAAAAElFTkSuQmCC",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB2klEQVR42p3UO2tVQRQF4O+cmxjxRVQCPkBELMRK7Sz8Dz4gKIiVYCEIsbO38BcIdhYiWGhjZWMRESy1UERFVBDEV0jM1Zjk3li4jgyHmys6MMxrz9prZu29K79bhZXMx4v5rMFtBOsz72G+PKwzHsUTdPENP3AlZ504ha14nfMuvuJm9qsR9LEPd8LsIZYD8mIAu594hF1YxAROhdjJxuhcwM74v/Y0r9pQF3/Sx/t4Gs1YrwLQKezgc/Y6IwVgjXUBrjKu1nrFvMq9Nc0fCrN5fIhBVYigUL3dGsdvIspCqfSOIYzqloMSUBhuNsBoovVvK1jCzL8oVGE37ufiLObSu/iO202cDWFalYt7YdPuM3ie+fVC4UGqN3oYx6cEcy+fvJD18djM4G3BojIkJ+uAdApmYzk/i0PYiC+x7bXE6uM09uAybMHHAPUyPsOr1vNfFs+tWnXgcWw2NRv9bNSYwn7sLYpDvxWLdZMZ6XOJ4z+B3cTZeVzFjbC+GKBLq2RKrxBltPnDpaTNhYDdwmTxtCmszV4DcDAxu4ydOIB3CTOjOBwh7g4InWtxfCRg2wbY9HCsYdAoNRmVunHSGI6lvE0XhfYEtufeIh6khFUGBGs1pGT5S777BYNegW84kKIWAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACNklEQVR42q2VS0tVURTHf+eeI7csS4ymgejESRMbOEmICGyYjWtUH0DIL9CsSYgQOShHGlEEQug3SGpWEBHRw7rVwEeCxK3rPQ8n/2WLzb3n5sUFm7PP3uv5X48N/yjicCnySitADkwCV4F+d74G3ALqOisc/zgwrf8IyID3wCxQM/2xBKcl3GoNOoMAib532vD/AM4AkUVwWp5WZX3VhfkNeKV94c4L4DhwEejRf6+iPQvMAFOG1zkxfDoE7K8LvhUfqmH7V5BFwXlWkkjDPwFSoOmjTRxjpm+uSw9JOwqNpzKYEiRtV8aqTnm31JSuBAfHJvAbeAR8dGFX3OoUkd3VgD/APPC9m+aJDtxtjkaAUwFM5tk28C4o03Y6Y+UytzwcBRaEX1GyluXAgSO57Soic9YznW8ADe0XJBOX6KuEDrxWaaXOW1P+BjgBXNH9ujq43YCMQkvWD3GAuxk0Q7l4YuBIh2oaDnneOq/zFtivq1cK4JfyEHprkI0rl3PhqEDKE42Mp1I6qWGYd3g37HxQOoY8RBZaAmwBFzS0bgBjGoIVZ6RVb9iySmx4A6kut4DLwEvgPvAE+ABcAj6Lv+m8jVoURcP1wj59AXaAUf0/cILPXehfpeikk60Cx1RZ/cBDRfrYG7gHnNd+TorrWgWwpLthYFEPDMA1PUg1zZ0N59hEmJwYeFbSxS+APvH2lDyza8BNawPf8gMSGAg60fCtA3fdhCyCqjEDPzVN/+c96Zr2E7wHPF7BtXeSgj4AAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADAklEQVR42rWXyWsVQRDGfzN5iVGjB5ejC25IDkENxjURBRU9aFxQISDeBBEM+H/oRbx6ErwIQlTExOUkihsRiRDUQBBBxDVGTfLmjZevpRyn581b0tC8mZ6u+qqrqr+qB/+OAAjJHgG1jYY8ylYDbUCz3mPtHQYe6jn2GBcD24AlRi4GfgHPgTe+U4UCvARMSShttksm9JxsR4bsb+C8ZEPrAKfscoawmx1prjTvO3PoOOdkAglGUvwIKAI/gQvAexkX6XcIuJsjBHuBZXoOgZLCetKcfAUwAlCQcK82xsAZpmdcNF44YsEBZpmYvNI35x1MMkY5M90meEF5NWTWZiYNsC5tVCjyAiZH5FlrTOKFHgNK0xSCUpYBTcbyxmkyoElGlByGDcFrc5VGU7xSy4gNhjv0SNoVOghsrxPl+ih8H7DHrflAChUkW728VLYI1UuuwbJokGCwOcAxYA0wI0PJBPACuAJ8y2DGik6wUkQRVzCHgdYaPUiomD+R0gmxVtqMDLij7ZeqokEtibtVyrLKcEnl9Kx4/J1hy92eCuk78H/eOi4AnwEO6KaR6TWGnc55e4Lkc5iz1XJJtkqdzmygy3Q8lRDSUmCRky3k5G7XEywHngJjUlTMyRmuqm4B+uXpLmAwLAPu4hWb+M4XeFwFC25WGZ7rWjufAUV9ewYcAtYCB4DH+j5ZZcZPmrya8iWNc+s9oBv4rvVBYAC4CuzSvmqufOBLQgt+H9gv8E1ivE7ghwpWv/YVM4AaUmbRx4KBkqTZgI8J/AZwFLiuxBlXOAa0P0q5XiWtuzmh3wW+1u6wFu8oQRD4F8OOsTzSpe8twC2tn0jwwGJgA7Bevx1AD/DRcEqbNaBVJ2zR+0bgc4KEImNEp2ks+4B15vTtRjaNTWPgWrJ+WBd2Ap+0eTLhyimtfzWNi5N317S7TAG7Dcxz/8ZsRgaK0QMRTrkxKk99MMqdIafEmjY/xqW7z7JrMnkCYKEMaErxTmzu81vFtFRFL/C3f6h331eupYuTBv8BYYwWX7A/G/oAAAAASUVORK5CYII=")
IconData["shot_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABhElEQVR42p3TT4iOURQG8N/7fm+MjMJIYzFEyEYWshELNpIlJTsbxcrGSlaWFpSytLS0M2rSTEmxMlJEbJCGmCxME8M332fhuXWjLJy6nfe8555/z3luMzs112CIEWzxW77hXb6Lfx02xv6CT2jaXNqDZ3iZ8wRj8fWib8T3Am9wDsNmdmoOprEDZ1PtKx5hUHWwE9vxE6dxCuNdsm/CJO76W4bRr3LgB05ifRlhFBvS7kjVdi0tVsQ3Ft2UDm7hdar1o9u0P4g9iG+A54n52FRb+C/pEnwU57EqVVusxh1cTuUajyYjLHfYitsJruU+LmEBV1KsTtQvwOxKcB/fM+NTHMZbHPyjeulgbUlQQGqygTbE+hBmLlSBZTsHQqiJtkK4h5uYwPGsVdV2L2N0ofU4RtsKkKth4jXMY28C11TkWUrCpfwbdDGu4yIeYh9OZPZjwQLO4FDuH8lje9/hQRCfSfBiGHcP+3EhCTZjN5bxOAUXy2NaiW0VAwvi8/j8Dx41vwDpOGtL+O7/HwAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB/klEQVR42n3UT4hOURgG8N/9vjtG/kRpaqQoKbJhLC3IUixkoSELRTZTMlKyt7C0UjYWkrJhYSFbEquJhdSsJCY0zGBo/nzfvRbeo9Ptft46fec7573P+5znfc4ppp7MQIHa39iYzb9rjxJrY97HQtroxKhxDK/xER/wCdcjrxtFYROmY38G73Ev1osSFXbhQQA/Ry9AplvYLeEltmIZIzgZxMbLSDoYDM7gTgtIP5sv4FRj/w2OYF0n06SK43YwlMnRFt0sD2ZjrVtmgB2sCeAifgdFzriI71YlDQWzhRC6yEaKegBwKvwumrJYhG06GI2utUVyQt0CWAfDYcwlhlWAjTR0q7GCuQGFUoHfMZRRZRtuYywAi4b/HuM8vg2QIOXXieEtHGphMI/POI6fYatuoykyEr0ONmBfJFVRfSn+nw3Tz0fBItaLlq73crtUUTkJPxyJ56LYenyN3H6DWYXT2I5rZVODSHobvjoc43/WgcvYgxudrMsJbBK7sSN7HKoGYCfdjBg/wsf/jJ1EncBN3MUXXAqgqwNuSj9zw1DScCWOdyHA7uNEJsUkVsdaAhgLz/awBXvjGftVYjF0msIjHM2YXIxbMIGHsTYauXlUuIJeGVVfBIOdeBX069g7gP14GkebxTg2B9AynsUTVqS7nJu1GNDRNkM3zV39AZodjCR1XmXEAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACZ0lEQVR42q3WS6hNYRQH8N8+d3OQcgtlQNJVMlFmTJS8uR4xIGLCzIhQJsrAhAkmFANDeRSp21UGJsSAgfKIvMvII5HXPWdvk7VvX9s9916y6rT396211/9b//X4Tnb/+jshGUr/TzKUeSwaKLARm9Cd7L/CPnyLvTKxX4T9sc7QxhOcxFtkObpCsR9HO5zmKF6GoxRgDXprtr3YioV4mwVFU+OkzUC/nYT5BndrFFbvE7EEY2I9IaKdh+PYU1E0M5QvsLdDFOUQ719xdQjuz2EO5LWPfgRlWW2/PUwiK/5ztDCQRpsnhu14FqEcTVXVwVsB2JJUCfwKsGbi/F9lIHzlVQQZHuIAniYUlUOcthjGcRVJPw7hBmRJo422efxNQ+a19VxMrtFUOfuER6Po+ixYKFDkkYcmzmDzEKCp9GEHPg4DUtaTXOAgtiXrssb5+yiE1TiRdHMnqUp30GhdJKlMlNX7A/RgS9gsjw5ud6i2tNQHAfJag1VhthLgImy6MG6E3phd2TQ6GGQYG8Dz8RwXR0hwVzwX4XHMoj8SWsTej3D4K0b41CQf2QglPCt89NQjKEPxAYujWnZhQUTQ6NBoWe03EL5+pgCtUH7AKtzBKVyI7l4Wk7aRDLOUrjLJ1c+kFwYpmoQvWIF7OIudobuGtViKm5geIBWlzWTk5FHKJT6nAH04H85Ph/PvyQ11BRvicjmcXJ/bcSShp4kpoTuXDrvdEdLlSCqMT3hej1tYGQ05JvanYUYtJ68DtB+N9D7oxrMYGY1aT7Tj1N1xi1Wj4BguxUGrXLyL6DMUfztNRyvVHwm/AS26soh3Q6nUAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADVklEQVR42rWXy6tNcRTHP799zj2uZ1cYGHjkFSnRRR4hBpRHXgOSkYkYCWN/AQOljIxJJHmUcIkSyfUqSh5lcEsG8rhe95yzTb5Ly6+z99n7YtWvc85vn99vfdfru9YOvVf6cBK0mmRLAFIGLxWgYT+q0cNUayYwB+h0+wF4AdzNAWH7K4BJ7lwKfAMeAq/8gWpkeQ04DuxsAc5kPvAASCJPmWWrgOsZZ3/o/gNmmAfQBE4AOwq40M7kPW8lQ4B98sh+oBJ6r/QZ8oXAPaAOfAWOAX2ytKHPZ0BPgRCsBabou3lqJrBbvwMwDXhTdZYs0YEqcAg4mmNJ2mb/co539uj7AgNgMsyBeS4gf2SsFDQKZnqIcm1AHjQZGleBt6pDoSiqMJZGxl5HrC/JANDk/0gzD0DNIe/4TwBqAtE0HT4EL10JvW2TbGUldTrM6DcGoK6Nk8B34APwqAAll82JAJwDNiohbwAhRL0gi6LzLv4rL3lFnlrrJe5ISnqq4islpuKRwHZgrmiTHE5/ApwCPpbskI3YA2bBdOA8MKuENQeATSKYZDA5kzggJ6X8p0LQasV1PB04rbad5jSotvFbBHRLSU2A4lVR9h4EtqlRNYDZ6v9pxCt5OpPYA1PaxNDKqAc4IqsPC5R5ggIeCI6IQsyEocAYNkOTznBg+SDcngKTgQl2tlqQu20mmKpp6LMuqhfkDOuqS4GrCuVy4HHSRrnFK3X1O0bKyxCQnzmGAqOUc5lJU9ezXmArMA/YDNzX85+DyXids8F3IItyza03VOOftP8YuAacBVaXZEuf9MF7JclQflNN4xOwWIy3DPgCbFEcqzkgEoUsXvUsIgpKkk6n/LOUX1LdX1Ti9Csc1/T/RhQOK7WGWz/0OTYe7SwE/ULYo8vN8stAl2I3SiDWA7f0vzPAGoH1pTYRGO8S2bhirxRXgKcewDNZul1uXqTfXTpQc83qIrAOuC0Qp9WYjLC6FaLRGTwQ1HOeAEnipuD1Ur7MKR+IBpM6MAK4AKzU69YGvXIZK07IUG7huQrssrDZQGKvZmOBOyKcdvJWnnrnSisIyF6xps+Pft19wbOrn4gMxDgBqLWg6NTV82vgvbxTdir6PT9UW7wZv9P6V5NWnAN/AP4FVbIDVYX2I+gAAAAASUVORK5CYII=")
IconData["shot_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABiElEQVR42p2TsW+OURTGf/d9vyhpm5CKdGlEQ9NFGrFWiI3VZOsiYbL1D2AV0qmTmPgHWIVNYiKCgaUGhDKUqNbn/Rk8b1yfRMRJbs699+Tc55znObeoBRDYCeznp20Cr7Lv43uAfTl/BN4BBbWoC+pLf9kHdUpFHcTfquJf1AsqRQW4CxwCzgdtA3gAdFUFc8BB4BuwBJwFpsnrz9TV7P9lHVeH6nyTPieAvUAbLlr+tAbYkdhUfBkkeBN4kVKH8U3K73LuEuuAp8l5WyoV/ssGST4FXAR2BbUBxoE7wKUgUwGVtPAd9UBkGbX78csjcv62GmA+yEPga3p8DJwE1oBjI+h9Bbt7ZnuSShRogAXgTSbzU5XYq7MIPAdmmorhFrgOzABnIitV/204G2Ssp4GJpiLkaibxGrAOHE3iZPw2sJUHt3LXoZ5QV9Qx9WFF4qJ6Wr0Sws7lP9xQX6tr6jhqmw91L4mf1W11Uz1SMX5ZfaI+Um+rh+vPNAbMVhPYM74OvP/LHJUfu3paXiGkOgwAAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAACDUlEQVR42pWUO2tUURRG17134ogvgiEQEUTEQqzUzsL/4AOCglgJKQQhdvYp8gsEOwsRLLSxsrFQBEstIqIiKkQkPoZER2My9y6L7DMchjugGzbntc939uPbp1ABCkC2ZDKbr9IuHWBnzGvg5/BELVXU0+oLta/+UH+ri3FWqUXMp9R3cd5Xv6t3Yr/oAA1wBLgfnj0FBkAFvG7x7g/wDDgAbADTwAWgBM4Tr865JZdi/b+6FFHtKrOcNMByvDQRYzkmh1VmB/A19qpOBlgCOwK4iHGc1Nm8iHvbgCIBLkelPodB0mHtxgCnh98DU8B6EbQpgRng05iLZYDaAmh42AV6CTDJ9EjeBDaBHv8qwa+D6iO1p66qa6F99Zd6L/Es42Ouw/20eGi79NRXMb+VkXwUsFI7CXBS/aIO1Fpt1PVYn40LPfVD5l0xjpOJLk3wKCW+Gxm5DJwAdgPfwrYeKVYDXAQOAQuoe9WVCKuO8aX6diT8N1m4ycP0DzwPmz2pok14VgLzwFHgMLA4cp57VmW6FjweErsMTl0BbgC3gRXgWgBdH9MpddaKE6nlNqNtrgbYXWA2I+48sD32EsDx4OwA2A8cAz4CfdQJ9aTaVR+0UOdmUOJU5GumxaZWz6gUaqrULLAA9MN9w6MuMAc8jtAK4BywL+5tAE+AJaBIrVdl4RRjPoNqhDJt/d78BTcNO5hqYy8+AAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACZklEQVR42q2VPWtUURCGn7N7Q/yIGhJshWAaGxstbAyICFoaa1PpDxCMpYWdjYggptAugihCQBQLW0U7BRURojGJFpEoWKwmu3tfm/eE8bLZbNSB4Z6ZM3e+Z06ShCEBa8R/gASoMFEDSmAcOAUMBv4ccB5omKcgPwZMmk5AG3gHXAMWgISkuiQkTWp9GLFMzd/C38vryH+WtEdSSk7Rbnvab+vPQpjzwItKCvN5ADgK9Jne5mj3A1eBc9iTg7Y8a/pfcEJSKemRJIpQFAG/gLo9jPx2l0Lm/BdAC2jGaIsg2Pa39GUvXVU13rLBFqFLAFZtrD8o/1toWleRI0jAG+AC8D6kSB28LbsozpE8Bi4CTwBSGLReh4fNDGRRofcBw5U0ZWXfgbc9TH1yFkqgzMOzVdK0pKa6w0NJw5KSccO2zYdLVtA2lsa2+V8lrfg87X/qXRTXsgOZ8VJSy6hgTJJeSdop6aTvlyQN+L9OUfzBq4Va1Ct5bxnboYPqxi0bzMbomowtvQ5elx1yvyRp1edvrkPV25yyMddyqroqsJeFV8Y9D+C4l2FZadX1WnjEOvbGSc6hFcAycASYAM4Ah4DZ8AZ0UhyxaV0r0UDLl8vACeA5cAO46+k+BnywfDN4m+dBoVYrYRbWavBR0g9JB0zfDPl/YN6IpE+u066Q+35J291Zg5JuuY53Yptel3TY5ykrbhglacZ3o5JuS+ozfVrSvKQFSYuelwzHs4EUuuB+lyl+KmmHZfu6PLNzks7mgUuScj6H/IAPhUck7vwGcAVYrOyo3DW5Fl+An7k+m92mvUI9r+/fzNFZnAWU+AQAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADYElEQVR42rWX34tVVRTHP/vMnVFLfdB6tMQyxAdJxya1ZsQeCnzwR4WJvfQW+KLov6H4Ir1FryEIgoqipj6JISkGKkgqiAQh5a/UZube++3lu2XN8Z5z753RBYt9zt57nbX2+vFd+yRJBErmNtWUADF9GgBa+aVRWpR5GbACmB3mE3ATuFhjRJ5fD7wb5AQ8B64At6ZqlJCUJBWSZkv6SdKkqmnYMoXHzAMeP6uR/U/SAcsWklIjWN4GfgR29ODCLFO33olmAbvtkT3AQJKUYzIC/Ao0gWfAQeBPoPB6AVwHzvYQgo3AEj8XPtwy4Hu/J+B94A6SGnbdbkltu2pXyb2vin8I4dgmaUoSvhHcesMJOiVjfaJWj5keQ9QAJu3BTHPKVRBdOuhQ9KqwTK2KucGyvqLCgDavh9p1BgwFywdfkwFDNqKddcQQ/BFK6G4Hr8yEFHTkQ98BSAGKE7AVeACcewWQW1Wim5yQJ4CUSr2gCqLrkm1GRkYDimkmX79yA7FSsgHZPfOA7cCHhs0qGgd+B34GHs0oXKGpLJV0Xf3RTUnLK5pTT5wkFXbjRWAYmCiVZ9ndRalFXwNW2yv9V44t+dQnqmvDbbfTvcbxe5KaXvui1JLruIjeyqdZ0sXylk97FtgPHAL2OaEELO3Soim1/XbeW5QWu9XwB77pvAmMhTD0A0iLgUVZttEjduc7wXvAb8ATf6jZI2bkrvoJcNpANAZcLbooz0mnUL8LrVx9oiDAOrfh+U74ymxveu0y8BWw0jB9yesTfbqeIJcvvpNVkJvdeg7YAjz2/FXgDHAY+Nz7poOaKXqlqFB+Hths5WuNeKPAv8CXjmOjxojCIStzs9PGbE3L/wFZ+RMrPw58Axxz4jx1OM54f6sUjlxqrcDjHt966WpnQPjagPKLpPmeWyvpgefHPT6WNOb1uZJOev47z+UL7juSPpb0kccRSd9Kuh/Aa4WkFwYsl3TMH0XSGkn/eGMWaAUjRr1vjqSjklaFH5zhINsJTSXpSEbF+GeUn0cl/e3NE1acedLzDyVtCDIpwPCWLg3slKQF+W8stuPkGF0w4HSju8Aa4K9QWsnJttOoGfPjqb99NKJr+UqWgLdtwFAHiFao59vAfSecpnk9o+pKNlNq1PSCKQb/Dy0mwy3oZIwWAAAAAElFTkSuQmCC")
IconData["stt_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABSElEQVR42pXTvUpcURAH8N/de00RkJUQDCSNgiAEm7BNIihYSgjpQtAiEPA1rGwDaSwkRUiXF0iK+AJWVpa7hYiLiYKFglnXzaaZK8fLXcWBYc4583n+M5O7SVnISbzCQ/xJ3m+lRsi36GKIv9iM9xdYxQreo5lmLOUjdEI5iKAZ3uApPuAybNfQLpLsA8yE8z/k6IduEV/Dph9BfkNRg8GwUlmOHlp4F+cJ7OKsSAwblSAp5TjEXuDyGcdolAGu7gB4iPHAqMBjnKRfeI05/KjJPgxuRwWfUl1Z9my07zS+MEg4i3JfBvJFDXZaJapJFSX3ojPf8SVsiroB2sFWnNexjW+YxlIEe17xub5keIZ9/MQCpgKXjej9xzrn6g40Y3Q7uMARfmE+aedIqi7MAZYrszBygSQTWALUxXk4jkVH7kVP8OAuo//VOEfg2z3LmAAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABp0lEQVR42pXUu2pVQRgF4O/s7CgGFSJqFAlYWKkgVmJhoY2FhUU6i1hZCgo+gbUPoPgANjYWvkAUC7GSEDle8IKIjYlGULycc2zWhnGzc3LywzB7Lnv9a836ZxgfU9hTjHvpq3w3rdoIoFy8gWV8wjMsFmATx1T6mxh1tMtJ+gjv8Cr9vYZQr8VuhL14ix0Fo79J9gbHcA1zma/Rx1306g7AQ9jZYl5nfQ6zWML+AFb42CW3OZsTHVKH6VdxGCsB+5H5xw2p2taixjrOFgy/4kvWR21DepswXAvDfrF2uzS0ZDiYgGEVmYsxr8bLEBmWBQoPsYBvbeotFWs4hTN4gBcFW1Xx8zkcxffC8TKGaQOcx4UkmG5LaNxdxvEc8OuA/srB/86+JwE9gucBH3U5J8U6wK5IWm8Z8wEHcTLji63b9V9B9zCTn5YyP5skt3AlDPfhM54GqBrnnkhexXtcipMzYXYdP3N/5zd7ZUrQedwvpDa34Q/uhHn5lJkEVORdDdgCdm+wbyLQbfk+HcADGU9vxqwr0zCl0pRNvzBuMKboJ47tW9n8D+Q9cySTDKftAAAAAElFTkSuQmCC",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAB+klEQVR42s3VPWgUURAH8N/e7Un8AL+iEMQguUQCghC0UGyMiJWN1iK2FrbaKljY+dGYzsJSLMQiiKBYK1r5icUVFqKFqFHUZO9s5mB53O5drBxYdufNzP/N/N+82Uy1NNAdYsvQHGAv0DMEHGZwE8/wHLcwl/jUSlaT3X48xKbE/hsnsIgpHE9wlnEHnyvwNZDjRZT5K0ouAryHT2jhXOjpczKw8ipq9oZjMSB4Jd7Hwnca7aimjckyYF5B2baaQ+pvtAU7gqJuKXYFd/ERWV4DktVskuEb5nF1gP0D7qGZ+3fZitt4nFQ2hk6/mjzJqhG8jyJLOIDL0TktvI6DH3gGvXAcVQpsxO6IXRsJjkW3SSleg53xfaSmi5bjfTp8JwJUXc/DWbzC+hLIsAoyvMTFWGulTnmpvcaxITZYqrqFpfUf8b0Z26u6rlFafB/9PIl3+F6iqS/dErdPsSvWOnUV92/vVDhdD/18ifciOY9r4XMp9PnQm8M2WcQfzIZ+IeZOH/gLroStHZftbXCf1dCqEcbpoKYT86h/TnPYF60oEngzavZpFUfxM4IXcDhmzgQO4UapojOjgkscZ3G/YhT38AQHVwtuQMAMTgVlXyPjPRW+q5JG8kt8FG2czq2hUjVNu4l9PP4Redi6I9z0kUsssC665oH/Tf4C0IaRh20kgJ8AAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAC30lEQVR42tXWT+ilUxgH8M/7u/fnz8xvMDMZrPxZTMifmZhsLGQhSSEWJCsLC2qywqwsEFnNhiKKkESKhY09zQKJ1OC3UKYw+TNy/czcPzbft06ve+/73uumPHV633POc57zfb7Pc55z6CYVejPmeplfSqqOOpP8X4ircTZ+wqf4YYpef469UaHXGeA5eBmDLK7bz3gG6ws41JmBKm0HPsS1DQ/KsLyHuzCO93djT/o1M2tx4A380mBsZmzhuShuxWDJwBh/5f+R6N/a0Gm2Q2WYqpa478EmziwYaco43+9wKXbiWZzbYECceByfh5Fxm/c3ZvGoxasJhti7aA70W+Y3ig3apIdtOAMHsavBQIU/8SKO1eNtACYLZvYJHMDTLcfwiQAe9q1WNvBZjuaubFYVDA3wegHEqgGs43c82kF3Ipm4ShmkWn6Cb9K+xlHcH4f785JwXs3vIqdwHvZPmduPl9oA1MdpWdmBI9iH07A9ewzxcRn7JoD6qFyAm/B+6ny1ZGk/huvx7qzYz6oHh6NQJ9EdBSuTDu1A1r2W/kMJ6emznOlPOUbDUPkPujrmgGw4TAkfzbt4mgCOB/FG+t+mmq21HSf8mvtA7oMefmtD3DT8RdDuS/8rfJSxU3O8rvBB8mYnrsrY5ry4TwNyUW6sLVwWI9fhZIycDLXDbFyP/4hLYuPejB1PNez8UKnP/zsx8FYxdwu+n5F4X+Ka6G0PaxO80LCrCwsVriweGYeK+fPxMN4M3a+mup1VbPR21p3AxbG3ULWt0T5YeHgYu1vW7Q2oes09i3o/DcRjhcFNPIWbcXnifUXqxPN5402SFw/8m82bIG5LjJtx35oydgQ3rGLzJohtuC9JebTIj0GO7Su4vdBfyeZmGFtPmR3jySkJtrbqN+GouKJ78X6QsT8CpC6743mv3GUBNK/oKtfsKN8q/6NlKV6UskkyvpfaP/EfSl1Od+PO4sKq/J/lbxWp4u6QeD6fAAAAAElFTkSuQmCC")
IconData["stt_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABZklEQVR42n3Tv2sUQRwF8M/enrGJJKgIpo0gqAhqo0W0sxFiIcTSQrTQP8AupIqVYCcW4o//QVOLYKUWElIFLCTBoCiHKWKS27N5J8PmzBeGnd2Z9+a977ytLs3/VFSFAY7hLL5hufi+p7rFvIMG1/EEx/EHz3Af53AqRA2W0Ou2Tj6Cl5hAH2O4l81TuIXtYD6UBJ0ATgTcoMZO1i7jefbshGSjbaFUUhXvdaxcwFzmk/iE36WFToukrBpraegWHuM7OkOCXfvXAIdwOKqP4kdp4RrO4PWI0wcZq1HwqFwbyj6Z6/sVC/1iVJF7EXdyaLe8e3iL6fh8kw01DqbjL3AV79p2uyH5iC94GjvzmME6FnAeN3E6uKadxAo38D4KHuIVxnEbD/JcKRL7j6AJwVryvxjJU+jhM66EvE5f9vwLw/D0knv4iruJsVHgsoklyZB0HZsBHhgFHhXlQdHl2Vxr/39g+AvkVmAGtv3fQAAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB3ElEQVR42p3UwYuNURgG8N/95o5phEmmmYSdLKRkpVsoNorlzEaJrOxIWZCMsrD1F6ARFnaUf4CwkcKEkQXGTgajaMb97rV5T31z+u41OXX6Tu8533Oe93mf9zRaU/P6jAGMIB1qoIsivirxjtiQbaTYWbzADJ7hWAWsE+s0OwmgmQEWKHEZFyvxjZiOC2/iEbbgDwbxFEfQaGbsSoziTKzTJe1I/wLu4D7GI97EbB3DpM8mrMmYN2N/HOvxEGMBWOBzr5T/NUqsxg1swxKG8Rh7/gewiQXsrzD8jq+x3y2ylBsrYLguUn6J17gUTAdyhuUKGBb4FRYajf/f5T5MrB5gAj8y0+ZG/4bd2It7eFPx4zLHH8B2/KxUvDo6MUscxOG4YDBPIek4gx0h8PsAXQzhl+LckwDdGhqW+cVVwNuYxFocDaZDodMQ5nACu8Iyd1Nll/Vua2o+aTiMt/iAfWHg49gcnXANG/AKn9DK+zhVuVup3qGwxEecx62Ij+A0rkRXTARQo86oSfAidNyJqyEB/A72bVzHuah0I2eXP18JdC60HMOpAJuMdE8GWNHLWkWNNQqswpd4B0WvLoRFapn1Akyg7YptZittWfYxfd/XJjF4Hpou1lmkbvwF5HSBsyIIlaEAAAAASUVORK5CYII=",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACRklEQVR42p3VT4hNcRQH8M99740ZUQYzLJRkwiwoI4VSYmuoWVpMGjsLxc5KFrNBEhaUBcNSxIqyUEZZEFFmhDT+JvInRmjmzbM5t27PvW8ep3517+/8fuec7/f8+SUbDnxWICVMTaNLUM7RV1FLDzYysAyncA/3cRY9oSuFkcmcVUsNVRoYX4sbaM/oerADfbiGpegNJKlM4CI+IqkUIKjgTBj/jZbYn0QrhrAIW3E85/57XEa5UhD9SqyO79aMfkbw24nNOBlIarGSQPAqDajeQQq1M8tjnaTG5gWK3kzCU5SXAkUhRWk0RU4SfAsUx3L0b3A1j6J/kfm4gJt1yNowlkdREjmoNulgHOsxGLy3YBR76qslS8vEPyCoYg6Wx92ZEWBbVB7UKnUVshCvm3TQjvNYhy/4VdSxqZPdGMGsQFJrAkGCxzgYey15DZWWVwdmh4Pxuu7MK+Uf8T0XC4qqrpTZfB71vBhP8T102aRPZfJ1F0tib6wIcXZiDsd/f0Q3GP/lODOV+T+Bt9gZe8MZx7kOSniB65GLbhzG/hhapVhfcQh70YV9gfZ2UPTXeE/iPUip6sIDfMJ2PIo8rYozI/gZAVzBCmyJZivn9VApw20SeeiLpD3EaWzEB7zDmqBnNIwPNDKeRZBKerAbR2KQ5cmtoO9OI+N5L1o1LjzBtujSfryM4TYQo3xTM8aLXrRqxvGzWLuifM9leiFpZm4VTdOpOn1HvBGVTMnWmpkn043r1NhQzKnJBh3+3w7gaN3UbVr+AGT+ow+CW6JmAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADQUlEQVR42q3XW6hlcxwH8M/ae58zmMM4U24P8kRoMmeKpDwL5VLjYSheFB5EUZoyo2gMXlyKJ4lyT0Yakry4lfuliHI55GEi5oIcM529zvHy3bVa7b322tv51Wqv/2X9ft/f/beLC+46oAUV6KAcctbFClZNQb2Wwlcj/DRsxgb8ji/wW+3eOL5lFWyvpfDj8SC24ejK+UE8jh1Yrtzvr4UFijzH4S2cW9OgwDzuwJm4Kq7oBeiJWQ9AdbCE5wK8wGoTgIHP74vwI5iNzwe0Gs0vx214AJfgqQa+G7A7fPq9Bu3LaHFdNJnNfv1eL+c34WF8imdwQs0CcBiv5X2lyQUD7TdhfYXRqLtwaoL0O1zbwv0rbYJwLujbpFgXx+Ao3IqNNQsU+DdBu69NDKh82Jb+wnm4f0wa7hoXA9PSHL5MMG6MsKJioSU8WwFirQHM4G9sb3F3tRpAa0VLCcTP8UOe7xOY10fhXlMhKmp5Pikt4yRsGXK2BU+MAzBRGR1Cx+JjLKRurI+MPj6s+r4OYJAqp+Ai7MWBCTNA5f4+XIhXRvm+XkQGZt+eMnpDbb8tDe4/hD24OXvrRinTG5JG/ZjSiP4/LgZEYD+ds6yV40YAfwTxXNY/ppp1xqUTDuGXvM+Hz5/jENcZfx20C1l/iw+yt9ygdYE3EjfzOCd7i8P8PgzASn7fS9s9H2flw9sjZCa/ZZ5+1rOZjnaGx6XphPtTD6r8GwF08TNejw/vDoCPcGUieyb3unHfDL7JDLCYtNsRnntikW6TBYrKUNrJxU3p6bO4M8MDnIyrY53BTPgOXkoT6uJFbE053hyFiiYL9Gr9uYuvMt08intT2e7Br0mvYXQGHsHFWd+In8KvnGQmLPPRY5kFd+MWXIYX8G4i/XB6/+kpXNsyuPaT+8+3EV53Qb2glLgiIM6unR9JnFTpkwyob7cV3tSOB5Z4NRPx1lhhId1uXaabRXyWkru38l25FmN5WRkins4zgydxTeJhZy3AOpNWz3EDSVlp0d2Yfil7/0T4oOyuNEX7//lrVm3RRdKzrIzp5RQ9Y2QpbgPmYKxxaNo/pJNaQK0z7sL7eHPKjjk1gIG2+/HyqAFjUvoPly7hx3ebklsAAAAASUVORK5CYII=")
IconData["stt_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABZ0lEQVR42n2TTSsGYRSGr5l3LEUSxYZSSlKykaIsJdlJLJTyN6xslY2FLGTnD7DgD1hZWbKQiCgLyseLy8IZPeaVu07zPHPOued83JOpJMgAgQ5gCLgBTpP3jVBLy+M5q177jRd1M94Pq4vqgjqvtqhkUUEWfG3AOdACfAB5+GaALmAJeIvYFeCsiEseCX2R/AnUgHr4JoCdiKkHyS1AUemo7DVL7jXgFRgB5uLcCpwAj0USmFdIUtSAqxjoC7AB3AF5SfDO/xBojhkVQDtwn7YwDQwC+3983bCzqGA99ZVl9wOzwEO08JFYFuWOxuSLX7OLHY+ot3He9zdeY+d76nbEFKV+UgEdq1txXlWP1F21V50MsoGK6H4IMrVbvVAP1HG1Rx1U19S6ulxNLgkIAqLUTfVcfVZv1EN1LPy1NDklSElKu1SnkntDsvojHhIFlhO+Bp5CRE2xkQZkld85RWes9e0/hX0BFJB0Y1X9DWIAAAAASUVORK5CYII=",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB4UlEQVR42p2VTW9NURSGn3PuKWlDpXEpoTMxoBOjpgkSJgYGBp0Z6C+QVGIu8S9ExNDExMAfIIw6QYP6iGpMFZVUlHMfA2vL7m57XVays/bnu9da5333qVT6WAfYA6zEuAIE6vBk8z1igWIhzV0FngALwDxwKQPrRT+13h8ENW+d8Nfd2mbVSn2oLqmvw9+Jc1WVpZzS6QLvgOGYr4Gfkf5b4DgwB4zHfAMsAjeBqinSFTgE7CpK0cT6ODAGPAD2B2ANfMg3/ou1wAhwGzgKrEcmj4CT/wPYAKvAmSzCz8DH9EnqIuVqgAhHI+WnwHPgWkTaKSNsB4iwBtaCQt04/6rkYYrqPjADfClIWxL9EzAFnALuAS8yPm5g/FngGPA1++K59aK1wDngfFwwVKaQ6rgATEaB3wTo9yj8eux7HKBHoobtpovVJlg+p7bqbnVKXS1UsqweVE/E+EKhLlQqNdVwGHgJLAGng8CzwOFQwi1gL/AMWAamN+k403IdflJdUd+rF9WuOhKRXVG/hX4nQtN18RZseBzS4oR6N0t1LfwP9YY6lh6CEqwEpLhxn3o5wGbU0W329QVMm3dEfzoAD8R4aLvIUqu3IG8vqJJos5jJsu1D+t/6/csvAGBnAA9kvwBITuXrJZJC/wAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACSUlEQVR42q2WO2hUURCGv7u7kQQF4yOKBEQ0kYAQCAoqNgYEGxutFW0tUttapLATbLQTtRQLsQgoKJJSUSx8YhF8gGgRTKIk5vFZOFePh3s3KzhwYM+8/7kzc7ZQqaEGsLKKrACaFfJlwFKxnYNB4DLwGHgCXAVGQtYIJ0sV53fWRQWC0vk+4B7Qm8kXgOPABLATOBZISloEbgJfgAI1Pw21pT71F82ry3EWgvdZ7VLHrKYT4auVIyizHwaeJaXI69sEjgJ3gYEoiYFkEXhXKrcy4xJqX1rHjEpnG4H+KNFKYrsE3AI+AUWrjZOiTZACmAFGgYsV8g/AbaBZF6AT2gTcAB5kyLqBqRJNK8uqETXuhOaAA8B41L0LeAmMpUqtrCyL/4BgGVgP7A7bnkiwO1oZwDTAGmAr8L7DAL3AdWA/MA3M101sGeQs8AJYG0jsAEEBPAfOB68rV2ol7bUZWBcB5rLprGrlb/F7A7ClrusaCfNt9PN24A0wG7L0o68k3+sRsCN4U3WI0405GfdTkd143Juhs5LcLwEfgdPBm0wCZxP1Z/+gTqg/1KG4n4u9U9K0eiFku9QZ9XXspSLOX7stDVCoA+qsOqUOlwtLHVH3qj3BG1JfRdDR4DUrFif5FkU9on4P4yvqYbVf3aYeUi8liM60c54HSBWH1DvW00P14GrOqwLkBoPqySjZ18h4T41u5Slq3uRG1pb3o30Hklko2rzZ1L0Heb+3kiHsi3vZsnayT1Zb16Wza7GnltpMePXYt/nb8l/oJ/gqU/wonHfLAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADNUlEQVR42rWXTWgdVRTHf/PmJdZ8WJPQqKtUF8GKrQmtdNNFcCEiFSntouIyoIsKpavarFy0pcGFuLFQsYhYKeIHmEUQ3FcC2iKWgNYsBANqSNJY8/U+/i78v3IzzpuZlzwPXGbuuWfO/Z9z7/mYSBIFKAJKQC1lLQbqQCFF/1FcAEAUKB8CngF2A38CN4HfU+TKGfpqW8BKyhqRnw9LuippVVtpUdKkpI6EfOGR5YHIoxf4BjiUsCCy+wG+Ak74KMrASWDQ84ZnSsAq8AmwdJ+fgS728z1buy6pnvBAXdKG389a/qiyacJy5SwPNFAPAnPAg4FHklT381fgSaAPeBvYk/AAwDrwFvCDPVLPs/45o64pn6qShlu9A+WcCOgx+iIhFgNdwC7gNNCf8EAErAHvA/MNfh4ANXF7M1oBngUu5YTheQOulmkv9QC3gEl7oBYYEDsKrgVAaDeADuAv4M0CssI3sZ206mz5PXDH42fgJ2DcBm8xupwSfvEOAFSAR4DRlLVR4IM8AAKqOwDQC8wAI0An0O09qsC34dknATRC5THgeWAKWGwxAgjk54EjwJfNzr5BpeCG4svzIfBagl+UGvLvAF8Ab5j3QDNjyilhVLUraVL/8+4A3rDqFF5LpONMAAtG3OP5L85mpbxwApZdD3A9iIG7eYiTin802hHPZ4Eb5lUyrI6Aad+bPuCAeXNp574V/r9FoeTnXpfddUn73GAclrTpgrPpolOVVAn4f0h6wjpeNW9BUn9eo5JWAT+3gk+DtRcl/dakCt6WdNBy3ZJmzb+S0JsLoGSk+4MmYyJYf1TSGUnXJU1L+kjSuKSHgo0+83crkh63vlJRACHaU4GF70oayKnrwwbVoFeKWJ8GIPzoXKBwTtJFSS9Iesrn/bSkY5IuS1qyXEXS60U3bwYg/Phln3GS1lN4M5LGWtk8ryuOnUS6gOPASw7PIef5NYfZd065U5aPW0pgOQiTlnRI+tjd8IWUC1Zqd09YC0p0DGy45kfA386SjbRbDzrkwlQu2LlUg2rXaWCdnte2UTOapuIiYJbsjeXt/pC2+nOa/FkZAMaAr4F7WZWu3QD+F/oH/c2v1QwM34sAAAAASUVORK5CYII=")
IconData["symbols_black"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABU0lEQVR42o3Tv0vWURQG8M/7fStQ0bZ6USH0DxAyHHIJXMXRQQfdHf0nnAKh1cVBF9OlphY3QYNoCXEQwSVIU9Aw8vdyLh1fX6wDF+4593mee77Pud+6v1GLVaIPA+jFDU6iXkV+JzJxChsBKusPPmGs1WUlacdqIn3BIpawnervglcvIlVs1gKwhddNHVYYxV5g3iYRMBkHn/E0ker5JvRjP7DD+RM2cY2hqD1xP0ptIgSWy8ELXOJrurlVZK+O8R1tVQjUQ6D2gEAZ3Rl20ECjitbhUXL6X/E4Yxuhuh8iVdO7yJOoAv8bu9mr96E28x8mzgd2LpvzElehPNLCzLKfDvIRepr9mo4n+wvjTW3XMBvkY7zJxB6s4CNOkznPEuZVqv/AByygAwaj/RucRxfrMe8y+258i7OLwB7geXG7G52p3d0A19Ib6Ipf+zryQ/y8BW4DWIMROE2mAAAAAElFTkSuQmCC",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABqUlEQVR42pXUPWtUURAG4OdeVxGMpFHzBwQVISsoKBZip6CiFoo/RKtUghZqk1ZExE6xiYUEUxqSRixsRcvEz0JU8Dtr895wvNndbAYO956Zd2beM3PmsFbqPrrxrHWxVWu/CX/zfwZn0cVEdO/wEjN40sdnTTA4iAX01lnzSVb6rjJsspzCQ2yLfh5zeJX9HpzE0ey/4EIwNVbK6AfwPdmXcN5guZjj9/AN+8ua1ujgeQBvsa9g3mmtphFdfIzPYvSrTTodw0oaAVuGMGxsl4qanigB9xJssV3kIdJgXsT3joLmZBo0m281QsAG8zT/XVQ1tmNnjG9CfyPyOt9dGKtbAUZlV+KbRvSaI3/FchSHNsiw9FlKLHCrUI63r8CAGa6xA+/je70E7MXvGG5Ht3nA8avY4H58fmJ3u/3TxZ26MuDxKHVTBf5mGat0msmd6uFGAHXRrDrspotBeFQma9gdxjl8xpGAj+EXnmXkqgS4hsux/UjAydiWYSzd6fdEPUjCZo7h8QDsJ2ztJMtdHG/V9AOuFsya8ky1huFP9HNhPXSsRhm9/+QfF6l08GyJrCoAAAAASUVORK5CYII=",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACIUlEQVR42p2Vv0tVYRjHP+d4/REhBqZS0ZLUojQYRA46OLTUVBHUUjTaXkMOVjS16NIgFA016D8gihKIQ0VL0FaDSxaVgWbFvabH5fvG9x7vOedeXzg8nPd9nuf7/H4g+zRR34nzeKOMuwjY0f9ZYAjoA3p0vwq8B5aAD2bQdpE1DngJeA0kOd8WMAcMmzdRkfI24HmGwnVgI+PtUR5IpIcDwKIEtkWXgVHgDHAMOA4MAncVngT4J/rMwhXVSui0ub4B3CwIaQtwT3kpS/ZhukhKotdN+bqsDC6XRGOrmpJZeU0gFek45yAR0Ap8FFMCXDULi4oi8IxbPubNOADO2+NCyrN6Kq9JQJ8sJ6ccIQAATOWVWo2TiL8CvLDQjDhAn5j+Am8ltLMPkCW7O+0AXaJrwHcTagQgAT6rSACOOkC8D6VZQFWNGxR/E+0Gjtg8ooFER8AJoNm8+Q/wTrQVuCCGuEGABLhs/2+cYcASuwIctKYqOqFje4FN6filyVsV/zlL1pTumgtCFdvceWXykw4epl+/ajkMrrGCEex3T035V+BwWi507S0xhZny2BijGsrbgRmTKdtu2DMJeoBDwJPUdHyZykcAa7emLMvzO0CHPKg694EfarRVMW8ZyMka+/ei3v6Iv6LS/Al8AW44wErOWlwDOs3y4El/wTqd9TiNArdToUiA38CEQGIb57G22RUtJa+2RDPtAQ02Uj13e84uo5ysrUAptqQAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADOElEQVR42q2XO2hUQRSGv7m7MUZR0CgpNKsSUdDGLkh8FzEIxsYija29NoKNvShBMBLQLgh2aqFgYyM+QMEXoiJJjJr4ICZNjNns5l6bf8JxcrN7d5OB4c7jzHn+c85cR7bmgEjjuSq0OX1jIMnCmAwMrdAmYCtQAJq1Ng58AT4DMxXO1tScsSYCuoGbwIgsC3sMDAMDwLFACVePcN+6gReBsLIs9b2oNUvzDOgy/DIr4WO9Aug3DGclKKnSi0DJzK8YT7pqGPDzNcAd4LBiGAMN2hsBHgNvgFGd2QTsATqAzaKbleAccB84afCRVIr5CuChsca79hXQA6yu4L21wCngnQmV99o9o5CrdH36U4RfAhoD2nzQc2Z/FdCXosTlQNYC4Z0m3j6OZ42H8lXA5Gl8uyAeJcPvQKiEM+5/aaxPgF7RNNR4lawiNwKeT4PENq9Jl7E+Vhwb6r3HEhAJM8Pi6b1w0Mr2mg6IaEZEPVrPU3/zZ0+L54xkXA95NwYZblRAcnVaH4Z3HfDb1IdPoWE7dN896m8thtY6Q4GuYSI5JWCb3SxoXNb89TJYbxVwwFvNy7K+YBVoDg59z1JKa2gJMBZkwQ1WgSg4ELP8LUkLjRc8EWwWlsn9FoytQb0ZtwoMChy+4OwzNX6pzSO/wyS1Wcn8L2u9NyidBraEGauO5pPYLiHfFrYIcJGIysBdU0abgHMijpbo+gQ4LyNLWr8tz+RsGLabClgW8d4lZMO8KXCxeM4BfwweFtSDq0HhGAZa6khKeQPmMSngeV5M4+djvR74ZopSAjzXelZPeJoWvZosryG9tqK0W+ZrfaepCSUDmrZFckZa2t0NfAh4+LdAlGZIqE0P8Nfk7QT4CRypoIRfOw5MGuFzwBRwIk2mM0gtAO26p1PAGeCQ4hdL60lgp08iJrtFGrcCH4GVEuxD+wC4JvcXgSfCxrwSbcCvKs9t74mjKSDKG8/ZmC/Wv+ol7SITm426IsXgOvruXTyaktv9eMh4JDzv+U7r6d7uzznlgIkMPx29GTDQl4HPDynhLAbalHjCd0Ci+aB+SFyFUu339uvBkaTwioFH+pl1tfwlZ6Wridc/IlAwv9L5fssAAAAASUVORK5CYII=")
IconData["symbols_color"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABjUlEQVR42oXTz4uNYRQH8M997h2/hoXNuOVXtlZixUIhCyGNspgNZWGh0RSKf8BydpYWU6xYmWJhRcksyIhSyoyEYUEokat7X5vvm7fpllOnp+c553zP9z3f87Z2TMyItXJWObdhM/p4i/d5LxhoXOriKn4Sj7CIB3iIBdzD0RS36oadRuc1uI7juc/jRXJ24mD8Ks6hjUGn0f0GxvEYU5jzzwoOpXgSPVxAu/6eiRQ/SZe5FLXjFe7gAN7hPPagX8JgKkln8R0rAtyPV3lbxKWwmqypbcEuPA/9EorL7U+a3cY37MPqgq2h+SwJxXCr5f2JV+ii29S005DyfzZS5xa8xi/sbYC0hhTV8+piO95gqeAT7mbrzoTRyBCATmKXsQo30atRryQ4jf0ZYlnWvYdTUexrdqKUUJ7H6STO4kQAS7yK9jNRYBwfMCjYiFsp6mE09MYCMsgqTzfkvIhrGC3YkP0/jJUBuY8fjZ/mI14mth5HcAxrO3iaAa5rTHoBvxtqLGE3NoVRhc/48heNZ2wTeH6Z5AAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAB9ElEQVR42pXUTYhOYRQH8N+9721SRjYYibWFxkwhH0kSmZIQpmysJAtqFtjMSsaCUiiraWLpY/KxkEw2Ziys1BSRWJomUTQbvTPe1+bc6XG9Y8app+c+5+N//uee8zxZ97HbKpKjUdEtjf3HfL5FxaGGX/G9HwfQhY7QTWIcj/AkwNKYPwBLwwbcwDZ/yxpswgm8xOlIMAtaVMD24S4Wh34MI/gQ57XoiWTbMYqj4ZOjUSRg3RjGIkxE9octWF5Eb1TRgQfYjLfIczSD6WCATWJ3gNXClq4c97AXX6OawdDPdqkHGwP8FN6hLZjPVFYjbOM4E6y3Yg8aeSgOB9grPA5mdXNLPXzu4HXEHikZ5liPDE9jz8wvpc+z+O5ClmMJlofxU2T7H/kY+wq05xWAhbJL/cvf1ixLnooxaSaNWaikMZ8xVTIci2y9cW8bSeZWUk7HMhyK2BeSoKEYiVW4ktzRbI4ya+FzNf5dHbdKwBre42YEnMQ5TP+D4TT6cTzO16M5tfT56YsZbAbLy8lYZUkDClzDQPgO43xgNGorOw+Ku3gQ37ElHHdEKaMBkkXyAZwN20/cjzluYKJAO57HXpXOFoO8Lva2WJfi/A2ri8gyhJ3JUwZfcCFhVoL2Vy7DTOhHUC9C0deik83KvJXyBrta+IDfvRp/xA631EwAAAAASUVORK5CYII=",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACjklEQVR42p3WS6iVVRQH8N/3nesjwpH5RBAymkjRoLSJFjfQQQ4kK3wghhCEgRGJg7CBik4a5CyISyj2gKBGDUIwSIgwQxCvQ6lBLysb2EO6es5x8t+X3emee7pu+Njft87a679e/7VP88iOk4asDrpGrxbNMN2xGWTNwIF12IC1WIYefsQlnMPkbA6NzWC8n+cZHMT6Wby/jc9xLGBtdX46vEHjC3ESH89g/Ab+GHBwE74ISK/KwL8iKMKF+BTjUW7xJT7Aefwc2SpsxO6krovXsQJ7k64e+p3lD21VCd7HloT+N17CflzAT/H+Br4P8AT+wVO4hUfj9NnY7LcRdLETz1fGNydVRaetnk5kt5KaXZiX70N4PDY7bV4W4HBqMIYX8RXmJ7Lb2cvTjUx0PsSRgMi7EkEfT+CB1OEsPgrQ1AgO9ON1B8dxNfJxPIhe6aJNVWu9U3fB/1j96E/hvYoT43Wbro3STXydQ727ADlXyR6uAZZkv45fq0NzAejjh6QMVtYA7V0YHQZUE3fa8C/Zl4YszRzrUPTvTyeVaKYBvsm+AE9HoZ0jQB/bqu/zNcAnVYiv4t5qVIxanXBiDXbExp/4TMXMizgT5NV4KwCdEalqK48n4liDd3GtMLkovJYO6IbJh/I9rB5NxeoJPBn5NRwNeK+tPJ3McOvE8FG8OdgVAzlfFNbvzZmpzLPfyt3QVhfHstTi7WpMHMDpgSjKvihj5bnotngjN919ZVYVgMO4klmytSrwVKbsmkpWz6/Hwv4y7l/Bt7iMPfWFsweLhxTy9zzNAJG+y35P1U0rq9+341QB2IeXKw9Ly/6FExkhpV6FI5N4Fi+EXE117mYZ2c0sf1tmItIo2X/WHQ4LtSgyojIPAAAAAElFTkSuQmCC",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAD7klEQVR42q3XW4iVVRQH8N/3nTNjFghlJVGOEwaCEUk3M0UsyCC6PQSh9RBB9CAUVFT0IEUPZVBUUARdEIKKCsqKbg9BTfe3LtRDTmnpRBAG0UjOnDmnl7WH5cfRM45u2Jz9nW/vtf57Xf5rfdWqTdvNYVSoYz0zYG8rfrvoDRLcnoPyVigtihdiFCNYHP/9hd+wC//1OTsvAOXWM/F7FW7AulDeHD3sxmd4Be/F2dbhrNE+jPJeCLgGW3F+ej+DTmN/KywzipvwNR7AB/G+6gei7qO8jo3DeBY7Qvk0ppJpF6Q5nHw/FeBW4308mWRWgyxQUC7CW7g0btvFUOzZjc/xHfbGmdOxCmtxRgLSwu04C9dHfBxkiXYfn7eS8iJkCN/iEbyDyUO4bhGuxX1YGeCncCXeCHcelCF1w/QzeKqhvIXHwqSvhvJWgM+zhX/wEi7EM+l8AfFoCuqDYqCky0bcFv4u1rgLd4eQdliqBGGeM/Gujf3YEkHYClkd3In1KTvUcagbf2xLKdXGE3g8+b8zgFx6sacAeRAvxLobe7blOKhThF4egTQdCn/EPQGsMxdWawDphuw7gqCGQs7FYYUuWnVKjRvTwQoPBZjqCJVLgVZHzDycXNcLnoCq+GZBoKpiPYG306H5jhIXr2Nf8EWFDeGWTgnCZZG/RdlYBFI9z9tnV1T4G1+leBvF0pwFIylSRc5X/ZhrHqO4+fsUyO1STwqAxY1DfxzlzftZYiKt4eQMoO4TQMd69PrVoaJ4X+PlyDEyf6b5pWldeohZAOMRgIVw1qWUPNpReH9tPA8Fq47nANmFn+O5Gym5LA7WR6G8FTJW4qKUlj9hT+GBwnQ7UhldiHuPAYBCYvdH5E/H/29mJixmfj6UDwXSW7Empc2Rjnac3YjNIXM4+OXF4p46FaKdeC5VxjZexpIQ1JqH8hFsT6xY42n8XnrFusHbW6PLGQ5zjeJdnJRAzVX5kjh7WjwP49eoMbOWr1OO1kGZt6Ro7eACfIzl8VwPYL0OzsYnOCeeS3bdHMWpbnZEVSq5H2FT9G9F4Ln4Apcla/VT3sXV0ZqvSIAncR0+jT2lZ5jtcHrhr9WB9t8oHhsSf58afd2KIJFcpusk4zUcl3xeB6BelPwDcZkJVMWny/ElTjnEzYolTsR5+LDx1VPeXxLKp5PZ4YqYZeyJxmSiIF8fyicD4YE+PV8x+94+3F7WvzQA5Vnk7o/Svxq9woRjEYAnpI+NZtdbR4/4Q47iRop9k7rh5vki93j8GXtnXbAzWuk1ffqA0lSMxwdJdYgaUVq5LdG+n9nna6jUl7FCxe2GgvE5UuugDmgs5kBZ/wOFWCxrmfygSAAAAABJRU5ErkJggg==")
IconData["symbols_white"] := Map(16,"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABfklEQVR42oWTsUtWURjGf/d+n2KJtdWHGWL/gUVDLUFrNDbokJt/gJP/RFOrS0MOhS1FQ0tbUEG4RDRIJEFhloOhaOqv5Tlx+rjQC5dz73ue9znPfZ/3NCqJJmtJzAAXgWPgM/Al+RY4KUWoqE1W1LvqK/+NA/WFervCNyr1x2l1rSp6pz5QH6ofqvz9kPTUBrUNwZMA3qjXKkUFc0v9FMy9QlIA89l4q56tinrlpOQuqZvBXq9/4bV6ol4NcHRIQZ2bC8FqIZhWj9T16mQ6nrpXO+pX9VQLTAM9YD1WtnRHsXcP+AgMgEHtaT8g+X+M/MWqA3UvzelXrtDhRBv8vrqhjrbAN+B5pm4xikY6Tu1nbxkYAx4Bh6U5s+pxmG92NLO8L8SBn+oFta0lLmRkf6l3hmQ36lKKd9QbpY4wPVafqbvVyJ6ryK9U+S31qbqijqNejnzVw6h4Gb+L95Pq++z9Dva7er7JdZ4EJjIDDbABHAxd8TPAVBopsA38+AOJzHA/s2ODmAAAAABJRU5ErkJggg==",20,"iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAABz0lEQVR42pWVO2tUURSFv3szEcGIjY8/IKgIjhBBsLJTUAkpDP4HaxuDhY2gla2IiJ1iEwsR04XBNGJhK1pGg9roKL7ns3AdOVzHPDYczrl7r7Uf5+w906h0pAVGHd2O7B/Ww/Y6gAngV85ngBmgD+yJbhV4DiwAD+Os5oBa1kT2afWJ68tA7Xe4NCm5RDkF3AO2Jd4AWARe5HsfcBI4lu+PwNlg/pRfeT+sfkn0FXW2yr675tTVYD+pB6NvUVu1pz4N4I16oCql11ltbH31XTjL0bcl4ukYRupMdFvWyLDYzlV3ekL9+yi342y5e8lrrIJ5Fu5NlTaXeQhogEfZG9aXgnmccx9oWmA7sCvGV4BsTl5m3w1MtR0HG82uxrelpcvoDIHXURzZZIY1ZwUYlgwHiTaXuR1VkcdJmeGdwGy4S/Xo7Vd/5PlvRDepNmNet4kN9U4439S9pW3K81+veupCRR7nEHW+wl8rrdQlLaSnVK8mWBtMk/NkFXyk3q+DlcNR9bx6Sf2cEkwWZORKJVeqMofqxXCnS8lTMYyTu5XDXs4P/oN9r27tAV+BW8Dx6kcW4C1wOS84qvpuvjMMP6NfBL43Y/4CCtENNPU/mN9BrNeYRNtinAAAAABJRU5ErkJggg==",24,"iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAACWklEQVR42p2WvWtUQRTFz3u7MYoEBT8WFRtFG4OFgmihhUUarVQEbQyWsddCCz+wsjGNRUCx0EL/AYkoQrDQYCNsp0WaRFFXSPwIu2v2Z3Pvch3f200yMMzb++49Z2benDObASppFUlL6t9ySVlZbrUgliUFhyQdlbRPUk1SR9KcpPeSpiTVe04IiD0Lz6eAN/RubWASOGY1eYKhIvC1wMMSwHlgoeTd7SKSCJ4D64CXVrBk42tgDDgI7AB2AkeAK0Ddcv7Y+MDwKk6iEBDwJCx9ARhNtjDta4CrQAdoWu2tiCmgaoHzAXzeZulLrtrovWIx34pzRtIyjMNO4tszCHywJICzYYa9VpCFnOvhezz3yXniSHj5wmLVPuCRpGJEH8M32Qsot9M6IskVN2E6WG7D8luSHgVNHHcVykSUSVqUNG1FnVWQTIXY/kiwxcaGpK+haCUESJqV1LbY9kiQrwK0jChaThf4i41bJW0LfrTc5vm7JA2E1XQJ3tk4KOmEJeQrJEDS6fD7bTS7A3a8OsAMsD6Iqt8xdRfYDfw0jB9AzZXsIJNBCxMWG0jdMel58J1XoX48Ktndb9ik7sZ1rcyCC6z9fgD/DGz2OiWqvWhJ7il3AkFWAD4EPA01zXA3VNP7oAZsBO4l7vg4+R5ONgRMW07TVn4Z2GAr+Oc+uAF8AxrAnCW3A8meZM8FnLR3vy2/BcwC34FPwIVIMNPjWmwAm8LMfSXDfa7TZ0D30h+TdMnOflT1L0l3zUJy8yfXSF3SGUmjJq4s1C1KuilJWY+/LUVC6hf7r/0FMS+i7TYBKbsAAAAASUVORK5CYII=",32,"iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAADlUlEQVR42q2Xz4sdRRDHvzPvbWIMETRKDsm+KBsQ9OIthGj8cYhBMF48BNQ/Qi+CFw8eBIkEwYgHb+JZPSh48SJqQEGNiIpsYqIbfxCzl2TN5r03Hy/fWsrO7LzJbhqa6enuqaqu+nZ9aypAPVolqfZ4OmPvwM9G0kzhVQ8DBoXSbZLuljSStNNzFyWdl/SrpKsd317fgPV6BQw8roGjwHvAOdpbA5wF3gWeSHIGltWqp0t5jI8CXxfKJsDV1Fc9l9sp4EiSV/U1oPZzC/B2EnjNima1VWCc3t9InrzOiBIDlZ87JH0g6VHHsJE057Vzkj6XdFrSkr/ZLekBSQcl7fG+a8bAQNLHkp5O+KANAxHzLcCn6TTh2m+BY8D2DtzcBjwH/JBCFV77yPL/hwkVYFFye1Z+HNha7B0WfZDWbwVOthjxeqFLpfLDKd4RxxeSh4ZdiE574v1lyxgneYeyzozQAfBNOj3ACW+em6G4y5B3Cplfer0OA+L0R9LpG8dxbtY97ui1+3bnhyZ54eHwQp2Q/4zR2XjuFUljj3vl66I1Tt9XJL1qOVPLenbt1tmSrUWGWzKQqg2eXkUCuh34x14A+CVCFASz1/c38vZnklZ8go2cXum+V5KWJZ3yuDGXzCsx3Mjjid+/8+ZKm28R5u/9PpE0tM41A3YWH/2xyZO3eeJCkQXvzAbULQC62Y0Wz6wpvlQsjm6S+zPHzBd8czEbsGgABuE8mK7kZltURgf9PmeiWgwyiqz1o6/IFFgB9uaMtcEeSew+J6FMbDVQ1abLiaQPE41uk/SiLa836XokvWTkjz3/vj0zyAXIvsSAE1t8wGvDDZx+mAiuscwpcAWYj3RdsuGbBXGcBXaVFHoDykfABRsQMl8r2VAp1ncAvydSAvjK8309EXt2AacLWWeAHRH/siAJrj+cOGGcQLNQ1Ixd9eT9wE+FjKgF6nwQrVMsHgP+dcxCwF/AYx1GxNyTwHJSPgUuA0+1Vd4VEEgdSdrve3pZ0vOSHjFaG6N4WdK9kURSdgvSmpf0s6RbnFfij+oTSW+52F2V9IVTcxWWLAB/zyi3wxOPt4BymDyXY75e+w3YHXkASYck3eXiYdV9UvTIB0stuT3GZ5JHyu9D7oqpf7+ktVjsAy71+Ok40QMDJ3vI+RPYA1QZAwuSDrTUAVFULPqHpKtEi7WHJN2Tvs2yGhc85yVV8WfUt+7rs++GZP0H+i6iraCaR7MAAAAASUVORK5CYII=")
IcoB64 := "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Gf8ZGRn/GRkZ/RkZGVoAAAAAAAAAAAAAAAAAAAAAAAAAABkZGQ8ZGRnjGRkZ/xkZGf8ZGRn/GRkZ/19fX//Z2dn//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////+Hh4f9xcXH/GRkZ/xkZGf8ZGRn/GRkZ/xkZGfIZGRkgAAAAAAAAAAAAAAAAAAAAABkZGYUZGRn/GRkZ/xkZGf8ZGRn/d3d3//Pz8//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////4+Pj/jY2N/xkZGf8ZGRn/GRkZ/xkZGf8ZGRmlAAAAAAAAAAAAAAAAGRkZDRkZGe0ZGRn/GRkZ/xkZGf9XV1f/8fHx////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////+Pj4/3BwcP8ZGRn/GRkZ/xkZGf8ZGRn5GRkZIQAAAAAAAAAAGRkZWBkZGf8ZGRn/GRkZ/xoaGv/Q0ND////////////////////////////x8fH/2dnZ/9bW1v/W1tb/1tbW/9bW1v/W1tb/1tbW/9bW1v/W1tb/1tbW/9bW1v/W1tb/1tbW/9bW1v/W1tb/1tbW/9bW1v/W1tb/1tbW/9bW1v/W1tb/2NjY/+3t7f///////////////////////////+Dg4P8hISH/GRkZ/xkZGf8ZGRn/GRkZeAAAAAAAAAAAGRkZmRkZGf8ZGRn/GRkZ/2NjY//9/f3//////////////////Pz8/62trf8uLi7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/yIiIv+cnJz/+fn5//////////////////////+Ghob/GRkZ/xkZGf8ZGRn/GRkZugAAAAAAAAAAGRkZxhkZGf8ZGRn/GRkZ/7Gxsf//////////////////////tLS0/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/nZ2d///////////////////////ExMT/GRkZ/xkZGf8ZGRn/GRkZ4xkZGQMAAAAAGRkZ3BkZGf8ZGRn/GRkZ/8/Pz//////////////////4+Pj/Pz8//xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/IyMj/+zs7P/////////////////i4uL/GRkZ/xkZGf8ZGRn/GRkZ8hkZGQoAAAAAGRkZ4BkZGf8ZGRn/GRkZ/9jY2P/////////////////l5eX/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/9zc3P/////////////////p6en/GRkZ/xkZGf8ZGRn/GRkZ9xkZGQ0AAAAAGRkZ4BkZGf8ZGRn/GRkZ/9jY2P/////////////////i4uL/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/9zc3P/////////////////q6ur/GRkZ/xkZGf8ZGRn/GRkZ9xkZGQ0AAAAAGRkZ4BkZGf8ZGRn/GRkZ/9jY2P/////////////////i4uL/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/9zc3P/////////////////q6ur/GRkZ/xkZGf8ZGRn/GRkZ9xkZGQ0AAAAAGRkZ4BkZGf8ZGRn/GRkZ/9jY2P/////////////////i4uL/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/9zc3P/////////////////q6ur/GRkZ/xkZGf8ZGRn/GRkZ9xkZGQ0AAAAAGRkZ4BkZGf8ZGRn/GRkZ/9jY2P/////////////////i4uL/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/9zc3P/////////////////q6ur/GRkZ/xkZGf8ZGRn/GRkZ9xkZGQ0AAAAAGRkZ4BkZGf8ZGRn/GRkZ/9jY2P/////////////////i4uL/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/9zc3P/////////////////q6ur/GRkZ/xkZGf8ZGRn/GRkZ9xkZGQ0AAAAAGRkZ4BkZGf8ZGRn/GRkZ/9jY2P/////////////////i4uL/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/9zc3P/////////////////q6ur/GRkZ/xkZ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UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP9z6kr/GRkZ/xkZGf8ZGRn/GRkZ9xkZGQ0AAAAAGRkZDRkZGe0ZGRn/GRkZ/xkZGf9XV1f/8fHx/////////////////////////////////////////////////////////////////////////////////5KSkv8ZGRn/GRkZ/xkZGf8ZGRn/cONI/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP9z6kr/GRkZ/xkZGf8ZGRn/GRkZ9xkZGQ0AAAAAAAAAABkZGYUZGRn/GRkZ/xkZGf8ZGRn/d3d3//Pz8////////////////////////////////////////////////////////////////////////////8TExP8ZGRn/GRkZ/xkZGf8ZGRn/cONI/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP9z6Ur/GRkZ/xkZGf8ZGRn/GRkZ9xkZGQ0AAAAAAAAAABkZGQ8ZGRnjGRkZ/xkZGf8ZGRn/GRkZ/19fX//Z2dn//////////////////////////////////////////////////////////////////////6Wlpf8ZGRn/GRkZ/xkZGf8ZGRn/U6k3/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP9p1UT/GRkZ/xkZGf8ZGRn/GRkZ7BkZGQcAAAAAAAAAAAAAAAAZGRlAGRkZ9xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/e3t7/8HBwf/h4eH/6+vr/+7u7v/u7u7/7u7u/+7u7v/u7u7/7u7u/+7u7v/q6ur/urq6/yAgIP8ZGRn/GRkZ/xkZGf8ZGRn/Gh4a/1SqN/9x5kn/de5L/3XuS/917kv/de5L/3XuS/917kv/de5L/3XuS/917kv/de5L/2nWRP8vWiP/GRkZ/xkZGf8ZGRn/GRkZwQAAAAAAAAAAAAAAAAAAAAAAAAAAGRkZWhkZGfkZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZXgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABkZGUYZGRnqGRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRm+GRkZBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZGRkWGRkZmhkZGfcZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGcAZGRkRAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABkZGR0ZGRlzGRkZuhkZGeUZGRn2GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfEZGRnFGRkZYhkZGQUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABkZGQQZGRkLGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/4AAAB/8AAP8AAAAA/wAA/AAAAAA/AAD4AAAAAB8AAPAAAAAADwAA4AAAAAAHAADAAAAAAAMAAMAAAAAAAwAAgAAAAAABAACAAAAAAAEAAIAAAAAAAQAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAMAAAAAAAAAAwAAAAAAAAADgAAAAAAEAAPAAAAAAAQAA+AAAAAABAAD8AAAAAAMAAP8AAAAABwAA/+AAAAA/AAAoAAAAIAAAAEAAAAABACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGRkZDBkZGT8ZGRlXGRkZWBkZGVgZGRlYGRkZWBkZGVgZGRlYGRkZWBkZGVgZGRlYGRkZWBkZGVgZGRlYGRkZWBkZGVgZGRlXGRkZQhkZGRAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGRkZJBkZGaUZGRn3GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ+hkZGa4ZGRktAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABkZGVwZGRn2GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGfoZGRltAAAAAAAAAAAAAAAAAAAAAAAAAAAZGRlYGRkZ/hkZGf8ZGRn/MDAw/5eXl/++vr7/yMjI/8jIyP/IyMj/yMjI/8jIyP/IyMj/yMjI/8jIyP/IyMj/yMjI/8jIyP/IyMj/yMjI/8jIyP/AwMD/nJyc/zg4OP8ZGRn/GRkZ/xkZGf8ZGRlsAAAAAAAAAAAAAAAAGRkZHRkZGfIZGRn/GRkZ/4SEhP/v7+//////////////////////////////////////////////////////////////////////////////////////////////////8vLy/5GRkf8ZGRn/GRkZ/xkZGfkZGRkrAAAAAAAAAAAZGRmUGRkZ/xkZGf+BgYH/+/v7/////////////////////////////////////////////////////////////////////////////////////////////////////////////f39/5CQkP8ZGRn/GRkZ/xkZGaoAAAAAGRkZAxkZGe0ZGRn/IyMj/+rq6v////////////j4+P/Gxsb/s7Oz/7Ozs/+zs7P/s7Oz/7Ozs/+zs7P/s7Oz/7Ozs/+zs7P/s7Oz/7Ozs/+zs7P/s7Oz/7Ozs//CwsL/9fX1////////////8vLy/zg4OP8ZGRn/GRkZ+RkZGQ0ZGRkoGRkZ/xkZGf+IiIj////////////5+fn/cHBw/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf9gYGD/9fX1////////////mpqa/xkZGf8ZGRn/GRkZPhkZGT8ZGRn/GRkZ/7CwsP///////////87Ozv8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf/CwsL///////////+/v7//GRkZ/xkZGf8ZGRlVGRkZQBkZGf8ZGRn/tbW1////////////vb29/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/7i4uP///////////8PDw/8ZGRn/GRkZ/xkZGVgZGRlAGRkZ/xkZGf+1tbX///////////+9vb3/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/uLi4////////////w8PD/xkZGf8ZGRn/GRkZWBkZGUAZGRn/GRkZ/7W1tf///////////729vf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf+4uLj////////////Dw8P/GRkZ/xkZGf8ZGRlYGRkZQBkZGf8ZGRn/tbW1////////////vb29/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/7i4uP///////////8PDw/8ZGRn/GRkZ/xkZGVgZGRlAGRkZ/xkZGf+1tbX///////////+9vb3/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/uLi4////////////w8PD/xkZGf8ZGRn/GRkZWBkZGUAZGRn/GRkZ/7W1tf///////////729vf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf+np6f///////////+7u7v/GRkZ/xkZGf8ZGRlYGRkZQBkZGf8ZGRn/tbW1////////////vb29/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/zY2Nv/CwsL/yMjI/0pKSv8ZGRn/GRkZ/xkZGVgZGRlAGRkZ/xkZGf+1tbX///////////+9vb3/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZWBkZGUAZGRn/GRkZ/7W1tf///////////729vf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRlYGRkZQBkZGf8ZGRn/tbW1////////////vb29/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/x8vG/9ChC3/LFMh/xkZGf8ZGRn/GRkZ/xkZGVgZGRlAGRkZ/xkZGf+1tbX///////////+9vb3/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8rTyD/ceZJ/33/UP96+U7/PXoq/xkZGf8ZGRn/GRkZWBkZGUAZGRn/GRkZ/7W1tf///////////729vf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/Kk4g/3HnSf99/1D/ff9Q/33/UP9fwT7/GRkZ/xkZGf8ZGRlYGRkZQBkZGf8ZGRn/tbW1////////////vb29/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/ypOIP9x50n/ff9Q/33/UP99/1D/ff9Q/2DDP/8ZGRn/GRkZ/xkZGVgZGRlAGRkZ/xkZGf+1tbX///////////+9vb3/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8qTSD/ceZJ/33/UP99/1D/ff9Q/33/UP99/1D/YMM//xkZGf8ZGRn/GRkZWBkZGT8ZGRn/GRkZ/7CwsP///////////87Ozv8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/KUwg/3HmSf99/1D/ff9Q/33/UP99/1D/ff9Q/33/UP9gwz//GRkZ/xkZGf8ZGRlYGRkZKBkZGf8ZGRn/iIiI////////////+fn5/3BwcP8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/ylMIP9x5kn/ff9Q/33/UP99/1D/ff9Q/33/UP99/1D/ff9Q/2DD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"
IcoPausedB64 := "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/////////////////////97e3v9paWn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGesZGRkXAAAAAAAAAAAAAAAAAAAAABkZGZUZGRn/GRkZ/xkZGf8ZGRn/gICA//X19f/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////29vb/gICA/xkZGf8ZGRn/GRkZ/xkZGf8ZGRmXAAAAAAAAAAAAAAAAGRkZFRkZGfQZGRn/GRkZ/xkZGf9iYmL/9fX1////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9fX1/2RkZP8ZGRn/GRkZ/xkZGf8ZGRn1GRkZFwAAAAAAAAAAGRkZZhkZGf8ZGRn/GRkZ/xwcHP/Y2Nj////////////////////////////v7+//2dnZ/9bW1v/W1tb/1tbW/9bW1v/W1tb/1tbW/9bW1v/W1tb/1tbW/9bW1v/W1tb/1tbW/9bW1v/W1tb/1tbW/9bW1v/W1tb/1tbW/9bW1v/W1tb/2dnZ/+/v7////////////////////////////9nZ2f8cHBz/GRkZ/xkZGf8ZGRn/GRkZaQAAAAAAAAAAGRkZqRkZGf8ZGRn/GRkZ/3R0dP/+/v7/////////////////+/v7/6ampv8pKSn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/ygoKP+kpKT/+/v7//////////////////7+/v92dnb/GRkZ/xkZGf8ZGRn/GRkZqwAAAAAAAAAAGRkZ1BkZGf8ZGRn/GRkZ/7u7u///////////////////////qamp/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/qKio//////////////////////+8vLz/GRkZ/xkZGf8ZGRn/GRkZ1gAAAAAZGRkEGRkZ5xkZGf8ZGRn/GRkZ/9jY2P/////////////////z8/P/MjIy/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/MDAw//Ly8v/////////////////Z2dn/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////f39//GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/9/f3//////////////////l5eX/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/97e3v/////////////////l5eX/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/97e3v/////////////////l5eX/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/97e3v/////////////////l5eX/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/97e3v/////////////////l5eX/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/97e3v/////////////////l5eX/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/97e3v/////////////////l5eX/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/97e3v/////////////////l5eX/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/9ra2v/////////////////i4uL/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/52dnf/+/v7///////////+np6f/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xoaGv+MjIz/ubm5/5GRkf8cHBz/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRr/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/Ghon/zExrv8+PuT/Pj7h/y8vpP8ZGRz/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8aGiD/NzfF/0ND9/9DQ/f/Q0P3/0ND9/8uLp7/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xoaJf83N8T/Q0P3/0ND9/9DQ/f/Q0P3/0ND9/88PNj/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/Ghom/zc3w/9DQ/f/Q0P3/0ND9/9DQ/f/Q0P3/0ND9/89Pd7/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGR3/NzfD/0ND9/9DQ/f/Q0P3/0ND9/9DQ/f/Q0P3/0ND9/89Pd7/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////e3t7/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xoaJP83N8P/Q0P3/0ND9/9DQ/f/Q0P3/0ND9/9DQ/f/Q0P3/0ND9/89Pd7/GRkZ/xkZGf8ZGRn/GRkZ6BkZGQQZGRkEGRkZ6BkZGf8ZGRn/GRkZ/+Xl5f/////////////////f39//GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/Ghok/zY2wv9DQ/f/Q0P3/0ND9/9DQ/f/Q0P3/0ND9/9DQ/f/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GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRmxGRkZAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZGRkbGRkZohkZGfkZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGf8ZGRn/GRkZ/xkZGbYZGRkNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABkZGSEZGRl5GRkZvBkZGecZGRn2GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfcZGRn3GRkZ9xkZGfAZGRnCGRkZXBkZGQMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABkZGQQZGRkLGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQwZGRkMGRkZDBkZGQgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/4AAAB/8AAP8AAAAA/wAA/AAAAAA/AAD4AAAAAB8AAPAAAAAADwAA4AAAAAAHAADAAAAAAAMAAMAAAAAAAwAAgAAAAAABAACAAAAAAAEAAIAAAAAAAQAAgAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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"


; ============================ start-up ============================
; (placed last so that every function above is already defined)

ApplyMenuTheme()          ; dark / light menus, as early as possible
SettingsStartup()
MigrateStartupLink()
try DirCreate(DataDir)
SetAppIcon()
LoadConfig()
FixToolPrefs()
if (PeekVersion(ConfigFile) != AppVersion)
    SaveConfig()           ; stamp the settings with this version
; The shortcut is received as a Windows message (WM_HOTKEY), because AutoHotkey's
; own hotkeys cannot react while its menu is open.
OnMessage(0x0133, CtlColor)           ; edit boxes
OnMessage(0x0134, CtlColor)           ; list boxes
OnMessage(0x0135, CtlColor)           ; buttons
OnMessage(0x0138, CtlColor)           ; texts
OnMessage(0x0312, HotkeyArrived)
OnMessage(0x0117, MenuPopupOpening)   ; WM_INITMENUPOPUP: a menu or submenu is about to open
OnMessage(0x0201, NoteClick)         ; left click: tick a to-do box / open a reduced note
OnMessage(0x0232, NoteMoved)       ; WM_EXITSIZEMOVE: a note was moved or resized
OnMessage(0x001A, ThemeChanged)    ; WM_SETTINGCHANGE: light / dark theme may have changed
OnExit(ExitHandler)
if (!OpenHotkeys.Length)
    OpenHotkeys.Push("^RButton")
StartShortcuts() {
    bad := []
    for hk in OpenHotkeys {
        if (!ActivateHotkey(hk, 10))
            bad.Push(hk)
    }
    for hk in bad {
        MsgBox("The saved shortcut (" HotkeyText(hk) ") could not be used.", "Contextool", "Iconx")
        for i, h in OpenHotkeys {
            if (h = hk) {
                OpenHotkeys.RemoveAt(i)
                break
            }
        }
    }
    if (!OpenHotkeys.Length) {
        OpenHotkeys.Push("^RButton")
        ActivateHotkey("^RButton", 10)
    }
}
StartShortcuts()
A_TrayMenu.Delete()
A_TrayMenu.Add("Settings", ShowSettings)
A_TrayMenu.Add("Open my menu", ShowMenu)
A_TrayMenu.Add()
A_TrayMenu.Add("Pause Contextool", TogglePause)
A_TrayMenu.Add()
A_TrayMenu.Add("Reload", (*) => Reload())
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default := "Settings"
SetTrayState()
ApplyMenuTheme()
HotIf(NoteTodoFocused)
Hotkey("$Enter", NoteEnterKey)
Hotkey("$NumpadEnter", NoteEnterKey)
HotIf()
LoadNotes()
StartSnippets()
SetTimer(OcrWarmUp, -6000)      ; wakes up PowerShell/OCR once in the background, so the first real use is fast


; Lets go of Ctrl/Shift/Alt/Win ONLY if they are really held (sending "Alt up" when Alt is not held
; makes Outlook/Word show their ribbon letters)
ReleaseMods() {
    for k in ["Ctrl", "Shift", "Alt", "LWin", "RWin"] {
        if (GetKeyState(k))
            Send("{" k " up}")
    }
}
