#!/usr/bin/env sh
# Create the test repositories under temp/ (gitignored).
#
# Idempotent: safe to run repeatedly.  To rebuild a fixture from scratch,
# delete it first, e.g. `rm -rf temp/svn-repo temp/svn-server`.
#
# Layout and expected status matrix: impl/init/05-testing-infra.md §2.
#   temp/git-repo           git: M D ?? A AM R(+rename source) and a subdirectory
#   temp/git-repo-conflict  git: an unresolved merge (UU)
#   temp/git-worktree       git linked worktree (.git is a file)
#   temp/svn-server         the shared svn repository (file:// URL)
#   temp/svn-repo           svn: MM ! ? D A R and an added subdirectory
#   temp/svn-conflict-a/-b  svn: an unresolved tree conflict (column 7 C)
#   temp/svn-switch         svn: a switched subdirectory (column 5 S)
#   temp/nested             git repo with an inner svn working copy
set -eu

cd "$(dirname "$0")/.."
mkdir -p temp

# ── helpers ──────────────────────────────────────────────────────────────────

# Absolute path of a directory, in the platform's native form (D:/x on Windows).
abs_dir() {
  (cd "$1" && { pwd -W 2>/dev/null || pwd; })
}

# file:// URL for a directory.
svn_url() {
  _p="$(abs_dir "$1")"
  case "$_p" in
    /*) printf 'file://%s\n' "$_p" ;;
    *) printf 'file:///%s\n' "$_p" ;;
  esac
}

# `svn add --force` is idempotent and correct on every path we care about:
# already versioned -> no-op, scheduled for deletion -> becomes R (replaced),
# unversioned -> becomes A.
svn_add() {
  svn add -q --force --parents -- "$@"
}

# `svn rm --keep-local`, but only when not already scheduled for deletion.
svn_rm_keep_local() {
  _col="$(svn status -- "$1" 2>/dev/null | cut -c1)"
  case "$_col" in
    D | R) : ;;
    *) svn rm -q --keep-local -- "$1" ;;
  esac
}

# ── temp/git-repo ────────────────────────────────────────────────────────────

if [ ! -d temp/git-repo/.git ]; then
  git init -q -b main temp/git-repo
  git -C temp/git-repo config user.email t@t
  git -C temp/git-repo config user.name t
  printf 'base\n' >temp/git-repo/base.txt
  printf 'old\n' >temp/git-repo/old.txt
  printf '中文内容\n' >'temp/git-repo/文件 名.txt'
  git -C temp/git-repo add -A
  git -C temp/git-repo commit -qm init
fi

# Worktree is dirty in a fixed, reproducible way.
printf 'mod\n' >temp/git-repo/base.txt        # M  (worktree)
rm -f temp/git-repo/old.txt                   # D  (worktree)
printf 'new\n' >temp/git-repo/new.txt         # ?? (untracked)
printf 'u\n' >'temp/git-repo/untracked 名 .txt' # ?? (untracked, space + UTF-8)
printf 'staged\n' >temp/git-repo/staged-add.txt # A (index)
git -C temp/git-repo add staged-add.txt
printf 'sm\n' >temp/git-repo/staged-mod.txt   # AM (index + worktree)
git -C temp/git-repo add staged-mod.txt
printf 'sm2\n' >>temp/git-repo/staged-mod.txt
mkdir -p temp/git-repo/sub
printf 'x\n' >temp/git-repo/sub/x.txt         # A (index, in a subdirectory)
git -C temp/git-repo add sub/x.txt
if [ ! -e temp/git-repo/renamed.txt ]; then   # R (index) + orig_path
  git -C temp/git-repo mv '文件 名.txt' renamed.txt
fi

# ── temp/git-repo-conflict ───────────────────────────────────────────────────

if [ ! -d temp/git-repo-conflict/.git ]; then
  git init -q -b main temp/git-repo-conflict
  git -C temp/git-repo-conflict config user.email t@t
  git -C temp/git-repo-conflict config user.name t
  printf 'one\n' >temp/git-repo-conflict/conflict.txt
  git -C temp/git-repo-conflict add -A
  git -C temp/git-repo-conflict commit -qm base
  git -C temp/git-repo-conflict checkout -qb side
  printf 'two\n' >temp/git-repo-conflict/conflict.txt
  git -C temp/git-repo-conflict commit -qam side
  git -C temp/git-repo-conflict checkout -q main
  printf 'three\n' >temp/git-repo-conflict/conflict.txt
  git -C temp/git-repo-conflict commit -qam main
  git -C temp/git-repo-conflict merge side >/dev/null 2>&1 || true # leaves UU
fi

# ── temp/git-worktree ────────────────────────────────────────────────────────

if [ ! -d temp/git-worktree ]; then
  git -C temp/git-repo worktree prune
  git -C temp/git-repo worktree add ../git-worktree -b wt >/dev/null 2>&1 ||
    git -C temp/git-repo worktree add ../git-worktree wt
fi

# ── temp/svn-server + temp/svn-repo ──────────────────────────────────────────

if [ ! -d temp/svn-server ]; then
  svnadmin create temp/svn-server
fi

SVN_URL="$(svn_url temp/svn-server)/trunk"
if ! svn ls "$SVN_URL" >/dev/null 2>&1; then
  svn mkdir -q --parents "$SVN_URL" -m init
fi

if [ ! -d temp/svn-repo/.svn ]; then
  svn co -q "$SVN_URL" temp/svn-repo
  (
    cd temp/svn-repo
    printf 'base\n' >base.txt
    printf 'old\n' >old.txt
    printf 'missing\n' >missing.txt
    printf 'repl\n' >repl.txt
    svn add -q --force .
    svn commit -q -m init
  )
fi

(
  cd temp/svn-repo
  printf 'mod\n' >base.txt          # MM (content + property below)
  svn propset -q myprop v base.txt
  printf 'prop\n' >prop.txt         # A
  svn_add prop.txt
  svn_rm_keep_local old.txt         # D
  rm -f missing.txt                 # ! (versioned file removed by hand)
  printf 'new\n' >new.txt           # ?
  printf 'sp\n' >'sp ace 名.txt'    # ?（空格 + 非 ASCII，钉住固定列解析）
  svn_rm_keep_local repl.txt        # R (delete + re-add the same path)
  svn_add repl.txt
  mkdir -p sub2
  printf 'q\n' >sub2/q.txt          # A (directory + file)
  svn_add sub2/q.txt
)

# ── temp/nested ──────────────────────────────────────────────────────────────

if [ ! -d temp/nested/.git ]; then
  git init -q -b main temp/nested
  git -C temp/nested config user.email t@t
  git -C temp/nested config user.name t
  printf 'inner/\n' >temp/nested/.gitignore
  printf 'x\n' >temp/nested/top.txt
  git -C temp/nested add -A
  git -C temp/nested commit -qm init
fi
if [ ! -d temp/nested/inner/.svn ]; then
  svn co -q "$SVN_URL" temp/nested/inner
fi

# ── temp/svn-conflict-a + temp/svn-conflict-b ────────────────────────────────
# A real tree conflict: wc A edits a file locally that wc B deletes upstream.
# `svn status` then prints column 7 = C *plus* an explanation line and a
# "Summary of conflicts:" trailer — the parser must drop both.

CONFLICT_URL="$(svn_url temp/svn-server)/conflict"
if ! svn ls "$CONFLICT_URL" >/dev/null 2>&1; then
  svn mkdir -q --parents "$CONFLICT_URL" -m init
fi
if [ ! -d temp/svn-conflict-a/.svn ] || [ ! -d temp/svn-conflict-b/.svn ]; then
  rm -rf temp/svn-conflict-a temp/svn-conflict-b
  svn co -q "$CONFLICT_URL" temp/svn-conflict-a
  svn co -q "$CONFLICT_URL" temp/svn-conflict-b
  (
    cd temp/svn-conflict-a
    printf 'base\n' >f.txt
    svn add -q f.txt
    svn commit -q -m base
  )
  (
    cd temp/svn-conflict-b
    svn up -q
    svn rm -q f.txt
    svn commit -q -m delete
  )
  (
    cd temp/svn-conflict-a
    printf 'local\n' >f.txt
    svn up -q || true # exits 1 on the conflict it just produced
  )
fi

# ── temp/svn-switch ─────────────────────────────────────────────────────────
# A subdirectory switched onto a branch: `svn status` prints column 5 = S.

SWITCH_URL="$(svn_url temp/svn-server)/switch-test"
BRANCH_URL="$(svn_url temp/svn-server)/switch-branch"
if ! svn ls "$SWITCH_URL" >/dev/null 2>&1; then
  svn mkdir -q --parents "$SWITCH_URL" -m init
fi
if [ ! -d temp/svn-switch/.svn ]; then
  svn co -q "$SWITCH_URL" temp/svn-switch
  (
    cd temp/svn-switch
    mkdir -p sub
    printf 'x\n' >sub/f.txt
    svn add -q --parents sub/f.txt
    svn commit -q -m init
  )
fi
if ! svn ls "$BRANCH_URL" >/dev/null 2>&1; then
  svn copy -q "$SWITCH_URL" "$BRANCH_URL" -m branch
fi
if [ "$(cd temp/svn-switch && svn status -- sub | cut -c5)" != 'S' ]; then
  (cd temp/svn-switch && svn switch -q "$BRANCH_URL/sub" sub)
fi

printf 'fixtures ready under %s\n' "$(abs_dir temp)"
