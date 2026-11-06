"""Mechanical grammar check of a Mermaid erDiagram block.

Not a renderer. It checks the things that actually break an ER diagram on
GitHub: unbalanced braces, attribute lines that do not match
  <type> <name> [PK|FK|UK[, ...]] ["comment"]
relationship lines whose cardinality tokens are not real Mermaid tokens,
missing relationship labels, entities used but never declared, and stray
pipe characters outside cardinality tokens.
"""
import re, sys

LEFT  = {"||", "|o", "}o", "}|"}
RIGHT = {"||", "o|", "o{", "|{"}
KEY   = r"(?:PK|FK|UK)"

ATTR = re.compile(rf'^(?P<type>[A-Za-z_][\w()]*)\s+(?P<name>[A-Za-z_]\w*)'
                  rf'(?P<keys>\s+{KEY}(?:\s*,\s*{KEY})*)?'
                  rf'(?P<comment>\s+"[^"]*")?$')
REL  = re.compile(r'^(?P<l>\S+)\s+(?P<lc>\S{2})(?P<line>--|\.\.)(?P<rc>\S{2})\s+(?P<r>\S+)\s*:\s*(?P<label>.+)$')

def blocks_from(path):
    """Yield (first_line_number, lines) for each ```mermaid fence in a file.

    A .mmd file is treated as one block. Line numbers are reported against the
    block, not the markdown file, because that is what a Mermaid error message
    would refer to.
    """
    text = open(path).read()
    if not path.endswith(".md"):
        return [(1, text.splitlines())]
    out, cur, start = [], None, 0
    for n, line in enumerate(text.splitlines(), start=1):
        if cur is None and line.strip() == "```mermaid":
            cur, start = [], n + 1
        elif cur is not None and line.strip() == "```":
            out.append((start, cur)); cur = None
        elif cur is not None:
            cur.append(line)
    if cur is not None:
        raise SystemExit("unterminated ```mermaid fence")
    return out


def check_block(lines):
    errors, warns = [], []
    declared, used = set(), set()
    depth, cur = 0, None

    if not lines or lines[0].strip() != "erDiagram":
        errors.append("line 1: must be exactly 'erDiagram'")

    for n, raw in enumerate(lines[1:], start=2):
        s = raw.strip()
        if not s or s.startswith("%%"):
            continue
        if s == "}":
            if depth == 0:
                errors.append(f"line {n}: '}}' with no open entity block")
            depth, cur = max(0, depth - 1), None
            continue
        m = re.match(r'^(?P<name>[A-Za-z_]\w*)\s*\{$', s)
        if m and depth == 0:
            name = m.group("name")
            if name in declared:
                errors.append(f"line {n}: entity '{name}' declared twice")
            declared.add(name); depth, cur = 1, name
            continue
        if depth == 1:
            if not ATTR.match(s):
                errors.append(f"line {n}: attribute does not match "
                              f"'<type> <name> [KEY] [\"comment\"]' -> {s!r}")
            elif '|' in s:
                errors.append(f"line {n}: '|' inside an attribute line is risky -> {s!r}")
            continue
        r = REL.match(s)
        if r:
            if r.group("lc") not in LEFT:
                errors.append(f"line {n}: left cardinality {r.group('lc')!r} "
                              f"not one of {sorted(LEFT)}")
            if r.group("rc") not in RIGHT:
                errors.append(f"line {n}: right cardinality {r.group('rc')!r} "
                              f"not one of {sorted(RIGHT)}")
            label = r.group("label").strip()
            if not label:
                errors.append(f"line {n}: relationship has no label")
            elif not (label.startswith('"') and label.endswith('"')) and " " in label:
                errors.append(f"line {n}: multi-word label must be quoted -> {label!r}")
            used.update([r.group("l"), r.group("r")])
            continue
        errors.append(f"line {n}: not an entity block, attribute or relationship -> {s!r}")

    if depth != 0:
        errors.append(f"unbalanced braces: {depth} entity block(s) left open")
    for e in sorted(used - declared):
        errors.append(f"relationship uses undeclared entity '{e}'")
    for e in sorted(declared - used):
        warns.append(f"entity '{e}' declared but has no relationship line")

    print(f"entities declared : {len(declared)}")
    print(f"relationships     : {len(used) and sum(1 for l in lines if REL.match(l.strip()))}")
    for w in warns:
        print(f"NOTE  {w}")
    if errors:
        print(f"\nFAIL: {len(errors)} problem(s)")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("\nPASS: grammar check found no problems")
    return 0

def main(paths):
    status = 0
    for path in paths:
        found = blocks_from(path)
        if not found:
            print(f"{path}: no mermaid block found")
            continue
        for i, (_, lines) in enumerate(found, start=1):
            print(f"--- {path} (mermaid block {i} of {len(found)}) ---")
            status |= check_block(lines)
            print()
    return status


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: check_mermaid.py <file.md|file.mmd> ...")
    sys.exit(main(sys.argv[1:]))
