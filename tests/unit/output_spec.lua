local config = require('opencode.config')
local Output = require('opencode.ui.output')

describe('output fold thresholds', function()
  local original_config

  before_each(function()
    original_config = vim.deepcopy(config.values)
    config.values = vim.deepcopy(config.defaults)
  end)

  after_each(function()
    config.values = original_config
  end)

it('uses the default latest-line preview when only_show_latest_n is not overridden', function()
  config.setup({
    ui = {
      output = {
        tools = {
          folding_threshold = 3,
          },
        },
      },
    })

    local output = Output.new()
    output:add_lines({ '1', '2', '3', '4', '5', '6', '7' })

  output:add_fold_with_threshold(1, true, true)

  assert.same({ { from = 4, to = 4 } }, output.fold_ranges)
end)

it('preserves the current fold behavior when only_show_latest_n is explicitly disabled', function()
  config.setup({
    ui = {
      output = {
        tools = {
          folding_threshold = 3,
          only_show_latest_n = 0,
        },
      },
    },
  })

  local output = Output.new()
  output:add_lines({ '1', '2', '3', '4', '5', '6', '7' })

  output:add_fold_with_threshold(1, true, true)

  assert.same({ { from = 4, to = 7 } }, output.fold_ranges)
end)

  it('keeps the latest lines visible below folds when output is shown', function()
    config.setup({
      ui = {
        output = {
          tools = {
            folding_threshold = 3,
            only_show_latest_n = 2,
          },
        },
      },
    })

    local output = Output.new()
    output:add_lines({ '1', '2', '3', '4', '5', '6', '7' })

    output:add_fold_with_threshold(1, true, true)

    assert.same({ { from = 4, to = 5 } }, output.fold_ranges)
  end)

  it('keeps the latest lines visible when output is otherwise hidden', function()
    config.setup({
      ui = {
        output = {
          tools = {
            show_output = false,
            only_show_latest_n = 2,
          },
        },
      },
    })

    local output = Output.new()
    output:add_lines({ '1', '2', '3', '4', '5', '6', '7' })

    output:add_fold_with_threshold(1, false, true)

    assert.same({ { from = 1, to = 5 } }, output.fold_ranges)
  end)
end)
