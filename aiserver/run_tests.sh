#!/usr/bin/env bash

# Test runner script for Gemma Local Chat API
# This script runs all unit tests with proper configuration

# Set script directory as working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Activate virtual environment if it exists
if [ -d ".venv" ]; then
    source .venv/bin/activate
    echo "✓ Activated virtual environment"
else
    echo "⚠️  No virtual environment found at .venv"
    echo "   Consider creating one with: python -m venv .venv"
fi

# Check if pytest is installed
if ! command -v pytest &> /dev/null; then
    echo "❌ pytest not found. Installing test dependencies..."
    pip install pytest pytest-asyncio
fi

echo ""
echo "🧪 Running Gemma Local Chat API Tests..."
echo "========================================="
echo ""

# Run different test categories
echo "📋 Running ALL unit tests..."
pytest tests/ -v --tb=short

echo ""
echo "📊 Running tests with coverage (if available)..."
if command -v pytest-cov &> /dev/null; then
    pytest tests/ --cov=routes --cov=utils --cov=state --cov=model_manager --cov=models --cov-report=term-missing
else
    echo "   pytest-cov not installed. Install with: pip install pytest-cov"
fi

echo ""
echo "🎯 Running tests by module..."
echo "   • Utils tests (19 tests)..."
pytest tests/test_utils.py -q
echo "   • State tests (25 tests)..."
pytest tests/test_state.py -q  
echo "   • Model Manager tests (18 tests)..."
pytest tests/test_model_manager.py -q
echo "   • Models tests (33 tests)..."
pytest tests/test_models.py -q
echo "   • API Routes tests (25 tests total):"
echo "     - Health check (8 tests)..."
pytest tests/test_health_check.py -q
echo "     - Start session (4 tests)..."
pytest tests/test_start_session.py -q
echo "     - Chat response (4 tests)..."
pytest tests/test_chat_response.py -q
echo "     - Embedding generation (5 tests)..."
pytest tests/test_embedding.py -q
echo "     - Embedding upload (4 tests)..."
pytest tests/test_embedding_upload.py -q

echo ""
echo "✅ Test run complete!"
echo ""
echo "💡 Useful test commands:"
echo "   - Run all tests: pytest tests/"
echo "   - Run specific module: pytest tests/test_utils.py"
echo "   - Run specific endpoint: pytest tests/test_health_check.py"
echo "   - Run specific class: pytest tests/test_health_check.py::TestHealthCheck"
echo "   - Run specific test: pytest tests/test_health_check.py::TestHealthCheck::test_health_check_no_models_loaded"
echo "   - Run with coverage: pytest tests/ --cov=routes --cov=utils --cov=state --cov=model_manager --cov=models"
echo "   - Run in verbose mode: pytest tests/ -v"
echo "   - Run and stop on first failure: pytest tests/ -x"
echo "   - Run in quiet mode: pytest tests/ -q"