"""
GenUI schema definitions and helper functions for generating A2UI messages.

This module provides utilities for creating GenUI (Generative UI) formatted
responses that can be rendered as dynamic UI components in the Flutter client.
"""
import uuid
from typing import Dict, Any, Optional, List


def create_surface_id() -> str:
    """Generate a unique surface ID for GenUI rendering."""
    return f"surface-{uuid.uuid4()}"


def create_text_component(text: str, hint: str = "body") -> Dict[str, Any]:
    """
    Create a GenUI Text component.
    
    Args:
        text: The text content to display
        hint: Text style hint (h1, h2, h3, body, caption)
        
    Returns:
        GenUI Text component definition
    """
    return {
        "Text": {
            "text": {"literalString": text},
            "hint": hint
        }
    }


def create_markdown_component(markdown: str) -> Dict[str, Any]:
    """
    Create a GenUI Markdown component.
    
    Args:
        markdown: Markdown formatted text
        
    Returns:
        GenUI Markdown component definition
    """
    return {
        "Markdown": {
            "data": {"literalString": markdown}
        }
    }


def create_image_component(url: str, alt_text: Optional[str] = None) -> Dict[str, Any]:
    """
    Create a GenUI Image component.
    
    Args:
        url: Image URL
        alt_text: Alternative text for the image
        
    Returns:
        GenUI Image component definition
    """
    component = {
        "Image": {
            "src": {"literalString": url}
        }
    }
    if alt_text:
        component["Image"]["semanticLabel"] = {"literalString": alt_text}
    return component


def create_begin_rendering_message(surface_id: str, root_component_id: str = "root") -> Dict[str, Any]:
    """
    Create a BeginRendering A2UI message to initialize a surface.
    
    Args:
        surface_id: Unique identifier for the surface
        root_component_id: ID of the root component (default: "root")
        
    Returns:
        BeginRendering message dictionary
    """
    return {
        "beginRendering": {
            "surfaceId": surface_id,
            "root": root_component_id
        }
    }


def create_surface_update_message(
    surface_id: str,
    components: List[Dict[str, Any]]
) -> Dict[str, Any]:
    """
    Create a SurfaceUpdate A2UI message with components.
    
    Args:
        surface_id: The surface ID to update
        components: List of component definitions, each with 'id' and 'component' keys
        
    Returns:
        SurfaceUpdate message dictionary
        
    Example component format:
        {
            "id": "root",
            "component": {
                "Text": {
                    "text": {"literalString": "Hello"},
                    "hint": "body"
                }
            }
        }
    """
    return {
        "surfaceUpdate": {
            "surfaceId": surface_id,
            "components": components
        }
    }


def create_genui_messages_for_text(
    text: str,
    surface_id: Optional[str] = None,
    use_markdown: bool = False
) -> List[Dict[str, Any]]:
    """
    Create both BeginRendering and SurfaceUpdate messages for a text response.
    
    Args:
        text: The response text
        surface_id: Optional surface ID (generated if not provided)
        use_markdown: If True, render as Markdown instead of plain Text
        
    Returns:
        List containing [BeginRendering message, SurfaceUpdate message]
    """
    if surface_id is None:
        surface_id = create_surface_id()
    
    # Choose component type
    if use_markdown:
        component_def = create_markdown_component(text)
    else:
        component_def = create_text_component(text)
    
    # Create the component with ID and wrapper
    component = {
        "id": "root",
        "component": component_def
    }
    
    # Return both messages
    return [
        create_begin_rendering_message(surface_id, "root"),
        create_surface_update_message(surface_id, [component])
    ]


def create_multi_component_response(
    components: List[Dict[str, Any]],
    surface_id: Optional[str] = None
) -> Dict[str, Any]:
    """
    Create a GenUI response with multiple components in a column layout.
    
    Args:
        components: List of GenUI component definitions
        surface_id: Optional surface ID (generated if not provided)
        
    Returns:
        Complete A2UI message dictionary with Column layout
    """
    if surface_id is None:
        surface_id = create_surface_id()
    
    # Create component IDs for each child
    component_dict = {"root": {
        "Column": {
            "children": []
        }
    }}
    
    for i, comp in enumerate(components):
        comp_id = f"comp-{i}"
        component_dict["root"]["Column"]["children"].append({"literalString": comp_id})
        component_dict[comp_id] = comp
    
    return {
        "beginRendering": {
            "surfaceId": surface_id,
            "root": "root",
            "components": component_dict
        }
    }


# GenUI system prompt to instruct the LLM on how to use GenUI format
GENUI_SYSTEM_PROMPT = """
You are a helpful AI assistant. Respond naturally to user questions.
""".strip()
