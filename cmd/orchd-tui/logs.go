package main

import (
	"io"
	"os"
	"strings"
)

func pollLogAppend(path string, offset int64) (int64, []string, error) {
	if strings.TrimSpace(path) == "" {
		return 0, nil, nil
	}

	st, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil, nil
		}
		return offset, nil, err
	}

	if st.Size() < offset {
		offset = 0
	}

	f, err := os.Open(path)
	if err != nil {
		return offset, nil, err
	}
	defer f.Close()

	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return offset, nil, err
	}

	buf, err := io.ReadAll(f)
	if err != nil {
		return offset, nil, err
	}
	if len(buf) == 0 {
		return offset, nil, nil
	}

	newOffset := offset + int64(len(buf))
	text := strings.ReplaceAll(string(buf), "\r\n", "\n")
	parts := strings.Split(text, "\n")
	if len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}

	return newOffset, parts, nil
}

func readLastLines(path string, limit int) []string {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		return nil
	}

	const maxTailBytes int64 = 512 * 1024
	size := st.Size()
	start := int64(0)
	if size > maxTailBytes {
		start = size - maxTailBytes
	}

	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return nil
	}

	buf, err := io.ReadAll(f)
	if err != nil {
		return nil
	}

	text := strings.ReplaceAll(string(buf), "\r\n", "\n")
	if start > 0 {
		if idx := strings.IndexByte(text, '\n'); idx >= 0 && idx+1 < len(text) {
			text = text[idx+1:]
		}
	}
	parts := strings.Split(text, "\n")
	if len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return wrapLines(parts, limit)
}
