# kind-script

Idempotent Bash script for managing [Kind](https://kind.sigs.k8s.io/) clusters with local container registry support.

Inspired by [StrimKKhaos](https://github.com/see-quick/StrimKKhaos).

## Features

- **Idempotent** - Safe to run multiple times
- **Docker & Podman** support
- **IPv4/IPv6/dual-stack** networking
- **Local container registry** for development
- **Multi-zone simulation** with standard topology labels
- **Cloud-provider-kind** for LoadBalancer support

## Installation

Download from the latest [GitHub release](https://github.com/see-quick/kind-script/releases):

```bash
curl -sSLO https://github.com/see-quick/kind-script/releases/latest/download/kind-cluster.sh
chmod +x kind-cluster.sh
```

Or pin to a specific version:

```bash
curl -sSLO https://github.com/see-quick/kind-script/releases/download/v1.0.0/kind-cluster.sh
chmod +x kind-cluster.sh
```

### Building from source

Clone the repo and run the build script to produce a single-file distribution:

```bash
git clone https://github.com/see-quick/kind-script.git
cd kind-script
./build.sh
# Output: dist/kind-cluster.sh
```

## Quick Start

```bash
./kind-cluster.sh create    # Create cluster
./kind-cluster.sh status    # Check status
./kind-cluster.sh delete    # Cleanup
```

## Commands

| Command        | Description                        |
|----------------|------------------------------------|
| `create`       | Create cluster with all components |
| `delete`       | Delete cluster and cleanup         |
| `status`       | Show status                        |
| `install-deps` | Install kind and kubectl           |
| `version`      | Show version information           |
| `help`         | Show help                          |

## Options

```
--name NAME              Cluster name (default: kind-cluster)
--control-planes N       Control plane nodes (default: 1)
--workers N              Worker nodes (default: 3)
--image IMAGE            Node image: latest, oldest, or full image
--ip-family FAMILY       ipv4, ipv6, dual (default: ipv4)
--docker-cmd CMD         docker or podman
--registry-port PORT     Registry port (default: 5001)
--no-registry            Disable local registry
--no-cloud-provider      Disable LoadBalancer support
--zones N                Number of zones to simulate
--nodes-per-zone N       Worker nodes per zone (default: 1)
--force                  Force recreate existing cluster
--debug                  Enable debug output
```

## Multi-Zone Simulation

Simulate Kubernetes availability zones by distributing nodes across zones with standard topology labels. 
This is useful for testing zone-aware workload placement, topology spread constraints, and rack-aware replication (e.g., Strimzi Kafka `rack.id`).

```bash
# 3 zones, 1 worker per zone (3 CPs + 3 workers = 6 nodes)
./kind-cluster.sh create --zones 3

# 2 zones, 3 workers per zone (2 CPs + 6 workers = 8 nodes)
./kind-cluster.sh create --zones 2 --nodes-per-zone 3

# Via environment variables
ZONES=3 NODES_PER_ZONE=2 ./kind-cluster.sh create
```

When `--zones` is specified:
- One control-plane node is created per zone
- Worker nodes are distributed round-robin across zones
- `--workers` and `--control-planes` flags are ignored with a warning
- Each node gets labels: `topology.kubernetes.io/zone=zoneN` and `rack-key=zoneN`

Check zone distribution with `status`:

```bash
./kind-cluster.sh status
# Zones:
#   zone0: kind-control-plane, kind-worker, kind-worker4
#   zone1: kind-control-plane2, kind-worker2, kind-worker5
```

## Examples

```bash
# Custom cluster
./kind-cluster.sh create --name my-cluster --workers 5 --control-planes 3

# IPv6 cluster
./kind-cluster.sh create --ip-family ipv6

# Use Podman
./kind-cluster.sh create --docker-cmd podman

# Environment variables
CONTROL_NODES=3 WORKER_NODES=5 ./kind-cluster.sh create
```

## Environment Variables

| Variable            | Default      | Description       |
|---------------------|--------------|-------------------|
| `KIND_VERSION`      | v0.31.0      | Kind version      |
| `KIND_NODE_IMAGE`   | latest       | Node image        |
| `KIND_CLUSTER_NAME` | kind-cluster | Cluster name      |
| `CONTROL_NODES`     | 1            | Control planes    |
| `WORKER_NODES`      | 3            | Workers           |
| `IP_FAMILY`         | ipv4         | IP family         |
| `DOCKER_CMD`        | docker       | Container runtime |
| `REGISTRY_PORT`     | 5001         | Registry port     |
| `ZONES`             | 0            | Number of zones   |
| `NODES_PER_ZONE`    | 1            | Workers per zone  |

## Using the Local Registry

```bash
docker tag my-app:latest localhost:5001/my-app:latest
docker push localhost:5001/my-app:latest
kubectl run my-app --image=localhost:5001/my-app:latest
```

## Requirements

- Docker or Podman
- curl, bash 4.0+

Kind and kubectl are installed automatically if missing.