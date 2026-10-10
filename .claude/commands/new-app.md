---
description: Scaffold a new app under apps/ using the new-app skill
argument-hint: <app-name>
---

Invoke the `new-app` skill at `.claude/skills/new-app/SKILL.md` to scaffold a new app.

App name (from `$ARGUMENTS`, may be empty): **$ARGUMENTS**

If `$ARGUMENTS` is non-empty, skip the "ask for app name" step of the skill and use this value. Then proceed with the interactive prompts (Postgres, Bitwarden secret, Dragonfly, PVC, exposure / Anubis) as specified in the skill.
