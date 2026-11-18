# nginx-docker-distroless

公式 nginx (Debian trixie) と設定互換のまま、シェル・パッケージマネージャを
含まない nginx イメージ。`gcr.io/distroless/base-debian13` に実行に必要な
ファイルだけを載せている。

- イメージ: `ghcr.io/nananek/nginx-docker-distroless`
- ビルド元: `nginx:stable-trixie`
- ランタイム: `gcr.io/distroless/base-debian13`
- master は root、worker は `nginx` (uid 101)
- アーキテクチャ: `linux/amd64`, `linux/arm64`, `linux/arm/v7`

## タグ

| タグ | 契機 |
|---|---|
| `nightly` | `main` への push、日次ビルド、workflow_dispatch |
| `nightly-YYYYMMDD` | `main` への push、日次ビルド |
| `nginx-<upstream version>` | すべてのビルド (例: `nginx-1.28.0`) |
| `sha-<7桁>` | すべてのビルド |
| `latest`, `X.Y.Z`, `X.Y` | `v*` タグ |

`nightly` は可変タグ。ベースはタグ (`nginx:stable-trixie`,
`gcr.io/distroless/base-debian13:latest`) で追従するので、日次ビルドで
新しい nginx / distroless を拾う。Renovate / Dependabot は使わない。

docker-server へ反映した時点の digest を nekono-operations の docs に記録する。
戻すときは `image: ...@sha256:...` で固定する。

## 使い方

compose の `image:` 行を差し替えるだけで、既存の nginx 設定をそのまま使える。

```yaml
services:
  viewer:
    image: ghcr.io/nananek/nginx-docker-distroless:nightly
    ports:
      - "8973:80"
    volumes:
      - ./lib-dist:/usr/share/nginx/html:ro
      - ./docker/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    restart: unless-stopped
```

前提として満たすもの:

- `user nginx;` を解決できる (passwd/group に uid 101 の nginx)
- `pid /run/nginx.pid` と `pid /var/run/nginx.pid` の両方が書ける
- `/var/cache/nginx` `/var/log/nginx` `/var/lib/nginx` は `101:101`
- `/etc/nginx/conf.d/*.conf` と `/etc/nginx/mime.types` を同梱
- access/error ログは公式イメージ同様 `/dev/stdout` `/dev/stderr` への symlink
- `resolver 127.0.0.11;` による Docker 組み込み DNS の名前解決が動く
  (`libnss_files` / `libnss_dns` を同梱)

## 公式イメージとの違い

そのまま置き換えられるが、次は非対応。

- `docker-entrypoint.sh` / `docker-entrypoint.d` / envsubst テンプレート
- `NGINX_ENVSUBST_*` などの公式 entrypoint 機能
- 非 root 既定 (`:nonroot`、listen 8080)
- Alpine/musl ベース、第三者モジュールの追加ビルド
- `docker exec ... sh -c ...`。shell がない。`docker exec` では実行ファイルを直接指定する
- `nginx -s reload` は pid ファイル経由なので使えるが、`kill -HUP` 以外のシェル操作はない

対象は設定を bind mount し、テンプレートを使わない構成に限る。

## ビルド

```sh
make image          # linux/amd64 を build
make test           # build + smoke test
make check          # scripts/*.sh の bash -n
```

直接 build する場合:

```sh
docker build --platform linux/amd64 -t nginx-distroless:dev .
docker run --rm \
  -v "$PWD/tests/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/tests/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  --entrypoint nginx nginx-distroless:dev -t
```

## smoke test

`scripts/smoke-test.sh` が次を確認する。

1. `nginx -t` (`user nginx;` と `pid /run/nginx.pid` を含む検証用 conf)
2. 起動して HTTP 200、master が uid 0、worker が uid 101
3. ユーザー定義ネットワーク上で `127.0.0.11` によるコンテナ名解決
4. `/bin/sh` `/bin/bash` `apt-get` `apk` が無いこと
5. イメージサイズを記録 (目安 30〜50MiB)

CI (`.github/workflows/nightly.yml`) は amd64 で build と smoke test を通した
あと、`linux/amd64,linux/arm64,linux/arm/v7` を provenance (`mode=max`) と
SBOM 付きで push する。PR トリガーは持たない。

## 設計メモ

- `/etc/passwd` と `/etc/group` は `rootfs/` の最小定義 (root / nginx / nonroot)。
  公式イメージのエントリを丸ごと持ち込まない。
- 共有ライブラリは `ldd` の結果から収集する。`/lib` と `/lib64` は `/usr` 配下に
  寄せ、`ld-linux` は distroless 側のものを使う。nginx も distroless も Debian 13
  なので glibc は一致する。
- `libnss_*` は dlopen されるため `ldd` では拾えない。明示的にコピーし、
  `/etc/nsswitch.conf` も最小定義を置く。
- `/run` と `/var/run` は実ディレクトリとして作る。distroless にはどちらも無い。
- `/var/log/nginx` は `--chown=101:101` でコピーする。COPY はディレクトリ内の
  symlink を symlink のまま持っていくので、`/dev/stdout` `/dev/stderr` への
  リンクが保たれる。
- `nginx` ユーザーは misskey-docker-compose の `nginx.conf` が `user nginx;` を
  使うため必須。
