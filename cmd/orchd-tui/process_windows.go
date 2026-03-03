//go:build windows

package main

import (
	"math"

	"golang.org/x/sys/windows"
)

func processExists(pid int) bool {
	if pid <= 0 || pid > math.MaxUint32 {
		return false
	}

	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	_ = windows.CloseHandle(h)
	return true
}
