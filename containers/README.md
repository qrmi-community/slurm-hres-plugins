# Slurm Cluster Containers

A local, container-based Slurm cluster (controller, database, login node and 2 compute nodes) for developing and testing QRMI and SPANK plugins without access to a production HPC cluster.

- Rocky Linux 9 + Slurm master（26.11)
- Open MPI 4.1.8 and Slurm built against OpenPMIx 4.1.3 (`srun --mpi=pmix`)
- Works with Docker or Podman on Apple silicon, Intel/AMD and Windows (WSL2)

| Container | Role |
|-----------|------|
| `mysql` | Database (Slurm accounting storage) |
| `slurmdbd` | Slurm database daemon (`slurmdbd`) |
| `slurmctld` | Slurm controller (`slurmctld`) |
| `login` | Login node (job submission) |
| `c1` | Compute node #1 (`slurmd`) |
| `c2` | Compute node #2 (`slurmd`) |
| `slurmrestd` | Slurm REST API (`slurmrestd`, JWT authentication) |

See **[docs/INSTALL.md](docs/INSTALL.md)** for setup, verification, image details, customization and troubleshooting.
See **[docs/SLURM-WEB.md](docs/SLURM-WEB.md)** for the Slurm REST API and the Slurm-web dashboard.

## Files

| Path | Description |
|------|-------------|
| `Dockerfile` | Image shared by all nodes (Slurm, OpenPMIx, Open MPI, tools) |
| `compose.yml` | Cluster definition: 7 containers, network, volumes and `/shared` bind mount |
| `entrypoint.sh` | Configures and starts each node according to the container command (`slurmdbd` / `slurmctld` / `slurmd` / `slurmrestd` / `login`) |
| `slurm.conf` | Slurm configuration; copied to `/etc/slurm` in the containers |
| `slurmdbd.conf` | `slurmdbd` configuration; copied to `/etc/slurm` in the containers |
| `cgroup.conf` | Slurm cgroup configuration; copied to `/etc/slurm` in the containers |
| `qrmi_config.json.example` | Example QRMI configuration; copied to `/etc/slurm` in the containers |
| `update_slurmfiles.sh` | Updates the Slurm configuration files in the containers from the host |
| `compose.slurm-web.yml` | Slurm-web add-on: web dashboard on http://localhost:5011; see [docs/SLURM-WEB.md](docs/SLURM-WEB.md) |
| `slurm-web/` | Slurm-web agent, gateway and RBAC policy configuration |
| `docs/INSTALL.md` | Installation and reference guide |
| `docs/SLURM-WEB.md` | Slurm REST API and Slurm-web guide |
| `images/` | Cluster diagram (PNG) |
