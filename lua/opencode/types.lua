
---@class OpencodeDiagnostic
---@field message string
---@field severity number
---@field lnum number
---@field col number
---@field end_lnum? number
---@field end_col? number
---@field source? string
---@field code? string|number
---@field user_data? any

---@class OpencodeConfigFile
---@field theme string
---@field autoshare boolean
---@field autoupdate boolean
---@field model string
---@field agent table<string, table>
---@field mcp table<string, table>
---@field mode table<string, table>
---@field command table<string, table>
---@field plugin table[]
---@field username string

---@class OpencodeProject
---@field id string
---@field worktree string
---@field vcs string
---@field time { created: number }

---@class OpencodePath
---@field state string
---@field config string
---@field worktree string
---@field directory string

---@class OpencodeCommand
---@field description string
---@field agent string
---@field model string
---@field template string

---@class OpencodeUICommand
---@field desc string
---@field execute fun(args: string[], range: OpencodeSelectionRange|nil): any
---@field completions? string[]
---@field nested_subcommand? OpencodeNestedSubcommandValidation
---@field completion_provider_id? string
---@field sub_completions? string[]
---@field nargs? string|integer
---@field range? boolean
---@field complete? boolean

---@class OpencodeNestedSubcommandValidation
---@field allow_empty boolean

---@class OpencodeCommandSubcommandSpec
---@field completions? string[]
---@field nested_subcommand? OpencodeNestedSubcommandValidation
---@field sub_completions? string[]
---@field completion_provider_id? string

---@class OpencodeCommandApi
---@field [string] any

---@alias OpencodeCommandHandler fun(api: OpencodeCommandApi, args: string[], range?: OpencodeSelectionRange): any
---@alias OpencodeCommandHandlerMap table<string, OpencodeCommandHandler>

---@class OpencodeParsedIntentSource
---@field raw_args string
---@field argv string[]

---@class OpencodeParsedIntent
---@field name string
---@field hook_key? string
---@field args string[]
---@field range OpencodeSelectionRange|nil
---@field source OpencodeParsedIntentSource

---@class OpencodeCommandParseError
---@field code 'unknown_subcommand'|'invalid_subcommand'
---@field message string
---@field subcommand string

---@class OpencodeCommandParseResult
---@field ok boolean
---@field intent? OpencodeParsedIntent
---@field error? OpencodeCommandParseError

---@class OpencodeCommandRouteOpts
---@field args? string
---@field range? integer
---@field line1? integer
---@field line2? integer

---@class OpencodeCommandDispatchError
---@field code 'unknown_subcommand'|'missing_handler'|'missing_execute'|'invalid_subcommand'|'invalid_arguments'|'execute_error'
---@field message string
---@field subcommand? string

---@class OpencodeCommandDispatchResult
---@field ok boolean
---@field intent? OpencodeParsedIntent
---@field result? any
---@field error? OpencodeCommandDispatchError

---@class OpencodeCommandActionContext
---@field parsed OpencodeCommandParseResult
---@field intent? OpencodeParsedIntent
---@field args? string[]
---@field range? OpencodeSelectionRange|nil
---@field execute? fun(args: string[], range: OpencodeSelectionRange|nil): any

---@class SessionRevertInfo
---@field messageID string
---@field partID? string
---@field snapshot string
---@field diff string

---@class SessionShareInfo
---@field url string

---@class Session
---@field workspace string
---@field title string
---@field time { created: number, updated: number }
---@field id string
---@field parentID string|nil
---@field revert? SessionRevertInfo
---@field share? SessionShareInfo

---@class OpencodeKeymapEntry
---@field [1] string # Function name
---@field mode? string|string[] # Mode(s) for the keymap
---@field desc? string # Keymap description
---@field defer_to_completion? boolean # Whether to defer the keymap when completion menu is open

---@class OpencodeKeymapEditor : table<string, OpencodeKeymapEntry>
---@class OpencodeKeymapInputWindow : table<string, OpencodeKeymapEntry>
---@class OpencodeKeymapOutputWindow : table<string, OpencodeKeymapEntry>

---@class OpencodeKeymap
---@field editor OpencodeKeymapEditor
---@field input_window OpencodeKeymapInputWindow
---@field output_window OpencodeKeymapOutputWindow
---@field session_picker OpencodeSessionPickerKeymap
---@field timeline_picker OpencodeTimelinePickerKeymap
---@field history_picker OpencodeHistoryPickerKeymap
---@field quick_chat OpencodeQuickChatKeymap

---@class OpencodeSessionPickerKeymap
---@field delete_session OpencodeKeymapEntry
---@field new_session OpencodeKeymapEntry
---@field rename_session OpencodeKeymapEntry

---@class OpencodeTimelinePickerKeymap
---@field undo OpencodeKeymapEntry
---@field fork OpencodeKeymapEntry

---@class OpencodeHistoryPickerKeymap
---@field delete_entry OpencodeKeymapEntry
---@field clear_all OpencodeKeymapEntry

---@class OpencodeQuickChatKeymap
---@field cancel OpencodeKeymapEntry

---@class OpencodeCompletionFileSourcesConfig
---@field enabled boolean
---@field preferred_cli_tool 'server'|'fd'|'fdfind'|'rg'|'git'
---@field ignore_patterns string[]
---@field max_files number
---@field max_display_length number

---@class OpencodeCompletionConfig
---@field file_sources OpencodeCompletionFileSourcesConfig

---@class OpencodeLoadingAnimationConfig
---@field frames string[]

---@class OpencodeServerConfig
---@field url string | nil -- URL/hostname of custom opencode server (e.g., "http://192.168.1.100" or "localhost")
---@field port number | 'auto' | nil -- Port number, 'auto' for random, or nil for default (4096)
---@field timeout number -- Timeout in seconds for health check (default: 5)
---@field retry_delay number -- Delay in milliseconds between health check retries (default: 2000)
---@field spawn_command? fun(port: number, url: string): number | nil -- Optional function to start the server, may return server PID
---@field kill_command? fun(port: number, url: string): nil -- Optional function to stop the server when auto_kill is true
---@field auto_kill boolean -- Kill spawned servers when nvim exits (default: true)
---@field path_map (string | fun(host_path: string): string) | nil -- Map host paths to server paths
---@field reverse_path_map (fun(server_path: string): string) | nil -- Map server paths back to host paths

---@class OpencodeUIConfig
---@field enable_treesitter_markdown boolean
---@field position 'right'|'left'|'current' # Position of the UI (default: 'right')
---@field input_position 'bottom'|'top' # Position of the input window (default: 'bottom')
---@field window_width number
---@field persist_state boolean
---@field zoom_width number
---@field picker_width number|nil # Default width for all pickers (nil uses current window width)
---@field display_model boolean
---@field display_context_size boolean
---@field display_cost boolean
---@field window_highlight string
---@field icons { preset: 'text'|'nerdfonts', overrides: table<string,string> }
---@field loading_animation OpencodeLoadingAnimationConfig
---@field output OpencodeUIOutputConfig
---@field input OpencodeUIInputConfig
---@field completion OpencodeCompletionConfig
---@field highlights? OpencodeHighlightConfig
---@field picker OpencodeUIPickerConfig

---Window-local options applied to the input window.
---Any valid Neovim window-local option (`:h window-variable`) can be set here.
---Common examples:
---  signcolumn = 'no'
---  cursorline = true
---  number = true
---  relativenumber = true
---  foldcolumn = '0'
---  statuscolumn = ''
---  conceallevel = 2
---@class OpencodeUIInputWinOptions : table<string, any>
---@field signcolumn? string # Value for 'signcolumn' (e.g. 'yes', 'no', 'auto')
---@field cursorline? boolean
---@field number? boolean
---@field relativenumber? boolean

---@class OpencodeUIInputConfig
---@field text { wrap: boolean }
---@field min_height number
---@field max_height number
---@field auto_hide boolean
---@field win_options? OpencodeUIInputWinOptions # Window-local options applied to the input window. Any valid Neovim window option is accepted.

---@class OpencodeHighlightConfig
---@field vertical_borders? { tool?: { fg?: string, bg?: string }, user?: { fg?: string, bg?: string }, assistant?: { fg?: string, bg?: string } }

---@class OpencodeUIOutputRenderingConfig
---@field markdown_debounce_ms number
---@field on_data_rendered (fun(buf: integer, win: integer)|boolean)|nil
---@field markdown_on_idle boolean
---@field event_throttle_ms number
---@field event_collapsing boolean

---@class OpencodeUIOutputConfig
---@field tools { show_output: boolean, show_reasoning_output: boolean }
---@field rendering OpencodeUIOutputRenderingConfig
---@field always_scroll_to_bottom boolean
---@field filetype string
---@field compact_assistant_headers boolean | 'minimal' | 'hidden' | 'full'

---@class OpencodeUIPickerConfig
---@field snacks_layout? snacks.picker.layout.Config
--- TODO: add more picker-specific presets

---@class OpencodeContextConfig
---@field enabled boolean
---@field cursor_data { enabled: boolean, context_lines?: number }
---@field diagnostics { enabled:boolean, info: boolean, warning: boolean, error: boolean, only_closest: boolean}
---@field current_file { enabled: boolean }
---@field selection { enabled: boolean }
---@field agents { enabled: boolean }
---@field buffer { enabled: boolean }
---@field git_diff { enabled: boolean }

---@alias OpencodeToggleableContextKey
---| 'current_file'
---| 'selection'
---| 'diagnostics'
---| 'cursor_data'
---| 'buffer'
---| 'git_diff'

---@class OpencodeDebugConfig
---@field enabled boolean
---@field capture_streamed_events boolean
---@field show_ids boolean
---@field highlight_changed_lines boolean
---@field highlight_changed_lines_timeout_ms number
---@field quick_chat {keep_session: boolean, set_active_session: boolean}

---@alias OpencodeCommandLifecycleStage 'before'|'after'|'error'|'finally'
---@alias OpencodeCommandDispatchHook fun(ctx: OpencodeCommandDispatchContext): OpencodeCommandDispatchContext|nil
---@alias OpencodeCommandHookScope string|string[]|'*'

---@class OpencodeCommandHookRegisterOptions
---@field command? OpencodeCommandHookScope

---@class OpencodeHooks
---@field on_file_edited? fun(file: string): nil
---@field on_session_loaded? fun(session: Session): nil
---@field on_done_thinking? fun(session: Session): nil
---@field on_permission_requested? fun(session: Session): nil
---@field on_command_before? OpencodeCommandDispatchHook
---@field on_command_after? OpencodeCommandDispatchHook
---@field on_command_error? OpencodeCommandDispatchHook
---@field on_command_finally? OpencodeCommandDispatchHook

---@class OpencodeCommandDispatchContext
---@field parsed OpencodeCommandParseResult
---@field intent OpencodeParsedIntent|nil
---@field args string[]|nil
---@field range OpencodeSelectionRange|nil
---@field result? any
---@field error OpencodeCommandDispatchError|nil

---@class OpencodeCommandLifecycleHookSpec
---@field before? OpencodeCommandDispatchHook
---@field after? OpencodeCommandDispatchHook
---@field error? OpencodeCommandDispatchHook
---@field finally? OpencodeCommandDispatchHook
---@field on_command_before? OpencodeCommandDispatchHook
---@field on_command_after? OpencodeCommandDispatchHook
---@field on_command_error? OpencodeCommandDispatchHook
---@field on_command_finally? OpencodeCommandDispatchHook

---@class OpencodeProviders
---@field [string] string[]

---@class OpencodeConfigModule
---@field defaults OpencodeConfig
---@field values OpencodeConfig
---@field setup fun(opts?: OpencodeConfig): nil
---@field get_key_for_function fun(scope: 'editor'|'input_window'|'output_window', function_name: string): string|nil

---@class OpencodeQuickChatConfig
---@field default_model? string -- Use current model if nil
---@field default_agent? string -- Use current mode if nil
---@field instructions? string[] -- Custom instructions for quick chat

---@class OpencodeLoggingConfig
---@field enabled boolean
---@field level 'debug' | 'info' | 'warn' | 'error'
---@field outfile string|nil

---@class OpencodeSlashCommandSpec
---@field desc? string
---@field args? boolean
---@field cmd_str? string
---@field command_name? string
---@field preset_args? string[]
---@field fn? fun(args:string[]|nil):nil|Promise<any>|any

---@class OpencodeConfig
---@field preferred_picker 'telescope' | 'fzf' | 'mini.pick' | 'snacks' | 'select' | nil
---@field default_global_keymaps boolean
---@field default_mode 'build' | 'plan' | string -- Default mode
---@field default_system_prompt string | nil
---@field keymap_prefix string
---@field opencode_executable 'opencode' | string -- Command run for calling opencode
---@field server OpencodeServerConfig -- Custom/external server configuration
---@field keymap OpencodeKeymap
---@field ui OpencodeUIConfig
---@field context OpencodeContextConfig
---@field logging OpencodeLoggingConfig
---@field debug OpencodeDebugConfig
---@field prompt_guard? fun(mentioned_files: string[]): boolean
---@field hooks OpencodeHooks
---@field quick_chat OpencodeQuickChatConfig

---@class MessagePartState
---@field input TaskToolInput|BashToolInput|FileToolInput|TodoToolInput|GlobToolInput|GrepToolInput|WebFetchToolInput|ListToolInput|QuestionToolInput|ApplyPatchToolInput Input data for the tool
---@field metadata TaskToolMetadata|ToolMetadataBase|WebFetchToolMetadata|BashToolMetadata|FileToolMetadata|GlobToolMetadata|GrepToolMetadata|ListToolMetadata|QuestionToolMetadata Metadata about the tool execution
---@field time { start: number, end: number } Timestamps for tool use
---@field status string Status of the tool use (e.g., 'running', 'completed', 'failed')
---@field title string Title of the tool use
---@field output string Output of the tool use, if applicable
---@field error? string Error message if the part failed

---@class ApplyPatchToolInput
---@field patchText string The patch content in unified diff format

---@class ApplyPatchFileResult
---@field filePath string Absolute path to the file
---@field relativePath string Relative path to the file
---@field before string File contents before the patch
---@field after string File contents after the patch
---@field additions number Number of lines added
---@field deletions number Number of lines deleted
---@field type 'add'|'edit'|'delete' Type of file operation
---@field diff string Unified diff for this file

---@class ApplyPatchToolMetadata: ToolMetadataBase
---@field truncated boolean Whether the output was truncated
---@field diagnostics table<string, any> Diagnostic information keyed by file path
---@field files ApplyPatchFileResult[] Per-file results
---@field diff string Combined unified diff for all files

---@class ToolMetadataBase
---@field error boolean|nil Whether the tool execution resulted in an error
---@field message string|nil Optional status or error message

---@class TaskToolMetadata: ToolMetadataBase
---@field summary TaskToolSummaryItem[]
---@field sessionId string|nil Child session ID

---@class WebFetchToolMetadata: ToolMetadataBase
---@field http_status number|nil HTTP response status code
---@field content_type string|nil Content type of the response

---@class BashToolMetadata: ToolMetadataBase
---@field output string|nil

---@class FileToolMetadata: ToolMetadataBase
---@field diff string|nil The diff of changes made to the file
---@field file_type string|nil Detected file type/extension
---@field line_count number|nil Number of lines in the file

---@class GlobToolMetadata: ToolMetadataBase
---@field truncated boolean|nil
---@field count number|nil

---@class GrepToolMetadata: ToolMetadataBase
---@field truncated boolean|nil
---@field matches number|nil

---@class BashToolInput
---@field command string The command to execute
---@field description string Description of what the command does

---@class FileToolInput
---@field filePath string The path to the file
---@field content? string Content to write (for write tool)

---@class TodoToolInput
---@field todos { id: string, content: string, status: 'pending'|'in_progress'|'completed'|'cancelled', priority: 'high'|'medium'|'low' }[]

---@class ListToolInput
---@field path string The directory path to list

---@class ListToolMetadata: ToolMetadataBase
---@field truncated boolean|nil
---@field count number|nil

---@class GlobToolInput
---@field pattern string The glob pattern to match files against
---@field path? string Optional directory to search in

---@class ListToolOutput
---@field output string The raw output string from the list tool

---@class GrepToolInput
---@field pattern? string The glob pattern to match
---@field path? string Optional directory to search in
---@field include? string Optional file type to include (e.g., '*.lua')

---@class WebFetchToolInput
---@field url string The URL to fetch content from
---@field format 'text'|'markdown'|'html'
---@field timeout? number Optional timeout in seconds (max 120)

---@class TaskToolInput
---@field prompt string The subtask prompt
---@field description string Description of the subtask
---@field subagent_type string The type of specialized agent to use

---@class TaskToolSummaryItem
---@field id string Tool call ID
---@field tool string Tool name
---@field state { status: string, title?: string }

-- Question types

---@class OpencodeQuestionOption
---@field label string Display text
---@field description string Explanation of choice

---@class OpencodeQuestionInfo
---@field question string Complete question
---@field header string Very short label (max 12 chars)
---@field options OpencodeQuestionOption[] Available choices
---@field multiple? boolean Allow selecting multiple choices

---@class OpencodeQuestionRequest
---@field id string Question request ID
---@field sessionID string Session ID
---@field questions OpencodeQuestionInfo[] Questions to ask
---@field tool? { messageID: string, callID: string }

---@class QuestionToolInput
---@field questions OpencodeQuestionInfo[] Questions that were asked

---@class QuestionToolMetadata: ToolMetadataBase
---@field answers string[][] Array of answer arrays (one per question)
---@field truncated boolean Whether the results were truncated

---@class MessageTokenCount
---@field reasoning number
---@field input number
---@field output number
---@field cache { write: number, read: number }

---@class OutputMetadata
---@field msg_idx number|nil Message index in session
---@field part_idx number|nil Part index in message
---@field role 'user'|'assistant'|'system'|nil Message role
---@field type 'text'|'tool'|'header'|'patch'|'step-start'|nil Message part type
---@field snapshot? string|nil snapshot commit hash

---@class OutputAction
---@field text string Action text
---@field type 'diff_revert_all'|'diff_revert_selected_file'|'diff_open'|'diff_restore_snapshot_file'|'diff_restore_snapshot_all'|'select_child_session' Type of action
---@field args? string[] Optional arguments for the command
---@field key string keybinding for the action
---@field display_line number Line number to display the action
---@field range? { from: number, to: number } Optional range for the action

---@alias OutputExtmarkType vim.api.keyset.set_extmark & {start_col:0}
---@alias OutputExtmark OutputExtmarkType|fun():OutputExtmarkType

---@class OpencodeMessage
---@field info MessageInfo Metadata about the message
---@field parts OpencodeMessagePart[] Parts that make up the message
---@field references CodeReference[]|nil Parsed file references from text parts (cached)
---@field system string|nil System message content

---@class MessageInfo
---@field id string Unique message identifier
---@field sessionID string Unique session identifier
---@field tokens MessageTokenCount Token usage statistics
---@field system string[] System messages
---@field time { created: number, completed: number } Timestamps
---@field cost number Cost of the message
---@field path { cwd: string, root: string } Working directory paths
---@field modelID string Model identifier
---@field providerID string Provider identifier
---@field role 'user'|'assistant'|'system' Role of the message sender
---@field system_role string|nil Role defined in system messages
---@field mode string|nil Agent or mode identifier
---@field error table

---@class RestorePoint
---@field id string Unique restore point identifier
---@field from_snapshot_id string|nil ID of the snapshot this restore point is based on
---@field files string[] List of file paths included in the restore point
---@field deleted_files string[] List of files that were deleted in this restore point
---@field created_at number Timestamp when the restore point was created

---@class OpencodeSnapshotPatch
---@field hash string Unique identifier for the snapshot
---@field files string[] List of file paths included in the snapshot

---@class OpenOpts
---@field focus? 'input' | 'output'
---@field start_insert? boolean
---@field new_session? boolean
---@field open_action? 'reuse_visible'|'restore_hidden'|'create_fresh'

---@class SendMessageOpts
---@field new_session? boolean
---@field context? OpencodeContextConfig
---@field model? string
---@field agent? string
---@field variant? string
---@field system? string

---@class CompletionContext
---@field trigger_char string The character that triggered completion
---@field input string The current input text
---@field cursor_pos number Current cursor position
---@field line string The full current line text

---@class CompletionItem
---@field label string Display text for the completion item
---@field kind string Type of completion item (e.g., 'file', 'subagent')
---@field kind_icon string Icon representing the kind
---@field kind_hl? string Highlight group for the kind
---@field detail string Additional detail text
---@field documentation string Documentation text
---@field insert_text string Text to insert when selected
---@field source_name string Name of the completion source
---@field priority? number Optional priority for individual item sorting (lower numbers have higher priority)
---@field data table Additional data associated with the item

---@class CompletionSource
---@field name string Name of the completion source
---@field priority number Priority for ordering sources
---@field complete fun(context: CompletionContext): Promise<CompletionItem[]> Function to generate completion items
---@field on_complete fun(item: CompletionItem): nil Optional callback when item is selected
---@field is_incomplete? boolean Whether the completion results are incomplete (for sources that support pagination)
---@field get_trigger_character? fun(): string|nil Optional function returning the trigger character for this source
---@field custom_kind? integer Custom LSP CompletionItemKind registered for this source

---Extended LSP completion item with opencode-specific rendering fields
---@class OpencodeLspItem : lsp.CompletionItem
---@field kind lsp.CompletionItemKind
---@field kind_hl? string Highlight group for the kind icon
---@field kind_icon string Icon string for the kind

---@class OpencodeContext
---@field current_file OpencodeContextFile|nil
---@field cursor_data OpencodeContextCursorData|nil
---@field mentioned_files string[]|nil
---@field mentioned_subagents string[]|nil
---@field selections OpencodeContextSelection[]|nil
---@field linter_errors OpencodeDiagnostic[]|nil

---@class OpencodeContextSelection
---@field file OpencodeContextFile
---@field content string|nil
---@field lines string|nil

---@class OpencodeContextCursorData
---@field line number
---@field column number
---@field line_content string
---@field lines_before string[]
---@field lines_after string[]

---@class OpencodeContextFile
---@field path string
---@field name string
---@field extension string
---@field sent_at? number

---@class OpencodeMessagePartSourceText
---@field start number
---@field value string
---@field ['end'] number

---@class OpencodeMessagePartSource
---@field path string|nil
---@field type string|nil
---@field text OpencodeMessagePartSourceText|nil
---@field value string|nil

---@class OpencodeMessagePart
---@field type 'text'|'file'|'agent'|'tool'|'step-start'|'patch'|'reasoning'|string
---@field id string|nil Unique identifier for tool use parts
---@field text string|nil
---@field tool string|nil Name of the tool being used
---@field state MessagePartState|nil State information for tool use parts
---@field filename string|nil
---@field mime string|nil
---@field url string|nil
---@field source OpencodeMessagePartSource|nil
---@field name string|nil
---@field synthetic boolean|nil
---@field snapshot string|nil Snapshot commit hash
---@field sessionID string|nil Session identifier
---@field messageID string|nil Message identifier
---@field callID string|nil Call identifier (used for tools)
---@field hash string|nil Hash identifier for patch parts
---@field files string[]|nil List of file paths for patch parts
---@field time { start: number, end?: number }|nil Timestamps for the part

---@class OpencodeModelModalities
---@field input ('text'|'image'|'audio'|'video')[] Supported input modalities
---@field output ('text')[] Supported output modalities

---@class OpencodeModelCost
---@field input number Cost per input token
---@field output number Cost per output token
---@field cache_read number|nil Cost per cache read token
---@field cache_write number|nil Cost per cache write token

---@class OpencodeModelLimits
---@field context number Maximum context length in tokens
---@field output number Maximum output length in tokens

---@class OpencodeModelVariant
---@field reasoningEffort string Reasoning effort level (e.g., "low", "medium", "high")

---@class OpencodeModel
---@field id string Unique identifier for the model
---@field name string Human-readable name of the model
---@field attachment boolean Whether the model supports file attachments
---@field reasoning boolean Whether the model supports reasoning/thinking
---@field temperature boolean Whether the model supports temperature parameter
---@field tool_call boolean Whether the model supports tool calling
---@field knowledge string|nil Knowledge cutoff date (e.g., "2024-04")
---@field release_date string Release date in YYYY-MM-DD format
---@field last_updated string Last updated date in YYYY-MM-DD format
---@field modalities OpencodeModelModalities Supported input/output modalities
---@field open_weights boolean Whether the model has open weights
---@field limit OpencodeModelLimits Token limits for the model
---@field cost OpencodeModelCost Pricing information for the model
---@field variants table<string, OpencodeModelVariant>|nil Model variants with different configurations

---@class OpencodeProvider
---@field id string Unique identifier for the provider
---@field env string[] Required environment variables for authentication
---@field npm string NPM package name for the provider SDK
---@field api string|nil Base API URL for the provider
---@field name string Human-readable name of the provider
---@field doc string|nil Documentation URL for the provider
---@field models table<string, OpencodeModel> Map of model ID to model configuration

---@class OpencodeProvidersResponse
---@field providers OpencodeProvider[] List of available providers
---@field default table<string, string> Map of provider ID to default model ID

---@class OpencodeToolListItem
---@field id string Tool identifier
---@field description string Tool description
---@field parameters any JSON schema parameters for the tool

---@alias OpencodeToolList OpencodeToolListItem[]

---@class OpencodeAgentPermissionBash
---@field [string] string Permission level ('allow', 'deny', etc.)

---@class OpencodeAgentPermission
---@field edit string Permission level for edit operations
---@field webfetch string Permission level for web fetch operations
---@field bash OpencodeAgentPermissionBash Bash command permissions

---@class OpencodeAgentModel
---@field providerID string Provider identifier
---@field modelID string Model identifier

---@class OpencodeAgent
---@field name string Unique identifier for the agent
---@field description string Human-readable description of the agent
---@field tools table<string, boolean> Map of tool names to availability
---@field options table Additional configuration options
---@field permission OpencodeAgentPermission Permissions for various operations
---@field mode 'primary'|'subagent'|'all' Agent execution mode
---@field builtIn boolean Whether this is a built-in agent
---@field model OpencodeAgentModel|nil Optional model configuration
---@field prompt string|nil Optional custom prompt for the agent
---@field temperature number|nil Optional temperature setting

---@class OpencodeSlashCommand
---@field slash_cmd string The command trigger (e.g., "/help")
---@field desc string|nil Description of the command
---@field fn fun(args:string[]|nil):nil|Promise<any>|any Function to execute the command
---@field args boolean Whether the command accepts arguments

---@class OpencodeRevertSummary
---@field messages number Number of messages reverted
---@field tool_calls number Number of tool calls reverted
---@field files table<string, {additions: number, deletions: number}> Summary of file changes reverted

---@class OpencodeSelectionRange
---@field start number Starting line number (inclusive)
---@field stop number Ending line number (inclusive)
