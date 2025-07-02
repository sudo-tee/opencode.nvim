#!/bin/bash
# run_tests.sh - Test runner with clean failure summary

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Clean test output by removing Errors lines
clean_output() {
    echo "$1" | grep -v "\[31mErrors : "
}

echo -e "${YELLOW}Running all tests for opencode.nvim${NC}"
echo "------------------------------------------------"

# Run minimal tests
minimal_output=$(nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/minimal', {minimal_init = './tests/minimal/init.lua', sequential = true})" 2>&1)
minimal_status=$?
clean_output "$minimal_output"

if [ $minimal_status -eq 0 ]; then
    echo -e "${GREEN}✓ Minimal tests passed${NC}"
else
    echo -e "${RED}✗ Minimal tests failed${NC}"
fi
echo "------------------------------------------------"

# Run unit tests
unit_output=$(nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/unit', {minimal_init = './tests/minimal/init.lua'})" 2>&1)
unit_status=$?
clean_output "$unit_output"

if [ $unit_status -eq 0 ]; then
    echo -e "${GREEN}✓ Unit tests passed${NC}"
else
    echo -e "${RED}✗ Unit tests failed${NC}"
fi
echo "------------------------------------------------"

# Check for any failures
all_output="$minimal_output
$unit_output"

if [ $minimal_status -ne 0 ] || [ $unit_status -ne 0 ] || echo "$all_output" | grep -q "\[31mFail"; then
    echo -e "\n${RED}======== TEST FAILURES SUMMARY ========${NC}"
    
    # Extract and format failures
    failures_file=$(mktemp)
    echo "$all_output" | grep -B 0 -A 6 "\[31mFail.*||" > "$failures_file"
    failure_count=$(grep -c "\[31mFail.*||" "$failures_file")
    
    echo -e "${RED}Found $failure_count failing test(s):${NC}\n"
    
    # Process the output line by line
    test_name=""
    while IFS= read -r line; do
        # Remove ANSI color codes
        clean_line=$(echo "$line" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
        
        if [[ "$clean_line" == *"Fail"*"||"* ]]; then
            # Extract test name
            test_name=$(echo "$clean_line" | sed -E 's/.*Fail.*\|\|\s*(.*)/\1/')
            echo -e "${RED}FAILED TEST:${NC} $test_name"
        elif [[ "$clean_line" == *"/Users/"*".lua:"*": "* ]]; then
            # This is an error message with file:line
            echo -e "  ${RED}ERROR:${NC} $clean_line"
        elif [[ "$clean_line" == *"stack traceback"* ]]; then
            # Stack trace header
            echo -e "  ${YELLOW}TRACE:${NC} $clean_line"
        elif [[ "$clean_line" == *"in function"* ]]; then
            # Stack trace details
            echo -e "    $clean_line"
        fi
    done < "$failures_file"
    
    rm -f "$failures_file"
    exit 1
else
    echo -e "${GREEN}All tests passed successfully!${NC}"
    exit 0
fi
