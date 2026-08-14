# AI Chat Module

The **AI Chat** module provides semantic search and conversational AI across all archived data (files, email, photos). It supports local LLM inference (offline-capable) and optional cloud model passthrough (Gemini, Claude, OpenAI, Grok) when the user provides their own API keys.

## Directory Structure

```
modules/aichat/
  pages/
    aichat_models_settings_page.dart  # Download/manage GGUF models
    aichat_page.dart                  # Main chat interface
    aichat_skills_settings_page.dart  # Configure built-in skills
  services/
    local_llm_content_generator.dart  # Chat completion wrapper (genui interface)
  widgets/
    aichat_drawer.dart                # Left nav (chat history, settings)
```

The heavy lifting (LLM inference, embeddings, model management) happens in the **Python service** (`/aiserver/`), not the Flutter client. The client merely sends requests over HTTP.

## Python Service (`/aiserver/`)

### Core Modules

| Module | Purpose |
|--------|---------|
| `main.py` | FastAPI app initialization, CORS, middleware |
| `routes.py` | All HTTP endpoints (chat, embeddings, models, skills) |
| `model_manager.py` | GGUF model loading, inference setup, caching |
| `model_registry.py` | Registry of available models (chat, embedding, vision) |
| `models.py` | Pydantic request/response schemas |
| `auth.py` | Bearer token validation |
| `config.py` | Configuration management (env vars, model paths) |
| `state.py` | Global service state (loaded models, cache) |
| `pst_parser.py` | Outlook PST file parsing (libpff wrapper) |
| `utils.py` | Helper functions (image processing, model download, etc.) |
| `skills.py` | Built-in skill definitions (e.g., "summarize", "translate") |

### Key Endpoints

#### Chat Completions

**`POST /v1/chat/completions`**

Streaming or non-streaming chat completion. Supports local GGUF models or cloud provider passthrough.

Request:

```json
{
  "model": "gemma-4-12B-it-Q4_0",  // Or "gpt-4", "claude-3-opus", etc.
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Find emails from Q1 2024 about project X"}
  ],
  "stream": false,
  "temperature": 0.7,
  "max_tokens": 1024,
  "top_p": 0.95,
  // Optional: cloud provider config
  "api_key": "sk-...",  // User's OpenAI/Anthropic/Google API key
  "provider": "openai"   // "openai", "anthropic", "google", "grok"
}
```

Response (non-streaming):

```json
{
  "model": "gemma-4-12B-it-Q4_0",
  "choices": [
    {
      "finish_reason": "stop",
      "message": {
        "role": "assistant",
        "content": "I found 42 emails from Q1 2024 mentioning project X..."
      }
    }
  ],
  "usage": {
    "prompt_tokens": 50,
    "completion_tokens": 150,
    "total_tokens": 200
  }
}
```

Response (streaming): Server-sent events (SSE) with token chunks:

```
data: {"choices":[{"delta":{"content":"I"}}]}
data: {"choices":[{"delta":{"content":" found"}}]}
// ...
data: {"choices":[{"delta":{"content":""}}]}
data: [DONE]
```

#### Embeddings

**`POST /util/embedding`**

Generate text or image embeddings (multimodal Qwen3-VL-Embedding-2B).

Request:

```json
{
  "input": "Find files similar to a sunset photo",
  "model": "qwen-vl-embedding-2b",
  "input_type": "text"  // Or "image" for base64-encoded image
}
```

Response:

```json
{
  "object": "list",
  "data": [
    {
      "object": "embedding",
      "index": 0,
      "embedding": [0.123, -0.456, ...]  // Dense vector, 1536 dims
    }
  ],
  "model": "qwen-vl-embedding-2b",
  "usage": {
    "prompt_tokens": 10,
    "total_tokens": 10
  }
}
```

#### Model Status & Download

**`GET /util/model-status`**

Check if a model is already downloaded on disk.

Request: `?model=gemma-4-12B-it-Q4_0`

Response:

```json
{
  "model": "gemma-4-12B-it-Q4_0",
  "status": "loaded",
  "file_size_gb": 7.2,
  "path": "/path/to/model.gguf"
}
```

**`POST /util/download-model`**

Download a GGUF model from Hugging Face or a custom URL (streaming SSE progress).

Request:

```json
{
  "model": "gemma-4-12B-it-Q4_0",
  "repo": "ggml-org/gemma-4-12B-it-GGUF"
}
```

Response (SSE):

```
data: {"status": "downloading", "progress": 0.1}
data: {"status": "downloading", "progress": 0.25}
// ...
data: {"status": "completed", "file_size_gb": 7.2}
```

#### PST Import

**`POST /util/import/pst`**

Parse an Outlook PST file and stream out email messages.

Request (multipart/form-data):

```
file: <binary pst data>
```

Response (SSE):

```
data: {"type": "message", "index": 1, "subject": "...", "from": "..."}
data: {"type": "message", "index": 2, "subject": "...", "from": "..."}
// ...
data: {"type": "completed", "total": 5000}
```

#### Thumbnail Generation

**`POST /util/thumbnail`**

Generate a thumbnail for an image (includes RAW format support via rawpy).

Request:

```json
{
  "image_path": "/path/to/image.RAW",
  "width": 256,
  "format": "jpeg"
}
```

Response:

```json
{
  "base64": "iVBORw0KGgoAAAANS...",
  "width": 256,
  "height": 192,
  "format": "jpeg"
}
```

#### Skills

**`GET /skills`**

List available built-in skills (AI assistant commands).

Response:

```json
{
  "skills": [
    {
      "name": "summarize",
      "prompt": "Summarize the following content in 3 bullet points:\n{content}"
    },
    {
      "name": "translate",
      "prompt": "Translate the following to {language}:\n{content}"
    },
    // ... more skills
  ]
}
```

## Local LLM Inference

### Model Registry

Available models are defined in `model_registry.py`:

```python
MODELS = {
  'gemma-4-12B-it-Q4_0': {
    'repo': 'ggml-org/gemma-4-12B-it-GGUF',
    'file': 'gemma-4-12B-it-Q4_0.gguf',
    'type': 'chat',
    'context_length': 8192,
    'quantization': 'Q4_0',
  },
  'qwen-vl-embedding-2b': {
    'repo': 'Qwen/Qwen3-VL-Embedding-2B',
    'type': 'embedding',
    'embedding_dim': 1536,
  },
  // ... more models
}
```

### Inference via llama-cpp-python

Chat completions use **llama-cpp-python** for local inference:

```python
# In model_manager.py
from llama_cpp import Llama

llm = Llama(
  model_path=model_path,
  n_ctx=8192,           # Context length
  n_gpu_layers=80,      # Metal GPU layers on macOS
  verbose=False,
)

# Generate completion
completion = llm.create_chat_completion(
  messages=[
    {"role": "user", "content": "..."},
  ],
  temperature=0.7,
  max_tokens=1024,
)
```

### Metal GPU Acceleration

On macOS, Metal GPU is enabled via PyInstaller build flags:

```bash
FORCE_CMAKE=1 CMAKE_ARGS="-DGGML_METAL=on -DGGML_NATIVE=off" pdm run pyinstaller -y main.spec
```

This allows the GGUF model to offload inference to the GPU, dramatically improving speed.

### Embeddings via Transformers

Embeddings use **Transformers** + **Qwen3-VL**:

```python
# In model_manager.py
from transformers import AutoModel, AutoTokenizer

model = AutoModel.from_pretrained('Qwen/Qwen3-VL-Embedding-2B')
tokenizer = AutoTokenizer.from_pretrained('Qwen/Qwen3-VL-Embedding-2B')

# For text
inputs = tokenizer(['Find files similar to a sunset photo'], return_tensors='pt')
embeddings = model(**inputs)  # Shape: (1, 1536)

# For image
from PIL import Image
img = Image.open('sunset.jpg')
inputs = tokenizer(images=[img], return_tensors='pt')
embeddings = model(**inputs)  # Shape: (1, 1536)
```

## Cloud Model Passthrough

If the user provides an API key for a cloud provider, the Python service forwards the request:

```python
# In routes.py
if provider == 'openai':
  from langchain_openai import ChatOpenAI
  llm = ChatOpenAI(api_key=api_key, model_name=model)
elif provider == 'anthropic':
  from langchain_anthropic import ChatAnthropic
  llm = ChatAnthropic(api_key=api_key, model_name=model)
# ... etc

completion = llm.invoke(messages)
```

**Important**: The user's API key is sent only to the Python service on localhost; it's never stored persistently on disk (unless the user explicitly saves it in settings).

## Context & Retrieval-Augmented Generation (RAG)

When the user asks a question, the AI Chat module can use semantic search to retrieve relevant files/emails as context:

```dart
// In local_llm_content_generator.dart

// 1. Embed user query
final queryEmbedding = await pythonService.generateEmbedding(userQuery);

// 2. Search for similar files/emails
final relevantFiles = await database.vectorSearch(
  queryEmbedding,
  table: 'files',
  limit: 5,
);

// 3. Build RAG prompt
final ragPrompt = '''
You are a helpful assistant. Use the following file summaries to answer the user's question.

Relevant Files:
${relevantFiles.map((f) => '- ${f.name}: ${f.summary}').join('\n')}

User Question: $userQuery
''';

// 4. Send to LLM
final response = await pythonService.chat(
  messages: [{'role': 'user', 'content': ragPrompt}],
);
```

This enables queries like "Find all emails from Q1 2024 about project X" — the LLM understands the intent, semantic search retrieves relevant messages, and the LLM synthesizes the answer.

## Skills & Commands

Built-in skills are prompt templates that the user can invoke via the `/skill_name <text>` syntax:

```
/summarize This is a long document with lots of content...
→ Invokes the "summarize" skill, which expands to:
  "Summarize the following content in 3 bullet points:\n<text>"

/translate --language Spanish This is English text...
→ Invokes the "translate" skill with parameter: language=Spanish
```

Skills are defined in `skills.py` and listed via `/skills` endpoint.

## Flutter Client Integration

### LocalLlmContentGenerator

`local_llm_content_generator.dart` wraps the Python endpoints and exposes them via the `genui` package's `ContentGenerator` interface:

```dart
class LocalLlmContentGenerator implements ContentGenerator {
  final String llmServiceUrl;
  final String bearerToken;
  
  @override
  Stream<String> generate(
    String prompt, {
    required String model,
    double temperature = 0.7,
    int maxTokens = 1024,
  }) async* {
    final response = await http.post(
      Uri.parse('$llmServiceUrl/v1/chat/completions'),
      headers: {'Authorization': 'Bearer $bearerToken'},
      body: jsonEncode({
        'model': model,
        'messages': [{'role': 'user', 'content': prompt}],
        'stream': true,
        'temperature': temperature,
        'max_tokens': maxTokens,
      }),
    );
    
    // Stream SSE chunks back to the caller
    await for (final chunk in response.stream.transform(...)) {
      yield chunk;
    }
  }
  
  @override
  Future<List<double>> embed(String text) async {
    final response = await http.post(
      Uri.parse('$llmServiceUrl/util/embedding'),
      headers: {'Authorization': 'Bearer $bearerToken'},
      body: jsonEncode({'input': text, 'model': 'qwen-vl-embedding-2b'}),
    );
    return jsonDecode(response.body)['data'][0]['embedding'];
  }
}
```

### Chat Page

`aichat_page.dart` displays:

- **Chat history**: Messages from current conversation
- **Input field**: User's question/prompt
- **Model selector**: Choose local or cloud provider
- **Settings**: Temperature, max tokens, API key management

### Model Settings

`aichat_models_settings_page.dart` allows:

- **View available models**: Chat, embedding, vision
- **Download models**: Stream GGUF from Hugging Face
- **Delete models**: Free up disk space
- **Model status**: Show which models are loaded/cached

## Performance Considerations

- **Model loading**: First inference with a model takes 5–10s (CPU overhead); subsequent calls are fast
- **Context length**: Default 8192 tokens (Gemma-4); can be reduced to save memory
- **Batch processing**: Embed 100 files at once (more efficient than one-by-one)
- **Caching**: Embedding vectors are cached in SQLite; don't re-embed same content

## Limitations & Privacy

- **Local inference**: Requires 8–16 GB RAM + 10–15 GB disk (for GGUF models)
- **Cloud providers**: User's API key is sent to that provider (not stored locally)
- **No persistent API keys**: Keys are stored in the secure vault only during the session
- **Rate limits**: Cloud provider rate limits apply (user's quota)

## Next Steps

- **[Files & Photos](./files-and-photos.md)** — File search context
- **[Email](./email.md)** — Email search context
- **[Building & Operations](../operations/building.md)** — Model download, PyInstaller config

## Source References

- **Flutter Client**: `/client/lib/modules/aichat/`, `/client/lib/services/local_llm_content_generator.dart`
- **Python Service**: `/aiserver/src/aichat/routes.py`, `/aiserver/src/aichat/model_manager.py`
- **Model Registry**: `/aiserver/src/aichat/model_registry.py`
- **Tests**: `/aiserver/tests/test_routes.py`, `/client/test/modules/aichat/`
