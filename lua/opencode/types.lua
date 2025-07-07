
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
--- @field keymap OpencodeKeymap
--- @field ui OpencodeUIConfig
--- @field providers OpencodeProviders
--- @field context OpencodeContextConfig
--- @field custom_commands table<string, { desc: string, fn: function }>
--- @field debug OpencodeDebugConfig

--- @class MessageToolInvocation
--- @field toolName string Name of the tool being invoked
--- @field toolCallId string Unique identifier for the tool call
--- @field args table Arguments passed to the tool
--- @field state string State of the tool invocation (e.g. 'result')
--- @field result string|nil Result of the tool invocation

--- @class MessagePart
--- @field type 'text'|'tool-invocation'|'step-start' Type of the message part
--- @field text string|nil Text content for text parts
--- @field toolInvocation MessageToolInvocation|nil Tool invocation data

--- @class MessageMetadata
--- @field snapshot string Git snapshot ID
--- @field time { created: number, completed: number } Timestamps
--- @field sessionID string Session identifier
--- @field tool table<string, table> Tool-specific metadata

--- @class Message
--- @field id string Unique message identifier
--- @field role 'user'|'assistant'|'system' Role of the message sender
--- @field parts MessagePart[] Array of message parts
--- @field metadata MessageMetadata Message metadata
