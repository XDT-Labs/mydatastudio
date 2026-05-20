"""
Global state management for the application.

This module manages the global state of loaded models and provides thread-safe
access to model instances, IDs, and synchronization locks. It ensures that
model loading operations are coordinated across concurrent requests.
"""
import asyncio
from typing import Optional, Any, Tuple, Dict, List

from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_community.llms import LlamaCpp

# Global variables to store the currently active model instance and status
llm_instance: Optional[LlamaCpp | ChatGoogleGenerativeAI] = None
current_model_id: Optional[str] = None

# Global variables for embedding model (separate from chat model)
embedding_model: Optional[Any] = None
embedding_processor: Optional[Any] = None
embedding_model_id: Optional[str] = None

# Lock to prevent multiple concurrent attempts to load a model
model_lock = asyncio.Lock()
embedding_lock = asyncio.Lock()


def get_llm_instance() -> Optional[LlamaCpp | ChatGoogleGenerativeAI]:
    """
    Get the currently loaded LLM instance for chat operations.
    
    Returns:
        Optional[LlamaCpp | ChatGoogleGenerativeAI]: The current LLM instance, or None if no model is loaded
        
    Example:
        >>> response = llm.invoke("Hello, world!")
    """
    return llm_instance


def set_llm_instance(instance: Optional[LlamaCpp | ChatGoogleGenerativeAI]) -> None:
    """
    Set the current LLM instance for chat operations.
    
    Args:
        instance (Optional[LlamaCpp | ChatGoogleGenerativeAI]): The LLM instance to store, or None to clear
        
    Example:
        >>> from langchain_community.llms import LlamaCpp
        >>> pipeline = LlamaCpp(...)
        >>> set_llm_instance(pipeline)
    """
    global llm_instance
    llm_instance = instance


def get_current_model_id() -> Optional[str]:
    """
    Get the identifier of the currently loaded chat model.
    
    Returns:
        Optional[str]: The model ID (e.g., 'google/gemma-3-4b-it'), or None if no model is loaded
        
    Example:
        >>> model_id = get_current_model_id()
        >>> print(f"Current model: {model_id}")
    """
    return current_model_id


def set_current_model_id(model_id: Optional[str]) -> None:
    """
    Set the identifier of the currently loaded chat model.
    
    Args:
        model_id (Optional[str]): The model identifier, or None to clear
        
    Example:
        >>> set_current_model_id("google/gemma-3-4b-it")
    """
    global current_model_id
    current_model_id = model_id


def get_embedding_model() -> Tuple[Optional[Any], Optional[Any]]:
    """
    Get the current embedding model and its processor.
    
    Returns:
        Tuple[Optional[Any], Optional[Any]]: A tuple of (model, processor), 
        or (None, None) if no embedding model is loaded
        
    Example:
        >>> model, processor = get_embedding_model()
        >>> if model and processor:
        ...     embeddings = generate_embedding(text, model, processor)
    """
    return embedding_model, embedding_processor


def set_embedding_model(model: Optional[Any], processor: Optional[Any]) -> None:
    """
    Set the current embedding model and processor.
    
    Args:
        model (Optional[Any]): The embedding model instance, or None to clear
        processor (Optional[Any]): The model processor instance, or None to clear
        
    Example:
        >>> from transformers import AutoModel, AutoProcessor
        >>> model = AutoModel.from_pretrained("model_path")
        >>> processor = AutoProcessor.from_pretrained("model_path")
        >>> set_embedding_model(model, processor)
    """
    global embedding_model, embedding_processor
    embedding_model = model
    embedding_processor = processor


def get_embedding_model_id() -> Optional[str]:
    """
    Get the identifier of the currently loaded embedding model.
    
    Returns:
        Optional[str]: The embedding model ID, or None if no embedding model is loaded
        
    Example:
        >>> embedding_model_id = get_embedding_model_id()
        >>> print(f"Embedding model: {embedding_model_id}")
    """
    return embedding_model_id


def set_embedding_model_id(model_id: Optional[str]) -> None:
    """
    Set the identifier of the currently loaded embedding model.
    
    Args:
        model_id (Optional[str]): The embedding model identifier, or None to clear
        
    Example:
        >>> set_embedding_model_id("google/gemma-3-4b-it")
    """
    global embedding_model_id
    embedding_model_id = model_id


def get_locks() -> Tuple[asyncio.Lock, asyncio.Lock]:
    """
    Get the async locks used for coordinating model loading operations.
    
    Returns:
        Tuple[asyncio.Lock, asyncio.Lock]: A tuple of (model_lock, embedding_lock)
        
    Note:
        These locks should be used to prevent concurrent model loading operations
        that could cause memory issues or inconsistent state.
        
    Example:
        >>> model_lock, embedding_lock = get_locks()
        >>> async with model_lock:
        ...     # Perform model loading operation
        ...     pass
    """
    return model_lock, embedding_lock


class ConversationManager:
    """
    Manages conversation history for multiple sessions in memory.
    """
    def __init__(self):
        self._histories: Dict[str, List[str]] = {}
        self._lock = asyncio.Lock()

    async def get_history(self, session_id: str) -> List[str]:
        """Retrieve the conversation history for a session."""
        async with self._lock:
            return self._histories.get(session_id, [])

    async def add_turn(self, session_id: str, user_prompt: str, model_response: str):
        """Add a turn (user prompt + model response) to the session history."""
        async with self._lock:
            if session_id not in self._histories:
                self._histories[session_id] = []
            
            # Store formatted turn
            # Note: We store the raw text, formatting happens in routes.py or here if preferred.
            # Storing pre-formatted turns makes reconstruction easier.
            turn = f"<start_of_turn>user\n{user_prompt}<end_of_turn>\n<start_of_turn>model\n{model_response}<end_of_turn>\n"
            self._histories[session_id].append(turn)

    async def clear_history(self, session_id: str):
        """Clear history for a session."""
        async with self._lock:
            if session_id in self._histories:
                del self._histories[session_id]

# Global conversation manager instance
conversation_manager = ConversationManager()