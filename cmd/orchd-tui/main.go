package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const version = "0.1.2"

type appConfig struct {
	projectDir string
	themeName  string
	refresh    time.Duration
	showSplash bool
}

func main() {
	var cfg appConfig
	var refreshSec int
	var showVersion bool

	flag.StringVar(&cfg.projectDir, "project", ".", "Project directory (orchd project root or child path)")
	flag.StringVar(&cfg.themeName, "theme", "auto", "Theme: auto|dark|light")
	flag.IntVar(&refreshSec, "refresh", 5, "State refresh interval in seconds")
	flag.BoolVar(&cfg.showSplash, "splash", true, "Show large ASCII splash header")
	flag.BoolVar(&showVersion, "version", false, "Print version")
	flag.Parse()

	if showVersion {
		fmt.Println(version)
		return
	}

	if refreshSec < 1 {
		refreshSec = 1
	}
	cfg.refresh = time.Duration(refreshSec) * time.Second

	m, err := newModel(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "orchd-tui: %v\n", err)
		os.Exit(1)
	}

	p := tea.NewProgram(
		m,
		tea.WithAltScreen(),
		tea.WithMouseCellMotion(),
	)

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "orchd-tui: %v\n", err)
		os.Exit(1)
	}
}
