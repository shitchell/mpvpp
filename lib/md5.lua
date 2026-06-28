-- lib/md5.lua : pure-Lua MD5 (RFC 1321), Lua 5.1 compatible.
--
-- Implements 32-bit bitwise ops via plain arithmetic mod 2^32 so the module
-- has zero dependency on any `bit`/`bit32`/LuaJIT bit library and uses no
-- Lua 5.3 native bitwise operators. Returns a table with M.sum(s) -> lowercase
-- 32-char hex digest.

local floor = math.floor

local TWO32 = 4294967296 -- 2^32

-- 32-bit bitwise XOR via bit-by-bit arithmetic.
local function bxor(a, b)
  local r, p = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + p end
    a = (a - x) / 2
    b = (b - y) / 2
    p = p * 2
  end
  return r
end

-- 32-bit bitwise AND.
local function band(a, b)
  local r, p = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x == 1 and y == 1 then r = r + p end
    a = (a - x) / 2
    b = (b - y) / 2
    p = p * 2
  end
  return r
end

-- 32-bit bitwise OR.
local function bor(a, b)
  local r, p = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x == 1 or y == 1 then r = r + p end
    a = (a - x) / 2
    b = (b - y) / 2
    p = p * 2
  end
  return r
end

-- 32-bit bitwise NOT (one's complement).
local function bnot(a)
  return (TWO32 - 1) - a
end

-- Logical left shift within 32 bits.
local function lshift(a, n)
  return (a * (2 ^ n)) % TWO32
end

-- Logical right shift within 32 bits.
local function rshift(a, n)
  return floor(a / (2 ^ n))
end

-- 32-bit left rotate by c bits.
local function lrotate(x, c)
  return bor(lshift(x, c), rshift(x, 32 - c))
end

-- Addition mod 2^32.
local function add32(a, b)
  return (a + b) % TWO32
end

-- Per-round left-rotate amounts (RFC 1321).
local S = {
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

-- K[i] = floor(abs(sin(i)) * 2^32), i = 1..64 (RFC 1321 constants).
local K = {
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
  0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
  0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
  0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
  0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
  0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
  0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

-- Format a 32-bit word as 8 lowercase hex chars in little-endian byte order.
local function word_le_hex(w)
  local b0 = w % 256; w = floor(w / 256)
  local b1 = w % 256; w = floor(w / 256)
  local b2 = w % 256; w = floor(w / 256)
  local b3 = w % 256
  return string.format("%02x%02x%02x%02x", b0, b1, b2, b3)
end

local M = {}

function M.sum(s)
  -- Pad the message: append 0x80, then 0x00 until length ≡ 56 (mod 64),
  -- then the original length in bits as a 64-bit little-endian integer.
  local msg_len = #s
  local bit_len = msg_len * 8

  local pad_count = (56 - (msg_len + 1) % 64) % 64
  local padded = s .. string.char(128) .. string.rep(string.char(0), pad_count)

  -- 64-bit little-endian length (bytes 0..7).
  local len_bytes = {}
  local n = bit_len
  for i = 1, 8 do
    len_bytes[i] = string.char(n % 256)
    n = floor(n / 256)
  end
  padded = padded .. table.concat(len_bytes)

  -- Initial state (little-endian word constants).
  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476

  local total = #padded
  for block = 1, total, 64 do
    -- Decode 16 little-endian 32-bit words from this 64-byte block.
    local Mw = {}
    for j = 0, 15 do
      local p = block + j * 4
      local x1, x2, x3, x4 = string.byte(padded, p, p + 3)
      Mw[j] = x1 + x2 * 256 + x3 * 65536 + x4 * 16777216
    end

    local A, B, C, D = a0, b0, c0, d0
    for i = 0, 63 do
      local F, g
      if i < 16 then
        F = bor(band(B, C), band(bnot(B), D))
        g = i
      elseif i < 32 then
        F = bor(band(D, B), band(bnot(D), C))
        g = (5 * i + 1) % 16
      elseif i < 48 then
        F = bxor(bxor(B, C), D)
        g = (3 * i + 5) % 16
      else
        F = bxor(C, bor(B, bnot(D)))
        g = (7 * i) % 16
      end

      F = add32(add32(add32(F, A), K[i + 1]), Mw[g])
      A = D
      D = C
      C = B
      B = add32(B, lrotate(F, S[i + 1]))
    end

    a0 = add32(a0, A)
    b0 = add32(b0, B)
    c0 = add32(c0, C)
    d0 = add32(d0, D)
  end

  return word_le_hex(a0) .. word_le_hex(b0) .. word_le_hex(c0) .. word_le_hex(d0)
end

return M
