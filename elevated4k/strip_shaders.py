#!/usr/bin/env python3
"""Strip comments and fully minimize whitespace in MSL for embedding as a C string.

Uses a tokenizer instead of line-by-line regexes so every unnecessary space is
removed, including around operators whose operands start with '.' (e.g. + .1).
"""
import re
import sys

# ── Tokenizer ─────────────────────────────────────────────────────────────────
# Order matters: longer/more-specific patterns must come first.
_TOK = re.compile(r"""
    (?P<id>   [A-Za-z_]\w*                                   ) |
    (?P<num>  0[xX][0-9A-Fa-f]+[uUlL]*                      |   # hex
              \d*\.\d+(?:[eE][+-]?\d+)?[fFhHuU]?            |   # .5, 0.5, 1.5f
              \d+\.(?:[eE][+-]?\d+)?[fFhHuU]?               |   # 1., 1.f
              \d+[fFhHuU]?                                   ) | # 1, 1u
    (?P<attr> \[\[|\]\]                                      ) | # Metal [[ ]]
    (?P<op>   [-+*/%&|^~!<>=]=?|&&|\|\||<<|>>|--|
              \+\+|->|::                                     ) |
    (?P<pun>  [(){}\[\].,;?:]                                ) |
    (?P<ws>   \s+                                            )
""", re.VERBOSE)


def _shrink_num(tok):
    """1.0 → 1.   1.50 → 1.5   0.5 → .5"""
    # strip trailing decimal zeros (keep the dot): 1.50f → 1.5f, 1.0 → 1.
    tok = re.sub(
        r"(\d)\.(\d*?)0+([fFhHuU]?)$",
        lambda m: m.group(1) + "." + m.group(2) + m.group(3),
        tok,
    )
    # remove leading zero on plain decimal fractions: 0.5 → .5
    # (negative lookbehind prevents matching inside hex or larger integers)
    tok = re.sub(r"(?<![0-9A-Fa-fx])0(\.\d)", r"\1", tok)
    return tok


def _word(ch):
    return ch.isalnum() or ch == "_"


def minify(src):
    # strip block comments, then line comments
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.DOTALL)
    src = re.sub(r"//[^\n]*", "", src)

    out = []
    last_ch = ""

    for raw in src.splitlines():
        s = raw.strip()
        if not s:
            continue
        if s.startswith("#"):
            # preprocessor directive: normalize internal whitespace, keep newline
            out.append(" ".join(s.split()) + "\n")
            last_ch = ""
            continue

        for m in _TOK.finditer(raw):
            if m.lastgroup == "ws":
                continue
            tok = m.group(0)
            if m.lastgroup == "num":
                tok = _shrink_num(tok)
            # insert a space only when both adjacent chars are word-like,
            # otherwise merging would create a new (wrong) identifier/keyword
            if last_ch and _word(last_ch) and _word(tok[0]):
                out.append(" ")
            out.append(tok)
            last_ch = tok[-1]

    return "".join(out)


def emit_c_string(text, width=96):
    for line in text.splitlines(True):
        nl = line.endswith("\n")
        line = line.rstrip("\n")
        esc = line.replace("\\", "\\\\").replace('"', '\\"')
        while esc:
            chunk, esc = esc[:width], esc[width:]
            suffix = "\\n" if nl and not esc else ""
            print(f'    "{chunk}{suffix}"')


emit_c_string(minify(open(sys.argv[1]).read()))
