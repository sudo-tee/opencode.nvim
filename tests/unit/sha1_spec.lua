local sha1 = require('opencode.sha1')

describe('sha1', function()
  it('produces correct hash for empty string', function()
    assert.equals('da39a3ee5e6b4b0d3255bfef95601890afd80709', sha1(''))
  end)

  it('produces correct hash for "abc"', function()
    assert.equals('a9993e364706816aba3e25717850c26c9cd0d89d', sha1('abc'))
  end)

  it('produces correct hash for "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"', function()
    assert.equals('84983e441c3bd26ebaae4aa1f95129e5e54670f1', sha1('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))
  end)

  it('produces correct hash for single character', function()
    assert.equals('86f7e437faa5a7fce15d1ddcb9eaeaea377667b8', sha1('a'))
  end)

  it('produces correct hash for "ab"', function()
    assert.equals('da23614e02469a0d7c7bd1bdab5c9c474b1904dc', sha1('ab'))
  end)

  it('produces correct hash for numbers', function()
    assert.equals('01b307acba4f54f55aafc33bb06bbbf6ca803e9a', sha1('1234567890'))
  end)

  it('produces correct hash for special characters', function()
    assert.equals('bf24d65c9bb05b9b814a966940bcfa50767c8a8d', sha1('!@#$%^&*()'))
  end)

  it('produces correct hash for string with spaces', function()
    assert.equals('2aae6c35c94fcfb415dbe95f408b9ce91ee846ed', sha1('hello world'))
  end)

  it('produces correct hash for newlines', function()
    assert.equals('05eed6236c8bda5ecf7af09bae911f9d5f90998b', sha1('line1\nline2'))
  end)

  it('produces correct hash for null byte', function()
    assert.equals('dbdd4f85d8a56500aa5c9c8a0d456f96280c92e5', sha1('ab\0c'))
  end)

  it('produces correct hash for 448-bit message (exactly 56 bytes, boundary condition)', function()
    local msg = string.rep('a', 56)
    assert.equals('c2db330f6083854c99d4b5bfb6e8f29f201be699', sha1(msg))
  end)

  it('produces correct hash for 512-bit message (exactly 64 bytes, one full block)', function()
    local msg = string.rep('a', 64)
    assert.equals('0098ba824b5c16427bd7a1122a5a442a25ec644d', sha1(msg))
  end)

  it('produces correct hash for multi-block message (200 bytes)', function()
    local msg = string.rep('a', 200)
    assert.equals('e61cfffe0d9195a525fc6cf06ca2d77119c24a40', sha1(msg))
  end)

  it('produces correct hash for unicode text', function()
    assert.equals('24e9f5c07847ff8a2a9fa77456655792f5bc7f9f', sha1('héllo wörld'))
  end)
end)
