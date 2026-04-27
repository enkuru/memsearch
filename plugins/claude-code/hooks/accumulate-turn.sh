#!/usr/bin/env bash
# UserPromptSubmit hook: accumulate previous turn to session buffer.
# Extracts key actions from the PREVIOUS assistant response (before user's new prompt).
# No LLM call — lightweight extraction for high-signal events only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Extract transcript path and session ID
TRANSCRIPT_PATH=$(_json_val "$INPUT" "transcript_path" "")
SESSION_ID=$(_json_val "$INPUT" "session_id" "")

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] || [ -z "$SESSION_ID" ]; then
  echo '{}'
  exit 0
fi

# Check minimum transcript size (skip first few turns)
LINE_COUNT=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
if [ "$LINE_COUNT" -lt 5 ]; then
  echo '{}'
  exit 0
fi

ensure_memory_dir
BUFFER_FILE="$MEMSEARCH_DIR/.session-buffer-${SESSION_ID}.md"

# Extract previous turn info using Python (handles JSONL parsing)
TURN_INFO=$(python3 -c '
import json
import sys
import re

transcript_path = sys.argv[1]

# Read all lines
with open(transcript_path) as f:
    lines = f.readlines()

# Find the second-to-last user message (the previous turn start)
# and extract assistant responses between that and the last user message
user_indices = []
for i, line in enumerate(lines):
    try:
        obj = json.loads(line)
        if obj.get("type") == "user" and not obj.get("isMeta"):
            content = obj.get("message", {}).get("content")
            if isinstance(content, str) and content.strip():
                user_indices.append(i)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text" and block.get("text", "").strip():
                        user_indices.append(i)
                        break
    except:
        pass

# Need at least 2 user messages to have a "previous turn"
if len(user_indices) < 2:
    sys.exit(0)

prev_user_idx = user_indices[-2]
curr_user_idx = user_indices[-1]

# Extract assistant responses between previous and current user message
events = []
tool_calls = []
text_responses = []

for i in range(prev_user_idx + 1, curr_user_idx):
    try:
        obj = json.loads(lines[i])
        if obj.get("type") != "assistant":
            continue

        content = obj.get("message", {}).get("content", [])
        for block in content:
            if not isinstance(block, dict):
                continue

            block_type = block.get("type", "")

            if block_type == "text":
                text = block.get("text", "").strip()
                if text and len(text) > 20:
                    # Extract first sentence or line
                    first_line = text.split("\n")[0][:200]
                    text_responses.append(first_line)

            elif block_type == "tool_use":
                name = block.get("name", "")
                inp = block.get("input", {})

                # High-signal tools to capture
                if name in ("Edit", "Write", "Bash"):
                    if name == "Edit":
                        file_path = inp.get("file_path", "")
                        if file_path:
                            fname = file_path.rsplit("/", 1)[-1]
                            events.append("Edited " + fname)
                    elif name == "Write":
                        file_path = inp.get("file_path", "")
                        if file_path:
                            fname = file_path.rsplit("/", 1)[-1]
                            events.append("Created " + fname)
                    elif name == "Bash":
                        cmd = inp.get("command", "")[:80]
                        # Skip trivial commands
                        if cmd and not cmd.startswith(("ls", "cat", "echo", "cd")):
                            events.append("Ran: " + cmd)

                tool_calls.append(name)
    except:
        pass

# Determine if this turn is worth capturing
# Skip if only reads/greps (low signal)
low_signal_tools = {"Read", "Glob", "Grep", "LSP"}
high_signal = any(t not in low_signal_tools for t in tool_calls)

# Also capture if there are text responses (decisions/explanations)
has_substance = bool(events) or (bool(text_responses) and len(text_responses[0]) > 50)

if not high_signal and not has_substance:
    sys.exit(0)

# Output summary
output = []
if events:
    output.extend(events[:5])  # Max 5 events
if text_responses:
    output.append(text_responses[0][:150])  # First meaningful response

print("\n".join(output))
' "$TRANSCRIPT_PATH" 2>/dev/null || true)

# Skip if nothing extracted
if [ -z "$TURN_INFO" ]; then
  echo '{}'
  exit 0
fi

# Append to buffer with timestamp
NOW=$(date +%H:%M)
{
  echo "- [$NOW] $TURN_INFO"
} >> "$BUFFER_FILE"

echo '{}'
