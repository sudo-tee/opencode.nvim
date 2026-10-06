local config = require('opencode.config')
local helpers = require('tests.helpers')
local state = require('opencode.state')
local store = require('opencode.state.store')
local footer = require('opencode.ui.footer')
local topbar = require('opencode.ui.topbar')
local ui = require('opencode.ui.ui')

describe('bar segment hooks', function()
  local original_state
  local original_hooks

  before_each(function()
    original_state = vim.deepcopy(store.state())
    original_hooks = config.hooks
    config.hooks = vim.deepcopy(config.hooks)
    helpers.replay_setup()
  end)

  after_each(function()
    topbar.close()
    if state.windows then
      ui.close_windows(state.windows)
    end
    config.hooks = original_hooks
    for key, value in pairs(original_state) do
      store.set_raw(key, value)
    end
  end)

  it('lets topbar hook prepend a styled segment', function()
    config.hooks.on_topbar_render = function(segments)
      table.insert(segments, 1, { 'project ', 'OpencodeHint' })
      return segments
    end
    topbar.render()

    assert.is_true(vim.wait(1000, function()
      local winbar = vim.wo[state.windows.output_win].winbar
      return winbar:find('project ', 1, true) ~= nil and winbar:find('New session', 1, true) ~= nil
    end))
  end)

  it('clears topbar when hook returns nil', function()
    config.hooks.on_topbar_render = function()
      return nil
    end

    topbar.render()

    assert.is_true(vim.wait(1000, function()
      return vim.wo[state.windows.output_win].winbar == ''
    end))
  end)

  it('lets footer hook prepend a left-aligned segment', function()
    config.hooks.on_footer_render = function(segments)
      table.insert(segments, 1, { 'repo:branch ', 'OpencodeHint' })
      return segments
    end

    footer.render()

    local lines = vim.api.nvim_buf_get_lines(state.windows.footer_buf, 0, -1, false)
    assert.is_true(lines[1]:find('repo:branch ', 1, true) == 1)
  end)

  it('clears footer when hook returns nil', function()
    config.hooks.on_footer_render = function()
      return nil
    end

    footer.render()

    local lines = vim.api.nvim_buf_get_lines(state.windows.footer_buf, 0, -1, false)
    assert.are.same({ '' }, lines)
  end)
end)
