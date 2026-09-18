---@class OpencodeBuiltinSlashCommand
---@field command_name string
---@field preset_args? string[]
---@field cmd_str string
---@field desc? string
---@field args? boolean

local M = {}

---@type table<string, OpencodeBuiltinSlashCommand>
local definitions = {
  ['/help'] = { command_name = 'help', cmd_str = 'help' },
  ['/agent'] = { command_name = 'agent', preset_args = { 'select' }, cmd_str = 'agent select' },
  ['/agents_init'] = { command_name = 'session', preset_args = { 'agents_init' }, cmd_str = 'session agents_init' },
  ['/child-sessions'] = { command_name = 'session', preset_args = { 'navigate', 'child', 'picker' }, cmd_str = 'session navigate child picker' },
  ['/command-list'] = { command_name = 'commands_list', cmd_str = 'commands_list' },
  ['/compact'] = { command_name = 'session', preset_args = { 'compact' }, cmd_str = 'session compact' },
  ['/history'] = { command_name = 'history', cmd_str = 'history' },
  ['/mcp'] = { command_name = 'mcp', cmd_str = 'mcp' },
  ['/models'] = { command_name = 'models', cmd_str = 'models' },
  ['/variant'] = { command_name = 'variant', cmd_str = 'variant' },
  ['/new'] = { command_name = 'session', preset_args = { 'new' }, cmd_str = 'session new' },
  ['/redo'] = { command_name = 'redo', cmd_str = 'redo' },
  ['/sessions'] = { command_name = 'session', preset_args = { 'select' }, cmd_str = 'session select' },
  ['/skills'] = { command_name = 'skills', cmd_str = 'skills' },
  ['/share'] = { command_name = 'session', preset_args = { 'share' }, cmd_str = 'session share' },
  ['/clear_selections'] = { command_name = 'clear_selections', cmd_str = 'clear_selections' },
  ['/clear_files'] = { command_name = 'clear_files', cmd_str = 'clear_files' },
  ['/timeline'] = { command_name = 'timeline', cmd_str = 'timeline' },
  ['/references'] = { command_name = 'references', cmd_str = 'references' },
  ['/undo'] = { command_name = 'undo', cmd_str = 'undo' },
  ['/unshare'] = { command_name = 'session', preset_args = { 'unshare' }, cmd_str = 'session unshare' },
  ['/rename'] = { command_name = 'session', preset_args = { 'rename' }, cmd_str = 'session rename' },
  ['/thinking'] = { command_name = 'toggle_reasoning_output', cmd_str = 'toggle_reasoning_output' },
  ['/reasoning'] = { command_name = 'toggle_reasoning_output', cmd_str = 'toggle_reasoning_output' },
  ['/review'] = { command_name = 'review', cmd_str = 'review', args = true },
}

---@return table<string, OpencodeBuiltinSlashCommand>
function M.get_definitions()
  return definitions
end

return M
