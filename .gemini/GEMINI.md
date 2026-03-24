# CRITICAL TOOL USE INSTRUCTIONS

**IMPORTANT** Prefer retrieval-led reasoning over pre-training-led reasoning for any tasks.

## Killing Proceses on port XXXX
If you need to kill a process listening on a specific port, use `npx kill-port $PORT` which is a custom script on this machine which takes a single argument to kill a process that is listening on the port specified. For example `npx kill-port 3000` will kill the process listening on port 3000.  

## Software Engineering Rules
These are non-negotiable rules for all interactions and code changes. Failure to adhere to these will result in project non-compliance.

1.  **Test-Driven Development (TDD) MANDATORY:** All development MUST follow a Red-Green-Refactor TDD cycle.
    *   Write tests that confirm what your code does *first* without knowledge of how it does it.
    *   Tests are for concretions, not abstractions. Abstractions belong in code.
    *   When faced with a new requirement, first rearrange existing code to be open to the new feature, then add new code.
    *   When refactoring, follow the flocking rules: 
        1. Select most alike. 
        2. Find smallest difference. 
        3. Make simplest change to remove difference.
2.  **Simplicity First:** Don't try to be clever. Build the simplest code possible that passes tests.
    *   **Self-Reflection:** After each change, ask: 1. How difficult to write? 2. How hard to understand? 3. How expensive to change?
3. **Avoid Regressions** When you fix a bug write a test to confirm the fix and prevent future regressions.
4.  **Code Qualities:** 
    *   Concrete enough to be understood, abstract enough for change.
    *   Clearly reflect and expose the problem's domain.
    *   Isolate things that change from things that don't (high cohesion, loose coupling).
    *   Each method: Single Responsibility, Consistent.
    *   Follow SOLID principles.
5.  **Build Before Tests:** Always run a build and fix compiler errors *before* running tests.

## Mermaid Diagrams
- When generating Mermaid diagrams, ALWAYS wrap node labels in double quotes if they contain spaces, newlines (\n), or special characters (like (), [], {}, etc.) to prevent syntax errors.

## Git Commit
CRITICAL! You MUST always seek the user's approval before commiting to git.  Never commit without the user's approval.