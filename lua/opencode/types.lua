
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
---@field modified number
---@field id string
---@field parentID string|nil
---@field path string
---@field messages_path string
---@field parts_path string
---@field snapshot_path string
---@field cache_path string
---@field revert? SessionRevertInfo
---@field share? SessionShareInfo

---@class OpencodeKeymapEntry
---@field [1] string # Function name
---@field mode? string|string[] # Mode(s) for the keymap
---@field desc? string # Keymap description

---@class OpencodeKeymapEditor : table<string, OpencodeKeymapEntry>
---@class OpencodeKeymapInputWindow : table<string, OpencodeKeymapEntry>
---@class OpencodeKeymapOutputWindow : table<string, OpencodeKeymapEntry>

---@class OpencodeKeymapPermission
---@field accept string
---@field accept_all string
---@field deny string

---@class OpencodeKeymap
---@field editor OpencodeKeymapEditor
---@field input_window OpencodeKeymapInputWindow
---@field output_window OpencodeKeymapOutputWindow
---@field permission OpencodeKeymapPermission
---@field session_picker OpencodeSessionPickerKeymap
---@field timeline_picker OpencodeTimelinePickerKeymap

---@class OpencodeSessionPickerKeymap
---@field delete_session OpencodeKeymapEntry
---@field new_session OpencodeKeymapEntry
---@field rename_session OpencodeKeymapEntry

---@class OpencodeTimelinePickerKeymap
---@field undo OpencodeKeymapEntry
---@field fork OpencodeKeymapEntry

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

---@class OpencodeUIConfig
---@field position 'right'|'left' # Position of the UI (default: 'right')
---@field input_position 'bottom'|'top' # Position of the input window (default: 'bottom')
---@field window_width number
---@field input_height number
---@field picker_width number|nil # Default width for all pickers (nil uses current window width)
---@field display_model boolean
---@field display_context_size boolean
---@field display_cost boolean
---@field window_highlight string
---@field icons { preset: 'text'|'nerdfonts', overrides: table<string,string> }
---@field loading_animation OpencodeLoadingAnimationConfig
---@field output OpencodeUIOutputConfig
---@field input { text: { wrap: boolean } }
---@field completion OpencodeCompletionConfig

---@class OpencodeUIOutputRenderingConfig
---@field markdown_debounce_ms number
---@field on_data_rendered (fun(buf: integer, win: integer)|boolean)|nil
---@field event_throttle_ms number
---@field event_collapsing boolean

---@class OpencodeUIOutputConfig
---@field tools { show_output: boolean }
---@field rendering OpencodeUIOutputRenderingConfig
---@field always_scroll_to_bottom boolean

---@class OpencodeContextConfig
---@field enabled boolean
---@field cursor_data { enabled: boolean }
---@field diagnostics { enabled:boolean, info: boolean, warning: boolean, error: boolean }
---@field current_file { enabled: boolean }
---@field selection { enabled: boolean }
---@field agents { enabled: boolean }

---@class OpencodeDebugConfig
---@field enabled boolean
---@field capture_streamed_events boolean
---@field show_ids boolean

---@class OpencodeHooks
---@field on_file_edited? fun(file: string): nil
---@field on_session_loaded? fun(session: Session): nil

---@class OpencodeProviders
---@field [string] string[]

---@class OpencodeConfigModule
---@field defaults OpencodeConfig
---@field values OpencodeConfig
---@field setup fun(opts?: OpencodeConfig): nil
---@field get_key_for_function fun(scope: 'editor'|'input_window'|'output_window', function_name: string): string|nil

---@class OpencodeConfig
---@field preferred_picker 'telescope' | 'fzf' | 'mini.pick' | 'snacks' | nil
---@field preferred_completion 'blink' | 'nvim-cmp' | 'vim_complete' | nil -- Preferred completion strategy for mentons and commands
---@field default_global_keymaps boolean
---@field default_mode 'build' | 'plan' | string -- Default mode
---@field keymap_prefix string
---@field keymap OpencodeKeymap
---@field ui OpencodeUIConfig
---@field context OpencodeContextConfig
---@field debug OpencodeDebugConfig
---@field prompt_guard? fun(mentioned_files: string[]): boolean
---@field hooks OpencodeHooks
---@field legacy_commands boolean

---@class MessagePartState
---@field input TaskToolInput|BashToolInput|FileToolInput|TodoToolInput|GlobToolInput|GrepToolInput|WebFetchToolInput|ListToolInput Input data for the tool
---@field metadata TaskToolMetadata|ToolMetadataBase|WebFetchToolMetadata|BashToolMetadata|FileToolMetadata|GlobToolMetadata|GrepToolMetadata|ListToolMetadata Metadata about the tool execution
---@field time { start: number, end: number } Timestamps for tool use
---@field status string Status of the tool use (e.g., 'running', 'completed', 'failed')
---@field title string Title of the tool use
---@field output string Output of the tool use, if applicable
---@field error? string Error message if the part failed

---@class ToolMetadataBase
---@field error boolean|nil Whether the tool execution resulted in an error
---@field message string|nil Optional status or error message

---@class TaskToolMetadata: ToolMetadataBase
---@field summary OpencodeMessagePart[]

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

---@class SendMessageOpts
---@field new_session? boolean
---@field context? OpencodeContextConfig
---@field model? string
---@field agent? string

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
---@field complete fun(context: CompletionContext): CompletionItem[] Function to generate completion items
---@field on_complete fun(item: CompletionItem): nil Optional callback when item is selected

---@class OpencodeContext
---@field current_file OpencodeContextFile|nil
---@field cursor_data OpencodeContextCursorData|nil
---@field mentioned_files string[]|nil
---@field mentioned_subagents string[]|nil
---@field selections OpencodeContextSelection[]|nil
---@field linter_errors vim.Diagnostic[]|nil

---@class OpencodeContextSelection
---@field file OpencodeContextFile
---@field content string|nil
---@field lines string|nil

---@class OpencodeContextCursorData
---@field line number
---@field column number
---@field line_content string

---@class OpencodeContextFile
---@field path string
---@field name string
---@field extension string

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
---@field type 'text'|'file'|'agent'|'tool'|'step-start'|'patch'|string
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
---@field fn fun(args:string[]):nil Function to execute the command
---@field args boolean Whether the command accepts arguments

---@class OpencodeRevertSummary
---@field messages number Number of messages reverted
---@field tool_calls number Number of tool calls reverted
---@field files table<string, {additions: number, deletions: number}> Summary of file changes reverted
