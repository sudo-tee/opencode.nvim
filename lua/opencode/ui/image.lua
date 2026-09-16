local config = require('opencode.config')
local util = require('opencode.util')

local M = {}

local output_images = {} ---@type table<string, ImageEntry[]>
local preview ---@type ImageEntry?
local support_api
local support_checked = false
local support_checked_at = 0
local support_result = false
local dimension_cache = {} ---@type table<string, { signature: string, width: number, height: integer }>
local refresh_timer
local refresh_force = false
local MAX_IMAGE_HEIGHT = 1000

---@class ImageEntry
---@field path string
---@field line integer 1-based buffer line containing image anchor
---@field col integer 1-based buffer column containing image anchor
---@field local_line integer? 1-based part-local line for output images
---@field above boolean? Place image above anchor instead of below it
---@field height integer?
---@field height_width number?
---@field last_opts table?
---@field id integer?

local function raw_image_api()
  local ok, img = pcall(function()
    return vim.ui and vim.ui.img
  end)
  if not ok or type(img) ~= 'table' or type(img.set) ~= 'function' or type(img.del) ~= 'function' then
    return nil
  end

  if img ~= support_api then
    support_api = img
    support_checked = false
    support_checked_at = 0
    support_result = false
  end
  return img
end

local function image_api()
  local img = raw_image_api()
  if not img then
    return nil
  end

  if type(img._supported) == 'function' then
    local now = vim.uv.now()
    if not support_checked or (not support_result and now - support_checked_at >= 1000) then
      support_checked = true
      support_checked_at = now
      local supported_ok, supported = pcall(img._supported, { timeout = 250 })
      support_result = supported_ok and supported == true
    end
    if not support_result then
      return nil
    end
  end

  return img
end

---@param value any
---@return boolean
local function is_valid_dimension(value)
  return type(value) == 'number' and value == value and value > 0 and value < math.huge
end

---@param options table
---@return integer?
local function configured_width(options)
  if not is_valid_dimension(options.width) then
    return nil
  end
  return math.max(1, math.floor(options.width))
end

local function image_options()
  local images = config.ui and config.ui.output and config.ui.output.images
  if type(images) ~= 'table' or images.enabled == false or not configured_width(images) then
    return nil
  end
  return images
end

---@param path string
---@return boolean
local function is_valid_file(path)
  return vim.fn.filereadable(path) == 1
end

---@param path string
---@param mime? string
---@return boolean
function M.is_supported_path(path, mime)
  return type(path) == 'string' and (mime == 'image/png' or path:lower():match('%.png$') ~= nil)
end

---@return boolean
function M.is_available()
  return image_options() ~= nil and image_api() ~= nil
end

---@param path string
---@return boolean
local function is_allowed_path(path)
  return util.is_path_in_cwd(path) or util.is_temp_path(path, '^pasted_image_')
end

---@param path string
---@return string?
function M.resolve_path(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end

  local image_handler = require('opencode.image_handler')
  local ok, restored = pcall(image_handler.restore_img_path, path)
  if ok and restored and is_allowed_path(restored) then
    return restored
  end

  path = path:gsub('^file://', '')
  if is_valid_file(path) and is_allowed_path(path) then
    return path
  end

  local absolute = vim.fn.fnamemodify(path, ':p')
  if is_valid_file(absolute) and is_allowed_path(absolute) then
    return absolute
  end

  return nil
end

---@param part OpencodeMessagePart
---@return string?
function M.path_for_part(part)
  local source = part.source
  local candidates = {
    source and source.path,
    part.url,
    part.filename,
  }
  for _, path in ipairs(candidates) do
    if path and M.is_supported_path(path, part.mime) then
      local resolved = M.resolve_path(path)
      if resolved then
        return resolved
      end
    end
  end
  return nil
end

---@param path string
---@return string?
local function read_bytes(path)
  local validate = function(data)
    return type(data) == 'string' and data:sub(1, 8) == '\137PNG\r\n\026\n' and data or nil
  end

  if vim.fn.readblob then
    local ok, data = pcall(vim.fn.readblob, path)
    if ok and type(data) == 'string' then
      return validate(data)
    end
  end

  local file = io.open(path, 'rb')
  if not file then
    return nil
  end
  local data = file:read('*a')
  file:close()
  return validate(data)
end

---@param data string
---@param offset integer
---@return integer?
local function read_be_u32(data, offset)
  local b1, b2, b3, b4 = data:byte(offset, offset + 3)
  if not b4 then
    return nil
  end
  return b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4
end

---@param data string
---@return integer?
---@return integer?
local function png_dimensions(data)
  if data:sub(1, 8) ~= '\137PNG\r\n\026\n' or data:sub(13, 16) ~= 'IHDR' then
    return nil, nil
  end

  return read_be_u32(data, 17), read_be_u32(data, 21)
end

---@param path string
---@return string?
local function file_signature(path)
  local ok, stat = pcall(vim.uv.fs_stat, path)
  if not ok or not stat then
    return nil
  end
  local mtime = stat.mtime or {}
  return string.format('%s:%s:%s', stat.size or '', mtime.sec or '', mtime.nsec or '')
end

---@param path string
---@return integer?
---@return integer?
local function read_png_dimensions(path)
  local file = io.open(path, 'rb')
  if not file then
    return nil, nil
  end
  local header = file:read(24)
  file:close()
  if not header then
    return nil, nil
  end
  return png_dimensions(header)
end

---@param path? string
---@return integer
function M.get_height(path)
  local options = image_options()
  if not options then
    return 1
  end
  if is_valid_dimension(options.height) then
    return math.min(MAX_IMAGE_HEIGHT, math.max(1, math.floor(options.height)))
  end
  if not path then
    return 1
  end

  local display_width = configured_width(options)
  local signature = file_signature(path) or ''
  local cached = dimension_cache[path]
  if cached and cached.signature == signature and cached.width == display_width then
    return cached.height
  end

  local width, height = read_png_dimensions(path)
  if
    not width
    or not height
    or not is_valid_dimension(width)
    or not is_valid_dimension(height)
    or not display_width
  then
    return 1
  end

  local display_height = math.min(MAX_IMAGE_HEIGHT, math.max(1, math.ceil(height / width * display_width * 0.5)))
  dimension_cache[path] = { signature = signature, width = display_width, height = display_height }
  return display_height
end

---@param win integer
---@param line integer
---@param col integer
---@return { row: integer, col: integer }?
local function screen_position(win, line, col)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local ok, position = pcall(vim.fn.screenpos, win, line, col)
  if ok and type(position) == 'table' then
    if position.row and position.row > 0 and position.col and position.col > 0 then
      return { row = position.row, col = position.col }
    end
    return nil
  end

  local win_ok, win_position = pcall(vim.api.nvim_win_get_position, win)
  if not win_ok then
    return nil
  end
  return {
    row = win_position[1] + line,
    col = win_position[2] + col,
  }
end

---@param win integer
---@param line integer
---@return integer
local function screen_line_height(win, line)
  local ok, height = pcall(vim.api.nvim_win_text_height, win, { start_row = line - 1, end_row = line - 1 })
  if ok and type(height) == 'table' and type(height.all) == 'number' then
    return math.max(1, height.all)
  end
  return 1
end

---@param win integer
---@param row integer
---@param col integer
---@param width integer
---@param height integer
---@return boolean
local function fits_in_window(win, row, col, width, height)
  local ok, position = pcall(vim.api.nvim_win_get_position, win)
  if not ok then
    return true
  end

  local win_height = vim.api.nvim_win_get_height(win)
  local win_width = vim.api.nvim_win_get_width(win)
  local top = position[1] + 1
  local left = position[2] + 1
  return row >= top
    and row + height - 1 <= top + win_height - 1
    and col >= left
    and col + width - 1 <= left + win_width - 1
end

---@param entry ImageEntry
local function delete_entry(entry)
  if not entry.id then
    entry.last_opts = nil
    return
  end
  local img = raw_image_api()
  if img then
    pcall(img.del, entry.id)
  end
  entry.id = nil
  entry.last_opts = nil
end

---@param entry ImageEntry
---@param win integer
---@param force? boolean Re-place image even when placement opts are unchanged
local function place_entry(entry, win, force)
  local options = image_options()
  local img = options and image_api() or nil
  if not img or not options then
    delete_entry(entry)
    return
  end

  local image_width = configured_width(options)
  local image_height
  if is_valid_dimension(options.height) then
    image_height = M.get_height(entry.path)
  elseif entry.height and entry.height_width == image_width then
    image_height = entry.height
  else
    image_height = M.get_height(entry.path)
    entry.height = image_height
    entry.height_width = image_width
  end

  local position = screen_position(win, entry.line, entry.col)
  if not position then
    delete_entry(entry)
    return
  end

  local row = entry.above and math.max(1, position.row - image_height)
    or position.row + screen_line_height(win, entry.line)
  local opts = {
    row = row,
    col = position.col,
    width = image_width,
    height = image_height,
    zindex = options.zindex,
  }

  if not entry.above and not fits_in_window(win, opts.row, opts.col, opts.width, opts.height) then
    delete_entry(entry)
    return
  end

  if not force and entry.id and entry.last_opts and vim.deep_equal(entry.last_opts, opts) then
    return
  end

  if entry.id then
    local ok = pcall(img.set, entry.id, opts)
    if ok then
      entry.last_opts = opts
      return
    end
    entry.id = nil
  end

  local data = read_bytes(entry.path)
  if not data then
    return
  end

  local ok, id = pcall(img.set, data, opts)
  if ok and type(id) == 'number' then
    entry.id = id
    entry.last_opts = opts
  end
end

---@param entries ImageEntry[]
local function delete_entries(entries)
  for _, entry in ipairs(entries) do
    delete_entry(entry)
  end
end

---@param part_id string
---@param images OutputImage[]|nil
---@param line_start integer 0-based absolute output line
---@param refresh? boolean Refresh visible output images after updating metadata
function M.set_output_images(part_id, images, line_start, refresh)
  local previous = output_images[part_id] or {}
  local entries = {}

  for index, image in ipairs(images or {}) do
    local path = M.resolve_path(image.path)
    if path and M.is_supported_path(path, image.mime) then
      local entry = previous[index]
      if not entry or entry.path ~= path then
        if entry then
          delete_entry(entry)
        end
        entry = { path = path, line = 0, col = image.col or 1 }
      end
      entry.local_line = image.line
      entry.line = line_start + image.line
      entry.col = image.col or 1
      entries[#entries + 1] = entry
    end
  end

  for index = #entries + 1, #previous do
    delete_entry(previous[index])
  end

  output_images[part_id] = entries
  if refresh ~= false then
    M.schedule_refresh_output()
  end
end

---@param part_id string
function M.clear_output_part(part_id)
  local entries = output_images[part_id]
  if not entries then
    return
  end
  delete_entries(entries)
  output_images[part_id] = nil
end

---@param force? boolean Re-place images for terminals that lost placements
function M.refresh_output(force)
  local state = require('opencode.state')
  local windows = state.windows
  local win = windows and windows.output_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not state.ui.is_window_in_current_tab(win) then
    M.hide_output()
    return
  end

  local ctx = require('opencode.ui.renderer.ctx')
  for part_id, entries in pairs(output_images) do
    local part = ctx.render_state:get_part(part_id)
    if part and part.line_start then
      for _, entry in ipairs(entries) do
        if entry.local_line then
          entry.line = part.line_start + entry.local_line
        end
      end
    end
    for _, entry in ipairs(entries) do
      place_entry(entry, win, force)
    end
  end
end

---@param force? boolean Re-place images for terminals that lost placements
function M.schedule_refresh_output(force)
  refresh_force = refresh_force or force == true
  if refresh_timer then
    return
  end
  refresh_timer = vim.defer_fn(function()
    refresh_timer = nil
    local force_refresh = refresh_force
    refresh_force = false
    M.refresh_output(force_refresh)
  end, 50)
end

function M.rebuild_output()
  for part_id in pairs(output_images) do
    M.clear_output_part(part_id)
  end

  local ctx = require('opencode.ui.renderer.ctx')
  for part_id, formatted in pairs(ctx.formatted_parts) do
    local part = ctx.render_state:get_part(part_id)
    if part and part.line_start and formatted.images then
      M.set_output_images(part_id, formatted.images, part.line_start, false)
    end
  end
  M.refresh_output()
  M.schedule_refresh_output()
end

function M.hide_output()
  for _, entries in pairs(output_images) do
    delete_entries(entries)
  end
end

function M.clear_output()
  for part_id in pairs(output_images) do
    M.clear_output_part(part_id)
  end
end

function M.clear_preview()
  if preview then
    delete_entry(preview)
    preview = nil
  end
end

---@param path string
---@param win integer
---@param line integer
---@param col integer
function M.show_preview(path, win, line, col)
  path = M.resolve_path(path)
  if not path or not M.is_supported_path(path) then
    M.clear_preview()
    return
  end

  if not preview or preview.path ~= path then
    M.clear_preview()
    preview = { path = path, line = line, col = col, above = true }
  else
    preview.line = line
    preview.col = col
  end
  place_entry(preview, win, true)
end

return M
