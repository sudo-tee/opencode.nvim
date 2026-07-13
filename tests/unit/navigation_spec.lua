local assert = require('luassert')
local stub = require('luassert.stub')

local navigation = require('opencode.ui.navigation')
local config = require('opencode.config')
local ui = require('opencode.ui.ui')
local renderer = require('opencode.ui.renderer')
local state = require('opencode.state')

local existing_path = 'lua/opencode/ui/navigation.lua'

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

  it('resolves the rendered target under the cursor', function()
    local target = { kind = 'file', path = existing_path, line = 12, col = 3 }
    local target_stub = stub(renderer, 'get_target_at_position').returns(target)
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'open target' })
    vim.api.nvim_win_set_cursor(output_win, { 1, 4 })

    assert.same(target, navigation.resolve_target_at_cursor())
    assert.stub(target_stub).was_called_with(1, 4)

    target_stub:revert()
  end)

  it('executes file and diff rendered targets on <CR>', function()
    local original_navigate_to_location = navigation.navigate_to_location
    local navigated = {}
    local targets = {
      { kind = 'file', path = existing_path, line = 7, col = 2 },
      { kind = 'diff', path = existing_path, line = 42 },
    }
    local index = 0
    local target_stub = stub(renderer, 'get_target_at_position').invokes(function()
      index = index + 1
      return targets[index]
    end)
    navigation.navigate_to_location = function(path, line, col)
      navigated[#navigated + 1] = { path = path, line = line, col = col }
      return true
    end
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'file', 'diff' })

    vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
    navigation.jump_to_target_at_cursor()
    vim.api.nvim_win_set_cursor(output_win, { 2, 0 })
    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate_to_location
    target_stub:revert()

    assert.same({
      { path = existing_path, line = 7, col = 2 },
      { path = existing_path, line = 42, col = nil },
    }, navigated)
  end)

  it('leaves target lifecycle to render invalidation when a rendered file target fails', function()
    local original_navigate_to_location = navigation.navigate_to_location
    local dirty_stub = stub(renderer, 'mark_part_dirty')
    local target_stub = stub(renderer, 'get_target_at_position').returns({
      kind = 'file',
      path = 'missing.lua',
      part_id = 'part_1',
      message_id = 'msg_1',
    })
    navigation.navigate_to_location = function()
      return false
    end

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'missing.lua' })
    vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate_to_location
    target_stub:revert()

    assert.stub(dirty_stub).was_not_called()
    dirty_stub:revert()
  end)

  it('does not dirty the source part after a rendered diff target opens', function()
    local original_navigate_to_location = navigation.navigate_to_location
    local dirty_stub = stub(renderer, 'mark_part_dirty')
    local target_stub = stub(renderer, 'get_target_at_position').returns({
      kind = 'diff',
      path = existing_path,
      part_id = 'part_1',
      message_id = 'msg_1',
    })
    navigation.navigate_to_location = function()
      return true
    end

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { existing_path })
    vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate_to_location
    target_stub:revert()

    assert.stub(dirty_stub).was_not_called()
    dirty_stub:revert()
  end)

  it('keypress consumes rendered targets instead of deriving targets from screen text', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local original_navigate_to_location = navigation.navigate_to_location
    local navigated = {}
    local target_stub = stub(renderer, 'get_target_at_position').returns(nil)

    package.loaded['opencode.ui.symbol_snapshot'] = {
      new_cycle = function()
        error('symbol target resolution must not run without a rendered target')
      end,
      targets_for_token = function()
        error('symbol target resolution must not run without a rendered target')
      end,
    }
    navigation.navigate_to_location = function(path, line, col)
      navigated[#navigated + 1] = { path = path, line = line, col = col }
      return true
    end
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { '`' .. existing_path .. '`', 'foo' })
    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
      navigation.jump_to_target_at_cursor()
      vim.api.nvim_win_set_cursor(output_win, { 2, 1 })
      navigation.jump_to_file_at_cursor()
    end)

    navigation.navigate_to_location = original_navigate_to_location
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot
    target_stub:revert()

    assert.is_true(ok, err)
    assert.are.same({}, navigated)
    assert.stub(target_stub).was_called(2)
    assert.are.same(1, target_stub.calls[1].refs[1])
    assert.are.same(0, target_stub.calls[1].refs[2])
    assert.are.same(2, target_stub.calls[2].refs[1])
    assert.are.same(1, target_stub.calls[2].refs[2])
    assert.are.same('function', type(target_stub.calls[2].refs[3]))
  end)

  it('keeps gf file-and-diff only', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local original_navigate_to_location = navigation.navigate_to_location
    local navigated = {}
    local targets = {
      { kind = 'diff', path = existing_path, line = 9 },
      {
        kind = 'symbol',
        token = 'foo',
        candidate_files = { existing_path },
        part_id = 'part_1',
        message_id = 'msg_1',
      },
    }
    local index = 0
    local target_stub = stub(renderer, 'get_target_at_position').invokes(function(_, _, filter)
      index = index + 1
      local target = targets[index]
      if filter and not filter(target) then
        return nil
      end
      return target
    end)
    package.loaded['opencode.ui.symbol_snapshot'] = {
      new_cycle = function()
        error('gf must not resolve symbol targets')
      end,
      targets_for_token = function()
        error('gf must not resolve symbol targets')
      end,
    }
    navigation.navigate_to_location = function(path, line, col)
      navigated[#navigated + 1] = { path = path, line = line, col = col }
      return true
    end

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'diff', 'foo' })
    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
      navigation.jump_to_file_at_cursor()
      vim.api.nvim_win_set_cursor(output_win, { 2, 0 })
      navigation.jump_to_file_at_cursor()
    end)

    navigation.navigate_to_location = original_navigate_to_location
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot
    target_stub:revert()

    assert.is_true(ok, err)
    assert.same({ { path = existing_path, line = 9, col = nil } }, navigated)
  end)

  it('executes a symbol rendered target with current file contents', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local original_navigate_to_location = navigation.navigate_to_location
    local navigated
    local target_stub = stub(renderer, 'get_target_at_position').returns({
      kind = 'symbol',
      token = 'foo',
      candidate_files = { existing_path },
      part_id = 'part_1',
      message_id = 'msg_1',
    })
    package.loaded['opencode.ui.symbol_snapshot'] = {
      new_cycle = function()
        return { cycle = 'fresh' }
      end,
      targets_for_token = function(cycle, token, candidate_files)
        assert.same({ cycle = 'fresh' }, cycle)
        assert.equal('foo', token)
        assert.same({ existing_path }, candidate_files)
        return { { token = 'foo', path = existing_path, line = 3, col = 1 } }
      end,
    }
    navigation.navigate_to_location = function(path, line, col)
      navigated = { path = path, line = line, col = col }
      return true
    end
    state.renderer.set_messages(setmetatable({}, {
      __pairs = function()
        error('symbol target navigation must not scan state.messages')
      end,
      __ipairs = function()
        error('symbol target navigation must not scan state.messages')
      end,
    }))

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'foo' })
    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
      navigation.jump_to_target_at_cursor()
    end)

    navigation.navigate_to_location = original_navigate_to_location
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot
    state.renderer.set_messages({})
    target_stub:revert()

    assert.is_true(ok, err)
    assert.same({ path = existing_path, line = 3, col = 1 }, navigated)
  end)

  it('reports symbol misses without mutating target lifecycle', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local notify_stub = stub(vim, 'notify')
    local dirty_stub = stub(renderer, 'mark_part_dirty')
    local target_stub = stub(renderer, 'get_target_at_position').returns({
      kind = 'symbol',
      token = 'foo',
      candidate_files = { existing_path },
      part_id = 'part_1',
      message_id = 'msg_1',
    })
    package.loaded['opencode.ui.symbol_snapshot'] = {
      new_cycle = function()
        return {}
      end,
      targets_for_token = function()
        return {}
      end,
    }

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'foo' })
    vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
    navigation.jump_to_target_at_cursor()

    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot
    target_stub:revert()

    assert.stub(notify_stub).was_called_with('No symbol target found: foo', vim.log.levels.INFO)
    assert.stub(dirty_stub).was_not_called()

    notify_stub:revert()
    dirty_stub:revert()
  end)

  it('offers multiple symbol rendered targets through the base picker', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local original_base_picker = package.loaded['opencode.ui.base_picker']
    local original_navigate_to_location = navigation.navigate_to_location
    local picked_opts
    local navigated
    local targets = {
      { token = 'foo', path = existing_path, line = 1, col = 1, kind = 'function' },
      { token = 'foo', path = existing_path, line = 2, col = 1 },
    }
    local target_stub = stub(renderer, 'get_target_at_position').returns({
      kind = 'symbol',
      token = 'foo',
      candidate_files = { existing_path },
      part_id = 'part_1',
      message_id = 'msg_1',
    })

    package.loaded['opencode.ui.symbol_snapshot'] = {
      new_cycle = function()
        return {}
      end,
      targets_for_token = function()
        return targets
      end,
    }
    package.loaded['opencode.ui.base_picker'] = {
      create_time_picker_item = function(text)
        return {
          text = text,
          to_string = function(self)
            return self.text
          end,
        }
      end,
      pick = function(opts)
        picked_opts = opts
        opts.callback(opts.items[2])
      end,
    }
    navigation.navigate_to_location = function(path, line, col)
      navigated = { path = path, line = line, col = col }
      return true
    end

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'foo' })
    vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate_to_location
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot
    package.loaded['opencode.ui.base_picker'] = original_base_picker
    target_stub:revert()

    assert.same(targets, picked_opts.items)
    assert.equal('file', picked_opts.preview)
    assert.equal('Symbol References (2)', picked_opts.title)
    assert.equal(
      'foo [function] ' .. existing_path .. ':1:1',
      picked_opts.format_fn(targets[1], 80):to_string():match('^%s*(.-)%s*$')
    )
    assert.same({ path = existing_path, line = 2, col = 1 }, navigated)
  end)

  it('does not mutate target lifecycle when a picked symbol target fails to open', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local original_base_picker = package.loaded['opencode.ui.base_picker']
    local original_navigate_to_location = navigation.navigate_to_location
    local dirty_stub = stub(renderer, 'mark_part_dirty')
    local source_target = {
      kind = 'symbol',
      token = 'foo',
      candidate_files = { existing_path },
      part_id = 'part_1',
      message_id = 'msg_1',
    }
    local targets = {
      { token = 'foo', path = existing_path, line = 1, col = 1 },
      { token = 'foo', path = existing_path, line = 2, col = 1 },
    }
    local target_stub = stub(renderer, 'get_target_at_position').returns(source_target)

    package.loaded['opencode.ui.symbol_snapshot'] = {
      new_cycle = function()
        return {}
      end,
      targets_for_token = function()
        return targets
      end,
    }
    package.loaded['opencode.ui.base_picker'] = {
      create_time_picker_item = function(text)
        return {
          text = text,
          to_string = function(self)
            return self.text
          end,
        }
      end,
      pick = function(opts)
        opts.callback(opts.items[2])
      end,
    }
    navigation.navigate_to_location = function()
      return false
    end

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'foo' })
    vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate_to_location
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot
    package.loaded['opencode.ui.base_picker'] = original_base_picker
    target_stub:revert()

    assert.stub(dirty_stub).was_not_called()
    dirty_stub:revert()
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

  it('keeps <CR> file-first without running the symbol resolver', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local original_navigate_to_location = navigation.navigate_to_location
    local navigated
    local target_stub = stub(renderer, 'get_target_at_position').returns({
      kind = 'file',
      path = existing_path,
      line = 7,
      col = 2,
    })

    package.loaded['opencode.ui.symbol_snapshot'] = {
      new_cycle = function()
        error('symbol resolver should not run when a file target exists')
      end,
    }
    navigation.navigate_to_location = function(path, line, col)
      navigated = { path = path, line = line, col = col }
      return true
    end

    local line = 'open ' .. existing_path .. ':7:2'
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(output_win, { 1, 0 })

    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate_to_location
    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot
    target_stub:revert()

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

describe('navigation jumplist preservation', function()
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

  it('marks the output cursor before goto_next_message moves', function()
    local renderer = require('opencode.ui.renderer')
    local ctx = require('opencode.ui.renderer.ctx')
    state.renderer.set_messages({
      { info = { id = 'm1', role = 'user' } },
      { info = { id = 'm2', role = 'assistant' } },
    })
    ctx.render_state:set_message({ info = { id = 'm1', role = 'user' } }, 1, 1)
    ctx.render_state:set_message({ info = { id = 'm2', role = 'assistant' } }, 20, 20)
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, vim.fn['repeat']({ 'line' }, 40))
    vim.api.nvim_win_set_cursor(output_win, { 5, 0 })
    vim.api.nvim_buf_set_mark(output_buf, "'", 1, 0, {})

    navigation.goto_next_message()

    local mark = vim.api.nvim_buf_get_mark(output_buf, "'")
    assert.equals(5, mark[1])
    assert.equals(0, mark[2])
  end)

  it('marks the output cursor before goto_prev_message moves', function()
    local renderer = require('opencode.ui.renderer')
    local ctx = require('opencode.ui.renderer.ctx')
    state.renderer.set_messages({
      { info = { id = 'm1', role = 'user' } },
      { info = { id = 'm2', role = 'assistant' } },
    })
    ctx.render_state:set_message({ info = { id = 'm1', role = 'user' } }, 1, 1)
    ctx.render_state:set_message({ info = { id = 'm2', role = 'assistant' } }, 20, 20)
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, vim.fn['repeat']({ 'line' }, 40))
    vim.api.nvim_win_set_cursor(output_win, { 31, 0 })
    vim.api.nvim_buf_set_mark(output_buf, "'", 1, 0, {})

    navigation.goto_prev_message()

    local mark = vim.api.nvim_buf_get_mark(output_buf, "'")
    assert.equals(31, mark[1])
    assert.equals(0, mark[2])
  end)

  it('marks the output cursor before jumping to a rendered file target', function()
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { existing_path })
    vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
    vim.api.nvim_buf_set_mark(output_buf, "'", 1, 0, {})
    local original_navigate = navigation.navigate_to_location
    navigation.navigate_to_location = function()
      return true
    end
    stub(renderer, 'get_target_at_position').returns({
      kind = 'file',
      path = existing_path,
      line = 1,
      col = 1,
    })

    navigation.jump_to_target_at_cursor()

    navigation.navigate_to_location = original_navigate
    local mark = vim.api.nvim_buf_get_mark(output_buf, "'")
    assert.equals(1, mark[1])
    assert.equals(0, mark[2])
  end)
end)

describe('navigation hidden-messages-notice handling', function()
  local output_buf, output_win
  local original_windows

  before_each(function()
    original_windows = state.store.get('windows')
    state.ui.clear_hidden_window_state()

    output_buf = vim.api.nvim_create_buf(false, true)
    output_win = vim.api.nvim_open_win(output_buf, true, {
      relative = 'editor',
      width = 80,
      height = 20,
      row = 0,
      col = 0,
    })
    state.ui.set_windows({ output_buf = output_buf, output_win = output_win })
  end)

  after_each(function()
    state.ui.clear_hidden_window_state()
    pcall(vim.api.nvim_win_close, output_win, true)
    pcall(vim.api.nvim_buf_delete, output_buf, { force = true })

    if original_windows ~= nil then
      state.ui.set_windows(original_windows)
    else
      state.ui.clear_windows()
    end
  end)

  it('does not jump [[ to the hidden-messages notice when max_messages truncates', function()
    local ctx = require('opencode.ui.renderer.ctx')
    -- Simulate `on_message_updated` appending the hidden notice to `state.messages` after a `max_messages` truncation.
    state.renderer.set_messages({
      { info = { id = 'real_old', role = 'assistant', sessionID = 's1' } },
      { info = { id = 'real_mid', role = 'user', sessionID = 's1' } },
      { info = { id = '__opencode_hidden_messages_notice__', role = 'system', sessionID = 's1' } },
    })
    ctx.render_state:set_message(
      { info = { id = '__opencode_hidden_messages_notice__', role = 'system', sessionID = 's1' } },
      1,
      2
    )
    ctx.render_state:set_message({ info = { id = 'real_old', role = 'assistant', sessionID = 's1' } }, 4, 8)
    ctx.render_state:set_message({ info = { id = 'real_mid', role = 'user', sessionID = 's1' } }, 10, 18)

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, vim.fn['repeat']({ 'line' }, 25))
    -- Without the fix, [[ from line 11 would match the notice (line 1) instead of `real_old` (line 4).
    vim.api.nvim_win_set_cursor(output_win, { 11, 0 })

    navigation.goto_prev_message()

    local cursor = vim.api.nvim_win_get_cursor(output_win)
    assert.equals(5, cursor[1])
  end)
end)
