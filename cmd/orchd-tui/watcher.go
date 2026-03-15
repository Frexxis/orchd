package main

import (
	"io/fs"
	"os"
	"path/filepath"

	"github.com/fsnotify/fsnotify"
)

type fileWatcher struct {
	root    string
	watcher *fsnotify.Watcher
	events  chan fileChangedMsg
	done    chan struct{}
}

func startFileWatcher(projectRoot string) (*fileWatcher, error) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}

	fw := &fileWatcher{
		root:    projectRoot,
		watcher: w,
		events:  make(chan fileChangedMsg, 256),
		done:    make(chan struct{}),
	}

	for _, path := range []string{
		filepath.Join(projectRoot, ".orchd"),
		filepath.Join(projectRoot, ".orchd", "tasks"),
		filepath.Join(projectRoot, ".orchd", "logs"),
		filepath.Join(projectRoot, "docs", "memory"),
		filepath.Join(projectRoot, "docs", "memory", "lessons"),
	} {
		if err := addRecursiveWatch(w, path); err != nil {
			// Keep watcher alive even if some optional paths are absent.
			continue
		}
	}

	go fw.loop()
	return fw, nil
}

func (fw *fileWatcher) Events() <-chan fileChangedMsg {
	if fw == nil {
		return nil
	}
	return fw.events
}

func (fw *fileWatcher) Close() error {
	if fw == nil {
		return nil
	}
	select {
	case <-fw.done:
		// already closed
	default:
		close(fw.done)
	}
	return fw.watcher.Close()
}

func (fw *fileWatcher) loop() {
	defer close(fw.events)

	for {
		select {
		case <-fw.done:
			return
		case ev, ok := <-fw.watcher.Events:
			if !ok {
				return
			}

			if ev.Op&fsnotify.Create != 0 {
				if st, err := os.Stat(ev.Name); err == nil && st.IsDir() {
					_ = addRecursiveWatch(fw.watcher, ev.Name)
				}
			}

			if ev.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Remove|fsnotify.Rename|fsnotify.Chmod) == 0 {
				continue
			}

			fw.emit(fileChangedMsg{root: fw.root, path: ev.Name})

		case err, ok := <-fw.watcher.Errors:
			if !ok {
				return
			}
			fw.emit(fileChangedMsg{root: fw.root, err: err})
		}
	}
}

func (fw *fileWatcher) emit(msg fileChangedMsg) {
	select {
	case fw.events <- msg:
	default:
		// Drop overflow events; polling still keeps state accurate.
	}
}

func addRecursiveWatch(w *fsnotify.Watcher, path string) error {
	st, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if !st.IsDir() {
		return nil
	}

	return filepath.WalkDir(path, func(curr string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		_ = w.Add(curr)
		return nil
	})
}
