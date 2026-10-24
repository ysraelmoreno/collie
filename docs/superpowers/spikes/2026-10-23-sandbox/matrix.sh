#!/bin/zsh -f
# matrix.sh: Step 5 tool matrix + escape routes under probe.sb, fake home. Usage: zsh -f matrix.sh  (offline)
here=${0:A:h}; eval $($here/setup.sh); export SPIKE; S=$SPIKE; run=$here/sbrun.sh
nodebin=${$(whence -p node):h}
echo "## escapes"; sleep 600 & o=$!; (cd $S/repo && COLLIE_DIR=$S/collie $run . /bin/zsh -f $here/escapes.sh $o); kill $o
echo "## swift build (expect sandbox_apply failure)"; (cd $S/swiftpkg && $run . swift build 2>&1 | tail -3)
echo "## swift build --disable-sandbox"; (cd $S/swiftpkg && $run . swift build --disable-sandbox 2>&1 | tail -3)
echo "## npm i local tarball"; (cd $S/nodeproj && $run . /bin/zsh -fc "PATH=$nodebin:\$PATH npm i --offline --no-audit --no-fund $S/dep/tiny-dep-1.0.0.tgz" | tail -3)
echo "## python venv"; (cd $S/py && $run . /bin/zsh -fc 'python3 -m venv .venv && .venv/bin/pip --version' | tail -3)
echo "## git commit (repo)"; (cd $S/repo && $run . /bin/zsh -fc 'echo b>>a && git commit -qam c1 && git gc -q && git log --oneline|head -1')
echo "## git commit (worktree, .git is a file)"; (cd $S/wt && GITCOMMON=$S/repo/.git $run . /bin/zsh -fc 'echo c>>a && git commit -qam c2 && git log --oneline|head -1')
echo "## xcodebuild macOS"; (cd $S/swiftpkg && $run . xcodebuild -IDEPackageSupportDisableManifestSandbox=YES -scheme Hello -destination platform=macOS build 2>&1 | tail -4)
echo "## xcrun simctl list"; (cd $S/swiftpkg && $run . /bin/zsh -fc 'xcrun simctl list devices | tail -1')
kill $(cat $S/sockserver.pid); rm -rf $S
