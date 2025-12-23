local arr = {
  'bltqsvhw',
  'dmroktuy',
  'ifwxcpza',
  'imcrwsyj',
  'kxgzlfnv',
  'phaekyru',
  'qzuhbpni',
  'twlmeyvs',
  'uqhdoxzp',
  'vjnslgtm',
}

function class(base)
  local c = {}
  c.__index = c
  setmetatable(c, { __index = base })

  function c:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
  end

  return c
end

---@param n integer
---@return integer
function fibonacci(n)
  if n <= 1 then
    return n
  end
  return fibonacci(n - 1) + fibonacci(n - 2)
end
