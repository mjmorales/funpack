#!/usr/bin/env python3
"""Remove Odin comments in place while preserving string-literal content.

String-literal-aware: `//` and `/*` inside "..." double-quoted strings, `...`
backtick raw strings (test fixtures embed comment-looking content), and '..'
char/rune literals are kept verbatim. Odin block comments nest, so /* */ depth
is tracked. Comment-only lines are dropped, trailing comments are trimmed,
leading blanks removed, and runs of blank lines collapsed to one.

Usage: strip-comments.py FILE [FILE ...]
"""
import sys


def strip(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c in '"`\'':
            closer = c
            escapes = c != "`"
            out.append(c)
            i += 1
            while i < n:
                out.append(src[i])
                if escapes and src[i] == "\\" and i + 1 < n:
                    out.append(src[i + 1])
                    i += 2
                    continue
                if src[i] == closer:
                    i += 1
                    break
                i += 1
            continue
        if c == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and nxt == "*":
            depth = 1
            i += 2
            while i < n and depth > 0:
                if src[i] == "/" and src[i + 1 : i + 2] == "*":
                    depth += 1
                    i += 2
                elif src[i] == "*" and src[i + 1 : i + 2] == "/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def cleanup(stripped: str, original: str) -> str:
    stripped_lines = stripped.split("\n")
    original_lines = original.split("\n")
    kept = []
    for idx, line in enumerate(stripped_lines):
        trimmed = line.rstrip()
        was_comment_only = (
            trimmed == "" and idx < len(original_lines) and original_lines[idx].strip() != ""
        )
        if was_comment_only:
            continue
        kept.append(trimmed)
    while kept and kept[0] == "":
        kept.pop(0)
    collapsed = []
    for line in kept:
        if line == "" and collapsed and collapsed[-1] == "":
            continue
        collapsed.append(line)
    while collapsed and collapsed[-1] == "":
        collapsed.pop()
    return "\n".join(collapsed) + "\n"


def main() -> None:
    for path in sys.argv[1:]:
        original = open(path).read()
        open(path, "w").write(cleanup(strip(original), original))
        print("stripped", path)


if __name__ == "__main__":
    main()
