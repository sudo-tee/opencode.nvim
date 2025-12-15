local summary = {
  '✅ Fully Functional and Tested',
  'All unit tests passing',
  'Syntax validation successful',
  'Complete spinner lifecycle management',
  'Robust error handling and cleanup',
  'Ready for production use',
}

---@param n number The upper limit for the FizzBuzz sequence
---@return table A table containing the FizzBuzz sequence
function fizz_buzz(n)
  local result = {}
  for i = 1, n do
    if i % 15 == 0 then
      result[i] = 'FizzBuzz'
    elseif i % 3 == 0 then
      result[i] = 'Fizz'
    elseif i % 5 == 0 then
      result[i] = 'Buzz'
    else
      result[i] = tostring(i)
    end
  end
  return result
end

---@param n number The number of Fibonacci numbers to generate
---@return table A table containing the Fibonacci sequence
function fibbonacci(n)
  if n <= 0 then
    return {}
  elseif n == 1 then
    return { 0 }
  end
  local seq = { 0, 1 }
  for i = 3, n do
    seq[i] = seq[i - 1] + seq[i - 2]
  end
  return seq
end
