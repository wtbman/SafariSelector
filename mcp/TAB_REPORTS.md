# Tab reports

Use this workflow when the user asks for a Safari tab report, inventory, or cleanup report.
Follow the user's scope and preferences; a report request alone does not authorize tab changes.

## Scope and destination

- Resolve the requested profile, window, and tab group through SafariSelector MCP. A label can
  occur in multiple profiles and label filters are substring matches: verify the exact scope.
- Always organize the report by **profile → tab group**. Within each group, organize tabs by
  useful topic and disposition. Keep loose tabs explicitly separate. Cover one or multiple
  requested groups; do not silently broaden to unrelated profiles or claim that unopened saved
  tab groups were inspected.
- Save the report in the user's configured default memory or knowledge location for the active
  domain, unless they specify another destination. Resolve that location from user/agent
  instructions and local configuration. Follow any established report-folder convention there;
  otherwise use the configured location itself. Do not assume a folder named `Journal`, the
  source repository, or the current working directory is the default. Do not hard-code a user's
  path or combine professional and personal records across their memory boundaries.
- For a small request, one dated Markdown document with a section per tab group works well.
  For large inventories (roughly 100+ tabs per group or an unwieldy combined document), create
  separate documents per group and a short linked overview with counts. Keep each group's full
  inventory together. Use readable, collision-safe filenames containing date, profile, and group.
- Use known preferences without asking again. If no memory location can be resolved, prepare the
  report in the conversation and ask one focused destination question before saving it.

## Inventory and verification

1. List windows and take a complete tab snapshot for each scoped group using SafariSelector MCP.
   Request JSON and an explicit limit large enough to cover the window counts (the default is
   300); cross-check counts to detect truncation, missing profiles, or changing tabs. Record the
   snapshot time and timezone, profile, group, window ID, and total. Report any coverage gaps.
2. Identify Jira, service-desk, Azure DevOps work-item, and pull-request links, including tracker
   destinations inside old sign-in redirects. Deduplicate lookup requests by tracker host and
   item identity, while retaining **every tab** in the inventory. IDs alone are not globally
   unique: include the Jira site, ADO organization, and PR repository as appropriate.
3. Prefer the relevant Jira/ADO MCP for current status, title, resolution/closed date, and updated
   date. Follow the host's connector-health and routine authentication recovery instructions if
   necessary. Verify a live read before concluding that the connector works. Use another approved
   source only if needed, and label its provenance. Never substitute a stale tab title for a live
   tracker status or claim that missing MCP tools mean the ticket is closed.
4. Separate closed/resolved tickets, open work, completed PRs, active/draft PRs, and unverified
   items. Use the actual workflow/category and resolution: Jira Done-category issues may be
   resolved without being named Closed. ADO Accepted is not automatically Closed; Removed and
   abandoned PRs are separate dispositions. A closed linked ticket does not prove another ticket
   is closed. Preserve exact source state names and verification timestamps.
5. A null response, permission error, missing item, expired login, or deleted/retained-away build
   does not prove completion. Mark it **Unverified** and explain the evidence gap. For non-ticket
   pages, distinguish confirmed past dates/session-expired pages from merely old or idle pages.
   Last-active age measures browsing activity, not content validity. State when only a title/URL
   was assessed. Group research, reference, administration, navigation, meeting pages, old runs,
   transient sign-in pages, and test pages as useful for the actual inventory.
6. Identify exact duplicates separately from equivalent destinations (query variants, migrated
   tracker links, or different views of one item). Preserve meaningful file/comment/filter
   context; don't normalize arbitrary URLs so aggressively that distinct pages become duplicates.
   Report both the number of duplicate sets and extra copies; these counts can overlap closed
   ticket/PR counts and must not be summed as independent cleanup totals.
7. Redact credentials, OAuth codes/tokens, signed URL secrets, meeting passcodes, and sensitive
   query/fragment values from persisted links and logs. Where possible, retain a safe canonical
   destination so the report remains useful after sign-in redirects expire.

## Report structure

Use Markdown tables and concrete links. Include:

- **Scope and coverage:** snapshot and status-check times, profiles/groups, totals, source systems,
  limits, and whether any cleanup has occurred.
- **Cleanup summary:** category, distinct items, tab count, suggested action, and overlapping counts.
- **Work to keep visible:** active tickets, draft PRs, and unresolved investigations.
- **Tracker tables:** linked ID/current title, exact state, resolution or closed date, updated date,
  verification source, and snapshot tab numbers. Separate Jira, ADO, and PRs when useful.
- **Duplicates:** destination, exact/equivalent classification, all snapshot positions, extra copies,
  and any meaningful differences between copies.
- **Old or transient information:** evidence of expiry/age, remaining uncertainty, and recommendation.
- **Complete inventory within each tab group:** one row per original tab, grouped by useful topic
  or disposition, with snapshot number, linked title/URL, status, evidence, and recommendation.

Distinguish verified facts from cleanup judgments. Never omit a tab just because it appears in a
tracker or duplicate summary. Preserve enough safe link information to reopen a closed destination.
Deliver links to all report documents and a concise count summary.

## Authorized cleanup and follow-up

- If the user subsequently requests cleanup, act within their named scope and categories without
  asking for the same authorization again. Close only tickets/PRs verified in the requested final
  states. Refresh status when the report is no longer current or the evidence is uncertain.
- Interpret duplicate quantities precisely: “close one copy” removes one extra per duplicate set;
  “keep one” removes all extras. Prefer retaining the active/pinned or more useful contextual copy.
  Account for tabs already removed as completed work before selecting additional duplicates.
- Re-list immediately before closing or moving and match the intended tabs to fresh IDs. IDs and
  positions can change. Closing by URL removes every exact match in scope, so use fresh IDs when
  keeping a copy. Do not use bulk duplicate cleanup for a one-copy-per-set request.
- Verify the resulting inventory. Append a dated cleanup log to the report with category counts,
  original snapshot positions/links removed, remaining count, and any failures. Keep the original
  inventory clearly labeled as a historical snapshot. Do not move a report under active review
  merely to change the destination convention for future reports.
