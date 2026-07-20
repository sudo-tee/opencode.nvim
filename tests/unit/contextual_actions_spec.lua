local assert = require('luassert')
local stub = require('luassert.stub')
local state = require('opencode.state')
local contextual_actions = require('opencode.ui.contextual_actions')

local function mapping(buf, key)
  for _, value in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if value.lhs == key then
      return value
    end
  end
end

local function action(key, type, args, range)
  return {
    key = key,
    text = key,
    type = type,
    args = args,
    display_line = range and range.to or 0,
    range = range,
  }
end

describe('contextual actions', function()
  local buf
  local windows

  before_each(function()
    windows = state.store.get('windows')
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'text' })
    vim.api.nvim_set_current_buf(buf)
    state.store.set_raw('windows', { output_buf = buf })
  end)

  after_each(function()
    state.store.set_raw('windows', windows)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it('reversibly overlays and restores buffer-local callback mappings', function()
    local original = function()
      return ''
    end
    vim.keymap.set('n', 'R', original, {
      buffer = buf,
      desc = 'Original R',
      silent = true,
      expr = true,
      nowait = true,
      remap = true,
      replace_keycodes = false,
    })

    contextual_actions.show_contextual_actions_menu(buf, { action('R') })
    assert.equal('R', mapping(buf, 'R').desc)

    contextual_actions.show_contextual_actions_menu(buf, {})
    local restored = mapping(buf, 'R')
    assert.equal(original, restored.callback)
    assert.equal('Original R', restored.desc)
    assert.equal(1, restored.silent)
    assert.equal(1, restored.expr)
    assert.equal(1, restored.nowait)
    assert.equal(0, restored.noremap)
    assert.not_equal(1, restored.replace_keycodes)
  end)

  it('keeps an originally unmapped key unmapped after invalidation', function()
    contextual_actions.show_contextual_actions_menu(buf, { action('C') })
    assert.equal('C', mapping(buf, 'C').desc)

    contextual_actions.show_contextual_actions_menu(buf, {})
    assert.is_nil(mapping(buf, 'C'))
  end)

  it('restores buffer-local rhs mappings', function()
    vim.keymap.set('n', 'C', "<Cmd>echo 'original'<CR>", { buffer = buf, desc = 'Original C' })

    contextual_actions.show_contextual_actions_menu(buf, { action('C') })
    contextual_actions.show_contextual_actions_menu(buf, {})

    assert.equal("<Cmd>echo 'original'<CR>", mapping(buf, 'C').rhs)
    assert.equal('Original C', mapping(buf, 'C').desc)
  end)

  it('preserves script-local rhs mappings through an action overlay', function()
    local script = vim.fn.tempname()
    vim.fn.writefile({
      'function! s:contextual_action_probe() abort',
      "  let g:opencode_contextual_action_probe = get(g:, 'opencode_contextual_action_probe', 0) + 1",
      'endfunction',
      'nnoremap <script> <buffer> R :call <SID>contextual_action_probe()<CR>',
    }, script)
    vim.cmd('source ' .. vim.fn.fnameescape(script))
    vim.fn.delete(script)
    local original = mapping(buf, 'R')

    contextual_actions.show_contextual_actions_menu(buf, { action('R') })
    contextual_actions.show_contextual_actions_menu(buf, {})

    local restored = mapping(buf, 'R')
    assert.equal(original.rhs, restored.rhs)
    assert.equal(original.script, restored.script)
    vim.g.opencode_contextual_action_probe = nil
    vim.api.nvim_feedkeys('R', 'xt', false)
    assert.equal(1, vim.g.opencode_contextual_action_probe)
  end)

  it('restores callback and script-local mappings with their native options', function()
    local script = vim.fn.tempname()
    vim.fn.writefile({
      'function! s:contextual_action_probe() abort',
      "  let g:opencode_contextual_action_probe = get(g:, 'opencode_contextual_action_probe', 0) + 1",
      'endfunction',
      'nnoremap <script> <buffer> S :call <SID>contextual_action_probe()<CR>',
    }, script)
    vim.cmd('source ' .. vim.fn.fnameescape(script))
    vim.fn.delete(script)
    local callback_calls = 0
    vim.api.nvim_buf_set_keymap(buf, 'n', 'R', '', {
      callback = function()
        callback_calls = callback_calls + 1
        return ''
      end,
      desc = 'Original R',
      expr = true,
      noremap = true,
      nowait = true,
      replace_keycodes = false,
      script = true,
      silent = true,
    })
    local original = mapping(buf, 'R')

    contextual_actions.show_contextual_actions_menu(buf, { action('R'), action('S') })
    contextual_actions.show_contextual_actions_menu(buf, {})

    local restored = mapping(buf, 'R')
    assert.equal(original.callback, restored.callback)
    assert.equal(1, restored.expr)
    assert.equal(2, restored.noremap)
    assert.equal(1, restored.nowait)
    assert.not_equal(1, restored.replace_keycodes)
    assert.equal(1, restored.script)
    assert.equal(1, restored.silent)
    restored.callback()
    assert.equal(1, callback_calls)
    vim.g.opencode_contextual_action_probe = nil
    vim.api.nvim_feedkeys('S', 'xt', false)
    assert.equal(1, vim.g.opencode_contextual_action_probe)
  end)

  it('attaches one observer and invalidates once when buffer lines change', function()
    local original_attach = vim.api.nvim_buf_attach
    local attach = stub(vim.api, 'nvim_buf_attach').invokes(original_attach)
    contextual_actions.setup_contextual_actions({ output_buf = buf })
    contextual_actions.setup_contextual_actions({ output_buf = buf })
    assert.equal(1, #attach.calls)
    attach:revert()

    vim.keymap.set('n', 'R', function() end, { buffer = buf, desc = 'Original R' })
    contextual_actions.show_contextual_actions_menu(buf, { action('R') })
    local original_clear_namespace = vim.api.nvim_buf_clear_namespace
    local clear_namespace = stub(vim.api, 'nvim_buf_clear_namespace').invokes(original_clear_namespace)

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'changed' })

    assert.stub(clear_namespace).was_called(1)
    assert.equal('Original R', mapping(buf, 'R').desc)
    clear_namespace:revert()
  end)

  it('clears actions on cursor and buffer lifecycle events, then can show them again', function()
    contextual_actions.setup_contextual_actions({ output_buf = buf })
    vim.keymap.set('n', 'R', function() end, { buffer = buf, desc = 'Original R' })

    contextual_actions.show_contextual_actions_menu(buf, { action('R') })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    assert.equal('Original R', mapping(buf, 'R').desc)

    contextual_actions.show_contextual_actions_menu(buf, { action('R') })
    vim.api.nvim_exec_autocmds('BufHidden', { buffer = buf })
    assert.equal('Original R', mapping(buf, 'R').desc)

    local renderer = package.loaded['opencode.ui.renderer']
    package.loaded['opencode.ui.renderer'] = {
      get_actions_for_line = function()
        return { action('R') }
      end,
    }
    vim.api.nvim_exec_autocmds('CursorHold', { buffer = buf })
    assert.is_true(vim.wait(100, function()
      return mapping(buf, 'R') and mapping(buf, 'R').desc == 'R'
    end))
    package.loaded['opencode.ui.renderer'] = renderer
  end)

  it('refreshes actions on setup and output re-entry', function()
    vim.keymap.set('n', 'R', function() end, { buffer = buf, desc = 'Original R' })
    local renderer = package.loaded['opencode.ui.renderer']
    package.loaded['opencode.ui.renderer'] = {
      get_actions_for_line = function()
        return { action('R') }
      end,
    }

    contextual_actions.setup_contextual_actions({ output_buf = buf })
    assert.equal('R', mapping(buf, 'R').desc)

    vim.api.nvim_exec_autocmds('BufLeave', { buffer = buf })
    assert.equal('Original R', mapping(buf, 'R').desc)
    vim.api.nvim_exec_autocmds('BufEnter', { buffer = buf })
    assert.equal('R', mapping(buf, 'R').desc)

    vim.api.nvim_exec_autocmds('BufLeave', { buffer = buf })
    vim.api.nvim_exec_autocmds('WinEnter', { buffer = buf })
    assert.equal('R', mapping(buf, 'R').desc)
    package.loaded['opencode.ui.renderer'] = renderer
  end)

  it('refreshes a persistent output buffer when setup runs again', function()
    vim.keymap.set('n', 'R', function() end, { buffer = buf, desc = 'Original R' })
    local renderer = package.loaded['opencode.ui.renderer']
    package.loaded['opencode.ui.renderer'] = {
      get_actions_for_line = function()
        return { action('R') }
      end,
    }

    contextual_actions.setup_contextual_actions({ output_buf = buf })
    vim.api.nvim_exec_autocmds('BufHidden', { buffer = buf })
    assert.equal('Original R', mapping(buf, 'R').desc)

    contextual_actions.setup_contextual_actions({ output_buf = buf })
    assert.equal('R', mapping(buf, 'R').desc)
    package.loaded['opencode.ui.renderer'] = renderer
  end)

  it('does not redraw contextual actions while the cursor stays in their range', function()
    contextual_actions.setup_contextual_actions({ output_buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'header', 'text', 'context', '' })
    vim.keymap.set('n', 'R', function() end, { buffer = buf, desc = 'Original R' })

    local renderer = package.loaded['opencode.ui.renderer']
    package.loaded['opencode.ui.renderer'] = {
      get_actions_for_line = function()
        return { action('R', 'undo', { 'message-one' }, { from = 0, to = 3 }) }
      end,
    }

    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    assert.equal('R', mapping(buf, 'R').desc)

    local clear_namespace = stub(vim.api, 'nvim_buf_clear_namespace').invokes(vim.api.nvim_buf_clear_namespace)
    local set_mapping = stub(vim.keymap, 'set').invokes(vim.keymap.set)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })

    assert.equal(0, #clear_namespace.calls)
    assert.equal(0, #set_mapping.calls)
    assert.equal('R', mapping(buf, 'R').desc)
    clear_namespace:revert()
    set_mapping:revert()
    package.loaded['opencode.ui.renderer'] = renderer
  end)

  it('shows, replaces, and clears contextual actions through CursorMoved', function()
    contextual_actions.setup_contextual_actions({ output_buf = buf })
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      { 'user one header', 'user one text', '', 'assistant', 'user two header', 'user two text', '' }
    )
    vim.keymap.set('n', 'R', function() end, { buffer = buf, desc = 'Original R' })

    local renderer = package.loaded['opencode.ui.renderer']
    local api = package.loaded['opencode.api']
    local calls = {}
    package.loaded['opencode.ui.renderer'] = {
      get_actions_for_line = function(line)
        if line <= 2 then
          return { action('R', 'undo', { 'message-one' }, { from = 0, to = 2 }) }
        end
        if line >= 4 and line <= 6 then
          return { action('R', 'undo', { 'message-two' }, { from = 4, to = 6 }) }
        end
      end,
    }
    package.loaded['opencode.api'] = {
      undo = function(id)
        calls[#calls + 1] = id
      end,
    }

    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    assert.equal('R', mapping(buf, 'R').desc)
    mapping(buf, 'R').callback()

    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    assert.equal('R', mapping(buf, 'R').desc)
    mapping(buf, 'R').callback()

    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    assert.equal('Original R', mapping(buf, 'R').desc)
    assert.same({ 'message-one', 'message-two' }, calls)
    package.loaded['opencode.ui.renderer'] = renderer
    package.loaded['opencode.api'] = api
  end)

  it('keeps another buffer lifecycle isolated from an old buffer observer', function()
    contextual_actions.setup_contextual_actions({ output_buf = buf })
    contextual_actions.show_contextual_actions_menu(buf, { action('R') })

    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'other' })
    contextual_actions.setup_contextual_actions({ output_buf = other })
    contextual_actions.show_contextual_actions_menu(other, { action('C') })

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'changed' })
    assert.equal('C', mapping(other, 'C').desc)
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it('dispatches R/C/F through opencode.api with the original message id', function()
    contextual_actions.setup_contextual_actions({ output_buf = buf })
    local api = package.loaded['opencode.api']
    local calls = {}
    package.loaded['opencode.api'] = {
      undo = function(id)
        calls.undo = id
      end,
      copy_message = function(id)
        calls.copy_message = id
      end,
      fork_session = function(id)
        calls.fork_session = id
      end,
    }

    for _, value in ipairs({
      action('R', 'undo', { 'message-r' }),
      action('C', 'copy_message', { 'message-c' }),
      action('F', 'fork_session', { 'message-f' }),
    }) do
      contextual_actions.show_contextual_actions_menu(buf, { value })
      mapping(buf, value.key).callback()
    end

    package.loaded['opencode.api'] = api
    assert.same({ undo = 'message-r', copy_message = 'message-c', fork_session = 'message-f' }, calls)
  end)
end)
