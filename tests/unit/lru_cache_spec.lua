local LruCache = require('opencode.lru_cache')

describe('LRU cache', function()
  it('evicts the least recently used entry', function()
    local cache = LruCache.new(2)
    cache:set('first', 1)
    cache:set('second', 2)
    assert.equal(1, cache:get('first'))

    cache:set('third', 3)

    assert.is_nil(cache:get('second'))
    assert.equal(1, cache:get('first'))
    assert.equal(3, cache:get('third'))
  end)

  it('updates existing entries without evicting another entry', function()
    local cache = LruCache.new(2)
    cache:set('first', 1)
    cache:set('second', 2)

    cache:set('first', 3)

    assert.equal(3, cache:get('first'))
    assert.equal(2, cache:get('second'))
  end)
end)
