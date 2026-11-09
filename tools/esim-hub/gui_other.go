//go:build !windows

package main

// The desktop host, clipboard and console attachment are Win32-only. A server
// build still needs the same entry points, so they degrade to no-ops and the
// process serves the console over HTTP instead of opening a native window.

const guiSupported = false

func attachParentConsoleIfCLI() {}

func setClipboardNative(string) error { return errNoNativeClipboard }

func playNativeBeep() {}

func runNativeGUIWindow(string) error { return errNoNativeGUI }
