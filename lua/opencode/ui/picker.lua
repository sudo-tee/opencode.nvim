local M = {}

function M.get_best_picker()
  local config = require('opencode.config')

  local preferred_picker = config.preferred_picker
  if preferred_picker and type(preferred_picker) == 'string' and preferred_picker ~= '' then
    if preferred_picker == 'select' then
      return nil
    end

    return preferred_picker
  end

  if pcall(require, 'telescope') then
    return 'telescope'
  end
  if pcall(require, 'fzf-lua') then
    return 'fzf'
  end
  if pcall(require, 'mini.pick') then
    return 'mini.pick'
  end
  if pcall(require, 'snacks') then
    return 'snacks'
  end
  return nil
end

return M
