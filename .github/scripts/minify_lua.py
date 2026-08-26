#!/usr/bin/env python3
"""Strip comments and blank lines from Lua 5.1 sources.

Uses a real lexer rather than regexes: quoted strings, long-bracket strings
([[...]], [==[...]==]) and long comments all have to be tracked so that a
"--" inside a string is never mistaken for a comment.

Trailing whitespace is trimmed and blank lines dropped, but line structure is
otherwise preserved -- WoW reports Lua errors by line number, so keeping the
file line-oriented (rather than collapsing it) keeps stack traces readable.
"""

import sys


def _long_bracket(src, i):
	"""If src[i] opens a long bracket, return (level, index after it), else None."""
	if src[i] != '[':
		return None
	j = i + 1
	level = 0
	while j < len(src) and src[j] == '=':
		level += 1
		j += 1
	if j < len(src) and src[j] == '[':
		return level, j + 1
	return None


def _close_long_bracket(src, i, level):
	"""Index just past the closing bracket of the given level, or len(src)."""
	needle = ']' + '=' * level + ']'
	end = src.find(needle, i)
	return len(src) if end == -1 else end + len(needle)


def strip_comments(src):
	out = []
	i, n = 0, len(src)
	while i < n:
		c = src[i]

		# Comment: line or long form.
		if c == '-' and src.startswith('--', i):
			lb = _long_bracket(src, i + 2)
			if lb:
				level, body = lb
				end = _close_long_bracket(src, body, level)
				# Keep newlines so following code stays on its original line.
				out.append('\n' * src.count('\n', i, end))
				i = end
			else:
				end = src.find('\n', i)
				i = n if end == -1 else end
			continue

		# Quoted string: copy verbatim, honouring backslash escapes.
		if c in '"\'':
			j = i + 1
			while j < n:
				if src[j] == '\\':
					j += 2
					continue
				if src[j] == c:
					j += 1
					break
				if src[j] == '\n':  # unterminated; let Lua report it
					break
				j += 1
			out.append(src[i:j])
			i = j
			continue

		# Long string: copy verbatim.
		lb = _long_bracket(src, i)
		if lb:
			level, body = lb
			end = _close_long_bracket(src, body, level)
			out.append(src[i:end])
			i = end
			continue

		out.append(c)
		i += 1

	return ''.join(out)


def minify(src):
	stripped = strip_comments(src)
	lines = [line.rstrip() for line in stripped.split('\n')]
	kept = [line for line in lines if line.strip()]
	return '\n'.join(kept) + '\n' if kept else ''


def main(paths):
	for path in paths:
		with open(path, 'r', encoding='utf-8', errors='surrogateescape') as fh:
			src = fh.read()
		with open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='\n') as fh:
			fh.write(minify(src))
	return 0


if __name__ == '__main__':
	sys.exit(main(sys.argv[1:]))
