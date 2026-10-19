# Contributing

## Commit messages

Commit messages are **English**, in the imperative present tense, following the
conventional-commit shape already used throughout the history:

```
type(scope): what the commit does, in one line, no trailing period

Why this commit exists, in the present tense. Wrap at ~80 columns.

Measurements, file paths and decisions belong here, not in the subject: numbers
("22 -> 3 processes"), the reason a shape was chosen over a plainer one, and the
trade-off it costs. Paths are written relative to the repository root.
```

- **Subject** — `type(scope): summary`, at most 72 columns, no trailing period.
  `type` is one of `feat` / `fix` / `perf` / `refactor` / `test` / `docs` / `chore`;
  `scope` names the module (`repo`, `attach`, `vcs`, `git`, `svn`, `signs`, `cli`,
  `actions`, `commands`, `loop`, `test`, ...). A breaking change keeps the `!` marker
  (`refactor(repo)!: ...`).
- **Body** — why, not what: the problem that prompted the commit, the shape chosen and
  what it was chosen over, the measurements that justify it, and anything a later reader
  would otherwise have to rediscover. Lists of findings (`F1`, `F2`, ...) and pointers to
  the governing decision or plan document (`D38`, `08 section 2.8`, a `loop/` path) are
  welcome.
- Keep every number, identifier, path and hash that the reasoning depends on. A
  translation or a rewrite of a message must not lose them.
- Do not mix unrelated changes in one commit: a `docs(...)` commit carries documentation,
  a `perf(...)` commit carries the code and its tests.

## Where the plans live

`loop/` is the planning and knowledge base (`loop/README.md` indexes it): `workspace/` is
unfinished work, `archive/` is finished iterations, `knowledge/` is the reusable facts
(git and svn output formats, libuv and `vim.system`, signs and extmarks, Lua traps,
headless testing). Read the knowledge documents before re-deriving a fact, and add to
them when a measurement contradicts the code or the docs.

## Before pushing

```
sh scripts/run_tests.sh          # the full suite must be green
deps/luacheck.exe .              # 0 warnings, 0 errors
deps/stylua.exe --check $(git ls-files 'lua/**/*.lua' 'test/*.lua' 'scripts/*.lua' 'plugin/*.lua')
```

The process-budget spec (`test/proc_budget_spec.lua`) is a regression gate: if a change
adds a subprocess to a path it covers, expect it to fail and say why in the commit
message.
