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

---@class PickerItem
---@field content string Main content text
---@field time_text? string Optional time text
---@field debug_text? string Optional debug text
---@field to_string fun(self: PickerItem): string
---@field to_formatted_text fun(self: PickerItem): table

---@class BasePicker
local M = {}
local picker = require('opencode.ui.picker')

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
  local displayer = entry_display.create({
    separator = ' ',
    items = { {}, {}, config.debug.show_ids and {} or nil },
  })

  local current_picker

  ---Creates entry maker function for telescope
  ---@param item any
  ---@return TelescopeEntry
  local function make_entry(item)
    return {
      value = item,
      display = function(entry)
        local formatted = opts.format_fn(entry.value):to_formatted_text()
        return displayer(formatted)
      end,
      ordinal = opts.format_fn(item):to_string(),
    }
  end

  local function refresh_picker()
    return current_picker
      and current_picker:refresh(
        finders.new_table({ results = opts.items, entry_maker = make_entry }),
        { reset_prompt = false }
      )
  end

  current_picker = pickers.new({}, {
    prompt_title = opts.title,
    finder = finders.new_table({ results = opts.items, entry_maker = make_entry }),
    sorter = conf.generic_sorter({}),
    layout_config = opts.width and {
        width = opts.width + 7, -- extra space for telescope UI
      } or nil,
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection and opts.callback then
          opts.callback(selection.value)
        end
      end)

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
                  opts.items = resolved_items
                  refresh_picker()
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
      },
      _headers = { 'actions' },
      fn_fzf_index = function(line)
        for i, item in ipairs(opts.items) do
          if opts.format_fn(item):to_string() == line then
            return i
          end
        end
        return nil
      end,
    }
  end

  local function create_finder()
    return function(fzf_cb)
      for _, item in ipairs(opts.items) do
        fzf_cb(opts.format_fn(item):to_string())
      end
      fzf_cb()
    end
  end

  local function refresh_fzf()
    vim.schedule(function()
      fzf_ui(opts)
    end)
  end

  ---@type FzfLuaActions
  local actions_config = {
    ['default'] = function(selected, fzf_opts)
      if not selected or #selected == 0 then
        return
      end
      local idx = fzf_opts.fn_fzf_index(selected[1] --[[@as string]])
      if idx and opts.items[idx] and opts.callback then
        opts.callback(opts.items[idx])
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
                opts.items = resolved_items
                refresh_fzf()
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

  fzf_lua.fzf_exec(create_finder(), fzf_config)
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
                opts.items = resolved_items
                mini_pick_ui(opts)
              end
            end)
          end
          return true
        end,
      }
    end
  end

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
          opts.callback(selected.item)
        end
        return false
      end,
    },
    mappings = mappings,
  })
end

---Snacks picker UI implementation
---@param opts PickerOptions The picker options
local function snacks_picker_ui(opts)
  local Snacks = require('snacks')

  local snack_opts = {
    title = opts.title,
    layout = {
      preset = 'select',
      config = function(layout)
        local width = opts.width and (opts.width + 3) or nil -- extra space for snacks UI
        layout.layout.width = width
        layout.layout.max_width = width
        layout.layout.min_width = width
        return layout
      end,
    },
    finder = function()
      return opts.items
    end,
    transform = function(item, ctx)
      -- Snacks requires item.text to be set to do matching
      if not item.text then
        local picker_item = opts.format_fn(item)
        item.text = picker_item:to_string()
      end
    end,
    format = function(item)
      return opts.format_fn(item):to_formatted_text()
    end,
    actions = {
      confirm = function(_picker, item)
        _picker:close()
        if item and opts.callback then
          vim.schedule(function()
            opts.callback(item)
          end)
        end
      end,
    },
  }

  snack_opts.win = snack_opts.win or {}
  snack_opts.win.input = snack_opts.win.input or { keys = {} }

  for action_name, action in pairs(opts.actions) do
    if action.key and action.key[1] then
      snack_opts.win.input.keys[action.key[1]] = { action_name, mode = action.key.mode or 'i' }

      snack_opts.actions[action_name] = function(_picker, item)
        if item then
          vim.schedule(function()
            local items_to_process
            if action.multi_selection then
              local selected_items = _picker:selected({ fallback = true })
              items_to_process = #selected_items > 1 and selected_items or item
            else
              items_to_process = item
            end

            local new_items = action.fn(items_to_process, opts)
            Promise.wrap(new_items):and_then(function(resolved_items)
              if action.reload and resolved_items then
                opts.items = resolved_items
                _picker:refresh()
                _picker:find()
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
---@param text string Array of text parts to join
---@param time? number Optional time text to highlight
---@param debug_text? string Optional debug text to append
---@param width? number Optional width override
---@return PickerItem
function M.create_picker_item(text, time, debug_text, width)
  local time_width = time and #util.format_time(time) + 1 or 0
  local debug_width = config.debug.show_ids and debug_text and #debug_text + 1 or 0
  local item_width = width or vim.api.nvim_win_get_width(0)
  local text_width = item_width - (debug_width + time_width)
  local item = {
    content = M.align(text, text_width --[[@as integer]], { truncate = true }),
    time_text = time and M.align(util.format_time(time), time_width, { align = 'right' }),
    debug_text = config.debug.show_ids and debug_text or nil,
  }

  function item:to_string()
    return table.concat({ self.content, self.time_text or '', self.debug_text or '' }, ' ')
  end

  function item:to_formatted_text()
    return {
      { self.content },
      self.time_text and { ' ' .. self.time_text, 'OpencodePickerTime' } or nil,
      self.debug_text and { ' ' .. self.debug_text, 'OpencodeDebugText' } or nil,
    }
  end

  return item
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

  local original_format_fn = opts.format_fn
  opts.format_fn = function(item)
    return original_format_fn(item, opts.width)
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
