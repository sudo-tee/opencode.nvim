local agent = require('opencode.commands.handlers.agent')
local agent_model = require('opencode.services.agent_model')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local log = require('opencode.log')
local model_state = require('opencode.model_state')
local stub = require('luassert.stub')

describe('agent selection', function()
  local stubs, saved, callback, visible, focus, notify, persist

  local function replace(object, name, fn)
    local replacement = stub(object, name)
    if fn then replacement.invokes(fn) end
    stubs[#stubs + 1] = replacement
    return replacement
  end

  before_each(function()
    stubs = {}
    saved = {
      model = state.current_model,
      mode = state.current_mode,
      variant = state.current_variant,
      overrides = state.user_mode_model_map,
    }
    state.store.set_raw('current_model', 'old/model')
    state.store.set_raw('current_mode', 'build')
    state.store.set_raw('current_variant', 'low')
    state.store.set_raw('user_mode_model_map', { plan = 'plan/model' })
    visible = true
    replace(state.ui, 'is_visible', function() return visible end)
    focus = replace(ui, 'focus_input')
    notify = replace(log, 'notify')
    persist = replace(model_state, 'set_variant')
    replace(model_state, 'get_variant', function() return 'saved' end)
    for _, module in ipairs({ 'opencode.model_picker', 'opencode.variant_picker' }) do
      replace(require(module), 'select', function(selected) callback = selected end)
    end
  end)

  after_each(function()
    for _, replacement in ipairs(stubs) do replacement:revert() end
    state.store.set_raw('current_model', saved.model)
    state.store.set_raw('current_mode', saved.mode)
    state.store.set_raw('current_variant', saved.variant)
    state.store.set_raw('user_mode_model_map', saved.overrides)
  end)

  for _, shown in ipairs({ true, false }) do
    for _, kind in ipairs({ 'provider', 'variant' }) do
      local panel = shown and 'visible' or 'hidden'
      it('applies a selected ' .. kind .. ' with the panel ' .. panel, function()
        visible = shown
        agent.actions['configure_' .. kind]()
        local message
        if kind == 'provider' then
          callback({ provider = 'new', model = 'model' })
          assert.equals('new/model', state.current_model)
          assert.same({ plan = 'plan/model', build = 'new/model' }, state.user_mode_model_map)
          assert.equals('saved', state.current_variant)
          message = 'Changed provider to new/model'
        else
          callback({ value = 'high', name = 'high' })
          assert.equals('high', state.current_variant)
          assert.stub(persist).was_called_with('old', 'model', 'high')
          message = 'Changed variant to high'
        end
        if shown then
          assert.stub(focus).was_called(1)
          assert.stub(notify).was_not_called()
        else
          assert.stub(focus).was_not_called()
          assert.stub(notify).was_called_with(message, vim.log.levels.INFO)
        end
      end)

      it('cancels the ' .. kind .. ' picker with the panel ' .. panel, function()
        visible = shown
        agent.actions['configure_' .. kind]()
        callback(nil)
        assert.equals('old/model', state.current_model)
        assert.equals('low', state.current_variant)
        assert.same({ plan = 'plan/model' }, state.user_mode_model_map)
        assert.stub(persist).was_not_called()
        assert.stub(notify).was_not_called()
        if shown then
          assert.stub(focus).was_called(1)
        else
          assert.stub(focus).was_not_called()
        end
      end)
    end
  end

  it('applies a model without an active mode or UI interaction', function()
    state.store.set_raw('current_mode', nil)
    assert.equals('new/model', agent_model.set_model('new', 'model'))
    assert.same({ plan = 'plan/model' }, state.user_mode_model_map)
    assert.stub(focus).was_not_called()
    assert.stub(notify).was_not_called()
  end)

  it('persists selection of the default variant', function()
    agent.actions.configure_variant()
    callback({ name = 'default' })
    assert.is_nil(state.current_variant)
    assert.stub(persist).was_called(1)
    assert.stub(persist).was_called_with('old', 'model', nil)
  end)

  it('shares variant application and persistence with cycling', function()
    local Promise = require('opencode.promise')
    local config_file = require('opencode.config_file')
    replace(config_file, 'get_opencode_providers', function() return Promise.new():resolve({}) end)
    replace(config_file, 'get_model_info', function() return { variants = { low = {}, high = {} } } end)
    agent_model.cycle_variant():wait()
    assert.equals('high', state.current_variant)
    assert.stub(persist).was_called(1)
    assert.stub(persist).was_called_with('old', 'model', 'high')
  end)

  it('persists a real variant picker selection only once', function()
    require('opencode.variant_picker').select:revert()
    local Promise = require('opencode.promise')
    local config_file = require('opencode.config_file')
    replace(config_file, 'get_opencode_providers', function() return Promise.new():resolve({}) end)
    replace(config_file, 'get_model_info', function() return { variants = { high = {} } } end)
    local choose
    replace(require('opencode.ui.base_picker'), 'pick', function(options) choose = options.callback end)
    agent.actions.configure_variant()
    assert.is_true(vim.wait(1000, function() return choose ~= nil end))
    choose({ name = 'high', value = 'high' })
    assert.equals('high', state.current_variant)
    assert.stub(persist).was_called(1)
    assert.stub(persist).was_called_with('old', 'model', 'high')
  end)
end)
