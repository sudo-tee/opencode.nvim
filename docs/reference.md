# Commands and Lua API

[Documentation](README.md) / Commands and Lua API

`:Opencode` toggles the panel. Subcommands have command-line completion; use
`:Opencode help` for in-editor help. The workflow tables explain common actions; the
[complete command list](#complete-command-list) includes every registered alias.

Lua examples use:

```lua
local api = require('opencode.api')
```

Commands, keymaps, slash commands, and API calls all go through the same
dispatcher. Some actions return a Promise, so a session or response may not
exist yet when the call returns. See
[`api.lua`](../lua/opencode/api.lua) for all exports and
[`types.lua`](../lua/opencode/types.lua) for signatures.

## Panel and navigation

| Command | Lua call | Default key |
| --- | --- | --- |
| `:Opencode` | `api.toggle()` | `<leader>og` |
| `:Opencode open input` | `api.open_input()` | `<leader>oi` |
| `:Opencode open output` | `api.open_output()` | `<leader>oo` |
| `:Opencode toggle_focus` | `api.toggle_focus()` | `<leader>ot` |
| `:Opencode close` | `api.close()` | `<leader>oq` |
| `:Opencode swap` | `api.swap_position()` | `<leader>ox` |
| `:Opencode toggle_zoom` | `api.toggle_zoom()` | `<leader>oz` |
| `:Opencode cancel` | `api.cancel()` | `<C-c>` in panel |
| `:Opencode references` | `api.references()` | `gr` in panel |
| `:Opencode jump_to_file` | `api.jump_to_file()` | `gf` in output |
| `:Opencode history` | `api.select_history()` | `<leader>oh` |

`api.hide()` follows `ui.persist_state`, like `close()`.
`api.navigate_to_location(path, line, col)` opens a specific file location.
`api.next_message()`, `prev_message()`, `next_user_message()`, and
`prev_user_message()` navigate output; `prev_history()` / `next_history()`
browse saved prompts.

## Sessions and tabs

| Command | Lua call | Default key |
| --- | --- | --- |
| `:Opencode session new` | `api.open_input_new_session()` | `<leader>oI` |
| `:Opencode session new <name>` | `api.open_input_new_session_with_title(name)` | — |
| `:Opencode session select` | `api.select_session()` | `<leader>os` |
| `:Opencode session rename <name>` | `api.rename_session(nil, name)` | `<leader>oR` opens rename input |
| `:Opencode tab new [name]` | `api.open_session_tab(name)` | `<leader>oN` |
| `:Opencode tab select [index]` | `api.select_session_tab(index)` | `<leader>o?` / `<leader>o1`…`o9` |
| `:Opencode tab previous` / `next` | `api.prev_session_tab()` / `next_session_tab()` | `<leader>o<` / `<leader>o>` |
| `:Opencode tab close` | `api.close_session_tab()` | `<leader>oQ` |
| `:Opencode timeline` | `api.timeline()` | `<leader>oT` |
| `:Opencode session navigate child picker` | `api.navigate_session_tree('child', 'picker')` | `<leader>oS` |
| `:Opencode session navigate parent` | `api.navigate_session_tree('parent')` | `<leader>oP` |
| `:Opencode session navigate sibling picker` | `api.navigate_session_tree('sibling', 'picker')` | `<leader>oB` |
| `:Opencode session share` / `unshare` | `api.share()` / `unshare()` | — |
| `:Opencode session compact` | `api.compact_session()` | — |
| `:Opencode session agents_init` | `api.initialize()` | — |
| `:Opencode undo` / `redo` | `api.undo()` / `redo()` | — |

Sharing publishes the conversation at a public link. Undo can change files on
disk. Panel tabs and the session tree are covered in
[Usage](usage.md#sessions-and-panel-tabs).

### Directory-bound sessions

`api.open_session(opts)` opens a session in a logical panel tab without changing
Neovim's cwd. There is no equivalent built-in Ex or slash command.

| Option | Meaning |
| --- | --- |
| `directory` | Required existing local directory; relative paths resolve against Neovim's cwd |
| `new` | Create a fresh session instead of resuming; incompatible with `session_id` |
| `session_id` | Open a specific session belonging to the supplied directory |
| `title` | Title for a newly created session |

Without `new` or `session_id`, it resumes the most recent root session in that
exact directory, or creates one if absent. Already-open sessions reuse their
panel tab. The Promise resolves to the session and rejects on invalid options,
server startup, lookup, creation, or panel failure. Normal path mapping applies.

Completion and new sessions use the bound directory, including after tab
switches. Explicit editor directory changes follow
[`lock_session_to_directory`](configuration.md#directory-changes).
See [Worktree sessions](recipes/worktree.md) for a complete example.

## Models, agents, and permissions

| Command | Lua call | Default key |
| --- | --- | --- |
| `:Opencode models` | `api.configure_provider()` | `<leader>op` |
| `:Opencode variant` | `api.configure_variant()` | `<leader>oV` |
| — | `api.cycle_variant()` | `<M-r>` in panel |
| `:Opencode agent build` / `plan` | `api.agent_build()` / `agent_plan()` | — |
| `:Opencode agent select` | `api.select_agent()` | `<M-m>` cycles in input |
| `:Opencode permission accept` | `api.permission_accept()` | Dialog choices |
| `:Opencode permission accept_all` | `api.permission_accept_all()` | Dialog choices |
| `:Opencode permission deny` | `api.permission_deny()` | Dialog choices |
| `:Opencode mcp` | `api.mcp()` | — |

## Prompts and context

```lua
api.run('Explain the edge cases in this function', {
  agent = 'plan',
  context = { current_file = { enabled = false } },
})

api.run_new_session('Suggest tests for this module', {
  model = 'provider/model-id',
})
```

Command equivalents:

```vim
:Opencode run agent=plan Explain this function
:Opencode run_new context=current_file.enabled=false Suggest tests for this module
```

Options go before the prompt: `agent=`, `model=` (`provider/model-id`),
`variant=`, and `context=`. Separate multiple context overrides with commas,
for example `context=selection.enabled=false,diagnostics.warning=false`.

| Action | Command / Lua call |
| --- | --- |
| Submit input | `:Opencode submit_input_prompt` / `api.submit_input_prompt()` |
| Add visual selection | `:Opencode add_visual_selection` / `api.add_visual_selection(opts, range)` |
| Insert selection inline | `:Opencode add_visual_selection_inline` / `api.add_visual_selection_inline(opts, range)` |
| Paste clipboard image | `:Opencode paste_image` / `api.paste_image()` |
| Quick chat | `:Opencode quick_chat [instructions]` / `api.quick_chat()` |
| Toggle tool output | `:Opencode toggle_tool_output` / `api.toggle_tool_output()` |
| Toggle reasoning | `:Opencode toggle_reasoning_output` / `api.toggle_reasoning_output()` |
| Toggle message limit | `:Opencode toggle_max_messages` / `api.toggle_max_messages()` |
| Clear selection context | `:Opencode clear_selections` |
| Clear mentioned files | `:Opencode clear_files` |

Visual-selection commands accept an Ex range. Lua callers can supply
`range = { start = first_line, stop = last_line }` as the second argument
(1-based lines). `opts.open_input` defaults to `true`. Configured visual
keymaps capture the range for you. See [Context](context.md#add-a-selection).

## Debugging

| Command | Lua call | Purpose |
| --- | --- | --- |
| `:Opencode debug events [filename]` | `api.debug_events(filename?)` | Export captured streamed events (`data.json` by default) |
| `:Opencode debug log` | `api.debug_log()` | Open the plugin log file in the current window |

## Change review

| Command | Lua call | Default key |
| --- | --- | --- |
| `:Opencode diff open` | `api.diff_open()` | `<leader>od` |
| `:Opencode diff next` / `prev` | `api.diff_next()` / `diff_prev()` | `<leader>o]` / `<leader>o[` |
| `:Opencode diff close` | `api.diff_close()` | `<leader>oc` |

Keys inside the V2 review view are listed in [Reviewing changes](review.md).
`:Opencode review [arguments]` and `api.review(args)` are different: they run
OpenCode's `review` command in a new session.

## Complete command list

Every registered `:Opencode` command, including the aliases keymaps use.

| Command | Purpose | Subcommands |
| --- | --- | --- |
| `:Opencode add_visual_selection` | Add current visual selection to context | — |
| `:Opencode add_visual_selection_inline` | Insert visual selection as inline code block in the input buffer | — |
| `:Opencode agent` | Manage agents (plan/build/select) | `plan`, `build`, `select` |
| `:Opencode breakpoint` | Take a V1 snapshot for later diff and revert actions | — |
| `:Opencode cancel` | Cancel running request | — |
| `:Opencode clear_files` | Clear only mentioned files from context | — |
| `:Opencode clear_selections` | Clear only selections from context | — |
| `:Opencode close` | Close opencode windows | — |
| `:Opencode close_session_tab` | Close the current Opencode panel tab | — |
| `:Opencode command` | Run user-defined command | — |
| `:Opencode commands_list` | Show user-defined commands | — |
| `:Opencode configure_provider` | Configure provider | — |
| `:Opencode configure_variant` | Configure model variant | — |
| `:Opencode context_items` | Open context items picker in input window | — |
| `:Opencode copy_server_url` | Copy server URL to clipboard | — |
| `:Opencode cycle_variant` | Cycle model variant | — |
| `:Opencode debug` | Export captured events or open plugin log | `events [filename]`, `log` |
| `:Opencode debug_message` | Open raw message debug view | — |
| `:Opencode debug_output` | Open raw output debug view | — |
| `:Opencode debug_session` | Open raw session debug view | — |
| `:Opencode diff` | View file diffs (open/next/prev/close) | `open`, `next`, `prev`, `close` |
| `:Opencode diff_close` | Close diff view | — |
| `:Opencode diff_next` | Next diff | — |
| `:Opencode diff_open` | Open diff view | — |
| `:Opencode diff_prev` | Previous diff | — |
| `:Opencode diff_restore_snapshot_all` | Restore all files from snapshot (optional snapshot_id) | — |
| `:Opencode diff_restore_snapshot_file` | Restore file from snapshot (optional snapshot_id) | — |
| `:Opencode diff_revert_all` | Revert all tracked changes (optional snapshot_id) | — |
| `:Opencode diff_revert_all_last_prompt` | Revert all (last prompt) | — |
| `:Opencode diff_revert_this` | Revert current change (optional snapshot_id) | — |
| `:Opencode diff_revert_this_last_prompt` | Revert this (last prompt) | — |
| `:Opencode diff_toggle_file` | Toggle diff for tool file | — |
| `:Opencode first_message` | Load history and go to the first message | — |
| `:Opencode focus_input` | Focus input window | — |
| `:Opencode fork_session` | Fork the session from a user message | — |
| `:Opencode help` | Show command help | — |
| `:Opencode hide` | Hide opencode windows (preserve buffers for fast restore) | — |
| `:Opencode history` | Select from prompt history | — |
| `:Opencode jump_to_file` | Jump to file at cursor in output window | — |
| `:Opencode jump_to_target_at_cursor` | Jump to target at cursor in output window | — |
| `:Opencode mcp` | Show MCP server configuration | — |
| `:Opencode mention` | Open mention picker in input window | — |
| `:Opencode mention_file` | Mention file in current input context | — |
| `:Opencode models` | Switch provider/model | — |
| `:Opencode navigate_session_tree` | Navigate session tree (parent/child/sibling/forward/backward) or switch to a session by ID | — |
| `:Opencode next_message` | Navigate to next message in output window | — |
| `:Opencode next_prompt_history` | Navigate to next prompt history item | — |
| `:Opencode next_session_tab` | Switch to the next Opencode panel tab | — |
| `:Opencode next_user_message` | Navigate to next user message in output window | — |
| `:Opencode open` | Open opencode window (input/output) | `input`, `output` |
| `:Opencode open_input` | Open input window | — |
| `:Opencode open_input_new_session` | Open input (new session) | — |
| `:Opencode open_output` | Open output window | — |
| `:Opencode open_session_tab` | Open a new session in an Opencode panel tab | — |
| `:Opencode paste_image` | Paste image from clipboard and add to context | — |
| `:Opencode permission` | Respond to permissions (accept/accept_all/deny) | `accept`, `accept_all`, `deny` |
| `:Opencode prev_message` | Navigate to previous message in output window | — |
| `:Opencode prev_prompt_history` | Navigate to previous prompt history item | — |
| `:Opencode prev_session_tab` | Switch to the previous Opencode panel tab | — |
| `:Opencode prev_user_message` | Navigate to previous user message in output window | — |
| `:Opencode quick_chat` | Quick chat about the cursor line (±10 lines) or visual selection | — |
| `:Opencode redo` | Redo last action | — |
| `:Opencode references` | Browse code references from conversation | — |
| `:Opencode rename_session` | Rename session | — |
| `:Opencode restore` | Restore from snapshot (file/all) | `file`, `all` |
| `:Opencode revert` | Revert changes (all/this, prompt/session) | `all`, `this`; targets: `prompt`, `session`, snapshot ID |
| `:Opencode review` | Review changes (commit/branch/pr), defaults to uncommitted changes | — |
| `:Opencode run` | Run prompt in current session | — |
| `:Opencode run_new` | Run prompt in new session | — |
| `:Opencode select_history` | Select from history | — |
| `:Opencode select_session` | Select session | — |
| `:Opencode select_session_tab` | Select an Opencode panel tab | — |
| `:Opencode select_session_tab_target` | Select the tab at the cursor or mouse position | — |
| `:Opencode session` | Manage sessions and Opencode panel tabs | `new`, `tab`, `tabs`, `next_tab`, `prev_tab`, `close_tab`, `select`, `navigate`, `compact`, `share`, `unshare`, `agents_init`, `rename`, `toggle_lock` |
| `:Opencode skill` | Activate a skill or run it with user instructions | — |
| `:Opencode skills` | Browse and select available skills | — |
| `:Opencode slash_commands` | Open slash commands picker in input window | — |
| `:Opencode submit_input_prompt` | Submit current input prompt | — |
| `:Opencode swap` | Swap pane position left/right | — |
| `:Opencode swap_position` | Swap window position | — |
| `:Opencode switch_mode` | Cycle agent mode | — |
| `:Opencode tab` | Manage Opencode panel tabs | `next`, `new`, `previous`, `select`, `close` |
| `:Opencode timeline` | Open timeline picker to navigate/undo/redo/fork to message | — |
| `:Opencode toggle` | Toggle opencode windows | — |
| `:Opencode toggle_focus` | Toggle focus between opencode and code | — |
| `:Opencode toggle_input` | Toggle input window visibility | — |
| `:Opencode toggle_max_messages` | Toggle maximum number of rendered messages | — |
| `:Opencode toggle_pane` | Toggle between input/output panes | — |
| `:Opencode toggle_reasoning_output` | Toggle reasoning output visibility in the output window | — |
| `:Opencode toggle_session_lock` | Toggle session lock (preserve active session across cwd changes) | — |
| `:Opencode toggle_tool_output` | Toggle tool output visibility in the output window | — |
| `:Opencode toggle_zoom` | Toggle window zoom | — |
| `:Opencode undo` | Undo last action | — |
| `:Opencode variant` | Switch model variant | — |

## Slash commands and user commands

Type `/` in the input window (insert mode) to browse commands. Built-ins:

| Slash command | Equivalent command | Purpose |
| --- | --- | --- |
| `/agent` | `:Opencode agent select` | Manage agents (plan/build/select) |
| `/agents_init` | `:Opencode session agents_init` | New session that runs `init` to create or update AGENTS.md |
| `/child-sessions` | `:Opencode session navigate child picker` | Pick a child session |
| `/clear_files` | `:Opencode clear_files` | Clear only mentioned files from context |
| `/clear_selections` | `:Opencode clear_selections` | Clear only selections from context |
| `/command-list` | `:Opencode commands_list` | Show user-defined commands |
| `/compact` | `:Opencode session compact` | Summarize the session |
| `/help` | `:Opencode help` | Show command help |
| `/history` | `:Opencode history` | Select from prompt history |
| `/mcp` | `:Opencode mcp` | Show MCP server configuration |
| `/models` | `:Opencode models` | Switch provider/model |
| `/new` | `:Opencode session new` | Open input in a new session |
| `/reasoning` | `:Opencode toggle_reasoning_output` | Toggle reasoning output visibility in the output window |
| `/redo` | `:Opencode redo` | Redo last action |
| `/references` | `:Opencode references` | Browse code references from conversation |
| `/rename` | `:Opencode session rename` | Rename the current session |
| `/review` | `:Opencode review` | Review changes (commit/branch/pr), defaults to uncommitted changes |
| `/sessions` | `:Opencode session select` | Pick a session |
| `/share` | `:Opencode session share` | Share the session and copy the link |
| `/skills` | `:Opencode skills` | Browse and select available skills |
| `/thinking` | `:Opencode toggle_reasoning_output` | Toggle reasoning output visibility in the output window |
| `/timeline` | `:Opencode timeline` | Open timeline picker to navigate/undo/redo/fork to message |
| `/undo` | `:Opencode undo` | Undo last action |
| `/unshare` | `:Opencode session unshare` | Disable the share link |
| `/variant` | `:Opencode variant` | Switch model variant |

User commands and skills from your OpenCode configuration also show up in the
menu.

Run a user command with `:Opencode command <name> [arguments]` or
`api.run_user_command(name, args)`. Commands are defined in OpenCode's
configuration, not in the plugin. V1 definitions can
live in `.opencode/command/` or the global `command/` directory. For V2, follow
the [OpenCode configuration guide](https://opencode.ai/v2/docs/config).

## Skills

`:Opencode skills` or `/skills` opens a picker with names, descriptions, and
Markdown previews. Selecting one inserts `/skill-name` into input.

- On V2, submitting `/skill-name` activates the native server-managed skill.
- `/skill-name review current changes` sends instructions with a native skill
  attachment instead.
- Older servers without skill support return an error; update OpenCode.
- V1 sends the skill's content as an ordinary prompt.

The same behavior is available through:

```vim
:Opencode skill <name> [instructions]
```

```lua
api.run_skill(name, instructions)
```

V2 API callers can pass `skills = { { id = skill_id } }` in run options.
Optional `mention = { start_byte = ..., end_byte = ... }` ranges are zero-based
UTF-8 byte offsets into the prompt, with an exclusive end.

## Legacy snapshot actions (V1)

These overwrite files. See [Compatibility](compatibility.md#v1-snapshots-and-restore-points)
before using them. V2 uses the [review view](review.md) instead.

| Command | Lua call |
| --- | --- |
| `:Opencode revert all prompt` | `api.diff_revert_all_last_prompt()` |
| `:Opencode revert this prompt` | `api.diff_revert_this_last_prompt()` |
| `:Opencode revert all session` | `api.diff_revert_all()` |
| `:Opencode revert this session` | `api.diff_revert_this()` |
| `:Opencode revert all <snapshot_id>` | `api.diff_revert_all(snapshot_id)` |
| `:Opencode revert this <snapshot_id>` | `api.diff_revert_this(snapshot_id)` |
| `:Opencode restore file <restore_point_id>` | `api.diff_restore_snapshot_file(restore_point_id)` |
| `:Opencode restore all <restore_point_id>` | `api.diff_restore_snapshot_all(restore_point_id)` |
