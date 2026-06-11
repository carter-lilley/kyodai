; maximize_process.ahk
; AHK v2.0+
; Usage: AutoHotkey.exe maximize_process.ahk <PID>
; Restores the main game window using the hwnd saved by minimize_window.ahk.

#NoTrayIcon
#SingleInstance Force
DetectHiddenWindows(true)
SetTitleMatchMode(2)

pid := A_Args[1]

; Try to read saved hwnd from minimize
posFile := EnvGet("TEMP") "\game_shuffler_hwnd_" pid ".txt"
bestHwnd := 0

if FileExist(posFile) {
	try {
		fh := FileOpen(posFile, "r")
		bestHwnd := Integer(fh.Read())
		fh.Close()
	}
}

; If no saved hwnd or it's invalid, fall back to finding the window
if bestHwnd = 0 or not WinExist(bestHwnd) {
	bestHwnd := 0
	maxArea := 0
	
	hwndList := WinGetList("ahk_pid " pid)
	for hwnd in hwndList {
		if not WinExist(hwnd) {
			continue
		}
		
		title := WinGetTitle(hwnd)
		WinGetPos(&X, &Y, &W, &H, hwnd)
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
}

if bestHwnd = 0 {
	ExitApp(1)
}

; Belt-and-suspenders: WinShow first, then restore
WinShow(bestHwnd)
DllCall("ShowWindow", "Ptr", bestHwnd, "Int", 9)  ; SW_RESTORE

; Allow foreground and activate
DllCall("AllowSetForegroundWindow", "UInt", -1)
DllCall("SetForegroundWindow", "Ptr", bestHwnd)

; Cleanup temp file
try FileDelete(posFile)

ExitApp(0)
