"""Seven stable bootstrap tools; detailed capabilities stay out of tools/list."""

from .runtime import AgentRuntime

INSTRUCTIONS = """SpliceKit v4: start with session_status and state_read. Use capability_search,
then capability_describe, then capability_invoke with the returned schema_hash and
schema-valid arguments. Use plan.validate -> plan.preview_diff -> plan.apply for
editorial work. Every mutation needs native readback. Inspect operation_status
after UNKNOWN_OUTCOME; never replay or issue a blind undo. review.capture returns
revision/hash-bound FCP evidence; still images cannot verify motion or sound.
Build scope and evidence level are independent of discovery. Missing native core
bindings are unsupported, never a reason to use legacy raw execution."""


def register_tools(mcp, bridge):
    runtime = AgentRuntime(bridge)

    def annotation(title, read_only=True):
        return {"title": title, "readOnlyHint": read_only, "destructiveHint": not read_only,
                "idempotentHint": read_only, "openWorldHint": False}

    @mcp.tool(annotations=annotation("Session Status"))
    def session_status() -> dict:
        """Read FCP build, capability count, evidence levels and unresolved operations."""
        return runtime.session_status()

    @mcp.tool(annotations=annotation("Search Capabilities"))
    def capability_search(query: str = "", category: str = None, limit: int = 10) -> dict:
        """Search compact descriptors; no native action. Describe a match before invoking."""
        return runtime.capability_search(query, category, limit)

    @mcp.tool(annotations=annotation("Describe Capability"))
    def capability_describe(name: str) -> dict:
        """Return a discovered capability's schemas, hash, build scope and limitations."""
        return runtime.capability_describe(name)

    @mcp.tool(annotations=annotation("Read State"))
    def state_read() -> dict:
        """Read fresh native identity/revision and bounded context via the core registry binding."""
        return runtime.state_read()

    @mcp.tool(annotations=annotation("Operation Status"))
    def operation_status(operation_id: str) -> dict:
        """Inspect a native operation ledger entry; cached results cannot reconcile UNKNOWN."""
        return runtime.operation_status(operation_id)

    @mcp.tool(annotations=annotation("History Checkpoint", False))
    def history_checkpoint(label: str, project_id: str, sequence_id: str, expected_revision: str) -> dict:
        """Request a native checkpoint for an exact project/sequence/revision."""
        return runtime.history_checkpoint(label, project_id, sequence_id, expected_revision)

    @mcp.tool(annotations=annotation("Invoke Capability", False))
    def capability_invoke(name: str, arguments: dict, schema_hash: str) -> dict:
        """Invoke a searched/described capability using its exact validated schema hash."""
        return runtime.capability_invoke(name, arguments, schema_hash)

    return runtime
