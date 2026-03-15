package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

const paneGap = 2

func (m *model) resizeViewports() {
	if m.width <= 0 || m.height <= 0 {
		return
	}

	_, rightW, bodyH := m.splitLayout()

	contentH := max(1, bodyH-2)
	contentW := max(20, rightW-2)

	m.detailViewport.Width = contentW
	m.detailViewport.Height = contentH

	topOuter := max(4, bodyH/2)
	bottomOuter := max(4, bodyH-topOuter)
	if bottomOuter < 4 {
		bottomOuter = 4
		topOuter = max(4, bodyH-bottomOuter)
	}

	m.taskLogViewport.Width = contentW
	m.taskLogViewport.Height = max(1, topOuter-2)
	m.globalViewport.Width = contentW
	m.globalViewport.Height = max(1, bottomOuter-2)

	m.dagViewport.Width = max(20, m.width-2)
	m.dagViewport.Height = max(1, bodyH-2)

	m.memoryViewport.Width = contentW
	m.memoryViewport.Height = contentH

	m.queueViewport.Width = max(20, m.width-2)
	m.queueViewport.Height = max(1, bodyH-2)

	m.statsViewport.Width = max(20, m.width-2)
	m.statsViewport.Height = max(1, bodyH-2)
}

func (m model) View() string {
	if m.width == 0 || m.height == 0 {
		return "Loading..."
	}

	header := m.viewHeader()
	body := m.viewBody()
	footer := m.viewFooter()

	out := lipgloss.JoinVertical(lipgloss.Left, header, body, footer)

	if m.pendingConfirm != nil {
		confirm := m.styles.Confirm.Render("CONFIRM: " + m.pendingConfirm.Prompt)
		out = lipgloss.JoinVertical(lipgloss.Left, out, confirm)
	}

	if m.inputMode {
		inputLine := m.styles.Confirm.Render(fmt.Sprintf("%s: %s_", m.inputPrompt, m.inputValue))
		out = lipgloss.JoinVertical(lipgloss.Left, out, inputLine)
	}

	if m.showHelp {
		helpText := m.styles.Help.Render(m.help.FullHelpView(m.keys.FullHelp()))
		out = lipgloss.JoinVertical(lipgloss.Left, out, helpText)
	}

	return m.styles.Root.
		Width(m.width).
		MaxWidth(m.width).
		MaxHeight(m.height).
		Render(out)
}

func (m model) viewHeader() string {
	parts := make([]string, 0, 4)

	if m.showLargeLogo() {
		parts = append(parts, m.styles.Logo.Render(strings.TrimSpace(logoLarge)))
	} else {
		parts = append(parts, m.styles.Logo.Render(strings.ToUpper(logoSmall)))
	}

	project := m.state.ProjectRoot
	if project == "" {
		project = m.cfg.projectDir
	}

	autopilot := "OFF"
	if m.autopilotRunning {
		autopilot = "ON"
	}

	summary := fmt.Sprintf(
		"orchd-tui %s | project: %s | runner: %s | tasks: %d | autopilot: %s",
		version,
		project,
		emptyDash(m.state.WorkerRunner),
		m.state.Counts.Total,
		autopilot,
	)
	summary = fitPlainLine(summary, max(20, m.width-4))
	parts = append(parts, m.styles.Summary.Render(summary))
	if m.activeTab == tabLogs {
		if strings.TrimSpace(m.logFilter) != "" {
			parts = append(parts, m.styles.StatusInfo.Render(fitPlainLine("log filter: "+m.logFilter, max(20, m.width-4))))
		} else {
			parts = append(parts, m.styles.Muted.Render("log filter: (none)"))
		}
	}

	tabs := make([]string, 0, len(tabNames))
	for i, name := range tabNames {
		label := fmt.Sprintf("%d %s", i+1, name)
		if tab(i) == m.activeTab {
			tabs = append(tabs, m.styles.TabActive.Render(label))
		} else {
			tabs = append(tabs, m.styles.TabInactive.Render(label))
		}
	}
	parts = append(parts, lipgloss.JoinHorizontal(lipgloss.Left, tabs...))

	if m.stateErr != "" {
		parts = append(parts, m.styles.StatusBad.Render("state error: "+m.stateErr))
	}

	return m.styles.Header.Render(strings.Join(parts, "\n"))
}

func (m model) viewBody() string {
	leftW, rightW, bodyH := m.splitLayout()
	gap := strings.Repeat(" ", paneGap)

	switch m.activeTab {
	case tabTasks:
		leftTitle := fmt.Sprintf("Tasks (%d)", m.state.Counts.Total)
		left := m.renderPanel(leftTitle, m.renderTaskList(bodyH-3, leftW), leftW, bodyH, m.focusPane == 0)
		rightContent := m.detailViewport.View()
		if len(m.state.Tasks) == 0 {
			rightContent = m.renderEmptyTasks()
		}
		rightTitle := "Task Detail"
		if t := m.selectedTask(); t != nil {
			rightTitle = fmt.Sprintf("%s %s", t.ID, (&m).statusChip((&m).taskDisplayStatus(*t)))
		}
		right := m.renderPanel(rightTitle, rightContent, rightW, bodyH, m.focusPane == 1)
		return lipgloss.JoinHorizontal(lipgloss.Top, left, gap, right)
	case tabLogs:
		leftTitle := fmt.Sprintf("Tasks (%d)", m.state.Counts.Total)
		left := m.renderPanel(leftTitle, m.renderTaskList(bodyH-3, leftW), leftW, bodyH, m.focusPane == 0)
		topTitle := "Task Log"
		if t := m.selectedTask(); t != nil {
			topTitle = fmt.Sprintf("Task Log: %s", t.ID)
		}
		top := m.renderPanel(topTitle, m.taskLogViewport.View(), rightW, max(4, bodyH/2), m.focusPane == 1)
		bottom := m.renderPanel("orchd.log", m.globalViewport.View(), rightW, bodyH-max(4, bodyH/2), false)
		right := lipgloss.JoinVertical(lipgloss.Left, top, bottom)
		return lipgloss.JoinHorizontal(lipgloss.Top, left, gap, right)
	case tabDAG:
		return m.renderPanel("DAG", m.dagViewport.View(), m.width, bodyH, true)
	case tabMemory:
		memTitle := "Memory Files"
		if len(m.memoryFiles) > 0 {
			idx := clamp(m.selectedMemoryIdx, 0, len(m.memoryFiles)-1)
			memTitle = fmt.Sprintf("Memory: %s", m.memoryFiles[idx].Name)
		}
		left := m.renderPanel(memTitle, m.renderMemoryList(bodyH-3, leftW), leftW, bodyH, m.focusPane == 0)
		right := m.renderPanel("Memory", m.memoryViewport.View(), rightW, bodyH, m.focusPane == 1)
		return lipgloss.JoinHorizontal(lipgloss.Top, left, gap, right)
	case tabQueue:
		return m.renderPanel("Idea Queue", m.queueViewport.View(), m.width, bodyH, true)
	case tabStats:
		return m.renderPanel("Project Stats", m.statsViewport.View(), m.width, bodyH, true)
	default:
		return m.renderPanel("Unknown", "", m.width, bodyH, true)
	}
}

func (m model) splitLayout() (leftW int, rightW int, bodyH int) {
	headerH := m.headerHeight()
	footerH := m.footerHeight()
	bodyH = max(6, m.height-headerH-footerH)

	availableW := m.width
	if availableW < 1 {
		availableW = 1
	}
	if availableW > paneGap {
		availableW = availableW - paneGap
	}

	leftW = max(32, availableW/3)
	rightW = max(32, availableW-leftW)

	if availableW < 100 {
		leftW = max(28, availableW/2)
		rightW = max(28, availableW-leftW)
	}

	return leftW, rightW, bodyH
}

func (m model) renderEmptyTasks() string {
	root := m.state.ProjectRoot
	if root == "" {
		root = m.cfg.projectDir
	}

	lines := []string{
		"Nothing to show yet.",
		"",
		"Quick start:",
		"  1) orchd init . \"<description>\"",
		"  2) orchd plan \"<what should be built>\"",
		"  3) orchd spawn --all",
		"  4) orchd check --all",
		"  5) orchd merge --all",
		"",
		"From here:",
		"  - Press r to refresh",
		"  - Press ? for keys",
		"",
		"Project:",
		"  " + root,
	}

	return strings.Join(lines, "\n")
}

func (m model) footerHeight() int {
	h := strings.Count(m.viewFooter(), "\n") + 1
	if h < 2 {
		h = 2
	}
	return h
}

func (m model) headerHeight() int {
	base := 2 // logo line(s) handled below + summary
	if m.showLargeLogo() {
		logoLines := strings.Count(strings.TrimSpace(logoLarge), "\n") + 1
		base = logoLines + 1
	} else {
		base = 2
	}
	// tabs
	base += 1
	// optional log filter line
	if m.activeTab == tabLogs {
		base += 1
	}
	// optional state error line
	if m.stateErr != "" {
		base += 1
	}
	if base < 4 {
		base = 4
	}
	return base
}

func (m model) showLargeLogo() bool {
	if !m.cfg.showSplash {
		return false
	}
	if m.state.Counts.Total > 0 {
		return false
	}
	return m.width >= 96 && m.height >= 24
}

func (m model) renderPanel(title string, content string, width int, height int, focused bool) string {
	if width < 12 {
		width = 12
	}
	if height < 4 {
		height = 4
	}
	if strings.TrimSpace(content) == "" {
		content = "(no data)"
	}

	panel := m.styles.Panel
	titleBar := m.styles.PanelTitleBar
	bodyStyle := m.styles.PanelBody
	if focused {
		panel = m.styles.PanelFocused
		titleBar = m.styles.TabActive
		// Make tab style behave like a title bar
		titleBar = titleBar.Padding(0, 1)
	}

	titleLine := titleBar.Width(width).MaxWidth(width).Render(title)
	bodyH := max(1, height-1)
	body := bodyStyle.
		Width(width).
		MaxWidth(width).
		Height(bodyH).
		MaxHeight(bodyH).
		Render(content)

	return panel.Width(width).Height(height).Render(lipgloss.JoinVertical(lipgloss.Left, titleLine, body))
}

func (m model) renderTaskList(height int, width int) string {
	if len(m.state.Tasks) == 0 {
		return "(no tasks)\nRun: orchd plan \"<description>\""
	}
	if height < 1 {
		height = 1
	}

	start, end := listWindow(len(m.state.Tasks), m.selectedTaskIdx, max(1, height))
	lines := make([]string, 0, end-start)
	innerW := max(24, width-2)
	roleW := 8
	chipW := 10
	idW := max(14, innerW-(3+roleW+chipW))
	if idW > 36 {
		idW = 36
	}
	for i := start; i < end; i++ {
		t := m.state.Tasks[i]
		displayStatus := m.taskDisplayStatus(t)
		chip := m.statusChip(displayStatus)
		role := t.Role
		if strings.TrimSpace(role) == "" {
			role = "-"
		}
		line := fmt.Sprintf("%s %-*s %-*s %s", statusASCII(displayStatus), idW, truncate(t.ID, idW), roleW, truncate(role, roleW), chip)
		if i == m.selectedTaskIdx {
			line = m.styles.TaskSelected.Render(line)
		} else {
			line = m.styles.TaskNormal.Render(line)
		}
		lines = append(lines, line)
	}

	return strings.Join(lines, "\n")
}

func (m model) renderMemoryList(height int, width int) string {
	if len(m.memoryFiles) == 0 {
		return "No memory files"
	}
	if height < 1 {
		height = 1
	}

	start, end := listWindow(len(m.memoryFiles), m.selectedMemoryIdx, max(1, height))
	lines := make([]string, 0, end-start)
	innerW := max(30, width-2)
	nameW := max(16, innerW-10)
	for i := start; i < end; i++ {
		f := m.memoryFiles[i]
		line := fmt.Sprintf("%-*s %8d", nameW, truncate(f.Name, nameW), f.Bytes)
		if i == m.selectedMemoryIdx {
			line = m.styles.TaskSelected.Render(line)
		} else {
			line = m.styles.TaskNormal.Render(line)
		}
		lines = append(lines, line)
	}

	return strings.Join(lines, "\n")
}

func (m model) viewFooter() string {
	total := m.state.Counts.Total
	merged := m.state.Counts.Merged
	pct := 0
	if total > 0 {
		pct = (merged * 100) / total
	}

	barW := max(10, min(36, m.width/5))
	filled := (pct * barW) / 100
	bar := strings.Repeat("=", filled) + strings.Repeat("-", barW-filled)

	countLine := fmt.Sprintf(
		"[%s] %3d%%  total=%d pending=%d running=%d done=%d merged=%d failed=%d",
		bar,
		pct,
		m.state.Counts.Total,
		m.state.Counts.Pending,
		m.state.Counts.Running,
		m.state.Counts.Done,
		m.state.Counts.Merged,
		m.state.Counts.Failed,
	)

	keysLine := "tab pane  1-6 tabs  s/c/m/x actions  a attach  f/g/G// log nav  n/d queue  e edit  r refresh  ? help  q quit"

	status := m.statusLine
	if m.commandBusy {
		status = "Working... " + status
	}
	if !m.lastStateUpdate.IsZero() {
		status = status + " | updated " + compactDuration(m.lastStateUpdate.Format(timeLayout)) + " ago"
	}

	lineWidth := max(24, m.width-4)
	countLine = fitPlainLine(countLine, lineWidth)
	keysLine = fitPlainLine(keysLine, lineWidth)
	status = fitPlainLine(status, lineWidth)

	footer := strings.Join([]string{
		countLine,
		keysLine,
		m.styles.FooterMessage.Render(status),
	}, "\n")

	return m.styles.Footer.Width(m.width).Render(footer)
}

const timeLayout = time.RFC3339

func listWindow(total int, selected int, visible int) (int, int) {
	if total <= visible {
		return 0, total
	}
	half := visible / 2
	start := selected - half
	if start < 0 {
		start = 0
	}
	end := start + visible
	if end > total {
		end = total
		start = end - visible
	}
	return start, end
}

func truncate(value string, width int) string {
	if width <= 0 {
		return ""
	}
	if len(value) <= width {
		return value
	}
	if width <= 3 {
		return value[:width]
	}
	return value[:width-3] + "..."
}

func fitPlainLine(line string, width int) string {
	if width <= 0 {
		return ""
	}
	if len(line) <= width {
		return line
	}
	if width <= 3 {
		return line[:width]
	}
	return line[:width-3] + "..."
}

func min(a int, b int) int {
	if a < b {
		return a
	}
	return b
}
