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
  end

  if opts.timeout then
    table.insert(args, '--max-time')
    table.insert(args, tostring(math.ceil(opts.timeout / 1000)))
  end

  table.insert(args, opts.url)

  return args
end

-- Header names whose values should never be logged.
local SENSITIVE_HEADER_NAMES = {
  authorization = true,
  ['proxy-authorization'] = true,
  cookie = true,
}

-- Query parameters whose values should never be logged.
local SENSITIVE_QUERY_PARAMS = {
  access_token = true,
  token = true,
  api_key = true,
  key = true,
  auth = true,
}

local function redact_query_params(str)
  return str:gsub('([?&])([^=&]+)=([^&]*)', function(prefix, key)
    if SENSITIVE_QUERY_PARAMS[key:lower()] then
      return prefix .. key .. '=REDACTED'
    end

    return prefix .. key .. '='
  end)
end

local function redact_url(url)
  return redact_query_params(url:gsub('^(https?://)[^/@]+@', '%1REDACTED@'))
end

local function redact_header(header)
  local name = header:match('^%s*([^:]+):')
  if not name or not SENSITIVE_HEADER_NAMES[name:lower()] then
    return header
  end

  return name .. ': REDACTED'
end

-- Returns a copy of `args` with sensitive values redacted for logging.
local function sanitize_args(args)
  local out = {}
  local i = 1

  while i <= #args do
    local arg = args[i]

    if (arg == '-H' or arg == '--header') and args[i + 1] then
      out[#out + 1] = arg
      out[#out + 1] = redact_header(args[i + 1])
      i = i + 2
    elseif arg == '--url' and args[i + 1] then
      out[#out + 1] = arg
      out[#out + 1] = redact_url(args[i + 1])
      i = i + 2
    elseif type(arg) == 'string' then
      out[#out + 1] = arg:match('^https?://') and redact_url(arg) or redact_query_params(arg)

      i = i + 1
    else
      out[#out + 1] = arg
      i = i + 1
    end
  end

  return out
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
  local safe_args = sanitize_args(args)
  log.debug('curl.request: executing command: %s', table.concat(safe_args, ' '))

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
          local err_msg = (result.stderr and result.stderr ~= '') and result.stderr or 'curl failed'
          opts.on_error({ message = err_msg })
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
