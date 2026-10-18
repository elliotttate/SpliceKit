# Core private selector evidence

Inspected without launching FCP on 2026-10-18: Final Cut Pro 12.4, bundle build
454072. The initial supported-build list contains this exact build only. This is
static ABI evidence, not live validation of transaction behavior.

All object getters below encode `@16@0:8` (object result, receiver and selector).
`SKV4Object` also checks the runtime method signature and `respondsToSelector:`
before calling the getter. No untyped scalar or struct getter is introduced.

| Image | Receiver | Getter | arm64 implementation address |
| --- | --- | --- | --- |
| Flexo | FFAnchoredTimelineModule | sequence | 0xaadcb8 |
| Flexo | FFModelObject | modelDocument | 0x272e3c |
| Flexo | FFModelDocument | library | 0x201294 |
| Flexo | FFModelDocument | undoHandler | 0x204028 |
| Flexo | FFUndoHandler | undoManager | 0x32f3cc |
| Flexo | FFAnchoredSequence | primaryObject | 0xe4478 |
| Flexo | FFAnchoredSequence | displayName | 0xd3a08 |
| Flexo | FFAnchoredCollection | containedItems | 0x91ae0 |
| Flexo | FFAnchoredObject | containedItems | 0xb0c5c |
| Flexo | FFLibrary | displayName | 0x1bf59c |
| Flexo | FFLibrary | URL | Runtime `@16@0:8`, live 12.4/454072 |
| Flexo | FFLibrary | libraryDocument | 0x1c0130 |
| Final Cut Pro | PEAppController | _targetLibrary | type string 0x10012f184 |

The last getter is a **status-only fallback when there is no sequence**. Mutation
undo never falls back to Browser focus, `_targetLibrary`, or the first library.
`FFUndoManager` statically subclasses public `NSUndoManager`. Grouping, action
names, notifications and undo use public AppKit/Foundation APIs. `fileURL` is
read with the same checked object-getter helper. Session library paths use the
owning FFLibrary's `URL`, not a project's `CurrentVersion.fcpevent` fileURL.

Reproduce using the installed application, with `APP` pointing to its path:

```sh
otool -arch arm64 -ov "$APP/Contents/Frameworks/Flexo.framework/Versions/A/Flexo"
otool -arch arm64 -ov "$APP/Contents/MacOS/Final Cut Pro"
otool -arch arm64 -l "$APP/Contents/MacOS/Final Cut Pro"
```

Flexo's `imp` annotations identify the receiver/selector; the preceding `types`
line gives the ABI. The stripped main executable uses relative method entries:
resolve the method's parenthesized name address into `__DATA,__objc_selrefs`
(start address from `otool -l`, 8-byte entries). Its `_targetLibrary` method on
`PEAppController` has type `@16@0:8`, verified this way.

The existing `SpliceKit_getActiveTimelineModule` traversal is reused unchanged.
No private selector was inferred from a display label. No new private selector
remains unverified; FCP-specific group behavior and notification coverage remain
explicitly unverified at runtime (see the workstream report).
