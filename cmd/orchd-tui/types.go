package main

import "time"

type tab int

const (
	tabTasks tab = iota
	tabLogs
	tabDAG
	tabMemory
	tabQueue
	tabStats
)

var tabNames = []string{"Tasks", "Logs", "DAG", "Memory", "Queue", "Stats"}

func (t tab) String() string {
	if int(t) < 0 || int(t) >= len(tabNames) {
		return "Unknown"
	}
	return tabNames[t]
}

type orchState struct {
	ProjectRoot  string      `json:"project_root"`
	BaseBranch   string      `json:"base_branch"`
	WorktreeDir  string      `json:"worktree_dir"`
	WorkerRunner string      `json:"worker_runner"`
	MaxParallel  int         `json:"max_parallel"`
	Counts       stateCounts `json:"counts"`
	Ready        readyCounts `json:"ready"`
	Tasks        []taskState `json:"tasks"`
}

type stateCounts struct {
	Total      int `json:"total"`
	Pending    int `json:"pending"`
	Running    int `json:"running"`
	Done       int `json:"done"`
	Merged     int `json:"merged"`
	Failed     int `json:"failed"`
	Conflict   int `json:"conflict"`
	NeedsInput int `json:"needs_input"`
}

type readyCounts struct {
	Spawn int `json:"spawn"`
	Check int `json:"check"`
	Merge int `json:"merge"`
}

type taskState struct {
	ID                string   `json:"id"`
	Title             string   `json:"title"`
	Role              string   `json:"role"`
	Status            string   `json:"status"`
	Deps              string   `json:"deps"`
	Branch            string   `json:"branch"`
	Worktree          string   `json:"worktree"`
	Runner            string   `json:"runner"`
	Session           string   `json:"session"`
	AgentAlive        bool     `json:"agent_alive"`
	Attempts          int      `json:"attempts"`
	CheckedAt         string   `json:"checked_at"`
	MergedAt          string   `json:"merged_at"`
	LastFailureReason string   `json:"last_failure_reason"`
	LogFile           string   `json:"log_file"`
	DepsSlice         []string `json:"-"`
}

type taskDetails struct {
	Description string
	Acceptance  string
	LastCheck   string
	StartedAt   string
	CheckPassed int
	CheckTotal  int
	CheckFailed int
}

type memoryFile struct {
	Name  string
	Path  string
	Bytes int64
}

type queueItem struct {
	LineNo    int
	Marker    string
	Status    string
	Timestamp string
	Idea      string
}

type commandAction struct {
	Label  string
	Prompt string
	Args   []string
	Index  int
}

type stateLoadedMsg struct {
	state orchState
	err   error
}

type commandResultMsg struct {
	action commandAction
	output string
	err    error
}

type logsPolledMsg struct {
	taskPath     string
	taskOffset   int64
	taskLines    []string
	globalPath   string
	globalOffset int64
	globalLines  []string
	err          error
}

type stateTickMsg time.Time

type logTickMsg time.Time

type tmuxAttachMsg struct {
	err error
}

type editorDoneMsg struct {
	err error
}

type fileChangedMsg struct {
	root   string
	path   string
	err    error
	closed bool
}
