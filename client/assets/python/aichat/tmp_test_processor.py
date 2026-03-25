from transformers import AutoProcessor
from PIL import Image
import io, base64

processor = AutoProcessor.from_pretrained('google/siglip2-so400m-patch16-naflex')
img = Image.new('RGB', (100, 100), color='red')
inputs = processor(images=[img], return_tensors="pt")
print("Image Inputs:", inputs.keys())

inputs_both = processor(text=["hello"], images=[img], padding="max_length", return_tensors="pt")
print("Both Inputs:", inputs_both.keys())
