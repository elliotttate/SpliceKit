"""Revision/hash-bound FCP-native preview contract. No external rendering."""

import hashlib
import json
import struct
import subprocess
import tempfile
import uuid
from pathlib import Path

from .contracts import ContractError, result
from .registry import digest, load_schema, validate
from .timing import json_time, rational


def png_dimensions(path):
    header = Path(path).read_bytes()[:24]
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ContractError("INVALID_ARTIFACT", "Capture did not produce a PNG")
    width, height = struct.unpack(">II", header[16:24])
    if width < 1 or height < 1:
        raise ContractError("INVALID_ARTIFACT", "Invalid PNG dimensions")
    return width, height


def capture(runtime, request):
    validate(load_schema("review.schema.json"), request)
    start, end = rational(request["range"]["start"]), rational(request["range"]["end"])
    if end <= start or end - start > 10:
        raise ContractError("INVALID_REVIEW_RANGE", "Preview range must be positive and at most ten seconds")
    state = runtime.state_data()
    runtime.assert_identity(state, request["project_id"], request["sequence_id"], request["expected_revision"])
    if request["mode"] == "native_share":
        # UNVERIFIED: the current share.export only opens a share flow. It provides
        # no destination file, completion receipt, dimensions, range, or audio proof.
        return result(False, code="NATIVE_SHARE_UNVERIFIED", message="Native export job/readback integration is pending",
                      readback={"artifact": None, "visual": "not_checked", "audio": "not_checked"})
    # The legacy capture endpoint can target the project viewer explicitly. Never
    # substitute a browser/source viewer or an uncropped full-window screenshot.
    if (state.get("playing") is not False or state.get("viewer_ready") is not True
            or state.get("viewer_sequence_id") != request["sequence_id"]):
        raise ContractError("VIEWER_NOT_READY", "Native state must confirm stopped playback and a rendered project viewer")
    position = rational(state.get("playhead"))
    if not start <= position < end:
        raise ContractError("PLAYHEAD_OUT_OF_RANGE", "Seek with a discovered native capability before capture")
    rate = rational(state.get("frame_rate"))
    if rate <= 0 or (position * rate).denominator != 1:
        raise ContractError("FRAME_ALIGNMENT", "Capture needs a native frame rate and an aligned playhead")
    directory = Path(runtime.artifact_directory) if runtime.artifact_directory else Path(tempfile.gettempdir()) / "splicekit-v4-review"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (str(uuid.uuid4()) + ".png")
    response = runtime.bridge.call("viewer.capture", path=str(path), viewer="normal")
    if (not isinstance(response, dict) or response.get("status") != "ok"
            or response.get("cropped") is not True or response.get("path") != str(path)
            or response.get("capture", {}).get("selectedViewer") != "normal"):
        raise ContractError("CAPTURE_UNVERIFIED", "Expected a freshly written, cropped project-viewer PNG")
    width, height = png_dimensions(path)
    limit = request.get("max_dimension", 640)
    if max(width, height) > limit:
        # Apple's image service only resizes the captured native pixels; it does
        # not reconstruct the edit or use a source/proxy composition.
        subprocess.run(["/usr/bin/sips", "-Z", str(limit), str(path)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        width, height = png_dimensions(path)
    if max(width, height) > limit:
        raise ContractError("INVALID_ARTIFACT", "Native image resize did not meet the preview bound")
    after = runtime.state_data()
    runtime.assert_identity(after, request["project_id"], request["sequence_id"], request["expected_revision"])
    if (after.get("playhead") != state.get("playhead") or after.get("viewer_ready") is not True
            or after.get("playing") is not False or after.get("viewer_sequence_id") != request["sequence_id"]
            or after.get("frame_rate") != state.get("frame_rate")):
        raise ContractError("STALE_ARTIFACT", "Viewer changed during capture")
    artifact = {
        "artifact_id": path.stem, "path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "project_id": request["project_id"], "sequence_id": request["sequence_id"],
        "revision": request["expected_revision"], "requested_range": request["range"],
        "range": {"start": state["playhead"], "end": json_time(position + 1 / rate)},
        "captured_time": state["playhead"],
        "native": state.get("evidence_origin") != "synthetic_fixture",
        "synthetic": state.get("evidence_origin") == "synthetic_fixture",
        "provenance": "synthetic offline fixture" if state.get("evidence_origin") == "synthetic_fixture" else "FCP project viewer via viewer.capture",
        "media_type": "image/png",
        "fcp_build": state.get("fcp_build", "unknown"), "loaded_binary_sha256": state.get("loaded_binary_sha256", "unknown"),
        "width": width, "height": height, "has_audio": False, "proxy_status": state.get("proxy_status", "unknown"),
        "color_space": "unknown", "motion_review": "not_supported_by_still", "evidence_level": "offline_tested",
        "warnings": ["Live capture not yet verified; a still cannot verify motion or audio.",
                     "Color transform and proxy state require separate native acceptance."],
    }
    artifact["binding_hash"] = digest(artifact)
    path.with_suffix(".json").write_text(json.dumps(artifact, indent=2) + "\n")
    return result(readback={"artifact": artifact, "visual": "pending_model_review", "audio": "not_checked"},
                  before=request["expected_revision"], after=request["expected_revision"])
