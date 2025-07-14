
--- @class OpencodeKeymapGlobal
--- @field toggle string
--- @field open_input string
--- @field open_input_new_session string
--- @field open_output string
--- @field toggle_focus string
--- @field close string
--- @field toggle_fullscreen string
--- @field select_session string
--- @field configure_provider string
--- @field diff_open string
--- @field diff_next string
--- @field diff_prev string
--- @field diff_close string
--- @field diff_revert_all string
--- @field diff_revert_this string

--- @class OpencodeKeymapWindow
--- @field submit string
--- @field submit_insert string
--- @field close string
--- @field stop string
--- @field next_message string
--- @field prev_message string
--- @field mention_file string
--- @field toggle_pane string
--- @field prev_prompt_history string
--- @field next_prompt_history string
--- @field focus_input string
--- @field debug_message string
--- @field debug_output string
--- @field switch_mode string
--- @class OpencodeKeymap
--- @field global OpencodeKeymapGlobal
--- @field window OpencodeKeymapWindow

--- @class OpencodeUIConfig
--- @field floating boolean
--- @field window_width number
--- @field input_height number
--- @field fullscreen boolean
--- @field layout string
--- @field floating_height number
--- @field display_model boolean
--- @field window_highlight string

--- @class OpencodeContextConfig
--- @field cursor_data boolean

--- @class OpencodeDebugConfig
--- @field enabled boolean

--- @class OpencodeProviders
--- @field [string] string[]

--- @class OpencodeConfig
--- @field prefered_picker 'telescope' | 'fzf' | 'mini.pick' | 'snacks' | nil
--- @field default_global_keymaps boolean
--- @field default_mode 'build' | 'plan' | string -- Default mode
--- @field keymap OpencodeKeymap
--- @field ui OpencodeUIConfig
--- @field providers OpencodeProviders
--- @field context OpencodeContextConfig
--- @field custom_commands table<string, { desc: string, fn: function }>
--- @field debug OpencodeDebugConfig

--- @class MessagePartState
--- @field input BashToolInput|FileToolInput|TodoToolInput|GlobToolInput|WebFetchToolInput Input data for the tool
--- @field metadata ToolMetadataBase Metadata for the tool use
--- @field time { start: number, end: number } Timestamps for tool use
--- @field status string Status of the tool use (e.g., 'running', 'completed', 'failed')
--- @field title string Title of the tool use
--- @field output string Output of the tool use, if applicable
--- @field error? string Error message if the part failed

--- @class ToolMetadataBase
--- @field error boolean|nil Whether the tool execution resulted in an error
--- @field message string|nil Optional status or error message

--- @class WebFetchToolMetadata: ToolMetadataBase
--- @field http_status number|nil HTTP response status code
--- @field content_type string|nil Content type of the response

--- @class BashToolMetadata: ToolMetadataBase
--- @field stdout string|nil

--- @class FileToolMetadata: ToolMetadataBase
--- @field diff string|nil The diff of changes made to the file
--- @field file_type string|nil Detected file type/extension
--- @field line_count number|nil Number of lines in the file

--- @class GlobToolMetadata: ToolMetadataBase
--- @field truncated boolean|nil
--- @field count number|nil

--- @class BashToolInput
--- @field command string The command to execute
--- @field description string Description of what the command does

--- @class FileToolInput
--- @field filePath string The path to the file
--- @field content? string Content to write (for write tool)

--- @class TodoToolInput
--- @field todos { id: string, content: string, status: 'pending'|'in_progress'|'completed'|'cancelled', priority: 'high'|'medium'|'low' }[]

--- @class GlobToolInput
--- @field pattern string The glob pattern to match
--- @field path? string Optional directory to search in

--- @class WebFetchToolInput
--- @field url string The URL to fetch content from
--- @field format 'text'|'markdown'|'html'
--- @field timeout? number Optional timeout in seconds (max 120)

--- @class MessagePart
--- @field type 'text'|'tool'|'step-start' Type of the message part
--- @field text string|nil Text content for text parts
--- @field id string|nil Unique identifier for tool use parts
--- @field tool string|nil Name of the tool being used
--- @field state MessagePartState|nil State information for tool use parts

--- @class MessageTokenCount
--- @field reasoning number
--- @field input number
--- @field output number
--- @field cache { write: number, read: number }

---@class OutputMetadata
---@field msg_idx number|nil Message index in session
---@field part_idx number|nil Part index in message
---@field role 'user'|'assistant'|'system'|nil Message role
---@field type 'text'|'tool'|'header'|nil Message part type

---@alias OutputExtmark vim.api.keyset.set_extmark

--- @class Message
--- @field id string Unique message identifier
--- @field sessionID string Unique session identifier
--- @field tokens MessageTokenCount Token usage statistics
--- @field parts MessagePart[] Array of message parts
--- @field system string[] System messages
--- @field time { created: number, completed: number } Timestamps
--- @field cost number Cost of the message
--- @field path { cwd: string, root: string } Working directory paths
--- @field modelID string Model identifier
--- @field providerID string Provider identifier
--- @field role 'user'|'assistant'|'system' Role of the message sender
--- @field system_role string|nil Role defined in system messages
--- @field error table
