import os
import sys

# Add the src directory to sys.path
sys.path.append(os.path.join(os.getcwd(), "src"))

from aichat.model_manager import load_embedding_model
from aichat.config import MODELS_BASE_DIR
from llama_cpp import Llama, llama_cpp
import ctypes

def test_vision_loading():
    model_id = "mradermacher/gme-Qwen2-VL-2B-Instruct-GGUF"
    filename = "gme-Qwen2-VL-2B-Instruct.Q4_K_M.gguf"
    
    print(f"Testing vision loading for {filename} in {MODELS_BASE_DIR}...")
    
    try:
        # 1. Get clip_path
        llm_data = load_embedding_model(model_id, filename, MODELS_BASE_DIR)
        llm, clip_path = (llm_data if isinstance(llm_data, tuple) else (llm_data, None))
        
        if not clip_path:
            print("❌ Vision encoder path is None.")
            return

        print(f"\n--- Testing Low-Level clip_model_load ---")
        print(f"Loading clip model from {clip_path}...")
        
        # In llama-cpp-python, we can try to call the C function direct
        try:
            # llama_cpp.clip_model_load returns a pointer (void*)
            # Note: The actual path might need to be bytes
            clip_ptr = llama_cpp.clip_model_load(clip_path.encode('utf-8'), 0)
            if clip_ptr:
                print("✅ Low-level clip_model_load SUCCESS.")
                llama_cpp.clip_model_free(clip_ptr)
            else:
                print("❌ Low-level clip_model_load returned NULL.")
        except Exception as low_e:
            print(f"❌ Low-level call failed: {low_e}")

    except Exception as e:
        print(f"❌ Error during loading: {e}")

if __name__ == "__main__":
    test_vision_loading()
