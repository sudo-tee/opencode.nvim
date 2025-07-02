-- Minimal init.lua for testing opencode.nvim
-- This init file is used by the test harness

-- Disable loading of user config
vim.opt.runtimepath:remove(vim.fn.expand("~/.config/nvim"))
vim.opt.packpath:remove(vim.fn.expand("~/.local/share/nvim/site"))

-- Add the plugin to the runtimepath
local plugin_root = vim.fn.expand("$PWD")
vim.opt.runtimepath:append(plugin_root)

-- Add plenary to the runtimepath for testing
local plenary_path = plugin_root .. "/deps/plenary.nvim"

-- Check if plenary exists, if not, clone it
if vim.fn.isdirectory(plenary_path) ~= 1 then
  -- Create deps directory if it doesn't exist
  if vim.fn.isdirectory(plugin_root .. "/deps") ~= 1 then
    vim.fn.mkdir(plugin_root .. "/deps", "p")
  end
  
  print("Cloning plenary.nvim for testing...")
  local clone_cmd = "git clone --depth 1 https://github.com/nvim-lua/plenary.nvim.git " .. plenary_path
  vim.fn.system(clone_cmd)
end

vim.opt.runtimepath:append(plenary_path)

-- Setup globals for testing
_G.test_plugin_root = plugin_root

-- For debugging
vim.opt.termguicolors = true

-- Load plugin (but only the essentials for testing)
require('opencode')
