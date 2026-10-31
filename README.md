# claude-dotfiles

My Claude Code setup. One folder, linked into place, so a clone on another machine runs with the same rules and the same status line.

![The status line in 4 states, and the subagent panel](statusline.png)

## What's in it

```text
claude-dotfiles/
├── README.md
├── install.sh              links the rules and the status line scripts into place
├── CLAUDE.md               the rules, read in full every turn
├── statusline.sh           the status line
├── subagent-statusline.sh  the subagent panel rows
├── statusline-lib.sh       the helpers both scripts share
├── width-table.sh          the wide and zero-width code point ranges, generated
├── gen-width-table.py      writes width-table.sh from Python's Unicode data
└── statusline.png          the picture above
```

CLAUDE.md is the part worth reading. It tells the agent how to talk and how to act, and every rule in it holds on every model and every turn. The agent reads all of it every turn, so each line is there because it changes what the agent does.

The scripts are run by Claude Code, not read by the model. Each one finds the folder it really lives in and sources the shared helpers from there, so the links can sit anywhere.

## Install

Clone it, then from inside the folder:

```sh
./install.sh
```

Links go under `$CLAUDE_CONFIG_DIR`, or `~/.claude` when that's unset. Run it again any time. A target that is already a link is pointed here. A regular file that is an identical copy becomes a link. Anything else is left alone and reported, so nothing gets overwritten unseen. `./install.sh --dry-run` reports all of that and changes nothing.

At the end it prints the `settings.json` entries for both status lines, with the paths it linked. Paste them into `settings.json` in the same directory.

## Memory

Not kept here. The agent writes it under the config directory's `projects/*/memory/` only when asked, and it stays on the machine it was written on.
