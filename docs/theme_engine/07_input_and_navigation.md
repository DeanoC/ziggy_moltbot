# Input and Navigation

Supporting the four profiles requires an explicit input model:

- Desktop: pointer + keyboard
- Phone: touch
- Tablet: touch + pen (optional keyboard)
- Fullscreen: controller-first

## Current State

- Input routing: `src/ui/input/input_router.zig`
- SDL backend: `src/ui/input/sdl_input_backend.zig`

The current SDL input backend primarily collects:
- mouse motion/buttons/wheel
- keyboard
- text input

SDL is initialized with `SDL_INIT_GAMEPAD`, but the input layer does not yet push gamepad events into the UI queue.

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

Core design:

- Each interactive widget can be assigned a stable **FocusId**.
- The UI maintains a **focus graph** each frame: nodes (focusables) with rectangles.
- Navigation chooses the nearest focusable in the requested direction.

Pseudo-types:

```zig
pub const FocusId = u64;

pub const FocusNode = struct {
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

