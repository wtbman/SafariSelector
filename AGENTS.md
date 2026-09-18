# SafariSelector agent instructions

For user requests to report on Safari tabs, follow [the tab-report workflow](mcp/TAB_REPORTS.md).
Always organize by profile and tab group and save reports in the user's configured memory
location for the relevant domain. This repository owns reusable behavior, not user tab records.

Keep `mcp/TAB_REPORTS.md` authoritative: the MCP server sends the same file as its initialization
instructions, so clients receive the workflow when connecting outside this repository too.
Keep user-specific paths, browser inventories, and credentials out of repository instructions.

For development, see [README.md](README.md), [the MCP README](mcp/README.md), and
[the build instructions](AGENT_BUILD_INSTRUCTIONS.md). Use build output outside the repository.
