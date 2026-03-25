from transformers import AutoProcessor
processor = AutoProcessor.from_pretrained('google/siglip2-so400m-patch16-naflex')
inputs = processor(text="hello", padding="max_length", return_tensors="pt")
print(inputs.keys())
