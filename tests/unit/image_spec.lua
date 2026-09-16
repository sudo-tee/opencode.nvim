local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')
local image = require('opencode.ui.image')
local mention = require('opencode.ui.mention')
local state = require('opencode.state')

describe('image rendering', function()
  local original_img
  local original_config
  local buf
  local win
  local path
  local set_calls
  local del_calls

  local function write_png_header(width, height)
    local function be_u32(value)
      return string.char(
        math.floor(value / 0x1000000) % 0x100,
        math.floor(value / 0x10000) % 0x100,
        math.floor(value / 0x100) % 0x100,
        value % 0x100
      )
    end

    local file = assert(io.open(path, 'wb'))
    file:write('\137PNG\r\n\026\n', string.char(0, 0, 0, 13), 'IHDR', be_u32(width), be_u32(height))
    file:close()
  end

  before_each(function()
    original_img = vim.ui.img
    original_config = vim.deepcopy(config.values)
    config.values = vim.deepcopy(config.defaults)
    set_calls = {}
    del_calls = {}
    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, 'p')
    path = temp_dir .. '/pasted_image_test.png'
    local file = assert(io.open(path, 'wb'))
    file:write('\137PNG\r\n\026\n')
    file:close()

    local next_id = 0
    vim.ui.img = {
      set = function(data_or_id, opts)
        next_id = next_id + 1
        table.insert(set_calls, { data_or_id = data_or_id, opts = opts })
        return next_id
      end,
      del = function(id)
        table.insert(del_calls, id)
        return true
      end,
    }

    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'image link' })
    win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = 80,
      height = 10,
      row = 0,
      col = 0,
    })
    state.ui.set_windows({ output_buf = buf, output_win = win })
  end)

  after_each(function()
    image.clear_preview()
    image.clear_output()
    state.ui.set_windows(nil)
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.fn.delete, path)
    vim.ui.img = original_img
    config.values = original_config
  end)

  it('renders a file image one screen row below its output link', function()
    image.set_output_images('part', { { path = path, line = 1 } }, 0)

    vim.wait(100, function()
      return #set_calls > 0
    end)

    assert.equals(1, #set_calls)
    assert.equals('\137PNG\r\n\026\n', set_calls[1].data_or_id:sub(1, 8))
    assert.is_number(set_calls[1].opts.row)
    assert.is_number(set_calls[1].opts.col)
    assert.equals(config.ui.output.images.width, set_calls[1].opts.width)
    assert.equals(image.get_height(path), set_calls[1].opts.height)

    image.refresh_output()
    assert.equals(1, #set_calls)

    image.refresh_output(true)
    assert.equals(2, #set_calls)
    assert.equals(1, set_calls[2].data_or_id)

    image.clear_output_part('part')
    assert.equals(1, #del_calls)
  end)

  it('emits image metadata for PNG file parts', function()
    local output = formatter.format_part({
      type = 'file',
      filename = 'screenshot.png',
      mime = 'image/png',
      source = { path = path },
    }, {
      info = { role = 'user' },
      parts = {},
    }, false, { interactive = true })

    assert.same({ { path = path, line = 1, mime = 'image/png' } }, output:get_images())
    assert.equals(2, output:get_line_count())
  end)

  it('derives bounded image height from PNG dimensions', function()
    write_png_header(100, 100)
    assert.equals(10, image.get_height(path))

    config.values.ui.output.images.width = 21
    write_png_header(1, 4294967295)
    assert.equals(1000, image.get_height(path))

    config.values.ui.output.images.width = 22
    write_png_header(0, 100)
    assert.equals(1, image.get_height(path))
  end)

  it('resolves the URL when restored file metadata has no usable source path', function()
    local resolved = image.path_for_part({
      type = 'file',
      filename = 'missing.png',
      mime = 'image/png',
      source = { path = '/missing/screenshot.png' },
      url = 'file://' .. path,
    })

    assert.equals(path, resolved)
  end)

  it('finds the mention under the cursor', function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'before @pasted_image.png after' })

    local found = mention.get_at_position(buf, 1, 10)

    assert.same({ name = 'pasted_image.png', start_col = 7, end_col = 24 }, found)
  end)
end)
