; maximize_process.ahk
; AHK v2.0+
; Usage: AutoHotkey.exe maximize_process.ahk <PID>
; Restores the main game window and forces it to the foreground.

#NoTrayIcon
#SingleInstance Force
DetectHiddenWindows(true)
SetTitleMatchMode(2)

pid := A_Args[1]
logFile := EnvGet("TEMP") "\game_shuffler_maximize_" pid ".log"
FileAppend("maximize pid=" pid "`n", logFile)

; Wait up to 5 seconds for the process to own a window.
try {
	WinWait("ahk_pid " pid, "", 5)
}

; Try to read saved hwnd from minimize
posFile := EnvGet("TEMP") "\game_shuffler_hwnd_" pid ".txt"
bestHwnd := 0
winTitle := ""

if FileExist(posFile) {
	try {
		fh := FileOpen(posFile, "r")
		bestHwnd := Integer(fh.Read())
		fh.Close()
		FileAppend("read saved hwnd=" bestHwnd "`n", logFile)
	}
}

; Validate saved hwnd
if bestHwnd != 0 and WinExist("ahk_id " bestHwnd) {
	winTitle := "ahk_id " bestHwnd
	FileAppend("using saved hwnd`n", logFile)
} else {
	bestHwnd := 0
	maxArea := 0
	
	hwndList := WinGetList("ahk_pid " pid)
	for hwnd in hwndList {
		if not WinExist("ahk_id " hwnd) {
			continue
		}
		if not DllCall("IsWindowVisible", "Ptr", hwnd) {
			continue
		}
		
		title := WinGetTitle("ahk_id " hwnd)
		WinGetPos(&X, &Y, &W, &H, "ahk_id " hwnd)
		area := W * H
		
		; Skip blank/helper/dummy windows
		if title = "" or area < 10000 {
			continue
		}
		if InStr(title, "wglDummyWindow") {
			continue
		}
		
		if area > maxArea {
			maxArea := area
			bestHwnd := hwnd
		}
	}
	
	if bestHwnd != 0 {
		winTitle := "ahk_id " bestHwnd
		FileAppend("fallback hwnd=" bestHwnd " area=" maxArea "`n", logFile)
	}
}

if winTitle = "" {
	FileAppend("no window found`n", logFile)
	ExitApp(1)
}

; Restore, activate, and briefly toggle topmost to steal focus.
success := false
Loop 3 {
	WinShow(winTitle)
	DllCall("ShowWindow", "Ptr", bestHwnd, "Int", 9)  ; SW_RESTORE
	DllCall("AllowSetForegroundWindow", "UInt", -1)
	WinActivate(winTitle)
	Sleep(100)
	WinSetAlwaysOnTop(1, winTitle)
	Sleep(50)
	WinSetAlwaysOnTop(0, winTitle)
	Sleep(50)
	
	if WinActive(winTitle) {
		success := true
		break
	}
	
	FileAppend("activate attempt " A_Index " failed, retrying`n", logFile)
	Sleep(300)
}

if success {
	FileAppend("window activated`n", logFile)
} else {
	FileAppend("window NOT activated`n", logFile)
}

; Cleanup temp file
try FileDelete(posFile)

ExitApp(success ? 0 : 1)
