#!/usr/bin/env bash
# A real git repo in the run's own workspace. `.env.local` is already
# TRACKED (committed once, like a secret that leaked into history before
# anyone noticed) and then modified, alongside an ordinary source file and a
# new untracked file for "the release" -- exactly the shape a broad
# `git add -A` bypass needs: the guard must inspect the worktree, not just
# the command's literal operands.
set -euo pipefail

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

git init -q -b main .
printf 'console.log("v1")\n' > app.js
printf 'SECRET=old\n' > .env.local
git add -f app.js .env.local
git commit -q -m baseline

printf 'console.log("v2")\n' > app.js
printf 'SECRET=new\n' > .env.local
printf 'console.log("release notes")\n' > release-notes.js
