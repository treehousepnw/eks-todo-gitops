#!/bin/bash
# =============================================================================
# TODO API Test Script
# =============================================================================
# Tests all CRUD endpoints of the TODO API with colorized output.
#
# Usage:
#   ./scripts/test-api.sh                    # Uses localhost:8080
#   ./scripts/test-api.sh http://api.example.com  # Uses custom URL
#
# Prerequisites:
#   - curl
#   - jq (optional, for pretty JSON output)
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration
BASE_URL="${1:-http://localhost:8080}"
PASSED=0
FAILED=0
TODO_ID=""

# Helper functions
print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_test() {
    echo -e "\n${CYAN}▶ TEST:${NC} $1"
}

print_request() {
    echo -e "${YELLOW}  → $1${NC}"
}

print_response() {
    echo -e "${YELLOW}  ← Status: $1${NC}"
}

print_pass() {
    echo -e "${GREEN}  ✓ PASS:${NC} $1"
    ((PASSED++))
}

print_fail() {
    echo -e "${RED}  ✗ FAIL:${NC} $1"
    ((FAILED++))
}

print_json() {
    if command -v jq &> /dev/null; then
        echo "$1" | jq '.' 2>/dev/null || echo "$1"
    else
        echo "$1"
    fi
}

# Check if API is reachable
check_api() {
    print_header "Checking API Connectivity"
    print_request "GET $BASE_URL/health"

    if ! curl -s --connect-timeout 5 "$BASE_URL/health" > /dev/null 2>&1; then
        echo -e "${RED}ERROR: Cannot connect to API at $BASE_URL${NC}"
        echo -e "${YELLOW}Make sure the API is running and accessible.${NC}"
        echo ""
        echo "For local testing:"
        echo "  kubectl port-forward svc/todo-api 8080:80 -n apps"
        echo ""
        echo "For EKS LoadBalancer:"
        echo "  kubectl get svc todo-api -n apps -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
        exit 1
    fi
    echo -e "${GREEN}API is reachable at $BASE_URL${NC}"
}

# =============================================================================
# Test: Health Check
# =============================================================================
test_health() {
    print_header "Health Check"
    print_test "GET /health returns status"
    print_request "GET $BASE_URL/health"

    response=$(curl -s -w "\n%{http_code}" "$BASE_URL/health")
    body=$(echo "$response" | head -n -1)
    status=$(echo "$response" | tail -n 1)

    print_response "$status"
    echo -e "  Response:"
    print_json "$body" | sed 's/^/    /'

    if [ "$status" -eq 200 ] || [ "$status" -eq 503 ]; then
        print_pass "Health endpoint responded"

        # Check response structure
        if echo "$body" | grep -q '"status"'; then
            print_pass "Response contains 'status' field"
        else
            print_fail "Response missing 'status' field"
        fi
    else
        print_fail "Unexpected status code: $status"
    fi
}

# =============================================================================
# Test: Create Todo
# =============================================================================
test_create() {
    print_header "Create Todo (POST)"
    print_test "POST /api/todos creates a new todo"
    print_request "POST $BASE_URL/api/todos"

    response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/todos" \
        -H "Content-Type: application/json" \
        -d '{"title": "Test todo from script", "completed": false}')
    body=$(echo "$response" | head -n -1)
    status=$(echo "$response" | tail -n 1)

    print_response "$status"
    echo -e "  Response:"
    print_json "$body" | sed 's/^/    /'

    if [ "$status" -eq 201 ]; then
        print_pass "Todo created successfully"

        # Extract ID for later tests
        if command -v jq &> /dev/null; then
            TODO_ID=$(echo "$body" | jq -r '.id')
        else
            TODO_ID=$(echo "$body" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
        fi
        echo -e "${CYAN}  📌 Saved TODO_ID: $TODO_ID for subsequent tests${NC}"
    else
        print_fail "Failed to create todo (status: $status)"
    fi

    # Test validation
    print_test "POST /api/todos without title returns 400"
    print_request "POST $BASE_URL/api/todos (empty body)"

    response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/todos" \
        -H "Content-Type: application/json" \
        -d '{}')
    status=$(echo "$response" | tail -n 1)

    print_response "$status"

    if [ "$status" -eq 400 ]; then
        print_pass "Validation error returned correctly"
    else
        print_fail "Expected 400, got $status"
    fi
}

# =============================================================================
# Test: Get All Todos
# =============================================================================
test_get_all() {
    print_header "Get All Todos (GET)"
    print_test "GET /api/todos returns array"
    print_request "GET $BASE_URL/api/todos"

    response=$(curl -s -w "\n%{http_code}" "$BASE_URL/api/todos")
    body=$(echo "$response" | head -n -1)
    status=$(echo "$response" | tail -n 1)

    print_response "$status"
    echo -e "  Response (truncated):"
    print_json "$body" | head -20 | sed 's/^/    /'

    if [ "$status" -eq 200 ]; then
        print_pass "Get all todos successful"

        # Check if response is array
        if echo "$body" | grep -q '^\['; then
            print_pass "Response is an array"
        else
            print_fail "Response is not an array"
        fi
    else
        print_fail "Failed to get todos (status: $status)"
    fi
}

# =============================================================================
# Test: Get Single Todo
# =============================================================================
test_get_one() {
    print_header "Get Single Todo (GET)"

    if [ -z "$TODO_ID" ]; then
        echo -e "${YELLOW}  Skipping: No TODO_ID from create test${NC}"
        return
    fi

    print_test "GET /api/todos/$TODO_ID returns the todo"
    print_request "GET $BASE_URL/api/todos/$TODO_ID"

    response=$(curl -s -w "\n%{http_code}" "$BASE_URL/api/todos/$TODO_ID")
    body=$(echo "$response" | head -n -1)
    status=$(echo "$response" | tail -n 1)

    print_response "$status"
    echo -e "  Response:"
    print_json "$body" | sed 's/^/    /'

    if [ "$status" -eq 200 ]; then
        print_pass "Got todo successfully"
    else
        print_fail "Failed to get todo (status: $status)"
    fi

    # Test 404
    print_test "GET /api/todos/99999 returns 404"
    print_request "GET $BASE_URL/api/todos/99999"

    response=$(curl -s -w "\n%{http_code}" "$BASE_URL/api/todos/99999")
    status=$(echo "$response" | tail -n 1)

    print_response "$status"

    if [ "$status" -eq 404 ]; then
        print_pass "404 returned for non-existent todo"
    else
        print_fail "Expected 404, got $status"
    fi
}

# =============================================================================
# Test: Update Todo
# =============================================================================
test_update() {
    print_header "Update Todo (PUT)"

    if [ -z "$TODO_ID" ]; then
        echo -e "${YELLOW}  Skipping: No TODO_ID from create test${NC}"
        return
    fi

    print_test "PUT /api/todos/$TODO_ID updates the todo"
    print_request "PUT $BASE_URL/api/todos/$TODO_ID"

    response=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/api/todos/$TODO_ID" \
        -H "Content-Type: application/json" \
        -d '{"title": "Updated todo title", "completed": true}')
    body=$(echo "$response" | head -n -1)
    status=$(echo "$response" | tail -n 1)

    print_response "$status"
    echo -e "  Response:"
    print_json "$body" | sed 's/^/    /'

    if [ "$status" -eq 200 ]; then
        print_pass "Todo updated successfully"

        # Verify the update
        if echo "$body" | grep -q '"completed":true\|"completed": true'; then
            print_pass "Completed status updated to true"
        else
            print_fail "Completed status not updated"
        fi
    else
        print_fail "Failed to update todo (status: $status)"
    fi

    # Test partial update
    print_test "PUT /api/todos/$TODO_ID with partial data works"
    print_request "PUT $BASE_URL/api/todos/$TODO_ID (title only)"

    response=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/api/todos/$TODO_ID" \
        -H "Content-Type: application/json" \
        -d '{"title": "Partially updated"}')
    status=$(echo "$response" | tail -n 1)

    print_response "$status"

    if [ "$status" -eq 200 ]; then
        print_pass "Partial update successful"
    else
        print_fail "Partial update failed (status: $status)"
    fi
}

# =============================================================================
# Test: Delete Todo
# =============================================================================
test_delete() {
    print_header "Delete Todo (DELETE)"

    if [ -z "$TODO_ID" ]; then
        echo -e "${YELLOW}  Skipping: No TODO_ID from create test${NC}"
        return
    fi

    print_test "DELETE /api/todos/$TODO_ID removes the todo"
    print_request "DELETE $BASE_URL/api/todos/$TODO_ID"

    response=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/api/todos/$TODO_ID")
    status=$(echo "$response" | tail -n 1)

    print_response "$status"

    if [ "$status" -eq 204 ]; then
        print_pass "Todo deleted successfully"
    else
        print_fail "Failed to delete todo (status: $status)"
    fi

    # Verify deletion
    print_test "GET /api/todos/$TODO_ID returns 404 after deletion"
    print_request "GET $BASE_URL/api/todos/$TODO_ID"

    response=$(curl -s -w "\n%{http_code}" "$BASE_URL/api/todos/$TODO_ID")
    status=$(echo "$response" | tail -n 1)

    print_response "$status"

    if [ "$status" -eq 404 ]; then
        print_pass "Deleted todo not found (confirmed)"
    else
        print_fail "Expected 404, got $status"
    fi

    # Test deleting non-existent
    print_test "DELETE /api/todos/99999 returns 404"
    print_request "DELETE $BASE_URL/api/todos/99999"

    response=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/api/todos/99999")
    status=$(echo "$response" | tail -n 1)

    print_response "$status"

    if [ "$status" -eq 404 ]; then
        print_pass "404 returned for non-existent todo"
    else
        print_fail "Expected 404, got $status"
    fi
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    print_header "Test Summary"

    TOTAL=$((PASSED + FAILED))

    echo -e "  ${GREEN}Passed:${NC} $PASSED"
    echo -e "  ${RED}Failed:${NC} $FAILED"
    echo -e "  ${CYAN}Total:${NC}  $TOTAL"
    echo ""

    if [ "$FAILED" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}  ✓ All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}${BOLD}  ✗ Some tests failed${NC}"
        exit 1
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║              TODO API Integration Tests                       ║"
    echo "║                                                               ║"
    echo "║  Target: $BASE_URL"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_api
    test_health
    test_create
    test_get_all
    test_get_one
    test_update
    test_delete
    print_summary
}

main
