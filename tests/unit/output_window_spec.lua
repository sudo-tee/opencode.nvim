local config = require('opencode.config')
local output_window = require('opencode.ui.output_window')

describe('output_window.create_buf', function()
  local original_config

  before_each(function()
    original_config = vim.deepcopy(config.values)
    config.values = vim.deepcopy(config.defaults)
  end)

  after_each(function()
    config.values = original_config
  end)

  it('uses default output filetype', function()
    config.setup({})
    local buf = output_window.create_buf()

    local filetype = vim.api.nvim_get_option_value('filetype', { buf = buf })
    assert.equals('opencode_output', filetype)

    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it('uses configured output filetype', function()
    config.setup({
      ui = {
        output = {
          filetype = 'markdown',
        },
      },
    })

    local buf = output_window.create_buf()
    local filetype = vim.api.nvim_get_option_value('filetype', { buf = buf })

    assert.equals('markdown', filetype)

    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)
