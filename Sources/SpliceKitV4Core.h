// v4 plugin integration contract:
// Register full RPC names through SpliceKit_registerPluginMethod (PluginAPI).
// metadata: `readOnly`: @YES for reads (missing means mutation),
// `v4Undo`: @"native_group" (default) or @"none" (non-undoable media/UI work),
// `v4RequiresSequence`: @YES (default) or @NO (session/library/file work).
// Handlers MUST complete all native mutations synchronously on the calling main
// thread, register their native undo (e.g. storeForUndo), and return fresh readback.
// Core wraps a native_group handler in one named outer NSUndoManager group; it
// cannot manufacture undo for direct setters that did not register inverses.
// Deferred work must NOT be returned as completed; use a domain-specific job RPC.
//
// Top-level mutations require operation_id and a nonempty expected_revision.
// Reads may omit operation_id. Nested mutations inherit the outer ID/revision.
// expected_revision is checked immediately before native execution.
// Calling SpliceKit_handleRequest synchronously from a handler is supported:
// legacy RPCs skip auto-dismiss; nested v4 mutations inherit the outer ID/group,
// may omit operation_id, and must not supply a different operation_id/revision.
// Nested errors MUST propagate to the outer result. Never forward async=true.
// Reads bypass the writer queue; status never waits for the main thread.
// Independent reads are stamped with core revision_before/revision_after; a
// changed token rejects the observation with OBSERVATION_CHANGED. Ledger-only
// operation.status does not claim a fresh native observation revision.
// The TCP dispatcher handles v4 BEFORE legacy auto-dismiss/async processing.
//
// history.undo: {target_operation_id: originalID, operation_id: undoRequestID}.
// Shorthand {operation_id: originalID} uses deterministic undo:originalID as the
// undo request ID. operation.reconcile never re-executes native work.
#import <Foundation/Foundation.h>
#import "SpliceKitPluginAPI.h"
#import "SpliceKitV4Result.h"

#ifdef __cplusplus
extern "C" {
#endif
void SpliceKitV4RegisterMethods(void);
BOOL SpliceKitV4IsExecuting(void);
// Register an explicit native inverse inside the current operation-owned group.
BOOL SpliceKitV4RegisterUndo(id target, void (^inverse)(id target));
NSDictionary *SpliceKitV4Dispatch(NSString *method, NSDictionary *params,
    SpliceKitMethodHandler handler, NSDictionary *metadata);
#ifdef __cplusplus
}
#endif
