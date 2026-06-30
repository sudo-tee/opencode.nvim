local assert = require('luassert')
local stub = require('luassert.stub')

local navigation = require('opencode.ui.navigation')
local config = require('opencode.config')
local ui = require('opencode.ui.ui')
local output_window = require('opencode.ui.output_window')
local renderer = require('opencode.ui.renderer')
local state = require('opencode.state')

local existing_path = 'lua/opencode/ui/navigation.lua'

local function set_cursor_on(win, line_num, line, needle)
  local start_pos = assert(line:find(needle, 1, true))
  vim.api.nvim_win_set_cursor(win, { line_num, start_pos - 1 })
end

local function add_diff_extmark(buf, line_idx, gutter, sign)
  vim.api.nvim_buf_set_extmark(buf, output_window.namespace, line_idx, 0, {
    virt_text = {
      { gutter, 'LineNr' },
      { sign, 'DiffAdd' },
      { ' ', 'Normal' },
    },
    virt_text_pos = 'inline',
  })
end

describe('output token navigation', function()
  local output_buf, output_win, input_buf, input_win, code_buf, code_win
  local original_windows, original_code_win, original_code_buf, original_config

  before_each(function()
    original_windows = state.store.get('windows')
    original_code_win = state.store.get('last_code_win_before_opencode')
    original_code_buf = state.store.get('current_code_buf')
    original_config = vim.deepcopy(config.values)
    state.ui.clear_hidden_window_state()

    code_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, { 'alpha', 'beta', 'gamma' })
    code_win = vim.api.nvim_open_win(code_buf, true, {
      relative = 'editor',
      width = 40,
      height = 5,
      row = 0,
      col = 0,
    })

    output_buf = vim.api.nvim_create_buf(false, true)
    output_win = vim.api.nvim_open_win(output_buf, true, {
      relative = 'editor',
      width = 80,
      height = 8,
      row = 6,
      col = 0,
    })

    state.ui.set_windows({ output_buf = output_buf, output_win = output_win })
    state.ui.set_last_code_window(code_win)
  end)

  after_each(function()
    state.ui.clear_hidden_window_state()
    pcall(vim.api.nvim_win_close, output_win, true)
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, code_win, true)
    pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })

    if original_windows ~= nil then
      state.ui.set_windows(original_windows)
    else
      state.ui.clear_windows()
    end
    state.ui.set_last_code_window(original_code_win)
    state.ui.set_current_code_buf(original_code_buf)
    config.values = original_config
  end)

  it('resolves an ordinary visible path token at the cursor', function()
    local line = 'open ' .. existing_path
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { line })
    set_cursor_on(output_win, 1, line, existing_path)

    local target = navigation.resolve_target_at_cursor()

    assert.same({ path = existing_path }, target)
  end)

  it('resolves path line and column from the cursor token', function()
    local token = existing_path .. ':12:3'
    local line = 'open ' .. token
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { line })
    set_cursor_on(output_win, 1, line, token)

    local target = navigation.resolve_target_at_cursor()

    assert.same({ path = existing_path, line = 12, col = 3 }, target)
  end)

  it('resolves backtick, file uri, markdown, and tool-path forms', function()
    local cases = {
      { '`' .. existing_path .. ':4`', existing_path, 4 },
      { 'file://' .. existing_path .. ':5', existing_path, 5 },
      { '[`' .. existing_path .. '`](file)', existing_path, nil },
      { '**tool** `' .. existing_path .. '`', existing_path, nil },
    }

    for _, case in ipairs(cases) do
      vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { case[1] })
      set_cursor_on(output_win, 1, case[1], existing_path)

      local target = navigation.resolve_target_at_cursor()

      assert.same({ path = case[2], line = case[3] }, target)
    end
  end)

  it('uses only the path token under the cursor on multi-token lines', function()
    local first = 'lua/opencode/api.lua'
    local second = existing_path .. ':7'
    local line = first .. ' then ' .. second
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { line })

    set_cursor_on(output_win, 1, line, second)
    assert.same({ path = existing_path, line = 7 }, navigation.resolve_target_at_cursor())

    vim.api.nvim_win_set_cursor(output_win, { 1, #first + 2 })
    assert.is_nil(navigation.resolve_target_at_cursor())
  end)

  it('uses diff extmark new-file line for add and context rows', function()
    local header = '[`' .. existing_path .. '`](file)'
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { header, '+ added', ' context' })

    add_diff_extmark(output_buf, 1, ' 42 ', '+')
    vim.api.nvim_win_set_cursor(output_win, { 2, 0 })
    assert.same({ path = existing_path, line = 42 }, navigation.resolve_target_at_cursor())

    add_diff_extmark(output_buf, 2, ' 43 ', ' ')
    vim.api.nvim_win_set_cursor(output_win, { 3, 0 })
    assert.same({ path = existing_path, line = 43 }, navigation.resolve_target_at_cursor())
  end)

  it('does not jump deleted diff rows to old-file lines', function()
    local header = '[`' .. existing_path .. '`](file)'
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { header, '- deleted' })
    add_diff_extmark(output_buf, 1, ' 9 ', '-')
    vim.api.nvim_win_set_cursor(output_win, { 2, 0 })

    assert.is_nil(navigation.resolve_target_at_cursor())
  end)

  it('keeps gf file-only and silent on missing path or plain text', function()
    local notify_stub = stub(vim, 'notify')
    local load_stub = stub(renderer, 'load_all_messages')
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { '`missing/not_here.lua`', 'plain text' })
    set_cursor_on(output_win, 1, '`missing/not_here.lua`', 'missing/not_here.lua')
    local before_win = vim.api.nvim_get_current_win()
    local before_cursor = vim.api.nvim_win_get_cursor(output_win)

    navigation.jump_to_file_at_cursor()

    assert.equals(before_win, vim.api.nvim_get_current_win())
    assert.same(before_cursor, vim.api.nvim_win_get_cursor(output_win))
    assert.stub(notify_stub).was_not_called()
    assert.stub(load_stub).was_not_called()

    vim.api.nvim_win_set_cursor(output_win, { 2, 0 })
    navigation.jump_to_file_at_cursor()
    assert.equals(before_win, vim.api.nvim_get_current_win())
    assert.stub(notify_stub).was_not_called()
    assert.stub(load_stub).was_not_called()

    notify_stub:revert()
    load_stub:revert()
  end)

  it('uses symbol fallback only after file resolution misses', function()
    local original_reference_picker = package.loaded['opencode.ui.reference_picker']
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local original_navigate_to_location = navigation.navigate_to_location
    local navigated

    package.loaded['opencode.ui.reference_picker'] = {
      collect_refs = function()
        return { { file_path = 'src/main.lua' } }
      end,
    }
    package.loaded['opencode.ui.symbol_snapshot'] = {
      collect = function(refs)
        assert.same({ { file_path = 'src/main.lua' } }, refs)
        return { by_token = {} }
      end,
      token_variants = function(token)
        assert.equal('M.actions.jump_to_file', token)
        return { 'M.actions.jump_to_file', 'actions.jump_to_file', 'jump_to_file' }
      end,
      targets_for_token = function(_, token)
        if token == 'jump_to_file' then
          return { { token = 'jump_to_file', path = existing_path, line = 12, col = 3 } }
        end
        return {}
      end,
    }
    navigation.navigate_to_location = function(path, line, col)
      navigated = { path = path, line = line, col = col }
    end

    local line = 'call M.actions.jump_to_file now'
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { line })
    set_cursor_on(output_win, 1, line, 'M.actions.jump_to_file')

    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate_to_location
    package.loaded['opencode.ui.reference_picker'] = original_reference_picker
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot

    assert.same({ path = existing_path, line = 12, col = 3 }, navigated)
  end)

  it('offers multiple symbol fallback targets through the base picker', function()
    local original_reference_picker = package.loaded['opencode.ui.reference_picker']
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local original_base_picker = package.loaded['opencode.ui.base_picker']
    local original_navigate_to_location = navigation.navigate_to_location
    local picked_opts
    local navigated
    local targets = {
      { token = 'foo', path = existing_path, line = 1, col = 1, kind = 'function' },
      { token = 'foo', path = existing_path, line = 2, col = 1 },
    }

    package.loaded['opencode.ui.reference_picker'] = {
      collect_refs = function()
        return { { file_path = existing_path } }
      end,
    }
    package.loaded['opencode.ui.symbol_snapshot'] = {
      collect = function()
        return { by_token = {} }
      end,
      token_variants = function(token)
        return { token }
      end,
      targets_for_token = function()
        return targets
      end,
    }
    package.loaded['opencode.ui.base_picker'] = {
      create_time_picker_item = function(text)
        return { text = text }
      end,
      pick = function(opts)
        picked_opts = opts
        opts.callback(opts.items[2])
      end,
    }
    navigation.navigate_to_location = function(path, line, col)
      navigated = { path = path, line = line, col = col }
    end

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'foo' })
    vim.api.nvim_win_set_cursor(output_win, { 1, 0 })

    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate_to_location
    package.loaded['opencode.ui.reference_picker'] = original_reference_picker
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot
    package.loaded['opencode.ui.base_picker'] = original_base_picker

    assert.same(targets, picked_opts.items)
    assert.equal('file', picked_opts.preview)
    assert.equal('Symbol References (2)', picked_opts.title)
    assert.equal(
      'foo [function] ' .. existing_path .. ':1:1',
      picked_opts.format_fn(targets[1], 80):to_string():match('^%s*(.-)%s*$')
    )
    assert.same({ path = existing_path, line = 2, col = 1 }, navigated)
  end)

  it('uses the symbol before a trailing prose colon', function()
    local original_reference_picker = package.loaded['opencode.ui.reference_picker']
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local original_navigate_to_location = navigation.navigate_to_location
    local navigated

    package.loaded['opencode.ui.reference_picker'] = {
      collect_refs = function()
        return { { file_path = existing_path } }
      end,
    }
    package.loaded['opencode.ui.symbol_snapshot'] = {
      collect = function()
        return { by_token = {} }
      end,
      token_variants = function(token)
        assert.equal('foo', token)
        return { token }
      end,
      targets_for_token = function(_, token)
        if token == 'foo' then
          return { { token = 'foo', path = existing_path, line = 3, col = 1 } }
        end
        return {}
      end,
    }
    navigation.navigate_to_location = function(path, line, col)
      navigated = { path = path, line = line, col = col }
    end

    local line = 'foo: call this'
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { line })
    set_cursor_on(output_win, 1, line, 'foo')

    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate_to_location
    package.loaded['opencode.ui.reference_picker'] = original_reference_picker
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot

    assert.same({ path = existing_path, line = 3, col = 1 }, navigated)
  end)

  it('does not treat a prose colon as part of the symbol token', function()
    local original_reference_picker = package.loaded['opencode.ui.reference_picker']
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local notify_stub = stub(vim, 'notify')

    package.loaded['opencode.ui.reference_picker'] = {
      collect_refs = function()
        return { { file_path = existing_path } }
      end,
    }
    package.loaded['opencode.ui.symbol_snapshot'] = {
      collect = function()
        return { by_token = {} }
      end,
      token_variants = function(token)
        error('symbol fallback should not run for cursor on prose colon: ' .. token)
      end,
      targets_for_token = function()
        return {}
      end,
    }

    local line = 'Note: plain text'
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { line })
    set_cursor_on(output_win, 1, line, ':')

    navigation.jump_to_target_at_cursor()

    package.loaded['opencode.ui.reference_picker'] = original_reference_picker
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot

    assert.stub(notify_stub).was_not_called()
    notify_stub:revert()
  end)

  it('notifies on symbol fallback miss without moving the cursor or window', function()
    local original_reference_picker = package.loaded['opencode.ui.reference_picker']
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local notify_stub = stub(vim, 'notify')

    package.loaded['opencode.ui.reference_picker'] = {
      collect_refs = function()
        return {}
      end,
    }
    package.loaded['opencode.ui.symbol_snapshot'] = {
      collect = function()
        return { by_token = {} }
      end,
      token_variants = function(token)
        return { token }
      end,
      targets_for_token = function()
        return {}
      end,
    }

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'plain' })
    vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
    local before_win = vim.api.nvim_get_current_win()
    local before_cursor = vim.api.nvim_win_get_cursor(output_win)

    navigation.jump_to_target_at_cursor()

    package.loaded['opencode.ui.reference_picker'] = original_reference_picker
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot

    assert.equals(before_win, vim.api.nvim_get_current_win())
    assert.same(before_cursor, vim.api.nvim_win_get_cursor(output_win))
    assert.stub(notify_stub).was_called_with('No symbol target found: plain', vim.log.levels.INFO)

    notify_stub:revert()
  end)

  it('opens explicit locations with 1-based col converted and clamped', function()
    navigation.navigate_to_location(existing_path, 9999, 9999)

    assert.equals(code_win, vim.api.nvim_get_current_win())
    local cursor = vim.api.nvim_win_get_cursor(code_win)
    local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(code_win))
    assert.equals(line_count, cursor[1])
    local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(code_win), line_count - 1, line_count, false)[1]
    assert.equals(math.max(#line - 1, 0), cursor[2])
  end)

  it('keeps <CR> file-first without reading symbol fallback state', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local original_navigate_to_location = navigation.navigate_to_location
    local navigated

    package.loaded['opencode.ui.symbol_snapshot'] = {
      collect = function()
        error('symbol fallback should not run when a file target exists')
      end,
    }
    navigation.navigate_to_location = function(path, line, col)
      navigated = { path = path, line = line, col = col }
    end

    local line = 'open ' .. existing_path .. ':7:2'
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { line })
    set_cursor_on(output_win, 1, line, existing_path)

    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate_to_location
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot

    assert.same({ path = existing_path, line = 7, col = 2 }, navigated)
  end)

  it('hides current-mode output before opening a target so output view can be restored', function()
    config.values.ui.position = 'current'
    config.values.ui.persist_state = true

    input_buf = vim.api.nvim_create_buf(false, true)
    input_win = vim.api.nvim_open_win(input_buf, false, {
      relative = 'editor',
      width = 40,
      height = 3,
      row = 15,
      col = 0,
    })

    vim.api.nvim_win_set_buf(code_win, output_buf)
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'out 1', 'out 2', 'out 3' })
    vim.api.nvim_set_current_win(code_win)
    vim.api.nvim_win_set_cursor(code_win, { 2, 3 })

    state.ui.set_windows({
      input_buf = input_buf,
      input_win = input_win,
      output_buf = output_buf,
      output_win = code_win,
    })
    state.ui.set_last_code_window(code_win)
    state.ui.set_current_code_buf(code_buf)

    navigation.navigate_to_location(existing_path, 1, 1)

    assert.is_true(ui.has_hidden_buffers())
    assert.equals('hidden', state.ui.get_window_state().status)
    assert.is_true(vim.api.nvim_win_is_valid(code_win))
    assert.is_not_equal(output_buf, vim.api.nvim_win_get_buf(code_win))

    assert.is_true(ui.restore_hidden_windows())
    vim.wait(200, function()
      local pos = vim.api.nvim_win_get_cursor(state.windows.output_win)
      return pos[1] == 2 and pos[2] == 3
    end, 10)

    assert.equals(output_buf, vim.api.nvim_win_get_buf(state.windows.output_win))
    assert.same({ 2, 3 }, vim.api.nvim_win_get_cursor(state.windows.output_win))
  end)
end)
