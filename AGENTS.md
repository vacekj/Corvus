# Project workflow

## Feature completion

A feature is not complete until its changes are verified, squash-merged into `main`, installed locally, and its task worktree and branch are cleaned up. Do not stop at an uncommitted worktree or leave the installed app on an older build.

1. Implement in a dedicated task branch and worktree. Preserve unrelated changes and other tasks' branches and worktrees.
2. Run focused checks for the changed behavior and exercise the actual app surface.
3. Squash-merge the completed feature into the current `main`, producing one feature commit. Resolve integration conflicts and run any checks affected by integration before proceeding. Respect required reviews, repository protections, and higher-priority merge rules; never bypass them to finish automatically.
4. Build and reinstall the latest integrated application, then launch the installed copy and smoke-test the feature. On macOS, use `macos/scripts/build-app.sh` to build `macos/build/Corvus.app`, replace `/Applications/Corvus.app`, and launch that installed bundle. Quit the previous instance gracefully before replacement; preserve chat history, credentials, settings, and other user data. A preview or a binary running from the worktree does not count as reinstallation.
5. After successful integration, reinstallation, and smoke verification, move the session to the main checkout and remove this task's worktree and branch. Use the session-move workflow and wait for relocation before removing its former directory. With a squash merge, confirm the feature's changes are present in `main`; commit ancestry alone cannot prove integration. Keep any requested screenshots or evidence outside the worktree before deleting it. Never discard unmerged changes or remove another task's worktree or branch.

Apply the reinstall requirement after every completed app change, including bug fixes: the installed app must match the latest verified, integrated source rather than an earlier release or task build.

If review, permissions, integration conflicts, installation, or smoke verification blocks completion, finish all reachable work, retain the task branch and worktree, and report the exact blocker. Do not claim the feature is merged, installed, or cleaned up unless those steps actually succeeded.
