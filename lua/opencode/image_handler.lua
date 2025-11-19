--- Image pasting functionality from clipboard
--- @see https://github.com/sst/opencode/blob/45180104fe84e2d0b9d29be0f9f8a5e52d18e102/packages/opencode/src/cli/cmd/tui/util/clipboard.ts
local context = require('opencode.context')
local state = require('opencode.state')

local M = {}

--- Check if a file exists and has content
--- @param path string
--- @return boolean
local function is_valid_file(path)
  return vim.fn.getfsize(path) > 0
end

--- Run shell command and return success
--- @param cmd string
--- @return boolean
local function run_shell_cmd(cmd)
  return vim.system({ 'sh', '-c', cmd }):wait().code == 0
end

--- Save base64 data to file
--- @param data string
--- @param path string
--- @return boolean
local function save_base64(data, path)
  if vim.fn.has('win32') == 1 then
    local script =
      string.format('[System.IO.File]::WriteAllBytes("%s", [System.Convert]::FromBase64String("%s"))', path, data)
    return vim.system({ 'powershell.exe', '-command', '-' }, { stdin = script }):wait().code == 0
  else
    local decode_arg = vim.uv.os_uname().sysname == 'Darwin' and '-D' or '-d'
    return vim.system({ 'sh', '-c', string.format('base64 %s > "%s"', decode_arg, path) }, { stdin = data }):wait().code
      == 0
  end
end

--- macOS clipboard image handler using osascript
--- @param path string
--- @return boolean
local function handle_darwin_clipboard(path)
  if vim.fn.executable('osascript') ~= 1 then
    return false
  end
  local cmd = string.format(
    "osascript -e 'set imageData to the clipboard as \"PNGf\"' -e 'set fileRef to open for access POSIX file \"%s\" with write permission' -e 'set eof fileRef to 0' -e 'write imageData to fileRef' -e 'close access fileRef'",
    path
  )
  return run_shell_cmd(cmd)
end

--- Linux clipboard image handler supporting Wayland and X11
--- @param path string
--- @return boolean
local function handle_linux_clipboard(path)
  if vim.fn.executable('wl-paste') == 1 and run_shell_cmd(string.format('wl-paste -t image/png > "%s"', path)) then
    return true
  end
  return vim.fn.executable('xclip') == 1
    and run_shell_cmd(string.format('xclip -selection clipboard -t image/png -o > "%s"', path))
end

--- Windows clipboard image handler using PowerShell
--- @param path string
--- @return boolean
local function handle_windows_clipboard(path)
  if vim.fn.executable('powershell.exe') ~= 1 then
    return false
  end
  local script = string.format(
    [[
      Add-Type -AssemblyName System.Windows.Forms;
      $img = [System.Windows.Forms.Clipboard]::GetImage();
      if ($img) {
        $img.Save('%s', [System.Drawing.Imaging.ImageFormat]::Png);
      } else {
        exit 1
      }
    ]],
    path
  )
  return vim.system({ 'powershell.exe', '-command', '-' }, { stdin = script }):wait().code == 0
end

local handlers = {
  Darwin = handle_darwin_clipboard,
  Linux = handle_linux_clipboard,
  Windows_NT = handle_windows_clipboard,
}

--- Try to get image from system clipboard
--- @param image_path string
--- @return boolean
local function try_system_clipboard(image_path)
  local os_name = vim.uv.os_uname().sysname
  local handler = handlers[os_name]

  -- WSL detection and override
  if vim.fn.exists('$WSL_DISTRO_NAME') == 1 then
    handler = handlers.Windows_NT
  end

  return handler and handler(image_path) and is_valid_file(image_path) or false
end

--- Try to parse base64 image data from clipboard
--- @param temp_dir string
--- @param timestamp string
--- @return boolean, string?
local function try_base64_clipboard(temp_dir, timestamp)
  local content = vim.fn.getreg('+')
  if not content or content == '' then
    return false
  end

  local format, data = content:match('^data:image/([^;]+);base64,(.+)$')
  if not format or not data then
    return false
  end

  local image_path = string.format('%s/pasted_image_%s.%s', temp_dir, timestamp, format)
  local success = save_base64(data, image_path) and is_valid_file(image_path)

  return success, success and image_path or nil
end

--- Handle clipboard image data by saving it to a file and adding it to context
--- @return boolean success True if image was successfully handled
function M.paste_image_from_clipboard()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')
  local timestamp = os.date('%Y%m%d_%H%M%S')
  local image_path = string.format('%s/pasted_image_%s.png', temp_dir, timestamp)

  local success = try_system_clipboard(image_path)

  if not success then
    local base64_success, base64_path = try_base64_clipboard(temp_dir, timestamp --[[@as string]])
    success = base64_success
    if base64_path then
      image_path = base64_path
    end
  end

  if success then
    context.add_file(image_path)
    state.context_updated_at = os.time()
    vim.notify('Image saved and added to context: ' .. vim.fn.fnamemodify(image_path, ':t'), vim.log.levels.INFO)
    return true
  end

  vim.notify('No image found in clipboard.', vim.log.levels.WARN)
  return false
end

return M
