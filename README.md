# KinD: ArgoCD, Grafana, Prometheus, Loki, Tempo, Phlare, VictoriaMetrics and MetalLB.

- `ArgoCD` is a tool for automating continuous delivery of applications to Kubernetes clusters. It uses GitOps methodology to synchronize the desired state of the application with the actual state in the cluster.

- `Loki` is a horizontally-scalable, highly-available, multi-tenant log aggregation system inspired by Prometheus. It is designed to be very cost effective and easy to operate, as it does not index the contents of the logs, but rather a set of labels for each log stream.

- `Grafana Tempo` is an open source, easy-to-use, and high-scale distributed tracing backend. Tempo is cost-efficient, requiring only object storage to operate, and is deeply integrated with Grafana, Prometheus, and Loki. Tempo can ingest common open source tracing protocols, including Jaeger, Zipkin, and OpenTelemetry.

- `Grafana Phlare` lets you aggregate continuous profiling data with high availability, multi-tenancy, and durable storage. This helps you get a better understanding of resource usage in your applications down to the line number.

- `VictoriaMetrics` is a fast, cost-effective and scalable monitoring solution and time series database.

- `Prometheus` is a monitoring and alerting tool for Kubernetes and other systems. It collects metrics from various sources, stores them in a time-series database, and allows users to query and visualize the data. It also has a built-in alerting system that can send notifications based on specific conditions.

- `Grafana` is a tool for visualizing and analyzing data from various sources, including Prometheus. It provides a flexible and customizable dashboard that allows users to create graphs, charts, and other visualizations to monitor the performance of their systems. Grafana also has a built-in alerting system that can trigger notifications based on specific thresholds.

- `MetalLB` is a load-balancer implementation for bare-metal Kubernetes clusters. It assigns real IP addresses from a configured pool to `LoadBalancer` services, making them reachable from outside the cluster without a cloud provider.

## Requirements

- Linux OS
- [Docker](https://docs.docker.com/)
- [KinD](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/reference/kubectl/)
- [helm](https://helm.sh/docs/intro/install/)
- [yq](https://github.com/mikefarah/yq)
- [argocd CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/)
- [kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/) (for applying dashboard ConfigMaps)


### Usage:
```
make launch-k8s
make deploy-argocd
```

ArgoCD and Grafana are exposed via MetalLB `LoadBalancer` services — no port-forwarding needed after syncing apps.

```
# Show ArgoCD admin password
make argocd-password

# Show Grafana admin password
make grafana-password

# Login argocd CLI (after MetalLB IPs are assigned)
make login-argocd
```

Legacy port-forward approach (if MetalLB is not yet configured):
```
kubectl port-forward service/argocd-server -n argocd 8080:443 &
### Browser (ArgoCD) : https://localhost:8080

argocd login localhost:8080 --grpc-web --insecure --username admin \
  --password $(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

kubectl port-forward svc/prometheus-grafana 3000:80 -n prometheus
### Browser (Grafana) : http://localhost:3000
```
### Sync apps in below order, based on Argo sync-wave annotation via ArgoCD UI or using `make sync-applications` !

> **Note:** The `metallb` and `metallb-config` ArgoCD applications must be on the `main` branch of the repo before syncing. The `metallb-config` app (sync-wave 3) provisions the `IPAddressPool` (`172.18.255.200–250`) and `L2Advertisement` that MetalLB requires to assign external IPs. If these resources are missing, LoadBalancer services will remain `<pending>`.


```
make sync-applications
```
Explanation (Argo sync-wave annotation):
```
### Sort applications by Argo sync-wave annotation 
$ kustomize build ./manifests/applications/ | yq ea [.] -o json | jq -r '. | sort_by(.metadata.annotations."argocd.argoproj.io/sync-wave" // "0" | tonumber) | .[] | .metadata.name'
namespaces
cert-manager
loki
phlare
prometheus-adapter
tempo
victoriametrics
prometheus
monitoring
sandbox

###Using argocd CLI example
kustomize build ./manifests/applications/ | yq ea [.] -o json | jq -r '. | sort_by(.metadata.annotations."argocd.argoproj.io/sync-wave" // "0" | tonumber) | .[] | .metadata.name' > apps-sync.sort
for app in `cat apps-sync.sort`; do argocd app sync $app --retry-limit 3 --timeout 300; done

```
## MetalLB

MetalLB is deployed via ArgoCD (sync-wave 2) and configured via a second ArgoCD app `metallb-config` (sync-wave 3). After sync, two `LoadBalancer` services receive external IPs from the `172.18.255.200–250` pool:

| Service | External IP | Port |
|---|---|---|
| ArgoCD (`argocd-server`) | `172.18.255.200` | 80, 443 |
| Grafana (`prometheus-grafana`) | `172.18.255.201` | 80 |

The IP pool is defined in [manifests/metallb/config.yaml](manifests/metallb/config.yaml).

### Accessing services from the LAN — `metallb-dnat.sh`

When running KinD inside a Linux host on a LAN, MetalLB IPs are only reachable on the host itself (they live in the Docker bridge network). `metallb-dnat.sh` automatically discovers all `LoadBalancer` services via `kubectl` and installs iptables DNAT rules so those services are reachable from other machines on the LAN.

```bash
# Show what would be mapped (no changes made)
bash metallb-dnat.sh list

# Apply DNAT rules (requires root)
sudo bash metallb-dnat.sh apply

# Check current rules and discovered services
sudo bash metallb-dnat.sh status

# Remove all managed rules
sudo bash metallb-dnat.sh remove

# Watch mode — re-syncs every 30s, picks up new services automatically
sudo bash metallb-dnat.sh watch

# Install as a systemd service (survives reboots)
sudo bash metallb-dnat.sh install
```

After `apply`, services are reachable at the host's LAN IP. Port collisions between services are resolved automatically by incrementing the host port (e.g. if two services both expose port 80, the second gets host port 81).

| Service | LAN URL (example) |
|---|---|
| ArgoCD | `http://<host-lan-ip>:80` / `https://<host-lan-ip>:443` |
| Grafana | `http://<host-lan-ip>:81` |

### Check apps
```
$ kubectl get po --all-namespaces
NAMESPACE            NAME                                                         READY   STATUS    RESTARTS        AGE
argocd               argocd-application-controller-0                              1/1     Running   0               27m
argocd               argocd-applicationset-controller-6477f4dc9-7lvpz             1/1     Running   0               27m
argocd               argocd-dex-server-587855cf49-ndqpl                           1/1     Running   0               27m
argocd               argocd-notifications-controller-5f88985887-zpq6w             1/1     Running   0               27m
argocd               argocd-redis-59687468f9-6qpg4                                1/1     Running   0               30m
argocd               argocd-repo-server-6594ddf4f4-tws8x                          1/1     Running   0               27m
argocd               argocd-server-7f9cd56796-m68cc                               1/1     Running   0               27m
cert-manager         cert-manager-55b858df44-4xzvw                                1/1     Running   0               22m
cert-manager         cert-manager-cainjector-7f47598f9b-g24wc                     1/1     Running   0               22m
cert-manager         cert-manager-webhook-7d694cd764-hmh45                        1/1     Running   0               22m
kube-system          coredns-787d4945fb-d74hw                                     1/1     Running   0               34m
kube-system          coredns-787d4945fb-jsb68                                     1/1     Running   0               34m
kube-system          etcd-hands-on-control-plane                                  1/1     Running   0               34m
kube-system          kindnet-8rz6f                                                1/1     Running   0               34m
kube-system          kindnet-9kd9z                                                1/1     Running   0               33m
kube-system          kindnet-jxfgm                                                1/1     Running   0               33m
kube-system          kindnet-pw2dw                                                1/1     Running   0               33m
kube-system          kube-apiserver-hands-on-control-plane                        1/1     Running   0               34m
kube-system          kube-controller-manager-hands-on-control-plane               1/1     Running   0               34m
kube-system          kube-proxy-5k7zn                                             1/1     Running   0               33m
kube-system          kube-proxy-dcfkp                                             1/1     Running   0               33m
kube-system          kube-proxy-g7r9z                                             1/1     Running   0               33m
kube-system          kube-proxy-tlpmq                                             1/1     Running   0               34m
kube-system          kube-scheduler-hands-on-control-plane                        1/1     Running   0               34m
local-path-storage   local-path-provisioner-c8855d4bb-6c6cw                       1/1     Running   0               34m
loki                 loki-0                                                       1/1     Running   0               20m
loki                 loki-promtail-dplmz                                          1/1     Running   0               20m
loki                 loki-promtail-kw98s                                          1/1     Running   0               20m
loki                 loki-promtail-rsn7m                                          1/1     Running   0               20m
loki                 loki-promtail-x4tsf                                          1/1     Running   0               20m
phlare               phlare-0                                                     1/1     Running   0               18m
prometheus-adapter   prometheus-adapter-7c6bbdd68b-ljldh                          1/1     Running   0               17m
prometheus           alertmanager-prometheus-kube-prometheus-alertmanager-0       2/2     Running   0               13m
prometheus           prometheus-grafana-66f47cb6fc-t2sq4                          3/3     Running   0               15m
prometheus           prometheus-kube-prometheus-operator-68b694d86f-pztcs         1/1     Running   0               15m
prometheus           prometheus-kube-state-metrics-cdf984bd9-j2lpv                1/1     Running   0               15m
prometheus           prometheus-prometheus-kube-prometheus-prometheus-0           2/2     Running   0               10m
prometheus           prometheus-prometheus-node-exporter-5bmzh                    1/1     Running   0               15m
prometheus           prometheus-prometheus-node-exporter-db664                    1/1     Running   0               15m
prometheus           prometheus-prometheus-node-exporter-kvncl                    1/1     Running   0               15m
prometheus           prometheus-prometheus-node-exporter-xlsdf                    1/1     Running   0               15m
prometheus           promlens-69596fbb57-n8b8b                                    1/1     Running   0               11m
sandbox              dummy-metrics-d994b565d-hzg2h                                1/1     Running   0               11s
sandbox              request                                                      1/1     Running   0               8m26s
sandbox              todo-795757947b-lvmnf                                        1/1     Running   0               8m25s
tempo                tempo-0                                                      1/1     Running   0               16m
victoriametrics      victoriametrics-victoria-metrics-operator-786cbbd895-wzqmf   1/1     Running   0               16m
victoriametrics      vmagent-vmagent-5d4bc68b54-nrlxn                             2/2     Running   0               11m
victoriametrics      vmsingle-database-6d4bbfffc4-72kcm                           1/1     Running   0               11m


$ kubectl get svc --all-namespaces
NAMESPACE            NAME                                                 TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)                                                                                                   AGE
argocd               argocd-application-controller-metrics                ClusterIP   10.96.243.43    <none>        8082/TCP                                                                                                  28m
argocd               argocd-applicationset-controller                     ClusterIP   10.96.200.187   <none>        7000/TCP                                                                                                  30m
argocd               argocd-dex-server                                    ClusterIP   10.96.171.200   <none>        5556/TCP,5557/TCP                                                                                         30m
argocd               argocd-redis                                         ClusterIP   10.96.176.242   <none>        6379/TCP                                                                                                  30m
argocd               argocd-repo-server                                   ClusterIP   10.96.182.245   <none>        8081/TCP                                                                                                  30m
argocd               argocd-repo-server-metrics                           ClusterIP   10.96.177.251   <none>        8084/TCP                                                                                                  28m
argocd               argocd-server                                        ClusterIP   10.96.235.0     <none>        80/TCP,443/TCP                                                                                            30m
argocd               argocd-server-metrics                                ClusterIP   10.96.137.59    <none>        8083/TCP                                                                                                  28m
cert-manager         cert-manager                                         ClusterIP   10.96.90.32     <none>        9402/TCP                                                                                                  22m
cert-manager         cert-manager-webhook                                 ClusterIP   10.96.168.207   <none>        443/TCP                                                                                                   22m
default              kubernetes                                           ClusterIP   10.96.0.1       <none>        443/TCP                                                                                                   34m
kube-system          kube-dns                                             ClusterIP   10.96.0.10      <none>        53/UDP,53/TCP,9153/TCP                                                                                    34m
kube-system          prometheus-kube-prometheus-coredns                   ClusterIP   None            <none>        9153/TCP                                                                                                  15m
kube-system          prometheus-kube-prometheus-kube-controller-manager   ClusterIP   None            <none>        10257/TCP                                                                                                 15m
kube-system          prometheus-kube-prometheus-kube-etcd                 ClusterIP   None            <none>        2381/TCP                                                                                                  15m
kube-system          prometheus-kube-prometheus-kube-proxy                ClusterIP   None            <none>        10249/TCP                                                                                                 15m
kube-system          prometheus-kube-prometheus-kube-scheduler            ClusterIP   None            <none>        10259/TCP                                                                                                 15m
kube-system          prometheus-kube-prometheus-kubelet                   ClusterIP   None            <none>        10250/TCP,10255/TCP,4194/TCP                                                                              14m
loki                 loki                                                 ClusterIP   10.96.97.176    <none>        3100/TCP                                                                                                  21m
loki                 loki-headless                                        ClusterIP   None            <none>        3100/TCP                                                                                                  21m
loki                 loki-memberlist                                      ClusterIP   None            <none>        7946/TCP                                                                                                  21m
phlare               phlare                                               ClusterIP   10.96.217.164   <none>        4100/TCP                                                                                                  18m
phlare               phlare-headless                                      ClusterIP   None            <none>        4100/TCP                                                                                                  18m
phlare               phlare-memberlist                                    ClusterIP   None            <none>        7946/TCP                                                                                                  18m
prometheus-adapter   prometheus-adapter                                   ClusterIP   10.96.200.242   <none>        443/TCP                                                                                                   17m
prometheus           alertmanager-operated                                ClusterIP   None            <none>        9093/TCP,9094/TCP,9094/UDP                                                                                14m
prometheus           prometheus-grafana                                   ClusterIP   10.96.4.160     <none>        80/TCP                                                                                                    15m
prometheus           prometheus-kube-prometheus-alertmanager              ClusterIP   10.96.133.168   <none>        9093/TCP,8080/TCP                                                                                         15m
prometheus           prometheus-kube-prometheus-operator                  ClusterIP   10.96.3.78      <none>        443/TCP                                                                                                   15m
prometheus           prometheus-kube-prometheus-prometheus                ClusterIP   10.96.205.35    <none>        9090/TCP,8080/TCP                                                                                         15m
prometheus           prometheus-kube-state-metrics                        ClusterIP   10.96.73.200    <none>        8080/TCP                                                                                                  15m
prometheus           prometheus-operated                                  ClusterIP   None            <none>        9090/TCP                                                                                                  10m
prometheus           prometheus-prometheus-node-exporter                  ClusterIP   10.96.64.146    <none>        9100/TCP                                                                                                  15m
sandbox              todo                                                 ClusterIP   10.96.202.85    <none>        80/TCP                                                                                                    8m43s
tempo                tempo                                                ClusterIP   10.96.0.2       <none>        3100/TCP,6831/UDP,6832/UDP,14268/TCP,14250/TCP,9411/TCP,55680/TCP,55681/TCP,4317/TCP,4318/TCP,55678/TCP   17m
victoriametrics      victoriametrics-victoria-metrics-operator            ClusterIP   10.96.141.235   <none>        8080/TCP,443/TCP                                                                                          16m
victoriametrics      vmagent-vmagent                                      ClusterIP   10.96.157.233   <none>        8429/TCP                                                                                                  12m
victoriametrics      vmsingle-database                                    ClusterIP   10.96.178.211   <none>        8429/TCP                                                                                                  12m


```
## Grafana Dashboards

Dashboards are provisioned automatically via a `ConfigMap` (label `grafana_dashboard: "1"`) watched by the Grafana sidecar. JSON files live in [manifests/monitoring/prometheus/dashboards/](manifests/monitoring/prometheus/dashboards/) and are bundled by [manifests/monitoring/prometheus/kustomization.yaml](manifests/monitoring/prometheus/kustomization.yaml).

To apply changes locally:
```bash
kustomize build manifests/monitoring/prometheus | kubectl apply -f -
```

### Available Dashboards

#### Pre-provisioned (kube-prometheus-stack)
| Dashboard | Description |
|---|---|
| Kubernetes / Compute Resources / Cluster | Cluster-wide CPU & memory requests vs allocatable |
| Kubernetes / Compute Resources / Node (Pods) | Per-node pod scheduling breakdown |
| Node Exporter / Nodes | Per-node disk, CPU, memory, network |
| Node Exporter / USE Method / Cluster | Utilisation, Saturation, Errors — cluster view |
| Alertmanager / Overview | Alertmanager firing alerts and routing |
| Prometheus / Overview | Prometheus engine health |
| etcd | etcd cluster health and latency |
| CoreDNS | DNS query rates and latency |

#### Custom (this repo)
| Dashboard | Datasource | Description |
|---|---|---|
| [ArgoCD / App Health & Sync](manifests/monitoring/prometheus/dashboards/argocd-app-health.json) | Prometheus | Per-app health/sync status table, sync success/failure rate, reconcile latency |
| [ArgoCD Performance](manifests/monitoring/prometheus/dashboards/argocd-performance.json) | Prometheus + Loki + Tempo + Phlare | ArgoCD server CPU/memory, sync duration, flame graph |
| [Cluster Capacity](manifests/monitoring/prometheus/dashboards/cluster-capacity.json) | Prometheus | Allocatable vs requested vs actual CPU/memory per node, pod headroom, disk, namespace breakdown |
| [Cert-Manager / Certificate Health](manifests/monitoring/prometheus/dashboards/cert-manager.json) | Prometheus | Pod readiness, cert read rate/errors, API server certificate TTL |
| [Loki / Log Volume & Errors](manifests/monitoring/prometheus/dashboards/loki-logs.json) | Loki | Log ingestion rate by namespace, error/warn rate, top emitting pods, live log stream |
| [MetalLB / LoadBalancer Services](manifests/monitoring/prometheus/dashboards/metallb-services.json) | Prometheus | LoadBalancer service inventory, speaker/controller readiness, pod resource usage |
| [Phlare / Continuous Profiling](manifests/monitoring/prometheus/dashboards/phlare-profiling.json) | Phlare | CPU & memory allocation flamegraphs per service |
| [Tempo / Distributed Tracing](manifests/monitoring/prometheus/dashboards/tempo-tracing.json) | Tempo | Trace count, error traces, p95 duration, recent trace table with links |
| [VictoriaMetrics / Health](manifests/monitoring/prometheus/dashboards/victoriametrics-health.json) | Prometheus | VM pod readiness, CPU/memory usage, ingestion rate, network I/O |

### Screenshots:

### Browser (ArgoCD) : https://localhost:8080

<img src="pictures/ArgoCD-applications.png?raw=true" width="1000">

### Browser (Grafana): http://\<metallb-ip\>:80 (or http://\<host-lan-ip\>:81 via DNAT)

<img src="pictures/Grafana-DataSources.png?raw=true" width="1000">

<img src="pictures/Grafana-UI.png?raw=true" width="1000">

<img src="pictures/Grafana-UI-ArgoCD-performance.png?raw=true" width="1000">


### Clean environment
```
make shutdown-k8s
```

### REF: VictoriMetrics vs Prometheus vs ..., etc.

- https://github.com/VictoriaMetrics/VictoriaMetrics
- https://valyala.medium.com (all articles related)
- Benchmark Prometheus vs VictoriMetrics: https://valyala.medium.com/prometheus-vs-victoriametrics-benchmark-on-node-exporter-metrics-4ca29c75590f
- Benchmark Thanos vs VictoriMetrics: https://faun.pub/comparing-thanos-to-victoriametrics-cluster-b193bea1683
- https://faun.pub/victoriametrics-creating-the-best-remote-storage-for-prometheus-5d92d66787ac
- Benchmark VictoriMetrics vs TimescaleDB vs InfluxDB: https://valyala.medium.com/high-cardinality-tsdb-benchmarks-victoriametrics-vs-timescaledb-vs-influxdb-13e6ee64dd6b
- https://www.youtube.com/watch?v=ZTc1Qxn9aaE
  
Credits: https://github.com/zoetrope/k8s-hands-on
