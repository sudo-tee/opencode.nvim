local image_handler = require('opencode.image_handler')
local context = require('opencode.context')

describe('image_handler', function()
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
    }

    vim.fn = setmetatable({
      executable = function(cmd)
        return mocks.executable[cmd] or 0
      end,
      tempname = function()
        return mocks.temp_dir
      end,
      mkdir = function() end,
      getfsize = function(_)
        return 100 -- Simulating non-empty file
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

    local success = image_handler.paste_image_from_clipboard()

    assert.is_true(success)
    assert.equals(1, #mocks.added_files)
    assert.matches('wl%-paste', mocks.system_calls[1].cmd[3])
  end)

  it('handles Linux clipboard with xclip', function()
    mocks.os_name = 'Linux'
    mocks.executable['wl-paste'] = 0
    mocks.executable['xclip'] = 1

    local success = image_handler.paste_image_from_clipboard()

    assert.is_true(success)
    assert.equals(1, #mocks.added_files)
    assert.matches('xclip', mocks.system_calls[1].cmd[3])
  end)

  it('handles Windows clipboard', function()
    mocks.os_name = 'Windows_NT'
    mocks.executable['powershell.exe'] = 1

    local success = image_handler.paste_image_from_clipboard()

    assert.is_true(success)
    assert.equals(1, #mocks.added_files)
    local cmd_args = mocks.system_calls[1].cmd
    assert.equals('powershell.exe', cmd_args[1])
  end)

  it('handles WSL clipboard as Windows', function()
    mocks.os_name = 'Linux'
    mocks.wsl_distro = 1
    mocks.executable['powershell.exe'] = 1

    local success = image_handler.paste_image_from_clipboard()

    assert.is_true(success)
    assert.equals(1, #mocks.added_files)
    local cmd_args = mocks.system_calls[1].cmd
    assert.equals('powershell.exe', cmd_args[1])
  end)

  it('falls back to base64 clipboard if system command fails', function()
    mocks.os_name = 'Darwin'
    mocks.executable['osascript'] = 0 -- Force failure of system tool
    mocks.clipboard_content = 'data:image/png;base64,fakebasedata'

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
end)
