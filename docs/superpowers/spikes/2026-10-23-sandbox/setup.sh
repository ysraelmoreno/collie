#!/bin/zsh -f
# setup.sh: fresh temp root with a FAKE home tree (fake secrets) and throwaway projects. Prints `export SPIKE=...`.
S=$(mktemp -d /tmp/sbspike.XXXX); S=${S:A}
h=$S/home; mkdir -p $h/.ssh $h/.aws $h/.config/gh $h/Documents $h/Library/Caches $h/collie-other $S/collie
echo key >$h/.ssh/id_ed25519; echo host >$h/.ssh/known_hosts; echo cfg >$h/.ssh/config; echo aws >$h/.aws/credentials
echo gh >$h/.config/gh/hosts.yml; echo doc >$h/Documents/doc.txt; echo m >$h/.netrc
printf '[user]\n\tname = Spike\n\temail = spike@example.invalid\n[init]\n\tdefaultBranch = main\n' >$h/.gitconfig
echo token >$S/collie/admin-token
# daemon socket stand-in + one other socket in the Collie dir
python3 ${0:A:h}/sockserver.py $S/collie >/dev/null 2>&1 </dev/null &
echo $! >$S/sockserver.pid
# projects
mkdir -p $S/swiftpkg/Sources/Hello && cd $S/swiftpkg && printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "Hello", targets: [.executableTarget(name: "Hello")])\n' >Package.swift && echo 'print("hi")' >Sources/Hello/main.swift
mkdir -p $S/dep $S/nodeproj && cd $S/dep && echo '{"name":"tiny-dep","version":"1.0.0","main":"i.js"}' >package.json && echo 'module.exports=1' >i.js && npm pack --silent >/dev/null
cd $S/nodeproj && echo '{"name":"nodeproj","version":"1.0.0"}' >package.json
mkdir -p $S/repo && cd $S/repo && HOME=$h git init -q && echo a >a && HOME=$h git add a && HOME=$h git commit -qm init && HOME=$h git worktree add -q $S/wt -b wt
mkdir -p $S/py
echo "export SPIKE=$S"
