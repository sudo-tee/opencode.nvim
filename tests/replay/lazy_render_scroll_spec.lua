local helpers = require('tests.helpers')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local ctx = require('opencode.ui.renderer.ctx')
local output_window = require('opencode.ui.output_window')
local Promise = require('opencode.promise')

local function make_message_events(pair_count)
  local events = {}
  local session_id = 'ses_lazy_scroll'
  for i = 1, pair_count do
    local user_id = 'msg_lazy_user_' .. i
    table.insert(events, {
      type = 'message.updated',
      properties = {
        info = {
          id = user_id,
          sessionID = session_id,
          role = 'user',
          time = { created = 1700000000000 + i * 2 },
        },
      },
    })
    table.insert(events, {
      type = 'message.part.updated',
      properties = {
        part = {
          id = user_id .. '_text',
          messageID = user_id,
          sessionID = session_id,
          type = 'text',
          text = 'User message ' .. i,
        },
      },
    })

    local assistant_id = 'msg_lazy_assistant_' .. i
    table.insert(events, {
      type = 'message.updated',
      properties = {
        info = {
          id = assistant_id,
          sessionID = session_id,
          role = 'assistant',
          parentID = user_id,
          time = { created = 1700000000001 + i * 2 },
        },
      },
    })
    table.insert(events, {
      type = 'message.part.updated',
      properties = {
        part = {
          id = assistant_id .. '_text',
          messageID = assistant_id,
          sessionID = session_id,
          type = 'text',
          text = 'Assistant message ' .. i,
        },
      },
    })
  end
  return events
end

local function output_text()
  return table.concat(vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false), '\n')
end

describe('replay lazy-render upward loading', function()
  before_each(function()
    helpers.replay_setup()
    state.jobs.set_api_client({
      list_questions = function()
        return Promise.new():resolve({})
      end,
      list_permissions = function()
        return Promise.new():resolve({})
      end,
    })
  end)

  after_each(function()
    state.jobs.set_api_client(nil)
    if state.windows then
      ui.close_windows(state.windows)
    end
  end)

  it('loads older replayed messages when the viewport reaches the rendered top', function()
    local renderer = require('opencode.ui.renderer')
    local events = make_message_events(50)
    state.session.set_active(helpers.get_session_from_events(events))
    vim.wait(50, function()
      return false
    end)

    local win = state.windows.output_win
    vim.api.nvim_win_set_height(win, 15)
    ctx.lazy_render_count = nil
    renderer._render_full_session_data(helpers.load_session_from_events(events))

    local initial_count = ctx.lazy_render_count
    assert.is_true(initial_count ~= nil and initial_count < #(state.messages or {}))
    assert.is_not_match('User message 1', output_text())

    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    vim.api.nvim_win_call(win, function()
      vim.cmd('normal! zz')
    end)

    assert.are.equal(1, output_window.get_visible_top_line(win))
    assert.are.equal(5, vim.api.nvim_win_get_cursor(win)[1])

    vim.api.nvim_exec_autocmds('WinScrolled', {
      buffer = state.windows.output_buf,
      modeline = false,
    })

    local loaded = vim.wait(1000, function()
      return ctx.lazy_render_count and ctx.lazy_render_count > initial_count
    end)

    assert.is_true(loaded, 'Expected viewport-at-top WinScrolled to load older replayed messages')
  end)
end)
