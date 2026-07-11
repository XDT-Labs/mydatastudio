Perform a comprehensive audit of the application, covering security, reliability, concurrency, accessibility, and UI consistency.



Review the relevant codebase, architecture, data flows, API interactions, authentication and authorization logic, state management, async operations, error handling, and user-facing interfaces. Trace important flows end-to-end rather than reviewing files in isolation.



# Specifically investigate:



## Security vulnerabilities and data exposure

- Authentication and authorization flaws, including missing server-side permission checks, privilege escalation, insecure direct object references, and cross-tenant data access.



- Sensitive information exposed through client-side code, environment variables, API responses, logs, analytics, URLs, local storage, session storage, cookies, error messages, or source maps.



- Injection risks, including SQL, command, template, prompt, HTML, and script injection where applicable.

XSS, CSRF, SSRF, insecure redirects, unsafe file uploads, path traversal, weak session handling, insecure token storage, and missing security boundaries.



- Overly permissive database rules, API endpoints, CORS policies, storage buckets, webhook handlers, or third-party integrations.



- Secrets, API keys, credentials, internal endpoints, personal data, or implementation details that could be unintentionally exposed.



- Missing validation and sanitisation at trust boundaries. Do not assume client-side validation is sufficient.



## Race conditions, concurrency, and state integrity



- Duplicate submissions caused by repeated clicks, retries, refreshes, or concurrent requests.



- Non-idempotent operations that can create duplicate records, payments, messages, bookings, jobs, or side effects.



- Stale state, optimistic update failures, lost updates, conflicting writes, and out-of-order async responses.



- Effects, subscriptions, listeners, timers, and requests that are not correctly cleaned up.



- UI states where actions remain available while an operation is already in progress.



- Cache invalidation problems and inconsistencies between client state, server state, and persisted data.



- Multi-tab, multi-device, and poor-network scenarios where relevant.



## Reliability and failure handling

- Unhandled promise rejections, swallowed errors, silent failures, infinite loading states, broken retry loops, and incomplete rollback behaviour.



- Missing loading, empty, error, offline, timeout, and partial-success states.



- Failure paths that leave data or the UI in an inconsistent state.



- Assumptions about API responses, nullability, ordering, timing, or network availability that could cause production failures.



- Memory leaks, unnecessary rerenders, expensive operations, and obvious performance bottlenecks that materially affect the user experience.



## Accessibility

- Semantic HTML and correct use of landmarks, headings, labels, lists, tables, buttons, and links.



- Keyboard navigation, logical tab order, focus visibility, focus trapping, and focus restoration.



- Missing or incorrect accessible names, labels, descriptions, and ARIA attributes.



- Colour contrast, text legibility, touch-target sizes, zoom behaviour, reduced-motion support, and reliance on colour alone to communicate meaning.



- Screen-reader behaviour for modals, menus, dropdowns, tabs, toasts, validation errors, loading states, and dynamically updated content.



- Forms with unclear instructions, inaccessible validation, missing autocomplete attributes, or poor error recovery.



- Test against WCAG 2.2 AA expectations where applicable.



## Visual and interaction consistency

- Inconsistent spacing, typography, colour usage, border radii, shadows, icon sizing, alignment, component dimensions, and responsive behaviour.



- Components that visually appear identical but behave differently, or behave identically but are implemented inconsistently.



- Incorrect or inconsistent use of design tokens and shared components.



- Hover, focus, active, selected, disabled, loading, success, warning, destructive, and error states that are missing or inconsistent.



- Layout shifts, clipping, overflow, truncation, wrapping issues, breakpoint problems, and inconsistent empty states.



- Copy inconsistencies, terminology drift, inconsistent capitalisation, punctuation, date formats, number formats, and action labels.



## Responsive and edge-case behaviour

- Review narrow mobile screens, tablets, desktop layouts, unusually wide screens, zoomed interfaces, and large text settings.



- Check long names, long email addresses, translated or expanded text, empty values, very large datasets, zero-result states, and malformed or unexpected content.



- Identify assumptions that only work with ideal content or a specific viewport size.


## Missing Functionality
The applicate is made up multiple modules, review each of the modules 

- Identify missing features that still need to be implemented. 

- Identify similar features in different modules that work differently, come up with a plan to bring the functionality together. 

- Build a plan for each module to finish the missing (or incorrect) parts of each module. 



___________________________



# For every issue found, report:



- Severity: Critical, High, Medium, Low, or Informational

- Category: Security, Race Condition, Reliability, Accessibility, Performance, or Visual Consistency

- Location: Exact file, component, function, endpoint, or flow

Issue: What is wrong

- Impact: What can realistically happen in production

- Evidence: The code path, behaviour, or reproducible condition supporting the finding

- Reproduction: Clear steps to trigger or verify the issue where applicable

- Recommended fix: A specific, technically actionable remediation

- Confidence: Confirmed, High Confidence, or Needs Verification



Prioritise findings by real-world impact and exploitability. Distinguish confirmed vulnerabilities from theoretical concerns and avoid reporting speculative issues without evidence.


** IMPORTANT ** 

Do not modify the code during the initial audit. First produce the complete findings report, grouped by severity and category. After the report, provide:


A prioritised remediation plan.

A list of quick wins that can be fixed safely with low regression risk.

A list of issues requiring architectural changes or deeper investigation.

A concise release recommendation: Safe to ship, Ship with known risks, or Do not ship, with justification.



Be adversarial in the security review, systematic in the accessibility review, and precise in the UI review. Do not limit the audit to obvious linting or styling issues. Trace actual user flows and failure scenarios, challenge assumptions, and identify problems that are likely to emerge under real users, unreliable networks, concurrent actions, and malicious input.