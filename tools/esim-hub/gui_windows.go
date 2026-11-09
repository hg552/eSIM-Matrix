//go:build windows

package main

import (
	"fmt"
	"os"
	"runtime"
	"syscall"
	"time"
	"unsafe"

	"github.com/jchv/go-webview2"
)

var (
	user32                  = syscall.NewLazyDLL("user32.dll")
	kernel32                = syscall.NewLazyDLL("kernel32.dll")
	dwmapi                  = syscall.NewLazyDLL("dwmapi.dll")
	procOpenClipboard       = user32.NewProc("OpenClipboard")
	procCloseClipboard      = user32.NewProc("CloseClipboard")
	procEmptyClipboard      = user32.NewProc("EmptyClipboard")
	procSetClipboardData    = user32.NewProc("SetClipboardData")
	procMessageBeep         = user32.NewProc("MessageBeep")
	procGetSystemMetrics    = user32.NewProc("GetSystemMetrics")
	procGetWindowRect       = user32.NewProc("GetWindowRect")
	procSetWindowPos        = user32.NewProc("SetWindowPos")
	procSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	procGlobalAlloc         = kernel32.NewProc("GlobalAlloc")
	procGlobalFree          = kernel32.NewProc("GlobalFree")
	procGlobalLock          = kernel32.NewProc("GlobalLock")
	procGlobalUnlock        = kernel32.NewProc("GlobalUnlock")
	procAttachConsole       = kernel32.NewProc("AttachConsole")
	procDwmSetWindowAttr    = dwmapi.NewProc("DwmSetWindowAttribute")
)

const (
	guiSupported        = true
	cfUnicodeText       = 13
	gmemMoveable        = 0x0002
	smCxScreen          = 0
	smCyScreen          = 1
	swpNoZOrder         = 0x0004
	swpNoSize           = 0x0001
	dwmwaImmersiveDark  = 20
	attachParentProcess = ^uintptr(0) // (DWORD)-1
	mbIconAsterisk      = 0x00000040
)

// attachParentConsoleIfCLI attaches stdout/stderr to the parent PowerShell/CMD terminal
// when the binary is compiled with -H=windowsgui and invoked with CLI subcommands.
func attachParentConsoleIfCLI() {
	r, _, _ := procAttachConsole.Call(attachParentProcess)
	if r == 0 {
		return
	}
	if out, err := os.OpenFile("CONOUT$", os.O_WRONLY, 0); err == nil {
		os.Stdout = out
		os.Stderr = out
	}
}

// setClipboardNative writes UTF-16 text directly to the Windows clipboard via user32.dll (<0.1ms, no subprocess).
func setClipboardNative(text string) error {
	// The clipboard open count is per thread: CloseClipboard must run on the same
	// thread as OpenClipboard. Without pinning, the goroutine can migrate between
	// the two calls and leave the system clipboard locked for every process.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	utf16, err := syscall.UTF16FromString(text)
	if err != nil {
		return err
	}
	// Retry OpenClipboard briefly in case another process holds it.
	var opened uintptr
	for range 5 {
		opened, _, _ = procOpenClipboard.Call(0)
		if opened != 0 {
			break
		}
		time.Sleep(15 * time.Millisecond)
	}
	if opened == 0 {
		return fmt.Errorf("OpenClipboard failed")
	}
	defer procCloseClipboard.Call()

	procEmptyClipboard.Call()
	sizeBytes := uintptr(len(utf16) * 2)
	hMem, _, _ := procGlobalAlloc.Call(gmemMoveable, sizeBytes)
	if hMem == 0 {
		return fmt.Errorf("GlobalAlloc failed")
	}
	ptr, _, _ := procGlobalLock.Call(hMem)
	if ptr == 0 {
		procGlobalFree.Call(hMem)
		return fmt.Errorf("GlobalLock failed")
	}
	// GlobalLock hands back a Win32 pointer as a uintptr. Converting it straight
	// into a slice is the documented way to write into a global memory block;
	// `go vet` flags it because the same shape is unsafe after pointer arithmetic,
	// which never happens here.
	src := unsafe.Slice((*byte)(unsafe.Pointer(unsafe.SliceData(utf16))), sizeBytes)
	dst := unsafe.Slice((*byte)(unsafe.Pointer(ptr)), sizeBytes)
	copy(dst, src)
	procGlobalUnlock.Call(hMem)

	res, _, _ := procSetClipboardData.Call(cfUnicodeText, hMem)
	if res == 0 {
		procGlobalFree.Call(hMem)
		return fmt.Errorf("SetClipboardData failed")
	}
	return nil
}

func playNativeBeep() {
	_, _, _ = procMessageBeep.Call(mbIconAsterisk)
}

func applyDarkTitleBar(hwnd uintptr) {
	if hwnd == 0 {
		return
	}
	// Enable Windows 10/11 dark mode title bar (DWMWA_USE_IMMERSIVE_DARK_MODE = 20, fallback 19).
	dark := int32(1)
	_, _, _ = procDwmSetWindowAttr.Call(hwnd, dwmwaImmersiveDark, uintptr(unsafe.Pointer(&dark)), 4)
	_, _, _ = procDwmSetWindowAttr.Call(hwnd, 19, uintptr(unsafe.Pointer(&dark)), 4)
}

// centerWindow places an already-sized window in the middle of the primary
// display using its real outer rectangle.
func centerWindow(hwnd uintptr) {
	if hwnd == 0 {
		return
	}
	var rect struct{ Left, Top, Right, Bottom int32 }
	if ok, _, _ := procGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&rect))); ok == 0 {
		return
	}
	winW := int(rect.Right - rect.Left)
	winH := int(rect.Bottom - rect.Top)
	screenW, _, _ := procGetSystemMetrics.Call(smCxScreen)
	screenH, _, _ := procGetSystemMetrics.Call(smCyScreen)
	x := (int(screenW) - winW) / 2
	y := (int(screenH) - winH) / 2
	if x < 0 {
		x = 0
	}
	if y < 0 {
		y = 0
	}
	_, _, _ = procSetWindowPos.Call(hwnd, 0, uintptr(x), uintptr(y), 0, 0, swpNoZOrder|swpNoSize)
	_, _, _ = procSetForegroundWindow.Call(hwnd)
}

// fitToPrimaryDisplay shrinks a preferred window size until it fits the screen,
// so a small or high-DPI display cannot push the title bar off-screen.
func fitToPrimaryDisplay(preferredW, preferredH int) (int, int) {
	screenW, _, _ := procGetSystemMetrics.Call(smCxScreen)
	screenH, _, _ := procGetSystemMetrics.Call(smCyScreen)
	w, h := preferredW, preferredH
	if int(screenW) > 320 && w > int(screenW)-80 {
		w = int(screenW) - 80
	}
	if int(screenH) > 240 && h > int(screenH)-120 {
		h = int(screenH) - 120
	}
	if w < 640 {
		w = 640
	}
	if h < 480 {
		h = 480
	}
	return w, h
}

// runNativeGUIWindow opens a native Win32 desktop window embedding Edge WebView2 pointed at localURL.
func runNativeGUIWindow(localURL string) error {
	winW, winH := fitToPrimaryDisplay(1400, 880)

	w := webview2.NewWithOptions(webview2.WebViewOptions{
		// DevTools would expose every token in hubState to anyone at the keyboard.
		Debug:     os.Getenv("ESIM_HUB_DEBUG") != "",
		AutoFocus: true,
		WindowOptions: webview2.WindowOptions{
			Title:  "eSIM-Matrix Windows Hub · 远程切卡与接码控制中枢",
			Width:  uint(winW),
			Height: uint(winH),
			Center: false,
		},
	})
	if w == nil {
		return fmt.Errorf("webview2 initialization returned nil")
	}
	defer w.Destroy()

	hwnd := uintptr(w.Window())
	applyDarkTitleBar(hwnd)
	w.SetSize(winW, winH, webview2.HintNone)
	centerWindow(hwnd)

	// Bind native helpers into JS window context
	_ = w.Bind("nativeCopyClipboard", func(text string) error {
		return setClipboardNative(text)
	})
	_ = w.Bind("nativeBeep", func() {
		playNativeBeep()
	})

	w.Navigate(localURL)
	w.Run()
	return nil
}
