import asyncio
from src.aichat.model_manager import load_embedding_model, generate_embedding
model_id = "google/siglip2-so400m-patch16-naflex"
print("Loading model...")
model, processor = load_embedding_model(model_id, "", model_id)
print("Generating text embedding...")
emb = generate_embedding(model, processor, text="hello world")
print("Text Embedding size:", len(emb))
