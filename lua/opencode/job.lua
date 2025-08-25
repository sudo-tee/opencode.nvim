local context = require('opencode.context')
local state = require('opencode.state')
local util = require('opencode.util')
local Job = require('plenary.job')

local M = {}

---@param opts? {no_context: boolean, model?: string, agent?: string} Optional settings for execution
function M.build_args(prompt, opts)
  opts = opts or {}
  if not prompt then
    return nil
  end
  local message = opts.no_context == true and prompt or context.format_message(prompt)
  local args = { 'run', message }

  if state.active_session then
    table.insert(args, '-s')
    table.insert(args, state.active_session.name)
  end

  if opts.agent or state.current_mode then
    table.insert(args, '--agent')
    table.insert(args, opts.agent or state.current_mode)
  end

  if opts.model or state.current_model then
    table.insert(args, '--model')
    table.insert(args, opts.model or state.current_model)
  end

  table.insert(args, '--print-logs')

  return args
end

--- Executes the opencode command with the given prompt and handlers
---@param prompt string The user prompt to send to opencode
---@param handlers table A table containing handler functions
---@param opts? {no_context: boolean, model?: string, agent?: string} Optional settings for execution
function M.execute(prompt, handlers, opts)
  if not prompt then
    return nil
  end

  local args = M.build_args(prompt, opts)

  state.opencode_run_job = Job:new({
    interactive = false,
    command = 'opencode',
    args = args,
    on_start = function()
      vim.schedule(function()
        handlers.on_start()
      end)
    end,
    on_stdout = function(_, out)
      if out then
        vim.schedule(function()
          handlers.on_output(out)
        end)
      end
    end,
    on_stderr = function(err, data)
      vim.schedule(function()
        ---@see https://github.com/sst/opencode/issues/369
        if err then
          handlers.on_error(data)
        else
          handlers.on_output(data)
        end
      end)
    end,
    on_exit = function(data, code)
      if code == nil then
        vim.schedule(function()
          handlers.on_interrupt()
        end)
        return
      end
      if code ~= 0 then
        vim.schedule(function()
          handlers.on_error(util.strip_ansi(table.concat(data._stderr_results, '\n')))
        end)
        return
      end
      vim.schedule(function()
        handlers.on_exit(code)
      end)
    end,
  })

  state.opencode_run_job:start()
end

function M.stop(job)
  if job then
    pcall(function()
      vim.uv.process_kill(job.handle)
      job:shutdown()
    end)
  end
end

return M
