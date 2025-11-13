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

# Run tests based on type
minimal_status=0
unit_status=0
replay_status=0
minimal_output=""
unit_output=""
replay_output=""

if [ "$TEST_TYPE" = "all" ] || [ "$TEST_TYPE" = "minimal" ]; then
    # Run minimal tests
    minimal_output=$(nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/minimal', {minimal_init = './tests/minimal/init.lua', sequential = true$FILTER_OPTION})" 2>&1)
    minimal_status=$?
    clean_output "$minimal_output"

    if [ $minimal_status -eq 0 ]; then
        echo -e "${GREEN}✓ Minimal tests passed${NC}"
    else
        echo -e "${RED}✗ Minimal tests failed${NC}"
    fi
    echo "------------------------------------------------"
fi

if [ "$TEST_TYPE" = "all" ] || [ "$TEST_TYPE" = "unit" ]; then
    # Run unit tests
    unit_output=$(nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/unit', {minimal_init = './tests/minimal/init.lua'$FILTER_OPTION})" 2>&1)
    unit_status=$?
    clean_output "$unit_output"

    if [ $unit_status -eq 0 ]; then
        echo -e "${GREEN}✓ Unit tests passed${NC}"
    else
        echo -e "${RED}✗ Unit tests failed${NC}"
    fi
    echo "------------------------------------------------"
fi

if [ "$TEST_TYPE" = "all" ] || [ "$TEST_TYPE" = "replay" ]; then
    # Run replay tests
    replay_output=$(nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/replay', {minimal_init = './tests/minimal/init.lua'$FILTER_OPTION})" 2>&1)
    replay_status=$?
    clean_output "$replay_output"

    if [ $replay_status -eq 0 ]; then
        echo -e "${GREEN}✓ Replay tests passed${NC}"
    else
        echo -e "${RED}✗ Replay tests failed${NC}"
    fi
    echo "------------------------------------------------"
fi

# Handle specific test file
if [ "$TEST_TYPE" != "all" ] && [ "$TEST_TYPE" != "minimal" ] && [ "$TEST_TYPE" != "unit" ] && [ "$TEST_TYPE" != "replay" ]; then
    # Assume it's a specific test file path
    if [ -f "$TEST_TYPE" ]; then
        specific_output=$(nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./$TEST_TYPE', {minimal_init = './tests/minimal/init.lua'$FILTER_OPTION})" 2>&1)
        specific_status=$?
        clean_output "$specific_output"

        if [ $specific_status -eq 0 ]; then
            echo -e "${GREEN}✓ Specific test passed${NC}"
        else
            echo -e "${RED}✗ Specific test failed${NC}"
        fi
        echo "------------------------------------------------"

        # Use specific test output for failure analysis
        unit_output="$specific_output"
        unit_status=$specific_status
    else
        echo -e "${RED}Error: Test file '$TEST_TYPE' not found${NC}"
        exit 1
    fi
fi

# Check for any failures
all_output="$minimal_output
$unit_output
$replay_output"

if [ $minimal_status -ne 0 ] || [ $unit_status -ne 0 ] || [ $replay_status -ne 0 ] || echo "$all_output" | grep -q "\[31mFail.*||"; then
    echo -e "\n${RED}======== TEST FAILURES SUMMARY ========${NC}"

    # Extract and format failures
    failures_file=$(mktemp)
    echo "$all_output" | grep -B 0 -A 6 "\[31mFail.*||" >"$failures_file"
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
    done <"$failures_file"

    rm -f "$failures_file"
    exit 1
else
    echo -e "${GREEN}All tests passed successfully!${NC}"
    exit 0
fi
