# Input and Navigation

Supporting the four profiles requires an explicit input model:

- Desktop: pointer + keyboard
- Phone: touch
- Tablet: touch + pen (optional keyboard)
- Fullscreen: controller-first

## Current State

- Input routing: `src/ui/input/input_router.zig`
- SDL backend: `src/ui/input/sdl_input_backend.zig`
- Controller navigation: `src/ui/input/nav.zig` + `src/ui/input/nav_router.zig`

The SDL input backend collects:
- mouse motion/buttons/wheel
- keyboard
- text input
- gamepad (buttons + left stick axis)

In multi-window mode, gamepad events are treated as **global** and routed to the window that currently has keyboard focus (fallback: the first window that collects input that frame).

Controller navigation currently works by:
- collecting a per-frame list of focusable rectangles (buttons, checkboxes, control-panel tabs, etc.)
- generating stable focus ids per widget (widget kind+label, a per-scope seed like panel id/list item id, and a per-callsite seed)
- using d-pad / left stick to move selection between those rectangles using a simple geometric nearest-in-direction heuristic
- pinning a virtual cursor to the focused item's center
- generating a `nav_activate` event on `A` (South face button) that core widgets interpret as click/toggle/focus
- drawing a visible focus indicator via the theme focus ring (thickness/color/glow are theme-controlled)

## Proposed Additions

### 1. Input modality
Track the active modality at runtime (can change frame-to-frame):

- pointer_keyboard
- touch
- pen
- controller

Heuristic examples:
- if a touch event happened recently: modality = touch
- if gamepad button pressed: modality = controller
- if mouse moved: modality = pointer

Profiles decide the *defaults* and style expectations (hover states allowed, focus ring always-on, etc.).

### 2. Touch and pen events
Add event types:
- touch_down/up/move with pointer id
- pinch/zoom (optional)
- pen_down/up/move + pressure (optional)

Minimum for phone/tablet:
- single pointer touch with drag
- scroll gestures

### 3. Controller navigation
Fullscreen requires a navigation system that does not depend on pointer hover.

Current design:
- Focusables are registered by rect and a stable 64-bit focus id.
- Navigation chooses the nearest focusable in the requested direction.
- Activation is implemented via a `nav_activate` event (preferred over synthetic clicks).

Touch/pen (SDL3) are also supported:
- touch and pen are mapped onto the existing mouse-driven widgets for broad compatibility
- drag-to-scroll is enabled in scroll views (after a small drag threshold, so taps still click)

Pseudo-types:

```zig
pub const FocusId = u64;

pub const FocusNode = struct {
    // TODO: stable id for better persistence across frames/layout changes.
    id: FocusId,
    rect: Rect,
    enabled: bool,
};

pub const FocusSystem = struct {
    focused: ?FocusId,
    nodes: std.ArrayList(FocusNode),

    pub fn beginFrame(self: *FocusSystem) void; // clear nodes
    pub fn register(self: *FocusSystem, node: FocusNode) void;
    pub fn handleNav(self: *FocusSystem, nav: NavEvent) void;
};
```

Nav events:
- left/right/up/down
- activate
- back
- page/tab left/right

### 4. Theme hooks
Themes should control:
- focus ring thickness/color/glow
- selected/pressed states
- controller hint styling and placement

The focus ring should be drawn using the material system (glow is a material).

## Controller Mapping (Suggested)

- D-pad / left stick: move focus
- A / Cross: activate
- B / Circle: back
- X / Square: search or context
- Y / Triangle: menu
- LB/RB: previous/next tab
- LT/RT: page up/down, or fast scroll

## Accessibility Notes

- Always provide a visible focus indicator when keyboard/controller is active.
- Ensure state visuals do not rely on hover alone.
- Keep hit targets consistent across profiles.
