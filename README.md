# kind-script

Idempotent Bash script for managing [Kind](https://kind.sigs.k8s.io/) clusters with local container registry support.

Inspired by [StrimKKhaos](https://github.com/see-quick/StrimKKhaos).

## Features

- **Idempotent** - Safe to run multiple times
- **Docker & Podman** support
- **IPv4/IPv6/dual-stack** networking
- **Local container registry** for development
- **Cloud-provider-kind** for LoadBalancer support

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
--force                  Force recreate existing cluster
--debug                  Enable debug output
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
| `KIND_VERSION`      | v0.29.0      | Kind version      |
| `KIND_NODE_IMAGE`   | latest       | Node image        |
| `KIND_CLUSTER_NAME` | kind-cluster | Cluster name      |
| `CONTROL_NODES`     | 1            | Control planes    |
| `WORKER_NODES`      | 3            | Workers           |
| `IP_FAMILY`         | ipv4         | IP family         |
| `DOCKER_CMD`        | docker       | Container runtime |
| `REGISTRY_PORT`     | 5001         | Registry port     |

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