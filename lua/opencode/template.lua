-- Template rendering functionality

local M = {}

local Renderer = {}

function Renderer.escape(data)
  return tostring(data or ''):gsub("[\">/<'&]", {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
    ["'"] = "&#39;",
    ["/"] = "&#47;"
  })
end

function Renderer.render(tpl, args)
  tpl = tpl:gsub("\n", "\\n")

  local compiled = load(Renderer.parse(tpl))()

  local buffer = {}
  local function exec(data)
    if type(data) == "function" then
      local args = args or {}
      setmetatable(args, { __index = _G })
      load(string.dump(data), nil, nil, args)(exec)
    else
      table.insert(buffer, tostring(data or ''))
    end
  end
  exec(compiled)

  -- First replace all escaped newlines with actual newlines
  local result = table.concat(buffer, ''):gsub("\\n", "\n")
  -- Then reduce multiple consecutive newlines to a single newline
  result = result:gsub("\n\n+", "\n")
  return vim.trim(result)
end

function Renderer.parse(tpl)
  local str =
      "return function(_)" ..
      "function __(...)" ..
      "_(require('template').escape(...))" ..
      "end " ..
      "_[=[" ..
      tpl:
      gsub("[][]=[][]", ']=]_"%1"_[=['):
      gsub("<%%=", "]=]_("):
      gsub("<%%", "]=]__("):
      gsub("%%>", ")_[=["):
      gsub("<%?", "]=] "):
      gsub("%?>", " _[=[") ..
      "]=] " ..
      "end"

  return str
end

-- Find the plugin root directory
local function get_plugin_root()
  local path = debug.getinfo(1, "S").source:sub(2)
  local lua_dir = vim.fn.fnamemodify(path, ":h:h")
  return vim.fn.fnamemodify(lua_dir, ":h") -- Go up one more level
end

-- Read the Jinja template file
local function read_template(template_path)
  local file = io.open(template_path, "r")
  if not file then
    error("Failed to read template file: " .. template_path)
    return nil
  end

  local content = file:read("*all")
  file:close()
  return content
end

function M.cleanup_indentation(template)
  local res = vim.split(template, "\n")
  for i, line in ipairs(res) do
    res[i] = line:gsub("^%s+", "")
  end
  return table.concat(res, "\n")
end

function M.render_template(template_vars)
  local plugin_root = get_plugin_root()
  local template_path = plugin_root .. "/template/prompt.tpl"

  local template = read_template(template_path)
  if not template then return nil end

  template = M.cleanup_indentation(template)

  return Renderer.render(template, template_vars)
end

function M.extract_tag(tag, text)
  local start_tag = "<" .. tag .. ">"
  local end_tag = "</" .. tag .. ">"

  -- Use pattern matching to find the content between the tags
  -- Make search start_tag and end_tag more robust with pattern escaping
  local pattern = vim.pesc(start_tag) .. "(.-)" .. vim.pesc(end_tag)
  local content = text:match(pattern)

  if content then
    return vim.trim(content)
  end

  -- Fallback to the original method if pattern matching fails
  local query_start = text:find(start_tag)
  local query_end = text:find(end_tag)

  if query_start and query_end then
    -- Extract and trim the content between the tags
    local query_content = text:sub(query_start + #start_tag, query_end - 1)
    return vim.trim(query_content)
  end

  return nil
end

return M
