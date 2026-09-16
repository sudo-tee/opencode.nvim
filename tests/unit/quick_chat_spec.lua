local Promise = require('opencode.promise')
local state = require('opencode.state')

describe('quick chat', function()
  local originals
  local bufnr
  local notifications

  local function load_quick_chat(message, options)
    options = options or {}
    local submitted = {}
    local observation = {
      request_reply = function(_, input)
        submitted.input = vim.deepcopy(input)
        local promise = Promise.new()
        if options.reply_error then
          promise:reject(options.reply_error)
        else
          promise:resolve(vim.deepcopy(message))
        end
        return {
          promise = promise,
          stop = function()
            submitted.stopped = true
          end,
        }
      end,
    }
    local connection = {
      observe = function(_, ref)
        assert.equals('quick-session', ref.id)
        return observation
      end,
      is_ready = function()
        return true
      end,
      check_health = function()
        return Promise.new():resolve(true)
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
      format_quick_chat_message = function(prompt)
        return Promise.new():resolve({ text = prompt })
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
        if options.create_session then
          return options.create_session()
        end
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
    package.loaded['opencode.quick_chat.spinner'] = options.spinner or {
      new = function()
        return { stop = function() end }
      end,
    }
    package.loaded['opencode.quick_chat'] = nil
    return require('opencode.quick_chat'), submitted
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

  local function assistant_reply(content)
    return {
      id = 'reply-1',
      kind = 'assistant',
      finish = 'stop',
      content = content or { { kind = 'text', text = 'local answer = true' } },
    }
  end

  it('applies the assistant reply and cleans up the request', function()
    local quick_chat, submitted = load_quick_chat(assistant_reply())

    quick_chat.quick_chat('replace it'):wait()

    assert.same({ 'local answer = true' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.is_true(submitted.stopped)
  end)

  it('does not apply a reply with an unfinished tool', function()
    local quick_chat = load_quick_chat(assistant_reply({
      { kind = 'tool', state = 'running' },
      { kind = 'text', text = 'unsafe' },
    }))

    quick_chat.quick_chat('replace it'):wait()

    assert.same({ 'old code' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.matches('did not receive a safe reply', notifications[#notifications])
  end)

  it('reports a reply request failure without changing the buffer', function()
    local quick_chat, submitted = load_quick_chat(nil, { reply_error = 'Request failed' })

    quick_chat.quick_chat('replace it'):wait()

    assert.same({ 'old code' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.matches('Request failed', notifications[#notifications])
    assert.is_true(submitted.stopped)
  end)

  it('requests a reply with the formatted prompt and context', function()
    local quick_chat, submitted = load_quick_chat(assistant_reply())

    quick_chat.quick_chat('replace it'):wait()

    assert.is_string(submitted.input.text)
    assert.matches('replace it', submitted.input.text, 1, true)
    assert.same({}, submitted.input.context)
    assert.same({}, submitted.input.files)
    assert.same({}, submitted.input.agents)
  end)

  it('stops the spinner when session startup fails', function()
    local spinner_stopped = false
    local quick_chat = load_quick_chat(nil, {
      create_session = function()
        return Promise.new():reject('server unavailable')
      end,
      spinner = {
        new = function()
          return {
            stop = function()
              spinner_stopped = true
            end,
          }
        end,
      },
    })

    quick_chat.quick_chat('replace it'):wait()

    assert.is_true(spinner_stopped)
    assert.matches('server unavailable', notifications[#notifications])
  end)
end)
