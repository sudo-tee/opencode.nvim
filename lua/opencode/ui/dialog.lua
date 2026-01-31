---@class DialogConfig
---@field buffer integer Buffer ID where keymaps should be set
---@field on_select function(index: integer) Called when an option is selected
---@field on_dismiss? function() Called when dialog is dismissed
---@field on_navigate? function() Called when selection changes
---@field get_option_count function(): integer Returns the total number of options
---@field check_focused? function(): boolean Returns whether dialog should be active
---@field keymaps? DialogKeymaps Custom keymap configuration
---@field namespace_prefix? string Prefix for vim.on_key namespace (default: 'opencode_dialog')
---@field hide_input? boolean Whether to hide the input window when dialog is active (default: true)

---@class DialogKeymaps
---@field up? string[] Keys for navigating up (default: {'k', '<Up>'})
---@field down? string[] Keys for navigating down (default: {'j', '<Down>'})
---@field select? string Key for selecting current option (default: '<CR>')
---@field dismiss? string Key for dismissing dialog (default: '<Esc>')
---@field number_shortcuts? boolean Enable 1-9 number shortcuts (default: true)

---@class Dialog
---@field private _config DialogConfig
---@field private _keymaps string[] List of key bindings for cleanup
---@field private _key_capture_ns integer? Namespace for vim.on_key
---@field private _selected_index integer Currently selected option index
---@field private _active boolean Whether dialog is currently active
local Dialog = {}
Dialog.__index = Dialog

---Create a new dialog instance
---@param config DialogConfig Dialog configuration
---@return Dialog
function Dialog.new(config)
  local self = setmetatable({}, Dialog)

  -- Set up default keymaps if not provided
  local default_keymaps = {
    up = { 'k', '<Up>' },
    down = { 'j', '<Down>' },
    select = '<CR>',
    dismiss = '<Esc>',
    number_shortcuts = true,
  }

  self._config = vim.tbl_deep_extend('force', {
    keymaps = default_keymaps,
    namespace_prefix = 'opencode_dialog',
    check_focused = function()
      return true
    end,
    hide_input = true,
  } --[[@as DialogConfig]], config)

  self._keymaps = {}
  self._key_capture_ns = nil
  self._selected_index = 1
  self._active = false

  return self
end

---Get the currently selected option index
---@return integer
function Dialog:get_selection()
  return self._selected_index
end

---Set the selected option index
---@param index integer Option index to select
function Dialog:set_selection(index)
  local option_count = self._config.get_option_count()
  if index >= 1 and index <= option_count then
    self._selected_index = index
  end
end

---Navigate selection by delta (positive for down, negative for up)
---@param delta integer Amount to move selection
function Dialog:navigate(delta)
  if not self._active or not self._config.check_focused() then
    return
  end

  local option_count = self._config.get_option_count()
  if option_count == 0 then
    return
  end

  self._selected_index = self._selected_index + delta

  -- Wrap around selection
  if self._selected_index < 1 then
    self._selected_index = option_count
  elseif self._selected_index > option_count then
    self._selected_index = 1
  end

  if self._config.on_navigate then
    self._config.on_navigate()
  end
end

---Select the current option
function Dialog:select()
  if not self._active or not self._config.check_focused() then
    return
  end

  local option_count = self._config.get_option_count()
  if option_count == 0 then
    return
  end

  self._config.on_select(self._selected_index)
end

---Dismiss the dialog
function Dialog:dismiss()
  if not self._active or not self._config.check_focused() then
    return
  end

  if self._config.on_dismiss then
    self._config.on_dismiss()
  end
end

---Set up keymaps and activate the dialog
function Dialog:setup()
  if self._active then
    self:teardown()
  end

  self._active = true

  -- Hide input window if configured
  if self._config.hide_input then
    local input_window = require('opencode.ui.input_window')
    input_window._hide()
  end

  self:_setup_keymaps()
end

---Clean up keymaps and deactivate the dialog
function Dialog:teardown()
  self._active = false
  self:_clear_keymaps()

  -- Show input window if it was hidden
  if self._config.hide_input then
    local input_window = require('opencode.ui.input_window')
    input_window._show()
  end
end

---Check if dialog is currently active
---@return boolean
function Dialog:is_active()
  return self._active
end

---Format the legend/instructions for this dialog
---@param output Output Output object to write to
---@param options? table Options for legend formatting
function Dialog:format_legend(output, options)
  options = options or {}
  local ui = require('opencode.ui.ui')

  if not self._active then
    return
  end

  local option_count = self._config.get_option_count()
  if option_count == 0 then
    return
  end

  if ui.is_opencode_focused() then
    local legend_parts = {}
    local keymaps = self._config.keymaps
    if not keymaps then
      return
    end

    if keymaps.up and #keymaps.up > 0 and keymaps.down and #keymaps.down > 0 then
      table.insert(legend_parts, string.format('Navigate: `%s`/`%s` or `↑`/`↓`', keymaps.down[1], keymaps.up[1]))
    end

    if keymaps.select and keymaps.select ~= '' then
      local select_text = string.format('Select: `%s`', keymaps.select)
      if keymaps.number_shortcuts and option_count > 0 then
        local max_shortcut = math.min(option_count, 9)
        select_text = select_text .. string.format(' or `1-%d`', max_shortcut)
      end
      table.insert(legend_parts, select_text)
    end

    if keymaps.dismiss and keymaps.dismiss ~= '' then
      table.insert(legend_parts, string.format('Dismiss: `%s`', keymaps.dismiss))
    end

    if #legend_parts > 0 then
      output:add_line(table.concat(legend_parts, '  '))
    end
  else
    local message = options.unfocused_message or 'Focus Opencode window to interact'
    output:add_line(message)
  end
end

---Format a complete dialog with title, options, legend, and border
---@param output Output Output object to write to
---@param config table Configuration for dialog rendering
---  - title: string - Dialog title
---  - title_hl: string - Highlight group for title
---  - border_hl: string - Highlight group for border
---  - options: table[] - Array of option objects with {label: string, description?: string}
---  - unfocused_message: string - Message to show when not focused
---  - progress?: string - Progress indicator (e.g., "(1/3)")
---  - content?: string[] - Array of lines to render before options
---  - render_content?: function(output: Output) - Custom function to render content before options
function Dialog:format_dialog(output, config)
  if not self._active then
    return
  end

  local formatter = require('opencode.ui.formatter')
  local icons = require('opencode.ui.icons')

  local start_line = output:get_line_count()

  local title = config.title or 'Dialog'
  if config.progress then
    title = title .. config.progress
  end

  output:add_line(title)
  if config.title_hl then
    output:add_extmark(start_line, { line_hl_group = config.title_hl } --[[@as OutputExtmark]])
  end
  output:add_line('')

  if config.render_content then
    config.render_content(output)
    output:add_line('')
  elseif config.content then
    for _, line in ipairs(config.content) do
      output:add_line(line)
    end
    output:add_line('')
  end

  self:format_options(output, config.options or {})

  output:add_line('')

  self:format_legend(output, { unfocused_message = config.unfocused_message })

  local end_line = output:get_line_count()

  if config.border_hl then
    formatter.add_vertical_border(output, start_line + 1, end_line, config.border_hl, -2)
  end

  output:add_line('')
end

---Format options list with selection indicator
---@param output Output Output object to write to
---@param options table[] Array of option objects with {label: string, description?: string}
function Dialog:format_options(output, options)
  for i, option in ipairs(options) do
    local label = option.label
    if option.description and option.description ~= '' then
      label = label .. ' - ' .. option.description
    end

    local line_idx = output:get_line_count()
    local is_selected = self._selected_index == i
    local line_text = is_selected and string.format('    %d. %s ', i, label) or string.format('    %d. %s', i, label)

    output:add_line(line_text)

    if is_selected then
      output:add_extmark(line_idx, { line_hl_group = 'OpencodeDialogOptionHover' } --[[@as OutputExtmark]])
      output:add_extmark(line_idx, {
        start_col = 2,
        virt_text = { { '› ', 'OpencodeDialogOptionHover' } },
        virt_text_pos = 'overlay',
      } --[[@as OutputExtmark]])
    end
  end
end

---Set up buffer-scoped keymaps
function Dialog:_setup_keymaps()
  self:_clear_keymaps()

  local buf = self._config.buffer
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local keymaps = self._config.keymaps
  local keymap_opts = { buffer = buf, silent = true }

  if keymaps.up then
    for _, key in ipairs(keymaps.up) do
      if key and key ~= '' then
        vim.keymap.set('n', key, function()
          self:navigate(-1)
        end, keymap_opts)
        table.insert(self._keymaps, key)
      end
    end
  end

  if keymaps.down then
    for _, key in ipairs(keymaps.down) do
      if key and key ~= '' then
        vim.keymap.set('n', key, function()
          self:navigate(1)
        end, keymap_opts)
        table.insert(self._keymaps, key)
      end
    end
  end

  if keymaps.select and keymaps.select ~= '' then
    vim.keymap.set('n', keymaps.select, function()
      self:select()
    end, keymap_opts)
    table.insert(self._keymaps, keymaps.select)
  end

  if keymaps.dismiss and keymaps.dismiss ~= '' then
    vim.keymap.set('n', keymaps.dismiss, function()
      self:dismiss()
    end, keymap_opts)
    table.insert(self._keymaps, keymaps.dismiss)
  end

  if keymaps.number_shortcuts then
    local option_count = self._config.get_option_count()
    local number_keymap_opts = vim.tbl_extend('force', keymap_opts, { nowait = true })
    for i = 1, math.min(option_count, 9) do
      local key = tostring(i)
      vim.keymap.set('n', key, function()
        if not self._active or not self._config.check_focused() then
          return
        end
        self._selected_index = i
        self._config.on_select(i)
      end, number_keymap_opts)
      table.insert(self._keymaps, key)
    end
  end
end

---Clear all buffer-scoped keymaps
function Dialog:_clear_keymaps()
  local buf = self._config.buffer
  if buf and vim.api.nvim_buf_is_valid(buf) then
    for _, key in ipairs(self._keymaps) do
      pcall(vim.keymap.del, 'n', key, { buffer = buf })
    end
  end
  self._keymaps = {}
end

return Dialog
