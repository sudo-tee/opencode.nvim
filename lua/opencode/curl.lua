local M = {}

--- Build curl command arguments from options
--- @param opts table Options for the curl request
--- @return table args Array of curl command arguments
local function build_curl_args(opts)
  local args = { 'curl', '-s', '--no-buffer' }

  if opts.method and opts.method ~= 'GET' then
    table.insert(args, '-X')
    table.insert(args, opts.method)
  end

  if opts.headers then
    for key, value in pairs(opts.headers) do
      table.insert(args, '-H')
      table.insert(args, key .. ': ' .. value)
    end
  end

  if opts.body then
    table.insert(args, '-d')
    table.insert(args, '@-') -- Read from stdin
  end

  if opts.proxy and opts.proxy ~= '' then
    table.insert(args, '--proxy')
    table.insert(args, opts.proxy)
  elseif opts.proxy == '' then
    table.insert(args, '--noproxy')
    table.insert(args, '*')
  end

  if opts.timeout then
    table.insert(args, '--max-time')
    table.insert(args, tostring(math.ceil(opts.timeout / 1000))) -- Convert ms to seconds
  end

  table.insert(args, opts.url)

  return args
end

--- Parse HTTP response headers and body
--- @param output string Raw curl output with headers
--- @return table response Response object with status, headers, and body
local function parse_response(output)
  local lines = vim.split(output, '\n')
  local status = 200
  local headers = {}
  local body_start = 1

  -- Find status line and headers
  for i, line in ipairs(lines) do
    if line:match('^HTTP/') then
      status = math.floor(tonumber(line:match('HTTP/[%d%.]+%s+(%d+)')) or 200)
    elseif line:match('^[%w%-]+:') then
      local key, value = line:match('^([%w%-]+):%s*(.*)$')
      if key and value then
        headers[key:lower()] = value
      end
    elseif line == '' then
      body_start = i + 1
      break
    end
  end

  local body_lines = {}
  for i = body_start, #lines do
    table.insert(body_lines, lines[i])
  end
  local body = table.concat(body_lines, '\n')

  return {
    status = status,
    headers = headers,
    body = body,
  }
end

--- Make an HTTP request
--- @param opts table Request options
--- @return table|nil job Job object for streaming requests, nil for regular requests
function M.request(opts)
  local args = build_curl_args(opts)

  local log = require('opencode.log')
  log.debug('curl.request: executing command: %s', table.concat(args, ' '))

  if opts.stream then
    local buffer = ''
    -- job.pid is not cleared on process exit
    local is_running = true

    local job_opts = {
      stdout = function(err, chunk)
        if err then
          if opts.on_error then
            opts.on_error({ message = err })
          end
          return
        end

        if chunk then
          buffer = buffer .. chunk

          -- Extract complete lines
          while buffer:find('\n') do
            local line, rest = buffer:match('([^\n]*\n)(.*)')
            if line then
              opts.stream(nil, line)
              buffer = rest
            else
              break
            end
          end
        end
      end,
      stderr = function(err, data)
        if err and opts.on_error then
          opts.on_error({ message = err })
        end
      end,
    }

    if opts.body then
      job_opts.stdin = opts.body
    end

    local job = vim.system(args, job_opts, function(result)
      is_running = false

      if buffer and buffer ~= '' then
        opts.stream(nil, buffer)
      end

      if opts.on_exit then
        opts.on_exit(result.code, result.signal)
      end
    end)

    return {
      _job = job,
      is_running = function()
        return is_running
      end,
      shutdown = function()
        -- Flip state before kill so callers immediately observe shutdown.
        is_running = false
        if job and job.pid then
          pcall(function()
            job:kill(15) -- SIGTERM
          end)
        end
      end,
    }
  else
    table.insert(args, 2, '-i')

    local job_opts = {
      text = true,
    }

    if opts.body then
      job_opts.stdin = opts.body
    end

    vim.system(args, job_opts, function(result)
      if result.code ~= 0 then
        if opts.on_error then
          opts.on_error({ message = result.stderr or 'curl failed' })
        end
        return
      end

      local response = parse_response(result.stdout or '')

      if opts.callback then
        opts.callback(response)
      end
    end)
  end
end

return M
