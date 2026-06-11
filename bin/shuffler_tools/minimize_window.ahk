; minimize_window.ahk
; AHK v2.0+
; Usage: AutoHotkey.exe minimize_window.ahk <PID>
; Minimizes the main game window and saves its hwnd for maximize to use.

#NoTrayIcon
#SingleInstance Force
DetectHiddenWindows(true)
SetTitleMatchMode(2)

if A_Args.Length < 1 {
	MsgBox("No PID provided.`nUsage: minimize_window.ahk <PID>", "Error", 16)
	ExitApp(2)
}

pid := A_Args[1]

; Find the main window: largest visible window with non-empty title
bestHwnd := 0
maxArea := 0

hwndList := WinGetList("ahk_pid " pid)
for hwnd in hwndList {
	if not WinExist(hwnd) {
		continue
	}
	if not DllCall("IsWindowVisible", "Ptr", hwnd) {
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

if bestHwnd = 0 {
	ExitApp(2)
}

; Save hwnd to temp file for maximize to read
posFile := EnvGet("TEMP") "\game_shuffler_hwnd_" pid ".txt"
try {
	fh := FileOpen(posFile, "w")
	fh.Write(bestHwnd)
	fh.Close()
}

; Belt-and-suspenders: WinHide first, then minimize
WinHide(bestHwnd)
DllCall("ShowWindow", "Ptr", bestHwnd, "Int", 6)  ; SW_MINIMIZE

ExitApp(0)
