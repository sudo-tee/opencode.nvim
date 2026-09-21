local lifecycle = require('opencode.protocols.observation')
local submission = require('opencode.protocols.submission')
local boundary = require('opencode.protocols.v2.observation.boundary')

local M = {}

---@param observation OpencodeV2Observation
---@param reason string
local function fail_admissions(observation, reason)
  observation._v2_delivered = {}
  for _, admission in ipairs(vim.tbl_values(observation._v2_admissions)) do
    admission.finish(nil, 'V2 observation: admission_unknown: ' .. tostring(reason))
  end
end

---@param observation OpencodeV2Observation
---@param reason string
function M.invalidate_submissions(observation, reason)
  observation._v2_stream_generation = observation._v2_stream_generation + 1
  fail_admissions(observation, reason)
end

---@param observation OpencodeV2Observation
function M.execution_ambiguous(observation)
  observation._v2_horizon_ambiguous = true
  fail_admissions(observation, 'overlapping execution horizons')
end

---@param admission OpencodeV2PendingAdmission
---@param terminal OpencodeV2Terminal
local function complete_admission(admission, terminal)
  if terminal.ambiguous then
    admission.finish(nil, 'V2 observation: admission_unknown: multiple inputs delivered in one execution')
    return
  end
  admission.finish({
    kind = 'session_idle',
    outcome = terminal.outcome,
    idle_at = terminal.idle_at,
    error = terminal.error,
  })
end

---@param observation OpencodeV2Observation
---@param input_id string
function M.delivered(observation, input_id)
  local delivery = observation._v2_delivered[input_id] or {}
  observation._v2_delivered[input_id] = delivery
  local admission = observation._v2_admissions[input_id]
  if admission then
    admission.delivery = delivery
  end
end

---@param observation OpencodeV2Observation
---@param terminal OpencodeV2Terminal
function M.execution_finished(observation, terminal)
  local deliveries = 0
  for _, delivery in pairs(observation._v2_delivered) do
    if not delivery.terminal then
      delivery.terminal = terminal
      deliveries = deliveries + 1
    end
  end
  terminal.ambiguous = deliveries > 1
  for _, admission in ipairs(vim.tbl_values(observation._v2_admissions)) do
    if admission.delivery and admission.delivery.terminal == terminal then
      complete_admission(admission, terminal)
    end
  end
end

---@param field OpencodeV2FormField
---@param candidate string
local function option_allowed(field, candidate)
  if type(field.options) ~= 'table' or #field.options == 0 then
    return true
  end
  for _, option in ipairs(field.options) do
    if type(option) == 'table' and option.value == candidate then
      return true
    end
  end
  return field.custom == true
end

---@type table<string, fun(field: OpencodeV2FormField, value: OpencodeV2FormAnswer): boolean>
local answer_validators = {
  string = function(field, value)
    return type(value) == 'string' and option_allowed(field, value)
  end,
  boolean = function(_, value)
    return type(value) == 'boolean'
  end,
  number = function(_, value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
  end,
  integer = function(_, value)
    return type(value) == 'number' and value == value and value % 1 == 0
  end,
  multiselect = function(field, value)
    if type(value) ~= 'table' then
      return false
    end
    for _, selected in ipairs(value) do
      if type(selected) ~= 'string' or not option_allowed(field, selected) then
        return false
      end
    end
    return true
  end,
}

---@param field OpencodeV2FormField
---@param value? OpencodeV2FormAnswer
local function valid_answer(field, value)
  if value == nil then
    return not field.required
  end
  local validate = answer_validators[field.type]
  return validate ~= nil and validate(field, value)
end

---@param observation OpencodeV2Observation
---@param connection OpencodeV2Connection
function M.attach(observation, connection)
  observation._v2_delivered = {}
  observation._v2_admissions = {}
  observation._v2_stream_generation = 0
  observation._v2_horizon_ambiguous = false

  ---@param input OpencodeV2SubmitInput
  ---@return Promise<OpencodeSubmission>
  function observation:submit(input)
    local finish = self:_begin_local_operation()
    local ok, err = pcall(lifecycle.ensure_stream, connection, self)
    if not ok then
      finish()
      error(err, 0)
    end
    local stream_generation = self._v2_stream_generation
    local called, request = pcall(connection.operations.submit, connection, self._session_id, input, nil, nil)
    if not called then
      finish()
      error(request, 0)
    end
    local result = request:and_then(function(admission)
      ---@cast admission OpencodeV2Admission
      if not self:_is_current() then
        boundary.fail('submit response arrived after Observation release')
      end
      if self._v2_admissions[admission.id] then
        boundary.fail('duplicate submit admission')
      end

      local release = self:_begin_local_operation()
      local record = { delivery = self._v2_delivered[admission.id] }
      local handle, complete = submission.new({ kind = 'accepted', input = vim.deepcopy(admission) }, function()
        if self._v2_admissions[admission.id] == record then
          self._v2_admissions[admission.id] = nil
        end
        release()
      end)
      record.finish = complete
      self._v2_admissions[admission.id] = record

      if self._v2_stream_generation ~= stream_generation then
        complete(nil, 'V2 observation: admission_unknown: event stream continuity was lost during submit')
      elseif self._v2_horizon_ambiguous then
        complete(nil, 'V2 observation: admission_unknown: overlapping execution horizons')
      elseif record.delivery and record.delivery.terminal then
        complete_admission(record, record.delivery.terminal)
      end
      return handle
    end)
    return result:finally(finish)
  end
  ---@return Promise<boolean>
  function observation:interrupt()
    return self:_start_action(connection.operations.interrupt, self._session_id)
  end

  ---@param message_id string
  ---@param _? any
  ---@param reverse_path_map? OpencodeV2PathMap
  ---@return Promise<SessionRevertInfo>
  function observation:revert_message(message_id, _, reverse_path_map)
    return self:_start_state_action(connection.operations.revert_message, function(revert)
      if revert.messageID ~= message_id then
        boundary.fail('invalid revert response')
      end
      self:read().session.revert = vim.deepcopy(revert)
      self:_event_changed('session')
      return revert
    end, self._session_id, nil, { messageID = message_id }, nil, reverse_path_map)
  end

  ---@return Promise<boolean>
  function observation:unrevert_messages()
    return self:_start_state_action(connection.operations.unrevert_messages, function()
      self:read().session.revert = nil
      self:_event_changed('session')
      return true
    end, self._session_id)
  end
  ---@param request_id string
  ---@param answer OpencodeV2PermissionAnswer
  ---@return Promise<boolean>
  function observation:reply_permission(request_id, answer)
    local request = self:read().permission_requests_by_id[request_id]
    if not request or request.status ~= 'pending' then
      boundary.fail('permission request is not pending')
    end
    local supported = false
    for _, choice in ipairs(request.choices) do
      supported = supported or choice.value == answer.choice
    end
    if not supported then
      boundary.fail('invalid permission answer')
    end
    return self:_start_action(connection.operations.reply_permission, self._session_id, request_id, {
      reply = answer.choice,
      message = answer.message,
    })
  end

  ---@param request_id string
  ---@param answers OpencodeV2FormAnswers
  ---@return Promise<boolean>
  function observation:reply_question(request_id, answers)
    local request = self:read().question_requests_by_id[request_id]
    if not request or request.status ~= 'pending' or request.unavailable_reason then
      boundary.fail('question request is not answerable')
    end
    local known = {}
    for _, field in ipairs(request.fields) do
      known[field.key] = true
      if not valid_answer(field, answers[field.key]) then
        boundary.fail('invalid answer for question field ' .. field.key)
      end
    end
    for key in pairs(answers) do
      if not known[key] then
        boundary.fail('unknown question field ' .. tostring(key))
      end
    end
    return self:_start_action(connection.operations.reply_question, self._session_id, request_id, answers)
  end

  ---@param request_id string
  ---@return Promise<boolean>
  function observation:reject_question(request_id)
    local request = self:read().question_requests_by_id[request_id]
    if not request or request.status ~= 'pending' then
      boundary.fail('question request is not pending')
    end
    return self:_start_action(connection.operations.cancel_question, self._session_id, request_id)
  end
end

return M
