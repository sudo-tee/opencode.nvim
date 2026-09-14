---@generic T
---@class LruCache<T>
---@field private capacity integer
---@field private entries table<any, { value: T, used: integer }>
---@field private size integer
---@field private clock integer
local LruCache = {}
LruCache.__index = LruCache

---@param capacity integer
---@return LruCache<T>
function LruCache.new(capacity)
  assert(capacity > 0, 'cache capacity must be positive')
  return setmetatable({
    capacity = capacity,
    entries = {},
    size = 0,
    clock = 0,
  }, LruCache)
end

---@param key any
---@return T
function LruCache:get(key)
  local entry = self.entries[key]
  if not entry then
    return nil
  end

  self.clock = self.clock + 1
  entry.used = self.clock
  return entry.value
end

---@param key any
---@param value T
function LruCache:set(key, value)
  local entry = self.entries[key]
  if not entry and self.size >= self.capacity then
    local oldest_key
    local oldest_use = math.huge
    for cached_key, cached_entry in pairs(self.entries) do
      if cached_entry.used < oldest_use then
        oldest_key = cached_key
        oldest_use = cached_entry.used
      end
    end
    self.entries[oldest_key] = nil
    self.size = self.size - 1
  end

  if not entry then
    self.size = self.size + 1
  end
  self.clock = self.clock + 1
  self.entries[key] = { value = value, used = self.clock }
end

return LruCache
