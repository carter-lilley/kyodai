; maximize_process.ahk
; AHK v2.0+
; Usage: AutoHotkey.exe maximize_process.ahk <PID>
; Restores the emulator game window and forces it to the foreground.

#NoTrayIcon
#SingleInstance Off
DetectHiddenWindows(true)
SetTitleMatchMode(2)

pid := Integer(A_Args[1])

logFile := EnvGet("TEMP") . "\game_shuffler_maximize_" . pid . ".log"
startTick := A_TickCount
budgetMs := 15000

FileAppend(Format("maximize pid={1}`n", pid), logFile)

; Try to read saved hwnd from a previous minimize
posFile := EnvGet("TEMP") . "\game_shuffler_hwnd_" . pid . ".txt"

FindGameWindow(pid) {
	bestHwnd := 0
	maxArea := 0
	hwndList := WinGetList("ahk_pid " . pid)
	for hwnd in hwndList {
		if not DllCall("IsWindowVisible", "Ptr", hwnd) {
			continue
		}

		title := WinGetTitle("ahk_id " . hwnd)
		WinGetPos(&X, &Y, &W, &H, "ahk_id " . hwnd)
		area := W * H

		; Skip tiny/helper windows. Allow blank titles if the window is large
		; (emulators often have no title while booting).
		if area < 10000 {
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
	return bestHwnd
}

bestHwnd := 0

if FileExist(posFile) {
	try {
		fh := FileOpen(posFile, "r")
		saved := Integer(fh.Read())
		fh.Close()
		if saved != 0 and WinExist("ahk_id " . saved) and DllCall("IsWindowVisible", "Ptr", saved) {
			bestHwnd := saved
			FileAppend(Format("using saved hwnd={1}`n", saved), logFile)
		}
	}
}

; Some emulators (e.g. Vita3K) destroy their initial "Loading..." window and
; create a new one when the game starts rendering, so any hwnd can die at any
; point. Rediscover instead of retrying a dead handle.
success := false

Loop {
	if A_TickCount - startTick > budgetMs {
		FileAppend(Format("timeout after {1}ms`n", budgetMs), logFile)
		break
	}

	if bestHwnd = 0 or not WinExist("ahk_id " . bestHwnd) {
		if bestHwnd != 0 {
			FileAppend(Format("hwnd={1} vanished, rediscovering`n", bestHwnd), logFile)
			bestHwnd := 0
		}
		bestHwnd := FindGameWindow(pid)
		if bestHwnd = 0 {
			Sleep(200)
			continue
		}
		FileAppend(Format("found hwnd={1} title=`"{2}`" class=`"{3}`"`n", bestHwnd, WinGetTitle("ahk_id " . bestHwnd), WinGetClass("ahk_id " . bestHwnd)), logFile)
	}

	hwndRef := "ahk_id " . bestHwnd

	; Restore, activate, and briefly toggle topmost to steal focus.
	WinShow(hwndRef)
	DllCall("ShowWindow", "Ptr", bestHwnd, "Int", 9)  ; SW_RESTORE
	DllCall("AllowSetForegroundWindow", "UInt", -1)
	WinActivate(hwndRef)
	Sleep(100)
	if WinExist(hwndRef) {
		try {
			WinSetAlwaysOnTop(1, hwndRef)
			Sleep(50)
			WinSetAlwaysOnTop(0, hwndRef)
		} catch Error as e {
			FileAppend(Format("topmost toggle failed: {1}`n", e.Message), logFile)
		}
	}
	Sleep(50)

	if not WinExist(hwndRef) {
		FileAppend(Format("hwnd={1} died during activation`n", bestHwnd), logFile)
		bestHwnd := 0
		continue
	}

	if WinActive(hwndRef) {
		; Settle check: the window may still be recreated moments later
		; (Vita3K loading -> game transition). Re-verify after a beat.
		Sleep(1500)
		if WinExist(hwndRef) and WinActive(hwndRef) {
			success := true
			break
		}
		if not WinExist(hwndRef) {
			FileAppend(Format("hwnd={1} died after activation, rediscovering`n", bestHwnd), logFile)
			bestHwnd := 0
		} else {
			FileAppend("lost foreground after activation, retrying`n", logFile)
		}
		continue
	}

	FileAppend("activate attempt failed, retrying`n", logFile)
	Sleep(300)
}

if success {
	FileAppend("window activated`n", logFile)

	; If the emulator window is also topmost, it can outrank our non-active controls palette.
	; Drop its topmost flag so the controls palette (which we keep HWND_TOPMOST) stays visible.
	if WinExist("ahk_id " . bestHwnd) {
		emExStyle := DllCall("GetWindowLongPtr", "Ptr", bestHwnd, "Int", -20)
		if (emExStyle & 0x00000008) {
			try {
				WinSetAlwaysOnTop(0, "ahk_id " . bestHwnd)
				FileAppend("removed emulator WS_EX_TOPMOST`n", logFile)
			} catch Error as e {
				FileAppend(Format("failed to remove emulator topmost: {1}`n", e.Message), logFile)
			}
		}
	}

} else {
	FileAppend("window NOT activated`n", logFile)
}

; Cleanup temp file
try FileDelete(posFile)

ExitApp(success ? 0 : 1)
