local M = {}

---@param opts OpencodeCommandRouteOpts
---@return OpencodeSelectionRange|nil
local function parse_range(opts)
  if not (opts.range and opts.range > 0) then
    return nil
  end

  return {
    start = opts.line1,
    stop = opts.line2,
  }
end

---@param command_name string
---@param command_def OpencodeUICommand
---@param args string[]
---@return OpencodeCommandParseError|nil
local function validate_nested_subcommand(command_name, command_def, args)
  local validation = command_def.nested_subcommand
  if not validation then
    return nil
  end

  local nested_subcommand = args[1]
  if not nested_subcommand then
    if validation.allow_empty then
      return nil
    end

    return {
      code = 'invalid_subcommand',
      message = 'Invalid ' .. command_name .. ' subcommand. Use: ' .. table.concat(command_def.completions or {}, ', '),
      subcommand = command_name,
    }
  end

  if vim.tbl_contains(command_def.completions or {}, nested_subcommand) then
    return nil
  end

  return {
    code = 'invalid_subcommand',
    message = 'Invalid ' .. command_name .. ' subcommand. Use: ' .. table.concat(command_def.completions or {}, ', '),
    subcommand = command_name,
  }
end

---@param opts OpencodeCommandRouteOpts
---@param commands table<string, OpencodeUICommand>
---@return OpencodeCommandParseResult
function M.command(opts, commands)
  local raw_args = opts.args or ''
  local argv = vim.split(raw_args, '%s+', { trimempty = true })
  local subcommand = #argv == 0 and 'toggle' or argv[1]
  local subcmd_def = commands[subcommand]
  local range = parse_range(opts)

  if not subcmd_def then
    return {
      ok = false,
      error = {
        code = 'unknown_subcommand',
        message = 'Unknown subcommand: ' .. subcommand,
        subcommand = subcommand,
      },
    }
  end

  if not subcmd_def.execute then
    return {
      ok = false,
      error = {
        code = 'missing_execute',
        message = 'Command is missing execute function: ' .. subcommand,
        subcommand = subcommand,
      },
    }
  end

  local args = #argv == 0 and {} or vim.list_slice(argv, 2)
  local nested_subcommand_error = validate_nested_subcommand(subcommand, subcmd_def, args)
  if nested_subcommand_error then
    return {
      ok = false,
      error = nested_subcommand_error,
    }
  end

  return {
    ok = true,
    intent = {
      command_id = subcommand,
      execute = subcmd_def.execute,
      args = args,
      range = range,
      raw = {
        args = raw_args,
        argv = argv,
        subcommand = subcommand,
      },
    },
  }
end

return M
