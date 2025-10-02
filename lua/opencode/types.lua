
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

---@class OpencodeUserCommandFrontMatter
---@field description string
---@field agent string
---@field model string

---@class SessionRevertInfo
---@field messageID string
---@field partID? string
---@field snapshot string
---@field diff string

---@class Session
---@field workspace string
---@field description string
---@field modified number
---@field name string
---@field parentID string|nil
---@field path string
---@field messages_path string
---@field parts_path string
---@field snapshot_path string
---@field cache_path string
---@field workplace_slug string
---@field revert? SessionRevertInfo

---@class OpencodeKeymapGlobal
---@field toggle string
---@field open_input string
---@field open_input_new_session string
---@field open_output string
---@field toggle_focus string
---@field close string
---@field select_session string
---@field configure_provider string
---@field diff_open string
---@field diff_next string
---@field diff_prev string
---@field diff_close string
---@field diff_revert_all_last_prompt string
---@field diff_revert_this_last_prompt string
---@field diff_revert_all string
---@field diff_revert_this string
---@field diff_restore_snapshot_file string
---@field diff_restore_snapshot_all string
---@field open_configuration_file string
---@field swap_position string # Swap Opencode pane left/right

---@class OpencodeKeymapWindow
---@field submit string
---@field submit_insert string
---@field close string
---@field stop string
---@field next_message string
---@field prev_message string
---@field mention_file string # mention files with a file picker
---@field mention string # mention subagents or files with a completion popup
---@field slash_commands string
---@field toggle_pane string
---@field prev_prompt_history string
---@field next_prompt_history string
---@field switch_mode string
---@field focus_input string
---@field select_child_session string\n---@field debug_message string\n---@field debug_output string\n---@field debug_session string
---@class OpencodeKeymap
---@field global OpencodeKeymapGlobal
---@field window OpencodeKeymapWindow

---@class OpencodeCompletionFileSourcesConfig
---@field enabled boolean
---@field preferred_cli_tool 'fd'|'fdfind'|'rg'|'git'
---@field ignore_patterns string[]
---@field max_files number
---@field max_display_length number
---@field cache_timeout number

---@class OpencodeCompletionConfig
---@field file_sources OpencodeCompletionFileSourcesConfig

---@class OpencodeUIConfig
---@field position 'right'|'left' # Position of the UI (default: 'right')
---@field input_position 'bottom'|'top' # Position of the input window (default: 'bottom')
---@field window_width number
---@field input_height number
---@field display_model boolean
---@field display_context_size boolean
---@field display_cost boolean
---@field window_highlight string
---@field icons { preset: 'emoji'|'text'|'nerdfonts', overrides: table<string,string> }
---@field output { tools: { show_output: boolean } }
---@field input { text: { wrap: boolean } }
---@field completion OpencodeCompletionConfig

---@class OpencodeContextConfig
---@field enabled boolean
---@field plugin_versions { enabled: boolean, limit: number }
---@field cursor_data { enabled: boolean }
---@field diagnostics { info: boolean, warning: boolean, error: boolean }
---@field current_file { enabled: boolean, show_full_path: boolean }
---@field selection { enabled: boolean }
---@field marks { enabled: boolean, limit: number }
---@field jumplist { enabled: boolean, limit: number }
---@field recent_buffers { enabled: boolean, limit: number, symbols_only: boolean }
---@field undo_history { enabled: boolean, limit: number }
---@field windows_tabs { enabled: boolean }
---@field highlights { enabled: boolean }
---@field session_info { enabled: boolean }
---@field registers { enabled: boolean, include: string[] }
---@field command_history { enabled: boolean, limit: number }
---@field search_history { enabled: boolean, limit: number }
---@field debug_data { enabled: boolean }
---@field lsp_context { enabled: boolean, diagnostics_limit: number, code_actions: boolean }
---@field git_info { enabled: boolean, diff_limit: number, changes_limit: number }
---@field fold_info { enabled: boolean }
---@field cursor_surrounding { enabled: boolean, lines_above: number, lines_below: number }
---@field quickfix_loclist { enabled: boolean, limit: number }
---@field macros { enabled: boolean, register: string }
---@field terminal_buffers { enabled: boolean }
---@field session_duration { enabled: boolean }

---@class OpencodeDebugConfig
---@field enabled boolean

--- @class OpencodeProviders
--- @field [string] string[]

---@class OpencodeConfigModule
---@field defaults OpencodeConfig
---@field values OpencodeConfig
---@field setup fun(opts?: OpencodeConfig): nil
---@overload fun(key: nil): OpencodeConfig
---@overload fun(key: "preferred_picker"): 'mini.pick' | 'telescope' | 'fzf' | 'snacks' | nil
---@overload fun(key: "preferred_completion"): 'blink' | 'nvim-cmp' | 'vim_complete' | nil
---@overload fun(key: "default_mode"): 'build' | 'plan'
---@overload fun(key: "default_global_keymaps"): boolean
---@overload fun(key: "keymap"): OpencodeKeymap
---@overload fun(key: "ui"): OpencodeUIConfig
---@overload fun(key: "providers"): OpencodeProviders
---@overload fun(key: "context"): OpencodeContextConfig
---@overload fun(key: "debug"): OpencodeDebugConfig

---@class OpencodeConfig
---@field preferred_picker 'telescope' | 'fzf' | 'mini.pick' | 'snacks' | nil
---@field preferred_completion 'blink' | 'nvim-cmp' | 'vim_complete' | nil -- Preferred completion strategy for mentons and commands
---@field default_global_keymaps boolean
---@field default_mode 'build' | 'plan' | string -- Default mode
---@field keymap OpencodeKeymap
---@field ui OpencodeUIConfig
---@field providers OpencodeProviders
---@field context OpencodeContextConfig
---@field custom_commands table<string, { desc: string, fn: function }>
---@field debug OpencodeDebugConfig

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
---@field summary MessagePart[]

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

---@class MessagePart
---@field type 'text'|'tool'|'step-start'|'patch' Type of the message part
---@field text string|nil Text content for text parts
---@field id string|nil Unique identifier for tool use parts
---@field tool string|nil Name of the tool being used
---@field state MessagePartState|nil State information for tool use parts
---@field snapshot string|nil Snapshot commit hash
---@field sessionID string|nil Session identifier
---@field messageID string|nil Message identifier
---@field hash string|nil Hash identifier for patch parts
---@field files string[]|nil List of file paths for patch parts
---@field synthetic boolean|nil Whether the message was generated synthetically

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

---@alias OutputExtmark vim.api.keyset.set_extmark|fun():vim.api.keyset.set_extmark

---@class Message
---@field id string Unique message identifier
---@field sessionID string Unique session identifier
---@field tokens MessageTokenCount Token usage statistics
---@field parts MessagePart[] Array of message parts
---@field system string[] System messages
---@field time { created: number, completed: number } Timestamps
---@field cost number Cost of the message
---@field path { cwd: string, root: string } Working directory paths
---@field modelID string Model identifier
---@field providerID string Provider identifier
---@field role 'user'|'assistant'|'system' Role of the message sender
---@field system_role string|nil Role defined in system messages
---@field mode string|nil Agent/mode used to create this message (from CLI)
---@field assistant_mode string|nil Assistant mode active when message was created (deprecated)
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
---@field detail string Additional detail text
---@field documentation string Documentation text
---@field insert_text string Text to insert when selected
---@field source_name string Name of the completion source
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
---@field linter_errors string|nil

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
---@field type 'text'|'file'|'agent'|string
---@field text string|nil
---@field filename string|nil
---@field mime string|nil
---@field url string|nil
---@field source OpencodeMessagePartSource|nil
---@field name string|nil
---@field synthetic boolean|nil
