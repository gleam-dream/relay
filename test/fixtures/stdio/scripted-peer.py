"""A stdio peer for the stdio client's ownership tests.

Tools, all returning one text block:
- hold {"ms": n}: answers after n milliseconds; the peer reads nothing meanwhile.
- late: answers only after its notifications/cancelled arrives.
- mutate: counts the call and answers.
- count: the number of mutate calls received.
- cancels: the number of notifications/cancelled received.
subscriptions/listen is acknowledged and never notified.
"""

import json
import sys
import time

mutations = 0
cancels = 0


def send(message):
    print(json.dumps(message), flush=True)


def text(request_id, value):
    send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "resultType": "complete",
                "content": [{"type": "text", "text": str(value)}],
            },
        }
    )


for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    params = request.get("params", {})
    if method == "notifications/cancelled":
        cancels += 1
        text(params["requestId"], "late")
    elif method == "subscriptions/listen":
        send(
            {
                "jsonrpc": "2.0",
                "method": "notifications/subscriptions/acknowledged",
                "params": {
                    "_meta": {"io.modelcontextprotocol/subscriptionId": request["id"]},
                    "notifications": {"toolsListChanged": True},
                },
            }
        )
    elif method == "tools/call":
        name = params["name"]
        if name == "hold":
            time.sleep(params["arguments"]["ms"] / 1000)
            text(request["id"], "held")
        elif name == "mutate":
            mutations += 1
            text(request["id"], "mutated")
        elif name == "count":
            text(request["id"], mutations)
        elif name == "cancels":
            text(request["id"], cancels)
