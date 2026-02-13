# Ziggy-Core Library Extraction Design

## Goal
Extract `ziggy-core` into a proper, versioned, publishable library in a separate repository.

## Current State

`libs/core/` contains:
- **protocol/**: chat, constants, gateway, messages, requests
- **client/**: device_identity
- **utils/**: logger, json_helpers, string_utils, secret_prompt, allocator

Dependencies:
- websocket (external dep)
- build_options (from parent)

## Design

### Repository Structure (New Repo: `ziggy-core`)

```
ziggy-core/
├── build.zig              # Library build file
├── build.zig.zon          # Package manifest
├── src/
│   └── root.zig           # Main module export
├── lib/
│   ├── protocol/
│   │   ├── chat.zig
│   │   ├── constants.zig
│   │   ├── gateway.zig
│   │   ├── messages.zig
│   │   └── requests.zig
│   ├── client/
│   │   └── identity.zig
│   └── utils/
│       ├── logger.zig
│       ├── json_helpers.zig
│       ├── string_utils.zig
│       ├── secret_prompt.zig
│       └── allocator.zig
└── tests/
    └── core_tests.zig
```

### Versioning Strategy

- Follow Semantic Versioning (SemVer)
- Start at `0.1.0` for initial extraction
- Tag releases: `v0.1.0`, `v0.2.0`, etc.

### Dependencies

**Required:**
- `websocket` - Already a dep, keep as external

**To be removed/abstracted:**
- `build_options` - Replace with compile-time config or feature flags

### API Stability

Phase 1: Internal API (v0.x)
- APIs may change between minor versions
- Focus on getting the extraction right

Phase 2: Stable API (v1.0+)
- Commit to backward compatibility
- Document public API surface

### Migration Plan

1. **Setup new repo** with proper structure
2. **Migrate code** from `libs/core/` to new repo
3. **Update imports** in ZiggyStarClaw to use package
4. **Add as git submodule** or zig package dependency
5. **Remove `libs/core/`** from main repo
6. **CI/CD** for the library

### Open Questions (Answered)

1. **Should profiler stay in core or move to ZSC-specific?**
   - ✅ Keep in core for now

2. **How to handle build_options dependency cleanly?**
   - ⚠️ TBD (needs investigation)

3. **Package manager: git submodule vs zig package manager?**
   - ✅ Use Zig package manager

## Benefits

- Clean separation of concerns
- Reusable core for other projects
- Independent versioning
- Easier testing of core logic

## Risks

- Initial migration effort
- Dual maintenance during transition
- Breaking changes in early versions
