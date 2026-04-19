local image_handler = require('opencode.image_handler')
local context = require('opencode.context')

describe('image_handler', function()
  local function assert_has_sta(args)
    local has_sta = false
    for _, arg in ipairs(args) do
      if arg == '-STA' then
        has_sta = true
        break
      end
    end
    assert.is_true(has_sta)
  end
  local original_fn = vim.fn
  local original_system = vim.system
  local original_uv = vim.uv
  local original_context_add_file = context.add_file
  local original_notify = vim.notify
  local original_os_date = os.date

  local mocks = {
    executable = {},
    system_calls = {},
    clipboard_content = nil,
    temp_dir = '/tmp/test_dir',
    os_name = 'Darwin',
    wsl_distro = 0,
    added_files = {},
    notifications = {},
  }

  before_each(function()
    mocks = {
      executable = {},
      system_calls = {},
      clipboard_content = nil,
      temp_dir = '/tmp/test_dir',
      os_name = 'Darwin',
      wsl_distro = 0,
      added_files = {},
      notifications = {},
      existing_files = {},
    }

    vim.fn = setmetatable({
      executable = function(cmd)
        return mocks.executable[cmd] or 0
      end,
      tempname = function()
        return mocks.temp_dir
      end,
      mkdir = function() end,
      getfsize = function(path)
        for _, f in ipairs(mocks.existing_files) do
          if f == path then
            return 100
          end
        end
        return 0
      end,
      has = function(feature)
        if feature == 'win32' then
          return mocks.os_name == 'Windows_NT' and 1 or 0
        end
        return 0
      end,
      getreg = function(reg)
        if reg == '+' then
          return mocks.clipboard_content
        end
        return ''
      end,
      exists = function(var)
        if var == '$WSL_DISTRO_NAME' then
          return mocks.wsl_distro
        end
        return 0
      end,
      fnamemodify = function(path, _)
        return path
      end,
    }, {
      __index = original_fn,
    })

    vim.system = function(cmd, opts)
      table.insert(mocks.system_calls, { cmd = cmd, opts = opts })
      return {
        wait = function()
          if cmd[1] == 'wslpath' then
            return { code = 0, stdout = 'C:\\Windows\\Path' }
          end
          return { code = 0 }
        end,
      }
    end

    vim.uv = {
      os_uname = function()
        return { sysname = mocks.os_name }
      end,
    }

    context.add_file = function(path)
      table.insert(mocks.added_files, path)
    end

    vim.notify = function(msg, level)
      table.insert(mocks.notifications, { msg = msg, level = level })
    end

    os.date = function(fmt)
      if fmt == '%Y%m%d_%H%M%S' then
        return '20240101_120000'
      end
      return original_os_date(fmt)
    end
  end)

  after_each(function()
    vim.fn = original_fn
    vim.system = original_system
    vim.uv = original_uv
    context.add_file = original_context_add_file
    vim.notify = original_notify
    os.date = original_os_date
  end)

  it('handles Darwin clipboard with osascript', function()
    mocks.os_name = 'Darwin'
    mocks.executable['osascript'] = 1
    table.insert(mocks.existing_files, '/tmp/test_dir/pasted_image_20240101_120000.png')

    local success = image_handler.paste_image_from_clipboard()

    assert.is_true(success)
    assert.equals(1, #mocks.added_files)
    assert.equals('/tmp/test_dir/pasted_image_20240101_120000.png', mocks.added_files[1])
    assert.is_true(#mocks.system_calls > 0)
    local cmd = mocks.system_calls[1].cmd
    assert.matches('osascript', cmd[3])
  end)

  it('handles Linux clipboard with wl-paste', function()
    mocks.os_name = 'Linux'
    mocks.executable['wl-paste'] = 1
    mocks.executable['xclip'] = 0
    table.insert(mocks.existing_files, '/tmp/test_dir/pasted_image_20240101_120000.png')

    local success = image_handler.paste_image_from_clipboard()

    assert.is_true(success)
    assert.equals(1, #mocks.added_files)
    assert.matches('wl%-paste', mocks.system_calls[1].cmd[3])
  end)

  it('handles Linux clipboard with xclip', function()
    mocks.os_name = 'Linux'
    mocks.executable['wl-paste'] = 0
    mocks.executable['xclip'] = 1
    table.insert(mocks.existing_files, '/tmp/test_dir/pasted_image_20240101_120000.png')

    local success = image_handler.paste_image_from_clipboard()

    assert.is_true(success)
    assert.equals(1, #mocks.added_files)
    assert.matches('xclip', mocks.system_calls[1].cmd[3])
  end)

  it('handles Windows clipboard', function()
    mocks.os_name = 'Windows_NT'
    mocks.executable['powershell.exe'] = 1
    table.insert(mocks.existing_files, '/tmp/test_dir/pasted_image_20240101_120000.png')

    local success = image_handler.paste_image_from_clipboard()

    assert.is_true(success)
    assert.equals(1, #mocks.added_files)
    local cmd_args = mocks.system_calls[1].cmd
    assert.equals('powershell.exe', cmd_args[1])
    assert_has_sta(cmd_args)
  end)

  it('handles WSL clipboard as Windows', function()
    mocks.os_name = 'Linux'
    mocks.wsl_distro = 1
    mocks.executable['powershell.exe'] = 1
    table.insert(mocks.existing_files, '/tmp/test_dir/pasted_image_20240101_120000.png')

    local success = image_handler.paste_image_from_clipboard()

    assert.is_true(success)
    assert.equals(1, #mocks.added_files)

    -- First call should be wslpath
    assert.equals('wslpath', mocks.system_calls[1].cmd[1])

    -- Second call should be powershell.exe with -STA
    local cmd_args = mocks.system_calls[2].cmd
    assert.equals('powershell.exe', cmd_args[1])
    assert_has_sta(cmd_args)
  end)

  it('falls back to base64 clipboard if system command fails', function()
    mocks.os_name = 'Darwin'
    mocks.executable['osascript'] = 0 -- Force failure of system tool
    mocks.clipboard_content = 'data:image/png;base64,fakebasedata'
    table.insert(mocks.existing_files, '/tmp/test_dir/pasted_image_20240101_120000.png')

    local success = image_handler.paste_image_from_clipboard()

    assert.is_true(success)
    assert.equals(1, #mocks.added_files)
    assert.equals('/tmp/test_dir/pasted_image_20240101_120000.png', mocks.added_files[1])
    local cmd_info = mocks.system_calls[1]
    assert.matches('base64', cmd_info.cmd[3])
  end)

  it('fails gracefully when no image is found', function()
    mocks.os_name = 'Darwin'
    mocks.executable['osascript'] = 0
    mocks.clipboard_content = ''

    local success = image_handler.paste_image_from_clipboard()

    assert.is_false(success)
    assert.equals(0, #mocks.added_files)
    assert.equals(1, #mocks.notifications)
    assert.equals('No image found in clipboard.', mocks.notifications[1].msg)
  end)

  it('fails gracefully when base64 data is invalid', function()
    mocks.os_name = 'Darwin'
    mocks.executable['osascript'] = 0
    mocks.clipboard_content = 'invalid data'

    local success = image_handler.paste_image_from_clipboard()

    assert.is_false(success)
    assert.equals(0, #mocks.added_files)
  end)

  it('restores image path when file exists and name is valid', function()
    mocks.os_name = 'Darwin'
    mocks.executable['osascript'] = 1
    -- Initialize cached_temp_dir
    image_handler.paste_image_from_clipboard()

    local img_name = 'pasted_image_test.png'
    local expected_path = mocks.temp_dir .. '/' .. img_name
    table.insert(mocks.existing_files, expected_path)

    local restored_path = image_handler.restore_img_path(img_name)
    assert.equals(expected_path, restored_path)
  end)

  it('returns nil when restoring image path with invalid name', function()
    mocks.os_name = 'Darwin'
    mocks.executable['osascript'] = 1
    image_handler.paste_image_from_clipboard()

    local restored_path = image_handler.restore_img_path('not_a_pasted_image.png')
    assert.is_nil(restored_path)
  end)

  it('returns nil when restoring image path and file does not exist', function()
    mocks.os_name = 'Darwin'
    mocks.executable['osascript'] = 1
    image_handler.paste_image_from_clipboard()

    local img_name = 'pasted_image_missing.png'

    local restored_path = image_handler.restore_img_path(img_name)
    assert.is_nil(restored_path)
  end)
end)
