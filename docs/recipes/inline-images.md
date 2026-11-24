# Inline images

[Documentation](../README.md) / [Recipes](README.md) / Inline images

Show image attachments in the output instead of only their names.

## When to use it

Images pasted with `paste_image` (`<leader>ov`, or `<M-v>` in the input) are
shown in the output as a file name. This recipe draws PNG attachments below
that name with Neovim's `vim.ui.img`, so you can see what you sent.

## Prerequisites

- Neovim 0.13 or newer with `vim.ui.img`. The API is experimental and may change.
- A terminal that supports the Kitty graphics protocol, such as Kitty, Ghostty,
  or WezTerm. Over tmux, `allow-passthrough` must be on.
- PNG images only. Other formats keep the default file line.
- Works on V1 and V2.

## Setup

Save the module as `~/.config/nvim/lua/my_recipes/inline_images.lua` and list
it in `recipes`
(see [Keep a recipe in its own file](README.md#keep-a-recipe-in-its-own-file)):

```lua
require('opencode').setup({
  recipes = { 'my_recipes.inline_images' },
})
```

The module registers an [attachment formatter](../extensions.md#attachment-formatters)
that reserves blank lines below an `image name` header, and places each image
over those lines after every render, scroll, and resize:

```lua
local M = {}

local ROWS = 12

---@type table<string, { bytes: string, id?: integer, at?: string }>
local images = {}

---@param attachment OpencodeAttachment
---@return string?
local function read_png(attachment)
  if attachment.path then
    return vim.fn.filereadable(attachment.path) == 1 and vim.fn.readblob(attachment.path) or nil
  end
  local data = attachment.uri:match('^data:image/png;base64,(.+)$')
  return data and vim.base64.decode(data)
end

---Draw each image on the blank lines below its header, or hide it.
local function update()
  local tab = vim.api.nvim_get_current_tabpage()
  for part_id, image in pairs(images) do
    local part = require('opencode').get_rendered_part(part_id)
    local win = part and part.win
    local top, bottom
    if win and vim.api.nvim_win_get_tabpage(win) == tab then
      top = vim.fn.screenpos(win, part.first + 1, 1)
      bottom = vim.fn.screenpos(win, part.first + ROWS, 1)
    end
    if top and top.row > 0 and bottom.row > 0 then
      local at = top.row .. ':' .. top.col
      if image.at ~= at then
        -- Height alone lets the terminal keep the aspect ratio.
        image.id = vim.ui.img.set(image.id or image.bytes, { row = top.row, col = top.col, height = ROWS })
        image.at = at
      end
    elseif image.id then
      vim.ui.img.del(image.id)
      image.id, image.at = nil, nil
    end
    if not part then
      images[part_id] = nil
    end
  end
end

function M.setup(opencode)
  if not vim.ui.img then
    vim.notify('inline images need vim.ui.img (Neovim 0.13+)', vim.log.levels.WARN)
    return
  end

  opencode.register_attachment_formatter('inline_images', {
    format = function(output, attachment)
      local part_id = attachment.part_id
      if not part_id or attachment.media_type ~= 'image/png' then
        return
      end
      if not images[part_id] then
        local bytes = read_png(attachment)
        if not bytes then
          return
        end
        images[part_id] = { bytes = bytes }
      end
      output:add_line('**image** `' .. attachment.name .. '`')
      for _ = 1, ROWS do
        output:add_line('')
      end
    end,
  })

  local group = vim.api.nvim_create_augroup('my_recipes_inline_images', { clear = true })
  local schedule_update = vim.schedule_wrap(update)
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'OpencodeOutputRendered', callback = schedule_update })
  vim.api.nvim_create_autocmd(
    { 'WinScrolled', 'WinResized', 'TabEnter', 'WinClosed', 'BufWinLeave' },
    { group = group, callback = schedule_update }
  )
end

return M
```

Each image is 12 rows tall; the terminal picks the width that keeps its aspect
ratio. Change `ROWS` to make images larger or smaller.

## Try it

1. Copy a PNG to the clipboard and open OpenCode.
2. Press `<M-v>` in the input, type a question, and send it.
3. The user message shows `**image** pasted_image_<time>.png` with the image
   below it. Scroll the output: the image moves with it and disappears once its
   lines leave the window.

## Caveats and undo

- Images are drawn on top of the screen, so they cover floating windows that
  open over the output.
- An image is hidden while any of its rows is off screen, or while the output
  is in another tab.
- A wide image can extend past the right edge of the output window.
- Pasted images live in a temporary directory. An attachment sent as a
  `file://` URI can point to a file that is gone in history from an earlier
  Neovim run; it then shows the default file line. Attachments sent as `data:`
  URIs, as on V2, are not affected.
- Each image is read once and kept in memory until its message leaves the
  output.
- A formatter error is logged once and the attachment falls back to the default
  line.

To undo, remove the module from `recipes`, or call
`require('opencode').unregister_attachment_formatter('inline_images')`.

## Related

- [Attachment formatters](../extensions.md#attachment-formatters)
- [Paste as an attachment](paste-as-attachment.md)
