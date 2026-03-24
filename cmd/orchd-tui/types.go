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
	ProjectRoot  string                     `json:"project_root"`
	BaseBranch   string                     `json:"base_branch"`
	WorktreeDir  string                     `json:"worktree_dir"`
	WorkerRunner string                     `json:"worker_runner"`
	MaxParallel  int                        `json:"max_parallel"`
	Counts       stateCounts                `json:"counts"`
	Ready        readyCounts                `json:"ready"`
	Finisher     finisherState              `json:"finisher"`
	Scheduler    schedulerState             `json:"scheduler"`
	Orchestrator orchestratorRuntimeState   `json:"orchestrator"`
	SwarmRouting map[string]swarmRouteState `json:"swarm_routing"`
	Tasks        []taskState                `json:"tasks"`
}

type stateCounts struct {
	Total      int `json:"total"`
	Pending    int `json:"pending"`
	Running    int `json:"running"`
	Done       int `json:"done"`
	Merged     int `json:"merged"`
	Split      int `json:"split"`
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
	ID                            string           `json:"id"`
	Title                         string           `json:"title"`
	Role                          string           `json:"role"`
	Status                        string           `json:"status"`
	EffectiveStatus               string           `json:"effective_status"`
	Deps                          string           `json:"deps"`
	Branch                        string           `json:"branch"`
	Worktree                      string           `json:"worktree"`
	Runner                        string           `json:"runner"`
	RoutingRole                   string           `json:"routing_role"`
	SelectedRunner                string           `json:"selected_runner"`
	RoutingDefaultRunner          string           `json:"routing_default_runner"`
	RoutingCandidates             string           `json:"routing_candidates"`
	RoutingFallbackUsed           bool             `json:"routing_fallback_used"`
	RoutingFallbackCount          int              `json:"routing_fallback_count"`
	RoutingReason                 string           `json:"routing_reason"`
	Session                       string           `json:"session"`
	SessionState                  string           `json:"session_state"`
	AgentAlive                    bool             `json:"agent_alive"`
	Attempts                      int              `json:"attempts"`
	CheckedAt                     string           `json:"checked_at"`
	MergedAt                      string           `json:"merged_at"`
	LastFailureReason             string           `json:"last_failure_reason"`
	VerificationTier              string           `json:"verification_tier"`
	VerificationReason            string           `json:"verification_reason"`
	FailureClass                  string           `json:"failure_class"`
	FailureSummary                string           `json:"failure_summary"`
	FailureStreak                 int              `json:"failure_streak"`
	RecoveryPolicy                string           `json:"recovery_policy"`
	RecoveryNextAction            string           `json:"recovery_next_action"`
	RecoveryPolicyReason          string           `json:"recovery_policy_reason"`
	ReviewStatus                  string           `json:"review_status"`
	ReviewReason                  string           `json:"review_reason"`
	ReviewRequired                bool             `json:"review_required"`
	ReviewedAt                    string           `json:"reviewed_at"`
	ReviewRunner                  string           `json:"review_runner"`
	ReviewOutputFile              string           `json:"review_output_file"`
	MergeGateStatus               string           `json:"merge_gate_status"`
	MergeGateReason               string           `json:"merge_gate_reason"`
	MergeRequiredVerificationTier string           `json:"merge_required_verification_tier"`
	SplitChildren                 string           `json:"split_children"`
	LogFile                       string           `json:"log_file"`
	NeedsInput                    *needsInputState `json:"needs_input"`
	DepsSlice                     []string         `json:"-"`
}

type finisherState struct {
	State     string `json:"state"`
	Reason    string `json:"reason"`
	UpdatedAt string `json:"updated_at"`
}

type schedulerScopeState struct {
	Action    string `json:"action"`
	Reason    string `json:"reason"`
	UpdatedAt string `json:"updated_at"`
}

type schedulerState struct {
	LastAction  string              `json:"last_action"`
	LastReason  string              `json:"last_reason"`
	UpdatedAt   string              `json:"updated_at"`
	Autopilot   schedulerScopeState `json:"autopilot"`
	Orchestrate schedulerScopeState `json:"orchestrate"`
}

type orchestratorRuntimeState struct {
	RouteRole          string `json:"route_role"`
	SelectedRunner     string `json:"selected_runner"`
	RouteReason        string `json:"route_reason"`
	RouteFallbackUsed  bool   `json:"route_fallback_used"`
	SessionMode        string `json:"session_mode"`
	LastResult         string `json:"last_result"`
	LastReason         string `json:"last_reason"`
	LastIdleDecision   string `json:"last_idle_decision"`
	LastReminderReason string `json:"last_reminder_reason"`
}

type swarmRouteState struct {
	SelectedRunner  string `json:"selected_runner"`
	PreferredRunner string `json:"preferred_runner"`
	DefaultRunner   string `json:"default_runner"`
	Candidates      string `json:"candidates"`
	FallbackUsed    bool   `json:"fallback_used"`
	Reason          string `json:"reason"`
}

type needsInputState struct {
	Source   string `json:"source"`
	File     string `json:"file"`
	Code     string `json:"code"`
	Summary  string `json:"summary"`
	Question string `json:"question"`
	Blocking string `json:"blocking"`
	Options  string `json:"options"`
	Error    string `json:"error"`
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
