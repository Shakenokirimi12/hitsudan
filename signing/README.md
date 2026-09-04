# Developer ID 証明書の発行

秘密鍵 `devid.key` と対応する CSR `devid.csr` は `~/.hitsudan/signing/` にあり、
ここ（リポジトリ）には**絶対に置かない**。同じ Mac 上で鍵を作って発行まで
完結できるので、CSR をリポジトリ経由で受け渡す必要はない。

## 使い方

1. https://developer.apple.com/account/resources/certificates/list
2. ＋ → **Developer ID Application**（Apple Development ではない）
3. `~/.hitsudan/signing/devid.csr` をアップロードして `.cer` をダウンロード
4. `~/.hitsudan/signing/` に保存し、鍵と結合して `.p12` を作る（`../README.md` の
   「署名と公証に必要な Secrets」参照）

鍵を紛失・失効させた場合は、この手順ごとやり直す（新しい CSR を作って再発行）。
