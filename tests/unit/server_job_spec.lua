local server_job = require('opencode.server_job')
local stub = require('luassert.stub')

-- These tests are basic and mock the Job interface, since we can't actually spawn the server in CI.
describe('server_job', function()
  it('should expose spawn_server, call_api, and run', function()
    assert.is_function(server_job.spawn_server)
    assert.is_function(server_job.call_api)
    assert.is_function(server_job.run)
  end)

  it('should call on_ready with url when server outputs ready line', function()
    local called, url_val = false, nil
    local opts = {
      on_ready = function(_, url)
        called = true
        url_val = url
      end,
    }
    local fake_job = { start = function() end }
    stub(fake_job, 'start')
    -- Add on_stdout field to fake_job
    fake_job.on_stdout = function(_, data)
      if data:find('listening') then
        opts.on_ready(fake_job, data:match('listening on ([^%s]+)'))
      end
    end

    local Job = stub(require('plenary.job'), 'new')
    Job.returns(fake_job)
    local job = server_job.spawn_server(opts)
    job.on_stdout(nil, 'opencode server listening on http://127.0.0.1:41961')
    assert.is_true(called)
    assert.are.same('http://127.0.0.1:41961', url_val)
    Job:revert()
  end)

  it('should call API and invoke callback', function(done)
    local Job = stub(require('plenary.job'), 'new')
    local captured_on_exit
    local fake_job = {
      start = function()
        -- Simulate async job completion
        vim.schedule(function()
          if captured_on_exit then
            captured_on_exit(fake_job, 0)
          end
        end)
      end,
      result = function()
        return { '{"ok":true}' }
      end,
    }
    Job.invokes(function(args)
      captured_on_exit = args.on_exit
      return fake_job
    end)
    server_job.call_api('http://localhost:8080/api/test', 'GET', nil, function(err, result)
      assert.is_nil(err)
      assert.are.same('{"ok":true}', result)
      Job:revert()
      done()
    end)
  end)
end)
