import json
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    params = request["params"]
    name = params.get("name")
    if name == "state-only" and "requestState" not in params:
        result = {"resultType": "input_required", "requestState": "opaque"}
    elif name == "state-only":
        valid = (
            params.get("requestState") == "opaque"
            and params.get("inputResponses") == {}
            and params.get("arguments") == {}
        )
        result = {
            "resultType": "complete",
            "content": [],
            "structuredContent": "resumed" if valid else "bad continuation",
        }
    elif name == "empty-requests" and "inputResponses" not in params:
        result = {"resultType": "input_required", "inputRequests": {}}
    elif name == "empty-requests":
        result = {"resultType": "complete", "content": [], "structuredContent": "resumed empty"}
    elif name == "content-only" and "requestState" not in params:
        result = {
            "resultType": "input_required",
            "requestState": "content-state",
            "inputRequests": {"root": {"method": "roots/list", "params": {}}},
        }
    elif name == "content-only":
        result = {
            "resultType": "complete",
            "content": [{"type": "text", "text": "content resumed"}],
        }
    elif name == "slow":
        time.sleep(2)
        result = {"resultType": "complete", "content": [], "structuredContent": "late"}
    else:
        result = {"resultType": "input_required"}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
