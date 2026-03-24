import asyncio
import base64
from PIL import Image
import io
from src.aichat.model_manager import load_embedding_model, generate_embedding

# create a dummy image
img = Image.new('RGB', (100, 100), color = 'red')
buffered = io.BytesIO()
img.save(buffered, format="JPEG")
img_str = base64.b64encode(buffered.getvalue()).decode()

model_id = "google/siglip2-so400m-patch16-naflex"
print("Loading model...")
model, processor = load_embedding_model(model_id, "", model_id)
print("Generating image embedding...")
emb = generate_embedding(model, processor, text=None, image_base64=f"data:image/jpeg;base64,{img_str}")
print("Image Embedding size:", len(emb))
