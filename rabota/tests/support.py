"""Helpers shared by the rabota tests. Not a test module: nothing in here is collected."""
import json


def last_json(stream: str):
    """Return the last JSON object in a captured stream, decoded.

    A stream may carry lines before the payload that are not the product's — on python
    3.12+ a collected, unclosed ``sqlite3`` connection writes ``ResourceWarning: unclosed
    database`` to stderr — and ``json.loads`` over the whole thing would report a
    ``JSONDecodeError`` that names no cause. So the object is located from the END: it
    must run to the end of the stream (trailing whitespace aside), which also means a
    traceback printed AFTER the JSON is never read as a pass.

    Raises ``AssertionError`` quoting the stream when no such object exists, so the test
    fails with the stream in front of the reader rather than a decoder position.
    """
    text = stream.rstrip()
    decoder = json.JSONDecoder()
    start = text.rfind("{")
    while start != -1:
        try:
            obj, end = decoder.raw_decode(text, start)
        except json.JSONDecodeError:
            pass
        else:
            if end == len(text):
                return obj
        start = text.rfind("{", 0, start)
    raise AssertionError(f"no JSON object at the end of the captured stream:\n{stream}")
