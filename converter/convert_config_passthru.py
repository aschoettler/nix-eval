#!/usr/bin/env python3
"""Rewrite top-level `config =` assignments to `config.snapshot =`."""

from __future__ import annotations

import pathlib
import sys


# Checks if iterator `sub` is a subsequence of `super`.
# Similar to issubset() but cares about order.
# Ex: iter_subset((1, 3), (1, 2, 3)) -> True
#     iter_subset((1, 3), (3, 2, 1)) -> False
def iter_subset(sub, super):
    it = iter(super)
    return all(s in it for s in sub)


# Rewrites nix modules of the form `{ ... }: let ... in { config = ... }` to `{ ... }: let ... in { config.snapshot.<fname> = ... }`,
# replacing `config` with `config.snapshot.<fname>` where `<fname>` is the name of the file.
# This converter is brittle.
# - It assumes the input file is formatted by eg `nixfmt`
# - It doesn't track scopes or know about multiple `let ... in` blocks
def rewrite_file(path: pathlib.Path) -> None:
    text = path.read_text()
    lines = text.splitlines(keepends=True)
    seen_in = False
    stem = path.stem

    # Expecting two of these:
    # - line 1: `{ ... }:` where `...` may include `\n`
    #   (then maybe a `let ... in` block, which should have indented body)
    # - immediately after that, we should have `^{\n`
    num_toplevel_braces = 0

    # loosely checks if there's a `let ... in` block
    has_let_in = iter_subset(("let", "in"), (line.strip() for line in lines))

    for idx, line in enumerate(lines):
        if line.startswith("{"):
            num_toplevel_braces += 1

        stripped = line.strip()
        if not seen_in and stripped == "in":
            seen_in = True
            continue

        if (
            (seen_in or not has_let_in)
            and (num_toplevel_braces == 2)
            and stripped.startswith("config = ")
        ):
            pos = line.find("config =")
            if pos != -1:
                lines[idx] = line.replace("config =", f"config.snapshot.{stem} =", 1)
                break

    else:  # no changes
        # Not every file needs rewriting (e.g., aggregator modules).
        print(f"No changes made to {path}")
        return

    with open(path, "w", encoding="utf-8") as fh:
        print(f"Converted {path}")
        fh.write("".join(lines))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <modules-directory>", file=sys.stderr)
        return 2

    root = pathlib.Path(argv[1])
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 1

    for path in sorted(root.glob("*.nix")):
        rewrite_file(path)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
