# devid.csr — 一時的な受け渡し用

Developer ID 証明書を発行するための署名要求。**中身は公開鍵と名前だけで、秘密鍵は
含まれていない**ので、このリポジトリに置いても資格情報の漏洩にはならない。

置いてある理由は、証明書の発行を別の Mac のブラウザから行うため。AirDrop が
使えない環境での受け渡し経路として git を使っている。

## 使い方

1. https://developer.apple.com/account/resources/certificates/list
2. ＋ → **Developer ID Application**（Apple Development ではない）
3. このファイルをアップロードして `.cer` をダウンロード

## 使い終わったら消すこと

用が済んだら削除する。CSR にはメールアドレスが入っているので、万一リポジトリを
公開する場合に残しておく理由がない。

```sh
git rm signing/devid.csr && git commit -m "使い終わった CSR を削除" && git push
```

秘密鍵 `devid.key` は `~/.hitsudan/signing/` にあり、ここには**絶対に置かない**。
