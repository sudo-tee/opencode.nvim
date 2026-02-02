local state = require('opencode.state')
local config = require('opencode.config')
local input_window = require('opencode.ui.input_window')
local output_window = require('opencode.ui.output_window')
local ui = require('opencode.ui.ui')

describe('ui zoom state', function()
  local windows
  local original_columns

  before_each(function()
    original_columns = vim.o.columns
    vim.o.columns = 200

    config.setup({
      ui = {
        window_width = 0.4,
        zoom_width = 0.8,
        position = 'right',
      },
    })

    local input_buf = vim.api.nvim_create_buf(false, true)
    local output_buf = vim.api.nvim_create_buf(false, true)
    local input_win = vim.api.nvim_open_win(input_buf, true, {
      relative = 'editor',
      width = 80,
      height = 10,
      row = 0,
      col = 0,
    })
    local output_win = vim.api.nvim_open_win(output_buf, false, {
      relative = 'editor',
      width = 80,
      height = 20,
      row = 11,
      col = 0,
    })

    windows = {
      input_buf = input_buf,
      input_win = input_win,
      output_buf = output_buf,
      output_win = output_win,
    }
    state.windows = windows
    state.pre_zoom_width = nil
  end)

  after_each(function()
    vim.o.columns = original_columns
    state.pre_zoom_width = nil

    if windows then
      pcall(vim.api.nvim_win_close, windows.input_win, true)
      pcall(vim.api.nvim_win_close, windows.output_win, true)
      pcall(vim.api.nvim_buf_delete, windows.input_buf, { force = true })
      pcall(vim.api.nvim_buf_delete, windows.output_buf, { force = true })
    end
    state.windows = nil
  end)

  describe('toggle_zoom', function()
    it('sets zoom width when not zoomed', function()
      local initial_width = vim.api.nvim_win_get_width(windows.output_win)

      ui.toggle_zoom()

      local expected_zoom_width = math.floor(config.ui.zoom_width * vim.o.columns)
      local actual_width = vim.api.nvim_win_get_width(windows.output_win)

      assert.is_not_nil(state.pre_zoom_width)
      assert.equals(initial_width, state.pre_zoom_width)
      assert.equals(expected_zoom_width, actual_width)
    end)

    it('restores original width when zoomed', function()
      local initial_width = vim.api.nvim_win_get_width(windows.output_win)

      ui.toggle_zoom()
      ui.toggle_zoom()

      local actual_width = vim.api.nvim_win_get_width(windows.output_win)

      assert.is_nil(state.pre_zoom_width)
      assert.equals(initial_width, actual_width)
    end)

    it('sets zoom width for both input and output windows', function()
      ui.toggle_zoom()

      local expected_zoom_width = math.floor(config.ui.zoom_width * vim.o.columns)
      local input_width = vim.api.nvim_win_get_width(windows.input_win)
      local output_width = vim.api.nvim_win_get_width(windows.output_win)

      assert.equals(expected_zoom_width, input_width)
      assert.equals(expected_zoom_width, output_width)
    end)
  end)

  describe('input_window.update_dimensions', function()
    it('uses default window_width when not zoomed', function()
      input_window.update_dimensions(windows)

      local expected_width = math.floor(config.ui.window_width * vim.o.columns)
      local actual_width = vim.api.nvim_win_get_width(windows.input_win)

      assert.equals(expected_width, actual_width)
    end)

    it('uses zoom_width when zoomed', function()
      state.pre_zoom_width = 80

      input_window.update_dimensions(windows)

      local expected_width = math.floor(config.ui.zoom_width * vim.o.columns)
      local actual_width = vim.api.nvim_win_get_width(windows.input_win)

      assert.equals(expected_width, actual_width)
    end)

    it('preserves zoom state after update_dimensions', function()
      state.pre_zoom_width = 80

      input_window.update_dimensions(windows)

      assert.equals(80, state.pre_zoom_width)
    end)
  end)

  describe('output_window.update_dimensions', function()
    it('uses default window_width when not zoomed', function()
      output_window.update_dimensions(windows)

      local expected_width = math.floor(config.ui.window_width * vim.o.columns)
      local actual_width = vim.api.nvim_win_get_width(windows.output_win)

      assert.equals(expected_width, actual_width)
    end)

    it('uses zoom_width when zoomed', function()
      state.pre_zoom_width = 80

      output_window.update_dimensions(windows)

      local expected_width = math.floor(config.ui.zoom_width * vim.o.columns)
      local actual_width = vim.api.nvim_win_get_width(windows.output_win)

      assert.equals(expected_width, actual_width)
    end)

    it('preserves zoom state after update_dimensions', function()
      state.pre_zoom_width = 80

      output_window.update_dimensions(windows)

      assert.equals(80, state.pre_zoom_width)
    end)
  end)

  describe('zoom state persistence', function()
    it('maintains zoom width after input window show/hide cycle', function()
      ui.toggle_zoom()

      local expected_zoom_width = math.floor(config.ui.zoom_width * vim.o.columns)

      input_window.update_dimensions(windows)

      local actual_width = vim.api.nvim_win_get_width(windows.input_win)
      assert.equals(expected_zoom_width, actual_width)
      assert.is_not_nil(state.pre_zoom_width)
    end)

    it('maintains zoom width after output window update_dimensions', function()
      ui.toggle_zoom()

      local expected_zoom_width = math.floor(config.ui.zoom_width * vim.o.columns)

      output_window.update_dimensions(windows)

      local actual_width = vim.api.nvim_win_get_width(windows.output_win)
      assert.equals(expected_zoom_width, actual_width)
      assert.is_not_nil(state.pre_zoom_width)
    end)

    it('correctly un-zooms after multiple update_dimensions calls', function()
      ui.toggle_zoom()

      input_window.update_dimensions(windows)
      output_window.update_dimensions(windows)

      ui.toggle_zoom()

      assert.is_nil(state.pre_zoom_width)
    end)
  end)
end)
