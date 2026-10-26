# Image pins

All 13 images are pinned by digest in `helm/robot-shop/values-phase1.yaml`
(decision D7). Rendered references look like:

```
robotshop/rs-web:latest@sha256:b3c20d4a22f2875397726d2184062360bb2ab9c8776beffca7c2e7b3652893bc
```

The tag is kept for readability in `kubectl describe pod`; the digest is the
authoritative selector, so a re-pushed `:latest` cannot silently change what runs.

**Resolved:** 2026-10-26
**Source:** `docker image inspect <ref> --format '{{index .RepoDigests 0}}'` after
a successful pull, so each digest is the manifest that was actually loaded into
the Kind nodes — not a separately queried value that could differ.

| Image | Digest |
| --- | --- |
| `robotshop/rs-web:latest` | `sha256:b3c20d4a22f2875397726d2184062360bb2ab9c8776beffca7c2e7b3652893bc` |
| `robotshop/rs-catalogue:latest` | `sha256:d545747c1b97cd2e0f41221291cd2f66781bceabaab2cfd42a7be4b8c2f3ba62` |
| `robotshop/rs-cart:latest` | `sha256:388349d5cb3ccc14a192c345bfd42596920737db35d6a03a27457f6682710a37` |
| `robotshop/rs-payment:latest` | `sha256:774b52c6180d8f3273f77230d70ace9c45e1f8909e21e10a19ed83b1cec53bb3` |
| `robotshop/rs-user:latest` | `sha256:ea509182c180d20340a9427d8320f35085effdb4ed77b15275022d17bdd1fcf7` |
| `robotshop/rs-shipping:latest` | `sha256:89753ab489193286402c9486379da63c18a21d697b4fbd41246b68aacabfc6d3` |
| `robotshop/rs-ratings:latest` | `sha256:4899c686c249464783663342620425dc8c75a5d59ca55c247cf6aec62a5fff1a` |
| `robotshop/rs-dispatch:latest` | `sha256:de81f1d07b021f24c1cc66fef6aa27f9a5456f08b0c081dfb4cc71027ff67ead` |
| `robotshop/rs-mongodb:latest` | `sha256:119b545823cdce33a1d6cee87fdfed1cef82e680824ad0b49603be4aeb4e821e` |
| `robotshop/rs-mysql-db:latest` | `sha256:2355f9700d771f4326169d7d370ad1824d2d410876036f77342d9663d80f893b` |
| `robotshop/rs-load:latest` | `sha256:4041f38cb4d4c0263246dc4ceec493c5cd88e3be32b3292bd4960a1bceb8bd0e` |
| `redis:4.0.6` | `sha256:0e773022cd6572a5153e5013afced0f7191652d3cdf9b1c6785eb13f6b2974b1` |
| `rabbitmq:3.7-management-alpine` | `sha256:e97f6bb68aab3f747f8a6f4dc52ed57401de91ca480a0be3a36e7476ac273169` |

## Why pre-loading needs two steps

`kind load docker-image` stores an image under its **tag** only. A pod spec that
pins by digest asks containerd for a digest-qualified name
(`repo@sha256:...`), which is a different key in the image store — so the kubelet
would ignore the local copy and pull from Docker Hub, defeating the pre-load and
exposing the install to the same flaky DNS that plagues this workstation.

`scripts/load-images.ps1` therefore loads each image and then re-tags it by
digest inside containerd on every node:

```
ctr -n k8s.io images tag docker.io/robotshop/rs-web:latest \
    docker.io/robotshop/rs-web@sha256:b3c20...
```

## Refreshing the pins

```powershell
powershell -NoProfile -File scripts/pull-images.ps1   # retries through DNS hiccups
powershell -NoProfile -File scripts/load-images.ps1   # load + digest-tag every node
bash scripts/verify-render.sh                         # asserts 13 pinned references
```

Then update this table and the `digests` map together. If only one is updated,
`verify-render.sh` still passes — so treat the table as the human record and the
values file as the source of truth.
