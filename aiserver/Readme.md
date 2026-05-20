# Gemma Local Chat API - Refactored Structure

This project has been refactored into a more maintainable, modular structure following Python best practices.

## Project Structure

```
local-gemma/
├── main.py              # Main FastAPI application entry point
├── config.py            # Configuration settings and constants
├── models.py            # Pydantic models for request/response validation
├── routes.py            # API route handlers
├── model_manager.py     # Model loading and inference logic
├── utils.py             # Utility functions (file ops, archive handling)
├── state.py             # Global state management
├── requirements.txt     # Python dependencies
├── __init__.py          # Package initialization
├── tests/               # Unit test suite (120 comprehensive tests)
│   ├── __init__.py      # Test package initialization
│   ├── test_utils.py    # Tests for utility functions (19 tests)
│   ├── test_state.py    # Tests for state management (25 tests)
│   ├── test_model_manager.py # Tests for model operations (18 tests)
│   ├── test_models.py   # Tests for Pydantic models (33 tests)
│   ├── test_health_check.py # Tests for health check endpoint (8 tests)
│   ├── test_start_session.py # Tests for session management (4 tests)
│   ├── test_chat_response.py # Tests for chat response generation (4 tests)
│   ├── test_embedding.py # Tests for embedding generation (5 tests)
│   └── test_embedding_upload.py # Tests for file upload embedding (4 tests)
├── run_tests.sh         # Test runner script with coverage options
├── pytest.ini          # Pytest configuration
└── README.md            # This file
```

## File Descriptions

### `main.py` - Application Entry Point
- FastAPI app initialization
- Lifespan management (startup/shutdown)
- Route registration
- Can be run directly with `python main.py`

### `config.py` - Configuration
- Default model settings
- Model loading parameters
- API configuration
- File paths and constants

### `models.py` - Data Models  
- Pydantic models for request validation
- `ChatRequest`, `StartSessionRequest`, `EmbeddingRequest`
- JSON schema examples for API documentation

### `routes.py` - Route Handlers
- All API endpoint implementations
- Request/response handling
- Business logic coordination
- Error handling

### `model_manager.py` - Model Operations
- Model loading and initialization
- Embedding generation
- Text/image processing
- HuggingFace pipeline management

### `utils.py` - Utilities
- File path generation
- Archive extraction (tar, tgz, zip)
- Model downloading from HuggingFace
- General helper functions

### `state.py` - State Management
- Global variable management
- Async lock coordination
- Model instance tracking
- Thread-safe state access

## Running the Application

### Option 1: Run main.py directly
```bash
python main.py
```

### Option 2: Use uvicorn (recommended for production)
```bash
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

## Benefits of This Structure

1. **Separation of Concerns**: Each file has a single, clear responsibility
2. **Maintainability**: Easier to find and modify specific functionality
3. **Testability**: Individual modules can be tested in isolation
4. **Scalability**: Easy to add new features without bloating existing files
5. **Readability**: Code is organized logically and easy to navigate
6. **Reusability**: Utility functions and models can be imported elsewhere

## Migration from Original app.py

The original monolithic `app.py` (400+ lines) has been split into focused modules:

- **Routes** (150 lines) → `routes.py`
- **Model Logic** (100 lines) → `model_manager.py`  
- **Utilities** (80 lines) → `utils.py`
- **Configuration** (20 lines) → `config.py`
- **Data Models** (50 lines) → `models.py`
- **State Management** (60 lines) → `state.py`
- **Main App** (30 lines) → `main.py`

This makes the codebase much more manageable and follows Python packaging best practices.

## Testing

The project includes comprehensive unit tests with full coverage of the API endpoints.

### Running Tests

#### Quick Test Run
```bash
# Run all tests
./run_tests.sh

# Or use pytest directly
pytest tests/ -v
```

#### Manual Test Commands
```bash
# Run specific endpoint tests
pytest tests/test_health_check.py -v

# Run specific test class
pytest tests/test_health_check.py::TestHealthCheck -v

# Run specific test method
pytest tests/test_health_check.py::TestHealthCheck::test_health_check_no_models_loaded -v

# Run with coverage report
pytest tests/ --cov=routes --cov=utils --cov=state --cov=model_manager --cov=models --cov-report=term-missing

# Run and stop on first failure
pytest -x tests/
```

### Test Structure

The test suite includes:
- **Unit tests** for individual route handlers
- **Mock-based testing** to isolate functionality  
- **Async test support** using pytest-asyncio
- **Comprehensive scenarios** including error conditions
- **Response structure validation** ensuring API consistency

### Test Coverage

**120 comprehensive unit tests** covering all modules:

#### `tests/test_utils.py` (19 tests)
- ✅ Path generation functions (`get_local_path`, `get_local_zip_path`)
- ✅ Archive extraction (`handle_local_archive`)  
- ✅ Model downloading logic (`download_model_if_needed`)
- ✅ Error handling and edge cases

#### `tests/test_state.py` (25 tests)  
- ✅ Global state getter/setter functions
- ✅ LLM and embedding model management
- ✅ Async lock coordination
- ✅ State independence and cleanup

#### `tests/test_model_manager.py` (18 tests)
- ✅ Base64 image decoding (`decode_base64_image`)
- ✅ Model loading interfaces (mocked ML operations)
- ✅ Embedding generation interfaces
- ✅ Image processing workflows

#### `tests/test_models.py` (33 tests)
- ✅ Pydantic model validation (`ChatRequest`, `StartSessionRequest`, `EmbeddingRequest`)
- ✅ JSON serialization/deserialization
- ✅ Field validation and error handling
- ✅ Schema generation for OpenAPI

#### API Endpoint Tests (25 tests total)
#### `tests/test_health_check.py` (8 tests)
- ✅ Health check endpoint (all model states, loading conditions, response structure)

#### `tests/test_start_session.py` (4 tests)
- ✅ Session management (`start_session`)
- ✅ Model loading success/failure scenarios

#### `tests/test_chat_response.py` (4 tests)
- ✅ Chat response generation
- ✅ System instruction handling
- ✅ Model error conditions

#### `tests/test_embedding.py` (5 tests)
- ✅ Text and image embedding generation
- ✅ Input validation and error handling

#### `tests/test_embedding_upload.py` (4 tests)
- ✅ File upload validation and processing
- ✅ Combined text+image embedding generation

### Adding New Tests

When adding new API endpoints or modifying existing ones:

1. Create test methods in the appropriate test class
2. Use descriptive test names: `test_endpoint_scenario`
3. Mock external dependencies (models, file operations)
4. Test both success and error conditions
5. Validate response structure and types

### Test Dependencies

Required packages for testing:
```bash
pip install pytest pytest-asyncio
```

Optional for enhanced testing:
```bash
pip install pytest-cov  # Coverage reporting
pip install pytest-mock # Enhanced mocking
```

## Run
```
export GEMINI_API_KEY="YOUR_KEY" 
uvicorn main:app --reload
```
