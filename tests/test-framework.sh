#!/bin/bash
# Proxmox Health Monitoring - Test Framework
# shellcheck disable=SC1091
# Comprehensive testing suite for the monitoring system

set -euo pipefail

# Test configuration
TEST_DIR="/tmp/proxmox-health-tests"
TEST_RESULTS="$TEST_DIR/results"
TEST_LOGS="$TEST_DIR/logs"

# Test result tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize test environment
init_test_env() {
    echo -e "${BLUE}Initializing test environment...${NC}"

    mkdir -p "$TEST_RESULTS" "$TEST_LOGS"

    # Create test configuration
    cat > "$TEST_DIR/test-config.sh" << 'EOF'
# Test configuration overrides
LOG_LEVEL="DEBUG"
STATE_DIR="/tmp/proxmox-health-test-state"
LOG_DIR="/tmp/proxmox-health-test-logs"
WEBHOOK_URL="https://hooks.example.com/test-webhook"
EMAIL_NOTIFICATIONS_ENABLED="no"
CACHE_ENABLED="yes"
ALERT_COOLDOWN_MINUTES=1
EOF

    # Setup test directories
    mkdir -p "$STATE_DIR" "$LOG_DIR"

    echo -e "${GREEN}Test environment initialized${NC}"
}

# Test runner
run_test() {
    local test_name="$1"
    local test_func="$2"
    local expected_result="${3:-0}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "${BLUE}Running test: $test_name${NC}"

    local test_log="$TEST_LOGS/$test_name.log"
    local start_time
    start_time=$(date +%s.%N)

    # Run the test
    local actual_result
    if "$test_func" >"$test_log" 2>&1; then
        actual_result=0
    else
        actual_result=$?
    fi

    local end_time
    end_time=$(date +%s.%N)
    local duration
    duration=$(echo "$end_time - $start_time" | bc -l)

    # Check result
    if [ "$actual_result" -eq "$expected_result" ]; then
        echo -e "  ${GREEN}✓ PASSED${NC} (${duration}s)"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo "PASSED: $test_name" >> "$TEST_RESULTS/passed.txt"
    else
        echo -e "  ${RED}✗ FAILED${NC} (expected: $expected_result, got: $actual_result) (${duration}s)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo "FAILED: $test_name" >> "$TEST_RESULTS/failed.txt"
        echo "  Log: $test_log"
    fi
}

# Skip test
skip_test() {
    local test_name="$1"
    local reason="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
    echo -e "${YELLOW}SKIPPED: $test_name - $reason${NC}"
    echo "SKIPPED: $test_name - $reason" >> "$TEST_RESULTS/skipped.txt"
}

# Test functions
test_configuration_loading() {
    source "/etc/proxmox-health/proxmox-health.conf"

    # Test that required variables are set
    [ -n "$LOG_LEVEL" ] || return 1
    [ -n "$STATE_DIR" ] || return 1
    [ -n "$LOG_DIR" ] || return 1

    # Test numeric thresholds
    [[ "$MEMORY_WARNING_THRESHOLD" =~ ^[0-9]+$ ]] || return 1
    [[ "$DISK_ROOT_WARNING_THRESHOLD" =~ ^[0-9]+$ ]] || return 1

    return 0
}

test_logging_functions() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test logging functions exist
    declare -f log_debug >/dev/null || return 1
    declare -f log_info >/dev/null || return 1
    declare -f log_warning >/dev/null || return 1
    declare -f log_error >/dev/null || return 1
    declare -f log_critical >/dev/null || return 1

    # Test logging output
    log_debug "Test debug message"
    log_info "Test info message"
    log_warning "Test warning message"
    log_error "Test error message"
    log_critical "Test critical message"

    # Check if log file was created
    [ -f "$LOG_DIR/proxmox-health.log" ] || return 1

    return 0
}

test_notification_functions() {
    source "/usr/local/lib/proxmox-health/notifications.sh"

    # Test notification functions exist
    declare -f send_notification >/dev/null || return 1
    declare -f alert_once >/dev/null || return 1
    declare -f alert_clear >/dev/null || return 1

    # Test state management
    get_notification_state "test-key"
    set_notification_state "test-key" "test-value"
    local retrieved_state
    retrieved_state=$(get_notification_state "test-key")

    [ "$retrieved_state" = "test-value" ] || return 1

    return 0
}

test_maintenance_mode() {
    source "/usr/local/lib/proxmox-health/notifications.sh"

    # Test maintenance mode functions
    declare -f enable_maintenance_mode >/dev/null || return 1
    declare -f disable_maintenance_mode >/dev/null || return 1
    declare -f check_maintenance_mode >/dev/null || return 1

    # Test enabling maintenance mode
    enable_maintenance_mode "1m" "Test maintenance"
    check_maintenance_mode || return 1

    # Test disabling maintenance mode
    disable_maintenance_mode
    check_maintenance_mode && return 1  # Should return false

    return 0
}

test_cache_functions() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test cache functions exist
    declare -f get_cache_value >/dev/null || return 1
    declare -f set_cache_value >/dev/null || return 1
    declare -f clear_cache >/dev/null || return 1

    # Test cache operations
    set_cache_value "test-key" "test-value"
    local cached_value
    cached_value=$(get_cache_value "test-key")

    [ "$cached_value" = "test-value" ] || return 1

    # Test cache clearing
    clear_cache
    get_cache_value "test-key" && return 1  # Should return false

    return 0
}

test_health_check_functions() {
    source "/usr/local/lib/proxmox-health/health-checks.sh"

    # Test that health check functions exist
    declare -f check_services >/dev/null || return 1
    declare -f check_disk_space >/dev/null || return 1
    declare -f check_memory >/dev/null || return 1
    declare -f check_network >/dev/null || return 1
    declare -f run_all_health_checks >/dev/null || return 1

    return 0
}

test_error_handling() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test error handling functions
    declare -f handle_error >/dev/null || return 1
    declare -f set_error_handling >/dev/null || return 1

    # Test configuration validation
    validate_configuration || return 1

    return 0
}

test_disk_operations() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test disk operations
    declare -f backup_configuration >/dev/null || return 1
    declare -f restore_configuration >/dev/null || return 1
    declare -f cleanup_old_files >/dev/null || return 1

    # Test directory creation
    setup_directories || return 1

    return 0
}

test_system_info() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test system info functions
    declare -f get_system_info >/dev/null || return 1
    declare -f get_load_average >/dev/null || return 1
    declare -f get_memory_usage >/dev/null || return 1
    declare -f get_disk_usage >/dev/null || return 1

    # Test getting system info
    local sys_info
    sys_info=$(get_system_info)
    [ -n "$sys_info" ] || return 1

    local load_avg
    load_avg=$(get_load_average)
    [ -n "$load_avg" ] || return 1

    return 0
}

test_network_functions() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test network functions
    declare -f test_connectivity >/dev/null || return 1
    declare -f get_network_interface_info >/dev/null || return 1

    # Test network interface info
    get_network_interface_info "lo" >/dev/null || return 1

    return 0
}

test_time_functions() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test time functions
    declare -f is_business_hours >/dev/null || return 1
    declare -f get_next_business_day >/dev/null || return 1

    # Test business hours check
    is_business_hours  # Should return 0 or 1

    return 0
}

test_version_management() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test version function
    declare -f get_script_version >/dev/null || return 1

    local version
    version=$(get_script_version)
    [ -n "$version" ] || return 1

    return 0
}

test_dependency_checking() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test dependency checking
    declare -f check_dependencies >/dev/null || return 1

    # Test that required commands exist
    check_dependencies || return 1

    return 0
}

test_integration() {
    # Test that all components work together
    source "/etc/proxmox-health/proxmox-health.conf"
    source "/usr/local/lib/proxmox-health/utils.sh"
    source "/usr/local/lib/proxmox-health/notifications.sh"
    source "/usr/local/lib/proxmox-health/health-checks.sh"

    # Test initialization
    initialize_system || return 1

    # Test running a simple health check
    check_services || return 1

    return 0
}

test_performance() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test performance with multiple operations
    local start_time
    start_time=$(date +%s.%N)

    # Run multiple cache operations
    for i in {1..100}; do
        set_cache_value "perf-test-$i" "value-$i"
        get_cache_value "perf-test-$i" >/dev/null
    done

    local end_time
    end_time=$(date +%s.%N)
    local duration
    duration=$(echo "$end_time - $start_time" | bc -l)

    # Performance should be reasonable (< 5 seconds for 100 operations)
    (( $(echo "$duration < 5" | bc -l) )) || return 1

    return 0
}

test_security() {
    source "/usr/local/lib/proxmox-health/utils.sh"

    # Test file permissions
    [ -d "$STATE_DIR" ] || return 1
    [ -d "$LOG_DIR" ] || return 1

    # Test that sensitive files have restrictive permissions
    if [ -f "/etc/proxmox-health/webhook-secret" ]; then
        local perm
        perm=$(stat -c "%a" "/etc/proxmox-health/webhook-secret")
        [ "$perm" = "600" ] || return 1
    fi

    return 0
}

# Run all tests
run_all_tests() {
    echo -e "${BLUE}=== Proxmox Health Monitoring Test Suite ===${NC}"
    echo

    # Initialize test environment
    init_test_env

    # Clear previous results
    : > "$TEST_RESULTS/passed.txt"
    : > "$TEST_RESULTS/failed.txt"
    : > "$TEST_RESULTS/skipped.txt"

    # Run individual test suites
    echo -e "${BLUE}=== Configuration Tests ===${NC}"
    run_test "Configuration Loading" test_configuration_loading
    run_test "Error Handling" test_error_handling

    echo -e "\n${BLUE}=== Logging Tests ===${NC}"
    run_test "Logging Functions" test_logging_functions

    echo -e "\n${BLUE}=== Notification Tests ===${NC}"
    run_test "Notification Functions" test_notification_functions
    run_test "Maintenance Mode" test_maintenance_mode

    echo -e "\n${BLUE}=== Utility Tests ===${NC}"
    run_test "Cache Functions" test_cache_functions
    run_test "Disk Operations" test_disk_operations
    run_test "System Info" test_system_info
    run_test "Network Functions" test_network_functions
    run_test "Time Functions" test_time_functions
    run_test "Version Management" test_version_management
    run_test "Dependency Checking" test_dependency_checking

    echo -e "\n${BLUE}=== Health Check Tests ===${NC}"
    run_test "Health Check Functions" test_health_check_functions

    echo -e "\n${BLUE}=== Integration Tests ===${NC}"
    run_test "Integration" test_integration
    run_test "Performance" test_performance
    run_test "Security" test_security

    # Generate test report
    generate_test_report

    # Cleanup
    cleanup_test_env
}

generate_test_report() {
    echo -e "\n${BLUE}=== Test Results ===${NC}"
    echo -e "Total Tests: $TOTAL_TESTS"
    echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
    echo -e "${RED}Failed: $FAILED_TESTS${NC}"
    echo -e "${YELLOW}Skipped: $SKIPPED_TESTS${NC}"

    # Calculate success rate
    if [ "$TOTAL_TESTS" -gt 0 ]; then
        local success_rate
        success_rate=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
        echo -e "Success Rate: $success_rate%"
    fi

    # Show failed tests if any
    if [ "$FAILED_TESTS" -gt 0 ]; then
        echo -e "\n${RED}Failed Tests:${NC}"
        cat "$TEST_RESULTS/failed.txt"
    fi

    # Show skipped tests if any
    if [ "$SKIPPED_TESTS" -gt 0 ]; then
        echo -e "\n${YELLOW}Skipped Tests:${NC}"
        cat "$TEST_RESULTS/skipped.txt"
    fi

    # Generate detailed report
    cat > "$TEST_RESULTS/report.txt" << EOF
Proxmox Health Monitoring Test Report
=====================================
Generated: $(date)
Test Environment: $(hostname)

Test Results:
- Total Tests: $TOTAL_TESTS
- Passed: $PASSED_TESTS
- Failed: $FAILED_TESTS
- Skipped: $SKIPPED_TESTS
- Success Rate: $(( (PASSED_TESTS * 100) / TOTAL_TESTS ))%

System Information:
- OS: $(uname -a)
- Memory: $(free -h | awk '/Mem:/ {print $2}')
- Disk: $(df -h / | awk 'NR==2 {print $2}')
- CPU: $(nproc) cores

Test Logs Location: $TEST_LOGS
Test Results Location: $TEST_RESULTS
EOF
}

cleanup_test_env() {
    echo -e "\n${BLUE}Cleaning up test environment...${NC}"

    # Remove test directories
    rm -rf "$STATE_DIR" "$LOG_DIR"

    echo -e "${GREEN}Test environment cleaned up${NC}"
}

# Main execution
main() {
    case "${1:-all}" in
        "config")
            init_test_env
            run_test "Configuration Loading" test_configuration_loading
            run_test "Error Handling" test_error_handling
            ;;
        "logging")
            init_test_env
            run_test "Logging Functions" test_logging_functions
            ;;
        "notifications")
            init_test_env
            run_test "Notification Functions" test_notification_functions
            run_test "Maintenance Mode" test_maintenance_mode
            ;;
        "utils")
            init_test_env
            run_test "Cache Functions" test_cache_functions
            run_test "Disk Operations" test_disk_operations
            run_test "System Info" test_system_info
            run_test "Network Functions" test_network_functions
            run_test "Time Functions" test_time_functions
            run_test "Version Management" test_version_management
            run_test "Dependency Checking" test_dependency_checking
            ;;
        "health")
            init_test_env
            run_test "Health Check Functions" test_health_check_functions
            ;;
        "integration")
            init_test_env
            run_test "Integration" test_integration
            run_test "Performance" test_performance
            run_test "Security" test_security
            ;;
        "clean")
            rm -rf "$TEST_DIR"
            echo -e "${GREEN}Test directory removed${NC}"
            ;;
        "all"|*)
            run_all_tests
            ;;
    esac

    # Exit with appropriate code
    [ $FAILED_TESTS -eq 0 ] || exit 1
}

# Run main function
main "$@"
