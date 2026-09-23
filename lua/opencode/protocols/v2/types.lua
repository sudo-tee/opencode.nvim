---@alias OpencodeV2PathMap fun(path: string): string
---@alias OpencodeV2Outcome 'succeeded'|'failed'|'interrupted'
---@alias OpencodeV2RemoteResource 'session'|'children'|'messages'|'inbox'|'execution'|'permissions'|'questions'

---@class OpencodeV2SessionRef
---@field id string
---@field location? OpencodeLocation

---HTTP operations validate the envelope and normalize absent cursors to an empty table.
---Payload records are interpreted by normalize.lua.
---@class OpencodeV2Page<T>
---@field data T[]
---@field cursor {next?: string, previous?: string}

---@class OpencodeV2Admission
---@field id string

---@class OpencodeV2Children
---@field by_id table<string, table|nil>
---@field order string[]

---@class OpencodeV2Route
---@field resource OpencodeV2RemoteResource
---@field apply OpencodeV2EventHandler

---@alias OpencodeV2LocationListOperation fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>

---@class OpencodeV2PermissionReply
---@field reply 'once'|'always'|'reject'
---@field message? string

---@class OpencodeV2Operations
---@field get_current_project fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field get_config fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field list_providers fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<{location: OpencodeLocation, data: table[]}>
---@field list_sessions fun(connection: OpencodeV2Connection, location?: OpencodeLocation, cursor?: string, limit?: integer, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<OpencodeV2Page<table>>
---@field list_sessions_project fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>
---@field list_sessions_global fun(connection: OpencodeV2Connection, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>
---@field list_active_sessions fun(connection: OpencodeV2Connection): Promise<table<string, {type: 'running'}>>
---@field list_inbox fun(connection: OpencodeV2Connection, session_id: string, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>
---@field create_session fun(connection: OpencodeV2Connection, location: OpencodeLocation, input?: table, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field get_session fun(connection: OpencodeV2Connection, session_id: string, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field delete_session fun(connection: OpencodeV2Connection, session_id: string): Promise<boolean>
---@field rename_session fun(connection: OpencodeV2Connection, session_id: string, location: OpencodeLocation?, title: string): Promise<boolean>
---@field init_session fun(): never
---@field share_session fun(): never
---@field unshare_session fun(): never
---@field summarize_session fun(connection: OpencodeV2Connection, session_id: string): Promise<OpencodeV2Admission>
---@field fork_session fun(connection: OpencodeV2Connection, session_id: string, location?: OpencodeLocation, input?: {messageID?: string}, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field revert_message fun(connection: OpencodeV2Connection, session_id: string, location: OpencodeLocation?, input: {messageID: string}, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<SessionRevertInfo>
---@field unrevert_messages fun(connection: OpencodeV2Connection, session_id: string): Promise<boolean>
---@field list_messages fun(connection: OpencodeV2Connection, session_id: string, cursor?: string, limit?: integer, reverse_path_map?: OpencodeV2PathMap): Promise<OpencodeV2Page<table>>
---@field set_session_agent fun(connection: OpencodeV2Connection, session_id: string, agent: string): Promise<boolean>
---@field set_session_model fun(connection: OpencodeV2Connection, session_id: string, model: OpencodeV2ModelInput): Promise<boolean>
---@field send_command fun(connection: OpencodeV2Connection, session_id: string, location: OpencodeLocation?, input: OpencodeV2CommandInput): Promise<boolean>
---@field submit fun(connection: OpencodeV2Connection, session_id: string, input: OpencodeV2SubmitInput, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<OpencodeV2Admission>
---@field interrupt fun(connection: OpencodeV2Connection, session_id: string): Promise<boolean>
---@field list_permissions OpencodeV2LocationListOperation
---@field reply_permission fun(connection: OpencodeV2Connection, session_id: string, request_id: string, answer: OpencodeV2PermissionReply): Promise<boolean>
---@field list_questions OpencodeV2LocationListOperation
---@field reply_question fun(connection: OpencodeV2Connection, session_id: string, request_id: string, answer: OpencodeV2FormAnswers): Promise<boolean>
---@field cancel_question fun(connection: OpencodeV2Connection, session_id: string, request_id: string): Promise<boolean>
---@field list_agents OpencodeV2LocationListOperation
---@field list_models OpencodeV2LocationListOperation
---@field get_default_model fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field get_model_catalog fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field list_primary_agents fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<string[]>
---@field list_subagents fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<string[]>
---@field get_user_commands fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table<string, table>>
---@field list_commands OpencodeV2LocationListOperation
---@field list_skills OpencodeV2LocationListOperation
---@field list_mcp_servers OpencodeV2LocationListOperation
---@field find_files fun(connection: OpencodeV2Connection, query: string, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<string[]>
---@field get_file_status fun(connection: OpencodeV2Connection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>
---@field connect_mcp fun(connection: OpencodeV2Connection, name: string, location: OpencodeLocation, path_map?: OpencodeV2PathMap): Promise<boolean>
---@field disconnect_mcp fun(connection: OpencodeV2Connection, name: string, location: OpencodeLocation, path_map?: OpencodeV2PathMap): Promise<boolean>
---@field subscribe_events fun(connection: OpencodeV2Connection, on_chunk: fun(chunk: string), on_disconnect?: fun(reason: any)): table

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

---@class OpencodeV2MessageTime
---@field created? number
---@field streamed? number
---@field completed? number

---@class OpencodeV2TokenCache
---@field read? number
---@field write? number

---@class OpencodeV2TokenUsage
---@field input? number
---@field output? number
---@field reasoning? number
---@field cache? OpencodeV2TokenCache

---@class OpencodeV2ModelReference
---@field providerID string
---@field id string
---@field variant? string

---@class OpencodeV2NormalizedModel
---@field providerID string
---@field modelID string
---@field variant? string

---@class OpencodeV2NormalizedFileAttachment
---@field kind 'file'
---@field uri string
---@field media_type string
---@field name? string
---@field mention? OpencodeV2Mention
---@field source? {kind: 'resource', uri: string}

---@class OpencodeV2ValidatedFileMention
---@field start integer
---@field ['end'] integer
---@field text string

---@class OpencodeV2ValidatedFileAttachment
---@field mime string
---@field data string
---@field name? string
---@field mention? OpencodeV2ValidatedFileMention
---@field source? {kind: 'resource', uri: string}

---@class OpencodeV2NormalizedTextToolResult
---@field kind 'text'
---@field text string

---@class OpencodeV2NormalizedFileToolResult
---@field kind 'file'
---@field uri string
---@field media_type string
---@field name? string

---@alias OpencodeV2NormalizedToolResult OpencodeV2NormalizedTextToolResult|OpencodeV2NormalizedFileToolResult

---@class OpencodeV2Session
---@field id string
---@field parentID? string
---@field projectID string
---@field agent? string
---@field model? OpencodeV2NormalizedModel
---@field cost? number
---@field tokens? OpencodeV2TokenUsage
---@field outcome? string
---@field time {created: number, updated: number, idle?: number, viewed?: number, archived?: number}
---@field title? string
---@field location OpencodeLocation
---@field subpath? string
---@field metadata? table
---@field permissions? table
---@field revert? table

---@class OpencodeV2InboxItem
---@field id string
---@field session_id string
---@field kind string
---@field delivery 'steer'|'queue'
---@field status string
---@field created_at_ms number

---@class OpencodeV2PermissionRequest
---@field id string
---@field session_id string
---@field action string
---@field resources table
---@field choices table[]
---@field status string
---@field message? string
---@field source? table
---@field answer? string

---@class OpencodeV2QuestionRequest
---@field id string
---@field session_id string
---@field title? string
---@field fields OpencodeV2FormField[]
---@field status string
---@field unavailable_reason? string
---@field answers? OpencodeV2FormAnswers

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
---@field prompt? string
---@field title? string
---@field required? boolean
---@field options? {value: string, label?: string}[]
---@field custom? boolean
---@field minimum? number
---@field maximum? number
---@field min_items? integer
---@field max_items? integer

---@class OpencodeV2Event
---@field type string Unknown event types are ignored
---@field created number
---@field data table Native payload; route validates envelope once, handlers validate variants
---@field id? string

---@alias OpencodeV2EventHandler fun(observation: OpencodeV2Observation, event: OpencodeV2Event, data: table): false|'terminal'|nil

---@class OpencodeV2Observation: OpencodeObservation
---@field _connection OpencodeV2Connection
---@field _v2_admissions table<string, OpencodeV2PendingAdmission|nil>
---@field _v2_delivered table<string, OpencodeV2Delivery|nil>
---@field _v2_stream_generation integer
---@field _v2_horizon_ambiguous boolean
---@field _v2_terminal_seen_since_start boolean
---@field _v2_execution_event_active boolean
---@field _v2_content_by_message table<string, table<string, table|nil>|nil>
---@field _v2_older_cursor? string
---@field _v2_history_complete boolean
---@field _v2_older_loading boolean
---@field _v2_inbox_terminal table<string, table|nil>
---@field _v2_permission_terminal table<string, {answer: string}|nil>
---@field _v2_question_terminal table<string, {status: string, answers?: OpencodeV2FormAnswers}|nil>
---@field submit fun(self: OpencodeV2Observation, input: OpencodeV2SubmitInput): Promise<OpencodeSubmission>
---@field load_older fun(self: OpencodeV2Observation): Promise<nil>
---@field load_complete_history fun(self: OpencodeV2Observation): Promise<nil>
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
