"""Common result contract; native adapters must provide their own readback."""

import uuid

from .envelope import result as envelope_result


class ContractError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def result(ok=True, *, operation_id=None, applied=False, readback=None,
           before=None, after=None, code=None, message="", warnings=None):
    return envelope_result(ok=ok, operation_id=operation_id or str(uuid.uuid4()),
                           applied=applied, readback=readback, revision_before=before,
                           revision_after=after, warnings=warnings,
                           error=None if ok else {"code": code or "PRECONDITION_FAILED",
                                                  "message": message, "retryable": False})



def failure(exc, *, applied=False, operation_id=None):
    return result(False, code=getattr(exc, "code", "PRECONDITION_FAILED"),
                  message=str(exc), applied=applied, operation_id=operation_id)
