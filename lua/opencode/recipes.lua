local M = {}

---@class OpencodeRecipe
---@field opts? OpencodeConfig Merged before the user's options, which win
---@field setup? fun(opencode: table) Runs once the plugin is set up

---Resolve `opts.recipes` and merge each recipe's options under the user's.
---@param opts? OpencodeConfig
---@return OpencodeConfig? merged
---@return OpencodeRecipe[] recipes
function M.resolve(opts)
  local recipes = {} ---@type OpencodeRecipe[]
  if not opts or not opts.recipes then
    return opts, recipes
  end
  local merged = {} ---@type table
  for _, recipe in ipairs(opts.recipes) do
    if type(recipe) == 'string' then
      recipe = require(recipe) --[[@as OpencodeRecipe]]
    end
    recipes[#recipes + 1] = recipe
    if recipe.opts then
      merged = vim.tbl_deep_extend('force', merged, recipe.opts) --[[@as table]]
    end
  end
  return vim.tbl_deep_extend('force', merged, opts), recipes
end

---@param recipes OpencodeRecipe[]
---@param opencode table
function M.run(recipes, opencode)
  for _, recipe in ipairs(recipes) do
    if recipe.setup then
      recipe.setup(opencode)
    end
  end
end

return M
