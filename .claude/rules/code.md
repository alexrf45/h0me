## Code Fixes

Before suggesting any fix, do this: (1) state the exact error/symptom, (2) identify the failing component and read its actual config/logs, (3) form a hypothesis and tell me how you'll verify it, (4) THEN propose a fix. Do not iterate on speculative fixes.

## Debugging Discipline

- When a fix fails, re-diagnose the root cause before attempting another fix; avoid stacking speculative changes
- For permission/init-container issues, enumerate ALL writable paths the app needs (run dirs, log dirs, cache dirs) in one pass
