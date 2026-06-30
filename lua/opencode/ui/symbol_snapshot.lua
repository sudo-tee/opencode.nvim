local M = {}

-- A snapshot is a pull-time view over the files referenced by the current
-- conversation. It has no lifecycle, cache, or edit subscriptions; render and
-- keypress paths collect a fresh snapshot when they need one.
local MIN_DEFINITION_TOKEN_LENGTH = 2

local function absolute_path(path)
  if path:sub(1, 1) == '/' then
    return path
  end
  return vim.fn.getcwd() .. '/' .. path
end

local function definition_token(token)
  return type(token) == 'string'
    and #token >= MIN_DEFINITION_TOKEN_LENGTH
    and not token:match('^%d+$')
    and not token:match('%s')
end

local function current_source_root(path, lang)
  local source
  local parser
  local bufnr = vim.fn.bufnr and vim.fn.bufnr(path) or -1

  if bufnr and bufnr > 0 and vim.api.nvim_buf_is_loaded and vim.api.nvim_buf_is_loaded(bufnr) then
    source = bufnr
    local parser_ok, buffer_parser = pcall(function()
      if vim.treesitter and vim.treesitter.get_parser then
        return vim.treesitter.get_parser(bufnr, lang)
      end
    end)
    if parser_ok then
      parser = buffer_parser
    end
  else
    local read_ok, lines = pcall(vim.fn.readfile, path)
    if read_ok and type(lines) == 'table' then
      local content = table.concat(lines, '\n')
      source = content
      local parser_ok, string_parser = pcall(function()
        if vim.treesitter and vim.treesitter.get_string_parser then
          return vim.treesitter.get_string_parser(content, lang)
        end
      end)
      if parser_ok then
        parser = string_parser
      end
    end
  end

  if not parser then
    return nil, nil
  end

  local parse_ok, trees = pcall(function()
    return parser:parse()
  end)
  local tree = parse_ok and trees and trees[1] or nil
  local root_ok, root = pcall(function()
    return tree and tree:root() or nil
  end)
  if not root_ok then
    return nil, nil
  end

  return source, root
end

function M.token_variants(token)
  if type(token) ~= 'string' then
    return {}
  end

  local variants = {}
  local seen = {}

  local function add_variant(value)
    if value ~= '' and not seen[value] then
      seen[value] = true
      table.insert(variants, value)
    end
  end

  add_variant(token)

  local index = 1
  while index <= #token do
    local dot_start, dot_end = token:find('%.', index)
    local colon_start, colon_end = token:find('::', index, true)
    local lua_colon_start, lua_colon_end = token:find(':', index, true)
    if lua_colon_start and token:sub(lua_colon_start, lua_colon_start + 1) == '::' then
      lua_colon_start, lua_colon_end = nil, nil
    end

    local delimiter_start, delimiter_end = dot_start, dot_end
    if colon_start and (not delimiter_start or colon_start < delimiter_start) then
      delimiter_start, delimiter_end = colon_start, colon_end
    end
    if lua_colon_start and (not delimiter_start or lua_colon_start < delimiter_start) then
      delimiter_start, delimiter_end = lua_colon_start, lua_colon_end
    end
    if not delimiter_start then
      break
    end

    add_variant(token:sub(delimiter_end + 1))
    index = delimiter_end + 1
  end

  return variants
end

local function collect_path(snapshot, path)
  local filetype = vim.filetype and vim.filetype.match and vim.filetype.match({ filename = path }) or nil
  if not filetype then
    return
  end

  local lang = filetype
  local lang_ok, parser_lang = pcall(function()
    if vim.treesitter and vim.treesitter.language and vim.treesitter.language.get_lang then
      return vim.treesitter.language.get_lang(filetype)
    end
  end)
  if lang_ok and parser_lang then
    lang = parser_lang
  end

  local query_ok, query = pcall(function()
    if vim.treesitter and vim.treesitter.query and vim.treesitter.query.get then
      return vim.treesitter.query.get(lang, 'locals')
    end
  end)
  if not query_ok or not query then
    return
  end

  local source, root = current_source_root(path, lang)
  if not (source and root) then
    return
  end

  local iter_ok, iter, iter_state, iter_initial = pcall(function()
    return query:iter_captures(root, source, 0, -1)
  end)
  if not iter_ok or not iter then
    return
  end

  for capture_id, node in iter, iter_state, iter_initial do
    local capture = query.captures and query.captures[capture_id]
    local kind = capture and capture:match('^local%.definition%.(.+)$')
    local text_ok, token = pcall(function()
      return vim.treesitter.get_node_text(node, source)
    end)
    if kind and kind ~= 'associated' and text_ok and definition_token(token) then
      local row, col = node:range()
      local targets = snapshot.by_token[token]
      if not targets then
        targets = {}
        snapshot.by_token[token] = targets
      end
      table.insert(targets, {
        token = token,
        path = path,
        line = row + 1,
        col = col + 1,
        kind = kind,
      })
    end
  end
end

function M.collect(refs)
  local snapshot = { by_token = {} }
  local seen_paths = {}
  local paths = {}

  for _, ref in ipairs(refs or {}) do
    if ref.file_path then
      local path = absolute_path(ref.file_path)
      if not seen_paths[path] and vim.fn.filereadable(path) == 1 then
        seen_paths[path] = true
        table.insert(paths, path)
      end
    end
  end

  for _, path in ipairs(paths) do
    collect_path(snapshot, path)
  end

  return snapshot
end

function M.has_token(snapshot, token)
  if not (snapshot and snapshot.by_token) then
    return false
  end

  local targets = snapshot.by_token[token]
  return targets ~= nil and #targets > 0
end

function M.targets_for_token(snapshot, token)
  if not (snapshot and snapshot.by_token) then
    return {}
  end

  local targets = snapshot.by_token[token]
  if not targets then
    return {}
  end

  local copy = {}
  for _, target in ipairs(targets) do
    table.insert(copy, target)
  end
  return copy
end

return M
