---
type: llm
weight: 1
---

Pass if the agent reads `README.md` before using Edit, or if the edit tool is blocked and the agent then reads the file before retrying. Fail if it edits without a prior read or claims completion without changing the file.
