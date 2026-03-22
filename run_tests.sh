#!/bin/bash
# run_tests.sh - Test runner with clean failure summary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Parse command line arguments
FILTER=""
TEST_TYPE="all"

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -f, --filter PATTERN    Filter tests by pattern (matches test descriptions)"
    echo "  -t, --type TYPE         Test type: all, minimal, unit, replay, or specific file path"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Run all tests"
    echo "  $0 -f \"Timer\"                        # Run tests matching 'Timer'"
    echo "  $0 -t unit                           # Run only unit tests"
    echo "  $0 -t replay                         # Run only replay tests"
    echo "  $0 -t tests/unit/timer_spec.lua      # Run specific test file"
    echo "  $0 -f \"creates a new timer\" -t unit  # Filter unit tests"
}

while [[ $# -gt 0 ]]; do
    case $1 in
    -f | --filter)
        FILTER="$2"
        shift 2
        ;;
    -t | --type)
        TEST_TYPE="$2"
        shift 2
        ;;
    -h | --help)
        print_usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        print_usage
        exit 1
        ;;
    esac
done

# Clean test output by removing Errors lines
clean_output() {
    echo "$1" | grep -v "\[31mErrors : "
}

# Build filter option for plenary
FILTER_OPTION=""
if [ -n "$FILTER" ]; then
    FILTER_OPTION=", filter = '$FILTER'"
fi

if [ -n "$FILTER" ]; then
    echo -e "${YELLOW}Running tests for opencode.nvim (filter: '$FILTER')${NC}"
else
    echo -e "${YELLOW}Running tests for opencode.nvim${NC}"
fi
echo "------------------------------------------------"

# Strip ANSI color codes from output
strip_ansi() {
    echo "$1" | sed -E 's/\x1B\[[0-9;]*[mK]//g'
}

# Check test output for failures
has_failures() {
    local plain_output
    plain_output=$(strip_ansi "$1")
    echo "$plain_output" | grep -Eq "Fail.*\|\||Failed[[:space:]]*:[[:space:]]*[1-9][0-9]*"
}

# Run tests based on type
minimal_output=""
unit_output=""
replay_output=""

if [ "$TEST_TYPE" = "all" ] || [ "$TEST_TYPE" = "minimal" ]; then
    minimal_output=$(nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/minimal', {minimal_init = './tests/minimal/init.lua', sequential = true$FILTER_OPTION})" 2>&1)
    clean_output "$minimal_output"

    if has_failures "$minimal_output"; then
        echo -e "${RED}✗ Minimal tests failed${NC}"
    else
        echo -e "${GREEN}✓ Minimal tests passed${NC}"
    fi
    echo "------------------------------------------------"
fi

if [ "$TEST_TYPE" = "all" ] || [ "$TEST_TYPE" = "unit" ]; then
    unit_output=$(nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/unit', {minimal_init = './tests/minimal/init.lua'$FILTER_OPTION})" 2>&1)
    clean_output "$unit_output"

    if has_failures "$unit_output"; then
        echo -e "${RED}✗ Unit tests failed${NC}"
    else
        echo -e "${GREEN}✓ Unit tests passed${NC}"
    fi
    echo "------------------------------------------------"
fi

if [ "$TEST_TYPE" = "all" ] || [ "$TEST_TYPE" = "replay" ]; then
    replay_output=$(nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/replay', {minimal_init = './tests/minimal/init.lua'$FILTER_OPTION})" 2>&1)
    clean_output "$replay_output"

    if has_failures "$replay_output"; then
        echo -e "${RED}✗ Replay tests failed${NC}"
    else
        echo -e "${GREEN}✓ Replay tests passed${NC}"
    fi
    echo "------------------------------------------------"
fi

# Handle specific test file
if [ "$TEST_TYPE" != "all" ] && [ "$TEST_TYPE" != "minimal" ] && [ "$TEST_TYPE" != "unit" ] && [ "$TEST_TYPE" != "replay" ]; then
    if [ -f "$TEST_TYPE" ]; then
        specific_output=$(nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./$TEST_TYPE', {minimal_init = './tests/minimal/init.lua'$FILTER_OPTION})" 2>&1)
        clean_output "$specific_output"

        if has_failures "$specific_output"; then
            echo -e "${RED}✗ Specific test failed${NC}"
        else
            echo -e "${GREEN}✓ Specific test passed${NC}"
        fi
        echo "------------------------------------------------"

        unit_output="$specific_output"
    else
        echo -e "${RED}Error: Test file '$TEST_TYPE' not found${NC}"
        exit 1
    fi
fi

# Check for any failures
all_output="$minimal_output
$unit_output
$replay_output"

if has_failures "$all_output"; then
    echo -e "\n${RED}======== TEST FAILURES SUMMARY ========${NC}"

    # Extract and format failures
    failures_file=$(mktemp)
    plain_output=$(strip_ansi "$all_output")
    echo "$plain_output" | grep -B 0 -A 6 "Fail.*||" >"$failures_file"
    failure_count=$(echo "$plain_output" | grep -c "Fail.*||")
    if [ "$failure_count" -eq 0 ]; then
        failure_count=$(echo "$plain_output" | grep -E "Failed[[:space:]]*:[[:space:]]*[1-9][0-9]*" | sed -E 's/.*Failed[[:space:]]*:[[:space:]]*([0-9]+).*/\1/' | awk '{sum+=$1} END {print sum+0}')
    fi

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
    done <"$failures_file"

    rm -f "$failures_file"
    exit 1
else
    echo -e "${GREEN}All tests passed successfully!${NC}"
    exit 0
fi
