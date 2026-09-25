local config = require('opencode.config')

local M = {}

local function action_legend()
  ---@type {save: string[], cancel: string[]}
  local keys = { save = {}, cancel = {} }
  for key, entry in pairs(config.keymap.session_diff.comment) do
    if entry ~= false then
      if entry[1] == 'submit_comment' then
        keys.save[#keys.save + 1] = key
      elseif entry[1] == 'cancel_comment' then
        keys.cancel[#keys.cancel + 1] = key
      end
    end
  end
  local parts = {}
  for _, action in ipairs({ 'save', 'cancel' }) do
    if #keys[action] > 0 then
      table.sort(keys[action])
      parts[#parts + 1] = table.concat(keys[action], '/') .. ' ' .. action
    end
  end
  return ' ' .. table.concat(parts, ' · ') .. ' '
end

---@param opts {title: string, text?: string, on_submit: fun(text: string), on_cancel?: fun()}
function M.open(opts)
  local origin = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'opencode-review://' .. buf)
  vim.b[buf].completion = false
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.text or '', '\n', { plain = true }))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = math.min(72, vim.o.columns - 4),
    height = 6,
    style = 'minimal',
    border = 'rounded',
    title = opts.title,
    footer = action_legend(),
  })
  vim.bo[buf].buftype = 'acwrite'
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end, 25)
  end
  local function submit()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
    close()
    opts.on_submit(text)
  end
  local function cancel()
    close()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = submit })
  local actions = { submit_comment = submit, cancel_comment = cancel }
  for key, entry in pairs(config.keymap.session_diff.comment) do
    if entry ~= false then
      vim.keymap.set(entry.mode or 'n', key, actions[entry[1]], {
        buffer = buf,
        silent = true,
        desc = entry.desc,
        nowait = entry.nowait,
      })
    end
  end
  vim.cmd('startinsert')
end

return M
