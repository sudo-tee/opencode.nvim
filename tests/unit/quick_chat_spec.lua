local Promise = require('opencode.promise')
local state = require('opencode.state')

describe('quick chat reply ownership', function()
  local originals
  local bufnr
  local notifications

  local function load_quick_chat(result, wait_result)
    local observation = {
      submit = function()
        return Promise.new():resolve(vim.deepcopy(result))
      end,
      interrupt = function()
        return Promise.new():resolve(true)
      end,
    }
    if wait_result then
      observation.wait_until_idle = function()
        return Promise.new():resolve(vim.deepcopy(wait_result))
      end
    end
    local connection = {
      operations = {},
      observe = function(_, ref)
        assert.equals('quick-session', ref.id)
        return observation
      end,
      is_ready = function()
        return true
      end,
    }
    state.jobs.set_server(connection)

    package.loaded['opencode.config'] = {
      prompt_guard = nil,
      debug = { quick_chat = { keep_session = true } },
      keymap = { quick_chat = {} },
      quick_chat = {},
    }
    package.loaded['opencode.context'] = {
      format_quick_chat_message = function()
        return Promise.new():resolve({ text = 'request' })
      end,
    }
    package.loaded['opencode.util'] = {
      check_prompt_allowed = function()
        return true
      end,
      apply_path_map = function(value)
        return value
      end,
    }
    package.loaded['opencode.services.session_runtime'] = {
      create_new_session = function()
        return Promise.new():resolve({ id = 'quick-session', directory = '/workspace' })
      end,
    }
    package.loaded['opencode.services.agent_model'] = {
      initialize_current_model = function()
        return Promise.new():resolve(nil)
      end,
      ensure_current_mode = function()
        return Promise.new():resolve(false)
      end,
    }
    package.loaded['opencode.quick_chat.spinner'] = {
      new = function()
        return { stop = function() end }
      end,
    }
    package.loaded['opencode.quick_chat'] = nil
    return require('opencode.quick_chat')
  end

  before_each(function()
    originals = {
      config = package.loaded['opencode.config'],
      context = package.loaded['opencode.context'],
      util = package.loaded['opencode.util'],
      runtime = package.loaded['opencode.services.session_runtime'],
      agent_model = package.loaded['opencode.services.agent_model'],
      spinner = package.loaded['opencode.quick_chat.spinner'],
      quick_chat = package.loaded['opencode.quick_chat'],
      server = state.opencode_server,
      notify = vim.notify,
    }
    notifications = {}
    vim.notify = function(message)
      notifications[#notifications + 1] = message
    end
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'old code' })
    vim.bo[bufnr].filetype = 'lua'
  end)

  after_each(function()
    vim.notify = originals.notify
    state.jobs.set_server(originals.server)
    package.loaded['opencode.config'] = originals.config
    package.loaded['opencode.context'] = originals.context
    package.loaded['opencode.util'] = originals.util
    package.loaded['opencode.services.session_runtime'] = originals.runtime
    package.loaded['opencode.services.agent_model'] = originals.agent_model
    package.loaded['opencode.quick_chat.spinner'] = originals.spinner
    package.loaded['opencode.quick_chat'] = originals.quick_chat
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it('applies the V1 reply proven to belong to this input', function()
    local quick_chat = load_quick_chat({
      kind = 'reply',
      input_id = 'input-1',
      message = {
        id = 'reply-1',
        kind = 'assistant',
        parent_message_id = 'input-1',
        finish = 'stop',
        content = { { id = 'text-1', kind = 'text', text = 'local answer = true' } },
      },
    })

    quick_chat.quick_chat('replace it'):wait()

    assert.same({ 'local answer = true' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it('does not apply a V1 reply with an unfinished tool', function()
    local quick_chat = load_quick_chat({
      kind = 'reply',
      input_id = 'input-1',
      message = {
        id = 'reply-1',
        kind = 'assistant',
        parent_message_id = 'input-1',
        finish = 'stop',
        content = {
          { id = 'tool-1', kind = 'tool', state = 'running' },
          { id = 'text-1', kind = 'text', text = 'unsafe' },
        },
      },
    })

    quick_chat.quick_chat('replace it'):wait()

    assert.same({ 'old code' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.matches('did not receive a safe reply', notifications[#notifications])
  end)

  it('does not infer a V2 reply from session idle', function()
    local quick_chat = load_quick_chat({ kind = 'accepted', input = { id = 'inbox-1' } }, {
      kind = 'session_idle',
      outcome = 'succeeded',
      idle_at = 1,
    })

    quick_chat.quick_chat('replace it'):wait()

    assert.same({ 'old code' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.matches('cannot associate the completed reply', notifications[#notifications])
  end)
end)
