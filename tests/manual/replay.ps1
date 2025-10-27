# Get the directory containing this script
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Get the project root (two directories up)
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir "..\..")

# Change to project root
Set-Location $ProjectRoot

Write-Host "Starting Streaming Renderer Replay Test..."
Write-Host ""

# Run Neovim with the test init file, passing all arguments through
nvim -u "tests/manual/init_replay.lua" @Args

