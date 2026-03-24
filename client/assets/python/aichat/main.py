import sys
import os

# PyInstaller Workaround: Inject dynamic imports before they are needed
# In frozen processes, __spec__.parent is missing causing __getattr__ to fail.
# By explicitly importing and adding these to the module's globals, we bypass __getattr__.
try:
    import langchain_core.language_models
    import langchain_core.language_models.base
    import langchain_core.language_models.chat_models
    
    langchain_core.language_models.LangSmithParams = langchain_core.language_models.base.LangSmithParams
    langchain_core.language_models.LanguageModelInput = langchain_core.language_models.base.LanguageModelInput
    langchain_core.language_models.LanguageModelOutput = langchain_core.language_models.base.LanguageModelOutput
    langchain_core.language_models.LanguageModelLike = langchain_core.language_models.base.LanguageModelLike
    langchain_core.language_models.BaseChatModel = langchain_core.language_models.chat_models.BaseChatModel
    langchain_core.language_models.SimpleChatModel = langchain_core.language_models.chat_models.SimpleChatModel
    langchain_core.language_models.BaseLanguageModel = langchain_core.language_models.base.BaseLanguageModel
    langchain_core.language_models.get_tokenizer = langchain_core.language_models.base.get_tokenizer
except Exception as e:
    print(f"Warning: Failed to inject langchain_core.language_models dependencies: {e}")

# Add the src directory to the python path so we can import the aichat package
sys.path.append(os.path.join(os.path.dirname(__file__), "src"))

from aichat.main import main

if __name__ == "__main__":
    import multiprocessing
    multiprocessing.freeze_support()
    
    if len(sys.argv) > 1 and sys.argv[1] == "--pst":
        # Remove the --pst flag from sys.argv so pst_parser's argparse works correctly
        sys.argv.pop(1)
        from aichat.pst_parser import main as pst_main
        pst_main()
    else:
        main()