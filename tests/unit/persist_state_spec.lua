local state = require('opencode.state')
local config = require('opencode.config')
local ui = require('opencode.ui.ui')

describe('persist_state', function()
  local windows
  local original_config
  local code_buf
  local code_win
  local tmpfile

  before_each(function()
    original_config = vim.deepcopy(config.values)
    state.windows = nil
    state.current_code_view = nil
    state.current_code_buf = nil
    state.last_code_win_before_opencode = nil
    state.saved_window_options = nil
  end)

  after_each(function()
    if state.windows then
      ui.close_windows(state.windows, false)
      state.windows = nil
    end

    if code_win and vim.api.nvim_win_is_valid(code_win) then
      pcall(vim.api.nvim_win_close, code_win, true)
    end

    if code_buf and vim.api.nvim_buf_is_valid(code_buf) then
      pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    end

    if tmpfile then
      vim.fn.delete(tmpfile)
      tmpfile = nil
    end

    config.values = original_config
    state.current_code_view = nil
    state.current_code_buf = nil
    state.last_code_win_before_opencode = nil
    state.saved_window_options = nil
  end)

  local function create_code_file(lines)
    tmpfile = vim.fn.tempname() .. '.lua'
    vim.fn.writefile(lines or { 'line 1', 'line 2', 'line 3', 'line 4', 'line 5' }, tmpfile)

    code_buf = vim.fn.bufadd(tmpfile)
    vim.fn.bufload(code_buf)
    vim.bo[code_buf].buflisted = true

    code_win = vim.api.nvim_open_win(code_buf, true, {
      relative = 'editor',
      width = 80,
      height = 20,
      row = 0,
      col = 0,
    })

    return code_win, code_buf
  end

  local function cleanup_windows()
    if state.windows then
      ui.close_windows(state.windows, false)
      state.windows = nil
    end
  end

  describe('configuration', function()
    it('should have persist_state default to true', function()
      config.setup({})
      assert.equals(true, config.values.ui.persist_state)
    end)

    it('should allow persist_state to be set to false', function()
      config.setup({
        ui = { persist_state = false },
      })
      assert.equals(false, config.values.ui.persist_state)
    end)
  end)

  describe('buffer preservation', function()
    it('should preserve buffers when closing with persist_state=true', function()
      config.setup({
        ui = { position = 'right', persist_state = true },
      })

      create_code_file()

      windows = ui.create_windows()
      local input_buf = windows.input_buf
      local output_buf = windows.output_buf

      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'test content' })

      ui.close_windows(windows, true)

      assert.is_true(vim.api.nvim_buf_is_valid(input_buf), 'input buffer should be preserved')
      assert.is_true(vim.api.nvim_buf_is_valid(output_buf), 'output buffer should be preserved')
      assert.is_true(ui.has_hidden_buffers(), 'should have hidden buffers')

      pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
      pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
      state.windows = nil
    end)

    it('should restore preserved buffers when reopening', function()
      config.setup({
        ui = { position = 'right', persist_state = true },
      })

      create_code_file()

      windows = ui.create_windows()
      local input_buf = windows.input_buf
      local output_buf = windows.output_buf

      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'preserved content' })

      ui.close_windows(windows, true)
      assert.is_true(ui.has_hidden_buffers())

      windows = ui.create_windows()

      assert.equals(input_buf, windows.input_buf, 'should restore same input buffer')
      assert.equals(output_buf, windows.output_buf, 'should restore same output buffer')

      local lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
      assert.equals('preserved content', lines[1], 'content should be preserved')

      cleanup_windows()
    end)
  end)

  describe('api.get_window_state()', function()
    local api = require('opencode.api')
    local original_api_client

    before_each(function()
      original_api_client = state.api_client
      state.api_client = {
        create_message = function() return require('opencode.promise').new():resolve({}) end,
        get_config = function() return require('opencode.promise').new():resolve({}) end,
        list_sessions = function() return require('opencode.promise').new():resolve({}) end,
        get_session = function() return require('opencode.promise').new():resolve({}) end,
        create_session = function() return require('opencode.promise').new():resolve({}) end,
      }
    end)

    after_each(function()
      state.api_client = original_api_client
    end)

    it('should return correct state for closed, visible, and hidden', function()
      config.setup({ ui = { position = 'right', persist_state = true } })

      -- Test closed state
      local window_state = api.get_window_state()
      assert.equals('closed', window_state.status)
      assert.is_false(window_state.visible)
      assert.is_false(window_state.hidden)

      -- Test visible state
      create_code_file()
      api.toggle(false):wait()
      window_state = api.get_window_state()
      assert.equals('visible', window_state.status)
      assert.is_true(window_state.visible)
      assert.is_false(window_state.hidden)

      -- Test hidden state
      api.toggle(false):wait()
      window_state = api.get_window_state()
      assert.equals('hidden', window_state.status)
      assert.is_false(window_state.visible)
      assert.is_true(window_state.hidden)

      cleanup_windows()
    end)
  end)

  describe('api.toggle() integration', function()
    local api = require('opencode.api')
    local original_api_client

    before_each(function()
      original_api_client = state.api_client
      state.api_client = {
        create_message = function() return require('opencode.promise').new():resolve({}) end,
        get_config = function() return require('opencode.promise').new():resolve({}) end,
        list_sessions = function() return require('opencode.promise').new():resolve({}) end,
        get_session = function() return require('opencode.promise').new():resolve({}) end,
        create_session = function() return require('opencode.promise').new():resolve({}) end,
      }
    end)

    after_each(function()
      state.api_client = original_api_client
    end)

    it('should handle complete open-close-reopen cycle', function()
      config.setup({
        ui = { position = 'right', persist_state = true },
      })

      create_code_file({ 'line 1', 'line 2', 'line 3' })

      -- Open
      api.toggle(false):wait()
      local window_state = api.get_window_state()
      assert.equals('visible', window_state.status)
      local first_input_buf = state.windows.input_buf
      vim.api.nvim_buf_set_lines(first_input_buf, 0, -1, false, { 'test content' })

      -- Hide
      api.toggle(false):wait()
      window_state = api.get_window_state()
      assert.equals('hidden', window_state.status)
      assert.is_true(vim.api.nvim_buf_is_valid(first_input_buf), 'buffer should be preserved')

      -- Reopen
      api.toggle(false):wait()
      window_state = api.get_window_state()
      assert.equals('visible', window_state.status)
      assert.equals(first_input_buf, state.windows.input_buf, 'should reuse same buffer')

      local lines = vim.api.nvim_buf_get_lines(state.windows.input_buf, 0, -1, false)
      assert.equals('test content', lines[1], 'content should be preserved')

      cleanup_windows()
    end)
  end)
end)
