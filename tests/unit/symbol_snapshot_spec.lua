local assert = require('luassert')

describe('opencode.ui.symbol_snapshot', function()
  local symbol_snapshot
  local original_fn
  local original_api
  local original_filetype
  local original_treesitter
  local original_notify
  local files
  local buffers
  local captures_by_content
  local query_available
  local parser_available
  local notify_calls

  local function fake_node(text, row, col)
    return {
      text = text,
      range = function()
        return row, col, row, col + #text
      end,
    }
  end

  local function set_file(path, lines, captures)
    files[path] = lines
    captures_by_content[table.concat(lines, '\n')] = captures or {}
  end

  before_each(function()
    original_fn = vim.fn
    original_api = vim.api
    original_filetype = vim.filetype
    original_treesitter = vim.treesitter
    original_notify = vim.notify
    files = {}
    buffers = {}
    captures_by_content = {}
    query_available = true
    parser_available = true
    notify_calls = {}

    vim.fn = vim.tbl_extend('force', vim.fn or {}, {
      getcwd = function()
        return '/test/project'
      end,
      filereadable = function(path)
        return files[path] and 1 or 0
      end,
      readfile = function(path)
        if not files[path] then
          error('missing file')
        end
        return files[path]
      end,
      bufnr = function(path)
        return buffers[path] and buffers[path].bufnr or -1
      end,
    })

    vim.api = vim.tbl_extend('force', vim.api or {}, {
      nvim_buf_is_loaded = function(bufnr)
        for _, buffer in pairs(buffers) do
          if buffer.bufnr == bufnr then
            return true
          end
        end
        return false
      end,
      nvim_buf_get_lines = function(bufnr)
        for _, buffer in pairs(buffers) do
          if buffer.bufnr == bufnr then
            return buffer.lines
          end
        end
        return {}
      end,
    })

    vim.filetype = {
      match = function(opts)
        if opts.filename:match('%.lua$') then
          return 'lua'
        end
      end,
    }

    vim.treesitter = {
      language = {
        get_lang = function(filetype)
          return filetype
        end,
      },
      query = {
        get = function(_, name)
          if not query_available or name ~= 'locals' then
            return nil
          end

          return {
            captures = {
              'local.definition.function',
              'local.definition.var',
              'local.reference',
              'local.definition.associated',
            },
            iter_captures = function(_, _, source)
              local content = source
              if type(source) == 'number' then
                for _, buffer in pairs(buffers) do
                  if buffer.bufnr == source then
                    content = table.concat(buffer.lines, '\n')
                  end
                end
              end
              local captures = captures_by_content[content] or {}
              local index = 0
              return function()
                index = index + 1
                local capture = captures[index]
                if capture then
                  return capture.id, capture.node
                end
              end
            end,
          }
        end,
      },
      get_string_parser = function(content)
        if not parser_available then
          error('parser unavailable')
        end
        return {
          parse = function()
            return {
              {
                root = function()
                  return { content = content }
                end,
              },
            }
          end,
        }
      end,
      get_parser = function(bufnr)
        if not parser_available then
          error('parser unavailable')
        end
        return {
          parse = function()
            return {
              {
                root = function()
                  return { bufnr = bufnr }
                end,
              },
            }
          end,
        }
      end,
      get_node_text = function(node)
        return node.text
      end,
    }

    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    package.loaded['opencode.ui.symbol_snapshot'] = nil
    symbol_snapshot = require('opencode.ui.symbol_snapshot')
  end)

  after_each(function()
    vim.fn = original_fn
    vim.api = original_api
    vim.filetype = original_filetype
    vim.treesitter = original_treesitter
    vim.notify = original_notify
    package.loaded['opencode.ui.symbol_snapshot'] = nil
  end)

  it('exports only the frozen public API', function()
    local keys = {}
    for key in pairs(symbol_snapshot) do
      table.insert(keys, key)
    end
    table.sort(keys)

    assert.same({ 'collect', 'has_token', 'targets_for_token', 'token_variants' }, keys)
  end)

  it('collects definition tokens from referenced readable Lua files', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
      { id = 3, node = fake_node('ignored', 0, 0) },
    })

    local snapshot = symbol_snapshot.collect({ { file_path = 'src/main.lua' } })
    local targets = symbol_snapshot.targets_for_token(snapshot, 'foo')

    assert.is_true(symbol_snapshot.has_token(snapshot, 'foo'))
    assert.equal(1, #targets)
    assert.equal('/test/project/src/main.lua', targets[1].path)
    assert.equal(1, targets[1].line)
    assert.equal(16, targets[1].col)
    assert.equal('function', targets[1].kind)
  end)

  it('does not include tokens from files absent from refs', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
    })
    set_file('/test/project/src/other.lua', { 'local function bar() end' }, {
      { id = 1, node = fake_node('bar', 0, 15) },
    })

    local snapshot = symbol_snapshot.collect({ { file_path = 'src/main.lua' } })

    assert.is_true(symbol_snapshot.has_token(snapshot, 'foo'))
    assert.is_false(symbol_snapshot.has_token(snapshot, 'bar'))
  end)

  it('reflects file changes on each collect call', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
    })
    local first = symbol_snapshot.collect({ { file_path = 'src/main.lua' } })

    set_file('/test/project/src/main.lua', { '', '', 'local function bar() end' }, {
      { id = 1, node = fake_node('bar', 2, 15) },
    })
    local second = symbol_snapshot.collect({ { file_path = 'src/main.lua' } })

    assert.is_true(symbol_snapshot.has_token(first, 'foo'))
    assert.is_false(symbol_snapshot.has_token(second, 'foo'))
    local targets = symbol_snapshot.targets_for_token(second, 'bar')
    assert.equal(1, #targets)
    assert.equal(3, targets[1].line)
  end)

  it('uses loaded buffer content before disk content', function()
    set_file('/test/project/src/main.lua', { 'local function disk_name() end' }, {
      { id = 1, node = fake_node('disk_name', 0, 15) },
    })
    buffers['/test/project/src/main.lua'] = {
      bufnr = 7,
      lines = { 'local function buffer_name() end' },
    }
    captures_by_content['local function buffer_name() end'] = {
      { id = 1, node = fake_node('buffer_name', 0, 15) },
    }

    local snapshot = symbol_snapshot.collect({ { file_path = 'src/main.lua' } })

    assert.is_true(symbol_snapshot.has_token(snapshot, 'buffer_name'))
    assert.is_false(symbol_snapshot.has_token(snapshot, 'disk_name'))
  end)

  it('filters empty, short, numeric, and whitespace definition tokens', function()
    set_file('/test/project/src/main.lua', { 'symbols' }, {
      { id = 1, node = fake_node('', 0, 0) },
      { id = 1, node = fake_node('x', 0, 0) },
      { id = 1, node = fake_node('123', 0, 0) },
      { id = 1, node = fake_node('two words', 0, 0) },
      { id = 1, node = fake_node('ok', 0, 0) },
    })

    local snapshot = symbol_snapshot.collect({ { file_path = 'src/main.lua' } })

    assert.is_false(symbol_snapshot.has_token(snapshot, 'x'))
    assert.is_false(symbol_snapshot.has_token(snapshot, '123'))
    assert.is_false(symbol_snapshot.has_token(snapshot, 'two words'))
    assert.is_true(symbol_snapshot.has_token(snapshot, 'ok'))
  end)

  it('skips Lua associated owner captures', function()
    set_file('/test/project/src/client.lua', { 'function OpencodeApiClient:_call() end' }, {
      { id = 4, node = fake_node('OpencodeApiClient', 0, 9) },
      { id = 1, node = fake_node('_call', 0, 27) },
    })

    local snapshot = symbol_snapshot.collect({ { file_path = 'src/client.lua' } })

    assert.is_false(symbol_snapshot.has_token(snapshot, 'OpencodeApiClient'))
    assert.is_true(symbol_snapshot.has_token(snapshot, '_call'))
  end)

  it('silently skips parser and query failures', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
    })

    parser_available = false
    local no_parser = symbol_snapshot.collect({ { file_path = 'src/main.lua' } })
    parser_available = true
    query_available = false
    local no_query = symbol_snapshot.collect({ { file_path = 'src/main.lua' } })

    assert.is_false(symbol_snapshot.has_token(no_parser, 'foo'))
    assert.is_false(symbol_snapshot.has_token(no_query, 'foo'))
    assert.equal(0, #notify_calls)
  end)

  it('returns a new targets array', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
    })

    local snapshot = symbol_snapshot.collect({ { file_path = 'src/main.lua' } })
    local targets = symbol_snapshot.targets_for_token(snapshot, 'foo')
    table.remove(targets, 1)

    assert.equal(1, #symbol_snapshot.targets_for_token(snapshot, 'foo'))
  end)

  it('keeps token variants stable, deduplicated, and whole-token first', function()
    assert.same({ 'foo' }, symbol_snapshot.token_variants('foo'))
    assert.same(
      { 'M.actions.jump_to_file', 'actions.jump_to_file', 'jump_to_file' },
      symbol_snapshot.token_variants('M.actions.jump_to_file')
    )
    assert.same(
      { 'package::Type::method', 'Type::method', 'method' },
      symbol_snapshot.token_variants('package::Type::method')
    )
    assert.same({ 'OpencodeApiClient:_call', '_call' }, symbol_snapshot.token_variants('OpencodeApiClient:_call'))
  end)

  it('keeps token lookup exact', function()
    set_file('/test/project/src/main.lua', { 'local function jump_to_file() end' }, {
      { id = 1, node = fake_node('jump_to_file', 0, 15) },
    })

    local snapshot = symbol_snapshot.collect({ { file_path = 'src/main.lua' } })
    local exact_targets = symbol_snapshot.targets_for_token(snapshot, 'jump_to_file')
    local qualified_targets = symbol_snapshot.targets_for_token(snapshot, 'M.actions.jump_to_file')

    assert.is_true(symbol_snapshot.has_token(snapshot, 'jump_to_file'))
    assert.equal(1, #exact_targets)
    assert.equal('jump_to_file', exact_targets[1].token)
    assert.is_false(symbol_snapshot.has_token(snapshot, 'M.actions.jump_to_file'))
    assert.same({}, qualified_targets)
  end)
end)
