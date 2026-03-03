package main

import (
	"fmt"
	"sort"
	"strings"
)

func renderDAG(state orchState) string {
	if len(state.Tasks) == 0 {
		return "No tasks found. Run: orchd plan \"<description>\""
	}

	taskMap := make(map[string]taskState, len(state.Tasks))
	children := make(map[string][]string, len(state.Tasks))
	indegree := make(map[string]int, len(state.Tasks))

	for _, t := range state.Tasks {
		taskMap[t.ID] = t
		if _, ok := indegree[t.ID]; !ok {
			indegree[t.ID] = 0
		}
	}

	for _, t := range state.Tasks {
		for _, dep := range t.DepsSlice {
			children[dep] = append(children[dep], t.ID)
			indegree[t.ID]++
		}
	}

	roots := make([]string, 0, len(taskMap))
	for id, deg := range indegree {
		if deg == 0 {
			roots = append(roots, id)
		}
	}
	sort.Strings(roots)
	for key := range children {
		sort.Strings(children[key])
	}

	var b strings.Builder
	b.WriteString("Dependency Graph\n\n")

	visited := make(map[string]bool, len(taskMap))
	for i, root := range roots {
		last := i == len(roots)-1
		visited[root] = true
		walkDAG(&b, taskMap, children, root, "", last, true, visited)
	}

	remaining := make([]string, 0)
	for id := range taskMap {
		if !visited[id] {
			remaining = append(remaining, id)
		}
	}
	if len(remaining) > 0 {
		sort.Strings(remaining)
		b.WriteString("\nShared or cyclic nodes:\n")
		for _, id := range remaining {
			t := taskMap[id]
			b.WriteString(fmt.Sprintf("  %s %s [%s]\n", statusASCII(t.Status), id, t.Status))
		}
	}

	b.WriteString("\nLegend: [x]=merged [>]=running [ ]=pending [!]=failed [?]=needs_input [c]=conflict [d]=done\n")
	return strings.TrimSpace(b.String())
}

func walkDAG(
	b *strings.Builder,
	taskMap map[string]taskState,
	children map[string][]string,
	id string,
	prefix string,
	isLast bool,
	isRoot bool,
	visited map[string]bool,
) {
	t, ok := taskMap[id]
	if !ok {
		return
	}

	linePrefix := ""
	if !isRoot {
		if isLast {
			linePrefix = prefix + "`-- "
		} else {
			linePrefix = prefix + "|-- "
		}
	}

	b.WriteString(fmt.Sprintf("%s%s %s [%s]\n", linePrefix, statusASCII(t.Status), t.ID, t.Status))

	nextPrefix := prefix
	if !isRoot {
		if isLast {
			nextPrefix += "    "
		} else {
			nextPrefix += "|   "
		}
	}

	kids := children[id]
	for i, child := range kids {
		last := i == len(kids)-1
		if visited[child] {
			sharedPrefix := nextPrefix
			if last {
				sharedPrefix += "`-- "
			} else {
				sharedPrefix += "|-- "
			}
			ct := taskMap[child]
			b.WriteString(fmt.Sprintf("%s%s %s [%s] (shared)\n", sharedPrefix, statusASCII(ct.Status), child, ct.Status))
			continue
		}
		visited[child] = true
		walkDAG(b, taskMap, children, child, nextPrefix, last, false, visited)
	}
}
