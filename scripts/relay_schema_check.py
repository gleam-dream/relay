#!/usr/bin/env python3
"""Validate actual Relay output against the frozen upstream MCP 2026-07-28 schema."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "test/fixtures/mcp_2026/schema.json.source"
SHA256 = "ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203"
REQUIRED_DEFINITIONS = {
    "DiscoverResultResponse",
    "ListToolsResultResponse",
    "CallToolResultResponse",
    "ListResourcesResultResponse",
    "ReadResourceResultResponse",
    "ListResourceTemplatesResultResponse",
    "ListPromptsResultResponse",
    "GetPromptResultResponse",
    "CompleteResultResponse",
    "UnsupportedProtocolVersionError",
}
REQUIRED_RESULT_DEFINITIONS = {
    "ListResourcesResult",
    "ReadResourceResult",
    "ListResourceTemplatesResult",
    "ListPromptsResult",
    "GetPromptResult",
    "CompleteResult",
}
CACHED_SERVICE_RESULTS = {
    "ListResourcesResultResponse",
    "ReadResourceResultResponse",
    "ListResourceTemplatesResultResponse",
    "ListPromptsResultResponse",
}
DELIVERED_SERVICE_RESULTS = {
    "resources_list": "ListResourcesResultResponse",
    "resource_read": "ReadResourceResultResponse",
    "resource_templates_list": "ListResourceTemplatesResultResponse",
    "prompts_list": "ListPromptsResultResponse",
    "prompt_get": "GetPromptResultResponse",
    "completion": "CompleteResultResponse",
}
DELIVERED_RESULT_DEFINITIONS = {
    "resources_list": "ListResourcesResult",
    "resource_read": "ReadResourceResult",
    "resource_templates_list": "ListResourceTemplatesResult",
    "prompts_list": "ListPromptsResult",
    "prompt_get": "GetPromptResult",
    "completion": "CompleteResult",
}


def main():
    if not SCHEMA.exists():
        sys.exit(f"FAIL: schema file not found at {SCHEMA}")

    raw = SCHEMA.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if digest != SHA256:
        sys.exit(f"FAIL: frozen MCP schema checksum mismatch: got {digest}, expected {SHA256}")

    schema = json.loads(raw)
    Draft202012Validator.check_schema(schema)

    result = subprocess.run(
        ["gleam", "run", "-m", "relay_protocol_corpus"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        sys.exit(f"FAIL: gleam run -m relay_protocol_corpus failed:\n{result.stdout}\n{result.stderr}")

    lines = [line.strip() for line in result.stdout.splitlines() if line.strip().startswith("{")]
    cases = []
    for line in lines:
        try:
            cases.append(json.loads(line))
        except json.JSONDecodeError:
            pass

    if not cases:
        sys.exit("FAIL: empty Relay wire corpus")

    labels = set()
    definitions = set()
    delivered_service_results = {}
    delivered_result_definitions = {}
    tool_results = set()
    mutations = 0

    for case in cases:
        label = case["label"]
        definition = case["definition"]
        result_definition = case.get("resultDefinition")
        instance = case["instance"]

        if label in labels or definition not in schema["$defs"]:
            sys.exit(f"FAIL: invalid Relay corpus identity or missing def: {label} ({definition})")

        labels.add(label)
        definitions.add(definition)
        if label in DELIVERED_SERVICE_RESULTS:
            if DELIVERED_SERVICE_RESULTS[label] != definition:
                sys.exit(f"FAIL: unexpected MCP definition for delivered service result {label}: {definition}")
            delivered_service_results[label] = definition
            expected_result_definition = DELIVERED_RESULT_DEFINITIONS[label]
            if expected_result_definition != result_definition:
                sys.exit(
                    f"FAIL: unexpected MCP result definition for {label}: "
                    f"{result_definition}"
                )
            delivered_result_definitions[label] = result_definition

        validator = Draft202012Validator({
            "$schema": schema["$schema"],
            "$defs": schema["$defs"],
            "$ref": f"#/$defs/{definition}",
        })

        errors = list(validator.iter_errors(instance))
        if errors:
            sys.exit(f"FAIL: MCP schema disagreement for {label}: {errors[0]}")

        result_validator = None
        if label in DELIVERED_RESULT_DEFINITIONS:
            result_definition = DELIVERED_RESULT_DEFINITIONS[label]
            result_validator = Draft202012Validator({
                "$schema": schema["$schema"],
                "$defs": schema["$defs"],
                "$ref": f"#/$defs/{result_definition}",
            })
            result_errors = list(result_validator.iter_errors(instance["result"]))
            if result_errors:
                sys.exit(
                    f"FAIL: MCP result schema disagreement for {label}: "
                    f"{result_errors[0]}"
                )

        # Mutation 1: Delete jsonrpc
        malformed = copy.deepcopy(instance)
        del malformed["jsonrpc"]
        if validator.is_valid(malformed):
            sys.exit(f"FAIL: missing jsonrpc version accepted: {label}")
        mutations += 1

        # Check resultType on result
        if "result" in instance:
            if instance["result"].get("resultType") != "complete":
                sys.exit(f"FAIL: unexpected modern result kind in {label}: {instance['result'].get('resultType')}")
            malformed = copy.deepcopy(instance)
            del malformed["result"]["resultType"]
            if validator.is_valid(malformed):
                sys.exit(f"FAIL: missing resultType accepted: {label}")
            mutations += 1

        if definition in {"DiscoverResultResponse", "ListToolsResultResponse"} | CACHED_SERVICE_RESULTS:
            resp = instance["result"]
            if resp.get("cacheScope") != "private" or resp.get("ttlMs") != 0:
                sys.exit(f"FAIL: unestablished cache policy: {label}")
            for member in ("cacheScope", "ttlMs"):
                malformed = copy.deepcopy(instance)
                del malformed["result"][member]
                if result_validator is not None:
                    mutation_is_valid = result_validator.is_valid(malformed["result"])
                else:
                    mutation_is_valid = validator.is_valid(malformed)
                if mutation_is_valid:
                    sys.exit(f"FAIL: missing {member} accepted: {label}")
                mutations += 1

        if definition == "CallToolResultResponse":
            tool_results.add(instance["result"].get("isError", False))

        if definition == "UnsupportedProtocolVersionError":
            malformed = copy.deepcopy(instance)
            del malformed["error"]["data"]["supported"]
            if validator.is_valid(malformed):
                sys.exit("FAIL: missing supported versions accepted")
            mutations += 1

    if not REQUIRED_DEFINITIONS.issubset(definitions):
        sys.exit(f"FAIL: Relay corpus omits a required definition: missing {REQUIRED_DEFINITIONS - definitions}")

    if not REQUIRED_RESULT_DEFINITIONS.issubset(set(delivered_result_definitions.values())):
        sys.exit(
            "FAIL: Relay corpus omits a delivered service result definition: "
            f"missing {REQUIRED_RESULT_DEFINITIONS - set(delivered_result_definitions.values())}"
        )

    if delivered_service_results != DELIVERED_SERVICE_RESULTS:
        sys.exit(
            "FAIL: Relay corpus omits delivered service responses: "
            f"missing {set(DELIVERED_SERVICE_RESULTS) - set(delivered_service_results)}"
        )

    if tool_results != {True, False}:
        sys.exit(f"FAIL: Relay corpus must contain tool success and tool error, got {tool_results}")

    print(
        f"PASS: {len(cases)} Relay wire messages match official frozen MCP schema; "
        f"{mutations} malformed single-mutation negatives rejected."
    )


if __name__ == "__main__":
    main()
