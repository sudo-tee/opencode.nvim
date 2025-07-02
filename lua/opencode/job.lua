-- opencode.nvim/lua/opencode/job.lua
-- Contains opencode job execution logic

local context = require('opencode.context')
local state = require('opencode.state')
local Job = require('plenary.job')

local M = {}

function M.build_args(prompt)
  if not prompt then
    return nil
  end
  local message = context.format_message(prompt)
  local args = { 'run', message }

  if state.active_session then
    table.insert(args, '-s')
    table.insert(args, state.active_session.name)
  end
  return args
end

function M.execute(prompt, handlers)
  if not prompt then
    return nil
  end

  local args = M.build_args(prompt)

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
        if err then
          handlers.on_error(data)
        else
          handlers.on_output(data)
        end
      end)
    end,
    on_exit = function()
      vim.schedule(function()
        handlers.on_exit()
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
