#!/usr/bin/env bash
# Build a throwaway git sandbox for hand-testing the VCS view (docs/testing/vcs_manual.md).
#
#   scripts/vcs_sandbox.sh [DIR]      (default /tmp/ches-vcs-sandbox; DIR is wiped)
#
# Leaves:
#   DIR/remote.git   a bare "origin"
#   DIR/other        a second clone, used to push a commit main does not have
#   DIR/work         the repository to open in Ches, on main, with:
#     - history: v1 tag, a --no-ff merge of `feature`, a rename (old_name.txt ->
#       new_name.txt, then edited), a binary file, 210 "Counter" commits (> 200)
#     - branches: feature (merged), conflict-me (conflicts with main on a.txt and
#       deletes src/main.ml, which main modified), doomed (to delete by hand)
#     - main is 1 ahead / 1 behind origin/main after a fetch (both edit a.txt line 1)
#     - a dirty work tree: a.txt edited in two far-apart places (two hunks),
#       src/main.ml staged, notes.txt untracked
set -euo pipefail

S=${1:-/tmp/ches-vcs-sandbox}
case "$S" in
  / | "$HOME" | "$HOME"/) echo "refusing to wipe $S" >&2; exit 1 ;;
esac
rm -rf "$S"
mkdir -p "$S"
cd "$S"

# Deterministic for this script's own commands; Ches later uses your normal config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
id() {
  git config user.name "Ches Sandbox"
  git config user.email "sandbox@example.invalid"
  git config commit.gpgSign false
}

git init -q --bare -b main remote.git
git init -q -b main work
cd work
id
git remote add origin ../remote.git

seq -f 'line %g' 1 30 > a.txt
printf 'hello\n' > old_name.txt
mkdir src
printf 'let x = 1\n' > src/main.ml
git add -A
git commit -qm "Initial commit"
git tag v1

git branch conflict-me
git branch doomed

git switch -qc feature
sed -i 's/^line 15$/line 15 (feature)/' a.txt
git commit -qam "Feature: edit line 15 of a.txt"
echo "more" > feature.txt
git add feature.txt
git commit -qm "Feature: add feature.txt"

git switch -q main
sed -i 's/^line 30$/line 30 (main)/' a.txt
git commit -qam "Main: edit line 30"
printf 'let x = 2\n' > src/main.ml
git commit -qam "Main: edit src/main.ml"
git merge -q --no-ff feature -m "Merge branch 'feature'"

git mv old_name.txt new_name.txt
echo "world" >> new_name.txt
git commit -qam "Rename old_name.txt to new_name.txt and edit it"
echo "again" >> new_name.txt
git commit -qam "Edit new_name.txt"

head -c 64 /dev/urandom > logo.bin
git add logo.bin
git commit -qm "Add a binary file"

for i in $(seq 1 210); do
  echo "$i" > counter.txt
  git add counter.txt
  git commit -qm "Counter $i"
done
git push -qu origin main
git push -q origin feature v1

git switch -q conflict-me
sed -i 's/^line 30$/line 30 (conflict-me)/' a.txt
git rm -q src/main.ml
git commit -qam "conflict-me: edit line 30, delete src/main.ml"
git switch -q main

# Diverge from origin: one commit there, one here, both on a.txt line 1.
cd "$S"
git clone -q remote.git other
cd other
id
sed -i 's/^line 1$/line 1 (from origin)/' a.txt
git commit -qam "Upstream: edit line 1"
git push -q origin main
cd "$S/work"
sed -i 's/^line 1$/line 1 (local)/' a.txt
git commit -qam "Local: edit line 1"

# Dirty work tree.
sed -i 's/^line 5$/line 5 changed/; s/^line 6$/line 6 changed/' a.txt
sed -i 's/^line 25$/line 25 changed/' a.txt
printf 'let x = 3\n' > src/main.ml
git add src/main.ml
echo "scratch" > notes.txt

echo "Sandbox ready: $S/work"
git status --short
