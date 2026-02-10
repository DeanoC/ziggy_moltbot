# Spec: ZiggyStarClaw UI — Chat history virtualization (windowed rendering)

## Problem
The custom UI backend currently processes **the entire chat history every frame**, including calling text measurement/layout for all messages. For long histories this becomes O(N) per frame and causes intermittent hitches once the message count crosses a threshold.

## Goal
Make chat rendering cost scale with **visible content**, not total history:
- Per frame work is ~O(visible_messages + small_overscan)
- Text measurement is amortized and cached
- Scroll behavior remains correct (pinned-to-bottom, preserve scroll position)

## Non-goals (for first pass)
- Full-text search / filtering
- Rich markdown layout beyond what already exists
- Persisting chat history to disk (separate item)

## Proposed approach
### A) Per-message cache
Store per message:
- `id`
- `text` (or reference)
- `cached_wrap_width_px`
- `cached_height_px` (or line count)
- `dirty` boolean

Invalidate cache when:
- message text changes
- font changes / font size changes
- available wrap width changes

### B) Windowed rendering
Each frame:
1) Determine viewport height + current scroll Y.
2) Compute visible index range `[first, last]` using cached heights.
   - Include overscan (e.g. ±1 viewport).
   - If heights are unknown for some items encountered during range finding, measure on-demand.
3) Render:
   - Insert a top spacer = sum(heights[0..first-1])
   - Render messages first..last
   - Insert a bottom spacer = remaining height

### C) Efficient range seeking
MVP:
- Linear walk from last-known `first` to find the new `first` (good enough initially)

Upgrade (for 10k+ messages):
- Maintain prefix-sum array of heights to binary-search first visible index.
- Update prefix sums incrementally when a message height changes.

### D) Scroll + pinning policy
- Maintain `isPinnedToBottom` latch.
  - If user scrolls up: latch clears.
  - If user scrolls to bottom (within epsilon): latch sets.
- When new messages arrive:
  - If pinned: keep pinned (scroll to bottom).
  - If not pinned: preserve visual position (do not jump).

### E) Instrumentation (Tracy)
Add counters/plots:
- `chat.total_messages`
- `chat.visible_messages`
- `chat.measures_per_frame`
- `chat.layout_ms`
- `chat.render_ms`

Success criteria: `measures_per_frame` stays roughly proportional to visible messages, even as `total_messages` grows.

## Acceptance criteria
- With 5k–50k messages, UI remains responsive and frame time remains stable.
- No full-history measurement in steady state (only visible + overscan).
- Scroll feels correct:
  - pinned-to-bottom works
  - manual scroll-up stays put when new messages arrive

## Implementation notes
- If the UI uses an ImGui-like API, consider ImGuiListClipper semantics (but adapted for variable-height items).
- Variable-height virtualization requires cached heights; a pure fixed-height clipper won’t be sufficient.

## Risks / gotchas
- Height estimation errors can cause scroll jitter; mitigate by measuring unknown items before rendering and caching aggressively.
- Wrap width changes (window resize) can invalidate many caches; mitigate by only invalidating on threshold changes and remeasuring lazily.
