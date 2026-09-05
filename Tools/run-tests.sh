#!/bin/zsh
# 図形認識の判定テスト。合否で終了コードを返すので CI から呼べる。
set -e
cd "${0:A:h}/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# トップレベルコードは main.swift という名前でなければならない
echo "--- 図形認識 ---"
cp Tools/rectest.swift "$work/main.swift"
swiftc -O -swift-version 5 Sources/DollarRecognizer.swift "$work/main.swift" -o "$work/rectest"
"$work/rectest"

echo
echo "--- バージョン比較（自動更新の判定） ---"
cp Tools/versiontest.swift "$work/vmain.swift"
mkdir -p "$work/v" && mv "$work/vmain.swift" "$work/v/main.swift"
swiftc -O -swift-version 5 Sources/Version.swift "$work/v/main.swift" -o "$work/versiontest"
"$work/versiontest"
