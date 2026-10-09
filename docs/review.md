# Reviewing changes

[Documentation](README.md) / Reviewing changes

Session diffs show what the agent changed, file by file. You can leave
comments on lines and send them back with your next prompt. This needs OpenCode
V2; on V1, see [snapshots](compatibility.md#v1-snapshots-and-restore-points).

## Open a session diff

After the agent edits files, press `<leader>od` or run `:Opencode diff open`.
A new Neovim tab opens with the changed files on the left and a before/after
view of the selected file.

![Changed-file tree and side-by-side revisions](https://github.com/user-attachments/assets/e1e0e95c-c32a-4a10-9829-88bd7100d688)

In the file list, `<CR>` opens a file or folds a directory. `<Tab>` and
`<S-Tab>` go to the next and previous file from either the list or the preview.
Press `p` to switch between side by side and a unified patch.

![Unified patch preview](https://github.com/user-attachments/assets/f014f4b5-f672-4878-a581-0856894a7cb6)

Both sides come from snapshots OpenCode recorded during the session. If you
have edited a file since, the diff does not show those edits.

## Choose a range of messages

By default the diff covers your last prompt. To see the changes from several
prompts:

1. Press `r` to list your prompts.
2. Press `f` on the first prompt and `t` on the last.
3. Press `<CR>` to show the changes across that range.

`K` previews a prompt, and `r`, `q`, or `<Esc>` go back to the file list
without changing the range. `g?` shows the keys in any review pane.

![Message-range picker with start and end markers](https://github.com/user-attachments/assets/6933e4b5-34d0-4004-9328-7030297fe058)

## Leave inline feedback

In the preview, press `c` on a line or a visual selection. Write the comment
and save with `<C-s>`, `:w`, or `<CR>` in normal mode. `q` or `<Esc>` cancels.

![Review comment editor](https://github.com/user-attachments/assets/889b16fd-5e24-4c23-a073-62eb5e1199f9)

![Saved review comment beside its changed line](https://github.com/user-attachments/assets/af202f79-8980-4f46-a967-638563555967)

Saved comments show as signs in the preview and are marked in the file list.
`]r` / `[r` jump between them; `c` on a comment edits it and `dc` deletes it.
You can comment on either side, including on a deleted file.

Press `q` in the list or preview to close the review. If you left comments,
the prompt opens with them attached. Write the follow-up, for example "Fix
these, keep the public API the same", and send it.

The context bar shows how many comments are attached. Use `#` to detach all of
them or remove one. To never attach them automatically, set
`context.review_comments.enabled = false`.

Comment line numbers refer to the snapshot you reviewed. If the file has
changed since, including unsaved edits, the plugin also sends the current code
around each comment so the agent can find the right place.

The [session review recipe](recipes/review-session-diff.md) has the same steps
as a checklist.

## Jump to the working file

`gf` opens the real file in another tab and leaves the review open. From the
preview, the cursor lands on the matching line of the new version; on a deleted
line, it goes to the next line that still exists. If the file has changed since
the snapshot, the line may be off.

From the conversation, press `D` on an edit or patch tool block to open the
diff for that prompt with the file selected. Press `D` on the same block again
to close it.

## Customize review keys

Review keys are set under `keymap.session_diff`, one table per pane. Set the
old key to `false` when you move an action:

```lua
require('opencode').setup({
  keymap = {
    session_diff = {
      list = { ['p'] = false, ['v'] = { 'toggle_view' } },
      preview = {
        ['p'] = false,
        ['v'] = { 'toggle_view' },
        [']f'] = { 'next_file', desc = 'Next file' },
        ['[f'] = { 'prev_file', desc = 'Previous file' },
      },
    },
  },
})
```

An action can be a review action (the names in the
[defaults](configuration.md#full-default-configuration)), any `:Opencode`
command name, or a Lua function. Entries take `mode`, `desc`, and `nowait` like
[other keymaps](configuration.md#keymaps).

For your own `FileType` autocmds, the panes use these filetypes:
`opencode_diff_list`, `opencode_diff_messages`, `opencode_diff_comment`, and
`opencode_diff_help`. Previews combine the file's language with a suffix, such
as `lua.opencode_diff_preview`, so match `*.opencode_diff_preview` or
`*.opencode_diff_message_preview`. The plugin's mappings are already set when
your autocmd runs.
