#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$REPO_DIR/skills"

CLAUDE_DIR="$HOME/.claude/skills"
CODEX_DIR="$HOME/.agents/skills"

mkdir -p "$CLAUDE_DIR"
mkdir -p "$CODEX_DIR"

for skill in "$SKILLS_DIR"/*; do
    [[ -d "$skill" && -f "$skill/SKILL.md" ]] || continue

    name="$(basename "$skill")"

    for target_dir in "$CLAUDE_DIR" "$CODEX_DIR"; do
        target="$target_dir/$name"

        # Don't accidentally destroy someone's real skill directory.
        if [[ -e "$target" && ! -L "$target" ]]; then
            echo "Skipping $target: already exists and is not a symlink"
            continue
        fi

        ln -sfn "$skill" "$target"
        echo "$target -> $skill"
    done
done
