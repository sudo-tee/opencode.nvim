local config_file = require('opencode.config_file')
local state = require('opencode.state')
local tmpfile = '/tmp/opencode_test_config.json'

local function cleanup()
  os.remove(tmpfile)
end

describe('config_file.set_model', function()
  before_each(function()
    cleanup()
    -- Write config without model
    local f = assert(io.open(tmpfile, 'w'))
    f:write('{"other_key": "value"}')
    f:close()
    config_file.config_file = tmpfile
  end)

  after_each(function()
    cleanup()
  end)

  it('adds model key if missing', function()
    config_file.set_model('provider', 'modelname')
    local f = assert(io.open(tmpfile, 'r'))
    local content = f:read('*a')
    f:close()
    local json = vim.json.decode(content)
    assert.are.equal(json.model, 'provider/modelname')
    assert.are.equal(json.other_key, 'value')
  end)
end)
