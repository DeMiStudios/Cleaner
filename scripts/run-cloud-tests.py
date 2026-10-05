#!/usr/bin/env python3
"""Runs the test suite on Roblox servers through Open Cloud Luau Execution.

Uploads a place file as a new version of a test place, runs tests/Runner in it, prints the output, and exits non-zero
unless every test passed.

Usage:
    rojo build test.project.json -o tests.rbxl
    python3 scripts/run-cloud-tests.py tests.rbxl

Environment:
    ROBLOX_API_KEY      Open Cloud API key with the `universe-places:write` and
                        `universe.place.luau-execution-session:write` permissions for the test experience.
    ROBLOX_UNIVERSE_ID  The test experience's universe ID.
    ROBLOX_PLACE_ID     The test place's ID. Every run publishes a new saved version of this place.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://apis.roblox.com"
POLL_INTERVAL_SECONDS = 2
TIMEOUT_SECONDS = 300

# Runs inside the uploaded place. Its return values become the task's `output.results`.
TASK_SCRIPT = """
const runTests = require(game:GetService("ReplicatedStorage").Tests.Runner)
return runTests({ ci = true })
"""


def request(method, path, api_key, body=None, content_type="application/json"):
    headers = {"x-api-key": api_key}
    if body is not None:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(f"{API}/{path}", data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"{method} {path} failed with HTTP {error.code}: {error.read().decode(errors='replace')}")


def require_env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"Missing environment variable {name}")
    return value


def main():
    if len(sys.argv) != 2:
        sys.exit(f"Usage: {sys.argv[0]} <place file>")

    api_key = require_env("ROBLOX_API_KEY")
    universe_id = require_env("ROBLOX_UNIVERSE_ID")
    place_id = require_env("ROBLOX_PLACE_ID")

    with open(sys.argv[1], "rb") as place_file:
        place = place_file.read()

    version = request(
        "POST",
        f"universes/v1/{universe_id}/places/{place_id}/versions?versionType=Saved",
        api_key,
        place,
        "application/octet-stream",
    )["versionNumber"]
    print(f"Uploaded place version {version}")

    task = request(
        "POST",
        f"cloud/v2/universes/{universe_id}/places/{place_id}/versions/{version}/luau-execution-session-tasks",
        api_key,
        json.dumps({"script": TASK_SCRIPT, "timeout": f"{TIMEOUT_SECONDS}s"}).encode(),
    )

    deadline = time.monotonic() + TIMEOUT_SECONDS + 60
    while task["state"] not in ("COMPLETE", "FAILED", "CANCELLED"):
        if time.monotonic() > deadline:
            sys.exit(f"Timed out waiting for task {task['path']} (last state: {task['state']})")
        time.sleep(POLL_INTERVAL_SECONDS)
        task = request("GET", f"cloud/v2/{task['path']}", api_key)

    page_token = None
    while True:
        query = f"?pageToken={page_token}" if page_token else ""
        logs = request("GET", f"cloud/v2/{task['path']}/logs{query}", api_key)
        for entry in logs.get("luauExecutionSessionTaskLogs", []):
            for message in entry.get("messages", []):
                print(message)
        page_token = logs.get("nextPageToken")
        if not page_token:
            break

    if task["state"] != "COMPLETE":
        sys.exit(f"Task {task['state']}: {task.get('error', {}).get('message', 'no error message')}")
    if task.get("output", {}).get("results") != [True]:
        sys.exit("Tests failed")
    print("All tests passed")


if __name__ == "__main__":
    main()
