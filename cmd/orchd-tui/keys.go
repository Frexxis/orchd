package main

import "github.com/charmbracelet/bubbles/key"

type keyMap struct {
	Quit       key.Binding
	Help       key.Binding
	NextTab    key.Binding
	PrevTab    key.Binding
	SwitchPane key.Binding
	Refresh    key.Binding

	Up   key.Binding
	Down key.Binding

	Spawn      key.Binding
	SpawnAll   key.Binding
	Check      key.Binding
	CheckAll   key.Binding
	Merge      key.Binding
	MergeAll   key.Binding
	Resume     key.Binding
	AttachTmux key.Binding
	FollowLogs key.Binding
	ScrollTop  key.Binding
	ScrollEnd  key.Binding
	FilterLogs key.Binding

	NewIdea    key.Binding
	CancelIdea key.Binding
	EditFile   key.Binding

	Accept key.Binding
	Cancel key.Binding
}

func defaultKeys() keyMap {
	return keyMap{
		Quit: key.NewBinding(
			key.WithKeys("q", "ctrl+c"),
			key.WithHelp("q", "quit"),
		),
		Help: key.NewBinding(
			key.WithKeys("?"),
			key.WithHelp("?", "help"),
		),
		NextTab: key.NewBinding(
			key.WithKeys("ctrl+right", "]"),
			key.WithHelp("]", "next tab"),
		),
		PrevTab: key.NewBinding(
			key.WithKeys("ctrl+left", "["),
			key.WithHelp("[", "prev tab"),
		),
		SwitchPane: key.NewBinding(
			key.WithKeys("tab"),
			key.WithHelp("tab", "switch pane"),
		),
		Refresh: key.NewBinding(
			key.WithKeys("r"),
			key.WithHelp("r", "refresh"),
		),

		Up: key.NewBinding(
			key.WithKeys("up", "k"),
			key.WithHelp("up/k", "up"),
		),
		Down: key.NewBinding(
			key.WithKeys("down", "j"),
			key.WithHelp("down/j", "down"),
		),

		Spawn: key.NewBinding(
			key.WithKeys("s"),
			key.WithHelp("s", "spawn task"),
		),
		SpawnAll: key.NewBinding(
			key.WithKeys("S"),
			key.WithHelp("S", "spawn all"),
		),
		Check: key.NewBinding(
			key.WithKeys("c"),
			key.WithHelp("c", "check task"),
		),
		CheckAll: key.NewBinding(
			key.WithKeys("C"),
			key.WithHelp("C", "check all"),
		),
		Merge: key.NewBinding(
			key.WithKeys("m"),
			key.WithHelp("m", "merge task"),
		),
		MergeAll: key.NewBinding(
			key.WithKeys("M"),
			key.WithHelp("M", "merge all"),
		),
		Resume: key.NewBinding(
			key.WithKeys("x"),
			key.WithHelp("x", "resume task"),
		),
		AttachTmux: key.NewBinding(
			key.WithKeys("a"),
			key.WithHelp("a", "attach tmux"),
		),
		FollowLogs: key.NewBinding(
			key.WithKeys("f"),
			key.WithHelp("f", "toggle follow"),
		),
		ScrollTop: key.NewBinding(
			key.WithKeys("g"),
			key.WithHelp("g", "go top"),
		),
		ScrollEnd: key.NewBinding(
			key.WithKeys("G"),
			key.WithHelp("G", "go bottom"),
		),
		FilterLogs: key.NewBinding(
			key.WithKeys("/"),
			key.WithHelp("/", "filter logs"),
		),
		NewIdea: key.NewBinding(
			key.WithKeys("n"),
			key.WithHelp("n", "new idea"),
		),
		CancelIdea: key.NewBinding(
			key.WithKeys("d"),
			key.WithHelp("d", "cancel idea"),
		),
		EditFile: key.NewBinding(
			key.WithKeys("e"),
			key.WithHelp("e", "edit file"),
		),

		Accept: key.NewBinding(
			key.WithKeys("y", "enter"),
			key.WithHelp("y/enter", "confirm"),
		),
		Cancel: key.NewBinding(
			key.WithKeys("n", "esc"),
			key.WithHelp("n/esc", "cancel"),
		),
	}
}

func (k keyMap) ShortHelp() []key.Binding {
	return []key.Binding{
		k.SwitchPane,
		k.Up,
		k.Down,
		k.Spawn,
		k.Check,
		k.Merge,
		k.FollowLogs,
		k.Resume,
		k.Help,
		k.Quit,
	}
}

func (k keyMap) FullHelp() [][]key.Binding {
	return [][]key.Binding{
		{k.NextTab, k.PrevTab, k.SwitchPane, k.Refresh, k.Help, k.Quit},
		{k.Up, k.Down, k.Spawn, k.SpawnAll, k.Check, k.CheckAll, k.Merge, k.MergeAll, k.Resume, k.AttachTmux},
		{k.FollowLogs, k.ScrollTop, k.ScrollEnd, k.FilterLogs, k.NewIdea, k.CancelIdea, k.EditFile},
		{k.Accept, k.Cancel},
	}
}
