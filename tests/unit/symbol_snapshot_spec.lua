local assert = require('luassert')

describe('opencode.ui.symbol_snapshot', function()
  local symbol_snapshot
  local original_fn
  local original_api
  local original_filetype
  local original_treesitter
  local original_notify
  local original_uv
  local original_loop
  local original_lru_cache
  local files
  local file_versions
  local buffers
  local captures_by_content
  local read_counts
  local parse_counts
  local query_available
  local parser_available
  local notify_calls
  local cached_paths

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
    file_versions[path] = (file_versions[path] or 0) + 1
    captures_by_content[table.concat(lines, '\n')] = captures or {}
  end

  before_each(function()
    original_fn = vim.fn
    original_api = vim.api
    original_filetype = vim.filetype
    original_treesitter = vim.treesitter
    original_notify = vim.notify
    original_uv = vim.uv
    original_loop = vim.loop
    original_lru_cache = package.loaded['opencode.lru_cache']
    files = {}
    file_versions = {}
    buffers = {}
    captures_by_content = {}
    read_counts = {}
    parse_counts = {}
    query_available = true
    parser_available = true
    notify_calls = {}
    cached_paths = {}

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
        read_counts[path] = (read_counts[path] or 0) + 1
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
            parse_counts[content] = (parse_counts[content] or 0) + 1
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
            parse_counts[bufnr] = (parse_counts[bufnr] or 0) + 1
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

    local uv = {
      fs_stat = function(path)
        local version = file_versions[path]
        return version and { mtime = { sec = version, nsec = 0 }, size = #table.concat(files[path], '\n') } or nil
      end,
    }
    vim.uv = uv
    vim.loop = uv

    package.loaded['opencode.lru_cache'] = {
      new = function()
        return {
          get = function(_, path)
            return cached_paths[path]
          end,
          set = function(_, path, value)
            cached_paths[path] = value
          end,
        }
      end,
    }
    package.loaded['opencode.ui.symbol_snapshot'] = nil
    symbol_snapshot = require('opencode.ui.symbol_snapshot')
  end)

  after_each(function()
    vim.fn = original_fn
    vim.api = original_api
    vim.filetype = original_filetype
    vim.treesitter = original_treesitter
    vim.notify = original_notify
    vim.uv = original_uv
    vim.loop = original_loop
    package.loaded['opencode.ui.symbol_snapshot'] = nil
    package.loaded['opencode.lru_cache'] = original_lru_cache
  end)

  it('exports only the frozen public API', function()
    local keys = {}
    for key in pairs(symbol_snapshot) do
      table.insert(keys, key)
    end
    table.sort(keys)

    assert.same({ 'new_cycle', 'targets_for_token', 'token_variants' }, keys)
  end)

  it('bounds token lookup to candidate files', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
    })
    set_file('/test/project/src/other.lua', { 'local function bar() end' }, {
      { id = 1, node = fake_node('bar', 0, 15) },
    })

    local cycle = symbol_snapshot.new_cycle()

    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'foo', { '/test/project/src/main.lua' }))
    assert.equal(0, #symbol_snapshot.targets_for_token(cycle, 'bar', { '/test/project/src/main.lua' }))
    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'bar', { '/test/project/src/other.lua' }))
  end)

  it('parses each candidate file once per cycle', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
    })

    local cycle = symbol_snapshot.new_cycle()
    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'foo', { '/test/project/src/main.lua' }))

    set_file('/test/project/src/main.lua', { 'local function bar() end' }, {
      { id = 1, node = fake_node('bar', 0, 15) },
    })

    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'foo', { '/test/project/src/main.lua' }))
    assert.equal(0, #symbol_snapshot.targets_for_token(cycle, 'bar', { '/test/project/src/main.lua' }))
  end)

  it('reads and parses the same candidate file once per cycle', function()
    local path = '/test/project/src/main.lua'
    local content = 'local function foo() end\nlocal function bar() end'
    set_file(path, { 'local function foo() end', 'local function bar() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
      { id = 1, node = fake_node('bar', 1, 15) },
    })

    local cycle = symbol_snapshot.new_cycle()
    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'foo', { path }))
    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'bar', { path }))
    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'foo', { path, path }))

    assert.equal(1, read_counts[path])
    assert.equal(1, parse_counts[content])
  end)

  it('reuses parsed candidate files across cycles until they change', function()
    local path = '/test/project/src/main.lua'
    local content = 'local function foo() end'
    set_file(path, { content }, {
      { id = 1, node = fake_node('foo', 0, 15) },
    })

    local first = symbol_snapshot.new_cycle()
    local second = symbol_snapshot.new_cycle()
    assert.equal(1, #symbol_snapshot.targets_for_token(first, 'foo', { path }))
    assert.equal(1, #symbol_snapshot.targets_for_token(second, 'foo', { path }))
    assert.equal(1, read_counts[path])
    assert.equal(1, parse_counts[content])

    set_file(path, { 'local function bar() end' }, {
      { id = 1, node = fake_node('bar', 0, 15) },
    })
    local changed = symbol_snapshot.new_cycle()
    assert.equal(1, #symbol_snapshot.targets_for_token(changed, 'bar', { path }))
    assert.equal(2, read_counts[path])
  end)

  it('collects definition tokens from referenced readable Lua files', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
      { id = 3, node = fake_node('ignored', 0, 0) },
    })

    local cycle = symbol_snapshot.new_cycle()
    local targets = symbol_snapshot.targets_for_token(cycle, 'foo', { '/test/project/src/main.lua' })

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

    local cycle = symbol_snapshot.new_cycle()

    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'foo', { '/test/project/src/main.lua' }))
    assert.equal(0, #symbol_snapshot.targets_for_token(cycle, 'bar', { '/test/project/src/main.lua' }))
  end)

  it('reflects file changes on each collect call', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
    })
    local first = symbol_snapshot.new_cycle()
    assert.equal(1, #symbol_snapshot.targets_for_token(first, 'foo', { '/test/project/src/main.lua' }))

    set_file('/test/project/src/main.lua', { '', '', 'local function bar() end' }, {
      { id = 1, node = fake_node('bar', 2, 15) },
    })
    local second = symbol_snapshot.new_cycle()

    assert.equal(1, #symbol_snapshot.targets_for_token(first, 'foo', { '/test/project/src/main.lua' }))
    assert.equal(0, #symbol_snapshot.targets_for_token(second, 'foo', { '/test/project/src/main.lua' }))
    local targets = symbol_snapshot.targets_for_token(second, 'bar', { '/test/project/src/main.lua' })
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

    local cycle = symbol_snapshot.new_cycle()

    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'buffer_name', { '/test/project/src/main.lua' }))
    assert.equal(0, #symbol_snapshot.targets_for_token(cycle, 'disk_name', { '/test/project/src/main.lua' }))
  end)

  it('filters empty, short, numeric, and whitespace definition tokens', function()
    set_file('/test/project/src/main.lua', { 'symbols' }, {
      { id = 1, node = fake_node('', 0, 0) },
      { id = 1, node = fake_node('x', 0, 0) },
      { id = 1, node = fake_node('123', 0, 0) },
      { id = 1, node = fake_node('two words', 0, 0) },
      { id = 1, node = fake_node('ok', 0, 0) },
    })

    local cycle = symbol_snapshot.new_cycle()

    assert.equal(0, #symbol_snapshot.targets_for_token(cycle, 'x', { '/test/project/src/main.lua' }))
    assert.equal(0, #symbol_snapshot.targets_for_token(cycle, '123', { '/test/project/src/main.lua' }))
    assert.equal(0, #symbol_snapshot.targets_for_token(cycle, 'two words', { '/test/project/src/main.lua' }))
    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'ok', { '/test/project/src/main.lua' }))
  end)

  it('skips Lua associated owner captures', function()
    set_file('/test/project/src/client.lua', { 'function OpencodeApiClient:_call() end' }, {
      { id = 4, node = fake_node('OpencodeApiClient', 0, 9) },
      { id = 1, node = fake_node('_call', 0, 27) },
    })

    local cycle = symbol_snapshot.new_cycle()

    assert.equal(0, #symbol_snapshot.targets_for_token(cycle, 'OpencodeApiClient', { '/test/project/src/client.lua' }))
    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, '_call', { '/test/project/src/client.lua' }))
  end)

  it('silently skips parser and query failures', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
    })

    parser_available = false
    local no_parser = symbol_snapshot.new_cycle()
    assert.equal(0, #symbol_snapshot.targets_for_token(no_parser, 'foo', { '/test/project/src/main.lua' }))
    parser_available = true
    query_available = false
    local no_query = symbol_snapshot.new_cycle()

    assert.equal(0, #symbol_snapshot.targets_for_token(no_query, 'foo', { '/test/project/src/main.lua' }))
    assert.equal(0, #notify_calls)
  end)

  it('returns a new targets array', function()
    set_file('/test/project/src/main.lua', { 'local function foo() end' }, {
      { id = 1, node = fake_node('foo', 0, 15) },
    })

    local cycle = symbol_snapshot.new_cycle()
    local targets = symbol_snapshot.targets_for_token(cycle, 'foo', { '/test/project/src/main.lua' })
    table.remove(targets, 1)

    assert.equal(1, #symbol_snapshot.targets_for_token(cycle, 'foo', { '/test/project/src/main.lua' }))
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

    local cycle = symbol_snapshot.new_cycle()
    local exact_targets = symbol_snapshot.targets_for_token(cycle, 'jump_to_file', { '/test/project/src/main.lua' })
    local qualified_targets =
      symbol_snapshot.targets_for_token(cycle, 'M.actions.jump_to_file', { '/test/project/src/main.lua' })

    assert.equal(1, #exact_targets)
    assert.equal('jump_to_file', exact_targets[1].token)
    assert.equal(1, #qualified_targets)
    assert.equal('jump_to_file', qualified_targets[1].token)
  end)
end)
