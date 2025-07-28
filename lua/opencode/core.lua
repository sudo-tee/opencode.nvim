local M = {}
local state = require('opencode.state')
local context = require('opencode.context')
local session = require('opencode.session')
local ui = require('opencode.ui.ui')
local job = require('opencode.job')
local input_window = require('opencode.ui.input_window')

function M.select_session()
  local all_sessions = session.get_all_workspace_sessions() or {}
  local filtered_sessions = vim.tbl_filter(function(s)
    return s.description ~= '' and s ~= nil
  end, all_sessions)

  ui.select_session(filtered_sessions, function(selected_session)
    if not selected_session then
      if state.windows then
        ui.focus_input()
      end
      return
    end
    state.active_session = selected_session
    if state.windows then
      ui.render_output()
      ui.scroll_to_bottom()
      ui.focus_input()
    else
      M.open()
    end
  end)
end

function M.open(opts)
  opts = opts or { focus = 'input', new_session = false }

  if not M.opencode_ok() then
    return
  end

  local are_windows_closed = state.windows == nil

  if are_windows_closed then
    state.windows = ui.create_windows()
  end

  if opts.new_session then
    state.active_session = nil
    state.last_sent_context = nil
    ui.clear_output()
  else
    if not state.active_session then
      state.active_session = session.get_last_workspace_session()
    end

    if are_windows_closed or ui.is_output_empty() then
      ui.render_output()
      ui.scroll_to_bottom()
    end
  end

  if opts.focus == 'input' then
    ui.focus_input({ restore_position = are_windows_closed })
  elseif opts.focus == 'output' then
    ui.focus_output({ restore_position = are_windows_closed })
  end
end

function M.run(prompt, opts)
  if not M.opencode_ok() then
    return false
  end
  M.before_run(opts)

  -- Add small delay to ensure stop is complete
  vim.defer_fn(function()
    job.execute(prompt, {
      on_start = function()
        state.was_interrupted = false
        M.after_run(prompt)
      end,
      on_output = function(output)
        -- Reload all modified file buffers
        vim.cmd('checktime')

        if output and not state.active_session then
          local found = string.match(output, 'sessionID=(ses_%w+)')
          if found then
            state.active_session = session.get_by_name(found)
            state.new_session_name = found
          end
        end
        state.last_output = os.time()
        ui.render_output()
      end,
      on_error = function(err)
        vim.notify(err, vim.log.levels.ERROR)

        ui.close_windows(state.windows)
      end,
      on_exit = function()
        state.opencode_run_job = nil
        ui.render_output()
      end,
      on_interrupt = function()
        state.opencode_run_job = nil
        state.was_interrupted = true

        ui.render_output()
        vim.notify('Opencode run interrupted by user', vim.log.levels.WARN)
      end,
    })
  end, 10)
end

function M.after_run(prompt)
  context.unload_attachments()
  state.last_sent_context = vim.deepcopy(context.context)
  require('opencode.history').write(prompt)

  if state.windows then
    ui.render_output()
  end
end

function M.before_run(opts)
  M.stop()

  opts = opts or {}

  M.open({
    new_session = opts.new_session or not state.active_session,
  })
end

function M.add_file_to_context()
  local picker = require('opencode.ui.file_picker')
  require('opencode.ui.mention').mention(function(mention_cb)
    picker.pick(function(file)
      mention_cb(file.name)
      context.add_file(file.path)
    end)
  end)
end

function M.configure_provider()
  local cfg = require('opencode.config_file')
  require('opencode.provider').select(function(selection)
    if not selection then
      if state.windows then
        ui.focus_input()
      end
      return
    end
    cfg.set_model(selection.provider, selection.model)

    if state.windows then
      require('opencode.ui.topbar').render()
      ui.focus_input()
    else
      vim.notify('Changed provider to ' .. selection.display, vim.log.levels.INFO)
    end
  end)
end

function M.stop()
  if state.opencode_run_job then
    job.stop(state.opencode_run_job)
  end
  state.opencode_run_job = nil
  if state.windows then
    ui.stop_render_output()
    ui.render_output()
    input_window.set_content('')
    require('opencode.history').index = nil
    ui.focus_input()
  end
end

function M.opencode_ok()
  if vim.fn.executable('opencode') == 0 then
    vim.notify(
      'opencode command not found - please install and configure opencode before using this plugin',
      vim.log.levels.ERROR
    )
    return false
  end
  return true
end

return M
