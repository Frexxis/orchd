package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/charmbracelet/bubbles/help"
	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/muesli/reflow/wordwrap"
)

type model struct {
	cfg      appConfig
	orchdBin string
	styles   uiStyles
	keys     keyMap
	help     help.Model

	activeTab tab
	focusPane int

	width  int
	height int

	state    orchState
	stateErr string

	statusLine       string
	lastStateUpdate  time.Time
	commandBusy      bool
	lastWatchRefresh time.Time

	pendingConfirm *commandAction

	inputMode   bool
	inputPrompt string
	inputValue  string
	inputAction string

	selectedTaskIdx   int
	selectedMemoryIdx int
	selectedQueueIdx  int

	details taskDetails

	memoryFiles []memoryFile
	queueItems  []queueItem

	autopilotRunning bool

	detailViewport  viewport.Model
	taskLogViewport viewport.Model
	globalViewport  viewport.Model
	dagViewport     viewport.Model
	memoryViewport  viewport.Model
	queueViewport   viewport.Model
	statsViewport   viewport.Model

	taskLogPath     string
	taskLogOffset   int64
	taskLogLines    []string
	globalLogPath   string
	globalLogOffset int64
	globalLogLines  []string
	logFilter       string

	followLogs bool
	logsDirty  bool
	showHelp   bool

	watchRoot   string
	watcher     *fileWatcher
	watchEvents <-chan fileChangedMsg

	stateFetchInFlight bool
	stateFetchQueued   bool
}

func newModel(cfg appConfig) (model, error) {
	absProject, err := filepath.Abs(cfg.projectDir)
	if err != nil {
		return model{}, err
	}

	p, err := resolvePalette(cfg.themeName)
	if err != nil {
		return model{}, err
	}

	m := model{
		cfg:                cfg,
		orchdBin:           resolveOrchdBinary(),
		styles:             newStyles(p),
		keys:               defaultKeys(),
		help:               help.New(),
		activeTab:          tabTasks,
		focusPane:          0,
		statusLine:         "Loading orchd state...",
		followLogs:         true,
		logsDirty:          true,
		state:              orchState{ProjectRoot: absProject},
		memoryFiles:        []memoryFile{},
		queueItems:         []queueItem{},
		taskLogLines:       []string{},
		globalLogLines:     []string{},
		stateFetchInFlight: true,
	}

	m.help.ShowAll = false

	m.detailViewport = viewport.New(10, 10)
	m.taskLogViewport = viewport.New(10, 10)
	m.globalViewport = viewport.New(10, 10)
	m.dagViewport = viewport.New(10, 10)
	m.memoryViewport = viewport.New(10, 10)
	m.queueViewport = viewport.New(10, 10)
	m.statsViewport = viewport.New(10, 10)

	m.applyViewportsTheme()

	return m, nil
}

func (m model) Init() tea.Cmd {
	return tea.Batch(
		fetchStateCmd(m.orchdBin, m.state.ProjectRoot),
		stateTickCmd(m.cfg.refresh),
		logTickCmd(900*time.Millisecond),
	)
}

func (m *model) refreshTabContent() {
	switch m.activeTab {
	case tabTasks:
		m.refreshTaskDetails()
	case tabLogs:
		m.rebindLogSources()
		if m.logsDirty {
			m.updateLogViewports()
		}
	case tabDAG:
		m.refreshDAGViewport()
	case tabMemory:
		m.refreshMemoryData()
		m.refreshMemoryViewport()
	case tabQueue:
		m.refreshQueueData()
		m.refreshQueueViewport()
	case tabStats:
		m.refreshStatsViewport()
	}
}

func (m *model) refreshAutopilotStatus() {
	running, _ := detectAutopilotRunning(m.state.ProjectRoot)
	m.autopilotRunning = running
}

func (m *model) refreshMemoryData() {
	memoryFiles, err := loadMemoryFiles(m.state.ProjectRoot)
	if err == nil {
		m.memoryFiles = memoryFiles
	}
	if len(m.memoryFiles) == 0 {
		m.selectedMemoryIdx = 0
	} else {
		m.selectedMemoryIdx = clamp(m.selectedMemoryIdx, 0, len(m.memoryFiles)-1)
	}
}

func (m *model) refreshQueueData() {
	queueItems, err := loadQueueItems(m.state.ProjectRoot)
	if err == nil {
		m.queueItems = queueItems
	}
	if len(m.queueItems) == 0 {
		m.selectedQueueIdx = 0
	} else {
		m.selectedQueueIdx = clamp(m.selectedQueueIdx, 0, len(m.queueItems)-1)
	}
}

func (m *model) activateTab(t tab) {
	if m.activeTab == t {
		return
	}
	m.activeTab = t
	m.focusPane = 0
	m.resizeViewports()
	m.refreshTabContent()
}

func (m *model) scheduleStateRefresh() tea.Cmd {
	if m.stateFetchInFlight {
		m.stateFetchQueued = true
		return nil
	}
	m.stateFetchInFlight = true
	return fetchStateCmd(m.orchdBin, m.state.ProjectRoot)
}

func (m *model) consumeQueuedStateRefresh() tea.Cmd {
	if !m.stateFetchQueued {
		return nil
	}
	m.stateFetchQueued = false
	return m.scheduleStateRefresh()
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.resizeViewports()
		m.refreshTabContent()
		return m, nil

	case tea.MouseMsg:
		mouseCmd := m.handleMouse(msg)
		return m, mouseCmd

	case tea.KeyMsg:
		if m.inputMode {
			if msg.String() == "esc" {
				m.inputMode = false
				m.inputPrompt = ""
				m.inputValue = ""
				m.inputAction = ""
				m.statusLine = "Input cancelled"
				return m, nil
			}

			if msg.String() == "enter" {
				value := strings.TrimSpace(m.inputValue)
				action := m.inputAction
				m.inputMode = false
				m.inputPrompt = ""
				m.inputValue = ""
				m.inputAction = ""

				if value == "" && action != "log-filter" {
					m.statusLine = "Input was empty"
					return m, nil
				}

				switch action {
				case "idea":
					m.commandBusy = true
					act := commandAction{Label: "idea", Args: []string{"idea", value}}
					m.statusLine = fmt.Sprintf("Running: orchd idea %q", value)
					return m, runActionCmd(m.orchdBin, m.state.ProjectRoot, act)
				case "log-filter":
					m.logFilter = value
					m.updateLogViewports()
					if m.logFilter == "" {
						m.statusLine = "Log filter cleared"
					} else {
						m.statusLine = fmt.Sprintf("Log filter set: %q", m.logFilter)
					}
					return m, nil
				default:
					m.statusLine = "Unknown input action"
					return m, nil
				}
			}

			if msg.String() == "backspace" || msg.String() == "ctrl+h" {
				if m.inputValue != "" {
					_, size := utf8.DecodeLastRuneInString(m.inputValue)
					if size > 0 {
						m.inputValue = m.inputValue[:len(m.inputValue)-size]
					}
				}
				return m, nil
			}

			if msg.Type == tea.KeyRunes && len(msg.Runes) > 0 {
				m.inputValue += string(msg.Runes)
			}
			return m, nil
		}

		if m.pendingConfirm != nil {
			if key.Matches(msg, m.keys.Accept) {
				a := *m.pendingConfirm
				m.pendingConfirm = nil

				if a.Label == "queue-cancel" {
					if a.Index < 0 || a.Index >= len(m.queueItems) {
						m.statusLine = "Invalid queue selection"
						return m, nil
					}
					item := m.queueItems[a.Index]
					err := updateQueueItemMarker(m.state.ProjectRoot, item.LineNo, "-")
					if err != nil {
						m.statusLine = fmt.Sprintf("Failed to cancel idea: %v", err)
						return m, nil
					}
					m.statusLine = "Idea cancelled"
					m.refreshQueueData()
					m.refreshQueueViewport()
					return m, nil
				}

				m.commandBusy = true
				if len(a.Args) == 0 {
					m.commandBusy = false
					m.statusLine = "Invalid action"
					return m, nil
				}
				m.statusLine = fmt.Sprintf("Running: orchd %s", strings.Join(a.Args, " "))
				return m, runActionCmd(m.orchdBin, m.state.ProjectRoot, a)
			}
			if key.Matches(msg, m.keys.Cancel) {
				m.pendingConfirm = nil
				m.statusLine = "Action cancelled"
				return m, nil
			}
			return m, nil
		}

		if key.Matches(msg, m.keys.Quit) {
			m.closeWatcher()
			return m, tea.Quit
		}

		if key.Matches(msg, m.keys.Help) {
			m.showHelp = !m.showHelp
			return m, nil
		}

		switch msg.String() {
		case "1":
			m.activateTab(tabTasks)
			return m, nil
		case "2":
			m.activateTab(tabLogs)
			return m, nil
		case "3":
			m.activateTab(tabDAG)
			return m, nil
		case "4":
			m.activateTab(tabMemory)
			return m, nil
		case "5":
			m.activateTab(tabQueue)
			return m, nil
		case "6":
			m.activateTab(tabStats)
			return m, nil
		}

		if key.Matches(msg, m.keys.NextTab) {
			m.activateTab(tab((int(m.activeTab) + 1) % len(tabNames)))
			return m, nil
		}

		if key.Matches(msg, m.keys.PrevTab) {
			m.activateTab(tab((int(m.activeTab) - 1 + len(tabNames)) % len(tabNames)))
			return m, nil
		}

		if key.Matches(msg, m.keys.SwitchPane) {
			switch m.activeTab {
			case tabTasks, tabLogs, tabMemory:
				m.focusPane = (m.focusPane + 1) % 2
			default:
				m.focusPane = 0
			}
			return m, nil
		}

		if key.Matches(msg, m.keys.Refresh) {
			m.refreshAutopilotStatus()
			m.refreshTabContent()
			return m, m.scheduleStateRefresh()
		}

		if key.Matches(msg, m.keys.FollowLogs) && m.activeTab == tabLogs {
			m.followLogs = !m.followLogs
			if m.followLogs {
				m.taskLogViewport.GotoBottom()
				m.globalViewport.GotoBottom()
				m.statusLine = "Log follow enabled"
			} else {
				m.statusLine = "Log follow disabled"
			}
			return m, nil
		}

		if key.Matches(msg, m.keys.ScrollTop) {
			m.scrollFocusedTop()
			return m, nil
		}

		if key.Matches(msg, m.keys.ScrollEnd) {
			m.scrollFocusedBottom()
			return m, nil
		}

		if key.Matches(msg, m.keys.NewIdea) && m.activeTab == tabQueue {
			m.inputMode = true
			m.inputPrompt = "New idea"
			m.inputValue = ""
			m.inputAction = "idea"
			return m, nil
		}

		if key.Matches(msg, m.keys.EditFile) && m.activeTab == tabMemory {
			if len(m.memoryFiles) == 0 {
				m.statusLine = "No memory file selected"
				return m, nil
			}
			idx := clamp(m.selectedMemoryIdx, 0, len(m.memoryFiles)-1)
			f := m.memoryFiles[idx]
			cmd, err := editorCommand(f.Path)
			if err != nil {
				m.statusLine = fmt.Sprintf("editor error: %v", err)
				return m, nil
			}
			m.statusLine = fmt.Sprintf("Editing %s", f.Name)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return editorDoneMsg{err: err}
			})
		}

		if key.Matches(msg, m.keys.FilterLogs) && m.activeTab == tabLogs {
			m.inputMode = true
			m.inputPrompt = "Log filter (empty clears)"
			m.inputValue = m.logFilter
			m.inputAction = "log-filter"
			return m, nil
		}

		if key.Matches(msg, m.keys.CancelIdea) && m.activeTab == tabQueue {
			if len(m.queueItems) == 0 {
				m.statusLine = "No queue item selected"
				return m, nil
			}
			idx := clamp(m.selectedQueueIdx, 0, len(m.queueItems)-1)
			item := m.queueItems[idx]
			if item.Status == "done" || item.Status == "cancelled" {
				m.statusLine = "Selected idea is already completed/cancelled"
				return m, nil
			}

			m.pendingConfirm = &commandAction{
				Label:  "queue-cancel",
				Prompt: fmt.Sprintf("Cancel idea: %s ? [y/n]", truncate(item.Idea, 60)),
				Index:  idx,
			}
			return m, nil
		}

		if key.Matches(msg, m.keys.Up) {
			m.moveSelection(-1)
			return m, nil
		}

		if key.Matches(msg, m.keys.Down) {
			m.moveSelection(1)
			return m, nil
		}

		if m.activeTab == tabTasks || m.activeTab == tabLogs {
			if key.Matches(msg, m.keys.Spawn) {
				if t := m.selectedTask(); t != nil {
					m.pendingConfirm = &commandAction{
						Label:  "spawn",
						Prompt: fmt.Sprintf("Spawn task %s? [y/n]", t.ID),
						Args:   []string{"spawn", t.ID},
					}
				}
				return m, nil
			}
			if key.Matches(msg, m.keys.SpawnAll) {
				m.pendingConfirm = &commandAction{
					Label:  "spawn-all",
					Prompt: "Spawn all ready tasks? [y/n]",
					Args:   []string{"spawn", "--all"},
				}
				return m, nil
			}
			if key.Matches(msg, m.keys.Check) {
				if t := m.selectedTask(); t != nil {
					m.pendingConfirm = &commandAction{
						Label:  "check",
						Prompt: fmt.Sprintf("Run check for %s? [y/n]", t.ID),
						Args:   []string{"check", t.ID},
					}
				}
				return m, nil
			}
			if key.Matches(msg, m.keys.CheckAll) {
				m.pendingConfirm = &commandAction{
					Label:  "check-all",
					Prompt: "Run check --all? [y/n]",
					Args:   []string{"check", "--all"},
				}
				return m, nil
			}
			if key.Matches(msg, m.keys.Merge) {
				if t := m.selectedTask(); t != nil {
					m.pendingConfirm = &commandAction{
						Label:  "merge",
						Prompt: fmt.Sprintf("Merge task %s? [y/n]", t.ID),
						Args:   []string{"merge", t.ID},
					}
				}
				return m, nil
			}
			if key.Matches(msg, m.keys.MergeAll) {
				m.pendingConfirm = &commandAction{
					Label:  "merge-all",
					Prompt: "Run merge --all? [y/n]",
					Args:   []string{"merge", "--all"},
				}
				return m, nil
			}
			if key.Matches(msg, m.keys.Resume) {
				if t := m.selectedTask(); t != nil {
					m.pendingConfirm = &commandAction{
						Label:  "resume",
						Prompt: fmt.Sprintf("Resume task %s? [y/n]", t.ID),
						Args:   []string{"resume", t.ID, "resumed from orchd-tui"},
					}
				}
				return m, nil
			}
			if key.Matches(msg, m.keys.AttachTmux) {
				if t := m.selectedTask(); t != nil && strings.TrimSpace(t.Session) != "" {
					m.statusLine = fmt.Sprintf("Attaching to tmux session %s", t.Session)
					return m, attachTmuxCmd(t.Session)
				}
			}
		}

	case tmuxAttachMsg:
		if msg.err != nil {
			m.statusLine = fmt.Sprintf("tmux attach failed: %v", msg.err)
		} else {
			m.statusLine = "Detached from tmux"
		}
		return m, m.scheduleStateRefresh()

	case editorDoneMsg:
		if msg.err != nil {
			m.statusLine = fmt.Sprintf("Editor closed with error: %v", msg.err)
		} else {
			m.statusLine = "Editor closed"
		}
		m.refreshTabContent()
		return m, nil

	case fileChangedMsg:
		next := watchFileChangeCmd(m.watchEvents)
		if msg.closed {
			m.statusLine = "File watcher stopped"
			return m, nil
		}
		if msg.err != nil {
			m.statusLine = fmt.Sprintf("watch error: %v", msg.err)
			return m, next
		}
		if msg.root != "" && m.watchRoot != "" && msg.root != m.watchRoot {
			return m, next
		}

		now := time.Now()
		if now.Sub(m.lastWatchRefresh) < 150*time.Millisecond {
			return m, next
		}
		m.lastWatchRefresh = now

		// Cheap refreshes without calling orchd
		if strings.Contains(msg.path, string(filepath.Separator)+"docs"+string(filepath.Separator)+"memory"+string(filepath.Separator)) {
			if m.activeTab == tabMemory {
				m.refreshMemoryData()
				m.refreshMemoryViewport()
			}
			return m, next
		}
		if strings.HasSuffix(msg.path, string(filepath.Separator)+"queue.md") {
			if m.activeTab == tabQueue {
				m.refreshQueueData()
				m.refreshQueueViewport()
			}
			return m, next
		}
		if strings.HasSuffix(msg.path, string(filepath.Separator)+"autopilot.pid") {
			m.refreshAutopilotStatus()
			return m, next
		}

		// Log writes can be very frequent; avoid full state refreshes.
		logsDir := string(filepath.Separator) + filepath.Join(".orchd", "logs") + string(filepath.Separator)
		if strings.Contains(msg.path, logsDir) || strings.HasSuffix(msg.path, string(filepath.Separator)+filepath.Join(".orchd", "orchd.log")) {
			return m, next
		}

		// Task detail refresh if selected task files changed
		if t := m.selectedTask(); t != nil {
			taskDir := string(filepath.Separator) + filepath.Join(".orchd", "tasks", t.ID) + string(filepath.Separator)
			if strings.Contains(msg.path, taskDir) {
				m.refreshTaskDetails()
			}
		}

		return m, tea.Batch(next, m.scheduleStateRefresh())

	case stateLoadedMsg:
		m.stateFetchInFlight = false
		queuedCmd := m.consumeQueuedStateRefresh()

		if msg.err != nil {
			m.stateErr = msg.err.Error()
			m.statusLine = "Failed to refresh state"
			return m, queuedCmd
		}

		m.stateErr = ""
		m.lastStateUpdate = time.Now()

		selectedID := ""
		if t := m.selectedTask(); t != nil {
			selectedID = t.ID
		}

		m.state = msg.state
		m.selectedTaskIdx = indexOfTaskByID(m.state.Tasks, selectedID)
		if m.selectedTaskIdx < 0 {
			m.selectedTaskIdx = 0
		}

		m.refreshAutopilotStatus()
		m.refreshTabContent()

		if m.commandBusy {
			m.commandBusy = false
		}

		m.statusLine = fmt.Sprintf(
			"State updated. total=%d running=%d merged=%d failed=%d",
			m.state.Counts.Total,
			m.state.Counts.Running,
			m.state.Counts.Merged,
			m.state.Counts.Failed,
		)

		watchCmd := m.startWatcherIfNeeded()
		if watchCmd != nil && queuedCmd != nil {
			return m, tea.Batch(watchCmd, queuedCmd)
		}
		if watchCmd != nil {
			return m, watchCmd
		}
		return m, queuedCmd

	case commandResultMsg:
		m.commandBusy = false
		if msg.err != nil {
			m.statusLine = fmt.Sprintf("Action '%s' failed: %s", msg.action.Label, compactOutput(msg.output))
		} else {
			m.statusLine = fmt.Sprintf("Action '%s' complete: %s", msg.action.Label, compactOutput(msg.output))
		}
		return m, m.scheduleStateRefresh()

	case stateTickMsg:
		cmds = append(cmds, stateTickCmd(m.cfg.refresh))
		cmds = append(cmds, m.scheduleStateRefresh())
		return m, tea.Batch(cmds...)

	case logTickMsg:
		cmds = append(cmds, logTickCmd(900*time.Millisecond))
		cmds = append(cmds, pollLogsCmd(
			m.taskLogPath,
			m.taskLogOffset,
			m.globalLogPath,
			m.globalLogOffset,
		))
		return m, tea.Batch(cmds...)

	case logsPolledMsg:
		if msg.err != nil {
			return m, nil
		}

		contentUpdated := false

		if msg.taskPath == m.taskLogPath {
			if msg.taskOffset < m.taskLogOffset {
				m.taskLogLines = nil
				contentUpdated = true
			}
			m.taskLogOffset = msg.taskOffset
			if len(msg.taskLines) > 0 {
				m.taskLogLines = wrapLines(append(m.taskLogLines, msg.taskLines...), 4000)
				contentUpdated = true
			}
		}

		if msg.globalPath == m.globalLogPath {
			if msg.globalOffset < m.globalLogOffset {
				m.globalLogLines = nil
				contentUpdated = true
			}
			m.globalLogOffset = msg.globalOffset
			if len(msg.globalLines) > 0 {
				m.globalLogLines = wrapLines(append(m.globalLogLines, msg.globalLines...), 2500)
				contentUpdated = true
			}
		}

		if contentUpdated {
			m.logsDirty = true
			if m.activeTab == tabLogs {
				m.updateLogViewports()
			}
		}

		return m, nil
	}

	return m, nil
}

func fetchStateCmd(bin string, cwd string) tea.Cmd {
	return func() tea.Msg {
		st, err := fetchState(bin, cwd)
		return stateLoadedMsg{state: st, err: err}
	}
}

func stateTickCmd(interval time.Duration) tea.Cmd {
	return tea.Tick(interval, func(t time.Time) tea.Msg {
		return stateTickMsg(t)
	})
}

func logTickCmd(interval time.Duration) tea.Cmd {
	return tea.Tick(interval, func(t time.Time) tea.Msg {
		return logTickMsg(t)
	})
}

func runActionCmd(bin string, cwd string, action commandAction) tea.Cmd {
	return func() tea.Msg {
		out, err := runOrchdCommand(bin, cwd, action.Args...)
		return commandResultMsg{action: action, output: out, err: err}
	}
}

func pollLogsCmd(taskPath string, taskOffset int64, globalPath string, globalOffset int64) tea.Cmd {
	return func() tea.Msg {
		newTaskOffset, taskLines, err := pollLogAppend(taskPath, taskOffset)
		if err != nil {
			return logsPolledMsg{err: err}
		}

		newGlobalOffset, globalLines, err := pollLogAppend(globalPath, globalOffset)
		if err != nil {
			return logsPolledMsg{err: err}
		}

		return logsPolledMsg{
			taskPath:     taskPath,
			taskOffset:   newTaskOffset,
			taskLines:    taskLines,
			globalPath:   globalPath,
			globalOffset: newGlobalOffset,
			globalLines:  globalLines,
		}
	}
}

func attachTmuxCmd(session string) tea.Cmd {
	if runtime.GOOS == "windows" {
		return func() tea.Msg {
			return tmuxAttachMsg{err: errors.New("tmux attach is not supported on Windows")}
		}
	}
	if _, err := exec.LookPath("tmux"); err != nil {
		return func() tea.Msg {
			return tmuxAttachMsg{err: fmt.Errorf("tmux not found in PATH")}
		}
	}
	cmd := exec.Command("tmux", "attach", "-t", session)
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		return tmuxAttachMsg{err: err}
	})
}

func (m *model) moveSelection(delta int) {
	switch m.activeTab {
	case tabTasks, tabLogs:
		if m.focusPane == 0 {
			m.selectedTaskIdx = clamp(m.selectedTaskIdx+delta, 0, max(len(m.state.Tasks)-1, 0))
			m.refreshTaskDetails()
			if m.activeTab == tabLogs {
				m.rebindLogSources()
				m.updateLogViewports()
			}
		} else {
			if m.activeTab == tabTasks {
				if delta > 0 {
					m.detailViewport.LineDown(1)
				} else {
					m.detailViewport.LineUp(1)
				}
			} else {
				if delta > 0 {
					m.taskLogViewport.LineDown(1)
				} else {
					m.taskLogViewport.LineUp(1)
				}
			}
		}
	case tabMemory:
		if m.focusPane == 0 {
			m.selectedMemoryIdx = clamp(m.selectedMemoryIdx+delta, 0, max(len(m.memoryFiles)-1, 0))
			m.refreshMemoryViewport()
		} else {
			if delta > 0 {
				m.memoryViewport.LineDown(1)
			} else {
				m.memoryViewport.LineUp(1)
			}
		}
	case tabQueue:
		m.selectedQueueIdx = clamp(m.selectedQueueIdx+delta, 0, max(len(m.queueItems)-1, 0))
		m.refreshQueueViewport()
	case tabDAG:
		if delta > 0 {
			m.dagViewport.LineDown(1)
		} else {
			m.dagViewport.LineUp(1)
		}
	case tabStats:
		if delta > 0 {
			m.statsViewport.LineDown(1)
		} else {
			m.statsViewport.LineUp(1)
		}
	}
}

func (m *model) selectedTask() *taskState {
	if len(m.state.Tasks) == 0 {
		return nil
	}
	idx := clamp(m.selectedTaskIdx, 0, len(m.state.Tasks)-1)
	return &m.state.Tasks[idx]
}

func indexOfTaskByID(tasks []taskState, taskID string) int {
	if taskID == "" {
		return 0
	}
	for i, t := range tasks {
		if t.ID == taskID {
			return i
		}
	}
	return -1
}

func (m *model) refreshTaskDetails() {
	t := m.selectedTask()
	if t == nil {
		m.details = taskDetails{}
		m.detailViewport.SetContent("No task selected")
		return
	}

	details, _ := loadTaskDetails(m.state.ProjectRoot, t.ID)
	m.details = details
	m.refreshDetailViewport()
}

func (m *model) rebindLogSources() {
	newTaskPath := ""
	if t := m.selectedTask(); t != nil {
		newTaskPath = strings.TrimSpace(t.LogFile)
	}
	changed := false

	if m.taskLogPath != newTaskPath {
		m.taskLogPath = newTaskPath
		m.taskLogLines = readLastLines(newTaskPath, 900)
		m.taskLogOffset = fileSize(newTaskPath)
		changed = true
	}

	newGlobalPath := ""
	if strings.TrimSpace(m.state.ProjectRoot) != "" {
		newGlobalPath = filepath.Join(m.state.ProjectRoot, ".orchd", "orchd.log")
	}

	if m.globalLogPath != newGlobalPath {
		m.globalLogPath = newGlobalPath
		m.globalLogLines = readLastLines(newGlobalPath, 600)
		m.globalLogOffset = fileSize(newGlobalPath)
		changed = true
	}

	if changed {
		m.logsDirty = true
	}

	if m.activeTab == tabLogs && m.logsDirty {
		m.updateLogViewports()
	}
}

func fileSize(path string) int64 {
	if strings.TrimSpace(path) == "" {
		return 0
	}
	st, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return st.Size()
}

func (m *model) applyViewportsTheme() {
	m.detailViewport.Style = m.styles.TaskNormal
	m.taskLogViewport.Style = m.styles.TaskNormal
	m.globalViewport.Style = m.styles.Muted
	m.dagViewport.Style = m.styles.TaskNormal
	m.memoryViewport.Style = m.styles.TaskNormal
	m.queueViewport.Style = m.styles.TaskNormal
	m.statsViewport.Style = m.styles.TaskNormal
}

func (m *model) refreshAllViewportContent() {
	m.refreshDetailViewport()
	m.refreshDAGViewport()
	m.refreshMemoryViewport()
	m.refreshQueueViewport()
	m.refreshStatsViewport()
	m.updateLogViewports()
}

func (m *model) updateLogViewports() {
	taskLines := m.taskLogLines
	globalLines := m.globalLogLines

	if m.logFilter != "" {
		taskLines = filterLines(taskLines, m.logFilter)
		globalLines = filterLines(globalLines, m.logFilter)
	}

	if len(taskLines) == 0 {
		if m.logFilter != "" {
			m.taskLogViewport.SetContent("No task log lines match current filter")
		} else {
			m.taskLogViewport.SetContent("No task log yet")
		}
	} else {
		m.taskLogViewport.SetContent(strings.Join(taskLines, "\n"))
	}

	if len(globalLines) == 0 {
		if m.logFilter != "" {
			m.globalViewport.SetContent("No orchd.log lines match current filter")
		} else {
			m.globalViewport.SetContent("No orchd.log events yet")
		}
	} else {
		m.globalViewport.SetContent(strings.Join(globalLines, "\n"))
	}

	if m.followLogs {
		m.taskLogViewport.GotoBottom()
		m.globalViewport.GotoBottom()
	}

	m.logsDirty = false
}

func (m *model) refreshDetailViewport() {
	t := m.selectedTask()
	if t == nil {
		m.detailViewport.SetContent("No tasks available")
		return
	}

	deps := "none"
	if len(t.DepsSlice) > 0 {
		parts := make([]string, 0, len(t.DepsSlice))
		for _, dep := range t.DepsSlice {
			parts = append(parts, fmt.Sprintf("%s (%s)", dep, m.taskStatus(dep)))
		}
		deps = strings.Join(parts, ", ")
	}

	checkLine := "no check data"
	if m.details.CheckTotal > 0 {
		checkLine = fmt.Sprintf("%d/%d passed", m.details.CheckPassed, m.details.CheckTotal)
	}

	var b strings.Builder
	if strings.TrimSpace(t.Title) != "" {
		b.WriteString(t.Title)
		b.WriteString("\n\n")
	}
	fmt.Fprintf(&b, "role: %s\nrunner: %s\nattempts: %d\nagent alive: %t\n\n", emptyDash(t.Role), emptyDash(t.Runner), t.Attempts, t.AgentAlive)
	fmt.Fprintf(&b, "branch: %s\nsession: %s\nstarted: %s\nchecked: %s\nmerged: %s\n\n", emptyDash(t.Branch), emptyDash(t.Session), emptyDash(m.details.StartedAt), emptyDash(t.CheckedAt), emptyDash(t.MergedAt))
	fmt.Fprintf(&b, "deps: %s\n\n", deps)
	fmt.Fprintf(&b, "last check: %s\n\n", checkLine)

	if strings.TrimSpace(m.details.Description) != "" {
		b.WriteString("Description\n")
		b.WriteString(m.details.Description)
		b.WriteString("\n\n")
	}
	if strings.TrimSpace(m.details.Acceptance) != "" {
		b.WriteString("Acceptance\n")
		b.WriteString(m.details.Acceptance)
		b.WriteString("\n\n")
	}
	if strings.TrimSpace(m.details.LastCheck) != "" {
		b.WriteString("Check Output\n")
		b.WriteString(m.details.LastCheck)
		b.WriteString("\n")
	}

	wrapW := max(30, m.detailViewport.Width)
	text := strings.TrimSpace(wordwrap.String(b.String(), wrapW))
	if text == "" {
		text = "(no detail)"
	}

	m.detailViewport.SetContent(text)
	if m.followLogs {
		m.detailViewport.GotoTop()
	}
}

func (m *model) statusChip(status string) string {
	s := strings.ToLower(strings.TrimSpace(status))
	switch s {
	case "pending":
		return m.styles.ChipPending.Render("PENDING")
	case "running":
		return m.styles.ChipRunning.Render("RUNNING")
	case "done":
		return m.styles.ChipDone.Render("DONE")
	case "merged":
		return m.styles.ChipMerged.Render("MERGED")
	case "failed":
		return m.styles.ChipFailed.Render("FAILED")
	case "needs_input":
		return m.styles.ChipNeeds.Render("NEEDS")
	case "conflict":
		return m.styles.ChipConflict.Render("CONFLICT")
	default:
		return m.styles.Muted.Render(strings.ToUpper(truncate(s, 10)))
	}
}

func (m *model) refreshDAGViewport() {
	m.dagViewport.SetContent(renderDAG(m.state))
}

func (m *model) refreshMemoryViewport() {
	if len(m.memoryFiles) == 0 {
		m.memoryViewport.SetContent("Memory bank not initialized. Run: orchd memory init")
		return
	}
	idx := clamp(m.selectedMemoryIdx, 0, len(m.memoryFiles)-1)
	f := m.memoryFiles[idx]
	content := renderMarkdown(f.Path, max(40, m.memoryViewport.Width-4))
	m.memoryViewport.SetContent(content)
	m.memoryViewport.GotoTop()
}

func (m *model) refreshQueueViewport() {
	if len(m.queueItems) == 0 {
		m.queueViewport.SetContent("No ideas in queue. Add with: orchd idea \"...\"")
		return
	}

	lines := make([]string, 0, len(m.queueItems)+4)
	for i, item := range m.queueItems {
		prefix := "  "
		if i == m.selectedQueueIdx {
			prefix = "> "
		}
		lines = append(lines, fmt.Sprintf("%s[%s] %s  %s", prefix, item.Marker, item.Idea, item.Timestamp))
	}

	pending := 0
	active := 0
	done := 0
	for _, item := range m.queueItems {
		switch item.Status {
		case "pending":
			pending++
		case "active":
			active++
		case "done":
			done++
		}
	}

	lines = append(lines,
		"",
		fmt.Sprintf("pending=%d active=%d done=%d total=%d", pending, active, done, len(m.queueItems)),
	)

	m.queueViewport.SetContent(strings.Join(lines, "\n"))
}

func (m *model) refreshStatsViewport() {
	if m.state.Counts.Total == 0 {
		m.statsViewport.SetContent("No tasks yet")
		return
	}

	total := m.state.Counts.Total
	merged := m.state.Counts.Merged
	progress := (merged * 100) / max(total, 1)

	roleCounts := map[string]int{}
	for _, t := range m.state.Tasks {
		role := t.Role
		if strings.TrimSpace(role) == "" {
			role = "(none)"
		}
		roleCounts[role]++
	}

	roles := make([]string, 0, len(roleCounts))
	for k := range roleCounts {
		roles = append(roles, k)
	}
	sort.Strings(roles)

	roleLines := make([]string, 0, len(roles))
	for _, role := range roles {
		roleLines = append(roleLines, fmt.Sprintf("- %-12s %d", role+":", roleCounts[role]))
	}

	text := fmt.Sprintf(
		"Overview\n\nTotal tasks:     %d\nMerged:          %d (%d%%)\nRunning:         %d\nPending:         %d\nDone:            %d\nFailed:          %d\nConflict:        %d\nNeeds input:     %d\n\nReady queue\n\nSpawnable:       %d\nCheckable:       %d\nMergeable:       %d\n\nRoles\n\n%s\n\nProject\n\nRoot:            %s\nBase branch:     %s\nRunner:          %s\nMax parallel:    %d\nAutopilot:       %s\n",
		total,
		merged,
		progress,
		m.state.Counts.Running,
		m.state.Counts.Pending,
		m.state.Counts.Done,
		m.state.Counts.Failed,
		m.state.Counts.Conflict,
		m.state.Counts.NeedsInput,
		m.state.Ready.Spawn,
		m.state.Ready.Check,
		m.state.Ready.Merge,
		strings.Join(roleLines, "\n"),
		emptyDash(m.state.ProjectRoot),
		emptyDash(m.state.BaseBranch),
		emptyDash(m.state.WorkerRunner),
		m.state.MaxParallel,
		boolToWord(m.autopilotRunning),
	)

	m.statsViewport.SetContent(text)
}

func (m *model) taskStatus(taskID string) string {
	for _, t := range m.state.Tasks {
		if t.ID == taskID {
			return t.Status
		}
	}
	return "unknown"
}

func compactOutput(out string) string {
	out = strings.TrimSpace(out)
	if out == "" {
		return "ok"
	}
	line := firstLine(out)
	if len(line) > 100 {
		return line[:97] + "..."
	}
	return line
}

func boolToWord(v bool) string {
	if v {
		return "running"
	}
	return "stopped"
}

func emptyDash(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return "-"
	}
	return v
}

func clamp(v int, lo int, hi int) int {
	if hi < lo {
		return lo
	}
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func (m *model) closeWatcher() {
	if m.watcher != nil {
		_ = m.watcher.Close()
	}
	m.watcher = nil
	m.watchEvents = nil
	m.watchRoot = ""
}

func (m *model) startWatcherIfNeeded() tea.Cmd {
	root := strings.TrimSpace(m.state.ProjectRoot)
	if root == "" {
		return nil
	}

	if m.watcher != nil && m.watchRoot == root {
		return nil
	}

	m.closeWatcher()

	fw, err := startFileWatcher(root)
	if err != nil {
		m.statusLine = fmt.Sprintf("watcher disabled: %v", err)
		return nil
	}

	m.watcher = fw
	m.watchEvents = fw.Events()
	m.watchRoot = root
	m.statusLine = "File watcher active"
	return watchFileChangeCmd(m.watchEvents)
}

func watchFileChangeCmd(events <-chan fileChangedMsg) tea.Cmd {
	if events == nil {
		return nil
	}
	return func() tea.Msg {
		msg, ok := <-events
		if !ok {
			return fileChangedMsg{closed: true}
		}
		return msg
	}
}

func editorCommand(path string) (*exec.Cmd, error) {
	editor := strings.TrimSpace(os.Getenv("VISUAL"))
	if editor == "" {
		editor = strings.TrimSpace(os.Getenv("EDITOR"))
	}
	if editor == "" {
		editor = "vi"
	}

	parts := strings.Fields(editor)
	if len(parts) == 0 {
		return nil, fmt.Errorf("invalid editor command")
	}

	args := append(parts[1:], path)
	return exec.Command(parts[0], args...), nil
}

func (m *model) scrollFocusedTop() {
	switch m.activeTab {
	case tabTasks:
		if m.focusPane == 1 {
			m.detailViewport.GotoTop()
		}
	case tabLogs:
		if m.focusPane == 1 {
			m.taskLogViewport.GotoTop()
			m.globalViewport.GotoTop()
		}
	case tabDAG:
		m.dagViewport.GotoTop()
	case tabMemory:
		if m.focusPane == 1 {
			m.memoryViewport.GotoTop()
		}
	case tabQueue:
		m.queueViewport.GotoTop()
	case tabStats:
		m.statsViewport.GotoTop()
	}
}

func (m *model) scrollFocusedBottom() {
	switch m.activeTab {
	case tabTasks:
		if m.focusPane == 1 {
			m.detailViewport.GotoBottom()
		}
	case tabLogs:
		if m.focusPane == 1 {
			m.taskLogViewport.GotoBottom()
			m.globalViewport.GotoBottom()
		}
	case tabDAG:
		m.dagViewport.GotoBottom()
	case tabMemory:
		if m.focusPane == 1 {
			m.memoryViewport.GotoBottom()
		}
	case tabQueue:
		m.queueViewport.GotoBottom()
	case tabStats:
		m.statsViewport.GotoBottom()
	}
}

func (m *model) handleMouse(msg tea.MouseMsg) tea.Cmd {
	if m.pendingConfirm != nil || m.inputMode {
		return nil
	}

	if msg.Button == tea.MouseButtonWheelUp {
		m.moveSelection(-1)
		return nil
	}
	if msg.Button == tea.MouseButtonWheelDown {
		m.moveSelection(1)
		return nil
	}

	if msg.Action != tea.MouseActionPress || msg.Button != tea.MouseButtonLeft {
		return nil
	}

	if m.applyTabClick(msg.X, msg.Y) {
		return nil
	}

	leftW, _, bodyH := m.splitLayout()
	bodyStart := m.headerHeight()
	if msg.Y < bodyStart || msg.Y >= bodyStart+bodyH {
		return nil
	}

	if m.activeTab == tabTasks || m.activeTab == tabLogs {
		if msg.X < leftW {
			m.focusPane = 0
			row := msg.Y - bodyStart - 1
			if row >= 0 {
				start, end := listWindow(len(m.state.Tasks), m.selectedTaskIdx, max(1, bodyH-3))
				idx := start + row
				if idx >= start && idx < end && idx < len(m.state.Tasks) {
					m.selectedTaskIdx = idx
					m.refreshTaskDetails()
					if m.activeTab == tabLogs {
						m.rebindLogSources()
						m.updateLogViewports()
					}
				}
			}
		} else {
			m.focusPane = 1
		}
		return nil
	}

	if m.activeTab == tabMemory {
		if msg.X < leftW {
			m.focusPane = 0
			row := msg.Y - bodyStart - 1
			if row >= 0 {
				start, end := listWindow(len(m.memoryFiles), m.selectedMemoryIdx, max(1, bodyH-3))
				idx := start + row
				if idx >= start && idx < end && idx < len(m.memoryFiles) {
					m.selectedMemoryIdx = idx
					m.refreshMemoryViewport()
				}
			}
		} else {
			m.focusPane = 1
		}
	}

	return nil
}

func (m *model) applyTabClick(x int, y int) bool {
	tabY := m.tabLineY()
	if y != tabY {
		return false
	}

	pos := 0
	for i, name := range tabNames {
		label := fmt.Sprintf("%d %s", i+1, name)
		width := len(label) + 2
		if x >= pos && x < pos+width {
			m.activateTab(tab(i))
			return true
		}
		pos += width
	}

	return false
}

func (m *model) tabLineY() int {
	extra := 0
	if m.activeTab == tabLogs {
		extra = 1
	}
	if m.showLargeLogo() {
		logoLines := strings.Count(strings.TrimSpace(logoLarge), "\n") + 1
		return logoLines + 1 + extra
	}
	return 2 + extra
}

func max(a int, b int) int {
	if a > b {
		return a
	}
	return b
}
