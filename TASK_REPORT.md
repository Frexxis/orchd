# Task Report

## Summary

- Added `orchestrator-runbook.md` to generated agent docs so projects receive the full orchestration runbook.
- Expanded `ORCHESTRATOR.md` to require runbook reading and project-context scanning before planning.
- Added a fallback runbook stub for installs missing the runbook file.

## Files Modified/Created

- lib/core.sh
- ORCHESTRATOR.md

## Tests Run

- Not run (not requested)

## Risks/Notes

- Existing projects should run `orchd refresh-docs` to pick up the runbook and updated orchestrator guidance.
