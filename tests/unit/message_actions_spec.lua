local assert = require('luassert')
local stub = require('luassert.stub')
local helpers = require('tests.helpers')
local state = require('opencode.state')
local ctx = require('opencode.ui.renderer.ctx')

local function user_message(id, parts)
  return {
    info = {
      id = id,
      role = 'user',
      sessionID = 'ses_1',
    },
    parts = parts or {
      { id = id .. '_text', type = 'text', text = 'hello', messageID = id, sessionID = 'ses_1' },
    },
  }
end

local function message(role, id, parts)
  return {
    info = {
      id = id,
      role = role,
      sessionID = 'ses_1',
    },
    parts = parts or {},
  }
end

describe('message_actions', function()
  local message_actions
  local input_buf, output_buf, other_buf
  local input_win, output_win, other_win
  local render_display_stub
  local notify_mock

  local function with_mousepos(mousepos, callback)
    local original_getmousepos = vim.fn.getmousepos
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.getmousepos = function()
      return mousepos
    end

    local ok, err = pcall(callback)
    vim.fn.getmousepos = original_getmousepos
    if not ok then
      error(err)
    end
  end

  local function set_output_cursor(line)
    vim.api.nvim_win_set_cursor(output_win, { line, 0 })
  end

  local function has_buffer_key(lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(output_buf, 'n')) do
      if map.lhs == lhs then
        return true
      end
    end
    return false
  end

  local function render_message_at(message_to_render, line_start, line_end)
    ctx.render_state:set_message(message_to_render, line_start, line_end)
  end

  local function render_part_at(part, line_start, line_end)
    ctx.render_state:set_part(part, line_start, line_end)
  end

  local function attach_rendered_actions_part(line_start)
    local Output = require('opencode.ui.output')
    local output = Output.new()
    message_actions.format_display(output)
    render_part_at({
      id = 'message-actions-display-part:msg_user',
      type = 'message-actions-display',
      messageID = 'msg_user',
      sessionID = 'ses_1',
      synthetic = true,
    }, line_start, line_start + #output.lines - 1)
  end

  before_each(function()
    package.loaded['opencode.ui.message_actions'] = nil
    package.loaded['opencode.api'] = nil
    message_actions = require('opencode.ui.message_actions')

    input_buf = vim.api.nvim_create_buf(false, true)
    output_buf = vim.api.nvim_create_buf(false, true)
    other_buf = vim.api.nvim_create_buf(false, true)
    input_win = vim.api.nvim_open_win(input_buf, false, {
      relative = 'editor',
      width = 80,
      height = 5,
      row = 0,
      col = 0,
    })
    output_win = vim.api.nvim_open_win(output_buf, true, {
      relative = 'editor',
      width = 80,
      height = 10,
      row = 6,
      col = 0,
    })
    other_win = vim.api.nvim_open_win(other_buf, false, {
      relative = 'editor',
      width = 80,
      height = 5,
      row = 17,
      col = 0,
    })

    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'one', 'two', 'three', 'four' })
    state.ui.set_windows({
      input_buf = input_buf,
      input_win = input_win,
      output_buf = output_buf,
      output_win = output_win,
    })
    state.session.set_active({ id = 'ses_1' })
    state.renderer.set_messages({})
    ctx:reset()

    package.loaded['opencode.ui.input_window'] = {
      _hide = function() end,
      _show = function() end,
    }

    render_display_stub = stub(require('opencode.ui.renderer.events'), 'render_message_actions_display')
    notify_mock = helpers.mock_notify()
  end)

  after_each(function()
    notify_mock.reset()
    if render_display_stub then
      render_display_stub:revert()
    end
    pcall(message_actions.clear)
    ctx:reset()
    state.renderer.set_messages({})
    state.session.set_active(nil)
    state.ui.clear_windows()
    package.loaded['opencode.ui.input_window'] = nil
    package.loaded['opencode.api'] = nil
    require('opencode.ui.question_window')._current_question = nil
    require('opencode.ui.question_window')._current_question_index = 1
    require('opencode.ui.permission_window')._permission_queue = {}
    require('opencode.ui.permission_window')._dialog = nil
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, output_win, true)
    pcall(vim.api.nvim_win_close, other_win, true)
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
  end)

  it('does not require opencode.api at module load time', function()
    package.loaded['opencode.ui.message_actions'] = nil
    package.loaded['opencode.api'] = nil

    require('opencode.ui.message_actions')

    assert.is_nil(package.loaded['opencode.api'])
  end)

  it('open_at_cursor finds the user message from the output cursor line', function()
    local target = user_message('msg_user')
    render_message_at(target, 0, 0)
    set_output_cursor(1)

    message_actions.open_at_cursor()

    assert.are.equal(target, message_actions._target_message)
    assert.is_not_nil(message_actions._dialog)
    assert.stub(render_display_stub).was_called_with('msg_user', 'message-actions-display-part:msg_user')
  end)

  it('open_at_cursor finds the user message from a rendered user text part line', function()
    local target = user_message('msg_user')
    local text_part = target.parts[1]
    render_message_at(target, 0, 0)
    render_part_at(text_part, 1, 1)
    set_output_cursor(2)

    message_actions.open_at_cursor()

    assert.are.equal(target, message_actions._target_message)
    assert.stub(render_display_stub).was_called_with('msg_user', 'message-actions-display-part:msg_user')
  end)

  it('open_at_cursor does not open from assistant part or message actions part lines', function()
    local assistant = message('assistant', 'msg_assistant', {
      { id = 'part_assistant', type = 'text', text = 'assistant', messageID = 'msg_assistant', sessionID = 'ses_1' },
    })
    render_message_at(assistant, 0, 0)
    render_part_at(assistant.parts[1], 1, 1)
    set_output_cursor(2)

    message_actions.open_at_cursor()

    assert.is_nil(message_actions._target_message)
    assert.stub(render_display_stub).was_not_called()

    local target = user_message('msg_user')
    render_message_at(target, 2, 2)
    render_part_at({
      id = 'message-actions-display-part:msg_user',
      type = 'message-actions-display',
      messageID = 'msg_user',
      sessionID = 'ses_1',
      synthetic = true,
    }, 3, 3)
    set_output_cursor(4)

    message_actions.open_at_cursor()

    assert.is_nil(message_actions._target_message)
    assert.stub(render_display_stub).was_not_called()
  end)

  it('open_from_mouse uses the mouse line instead of the cursor line', function()
    local assistant = message('assistant', 'msg_assistant')
    local target = user_message('msg_user')
    render_message_at(assistant, 0, 0)
    render_message_at(target, 1, 1)
    set_output_cursor(1)

    with_mousepos({ winid = output_win, line = 2, column = 1 }, function()
      message_actions.open_from_mouse()
    end)

    assert.are.equal(target, message_actions._target_message)
  end)

  it('open_from_mouse finds the user message from a rendered user text part line', function()
    local target = user_message('msg_user')
    render_message_at(target, 0, 0)
    render_part_at(target.parts[1], 1, 1)

    with_mousepos({ winid = output_win, line = 2, column = 1 }, function()
      message_actions.open_from_mouse()
    end)

    assert.are.equal(target, message_actions._target_message)
    assert.stub(render_display_stub).was_called_with('msg_user', 'message-actions-display-part:msg_user')
  end)

  it('normalizes Neovim 1-based cursor and mouse lines to render-state 0-based lines', function()
    local first = user_message('msg_first')
    local second = user_message('msg_second')
    render_message_at(first, 0, 0)
    render_message_at(second, 1, 1)

    set_output_cursor(1)
    message_actions.open_at_cursor()
    assert.are.equal(first, message_actions._target_message)

    with_mousepos({ winid = output_win, line = 2, column = 1 }, function()
      message_actions.open_from_mouse()
    end)
    assert.is_nil(message_actions._target_message)

    with_mousepos({ winid = output_win, line = 2, column = 1 }, function()
      message_actions.open_from_mouse()
    end)
    assert.are.equal(second, message_actions._target_message)
  end)

  it('open_from_mouse silently ignores mouse positions outside the output window', function()
    render_message_at(user_message('msg_user'), 0, 0)

    with_mousepos({ winid = other_win, line = 1, column = 1 }, function()
      message_actions.open_from_mouse()
    end)

    assert.is_nil(message_actions._target_message)
    assert.stub(render_display_stub).was_not_called()
  end)

  it('open_from_mouse silently ignores output-window ids whose buffer does not match output_buf', function()
    render_message_at(user_message('msg_user'), 0, 0)
    vim.api.nvim_win_set_buf(output_win, other_buf)

    with_mousepos({ winid = output_win, line = 1, column = 1 }, function()
      message_actions.open_from_mouse()
    end)

    assert.is_nil(message_actions._target_message)
    assert.stub(render_display_stub).was_not_called()
  end)

  it('open_from_mouse routes active question clicks before message actions', function()
    local question_window = require('opencode.ui.question_window')
    local permission_window = require('opencode.ui.permission_window')
    local original_has_question = question_window.has_question
    local original_select_question = question_window.select_mouse_option
    local original_has_permissions = permission_window.has_permissions
    local selected = false

    question_window.has_question = function()
      return true
    end
    question_window.select_mouse_option = function()
      selected = true
      return true
    end
    permission_window.has_permissions = function()
      return false
    end
    render_message_at(user_message('msg_user'), 0, 0)

    with_mousepos({ winid = output_win, line = 1, column = 1 }, function()
      message_actions.open_from_mouse()
    end)

    question_window.has_question = original_has_question
    question_window.select_mouse_option = original_select_question
    permission_window.has_permissions = original_has_permissions

    assert.is_true(selected)
    assert.is_nil(message_actions._target_message)
    assert.stub(render_display_stub).was_not_called()
  end)

  it('open_from_mouse routes active permission clicks before message actions', function()
    local question_window = require('opencode.ui.question_window')
    local permission_window = require('opencode.ui.permission_window')
    local original_has_question = question_window.has_question
    local original_has_permissions = permission_window.has_permissions
    local original_select_permission = permission_window.select_mouse_option
    local selected = false

    question_window.has_question = function()
      return false
    end
    permission_window.has_permissions = function()
      return true
    end
    permission_window.select_mouse_option = function()
      selected = true
      return true
    end
    render_message_at(user_message('msg_user'), 0, 0)

    with_mousepos({ winid = output_win, line = 1, column = 1 }, function()
      message_actions.open_from_mouse()
    end)

    question_window.has_question = original_has_question
    permission_window.has_permissions = original_has_permissions
    permission_window.select_mouse_option = original_select_permission

    assert.is_true(selected)
    assert.is_nil(message_actions._target_message)
    assert.stub(render_display_stub).was_not_called()
  end)

  it('only allows non-synthetic user messages with ids', function()
    assert.is_true(message_actions.is_actionable_user_message(user_message('msg_user')))
    assert.is_false(message_actions.is_actionable_user_message(message('assistant', 'msg_assistant')))
    assert.is_false(message_actions.is_actionable_user_message(message('tool', 'msg_tool')))
    assert.is_false(message_actions.is_actionable_user_message(message('system', 'msg_system')))
    assert.is_false(message_actions.is_actionable_user_message(user_message('', {})))
    assert.is_false(message_actions.is_actionable_user_message(user_message('msg_synthetic', {
      { type = 'text', text = 'synthetic', synthetic = true },
    })))
  end)

  it('refuses to open while a question dialog is active', function()
    local question_window = require('opencode.ui.question_window')
    question_window._current_question = {
      id = 'question_1',
      questions = {
        { question = 'Choose', options = {} },
      },
    }
    question_window._current_question_index = 1
    render_message_at(user_message('msg_user'), 0, 0)
    set_output_cursor(1)

    message_actions.open_at_cursor()

    assert.is_nil(message_actions._target_message)
    assert.are.equal('Finish the active dialog first', notify_mock.get_notifications()[1].msg)
  end)

  it('refuses to open while a permission dialog is active', function()
    require('opencode.ui.permission_window')._permission_queue = { { id = 'permission_1' } }
    render_message_at(user_message('msg_user'), 0, 0)
    set_output_cursor(1)

    message_actions.open_at_cursor()

    assert.is_nil(message_actions._target_message)
    assert.are.equal('Finish the active dialog first', notify_mock.get_notifications()[1].msg)
  end)

  it('clear tears down the active dialog and requests synthetic display removal', function()
    render_message_at(user_message('msg_user'), 0, 0)
    set_output_cursor(1)
    message_actions.open_at_cursor()
    render_display_stub:clear()

    message_actions.clear()

    assert.is_nil(message_actions._target_message)
    assert.is_nil(message_actions._dialog)
    assert.stub(render_display_stub).was_called_with(nil, 'message-actions-display-part:msg_user')
  end)

  it('does not let Dialog override the output single-click mapping while active', function()
    render_message_at(user_message('msg_user'), 0, 0)
    set_output_cursor(1)
    message_actions.open_at_cursor()

    assert.is_false(has_buffer_key('<LeftMouse>'))
  end)

  it('active mouse click on an action option selects that option', function()
    local setreg_name, setreg_value
    local original_setreg = vim.fn.setreg
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.setreg = function(name, value)
      setreg_name = name
      setreg_value = value
    end

    render_message_at(
      user_message('msg_user', {
        { id = 'part_text', type = 'text', text = 'copy me', messageID = 'msg_user', sessionID = 'ses_1' },
      }),
      0,
      0
    )
    set_output_cursor(1)
    message_actions.open_at_cursor()
    attach_rendered_actions_part(20)
    local copy_line = 20 + message_actions._dialog._option_local_lines[2] + 1

    with_mousepos({ winid = output_win, line = copy_line, column = 1 }, function()
      message_actions.open_from_mouse()
    end)
    vim.fn.setreg = original_setreg

    assert.are.equal('+', setreg_name)
    assert.are.equal('copy me', setreg_value)
    assert.is_nil(message_actions._target_message)
  end)

  it('active mouse click outside action options clears the dialog', function()
    render_message_at(user_message('msg_user'), 0, 0)
    set_output_cursor(1)
    message_actions.open_at_cursor()
    attach_rendered_actions_part(20)
    render_display_stub:clear()

    with_mousepos({ winid = output_win, line = 1, column = 1 }, function()
      message_actions.open_from_mouse()
    end)

    assert.is_nil(message_actions._target_message)
    assert.is_nil(message_actions._dialog)
    assert.stub(render_display_stub).was_called_with(nil, 'message-actions-display-part:msg_user')
  end)

  it('active mouse click on another message clears instead of switching targets', function()
    render_message_at(user_message('msg_user'), 0, 0)
    render_message_at(user_message('msg_other'), 2, 2)
    set_output_cursor(1)
    message_actions.open_at_cursor()
    attach_rendered_actions_part(20)

    with_mousepos({ winid = output_win, line = 3, column = 1 }, function()
      message_actions.open_from_mouse()
    end)

    assert.is_nil(message_actions._target_message)
    assert.is_nil(message_actions._dialog)
  end)

  it('teardown clears state and keymaps without requesting renderer removal', function()
    local target = user_message('msg_user')
    render_message_at(target, 0, 0)
    set_output_cursor(1)
    message_actions.open_at_cursor()
    assert.is_true(has_buffer_key('1'))

    render_display_stub:clear()
    message_actions.teardown()

    assert.is_nil(message_actions._target_message)
    assert.is_nil(message_actions._dialog)
    assert.is_nil(message_actions._display_part_id)
    assert.is_false(has_buffer_key('1'))
    assert.stub(render_display_stub).was_not_called()
  end)

  it('renderer reset tears down the active message actions dialog', function()
    local target = user_message('msg_user')
    render_message_at(target, 0, 0)
    set_output_cursor(1)
    message_actions.open_at_cursor()
    assert.is_true(has_buffer_key('1'))

    require('opencode.ui.renderer').reset()

    assert.is_nil(message_actions._target_message)
    assert.is_nil(message_actions._dialog)
    assert.is_nil(message_actions._display_part_id)
    assert.is_false(has_buffer_key('1'))
  end)

  it('persist hide tears down the active message actions dialog', function()
    local config = require('opencode.config')
    config.values.ui.persist_state = true
    local target = user_message('msg_user')
    render_message_at(target, 0, 0)
    set_output_cursor(1)
    message_actions.open_at_cursor()
    assert.is_true(has_buffer_key('1'))
    render_display_stub:clear()

    require('opencode.ui.ui').hide_visible_windows(state.windows)

    assert.is_nil(message_actions._target_message)
    assert.is_nil(message_actions._dialog)
    assert.is_nil(message_actions._display_part_id)
    assert.is_false(has_buffer_key('1'))
    assert.stub(render_display_stub).was_called_with(nil, 'message-actions-display-part:msg_user')
  end)

  it('selecting Revert calls opencode.api.undo with the target message id', function()
    local undo_id = nil
    package.loaded['opencode.api'] = {
      undo = function(message_id)
        undo_id = message_id
      end,
    }
    render_message_at(user_message('msg_user'), 0, 0)
    set_output_cursor(1)
    message_actions.open_at_cursor()

    message_actions._dialog:set_selection(1)
    message_actions._dialog:select()

    assert.are.equal('msg_user', undo_id)
  end)

  it('selecting Fork calls opencode.api.fork_session with the target message id', function()
    local fork_id = nil
    package.loaded['opencode.api'] = {
      fork_session = function(message_id)
        fork_id = message_id
      end,
    }
    render_message_at(user_message('msg_user'), 0, 0)
    set_output_cursor(1)
    message_actions.open_at_cursor()

    message_actions._dialog:set_selection(3)
    message_actions._dialog:select()

    assert.are.equal('msg_user', fork_id)
  end)

  it('collect_user_text joins only non-synthetic text parts without trimming copied text', function()
    local text = message_actions.collect_user_text(user_message('msg_user', {
      { type = 'text', text = '  first  ' },
      { type = 'tool', text = 'tool output' },
      { type = 'text', text = 'synthetic', synthetic = true },
      { type = 'text', text = '   ' },
      { type = 'text', text = 'second\nline' },
    }))

    assert.are.equal('  first  \n\nsecond\nline', text)
  end)

  it('selecting Copy writes only the + register with the collected user text', function()
    local setreg_name, setreg_value
    local original_setreg = vim.fn.setreg
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.setreg = function(name, value)
      setreg_name = name
      setreg_value = value
    end

    render_message_at(
      user_message('msg_user', {
        { type = 'text', text = 'first' },
        { type = 'text', text = 'synthetic', synthetic = true },
        { type = 'text', text = 'second' },
      }),
      0,
      0
    )
    set_output_cursor(1)
    message_actions.open_at_cursor()

    message_actions._dialog:set_selection(2)
    message_actions._dialog:select()
    vim.fn.setreg = original_setreg

    assert.are.equal('+', setreg_name)
    assert.are.equal('first\n\nsecond', setreg_value)
  end)

  it('selecting Copy notifies and does not write a register when there is no text', function()
    local setreg_called = false
    local original_setreg = vim.fn.setreg
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.setreg = function()
      setreg_called = true
    end

    render_message_at(
      user_message('msg_user', {
        { type = 'text', text = '   ' },
        { type = 'text', text = 'synthetic', synthetic = true },
      }),
      0,
      0
    )
    set_output_cursor(1)
    message_actions.open_at_cursor()

    message_actions._dialog:set_selection(2)
    message_actions._dialog:select()
    vim.fn.setreg = original_setreg

    assert.is_false(setreg_called)
    assert.are.equal('No message text to copy', notify_mock.get_notifications()[1].msg)
  end)

  it('formats only the action choices without the generic dialog legend', function()
    local Output = require('opencode.ui.output')
    render_message_at(user_message('msg_user'), 0, 0)
    set_output_cursor(1)
    message_actions.open_at_cursor()

    local output = Output.new()
    message_actions.format_display(output)
    local lines = table.concat(output.lines, '\n')

    assert.is_not_nil(lines:find('Message Actions', 1, true))
    assert.is_not_nil(lines:find('Revert', 1, true))
    assert.is_not_nil(lines:find('Copy', 1, true))
    assert.is_not_nil(lines:find('Fork', 1, true))
    assert.is_nil(lines:find('Move:', 1, true))
    assert.is_nil(lines:find('Select:', 1, true))
    assert.is_nil(lines:find('Close:', 1, true))
  end)
end)

describe('renderer.events message actions display', function()
  local events = require('opencode.ui.renderer.events')
  local message_actions
  local part_stub
  local remove_part_stub

  before_each(function()
    package.loaded['opencode.ui.message_actions'] = nil
    message_actions = require('opencode.ui.message_actions')
    state.session.set_active({ id = 'ses_1' })
    state.renderer.set_messages({
      user_message('msg_user'),
      user_message('msg_other'),
    })
    ctx:reset()
    part_stub = stub(events, 'on_part_updated')
    remove_part_stub = stub(events, 'on_part_removed')
  end)

  after_each(function()
    part_stub:revert()
    remove_part_stub:revert()
    state.session.set_active(nil)
    state.renderer.set_messages({})
    ctx:reset()
  end)

  it('creates the synthetic part under the target message', function()
    events.render_message_actions_display('msg_user', 'message-actions-display-part:msg_user')

    assert.stub(part_stub).was_called_with({
      part = {
        id = 'message-actions-display-part:msg_user',
        messageID = 'msg_user',
        sessionID = 'ses_1',
        type = 'message-actions-display',
        synthetic = true,
      },
    })
  end)

  it('removes the synthetic part when asked not to show it', function()
    events.render_message_actions_display(nil, 'message-actions-display-part:msg_user')

    assert.stub(remove_part_stub).was_called_with({
      sessionID = 'ses_1',
      messageID = nil,
      partID = 'message-actions-display-part:msg_user',
    })
  end)

  it('uses separate synthetic part ids when the target message changes', function()
    ctx.render_state:set_part({
      id = 'message-actions-display-part:msg_other',
      messageID = 'msg_other',
      sessionID = 'ses_1',
      type = 'message-actions-display',
      synthetic = true,
    }, 10, 12)

    events.render_message_actions_display(nil, 'message-actions-display-part:msg_other')
    events.render_message_actions_display('msg_user', 'message-actions-display-part:msg_user')

    assert.stub(remove_part_stub).was_called_with({
      sessionID = 'ses_1',
      messageID = 'msg_other',
      partID = 'message-actions-display-part:msg_other',
    })
    assert.stub(part_stub).was_called_with({
      part = {
        id = 'message-actions-display-part:msg_user',
        messageID = 'msg_user',
        sessionID = 'ses_1',
        type = 'message-actions-display',
        synthetic = true,
      },
    })
  end)

  it('renders synthetic parts without loading message_actions', function()
    package.loaded['opencode.ui.message_actions'] = nil

    events.render_message_actions_display('msg_user', 'message-actions-display-part:msg_user')

    assert.is_nil(package.loaded['opencode.ui.message_actions'])
    assert.stub(part_stub).was_called_with({
      part = {
        id = 'message-actions-display-part:msg_user',
        messageID = 'msg_user',
        sessionID = 'ses_1',
        type = 'message-actions-display',
        synthetic = true,
      },
    })
  end)
end)
