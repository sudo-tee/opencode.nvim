local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local bnot = bit.bnot
local rol = bit.rol

local function u32hex(n)
  if n < 0 then
    n = n + 4294967296
  end
  return string.format('%08x', n)
end

---@param str string
---@return string|nil
local function sha1(str)
  local bytes = { string.byte(str, 1, #str) }
  local bit_len = #bytes * 8

  bytes[#bytes + 1] = 0x80
  while (#bytes % 64) ~= 56 do
    bytes[#bytes + 1] = 0
  end

  local bit_len_hi = math.floor(bit_len / 4294967296)
  local bit_len_lo = bit_len % 4294967296

  bytes[#bytes + 1] = math.floor(bit_len_hi / 16777216) % 256
  bytes[#bytes + 1] = math.floor(bit_len_hi / 65536) % 256
  bytes[#bytes + 1] = math.floor(bit_len_hi / 256) % 256
  bytes[#bytes + 1] = band(bit_len_hi, 0x000000ff)
  bytes[#bytes + 1] = math.floor(bit_len_lo / 16777216) % 256
  bytes[#bytes + 1] = math.floor(bit_len_lo / 65536) % 256
  bytes[#bytes + 1] = math.floor(bit_len_lo / 256) % 256
  bytes[#bytes + 1] = band(bit_len_lo, 0x000000ff)

  local h0 = 0x67452301
  local h1 = 0xefcdab89
  local h2 = 0x98badcfe
  local h3 = 0x10325476
  local h4 = 0xc3d2e1f0

  for i = 1, #bytes, 64 do
    local w = {}
    for j = 1, 16 do
      local k = i + (j - 1) * 4
      w[j] = band(bytes[k] * 16777216 + bytes[k + 1] * 65536 + bytes[k + 2] * 256 + bytes[k + 3], 0xffffffff)
    end
    for j = 17, 80 do
      w[j] = rol(bxor(bxor(w[j - 3], w[j - 8]), bxor(w[j - 14], w[j - 16])), 1)
    end

    local a = h0
    local b = h1
    local c = h2
    local d = h3
    local e = h4

    for j = 1, 80 do
      local f, k
      if j <= 20 then
        f = bor(band(b, c), band(bnot(b), d))
        k = 0x5a827999
      elseif j <= 40 then
        f = bxor(bxor(b, c), d)
        k = 0x6ed9eba1
      elseif j <= 60 then
        f = bor(bor(band(b, c), band(b, d)), band(c, d))
        k = 0x8f1bbcdc
      else
        f = bxor(bxor(b, c), d)
        k = 0xca62c1d6
      end

      local temp = band(rol(a, 5) + f + e + k + w[j], 0xffffffff)
      e = d
      d = c
      c = rol(b, 30)
      b = a
      a = temp
    end

    h0 = band(h0 + a, 0xffffffff)
    h1 = band(h1 + b, 0xffffffff)
    h2 = band(h2 + c, 0xffffffff)
    h3 = band(h3 + d, 0xffffffff)
    h4 = band(h4 + e, 0xffffffff)
  end

  return u32hex(h0) .. u32hex(h1) .. u32hex(h2) .. u32hex(h3) .. u32hex(h4)
end

return sha1
