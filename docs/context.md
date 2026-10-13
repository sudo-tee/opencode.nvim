# Context

[Documentation](README.md) / Context

Along with your prompt, the plugin sends editor context: the current file,
your selection, diagnostics, and so on. The context bar above the input shows
what will be sent. Type `#` in insert mode to toggle or remove items.

## What is included by default?

| Context | Default | Notes |
| --- | --- | --- |
| Current file | On | The last code buffer you were in before the panel |
| Visual selection | On | Added with `<leader>oy`, with file and line numbers |
| Mentioned files | On | Files added with `@` or `~` |
| Diagnostics | Warnings and errors | Only those at the cursor or selection |
| Review comments | On | Comments saved in a [session diff](review.md) |
| Cursor data | Off | Cursor line and 5 lines either side |
| Entire buffer | Off | Contents of the current buffer |
| Git diff | Off | Staged changes (`git diff --cached`) |

Each row has a setting under `context`; see
[Configuration](configuration.md#context). `context.enabled = false` turns off
all automatic context.

## Add a selection

Select code in visual mode and press `<leader>oy`. The selection is added to
the context and the input opens.

`<leader>oY` pastes the selection into the prompt itself, as a code block under
its file path, and leaves you in normal mode. Use it when you want to refer to
the code in the middle of your sentence.

To add several selections without jumping to the input each time:

```lua
require('opencode').setup({
  keymap = {
    editor = {
      ['<leader>oy'] = {
        'add_visual_selection', { open_input = false }, mode = { 'v' },
      },
    },
  },
})
```

If the selection is in the current file, the plugin sends just the selection
and not the whole file. The agent can still read the file if it needs to.
Mentioning the file with `@` sends it anyway.

## Mention files and agents

In insert mode in the input, `@` opens completion for files and agents, and `~`
opens your file picker.

![Mention completion menu showing file and agent suggestions after typing @](https://github.com/user-attachments/assets/5a98226e-c784-4ebf-a563-90dde5cc4e2a)

`#` lists everything in the context. From there you can remove a file or
selection, turn a whole group such as diagnostics on or off, or drop a single
review comment.

## What gets re-sent

The plugin avoids sending the same thing twice in a session:

- The current file is sent once, then again only after it changes on disk. In
  the context bar it is dimmed while it is up to date, and highlighted when it
  will be sent with the next prompt.
- Diagnostics, cursor data, buffer, and git diff are re-sent only when their
  contents change.
- Mentioned files and selections are sent with every prompt they are in.

![Context completion menu with current file, diagnostics, and a selection](https://github.com/user-attachments/assets/1f36af7e-3ddd-4419-999e-0bff4941b3a0)

![Review comments context group and individual comment in the completion menu](https://github.com/user-attachments/assets/9d129d2e-0aeb-4304-8919-b7d564117469)

## Attach an image

Press `<leader>ov`, or `<M-v>` in insert mode in the input, to attach the image
on your clipboard. The model you use has to accept images.

## Sensitive files

Check the context bar before sending from a buffer that holds secrets or code
you may not share with your provider.

These settings only control what the plugin attaches. The agent can still read
files through its tools; limit that with OpenCode's permissions. To block
prompts entirely in some projects, use a
[prompt guard](extensions.md#prompt-guard).

Next: [Reviewing changes](review.md) or [Configuration](configuration.md).
