local assert = require('luassert')
local stub = require('luassert.stub')
local Promise = require('opencode.promise')
local base_picker = require('opencode.ui.base_picker')
local model_picker = require('opencode.model_picker')
local server_job = require('opencode.server_job')
local state = require('opencode.state')

describe('opencode.model_picker', function()
  local original_pick

  before_each(function()
    original_pick = base_picker.pick
  end)

  after_each(function()
    base_picker.pick = original_pick
    if server_job.ensure_server.revert then
      server_job.ensure_server:revert()
    end
  end)

  it('starts the server before loading models', function()
    local ensure_server = stub(server_job, 'ensure_server').returns(Promise.new():resolve({
      operations = {
        get_model_catalog = function()
          return Promise.new():resolve({
            providers = {
              {
                id = 'openai',
                name = 'OpenAI',
                models = {
                  gpt = { id = 'gpt', name = 'GPT' },
                },
              },
            },
          })
        end,
      },
    }))

    local picker_opened = false
    base_picker.pick = function()
      picker_opened = true
    end
    state.jobs.clear_server()

    model_picker.select(function() end):wait()

    assert.stub(ensure_server).was_called()
    assert.is_true(picker_opened)
  end)
end)
