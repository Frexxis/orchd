package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestViewShowsHeaderAndPanelsBeforeStateLoad(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: true})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	updated, _ := m.Update(tea.WindowSizeMsg{Width: 140, Height: 40})
	model := updated.(model)
	out := model.View()

	checks := []string{
		"Tasks",
		"Task Detail",
	}

	for _, needle := range checks {
		if !strings.Contains(out, needle) {
			t.Fatalf("expected view output to contain %q", needle)
		}
	}
}

func TestViewShowsHeaderAndPanelsOnVeryWideTerminal(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: true})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	updated, _ := m.Update(tea.WindowSizeMsg{Width: 240, Height: 70})
	model := updated.(model)
	out := model.View()

	checks := []string{"Tasks", "Task Detail"}
	for _, needle := range checks {
		if !strings.Contains(out, needle) {
			t.Fatalf("expected wide view output to contain %q", needle)
		}
	}
}

func TestViewShowsNoTasksHint(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: false})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	m.state = orchState{}
	updated, _ := m.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	model := updated.(model)
	out := model.View()

	if !strings.Contains(out, "Run: orchd plan") {
		t.Fatalf("expected no-tasks hint in output")
	}
}

func TestViewKeepsHeaderVisibleWithVeryLongDetailContent(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: true})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	m.state = orchState{
		ProjectRoot: "/tmp/project",
		Tasks: []taskState{{
			ID:     "summary-quality-rubric",
			Title:  "Summary Quality Rubric",
			Status: "merged",
			Role:   "quality",
		}},
	}
	m.selectedTaskIdx = 0
	m.details = taskDetails{
		Description: strings.Repeat("Very long detail line that would normally wrap hard in terminal output. ", 40),
		Acceptance:  strings.Repeat("Acceptance criterion content. ", 40),
		LastCheck:   strings.Repeat("[PASS] check line ", 50),
	}

	updated, _ := m.Update(tea.WindowSizeMsg{Width: 220, Height: 60})
	model := updated.(model)
	model.refreshAllViewportContent()
	out := model.View()

	checks := []string{"o r c h d", "Tasks", "summary-quality-rubric"}
	for _, needle := range checks {
		if !strings.Contains(out, needle) {
			t.Fatalf("expected long-content view output to contain %q", needle)
		}
	}
}

func TestViewShowsNeedsInputDetails(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: false})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	m.state = orchState{
		ProjectRoot: "/tmp/project",
		Tasks: []taskState{{
			ID:              "needs-input-task",
			Title:           "Needs Product Decision",
			Status:          "needs_input",
			EffectiveStatus: "needs_input",
			Role:            "domain",
			NeedsInput: &needsInputState{
				Source:   "json",
				Code:     "decision_required",
				Summary:  "Need product direction",
				Question: "Should we ship flow A or B?",
				Options:  "flow_a | flow_b",
				Blocking: "true",
			},
		}},
	}
	m.selectedTaskIdx = 0

	updated, _ := m.Update(tea.WindowSizeMsg{Width: 160, Height: 40})
	model := updated.(model)
	model.refreshAllViewportContent()
	out := model.View()

	checks := []string{"Needs Input", "decision_required"}
	for _, needle := range checks {
		if !strings.Contains(out, needle) {
			t.Fatalf("expected needs-input view output to contain %q", needle)
		}
	}
}

func TestViewShowsSwarmDetailFields(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: false})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	m.state = orchState{
		ProjectRoot: "/tmp/project",
		Tasks: []taskState{{
			ID:                            "risky-task",
			Title:                         "Risky Merge Candidate",
			Status:                        "done",
			EffectiveStatus:               "done",
			Role:                          "builder",
			Runner:                        "codex",
			RoutingRole:                   "builder",
			SelectedRunner:                "codex",
			RoutingFallbackUsed:           true,
			RoutingFallbackCount:          2,
			RoutingReason:                 "preferred runner unavailable; fell back to codex",
			VerificationTier:              "targeted",
			VerificationReason:            "medium-risk task defaults to targeted verification",
			FailureClass:                  "test_failure",
			RecoveryPolicy:                "retry_alternate_runner",
			RecoveryNextAction:            "resume_with_recovery_prompt",
			ReviewRequired:                true,
			ReviewStatus:                  "approved",
			ReviewReason:                  "diff looks safe",
			ReviewRunner:                  "claude",
			MergeGateStatus:               "ready",
			MergeGateReason:               "review approval compensates for verification tier targeted on risky task",
			MergeRequiredVerificationTier: "full",
			SplitChildren:                 "risky-task-a,risky-task-b",
		}},
	}
	m.selectedTaskIdx = 0

	updated, _ := m.Update(tea.WindowSizeMsg{Width: 180, Height: 44})
	model := updated.(model)
	model.refreshAllViewportContent()
	out := model.View()

	checks := []string{"Swarm", "routing role:", "verification tier:", "review status:", "merge gate:"}
	for _, needle := range checks {
		if !strings.Contains(out, needle) {
			t.Fatalf("expected swarm detail view output to contain %q", needle)
		}
	}
}

func TestStatsViewShowsSchedulerAndFinisherSummary(t *testing.T) {
	m, err := newModel(appConfig{projectDir: ".", themeName: "dark", showSplash: false})
	if err != nil {
		t.Fatalf("newModel: %v", err)
	}

	m.activeTab = tabStats
	m.state = orchState{
		ProjectRoot:  "/tmp/project",
		BaseBranch:   "main",
		WorkerRunner: "codex",
		MaxParallel:  3,
		Counts:       stateCounts{Total: 3, Merged: 1, Split: 1, Running: 0, Pending: 1, Done: 0, Failed: 1, Conflict: 0, NeedsInput: 0},
		Ready:        readyCounts{Spawn: 1, Check: 0, Merge: 0},
		Finisher:     finisherState{State: "next_phase_available", Reason: "follow-on work exists"},
		Scheduler:    schedulerState{LastAction: "spawn", LastReason: "ready tasks can be spawned"},
		Orchestrator: orchestratorRuntimeState{RouteRole: "architect", SelectedRunner: "claude", LastReminderReason: "system reminder: state changed"},
		Tasks:        []taskState{{ID: "a", Role: "builder"}, {ID: "b", Role: "reviewer"}, {ID: "c", Role: "builder"}},
	}

	updated, _ := m.Update(tea.WindowSizeMsg{Width: 180, Height: 44})
	model := updated.(model)
	model.refreshAllViewportContent()
	out := model.View()

	checks := []string{"Last decision:", "Finisher state:", "Orch route:", "Idle avoidance:"}
	for _, needle := range checks {
		if !strings.Contains(out, needle) {
			t.Fatalf("expected stats view output to contain %q", needle)
		}
	}
}
