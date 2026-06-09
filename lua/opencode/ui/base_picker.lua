local config = require('opencode.config')
local util = require('opencode.util')
local Promise = require('opencode.promise')

---@class PickerAction
---@field key? OpencodeKeymapEntry|string The key binding for this action
---@field label string The display label for this action
---@field fn fun(selected: any|any[], opts: PickerOptions): any[]|Promise<any[]>? The action function
---@field reload? boolean Whether to reload the picker after action
---@field multi_selection? boolean Whether this action supports multi-selection

---@class PickerOptions
---@field items any[] The list of items to pick from
---@field format_fn fun(item: any, width?: number): PickerItem Function to format items for display
---@field actions table<string, PickerAction> Available actions for the picker
---@field callback fun(selected: any?) Callback when item is selected
---@field title string|fun(): string The picker title
---@field width? number Optional width for the picker (defaults to config or current window width)
---@field multi_selection? table<string, boolean> Actions that support multi-selection
---@field preview? "file"|"custom"|"none"|false Preview mode: "file" for file preview, "custom" for custom preview via preview_fn, "none" or false to disable
---@field preview_fn? fun(item: any, target: PickerPreviewTarget): nil Custom preview function, called when preview = 'custom' and a selection changes
---@field layout_opts? OpencodeUIPickerConfig
---@field close? fun() Close the picker programmatically (set by the backend)

---@class PickerPreviewTarget
---@field get_bufnr fun(self: PickerPreviewTarget): integer?
---@field is_valid fun(self: PickerPreviewTarget): boolean
---@field set_lines fun(self: PickerPreviewTarget, lines: string[]): nil
---@field with_window fun(self: PickerPreviewTarget, fn: fun(): nil): nil

---@class TelescopeEntry
---@field value any
---@field display fun(entry: TelescopeEntry): string[]
---@field ordinal string

---@class FzfLuaOptions
---@field fn_fzf_index fun(line: string): integer?

---@class FzfAction
---@field fn fun(selected: string[], fzf_opts: FzfLuaOptions): nil|Promise<nil>
---@field header string
---@field reload boolean

---@class FzfLuaActions
---@field [string] FzfAction|fun(selected: string[], fzf_opts: FzfLuaOptions): nil

---@class MiniPickItem
---@field text string
---@field item any

---@class MiniPickSelected
---@field current MiniPickItem?

---@class PickerItemPart
---@field text string The text content
---@field highlight? string Optional highlight group

---@class PickerItem
---@field parts PickerItemPart[] Array of text parts with optional highlights
---@field to_string fun(self: PickerItem): string
---@field to_formatted_text fun(self: PickerItem): table

---@class BasePicker
local M = {}
local picker = require('opencode.ui.picker')

---@param bufnr integer?
---@return PickerPreviewTarget
local function create_buffer_preview_target(bufnr)
  return {
    get_bufnr = function()
      return bufnr
    end,
    is_valid = function()
      return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
    end,
    set_lines = function(_, lines)
      if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local modifiable = vim.bo[bufnr].modifiable
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].modifiable = modifiable
    end,
    with_window = function(_, fn)
      if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local win = vim.fn.bufwinid(bufnr)
      if win ~= -1 then
        vim.api.nvim_win_call(win, fn)
      end
    end,
  }
end

---@param ctx snacks.picker.preview.ctx
---@return PickerPreviewTarget
local function create_snacks_preview_target(ctx)
  return {
    get_bufnr = function()
      return ctx.buf
    end,
    is_valid = function()
      return ctx.buf ~= nil and vim.api.nvim_buf_is_valid(ctx.buf)
    end,
    set_lines = function(_, lines)
      if ctx.preview and ctx.preview.set_lines then
        ctx.preview:set_lines(lines)
      elseif ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
        create_buffer_preview_target(ctx.buf):set_lines(lines)
      end
    end,
    with_window = function(_, fn)
      if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
        vim.api.nvim_win_call(ctx.win, fn)
        return
      end
      create_buffer_preview_target(ctx.buf):with_window(fn)
    end,
  }
end

---Build title with action legend
---@param base_title string The base title
---@param actions table<string, PickerAction> The available actions
---@param support_multi? boolean Whether multi-selection is supported
---@return string title The formatted title with action legend
local function build_title(base_title, actions, support_multi)
  local legend = {}
  for _, action in pairs(actions) do
    if action.key and action.key[1] then
      local label = action.label .. (action.multi_selection and support_multi ~= false and ' (multi)' or '')
      table.insert(legend, action.key[1] .. ' ' .. label)
    end
  end
  return base_title .. (#legend > 0 and ' | ' .. table.concat(legend, ' | ') or '')
end

---Telescope UI implementation
---@param opts PickerOptions The picker options
local function telescope_ui(opts)
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local action_utils = require('telescope.actions.utils')
  local entry_display = require('telescope.pickers.entry_display')

  -- Create displayer dynamically based on number of parts
  ---@param picker_item PickerItem
  ---@return table
  local function create_displayer(picker_item)
    local items = {}
    for _ in ipairs(picker_item.parts) do
      table.insert(items, {})
    end
    return entry_display.create({
      separator = ' ',
      items = items,
    })
  end

  local current_picker

  ---Creates entry maker function for telescope
  ---@param item any
  ---@return TelescopeEntry
  local function make_entry(item)
    local picker_item = opts.format_fn(item)
    local displayer = create_displayer(picker_item)

    local entry = {
      value = item,
      display = function(entry)
        local formatted = opts.format_fn(entry.value):to_formatted_text()
        return displayer(formatted)
      end,
      ordinal = picker_item:to_string(),
    }

    if type(item) == 'table' then
      entry.path = item.file or item.file_path or item.path or item.filename
      entry.lnum = item.line or item.lnum
      entry.col = item.column or item.col
      -- Support line ranges for preview highlighting
      if item.end_pos and type(item.end_pos) == 'table' and item.end_pos[1] then
        entry.lnend = item.end_pos[1]
      end
    elseif type(item) == 'string' then
      entry.path = item
    end

    return entry
  end

  ---@return unknown
  local function refresh_picker()
    return current_picker
      and current_picker:refresh(
        finders.new_table({ results = opts.items, entry_maker = make_entry }),
        { reset_prompt = false }
      )
  end

  local selection_made = false

  current_picker = pickers.new({}, {
    prompt_title = opts.title,
    finder = finders.new_table({ results = opts.items, entry_maker = make_entry }),
    sorter = conf.generic_sorter({}),
    previewer = (function()
      if opts.preview == 'file' then
        return require('telescope.previewers').vim_buffer_vimgrep.new({})
      elseif opts.preview == 'custom' and opts.preview_fn then
        return require('telescope.previewers').new_buffer_previewer({
          define_preview = function(self, entry)
            if not entry then
              return
            end
            opts.preview_fn(entry.value, create_buffer_preview_target(self.state.bufnr))
          end,
        })
      else
        return nil
      end
    end)(),
    layout_config = opts.width and {
        width = opts.width + 7, -- extra space for telescope UI
      } or nil,
    attach_mappings = function(prompt_bufnr, map)
      opts.close = function()
        selection_made = true
        actions.close(prompt_bufnr)
      end

      actions.select_default:replace(function()
        selection_made = true
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection and opts.callback then
          opts.callback(selection.value)
        end
      end)

      actions.close:enhance({
        post = function()
          if not selection_made and opts.callback then
            vim.schedule(function()
              opts.callback(nil)
            end)
          end
        end,
      })

      for _, action in pairs(opts.actions) do
        if action.key and action.key[1] then
          local modes = action.key.mode or { 'i', 'n' }
          if type(modes) == 'string' then
            modes = { modes }
          end

          local action_fn = function()
            local items_to_process

            if action.multi_selection then
              local multi_selection = {}
              action_utils.map_selections(prompt_bufnr, function(entry, index)
                table.insert(multi_selection, entry.value)
              end)

              if #multi_selection > 0 then
                items_to_process = multi_selection
              else
                local selection = action_state.get_selected_entry()
                items_to_process = selection and selection.value or nil
              end
            else
              local selection = action_state.get_selected_entry()
              items_to_process = selection and selection.value or nil
            end

            if items_to_process then
              local new_items = action.fn(items_to_process, opts)
              Promise.wrap(new_items):and_then(function(resolved_items)
                if action.reload and resolved_items then
                  if #resolved_items == 0 and opts.close then
                    opts.close()
                  else
                    opts.items = resolved_items
                    refresh_picker()
                  end
                end
              end)
            end
          end

          for _, mode in ipairs(modes) do
            map(mode, action.key[1], action_fn)
          end
        end
      end

      return true
    end,
  })

  current_picker:find()
end

---FZF-Lua UI implementation
---@param opts PickerOptions The picker options
local function fzf_ui(opts)
  local fzf_lua = require('fzf-lua')

  local function finder(fzf_cb)
    for idx, item in ipairs(opts.items) do
      local line_str = opts.format_fn(item):to_string()

      -- Prepend index with SOH delimiter for reliable matching
      local indexed_line = tostring(idx) .. '\x01' .. line_str

      -- For file preview support, append file:line:col format
      -- fzf-lua's builtin previewer automatically parses this format
      if opts.preview == 'file' and type(item) == 'table' then
        local file_path = item.file_path or item.path or item.filename or item.file
        local line = item.line or item.lnum
        local col = item.column or item.col

        if file_path then
          -- fzf-lua parses "path:line:col:" format for preview positioning
          local pos_info = file_path
          if line then
            pos_info = pos_info .. ':' .. tostring(line)
            if col then
              pos_info = pos_info .. ':' .. tostring(col)
            end
            pos_info = pos_info .. ':'
          end
          -- Append position info after nbsp separator (fzf-lua standard)
          -- nbsp is U+2002 EN SPACE, not regular tab
          local nbsp = '\xe2\x80\x82'
          indexed_line = indexed_line .. nbsp .. pos_info
        end
      end

      fzf_cb(indexed_line)
    end
    fzf_cb()
  end

  local has_custom_preview = opts.preview == 'custom' and opts.preview_fn ~= nil

  ---@return table
  local function create_fzf_config()
    local has_multi_action = util.some(opts.actions, function(action)
      return action.multi_selection
    end)

    return {
      winopts = opts.width and {
          width = opts.width + 8, -- extra space for fzf UI
        } or nil,
      fzf_opts = {
        ['--prompt'] = opts.title .. ' > ',
        ['--multi'] = has_multi_action and true or nil,
        ['--with-nth'] = '2..', -- hide the index prefix from display
        ['--delimiter'] = '\x01', -- use SOH as delimiter (invisible char)
      },
      _headers = { 'actions' },
      previewer = (function()
        if opts.preview == 'file' then
          return 'builtin'
        elseif has_custom_preview then
          return {
            _ctor = function()
              local previewer = require('fzf-lua.previewer.builtin').buffer_or_file:extend()
              function previewer:populate_preview_buf(entry_str)
                if not self.win or not self.win:validate_preview() then
                  return
                end
                local idx_str = entry_str:match('^(%d+)\x01')
                local idx = tonumber(idx_str)
                if not idx or not opts.items[idx] then
                  return
                end
                -- Create scratch buffer, attach to preview window first
                -- so preview_fn can use bufwinid for window-local ops (folds)
                local buf = self:get_tmp_buffer()
                self:set_preview_buf(buf, true) -- min_winopts=true
                opts.preview_fn(opts.items[idx], create_buffer_preview_target(buf))
              end
              return previewer
            end,
          }
        else
          return nil
        end
      end)(),
      fn_fzf_index = function(line)
        -- Extract the numeric index prefix before the SOH delimiter
        local idx_str = line:match('^(%d+)\x01')
        if idx_str then
          return tonumber(idx_str)
        end
        return nil
      end,
    }
  end

  ---Reopen fzf-lua to reflect updated picker items.
  local function refresh_fzf()
    vim.schedule(function()
      fzf_ui(opts)
    end)
  end

  local closed = false

  opts.close = function()
    if closed then
      return
    end
    closed = true
    vim.schedule(function()
      local ok, fzf_win = pcall(require, 'fzf-lua.win')
      if ok and fzf_win.__SELF then
        local win = fzf_win.__SELF()
        if win then
          win:close()
        end
      end
      if opts.callback then
        opts.callback(nil)
      end
    end)
  end

  ---@type FzfLuaActions
  local actions_config = {
    ['default'] = function(selected, fzf_opts)
      if closed then
        return
      end
      if not selected or #selected == 0 then
        if opts.callback then
          opts.callback(nil)
        end
        return
      end
      local idx = fzf_opts.fn_fzf_index(selected[1] --[[@as string]])
      if idx and opts.items[idx] and opts.callback then
        opts.callback(opts.items[idx])
      end
    end,
    ['esc'] = function()
      if closed then
        return
      end
      if opts.callback then
        opts.callback(nil)
      end
    end,
  }

  for _, action in pairs(opts.actions) do
    if action.key and action.key[1] then
      local key = require('fzf-lua.utils').neovim_bind_to_fzf(action.key[1])
      actions_config[key] = {
        fn = function(selected, fzf_opts)
          if not selected or #selected == 0 then
            return
          end

          local items_to_process
          if action.multi_selection and #selected > 1 then
            items_to_process = {}
            for _, sel in ipairs(selected) do
              local idx = fzf_opts.fn_fzf_index(sel --[[@as string]])
              if idx and opts.items[idx] then
                table.insert(items_to_process, opts.items[idx])
              end
            end
          else
            local idx = fzf_opts.fn_fzf_index(selected[1] --[[@as string]])
            if idx and opts.items[idx] then
              items_to_process = opts.items[idx]
            end
          end

          if items_to_process then
            local new_items = action.fn(items_to_process, opts)
            Promise.wrap(new_items):and_then(function(resolved_items)
              if action.reload and resolved_items then
                ---@cast resolved_items any[]
                if #resolved_items == 0 and opts.close then
                  opts.close()
                else
                  opts.items = resolved_items
                  refresh_fzf()
                end
              end
            end)
          end
        end,
        header = action.label,
        reload = action.reload or false,
      }
    end
  end

  local fzf_config = create_fzf_config()
  fzf_config.actions = actions_config

  fzf_lua.fzf_exec(function(fzf_cb)
    finder(fzf_cb)
  end, fzf_config)
end

---Mini.pick UI implementation
---@param opts PickerOptions The picker options
local function mini_pick_ui(opts)
  local mini_pick = require('mini.pick')

  ---@type MiniPickItem[]
  local items = vim.tbl_map(function(item)
    return { text = opts.format_fn(item):to_string(), item = item }
  end, opts.items)

  local mappings = {}

  opts.close = function()
    mini_pick.stop()
  end

  for action_name, action in pairs(opts.actions) do
    if action.key and action.key[1] then
      mappings[action_name] = {
        char = action.key[1],
        func = function()
          local current = mini_pick.get_picker_matches().current
          if current and current.item then
            -- Mini.pick doesn't have native multi-selection, we fallback single selection
            local new_items = action.fn(current.item, opts)
            Promise.wrap(new_items):and_then(function(resolved_items)
              if action.reload and resolved_items then
                if #resolved_items == 0 and opts.close then
                  opts.close()
                else
                  opts.items = resolved_items
                  mini_pick_ui(opts)
                end
              end
            end)
          end
          return true
        end,
      }
    end
  end

  local selection_made = false

  mini_pick.start({
    window = opts.width
        and {
          config = {
            width = opts.width + 2, -- extra space for mini.pick UI
          },
        }
      or nil,
    source = {
      items = items,
      name = opts.title,
      choose = function(selected)
        if selected and selected.item and opts.callback then
          selection_made = true
          opts.callback(selected.item)
        end
        return false
      end,
      on_done = function()
        if not selection_made and opts.callback then
          vim.schedule(function()
            opts.callback(nil)
          end)
        end
      end,
    },
    mappings = mappings,
  })
end

---Snacks picker UI implementation
---@param opts PickerOptions The picker options
local function snacks_picker_ui(opts)
  local Snacks = require('snacks')

  local has_custom_preview = opts.preview == 'custom' and opts.preview_fn ~= nil
  local has_preview = opts.preview == 'file' or has_custom_preview

  local title = type(opts.title) == 'function' and opts.title() or opts.title
  ---@cast title string

  local layout_opts = opts.layout_opts and opts.layout_opts.snacks_layout or nil

  local selection_made = false
  local default_layout = {
    preset = has_custom_preview and 'default' or 'select',
    config = function(layout)
      local width = opts.width and (opts.width + 3) or nil -- extra space for snacks UI
      if not has_preview then
        layout.layout.width = width
        layout.layout.max_width = width
        layout.layout.min_width = width
      end
    end,
  }
  if opts.preview == 'file' then
    default_layout.preview = 'main'
  elseif not has_preview then
    default_layout.preview = false
  end

  ---@type snacks.picker.Config
  local snack_opts = {
    title = title,
    layout = layout_opts or default_layout,
    finder = function()
      return opts.items
    end,
    matcher = {
      sort_empty = false,
    },
    sort = {
      fields = { 'score:desc', 'idx' },
    },
    transform = function(item, ctx)
      if type(item) == 'table' then
        if item.idx == nil then
          item.idx = ctx.idx
        end
        if item.favorite_index and item.favorite_index < 999 then
          item.score_add = (item.score_add or 0) + (1000 - item.favorite_index) * 1000
        end
        if not item.text then
          local picker_item = opts.format_fn(item)
          item.text = picker_item:to_string()
        end
      end
    end,
    format = function(item)
      return opts.format_fn(item):to_formatted_text()
    end,
    on_close = function()
      if not selection_made and opts.callback then
        vim.schedule(function()
          opts.callback(nil)
        end)
      end
    end,
    actions = {
      confirm = function(_picker, item)
        selection_made = true
        _picker:close()
        if item and opts.callback then
          vim.schedule(function()
            opts.callback(item)
          end)
        end
      end,
    },
  }

  if opts.preview == 'file' then
    snack_opts.preview = 'file'
  elseif has_custom_preview then
    snack_opts.preview = function(ctx)
      if ctx.item then
        ctx.preview:reset()
        opts.preview_fn(ctx.item, create_snacks_preview_target(ctx))
      end
    end
  else
    snack_opts.preview = function()
      return false
    end
  end

  snack_opts.win = snack_opts.win or {}
  snack_opts.win.input = snack_opts.win.input or { keys = {} }

  for action_name, action in pairs(opts.actions) do
    if action.key and action.key[1] then
      snack_opts.win.input.keys[action.key[1]] = { action_name, mode = action.key.mode or 'i' }

      snack_opts.actions[action_name] = function(_picker, item)
        if not opts.close then
          opts.close = function()
            selection_made = true
            _picker:close()
          end
        end

        if item then
          local items_to_process
          if action.multi_selection then
            local selected_items = _picker:selected({ fallback = true })
            items_to_process = #selected_items > 1 and selected_items or item
          else
            items_to_process = item
          end

          if not action.reload then
            selection_made = true
            _picker:close()
          end

          vim.schedule(function()
            local new_items = action.fn(items_to_process, opts)
            Promise.wrap(new_items):and_then(function(resolved_items)
              if action.reload and resolved_items then
                if #resolved_items == 0 and opts.close then
                  opts.close()
                else
                  opts.items = resolved_items
                  _picker:refresh()
                  _picker:find()
                end
              end
            end)
          end)
        end
      end
    end
  end

  ---@generic T
  Snacks.picker.pick(snack_opts)
end

---@param text? string
---@param width integer
---@param opts? {align?: "left" | "right" | "center", truncate?: boolean}
function M.align(text, width, opts)
  text = text or ''
  opts = opts or {}
  opts.align = opts.align or 'left'
  local tw = vim.api.nvim_strwidth(text)
  if tw > width then
    return opts.truncate and (vim.fn.strcharpart(text, 0, width - 1) .. '…') or text
  end
  local left = math.floor((width - tw) / 2)
  local right = width - tw - left
  if opts.align == 'left' then
    left, right = 0, width - tw
  elseif opts.align == 'right' then
    left, right = width - tw, 0
  end
  return (' '):rep(left) .. text .. (' '):rep(right)
end

---Creates a generic picker item that can format itself for different pickers
---@param parts PickerItemPart[] Array of text parts with optional highlights
---@return PickerItem
function M.create_picker_item(parts)
  local item = {
    parts = parts,
  }

  ---@return string
  function item:to_string()
    local texts = {}
    for _, part in ipairs(self.parts) do
      table.insert(texts, part.text)
    end
    return table.concat(texts, ' ')
  end

  ---@return table
  function item:to_formatted_text()
    local formatted = {}
    for _, part in ipairs(self.parts) do
      if part.highlight then
        table.insert(formatted, { ' ' .. part.text, part.highlight })
      else
        table.insert(formatted, { part.text })
      end
    end
    return formatted
  end

  return item
end

---Compute the maximum formatted time width across a list of items.
---@param items any[] The list of items
---@param get_time_fn fun(item: any): number? Extracts a timestamp from an item
---@return number max_width The width of the longest format_time result (0 if no valid timestamps)
function M.max_time_width(items, get_time_fn)
  local max_w = 0
  for _, item in ipairs(items) do
    local t = get_time_fn(item)
    if t and type(t) == 'number' then
      local w = #util.format_time(t)
      if w > max_w then
        max_w = w
      end
    end
  end
  return max_w
end

---Helper function to create a simple picker item with content, time, and debug text
---This is a convenience wrapper around create_picker_item for common use cases
---@param text string Main content text
---@param time? number Optional time to format
---@param debug_text? string Optional debug text to append
---@param width? number Optional width override
---@param max_time_width? number Optional pre-computed max time column width from max_time_width()
---@return PickerItem
function M.create_time_picker_item(text, time, debug_text, width, max_time_width)
  local time_width = time and (max_time_width or #util.format_time(0)) or 0
  local has_debug = config.debug.show_ids and debug_text
  local debug_width = has_debug and #debug_text or 0
  local item_width = width or vim.api.nvim_win_get_width(0)
  -- Each extra part adds a 1-char separator in to_string()/to_formatted_text(),
  -- so subtract those from the text budget.
  local separator_count = (time_width > 0 and 1 or 0) + (debug_width > 0 and 1 or 0)
  local text_width = item_width - time_width - debug_width - separator_count

  local parts = {
    {
      text = M.align(text, text_width --[[@as integer]], { truncate = true }),
    },
  }

  if time then
    table.insert(parts, {
      text = M.align(util.format_time(time), time_width, { align = 'right' }),
      highlight = 'OpencodePickerTime',
    })
  end

  if has_debug then
    table.insert(parts, {
      text = debug_text,
      highlight = 'OpencodeDebugText',
    })
  end

  return M.create_picker_item(parts)
end

---Generic picker that abstracts common logic for different picker UIs
---@param opts PickerOptions The picker options
---@return boolean success Whether the picker was successfully launched
function M.pick(opts)
  local picker_type = picker.get_best_picker()

  if not picker_type then
    return false
  end

  if not opts.width then
    opts.width = config.ui.picker_width
  end

  -- picker_width = false means "use picker backend defaults, no override"
  if opts.width == false then
    opts.width = nil
  end

  -- Resolve relative width (0 < w <= 1) to absolute columns so that
  -- format functions and all picker backends receive a consistent value.
  if opts.width and opts.width > 0 and opts.width <= 1 then
    opts.width = math.floor(vim.o.columns * opts.width)
  end

  -- When width is nil (picker_width = false or unset), derive a content width
  -- from the picker backend's default window size so format functions can
  -- produce correctly-sized output that fills the backend's content area.
  local format_width = opts.width
  if not format_width then
    if picker_type == 'fzf' then
      -- Read fzf-lua's effective winopts.width (respects user customization).
      local fzf_win_width = 0.8
      local ok, fzf_config = pcall(require, 'fzf-lua.config')
      if ok and fzf_config and fzf_config.globals and fzf_config.globals.winopts then
        fzf_win_width = fzf_config.globals.winopts.width or fzf_win_width
      end
      -- Resolve fraction to absolute columns
      if fzf_win_width > 0 and fzf_win_width <= 1 then
        fzf_win_width = math.floor(vim.o.columns * fzf_win_width)
      end
      -- Subtract the same chrome offset used when we set winopts ourselves (+8),
      -- which covers borders, padding, and fzf's pointer indicator.
      format_width = fzf_win_width - 8
    else
      format_width = math.floor(vim.o.columns * 0.8)
    end
  end

  local has_preview = opts.preview and opts.preview ~= 'none' and opts.preview ~= false
  if picker_type == 'fzf' and has_preview and format_width then
    local window_cols = format_width + 8
    -- Match fzf-lua's default right:60% preview split so item formatting
    -- targets the visible list pane instead of the full window width.
    format_width = math.floor(window_cols * 0.4) - 4
  end

  local original_format_fn = opts.format_fn
  opts.format_fn = function(item, width)
    return original_format_fn(item, width or format_width)
  end

  local title_str = type(opts.title) == 'function' and opts.title() or opts.title --[[@as string]]

  vim.schedule(function()
    if picker_type == 'telescope' then
      opts.title = build_title(title_str, opts.actions)
      telescope_ui(opts)
    elseif picker_type == 'fzf' then
      opts.title = title_str
      fzf_ui(opts)
    elseif picker_type == 'mini.pick' then
      opts.title = build_title(title_str, opts.actions, false)
      mini_pick_ui(opts)
    elseif picker_type == 'snacks' then
      opts.title = build_title(title_str, opts.actions)
      snacks_picker_ui(opts)
    else
      opts.callback(nil)
    end
  end)

  return true
end

return M
