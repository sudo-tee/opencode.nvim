---@alias OpencodeV2PathMap fun(path: string): string
---@alias OpencodeV2Outcome 'succeeded'|'failed'|'interrupted'
---@alias OpencodeV2RemoteResource 'session'|'children'|'messages'|'inbox'|'execution'|'permissions'|'questions'

---@class OpencodeV2Location
---@field directory string

---@class OpencodeV2SessionRef
---@field id string
---@field location? OpencodeV2Location

---HTTP operations validate the envelope and normalize absent cursors to an empty table.
---Payload records are interpreted by normalize.lua.
---@class OpencodeV2Page<T>
---@field data T[]
---@field cursor {next?: string, previous?: string}

---@class OpencodeV2Admission
---@field id string

---@class OpencodeV2Children
---@field by_id table<string, table>
---@field order string[]

---@class OpencodeV2Route
---@field resource OpencodeV2RemoteResource
---@field apply OpencodeV2EventHandler

---@alias OpencodeV2LocationListOperation fun(connection: OpencodeV2Connection, location: OpencodeV2Location, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>

---@class OpencodeV2Terminal
---@field outcome OpencodeV2Outcome
---@field idle_at number
---@field error? table
---@field ambiguous? boolean

---@class OpencodeV2Delivery
---@field terminal? OpencodeV2Terminal

---@class OpencodeV2PendingAdmission
---@field delivery? OpencodeV2Delivery
---@field finish fun(value?: OpencodeIdleCompletion, err?: string)

---@class OpencodeV2Mention
---@field start_byte integer Zero-based UTF-8 byte offset
---@field end_byte integer Exclusive UTF-8 byte offset

---@class OpencodeV2ContextInput
---@field text string
---@field source {kind: 'selection'|'diagnostics'|'cursor'|'buffer'|'git_diff', file_name?: string, range?: string}

---@class OpencodeV2FileInput
---@field media_type string
---@field name? string
---@field mention? OpencodeV2Mention
---@field bytes? string Exactly one of bytes and server_uri must be provided
---@field server_uri? string Absolute file URI

---@class OpencodeV2AgentInput
---@field name string
---@field mention? OpencodeV2Mention

---@class OpencodeV2SubmitInput
---@field text string
---@field context OpencodeV2ContextInput[]
---@field files OpencodeV2FileInput[]
---@field agents OpencodeV2AgentInput[]
---@field agent? string
---@field model? {providerID: string, modelID: string}
---@field variant? string Requires model
---@field system? string Rejected by V2; present in the shared submission contract
---@field tools? table<string, boolean> Nonempty tool overrides are rejected by V2

---@class OpencodeV2ModelInput
---@field providerID string
---@field id string
---@field variant? string

---@class OpencodeV2CommandInput
---@field command string
---@field arguments? string
---@field agent? string
---@field model? string provider/model
---@field variant? string
---@field files? table[]
---@field agents? table[]
---@field skills? table[]

---@class OpencodeV2PermissionAnswer
---@field choice 'once'|'always'|'reject'
---@field message? string

---@alias OpencodeV2FormAnswer string|number|boolean|string[]
---@alias OpencodeV2FormAnswers table<string, OpencodeV2FormAnswer>

---@class OpencodeV2FormField
---@field key string
---@field type string Server-defined; unsupported types are not answerable
---@field required? boolean
---@field options? {value: string, label?: string}[]
---@field custom? boolean

---@class OpencodeV2Event
---@field type string Unknown event types are ignored
---@field created number
---@field data table Native payload; route validates envelope once, handlers validate variants
---@field id? string

---@alias OpencodeV2EventHandler fun(observation: OpencodeV2Observation, event: OpencodeV2Event, data: table): false|'terminal'|nil

---@class OpencodeV2Observation: OpencodeObservation
---@field _connection OpencodeV2Connection
---@field _v2_admissions table<string, OpencodeV2PendingAdmission>
---@field _v2_delivered table<string, OpencodeV2Delivery>
---@field _v2_stream_generation integer
---@field _v2_horizon_ambiguous boolean
---@field _v2_terminal_seen_since_start boolean
---@field _v2_execution_event_active boolean
---@field _v2_content_by_message table<string, table<string, table>>
---@field _v2_older_cursor? string
---@field _v2_history_complete boolean
---@field _v2_older_loading boolean
---@field _v2_inbox_terminal table<string, table>
---@field _v2_permission_terminal table<string, {answer: string}>
---@field _v2_question_terminal table<string, {status: string, answers?: OpencodeV2FormAnswers}>
---@field submit fun(self: OpencodeV2Observation, input: OpencodeV2SubmitInput): Promise<OpencodeSubmission>
---@field load_older fun(self: OpencodeV2Observation): Promise
---@field load_complete_history fun(self: OpencodeV2Observation): Promise
---@field interrupt fun(self: OpencodeV2Observation): Promise<boolean>
---@field revert_message fun(self: OpencodeV2Observation, message_id: string, unused?: any, reverse_path_map?: OpencodeV2PathMap): Promise<SessionRevertInfo>
---@field unrevert_messages fun(self: OpencodeV2Observation): Promise<boolean>
---@field reply_permission fun(self: OpencodeV2Observation, request_id: string, answer: OpencodeV2PermissionAnswer): Promise<boolean>
---@field reply_question fun(self: OpencodeV2Observation, request_id: string, answers: OpencodeV2FormAnswers): Promise<boolean>
---@field reject_question fun(self: OpencodeV2Observation, request_id: string): Promise<boolean>

---@class OpencodeV2Connection: OpencodeServer
---@field operations OpencodeV2Operations
---@field observations table<string, OpencodeV2Observation>

return {}
