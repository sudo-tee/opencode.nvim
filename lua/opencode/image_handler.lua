local context = require('opencode.context')
local state = require('opencode.state')

local M = {}

--- Check if a file was successfully created and has content
--- @param path string File path to check
--- @return boolean success True if file exists and has content
local function is_valid_file(path)
  return vim.fn.filereadable(path) == 1 and vim.fn.getfsize(path) > 0
end

--- Try to extract image from macOS clipboard
--- @param image_path string Path where to save the image
--- @return boolean success True if image was extracted successfully
local function try_macos_clipboard(image_path)
  if vim.fn.executable('osascript') ~= 1 then
    return false
  end

  local osascript_cmd = string.format(
    'osascript -e \'set imageData to the clipboard as "PNGf"\' '
      .. '-e \'set fileRef to open for access POSIX file "%s" with write permission\' '
      .. "-e 'set eof fileRef to 0' "
      .. "-e 'write imageData to fileRef' "
      .. "-e 'close access fileRef'",
    image_path
  )

  local result = vim.system({ 'sh', '-c', osascript_cmd }):wait()
  return result.code == 0 and is_valid_file(image_path)
end

--- Try to extract image from Linux clipboard (Wayland)
--- @param image_path string Path where to save the image
--- @return boolean success True if image was extracted successfully
local function try_wayland_clipboard(image_path)
  if vim.fn.executable('wl-paste') ~= 1 then
    return false
  end

  local cmd = string.format('wl-paste -t image/png > "%s"', image_path)
  local result = vim.system({ 'sh', '-c', cmd }):wait()
  return result.code == 0 and is_valid_file(image_path)
end

--- Try to extract image from Linux clipboard (X11)
--- @param image_path string Path where to save the image
--- @return boolean success True if image was extracted successfully
local function try_x11_clipboard(image_path)
  if vim.fn.executable('xclip') ~= 1 then
    return false
  end

  local cmd = string.format('xclip -selection clipboard -t image/png -o > "%s"', image_path)
  local result = vim.system({ 'sh', '-c', cmd }):wait()
  return result.code == 0 and is_valid_file(image_path)
end

--- Try to extract image from Windows/WSL clipboard
--- @param image_path string Path where to save the image
--- @return boolean success True if image was extracted successfully
local function try_windows_clipboard(image_path)
  if vim.fn.executable('powershell.exe') ~= 1 then
    return false
  end

  local powershell_script = [[
    Add-Type -AssemblyName System.Windows.Forms; 
    $img = [System.Windows.Forms.Clipboard]::GetImage(); 
    if ($img) { 
      $ms = New-Object System.IO.MemoryStream; 
      $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); 
      [System.Convert]::ToBase64String($ms.ToArray()) 
    }
  ]]

  local result = vim.system({ 'powershell.exe', '-command', powershell_script }):wait()
  if result.code ~= 0 or not result.stdout or result.stdout:gsub('%s', '') == '' then
    return false
  end

  local base64_data = result.stdout:gsub('%s', '')
  local decode_cmd = string.format('echo "%s" | base64 -d > "%s"', base64_data, image_path)
  local decode_result = vim.system({ 'sh', '-c', decode_cmd }):wait()
  return decode_result.code == 0 and is_valid_file(image_path)
end

--- Try to extract image from clipboard as base64 text
--- @param temp_dir string Temporary directory
--- @param timestamp string Timestamp for filename
--- @return string|nil image_path Path to extracted image, or nil if failed
local function try_base64_clipboard(temp_dir, timestamp)
  local clipboard_content = vim.fn.getreg('+')
  if not clipboard_content or not clipboard_content:match('^data:image/[^;]+;base64,') then
    return nil
  end

  local format, base64_data = clipboard_content:match('^data:image/([^;]+);base64,(.+)$')
  if not format or not base64_data then
    return nil
  end

  local image_path = temp_dir .. '/pasted_image_' .. timestamp .. '.' .. format
  local decode_cmd = string.format('echo "%s" | base64 -d > "%s"', base64_data, image_path)
  local result = vim.system({ 'sh', '-c', decode_cmd }):wait()

  if result.code == 0 and is_valid_file(image_path) then
    return image_path
  end
  return nil
end

--- Get error message for missing clipboard tools
--- @param os_name string Operating system name
--- @return string error_message Error message with installation instructions
local function get_clipboard_error_message(os_name)
  local install_msg = 'No image found in clipboard. Install clipboard tools: '
  if os_name == 'Linux' then
    return install_msg .. 'xclip (X11) or wl-clipboard (Wayland)'
  elseif os_name == 'Darwin' then
    return install_msg .. 'system clipboard should work natively'
  else
    return install_msg .. 'PowerShell (Windows/WSL)'
  end
end

--- Handle clipboard image data by saving it to a file and adding it to context
--- @return boolean success True if image was successfully handled
function M.paste_image_from_clipboard()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')
  local timestamp = os.date('%Y%m%d_%H%M%S')
  local image_path = temp_dir .. '/pasted_image_' .. timestamp .. '.png'

  local os_name = vim.uv.os_uname().sysname
  local success = false

  if os_name == 'Darwin' then
    success = try_macos_clipboard(image_path)
  elseif os_name == 'Windows_NT' or vim.fn.exists('$WSL_DISTRO_NAME') == 1 then
    success = try_windows_clipboard(image_path)
  elseif os_name == 'Linux' then
    success = try_wayland_clipboard(image_path) or try_x11_clipboard(image_path)
  end

  if not success then
    local fallback_path = try_base64_clipboard(temp_dir, timestamp)
    if fallback_path then
      image_path = fallback_path
      success = true
    end
  end

  if not success then
    vim.notify(get_clipboard_error_message(os_name), vim.log.levels.WARN)
    return false
  end

  context.add_file(image_path)
  state.context_updated_at = os.time()

  local filename = vim.fn.fnamemodify(image_path, ':t')
  vim.notify(string.format('Image saved and added to context: %s', filename), vim.log.levels.INFO)

  return true
end

return M
