"""Protocol peer for absent/null structured output and state-only continuations."""

import json
import sys

reply, remaining = sys.argv[1], int(sys.argv[2])
state = None
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    params = request["params"]
    if state is not None:
        assert params["requestState"] == state
        assert params["inputResponses"] == {}
    assert params["arguments"] == {}
    if remaining:
        state = f"round-{remaining}"
        remaining -= 1
        result = {"resultType": "input_required", "requestState": state}
    else:
        result = {
            "resultType": "complete",
            "content": [{"type": "text", "text": "fallback"}],
        }
        if reply != "absent":
            result["structuredContent"] = json.loads(reply)
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
