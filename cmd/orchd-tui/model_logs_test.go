package main

import (
	"strings"
	"testing"
)

func TestLogsPolledOutsideLogsTabMarksDirty(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: false})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	m.activeTab = tabTasks
	m.taskLogPath = "/tmp/task.log"
	m.globalLogPath = "/tmp/orchd.log"
	m.logsDirty = false

	updated, _ := m.Update(logsPolledMsg{
		taskPath:     m.taskLogPath,
		taskOffset:   42,
		taskLines:    []string{"task-line-1"},
		globalPath:   m.globalLogPath,
		globalOffset: 77,
		globalLines:  []string{"global-line-1"},
	})

	model := updated.(model)
	if !model.logsDirty {
		t.Fatalf("expected logsDirty=true when logs update arrives off the Logs tab")
	}
}

func TestSwitchToLogsRendersPendingLogUpdates(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: false})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	m.width = 120
	m.height = 36
	m.resizeViewports()

	m.activeTab = tabTasks
	m.state.ProjectRoot = ""
	m.taskLogLines = []string{"task-line-1"}
	m.globalLogLines = []string{"global-line-1"}
	m.logsDirty = true

	m.activateTab(tabLogs)

	if m.logsDirty {
		t.Fatalf("expected logsDirty=false after Logs tab refresh")
	}

	if !strings.Contains(m.taskLogViewport.View(), "task-line-1") {
		t.Fatalf("expected task log viewport to render buffered lines")
	}

	if !strings.Contains(m.globalViewport.View(), "global-line-1") {
		t.Fatalf("expected global log viewport to render buffered lines")
	}
}

func TestLogsPolledRewindClearsTaskLogBuffer(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: false})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	m.taskLogPath = "/tmp/task.log"
	m.taskLogOffset = 120
	m.taskLogLines = []string{"old-task-line"}
	m.logsDirty = false

	updated, _ := m.Update(logsPolledMsg{
		taskPath:   m.taskLogPath,
		taskOffset: 0,
	})

	model := updated.(model)
	if len(model.taskLogLines) != 0 {
		t.Fatalf("expected task log buffer to clear on rewind, got %#v", model.taskLogLines)
	}
	if !model.logsDirty {
		t.Fatalf("expected logsDirty=true when task log rewinds")
	}
}

func TestLogsPolledRewindClearsGlobalLogBuffer(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: false})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	m.globalLogPath = "/tmp/orchd.log"
	m.globalLogOffset = 80
	m.globalLogLines = []string{"old-global-line"}
	m.logsDirty = false

	updated, _ := m.Update(logsPolledMsg{
		globalPath:   m.globalLogPath,
		globalOffset: 0,
	})

	model := updated.(model)
	if len(model.globalLogLines) != 0 {
		t.Fatalf("expected global log buffer to clear on rewind, got %#v", model.globalLogLines)
	}
	if !model.logsDirty {
		t.Fatalf("expected logsDirty=true when global log rewinds")
	}
}
