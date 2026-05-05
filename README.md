# Elastic Airgapped

[![License](https://img.shields.io/github/license/jamesagarside/elastic-airgapped)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/jamesagarside/elastic-airgapped)](https://github.com/jamesagarside/elastic-airgapped/releases/latest)
[![GitHub stars](https://img.shields.io/github/stars/jamesagarside/elastic-airgapped?style=social)](https://github.com/jamesagarside/elastic-airgapped/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/jamesagarside/elastic-airgapped)](https://github.com/jamesagarside/elastic-airgapped/commits)
[![Elastic Stack](https://img.shields.io/badge/Elastic-9.3.4-005571?logo=elastic&logoColor=white)](https://www.elastic.co/)
[![ECK](https://img.shields.io/badge/ECK-Cloud_on_Kubernetes-005571?logo=elastic&logoColor=white)](https://www.elastic.co/guide/en/cloud-on-k8s/current/index.html)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Docker Desktop](https://img.shields.io/badge/Docker%20Desktop-2496ED?logo=docker&logoColor=white)](https://www.docker.com/products/docker-desktop/)

**A fully air-gapped Elastic Stack lab: deploy Elasticsearch, Kibana, Fleet, Logstash, and Maps on Docker Desktop Kubernetes with zero internet required at run time.**

Elastic Airgapped is a single-laptop lab for engineers who need the full Elastic Stack offline: demos on a plane, field work without connectivity, secure-environment testing, or just a reproducible local cluster that does not reach out to the internet once deployed. Pull every asset once — images, Helm charts, Elastic Cloud on Kubernetes (ECK) manifests, GeoIP databases, ML models, and the Fleet package registry — then deploy and run with the network off.

---

## Table of Contents

- [Why Elastic Airgapped?](#why-elastic-airgapped)
- [Features](#features)
- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Pull Assets While Online](#pull-assets-while-online)
- [Deploy Offline](#deploy-offline)
- [License Tiers](#license-tiers-trial--basic--enterprise)
- [Access the Stack](#access-the-stack)
- [Makefile Reference](#makefile-reference)
- [Project Structure](#project-structure)
- [Architecture](#architecture)
- [Air-gap Considerations](#air-gap-considerations)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)

---

## Why Elastic Airgapped?

Running Elasticsearch locally is easy; running the **full** stack without internet is not. Fleet, integrations, ML models, GeoIP databases, and the ECK operator all reach out to `elastic.co` endpoints by default. A real air-gapped lab has to cache every one of those dependencies and rewire the cluster to use the local copies.

This project does all of that for you with a single `make pull-all` while you are online, then lets you run the stack end-to-end while offline.

**Who this is for:** solutions engineers preparing offline demos, security teams validating Elastic in disconnected environments, developers on unreliable connectivity, and anyone who wants a reproducible, self-contained local Elastic cluster.

## Features

- **Full stack**: Elasticsearch (with ML node), Kibana, Fleet Server, Elastic Agent, Logstash, Elastic Maps Server.
- **True air-gap**: GeoIP auto-download disabled, local Elastic Package Registry (EPR) for Fleet integrations, pre-cached ML models (ELSER).
- **ECK-managed**: Elastic Cloud on Kubernetes operator handles lifecycle, upgrades, certificates, and cluster bootstrapping.
- **Docker Desktop Kubernetes**: no extra cluster to manage — uses the Kubernetes that ships with Docker Desktop for Mac or Windows.
- **License aware**: switch between **Trial**, **Basic**, and **Enterprise** tiers with a single `.env` variable. Enterprise accepts a license JSON file.
- **One-command deploy**: `make deploy` provisions namespaces, installs the ECK operator, activates your license, and rolls out the stack.
- **One-command cleanup**: `make clean-all` removes the stack, the operator, the ingress controller, and leaves your Docker daemon otherwise untouched.
- **Portable image cache**: `make save-images` writes every required container image to `assets/images/*.tar` so the asset bundle can be transported to another machine.
- **Ingress + TLS**: ingress-nginx with `*.localhost` hostnames that resolve without touching `/etc/hosts` on Chrome and Firefox. Safari gets a `make add-hosts` helper.
- **Optional local LLM**: LM Studio is started, loaded, and stopped by `make deploy` / `make clean-all`, and a pre-wired Kibana AI Connector targets it on the host — so the Kibana AI Assistant works with a private model and no internet, with the same lifecycle commands as the rest of the stack.

---

## Quick Start

Docker Desktop installed and Kubernetes enabled? Run:

```bash
# 1. Clone
git clone https://github.com/jamesagarside/elastic-airgapped.git
cd elastic-airgapped

# 2. Copy the env template
cp .env.example .env

# 3. (Online) Cache every dependency
make pull-all

# 4. (Offline is fine now) Deploy
make deploy

# 5. Add /etc/hosts entries for Safari (Chrome/Firefox skip this)
make add-hosts

# 6. Open
open https://kibana.localhost
```

Username: `elastic`. Password: retrieve with `kubectl get secret elastic-lab-es-elastic-user -n elastic -o go-template='{{.data.elastic | base64decode}}'`.

---

## Prerequisites

You need:

- **Docker Desktop** (macOS, Windows, or Linux) with **Kubernetes enabled**.
- **At least 12 GB of RAM allocated to Docker Desktop** (Settings -> Resources). Elasticsearch's ML node alone asks for 4 GB.
- **`containerd` image store enabled** in Docker Desktop (Settings -> General -> *Use containerd for pulling and storing images*). Without it, you also need `kind` installed and must run `make load-images` after `make pull-images`.
- **`kubectl`** on `PATH`.
- **Homebrew** (macOS) — `make check-tools` will install `helm` and `gettext` if they are missing.
- **Internet** for the initial `make pull-all` only. Everything after that runs offline.

Verify your environment:

```bash
make check-env
make show-config
```

---

## Pull Assets While Online

One command downloads every asset the stack needs at run time:

```bash
make pull-all
```

This runs in sequence:

| Step | What it pulls | Destination |
| ---- | ------------- | ----------- |
| `pull-assets` | ECK CRDs + operator YAML, ingress-nginx Helm chart | `assets/eck/`, `assets/charts/` |
| `pull-geoip` | GeoLite2 City / Country / ASN `.mmdb` databases | `assets/geoip/` |
| `pull-ml-models` | ELSER v2 tokenizer + model weights | `assets/ml-models/` |
| `pull-epr` | Elastic Package Registry distribution image | local Docker daemon |
| `pull-images` | All stack images: Elasticsearch, Kibana, Agent, Logstash, Maps, ECK operator, ingress-nginx | local Docker daemon |

**Want a portable bundle** (for moving to a different offline machine)?

```bash
make save-images      # writes assets/images/*.tar
```

Then transport the whole `assets/` directory to the target machine and run `make load-images-tarball` before `make deploy`.

Verify the cache before disconnecting:

```bash
make verify-offline
```

---

## Deploy Offline

```bash
make deploy
```

`make deploy` will:

1. Validate `.env` (including license tier).
2. Install the ECK operator from `assets/eck/`.
3. Apply the license you selected in `.env` (Trial, Basic, or Enterprise).
4. Install ingress-nginx from the local Helm chart.
5. Start LM Studio on the host and load `LLM_CONNECTOR_MODEL` (skipped if that variable is empty in `.env`; LM Studio is installed via Homebrew if not already present).
6. Apply every manifest under `manifests/`, substituting `.env` values via `envsubst`.
7. Wait for Elasticsearch to report `health: green`.

---

## License Tiers (Trial / Basic / Enterprise)

Set the license tier in `.env`:

```bash
# One of: trial | basic | enterprise
ECK_LICENSE_TIER=trial
# Only used when ECK_LICENSE_TIER=enterprise
ECK_LICENSE_FILE=/path/to/eck-enterprise-license.json
```

| Tier | What you get | How it is applied |
| ---- | ------------ | ----------------- |
| **trial** | 30 days of Enterprise features (ML, alerts, AI Assistant, etc.). Can be started **once per cluster**. | `kubectl apply` of a Secret labelled `license.k8s.elastic.co/type: enterprise_trial`. |
| **basic** | Free tier. No action required. Any existing trial/enterprise secret is removed. | `kubectl delete secret eck-trial-license eck-license` in the ECK namespace. |
| **enterprise** | Full, paid Enterprise features. | `kubectl create secret generic eck-license --from-file=<LICENSE_FILE>` with `license.k8s.elastic.co/scope=operator`. |

Apply the license independently of `make deploy`:

```bash
make apply-license     # applies per ECK_LICENSE_TIER
make check-license     # shows current license secret + elastic-licensing ConfigMap
make clean-license     # removes all license secrets (reverts to basic)
```

See the [official ECK licensing docs](https://www.elastic.co/docs/deploy-manage/license/manage-your-license-in-eck) for the source material.

---

## Access the Stack

Default hostnames (set in `.env`):

| Service | URL | Notes |
| ------- | --- | ----- |
| Kibana  | `https://kibana.localhost` | main UI |
| Elasticsearch | `https://elasticsearch.localhost` | REST API |

Get the `elastic` user password:

```bash
kubectl get secret elastic-lab-es-elastic-user \
  -n elastic \
  -o go-template='{{.data.elastic | base64decode}}'
```

Tail operator or stack logs:

```bash
kubectl -n elastic-system logs -l control-plane=elastic-operator -f
kubectl -n elastic get elasticsearch,kibana,agent,logstash,elasticmapsserver
```

---

## Makefile Reference

```
make help                   # list every target

# Online, one-time
make pull-all               # assets + images + GeoIP + ML models + EPR
make save-images            # export images to assets/images/*.tar (for portability)

# Offline
make deploy                 # full deploy (ECK -> license -> ingress -> LLM -> stack)
make apply-license          # re-apply license per .env
make add-hosts              # /etc/hosts entries for Safari

# Local LLM (optional, host-side via LM Studio)
make check-lms              # ensure the lms CLI is installed (installs LM Studio via Homebrew if missing)
make start-llm              # start LM Studio server and load $LLM_CONNECTOR_MODEL
make check-llm              # probe the endpoint and confirm the model is loaded
make stop-llm               # unload models and stop the LM Studio server

# Inspect
make show-config            # pretty-print resolved .env
make check-env              # validate .env
make diff-env               # .env vs .env.example
make verify-offline         # are all asset caches present?
make check-license          # current license state

# Teardown
make clean-elastic          # remove stack (keeps ECK operator)
make clean-ingress          # remove ingress-nginx
make clean-eck              # remove ECK operator + CRDs
make clean-all              # all of the above + stop LM Studio
```

---

## Project Structure

```text
elastic-airgapped/
├── .env.example                    # config template
├── Makefile                        # every workflow lives here
├── manifests/                      # Kubernetes manifests (envsubst-templated)
│   ├── elasticsearch.yaml
│   ├── kibana.yaml
│   ├── fleet-server.yaml
│   ├── agent.yaml
│   ├── logstash.yaml
│   ├── maps-server.yaml
│   ├── package-registry.yaml       # local EPR (air-gapped Fleet integrations)
│   ├── ingress.yaml
│   └── network-policy.yaml
├── assets/                         # populated by `make pull-all` (gitignored)
│   ├── eck/                        # CRDs + operator.yaml
│   ├── charts/                     # ingress-nginx helm chart (.tgz)
│   ├── images/                     # optional: `make save-images` tarballs
│   ├── geoip/                      # GeoLite2 .mmdb files
│   └── ml-models/                  # ELSER model artefacts
└── .github/workflows/              # CI, Pages, release tracking
```

---

## Architecture

- **Orchestration**: ECK operator in `elastic-system` watches the custom resources (`Elasticsearch`, `Kibana`, `Agent`, `Logstash`, `ElasticMapsServer`) in the `elastic` namespace and reconciles them.
- **Ingress**: ingress-nginx terminates HTTPS for `kibana.localhost` and `elasticsearch.localhost`, routing through the cluster to the stack services.
- **Fleet**: Fleet Server runs as an ECK-managed `Agent` with `fleetServerEnabled: true`. A single ingest Agent enrols against it.
- **Package Registry**: a local `distribution:lite` EPR is deployed inside the cluster; Kibana is configured with `xpack.fleet.registryUrl` pointing at the in-cluster Service, so Fleet integrations install without reaching `epr.elastic.co`.
- **GeoIP**: `ingest.geoip.downloader.enabled: false` is set in the Elasticsearch config, and the `make pull-geoip` target downloads GeoLite2 databases into `assets/geoip/` for optional upload via the GeoIP processor API.
- **ML models**: ELSER model artefacts are cached in `assets/ml-models/` and can be uploaded to the ML node once the cluster is up.
- **LLM (optional)**: a Kibana AI Connector is wired to an OpenAI-compatible endpoint on the host (LM Studio by default) via `host.docker.internal`. Apple Silicon's GPU is not visible to Docker Desktop's Kubernetes VM, so the model stays on the host (Metal/MLX) while `make deploy` / `make clean-all` drive its lifecycle through the `lms` CLI — keeping the cluster reproducible and the inference fast. Fully offline and private.

---

## Air-gap Considerations

What "air-gapped" actually means here:

| Concern | Status |
| ------- | ------ |
| Container images | Pulled to local Docker daemon; optionally saved to tarball for portability. |
| ECK operator manifests + CRDs | Cached in `assets/eck/`. |
| Ingress Helm chart | Cached in `assets/charts/`. |
| GeoIP auto-download | Disabled in Elasticsearch config. Databases cached in `assets/geoip/` for optional manual upload. |
| Fleet integrations | Served by a local Elastic Package Registry deployed inside the cluster. |
| ML models (ELSER) | Cached in `assets/ml-models/` and uploadable via the ML trained-models API. |
| Detection rule updates | Auto-updates are an internet call; disable in Kibana or ignore on an offline lab. |
| Endpoint artefact updates | Same — manual or disabled. |
| Enterprise license | User-supplied JSON, applied as a Kubernetes Secret. |

---

## Troubleshooting

### Pods stuck Pending

```bash
kubectl describe pod -n elastic <pod>
```

Usually means Docker Desktop has not allocated enough memory. Bump it in Settings -> Resources.

### ImagePullBackOff

```bash
kubectl get events -n elastic --sort-by=.lastTimestamp | tail
```

If you see `ErrImagePull`, images are not in the local Docker daemon. Either you did not run `make pull-images`, or Docker Desktop is not using the containerd image store. Enable containerd (Settings -> General) or run `make load-images` to push images into a `kind` node instead.

### Ingress webhook TLS error on first deploy

`make deploy` already retries six times with a 10-second backoff — the ingress-nginx admission webhook needs a few seconds to come up. If it still fails, re-run `make deploy`.

### Stuck namespace on `make clean-*`

The clean targets strip finalizers and force-delete automatically. If a namespace still lingers:

```bash
kubectl patch namespace elastic \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
```

### `.env` drifted from `.env.example`

```bash
make diff-env
```

Shows missing and stale keys, with each key's default value.

---

## FAQ

### Does this really work with no internet?

Yes, once `make pull-all` has run. The runtime cluster has no outbound traffic: GeoIP auto-download is disabled, Fleet uses a local Elastic Package Registry, and every image is already in your Docker daemon. The only caveat is that the Docker Desktop daemon itself needs to be running — Docker Desktop's update check is internal to the Docker process, not the cluster.

### Can I use this on Linux or Windows?

Yes. Docker Desktop for Mac and Windows both work. On Linux you can use Docker Desktop for Linux or adapt the Makefile to use `kind` directly (the `load-images` target already exists for that).

### How much RAM do I need?

12 GB allocated to Docker Desktop is the realistic minimum for the full stack (Elasticsearch x2, ML node, Kibana, Fleet, Agent, Logstash, Maps, EPR). You can reduce the ML node to 0 replicas in `manifests/elasticsearch.yaml` if you do not need ML, which drops the requirement to roughly 8 GB.

### Do I need a license?

No. The default tier is **trial** (30 days of Enterprise features). After the trial you can continue on **Basic**, which is the free tier and covers Elasticsearch, Kibana, and Fleet. **Enterprise** is only needed for paid features like the full AI Assistant, Watcher, document-level security, and cross-cluster replication.

### Does Fleet work offline?

Yes — that is the whole point of the local Elastic Package Registry deployment. Fleet in Kibana browses integrations from the in-cluster EPR, not from `epr.elastic.co`. New integrations ship with each EPR image tag, so pulling a fresh image is how you update the integration catalogue in your offline lab.

### Will ML / ELSER work offline?

The ML node runs offline with no problem. Pre-trained models (ELSER, E5) normally download from `ml-models.elastic.co` on first use — `make pull-ml-models` caches those artefacts locally for manual upload via the `PUT _ml/trained_models` API.

### Can I transport the asset bundle to a different machine?

Yes. Run `make pull-all && make save-images`, copy the `assets/` directory to the target machine, and run `make load-images-tarball && make deploy`.

### How do I upgrade the stack version?

Bump `ELASTIC_VERSION` in `.env`, run `make pull-all` online (to cache the new images), then re-run `make deploy` offline. ECK handles rolling upgrades.

### How does the local LLM integration work?

Kibana is templated with an AI Connector pointing at `host.docker.internal:<LM_STUDIO_PORT>/v1` — an OpenAI-compatible endpoint. The model itself runs on the host through LM Studio so it can use Metal/MLX (Docker Desktop's Kubernetes VM cannot see the Apple Silicon GPU), and the lab manages its lifecycle through the same Makefile as the rest of the stack:

- `make deploy` runs `make start-llm`, which calls `make check-lms` to install LM Studio via Homebrew if needed (`brew install --cask lm-studio` + `lms bootstrap`), starts the `lms` server on `LM_STUDIO_PORT`, loads `LLM_CONNECTOR_MODEL`, and probes the endpoint with `make check-llm`.
- `make clean-all` runs `make stop-llm`, which unloads models and stops the `lms` server.
- `LLM_CONNECTOR_MODEL` in `.env` is the **single source of truth** for the model name: it is passed to `lms load` and substituted into the Kibana connector's `defaultModel`, so changing it in one place updates both sides.
- Set `LLM_CONNECTOR_MODEL=` (empty) in `.env` to skip the LLM entirely — `make deploy` becomes a no-op for the LM Studio steps.

The Kibana AI Assistant then uses that local endpoint without ever leaving your machine.

### Why ECK instead of Docker Compose?

ECK is how Elastic officially orchestrates the stack on Kubernetes. It handles TLS, upgrades, node roles, scaling, and stack version upgrades natively. Docker Compose works too — see the sibling project [elastic-at-home](https://github.com/jamesagarside/elastic-at-home) for a Compose-based home SIEM.

---

## License

Apache 2.0. See [LICENSE](LICENSE).

## Contributing

Issues and PRs welcome at [github.com/jamesagarside/elastic-airgapped](https://github.com/jamesagarside/elastic-airgapped).
