---
name: skill-creator
description: >-
  Guide for creating, testing, reviewing, and validating AI agent
  skills. Use when building new skills, updating existing skills, writing
  TEST.md test plans, reviewing skill CLs, or running skill test suites.
---

# Skill Creator

This skill provides guidance for the full lifecycle of agent skills: creation,
testing, review, and validation.

## About Skills

Skills are **cheatsheets, not documentation.** They're the gotchas, quick
recipes, and procedural knowledge that an experienced engineer would pass on to
a teammate — the things no model can reliably know from training data alone.
They are not manuals, tutorials, or comprehensive references.

A good skill reads like a senior engineer's notes: terse, opinionated, full of
"do this, not that" and "watch out for X." If you find yourself writing
paragraphs of explanation, you're writing docs, not a skill.

### What Skills Provide

1.  **Quick recipes** - Exact commands and patterns for common tasks
2.  **Gotchas and pitfalls** - What the agent will get wrong without help
3.  **Domain-specific knowledge** - Schemas, business logic, internal
    conventions
4.  **Bundled scripts** - Short, deterministic scripts for fragile/repetitive
    operations

Skills shouldn't contain abstractions like libraries, CLIs, etc. (long-lived
code.) If code is needed, an agent should always bias towards reusing existing
interfaces, but if it needs to build its own tooling, it should do that under
learning/gemini/agents/clis/.

### When to Create a Skill (and When Not To)

**Create a skill when:**

-   The agent cannot reliably do the job without it, even with good prompts
-   The workflow is real, recurring, and stable (not hypothetical or volatile)
-   The procedure has branching logic, scripts, or domain-specific knowledge
-   Consistency matters — getting it wrong has real consequences

**Don't create a skill when:**

-   It's a one-off task (inline instructions in the conversation are fine)
-   The agent already handles it reliably without help
-   The procedure changes frequently (skills work best when workflows stabilize)

**Prefer skills over MCP integrations.** Skills encode procedures and knowledge;
MCPs provide live data access. In most cases, an agent can wrap an MCP's
capabilities into a skill with better results — the skill tells the agent *how*
to use the MCP effectively, when to call it, and what pitfalls to avoid.

## Core Principles

### Concise is Key

The context window is shared with the system prompt, conversation history, other
skills, and user requests.

**Default assumption: The agent is already very smart.** Only add context it
doesn't already have. Challenge each piece: "Does the agent really need this?"
and "Does this justify its token cost?"

Prefer concise examples over verbose explanations.

### Verify, Don't Trust

Every instruction in a skill should be verifiable. If the agent can't test
whether it followed the instruction correctly, the instruction is too vague.
Include runnable validation commands, expected outputs, or concrete success
criteria.

### Ruthlessly Prune

If the agent already does something correctly without the instruction, delete
it. Over-specified skills cause the agent to ignore important rules because
they're buried in noise.

### Set Appropriate Degrees of Freedom

Match specificity to the task's fragility and variability:

| Freedom Level | Use When                   | Implementation              |
| ------------- | -------------------------- | --------------------------- |
| **High**      | Multiple approaches valid, | Text-based instructions     |
:               : context-dependent          :                             :
| **Medium**    | Preferred pattern exists,  | Pseudocode or parameterized |
:               : some variation OK          : scripts                     :
| **Low**       | Fragile operations,        | Specific scripts, few       |
:               : consistency critical       : parameters                  :

Analogy: A narrow bridge with cliffs → low freedom (exact script). An open field
→ high freedom (general direction).

### Avoid Offering Too Many Options

Provide **one default** with an escape hatch, not a menu of alternatives:

-   ✅ "Use pdfplumber for text extraction. For scanned PDFs requiring OCR, use
    pdf2image with pytesseract instead."
-   ❌ "You can use pypdf, or pdfplumber, or PyMuPDF, or pdf2image, or..."

### Use Consistent Terminology

Pick one term and use it throughout the skill. Don't mix "API endpoint" / "URL"
/ "API route" / "path" for the same concept. Consistency helps the agent follow
instructions.

### Avoid Time-Sensitive Information

Don't include information that will become outdated. If you must reference
deprecated patterns, put them in a separate "Legacy patterns" section, not
inline with current instructions.

## Skill Structure

### Anatomy

Every skill has a required SKILL.md and optional bundled resources:

```
skill_name/
├── SKILL.md              # Required: metadata + instructions
├── scripts/              # Executable code (Python/Bash)
├── references/           # Supplementary context loaded as needed
└── assets/               # Files used in output (templates, images)
```

### SKILL.md Structure

-   **Frontmatter** (YAML): Contains `name` and `description` (required). Only
    these are read to determine when the skill triggers.
-   **Body** (Markdown): Instructions loaded AFTER the skill triggers. Keep
    under **500 lines**. Use references/ for anything beyond that.

### Resource Types

| Type            | Purpose                    | Examples                 |
| --------------- | -------------------------- | ------------------------ |
| **scripts/**    | Executable code for        | `rotate_pdf.py`,         |
:                 : deterministic/repeated     : `validate_schema.py`     :
:                 : fragile operations where   :                          :
:                 : variation is a bug         :                          :
| **references/** | Supplementary context      | `api_cheatsheet.md`,     |
:                 : loaded as needed (schemas, : `database_schema.md`     :
:                 : cheatsheets, gotchas)      :                          :
| **assets/**     | Files used in output, not  | templates, images, fonts |
:                 : loaded into context        :                          :

### When Needing Scripts

Google3 is a monorepo environment, so scripts need BUILD files to be executable.
See [references/monorepo-patterns.md](references/monorepo-patterns.md) for BUILD
file patterns for script targets.

**Design scripts like tiny CLIs:**

-   Run from the command line with deterministic stdout
-   Fail loudly with clear error messages (don't silently return empty results)
-   Handle error conditions explicitly — don't punt to the agent
-   Write outputs to known file paths when needed
-   Document magic numbers (no "mysterious constants")

### Progressive Disclosure

Skills use a three-level loading system:

1.  **Metadata** (name + description) - Always in context (~100 words)
2.  **SKILL.md body** - When skill triggers (<500 lines)
3.  **Bundled resources** - As needed (unlimited, scripts execute without
    reading)

Prefer to keep SKILL.md body short, creating references/ when suitable.

**Pattern: High-level guide with references**

```markdown

## Advanced features

-   **Form filling**: See [FORMS.md](references/forms.md)
-   **API reference**: See [REFERENCE.md](references/api_reference.md)
```

**Pattern: Domain-specific organization**

```markdown
bigquery-skill/
├── SKILL.md (overview and navigation)
└── references/
    ├── finance.md
    ├── sales.md
    └── product.md
```

**Keep references one level deep.** All reference files should link directly
from SKILL.md, never from another reference file. Agents may only partially read
nested references, resulting in incomplete information.

**Add a table of contents to reference files over 100 lines.** This ensures the
agent can see the full scope even when previewing.

## Writing an Effective Name & Description

The `name` and `description` in the YAML frontmatter are the **only** thing the
agent sees before deciding whether to trigger a skill. A weak description means
the skill never fires, no matter how good the body is.

**This is the hardest part to get right.** Trigger reliability is the single
biggest failure mode for skills — agents frequently fail to invoke skills they
have access to. Description quality directly determines trigger rates.

### Name Rules

-   **Directory Name**: Must be `snake_case` (e.g., `pdf_processing`). This is
    enforced by the initialization script to match Blaze package rules.
-   **Skill Name**: Must be `kebab-case` (e.g., `pdf-processing`). This is
    enforced by the initialization script for the `name` field in `SKILL.md`.
-   Prefer **gerund form** (verb + -ing): `processing-pdfs`,
    `analyzing-spreadsheets`, `managing-databases`
-   Acceptable alternatives: `pdf-processing`, `process-pdfs`
-   Avoid: `helper`, `utils`, `tools`, `data` (too vague)

### Description Rules

1.  **Start with a third-person capability statement.** "Processes Excel files
    and generates reports" — not "I can help you" or "You can use this to". The
    description is injected into the system prompt; first/second person causes
    discovery problems.
2.  **Describe the user's problem, not the tool.** The agent matches skills to
    user requests. Describe what a user would be trying to do.
3.  **Use terms the LLM knows.** Internal tool names (Dapper, Stubby, Borgmon)
    mean nothing to the model. Compare with well-known external equivalents or
    describe the concept generically so the model can match.
4.  **List concrete triggers.** After the capability statement, add "Use
    when..." followed by specific scenarios the skill handles.
5.  **Include negative examples.** Add "Don't use when..." for common
    false-trigger scenarios. This improves routing accuracy.
6.  **Keep under 1024 characters.** This is a hard limit.

### Examples

**Bad** — internal jargon, no external anchoring:

```yaml
description: >-
    Interact with Dapper to view distributed traces.
```

The agent doesn't know what Dapper is. A user asking "help me debug a slow RPC"
won't trigger this skill.

**Good** — describes the concept, anchors externally, lists triggers:

```yaml
description: >-
    Search and analyze distributed traces for debugging RPC latency, errors,
    and service dependencies. Similar to Jaeger or Zipkin tracing. Use when
    debugging slow requests, viewing trace spans, finding error sources across
    microservices, or analyzing service-to-service call patterns. Don't use
    for log analysis or metrics dashboards.
```

**Bad** — too vague:

```yaml
description: >-
    A skill for working with bugs.
```

**Good** — specific about what, when, and when not:

```yaml
description: >-
    Search, create, and manage bugs in the issue tracker (similar to Jira
    or GitHub Issues). Use when listing assigned bugs, creating new bugs,
    updating priority or status, adding comments, or searching bugs by
    component, assignee, or priority. Don't use for incident management
    or outage tracking.
```

## Skill Creation Process

1.  **Understand** the skill with concrete examples
2.  **Plan** reusable resources (scripts, references, assets)
3.  **Initialize** the skill (run `init_skill.py`)
4.  **Implement** resources and write SKILL.md
5.  **Validate** the skill structure
6.  **Create EVAL.yaml** for automated evaluation
7.  **Test, review, and submit**

### Step 1: Understanding with Examples

Ask clarifying questions to understand concrete use cases:

-   "What functionality should the skill support?"
-   "Can you give examples of how this skill would be used?"
-   "What would a user say that should trigger this skill?"

Conclude when you have a clear sense of the required functionality.

### Step 2: Planning Resources

For each concrete example, analyze:

1.  What code/knowledge is needed to execute it?
2.  What would be helpful to have pre-written for repeated execution?

| Example Trigger        | Analysis                 | Resource                |
| ---------------------- | ------------------------ | ----------------------- |
| "Rotate this PDF"      | Same code rewritten each | `scripts/rotate_pdf.py` |
:                        : time                     :                         :
| "Build me a todo app"  | Same boilerplate needed  | `assets/hello-world/`   |
:                        :                          : template                :
| "How many users logged | Needs schema knowledge   | `references/schema.md`  |
: in?"                   :                          :                         :

### Step 3: Initializing the Skill

Run the init script to create a template skill directory:

```bash
blaze run //<path>/scripts:init_skill -- --name=<skill-name> --path=<output-directory>
```

The script creates SKILL.md with proper structure and example resource
directories.

### Step 4: Implementing the Skill

#### Design Patterns

-   **Multi-step processes**: See
    [references/workflows.md](references/workflows.md)
-   **Monorepo patterns (BUILD files, testing)**: See
    [references/monorepo-patterns.md](references/monorepo-patterns.md)

#### Start with Resources

Begin with scripts, references, and assets identified in planning. This may
require user input (e.g., brand assets, documentation).

**Test scripts by running them** to ensure no bugs and correct output.

Delete any unneeded example files from initialization.

#### Write SKILL.md

**Frontmatter:** Follow the guidance in "Writing an Effective Name &
Description" above. The description is the most important part of the entire
skill — it determines whether the skill ever triggers.

**Body:** Write clear instructions using imperative form. Think cheatsheet, not
manual. Include concrete input→command→output examples for each capability.

*   **Placeholders:** Use curly braces for placeholder values that should be
    replaced, e.g., `{module_name}` or `{command_name}`. Placeholder names
    should use `snake_case` to match common conventions (e.g., `{file_path}`,
    `{output_dir}`).
*   **Code Blocks:** Ensure all code blocks have language specifiers (e.g.,
    `bash`, `markdown`, `yaml`).

For complex multi-step workflows, include a copy-paste checklist that the agent
can track progress against:

```markdown
Copy this checklist and track progress:
- [ ] Step 1: Analyze the input
- [ ] Step 2: Validate the data
- [ ] Step 3: Process and transform
- [ ] Step 4: Verify output
```

For quality-critical tasks, implement **feedback loops** (validate→fix→repeat):

```markdown
1. Run: `python scripts/validate.py output/`
2. If validation fails:
   - Review the error message
   - Fix the issues
   - Run validation again
3. Only proceed when validation passes
```

### Step 5: Validating the Skill

Run structural validation:

```bash
blaze run //<path>/scripts:validate_skill -- --skill_dir=<path/to/skill-folder>
```

### Step 6: Create EVAL.yaml

Every new skill MUST include an `EVAL.yaml` for automated evaluation. Use the
eval-task-creator skill to generate it — it provides the full schema,
quality rules, and workflow for writing effective eval cases.

At minimum, create 3-5 cases covering at least two categories (knowledge,
procedural, troubleshooting). Place the file at `skill_name/EVAL.yaml`.

### Step 7: Test, Review, and Submit

1.  **Test with real prompts**: Use natural user language, not tool-directed
    prompts. Test multiple capabilities in separate conversations.
2.  **Write a TEST.md**: Create a TEST.md in the same directory as your
    SKILL.md. See [references/testing.md](references/testing.md) for the full
    guide on writing effective test plans.
3.  **Self-review**: Review your skill against the quality checklist before
    sending the CL. See [references/reviewing.md](references/reviewing.md) for
    the full review process and criteria.
4.  **Run the test plan**: Execute your TEST.md to verify everything works. See
    [references/running-tests.md](references/running-tests.md) for the testing
    workflow.
5.  **Add an OWNERS file**: You own skills you contribute.
6.  **CL description must include a Deliverables section** with:

    -   A gpaste link with the prompt used to create the skill
    -   Trajectory links for each capability tested

    Use this template at the top of the CL description:

    ```
    ## Deliverables

    ### Skill creation prompt
    <gpaste link>

    ### Trajectories using skill:
    - <describe what you tested>: go/traj/?trajectory_id=<id>
    - <describe what you tested>: go/traj/?trajectory_id=<id>

    ## Description
    <rest of CL description>

    MARKDOWN=true
    ```

### Step 8: Create a Bug Tracking Hotlist

Create a Buganizer hotlist for your new skill so users and agents can report
issues. Follow the `skill_issue` skill for the full workflow:

```bash
bugged create-hotlist "Agent Skill: <skill_name>"
```

Then set the description with owners and record the hotlist ID in the mapping
file. See the `skill_issue` skill for detailed instructions.

## What NOT to Include

Skills should only contain essential files. Do NOT create:

-   README.md, INSTALLATION_GUIDE.md, QUICK_REFERENCE.md
-   CHANGELOG.md or user-facing documentation
-   Setup/testing procedures beyond skill content
-   **Library code or CLIs** — these belong in `learning/gemini/agents/clis/`,
    or in their respective code areas, not in skills. Skills should reference
    tools, not bundle them.

## Reporting Issues

Report bugs or improvements for this skill at [Agent Skill: skill_creator](http://b/hotlists/8079054).
See the `skill_issue` skill for instructions on filing and triaging skill bugs.

## Agentic Constraints (Skill Authoring)

<constraints> - **No Block Scalars**: NEVER use `>` in the description field of
the frontmatter. - **Single Question Policy**: During interactive steps, prompt
for only one piece of information at a time. - **Precision**: Avoid
"vibe-coding" or generic advice; always encode specific, tool-driven
workflows. - **Avoid Duplication**: Information should live in either SKILL.md
or reference files, not both. </constraints>