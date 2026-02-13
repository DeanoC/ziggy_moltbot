# UI + Theme System Library Extraction Design

## Goal
Extract the UI and theme system into a proper, reusable library in a separate repository.

## Current State

### UI System (`src/ui/`)

**Core UI:**
- `theme_engine/` - Theming system with packs, profiles, stylesheets
- `components/` - Reusable UI components
- `widgets/` - Basic widgets (button, checkbox, text_input, etc.)
- `input/` - Input handling (keyboard, mouse, SDL backend, navigation)
- Layout system: `workspace.zig`, `panel_manager.zig`, docking

**ZSC-Specific UI:**
- `main_window.zig` - Main application window
- `chat_view.zig`, `input_panel.zig` - Chat-specific UI
- `agents_view.zig` - Agent management UI
- `settings_view.zig` - Settings panel

### Theme Engine (`src/ui/theme_engine/`)

**Core (Reusable):**
- `theme_engine.zig` - Main theming runtime
- `schema.zig` - Theme schema definitions
- `style_sheet.zig` - Style processing
- `runtime.zig` - Runtime theme application
- `profile.zig` - Theme profiles
- `theme_package.zig` - Package loading

## Design

### Repository Structure (New Repo: `ziggy-ui`)

```
ziggy-ui/
├── build.zig
├── build.zig.zon
├── src/
│   ├── root.zig              # Main export
│   ├── theme_engine.zig      # Core theming
│   ├── schema.zig            # Theme schemas
│   ├── style_sheet.zig       # Style processing
│   ├── runtime.zig           # Theme runtime
│   ├── profile.zig           # Profile management
│   ├── package.zig           # Package loading
│   └── widgets/
│       ├── root.zig          # Widget exports
│       ├── button.zig
│       ├── checkbox.zig
│       ├── text_input.zig
│       └── text_editor.zig
├── src/components/
│   ├── root.zig              # Component exports
│   └── composite/            # Complex components
├── src/layout/
│   ├── dock.zig              # Docking system
│   ├── panel.zig             # Panel management
│   └── workspace.zig         # Workspace layout
└── themes/
    ├── zsc_clean/            # Clean modern theme
    ├── zsc_showcase/         # Showcase theme
    └── zsc_winamp/           # Retro/winamp theme
```

### API Design Principles

1. **Backend Agnostic** - Support multiple renderers (WGPU, SDL, etc.)
2. **Input Abstraction** - Pluggable input backends
3. **Theme-First** - Everything styled via theme system
4. **Composability** - Easy to build complex UIs from simple parts

### Dependencies

**Required:**
- `ziggy-core` - For protocol types, utils
- Rendering backend (WGPU, etc.)
- Input backend (SDL, etc.)

**Optional:**
- Font loading (FreeType)
- Image loading

### Versioning Strategy

- Start at `0.1.0`
- API stability at `1.0.0`
- Theme format stability earlier (themes are data)

### Migration Plan

1. **Audit current UI** - Identify reusable vs ZSC-specific
2. **Extract theme engine** - Move to new repo first
3. **Extract widgets** - Basic widget set
4. **Extract components** - Higher-level components
5. **Extract layout** - Docking/workspace system
6. **Update ZSC** - Import as package, remove from src/ui/

### Separation Strategy

**Move to Library:**
- Theme engine (schema, runtime, packages)
- Base widgets (button, checkbox, text input)
- Layout system (dock, panels)
- Input abstraction layer

**Keep in ZSC:**
- Application-specific views (chat, agents, settings)
- Custom ZSC widgets
- Main window shell

## Open Questions (Answered)

1. **Should rendering be part of UI lib or separate?**
   - ✅ Keep it part of the UI lib for now - can refactor out later if needed

2. **How to handle platform-specific code (Android, WASM)?**
   - ✅ Keep it behind platform configs

3. **Should input be a separate abstraction library?**
   - ✅ Like renderer, keep it in for now

4. **Package manager: git submodule vs zig package?**
   - ✅ Use Zig package manager

## Benefits

- Reusable UI framework for other projects
- Independent theme development
- Easier to test UI components in isolation
- Community can contribute themes

## Risks

- Large refactoring effort
- Breaking changes during extraction
- Coordination between two repos
