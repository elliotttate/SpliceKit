"""Exact source clocks, half-open frame ranges, and transcript boundary snapping."""

from fractions import Fraction

from .contracts import ContractError


def rational(value):
    if (not isinstance(value, dict) or set(value) != {"num", "den"}
            or any(type(value[k]) is not int for k in ("num", "den")) or value["den"] <= 0):
        raise ContractError("INVALID_TIME", "Time/rate must be {num: integer, den: positive integer}")
    return Fraction(value["num"], value["den"])


def json_time(value):
    return {"num": value.numerator, "den": value.denominator}


def frame_snap(time, rate, mode="nearest"):
    scaled = rational(time) * rational(rate)
    lower = scaled.numerator // scaled.denominator
    if mode == "floor":
        frame = lower
    elif mode == "ceil":
        frame = -(-scaled.numerator // scaled.denominator)
    elif mode == "nearest":
        frame = lower + (scaled - lower >= Fraction(1, 2))
    else:
        raise ContractError("INVALID_TIME", f"Unknown rounding mode: {mode}")
    if rational(rate) <= 0:
        raise ContractError("INVALID_TIME", "Frame rate must be positive")
    return json_time(Fraction(frame) / rational(rate))


def snap_words(word_ids, words, rate):
    by_id = {word["id"]: word for word in words}
    if not word_ids or any(word_id not in by_id for word_id in word_ids):
        raise ContractError("WORD_NOT_FOUND", "Cut must refer to known transcript word IDs")
    positions = {word["id"]: i for i, word in enumerate(words)}
    indexes = [positions[word_id] for word_id in word_ids]
    if indexes != list(range(indexes[0], indexes[-1] + 1)):
        raise ContractError("INVALID_WORD_RANGE", "Word IDs must be contiguous and in source order")
    return {"start": frame_snap(by_id[word_ids[0]]["start"], rate, "floor"),
            "end": frame_snap(by_id[word_ids[-1]]["end"], rate, "ceil")}


def source_to_timeline(source_time, source_start, timeline_start, speed=None):
    """Constant-rate mapping only; retime curves require a native time-map capability."""
    speed = rational(speed or {"num": 1, "den": 1})
    if speed <= 0:
        raise ContractError("UNSUPPORTED_TIME_MAP", "Reverse/freeze requires an explicit native time map")
    return json_time(rational(timeline_start) + (rational(source_time) - rational(source_start)) / speed)
