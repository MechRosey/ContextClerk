# Monthly Archive Brief - Test Results

Input: 11 April 2026 session blocks, 9439 chars total

---

## V0-Balanced

**Brief:** Opening suggestion: mechanism-preserving compression, 5-8 bullets

- Phase 1 backfill of ContextClerk completed across 61 projects (71,633 lines); downgraded Claude model from Sonnet to Haiku for summarization-only work to reduce costs while maintaining functionality

- Implemented session-aware append logic in ContextLog.md by storing session IDs in state.json; distinguishes same-session runs (merge into latest block) from new sessions (create fresh block), resolving tension between log density and durability across compaction boundaries

- Renamed SESSION_LOG.md to ContextLog.md with automatic backwards-compatible migration on first run; updated all internal references and skill documentation to point to new filename

- Improved session progress structure by restructuring LLM prompt to ask for what/why/mechanism and Next: line for incomplete work, reducing noise from session IDs and commit summaries that don't reflect actual workflow patterns

- Fixed UTF-8 encoding corruption in ContextLog.md output by restricting LLM responses to ASCII, preventing em dashes and smart quotes from garbling the log file

- Implemented hook-based enforcement of dangerous git patterns rather than relying on memory or discipline; block-dangerous-git hook rejects cd ... && and git ... && chaining patterns using regex rules; fixed subtle pattern bug where 'git .+push' didn't match 'git push' because .+ requires at least one character between git and push

- Fixed two robustness issues: block-dangerous-git.sh initially failed on quoted command paths due to grep limitations, replaced with Python JSON parsing; update-logs.ps1 case-insensitive matching wrongly caught contextclerk.md files in skills directories, added directory-level exclusion

---

## V1-Thematic

**Brief:** Thematic grouping: identify 2-4 work themes, 1-3 bullets each

- Session ID tracking in state JSON resolved the append-vs-boundary tradeoff in ContextClerk: same-session runs merge into the latest block, new sessions create fresh blocks, distinguishing them via session continuity rather than time
- Migrated SESSION_LOG.md to ContextLog.md with structured progress notes (what/why/mechanism plus Next: line) and ASCII-only encoding to prevent UTF-8 corruption
- Optimized Claude API calls for ContextClerk by downgrading summarization from claude-sonnet-4-6 to claude-haiku-4-5-20251001, reducing cost for single-use workload

- Extended block-dangerous-git.ps1 hook with regex rules to enforce no-command-chaining constraint as automated pre-tool enforcement, moving the rule from memory-based discipline to automated checks blocking patterns like cd ... && and git ... &&
- Fixed regex false negatives in pattern matching (e.g. git push wasn't caught because the pattern required at least one character between git and push), verified all scenarios end-to-end

- Added Bash(git *) to global allow list to eliminate repeated permission prompts while preserving hook blocks on destructive operations (push, reset --hard, clean, branch -D)
- Fixed .gitignore handling in contextclerk.ps1 to respect ancestor chain with git check-ignore -q check, preventing redundant exclusion entries

- Completed automated migration of 17 SESSION_LOG.md files to ContextLog.md across projects, fixing case-insensitive matching bug in update-logs.ps1 that wrongly caught contextclerk.md in skills directories
- Fixed outdated references in global CLAUDE.md and skills/contextclerk.md pointing to ContextClerk.md instead of ContextLog.md, ensuring correct session orientation at startup

---

## V2-Decisions

**Brief:** Decisions + non-obvious fixes only: what is invisible from code/git

- Session tracking persists session IDs in state JSON to distinguish same-session appends (grow latest block) from new-session runs (create fresh block), eliminating duplicate entries while preserving compaction as history boundary
- Haiku downgrade from Sonnet for cost, but --no-session-persistence required to prevent feedback loop: haiku invocations were spawning child sessions that got immediately queued for processing
- Smart quotes and em dashes corrupted ContextLog.md on Windows; restricted LLM output to ASCII to prevent encoding corruption
- Grep command extraction silently failed on quoted file paths in state JSON; replaced with Python JSON parsing for robustness
- Regex pattern .+push didn't match git push (required non-zero character between command and verb); adjusted to .*push to catch it correctly
- Case-insensitive file matching caught unintended contextclerk.md in skills/ subdirectories during migration; scoped to project-root files only and added git check-ignore -q to respect full ancestor .gitignore chain

---

## V3-Arc

**Brief:** Chronological arc: problem-to-solution narrative, how understanding evolved

- Started month with contextclerk bug fixes and API optimization (Sonnet -> Haiku), but quickly hit a scaling wall: runaway feedback loop creating 2296 redundant sessions. Added --no-session-persistence and automated cleanup to enable Phase 1 backfill across 61 projects.

- Discovered that SESSION_LOG.md structure was ambiguous: same-session runs couldn't distinguish between appending to an existing entry vs creating a new one, causing duplication and format drift. Session tracking via state JSON (_sessions key) resolved this by using session continuity as the decision criterion rather than guessing from timestamps.

- Tightened the LLM prompt to ask for mechanism/rationale and a "Next:" line for incomplete work, replacing vague progress bullets with structured context that actually matches the user's workflow. Found UTF-8 corruption from smart quotes in LLM output garbling the log; fixed by restricting output to ASCII.

- User requested preventative enforcement of "no command chaining" rule (cd ... &&, git ... &&) rather than relying on memory; extended block-dangerous-git.sh hook with regex rules to catch violations at tool-call time. Initial hook had a subtle bug (grep silently failed on quoted paths), fixed by switching to Python JSON parsing.

- Automated migration of 17 SESSION_LOG.md files to ContextLog.md across the codebase. Discovered the migration script had a case-sensitivity bug catching contextclerk.md in skills/ dirs; fixed by excluding skill directories.

- Eliminated repeated permission prompts by adding git * to global allow list, enabling users to run any git command while hook enforcement continues blocking dangerous operations (push, reset --hard, clean, branch -D). Final pass corrected outdated documentation references pointing to the old ContextClerk.md name instead of ContextLog.md.

---

## V4-TopInsights

**Brief:** Top insights ranked by future utility

- UTF-8 encoding corruption in LLM output - restricting ContextLog.md updates to ASCII-only text prevents em dashes and smart quotes from garbling session logs; any downstream system writing unfiltered LLM content to plaintext logs should apply this filter
- Session persistence API behavior - passing `--no-session-persistence` flag to claude subprocess calls prevents haiku summarization invocations from spawning new sessions that get immediately processed, breaking feedback loops in batch LLM dispatch scenarios
- Session tracking via persisted state JSON - storing session IDs in state `_sessions` key allows scripts to distinguish same-session appends (grow latest block) from new-session runs (create new block), resolving the design tradeoff between density and durability in mutable session logs
- Regex pattern matching in PowerShell - patterns like `'git .+push'` require at least one character between the anchors; use `'git.*push'` (zero-or-more) to avoid silent false negatives on short commands like plain `git push`
- Case-insensitive path matching gotcha - PowerShell `Select-String -Pattern` with `-SimpleMatch` on full paths can unexpectedly match substrings (e.g., `contextclerk.md` in skills/ dirs when looking for root-level logs); restrict search scope or use full-path anchors
- Git check-ignore respecting .gitignore ancestry - use `git check-ignore -q` to verify the full ancestor chain before writing local .gitignore rules; parent directories may already exclude the file, making local additions redundant
- Automated hook-based constraint enforcement - moving hand-discipline rules (no command chaining, no destructive operations) into pre-tool hooks via regex matching prevents repeated violations better than memory/documentation alone

---

## V5-TwoPart

**Brief:** Two-part: Arc (project narrative) + Insights (portable lessons)

### Arc

- Started month with bug-fix pass on existing contextclerk script, then pivoted to improving session log quality - both structural (how compaction boundaries interact with same-session appends) and content (capturing mechanism/rationale instead of vague progress notes)
- Key design problem surfaced: same-session runs need growing log entries while compaction events need to create history boundaries - tension resolved by persisting session IDs in state JSON to signal whether to append or create new block
- User repeatedly violated no-command-chaining rule and requested preventative enforcement rather than relying on discipline - led to implementing hook-based regex rules that block cd && and git && patterns at tool invocation time
- Production-scale work exposed latent bugs that didn't appear in small-scale testing: regex false negatives when pattern allowed zero-width matches, case-insensitive file matching catching unintended targets, UTF-8 encoding corruption from smart quotes in LLM output
- Final phase addressed propagated outdated references in global documentation and edge cases in .gitignore handling logic

### Insights

- Use session continuity as a decision signal for mutable log structure - persisting session IDs allows distinguishing append-to-existing from create-new-block, enabling same log file to serve both immediate context needs and durable history
- Move constraint enforcement from memory/discipline to automated tooling - hook-based regex rules at execution time prevent violations more reliably than code review or personal memory
- Latent bugs in string matching surface under production load - case-insensitive matching in file operations, zero-width regex patterns, and string parsing edge cases all require explicit scoping and robust parsing over string munging
- Tailor model selection to actual workload characteristics - haiku adequate for pure summarization tasks avoids cost and latency of larger models without capability loss
- Explicit encoding handling necessary when LLM generates prose-like output - UTF-8 defaults can silently corrupt on smart quotes and em dashes if output channel expects ASCII

