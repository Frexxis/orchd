package main

import (
	"fmt"

	"github.com/charmbracelet/lipgloss"
)

const logoLarge = `
   ____   _____  _____  __  __
  / __ \ / ___/ / ___/ / / / /
 / / / // /    / /    / /_/ /
/ /_/ // /___ / /___ / __  /
\____/ \____/ \____//_/ /_/

  o r c h d    t e r m i n a l    u i
`

const logoSmall = "orchd tui"

type palette struct {
	Background    lipgloss.Color
	PanelBG       lipgloss.Color
	PanelBGFocus  lipgloss.Color
	Foreground    lipgloss.Color
	Muted         lipgloss.Color
	Accent        lipgloss.Color
	Success       lipgloss.Color
	Warning       lipgloss.Color
	Danger        lipgloss.Color
	Info          lipgloss.Color
	Border        lipgloss.Color
	FocusedBorder lipgloss.Color
	SelectedBG    lipgloss.Color
	SelectedFG    lipgloss.Color
}

type uiStyles struct {
	Root          lipgloss.Style
	Header        lipgloss.Style
	Logo          lipgloss.Style
	Summary       lipgloss.Style
	TabActive     lipgloss.Style
	TabInactive   lipgloss.Style
	Panel         lipgloss.Style
	PanelFocused  lipgloss.Style
	PanelTitle    lipgloss.Style
	PanelTitleBar lipgloss.Style
	PanelBody     lipgloss.Style
	Status        lipgloss.Style
	StatusGood    lipgloss.Style
	StatusWarn    lipgloss.Style
	StatusBad     lipgloss.Style
	StatusInfo    lipgloss.Style
	ChipPending   lipgloss.Style
	ChipRunning   lipgloss.Style
	ChipDone      lipgloss.Style
	ChipMerged    lipgloss.Style
	ChipFailed    lipgloss.Style
	ChipNeeds     lipgloss.Style
	ChipConflict  lipgloss.Style
	TaskSelected  lipgloss.Style
	TaskNormal    lipgloss.Style
	Muted         lipgloss.Style
	Help          lipgloss.Style
	Confirm       lipgloss.Style
	Footer        lipgloss.Style
	FooterKey     lipgloss.Style
	FooterMessage lipgloss.Style
}

func resolvePalette(themeName string) (palette, error) {
	if themeName == "auto" {
		if lipgloss.HasDarkBackground() {
			themeName = "dark"
		} else {
			themeName = "light"
		}
	}

	switch themeName {
	case "dark":
		return palette{
			Background:    lipgloss.Color("#111418"),
			PanelBG:       lipgloss.Color("#151B21"),
			PanelBGFocus:  lipgloss.Color("#1B242C"),
			Foreground:    lipgloss.Color("#E8ECF2"),
			Muted:         lipgloss.Color("#93A1B1"),
			Accent:        lipgloss.Color("#5EC2B7"),
			Success:       lipgloss.Color("#7BD88F"),
			Warning:       lipgloss.Color("#F2C94C"),
			Danger:        lipgloss.Color("#F28B82"),
			Info:          lipgloss.Color("#76B7F2"),
			Border:        lipgloss.Color("#3E4A59"),
			FocusedBorder: lipgloss.Color("#5EC2B7"),
			SelectedBG:    lipgloss.Color("#21313A"),
			SelectedFG:    lipgloss.Color("#DDF7F3"),
		}, nil
	case "light":
		return palette{
			Background:    lipgloss.Color("#F7FAFC"),
			PanelBG:       lipgloss.Color("#FFFFFF"),
			PanelBGFocus:  lipgloss.Color("#F1F5F9"),
			Foreground:    lipgloss.Color("#1B2530"),
			Muted:         lipgloss.Color("#5C6978"),
			Accent:        lipgloss.Color("#0F8A7B"),
			Success:       lipgloss.Color("#1E8E3E"),
			Warning:       lipgloss.Color("#A16207"),
			Danger:        lipgloss.Color("#B3261E"),
			Info:          lipgloss.Color("#1D4ED8"),
			Border:        lipgloss.Color("#B7C4D2"),
			FocusedBorder: lipgloss.Color("#0F8A7B"),
			SelectedBG:    lipgloss.Color("#DCEFEB"),
			SelectedFG:    lipgloss.Color("#0B3A34"),
		}, nil
	default:
		return palette{}, fmt.Errorf("invalid theme %q (expected auto|dark|light)", themeName)
	}
}

func newStyles(p palette) uiStyles {
	return uiStyles{
		Root: lipgloss.NewStyle().
			Foreground(p.Foreground).
			Background(p.Background),
		Header: lipgloss.NewStyle().
			Foreground(p.Foreground).
			Background(p.Background),
		Logo: lipgloss.NewStyle().
			Foreground(p.Accent).
			Bold(true),
		Summary: lipgloss.NewStyle().
			Foreground(p.Muted),
		TabActive: lipgloss.NewStyle().
			Foreground(p.Background).
			Background(p.Accent).
			Padding(0, 1).
			Bold(true),
		TabInactive: lipgloss.NewStyle().
			Foreground(p.Foreground).
			Background(p.Border).
			Padding(0, 1),
		Panel: lipgloss.NewStyle().
			Background(p.PanelBG),
		PanelFocused: lipgloss.NewStyle().
			Background(p.PanelBGFocus),
		PanelTitle: lipgloss.NewStyle().
			Foreground(p.Accent).
			Bold(true),
		PanelTitleBar: lipgloss.NewStyle().
			Foreground(p.Background).
			Background(p.Border).
			Padding(0, 1).
			Bold(true),
		PanelBody: lipgloss.NewStyle().
			Foreground(p.Foreground).
			Padding(0, 1),
		Status: lipgloss.NewStyle().
			Foreground(p.Foreground),
		StatusGood: lipgloss.NewStyle().
			Foreground(p.Success).
			Bold(true),
		StatusWarn: lipgloss.NewStyle().
			Foreground(p.Warning).
			Bold(true),
		StatusBad: lipgloss.NewStyle().
			Foreground(p.Danger).
			Bold(true),
		StatusInfo: lipgloss.NewStyle().
			Foreground(p.Info).
			Bold(true),
		ChipPending: lipgloss.NewStyle().
			Foreground(p.Background).
			Background(p.Muted).
			Padding(0, 1),
		ChipRunning: lipgloss.NewStyle().
			Foreground(p.Background).
			Background(p.Info).
			Padding(0, 1),
		ChipDone: lipgloss.NewStyle().
			Foreground(p.Background).
			Background(p.Accent).
			Padding(0, 1),
		ChipMerged: lipgloss.NewStyle().
			Foreground(p.Background).
			Background(p.Success).
			Padding(0, 1),
		ChipFailed: lipgloss.NewStyle().
			Foreground(p.Background).
			Background(p.Danger).
			Padding(0, 1),
		ChipNeeds: lipgloss.NewStyle().
			Foreground(p.Background).
			Background(p.Warning).
			Padding(0, 1),
		ChipConflict: lipgloss.NewStyle().
			Foreground(p.Background).
			Background(p.Warning).
			Padding(0, 1),
		TaskSelected: lipgloss.NewStyle().
			Background(p.SelectedBG).
			Foreground(p.SelectedFG).
			Bold(true),
		TaskNormal: lipgloss.NewStyle().
			Foreground(p.Foreground),
		Muted: lipgloss.NewStyle().
			Foreground(p.Muted),
		Help: lipgloss.NewStyle().
			Foreground(p.Muted),
		Confirm: lipgloss.NewStyle().
			Foreground(p.Warning).
			Bold(true),
		Footer: lipgloss.NewStyle().
			BorderTop(true).
			BorderStyle(lipgloss.NormalBorder()).
			BorderForeground(p.Border).
			Foreground(p.Foreground).
			Padding(0, 1),
		FooterKey: lipgloss.NewStyle().
			Foreground(p.Accent).
			Bold(true),
		FooterMessage: lipgloss.NewStyle().
			Foreground(p.Muted),
	}
}
