# Paste as an attachment

[Documentation](../README.md) / [Recipes](README.md) / Paste as an attachment

Send pasted text as an attachment instead of putting it in the prompt.

## Setup

Register a `pasted_text` context provider after `setup()`. Each paste is kept in
a list and referenced in the prompt as `@pasted_text_<time>.txt`; OpenCode sends
the referenced pastes with the next prompt. Press `<C-g>p` in the OpenCode input
to attach the `+` clipboard register:

```lua
local opencode = require('opencode')

local pastes = {}
local next_id = 0

local function attach(text)
  if text == '' then
    return
  end
  next_id = next_id + 1
  local paste = { id = tostring(next_id), name = os.date('pasted_text_%Y%m%d_%H%M%S.txt'), text = text }
  table.insert(pastes, paste)
  opencode.insert_context_reference(paste)
end

opencode.setup({
  keymap = {
    input_window = {
      ['<C-g>p'] = {
        function()
          attach(vim.fn.getreg('+'))
        end,
        mode = { 'n', 'i' },
        desc = 'Attach clipboard',
      },
    },
  },
})

opencode.register_context_provider({
  name = 'pasted_text',
  label = 'Pasted Text',
  icon = '󰆒 ',
  enabled = true,
  reference = true,
  collect = function()
    return pastes
  end,
  remove = function(item)
    pastes = vim.tbl_filter(function(paste)
      return paste.id ~= item.id
    end, pastes)
  end,
  on_sent = function()
    pastes = {}
  end,
  -- Show the pasted text in the output instead of the file name.
  render = function(attachment)
    if attachment.name:match('^pasted_text_%d+_%d+%.txt$') then
      -- Fence longer than any backtick run so the paste cannot close it.
      local fence = '```'
      while attachment.text:find(fence, 1, true) do
        fence = fence .. '`'
      end
      return { fence .. 'text', attachment.text, fence }
    end
  end,
})
```

## Optional: attach on every paste

To attach terminal and GUI pastes too, wrap `vim.paste`. Pastes into other
windows and the command line are passed through unchanged.

```lua
local default_paste = vim.paste
local chunks = {}

vim.paste = function(lines, phase)
  if not opencode.is_input_window() or vim.fn.mode() == 'c' then
    return default_paste(lines, phase)
  end
  -- Large pastes arrive in several chunks (phase 1, 2, ..., 3).
  if phase == -1 or phase == 1 then
    chunks = {}
  end
  table.insert(chunks, table.concat(lines, '\n'))
  if phase == -1 or phase == 3 then
    attach(table.concat(chunks))
  end
  return true
end
```

`<C-r>+` still inserts the clipboard as editable text.

## Usage

After attaching, the prompt contains `@pasted_text_<time>.txt` and the context
bar shows `󰆒 Pasted Text (1)`. Delete the token to detach the paste. Open the
context picker (`#`) to preview the exact text, select a paste to remove it, or
toggle `Pasted Text` off. Pastes are sent with your next prompt and then
cleared, including detached ones.
