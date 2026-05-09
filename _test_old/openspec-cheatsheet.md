# OpenSpec Quick Reference

> Root: `.vscode/openspec/`
> Wrappers: `opsx.bat` (CMD) / `opsx.ps1` (PowerShell) -- project root, not versioned

## Common commands

    .\opsx list                         # list all changes
    .\opsx new change <name>            # create new change
    .\opsx status --change <name>       # check task completion
    .\opsx archive --change <name>      # archive completed change

## VS Code prompt flow

    #start-plan   -> OpenSpec pre-read + KB read + plan output
    /opsx:propose -> create change artifacts  (after user confirms plan)
    #start-task   -> KB read + implement tasks
    #end-task     -> KB update + /opsx:archive + rebuild + finish-check

## Dual-track responsibility

| OpenSpec (.vscode/openspec/)     | Knowledge Base (.vscode/knowledge/)      |
|----------------------------------|------------------------------------------|
| WHAT: behaviour contracts, specs | WHY/HOW-NOT-TO: root causes, traps       |
| New features / spec changes      | Bug fixes, trap records                  |
| /opsx:propose, /opsx:explore     | kb.mjs new-trap                          |
| /opsx:archive -> rebuild         | rebuild                                  |

## Key files

- `.vscode/openspec/config.yaml`     -- project context and rules (fill in)
- `.vscode/openspec/specs/INDEX.md`  -- requirement counts per module
- `.vscode/openspec/changes/<name>/` -- change artifacts (working)
- `.vscode/openspec/changes/archive/<name>/` -- archived changes