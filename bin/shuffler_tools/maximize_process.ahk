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

FileAppend(Format("maximize pid={1}`n", pid), logFile)

; Try to read saved hwnd from a previous minimize
posFile := EnvGet("TEMP") . "\game_shuffler_hwnd_" . pid . ".txt"
bestHwnd := 0
winTitle := ""

if FileExist(posFile) {
	try {
		fh := FileOpen(posFile, "r")
		bestHwnd := Integer(fh.Read())
		fh.Close()
		FileAppend(Format("read saved hwnd={1}`n", bestHwnd), logFile)
	}
}

if bestHwnd != 0 and WinExist("ahk_id " . bestHwnd) and DllCall("IsWindowVisible", "Ptr", bestHwnd) {
	winTitle := "ahk_id " . bestHwnd
	FileAppend("using saved hwnd`n", logFile)
}

; If no saved hwnd, poll for up to 15 seconds until the process owns a suitable window.
; Some emulators (e.g. PCSX2) take several seconds to create their main game window.
if winTitle = "" {
	deadline := A_TickCount + 15000
	candidateCount := 0
	Loop {
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

			candidateCount += 1
			if area > maxArea {
				maxArea := area
				bestHwnd := hwnd
			}
		}

		if bestHwnd != 0 {
			winTitle := "ahk_id " . bestHwnd
			FileAppend(Format("fallback hwnd={1} area={2} candidates={3}`n", bestHwnd, maxArea, candidateCount), logFile)
			break
		}

		if A_TickCount > deadline {
			FileAppend(Format("no window found after 15s (candidates seen={1})`n", candidateCount), logFile)
			ExitApp(1)
		}

		Sleep(200)
	}
}

if winTitle = "" {
	FileAppend("no window found`n", logFile)
	ExitApp(1)
}

; Diagnostics about the chosen emulator window.
exStyle := DllCall("GetWindowLongPtr", "Ptr", bestHwnd, "Int", -20)
isTopmost := (exStyle & 0x00000008) ? 1 : 0
WinGetPos(&eX, &eY, &eW, &eH, "ahk_id " . bestHwnd)
chosenTitle := WinGetTitle("ahk_id " . bestHwnd)
chosenClass := WinGetClass("ahk_id " . bestHwnd)
FileAppend(Format("chosen hwnd={1} title=`"{2}`" class=`"{3}`" area={4} topmost={5}`n", bestHwnd, chosenTitle, chosenClass, eW * eH, isTopmost), logFile)

; Restore, activate, and briefly toggle topmost to steal focus.
success := false
Loop 3 {
	if (A_TickCount - startTick > 10000) {
		FileAppend("timeout after 10s`n", logFile)
		break
	}
	WinShow(winTitle)
	DllCall("ShowWindow", "Ptr", bestHwnd, "Int", 9)  ; SW_RESTORE
	DllCall("AllowSetForegroundWindow", "UInt", -1)
	WinActivate(winTitle)
	Sleep(100)
	try {
		WinSetAlwaysOnTop(1, winTitle)
		Sleep(50)
		WinSetAlwaysOnTop(0, winTitle)
	} catch Error as e {
		FileAppend(Format("topmost toggle failed: {1}`n", e.Message), logFile)
	}
	Sleep(50)

	if WinActive(winTitle) {
		success := true
		break
	}

	FileAppend(Format("activate attempt {1} failed, retrying`n", A_Index), logFile)
	Sleep(300)
}

if success {
	FileAppend("window activated`n", logFile)

	; If the emulator window is also topmost, it can outrank our non-active controls palette.
	; Drop its topmost flag so the controls palette (which we keep HWND_TOPMOST) stays visible.
	emExStyle := DllCall("GetWindowLongPtr", "Ptr", bestHwnd, "Int", -20)
	if (emExStyle & 0x00000008) {
		try {
			WinSetAlwaysOnTop(0, winTitle)
			FileAppend("removed emulator WS_EX_TOPMOST`n", logFile)
		} catch Error as e {
			FileAppend(Format("failed to remove emulator topmost: {1}`n", e.Message), logFile)
		}
	}

} else {
	FileAppend("window NOT activated`n", logFile)
}

; Cleanup temp file
try FileDelete(posFile)

ExitApp(success ? 0 : 1)
