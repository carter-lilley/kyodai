; shuffler_cursor_overlay.ahk
; AHK v2.0+
; Usage: AutoHotkey.exe shuffler_cursor_overlay.ahk <cursor_png_path>
; Creates a fullscreen, click-through, always-on-top overlay window and renders
; a custom cursor image via GDI+ directly onto a layered window.

#NoTrayIcon
#SingleInstance Force

if A_Args.Length < 1 {
	ExitApp(2)
}

cursorPath := A_Args[1]
if not FileExist(cursorPath) {
	ExitApp(2)
}

; Make the script per-monitor DPI aware so coordinates stay consistent.
DllCall("SetThreadDpiAwarenessContext", "Ptr", -4)

; --- GDI+ startup ---
GdiplusStartupInput := Buffer(24)
NumPut("UInt", 1, GdiplusStartupInput, 0)
DllCall("gdiplus\GdiplusStartup", "Ptr*", &GdiplusToken := 0, "Ptr", GdiplusStartupInput, "Ptr", 0)

; --- Load PNG into a GDI+ bitmap and read dimensions ---
pBitmap := 0
DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", cursorPath, "Ptr*", &pBitmap)
if not pBitmap {
	ExitApp(1)
}

imgW := 0
imgH := 0
DllCall("gdiplus\GdipGetImageWidth", "Ptr", pBitmap, "UInt*", &imgW)
DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &imgH)

; Cursor hotspot offset as a fraction of the image size.
; Positive values move the image down/right (so the hotspot moves up/left relative to the image).
CURSOR_OFFSET_X := 0.35
CURSOR_OFFSET_Y := 0.17
offsetX := Integer(imgW * CURSOR_OFFSET_X)
offsetY := Integer(imgH * CURSOR_OFFSET_Y)

; --- Get primary monitor dimensions ---
MONITOR_DEFAULTTOPRIMARY := 1
hMonitor := DllCall("MonitorFromPoint", "Int64", 0, "UInt", MONITOR_DEFAULTTOPRIMARY, "Ptr")
mi := Buffer(40)
NumPut("UInt", 40, mi, 0)
DllCall("GetMonitorInfo", "Ptr", hMonitor, "Ptr", mi)
screenX := NumGet(mi, 4, "Int")
screenY := NumGet(mi, 8, "Int")
screenW := NumGet(mi, 12, "Int") - screenX
screenH := NumGet(mi, 16, "Int") - screenY

; --- Create the fullscreen layered overlay window ---
myGui := Gui("-Caption +ToolWindow -DPIScale")
myGui.BackColor := "000000"
hwnd := myGui.Hwnd
myGui.Show(Format("x{1} y{2} w{3} h{4} NoActivate", screenX, screenY, screenW, screenH))

; Set extended styles: layered, transparent, tool window, no activate
exStyle := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -20, "UInt")
exStyle |= 0x00080000  ; WS_EX_LAYERED
exStyle |= 0x00000020  ; WS_EX_TRANSPARENT
exStyle |= 0x00000080  ; WS_EX_TOOLWINDOW
exStyle |= 0x08000000  ; WS_EX_NOACTIVATE
DllCall("SetWindowLong", "Ptr", hwnd, "Int", -20, "UInt", exStyle)

; Make the window truly click-through by returning HTTRANSPARENT for hit tests
OnMessage(0x0084, WM_NCHITTEST)
WM_NCHITTEST(wParam, lParam, msg, hwnd) {
	return -1  ; HTTRANSPARENT
}

; --- Create a memory DC/bitmap matching the overlay size for UpdateLayeredWindow ---
hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")

; BITMAPINFO for 32-bit pre-multiplied alpha DIB
bi := Buffer(40)
NumPut("UInt", 40, bi, 0)
NumPut("Int", screenW, bi, 4)
NumPut("Int", screenH, bi, 8)
NumPut("UShort", 1, bi, 12)
NumPut("UShort", 32, bi, 14)
NumPut("UInt", 0, bi, 16)

ppvBits := 0
hDIB := DllCall("CreateDIBSection",
	"Ptr", hdcScreen,
	"Ptr", bi,
	"UInt", 0,
	"Ptr*", &ppvBits,
	"Ptr", 0,
	"UInt", 0,
	"Ptr")

hOld := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hDIB, "Ptr")

; --- Pre-create a GDI+ graphics object for the memory DC ---
pGraphics := 0
DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hdcMem, "Ptr*", &pGraphics)
DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)  ; AntiAlias
DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", pGraphics, "Int", 7)  ; HighQualityBicubic

; --- Clear the memory bitmap fully transparent ---
DllCall("gdiplus\GdipGraphicsClear", "Ptr", pGraphics, "UInt", 0x00000000)

; --- Function to render the cursor at a given position ---
RenderCursor(cx, cy) {
	; Clear the entire memory bitmap
	DllCall("gdiplus\GdipGraphicsClear", "Ptr", pGraphics, "UInt", 0x00000000)

	; Draw the PNG at the offset position
	DllCall("gdiplus\GdipDrawImageRectRectI",
		"Ptr", pGraphics,
		"Ptr", pBitmap,
		"Int", cx - offsetX,
		"Int", cy - offsetY,
		"Int", imgW,
		"Int", imgH,
		"Int", 0,
		"Int", 0,
		"Int", imgW,
		"Int", imgH,
		"Int", 2)

	; Update the layered window
	ptSrc := Buffer(8)
	NumPut("Int", 0, ptSrc, 0)
	NumPut("Int", 0, ptSrc, 4)

	ptDst := Buffer(8)
	NumPut("Int", screenX, ptDst, 0)
	NumPut("Int", screenY, ptDst, 4)

	size := Buffer(8)
	NumPut("Int", screenW, size, 0)
	NumPut("Int", screenH, size, 4)

	; Update the layered window with a proper BLENDFUNCTION
	blend := Buffer(4)
	NumPut("UChar", 0, blend, 0)      ; BlendOp = AC_SRC_OVER
	NumPut("UChar", 0, blend, 1)      ; BlendFlags
	NumPut("UChar", 255, blend, 2)    ; SourceConstantAlpha
	NumPut("UChar", 1, blend, 3)      ; AlphaFormat = AC_SRC_ALPHA

	DllCall("UpdateLayeredWindow",
		"Ptr", hwnd,
		"Ptr", hdcScreen,
		"Ptr", ptDst,
		"Ptr", size,
		"Ptr", hdcMem,
		"Ptr", ptSrc,
		"UInt", 0,
		"Ptr", blend,
		"UInt", 2)  ; ULW_ALPHA
}

; --- Keep it topmost without re-ordering ---
DllCall("SetWindowPos",
	"Ptr", hwnd,
	"Ptr", -1,  ; HWND_TOPMOST
	"Int", screenX,
	"Int", screenY,
	"Int", screenW,
	"Int", screenH,
	"UInt", 0x0010)  ; SWP_NOACTIVATE

SetTimer(UpdatePosition, 10)

UpdatePosition() {
	pt := Buffer(8)
	DllCall("GetCursorPos", "Ptr", pt)
	mx := NumGet(pt, 0, "Int")
	my := NumGet(pt, 4, "Int")

	DllCall("ScreenToClient", "Ptr", hwnd, "Ptr", pt)
	cx := NumGet(pt, 0, "Int")
	cy := NumGet(pt, 4, "Int")

	RenderCursor(cx, cy)
}

; Keep running until killed by ShufflerManager
Persistent()

; Cleanup function (called when process exits)
OnExit(ExitFunc)
ExitFunc(*) {
	DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hOld, "Ptr")
	DllCall("DeleteObject", "Ptr", hDIB)
	DllCall("DeleteDC", "Ptr", hdcMem)
	DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
	if pGraphics {
		DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
	}
	if pBitmap {
		DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
	}
	DllCall("gdiplus\GdiplusShutdown", "Ptr", GdiplusToken)
}
