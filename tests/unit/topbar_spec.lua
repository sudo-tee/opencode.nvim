local helpers = require('tests.helpers')
local state = require('opencode.state')
local store = require('opencode.state.store')
local config_file = require('opencode.config_file')
local topbar = require('opencode.ui.topbar')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')

describe('topbar model metrics', function()
  local original_state
  local providers_stub

  before_each(function()
    original_state = vim.deepcopy(store.state())
    helpers.replay_setup()
    providers_stub = stub(config_file, 'get_opencode_providers')
  end)

  after_each(function()
    providers_stub:revert()
    topbar.close()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
    for key, value in pairs(original_state) do
      store.set_raw(key, value)
    end
  end)

  it('rerenders context percentage after the provider catalog loads', function()
    local providers = Promise.new()
    providers_stub.returns(providers)
    state.model.set_model('anthropic/claude')
    state.renderer.set_stats(100, 1.25)

    topbar.render()
    vim.wait(50, function()
      return false
    end)

    providers:resolve({
      providers = {
        {
          id = 'anthropic',
          models = { claude = { limit = { context = 1000 } } },
        },
      },
    })

    assert.is_true(vim.wait(1000, function()
      local winbar = vim.wo[state.windows.output_win].winbar or ''
      return winbar:find('10.0%%', 1, true) ~= nil
    end))
  end)
end)
