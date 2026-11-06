
## Resource.yml working example


```yml
- resource: PASQAL_LOCAL        # must be the first key; = backend name
  mode: MODE_1                  # enough on ONE overlapping layer
  disable_hres: false           # true = backend off, jobs pend (HRESDisabled)
  plugin:
    type: hres/lua              # only hres/lua exists for now
    config:                     # handed to the plugin as-is (visible to users)
      - name: path              # required by hres/lua
        value: /etc/slurm/qrmi_hres.lua  # for 1st test /etc/slurm/hres_trace.lua
      - name: qrmi_config       # QRMI resource definitions (controller + nodes)
        value: /etc/slurm/qrmi_config.json
      # qrmi.so is in /usr/lib64/lua/5.4, the default path: no lua_cpath needed
      # - name: qrmi_resource   # QRMI name, default = this resource name
      #   value: ibm_kingston
      # - name: release         # deferred (default) | immediate
      #   value: deferred
      # - name: admission       # yes (default): hold jobs on QRMI status/slots
      #   value: "yes"
      # - name: status_max_age  # seconds; hold jobs if the status is older
      #   value: "60"
      # Per-user credentials (default: required). Each user keeps their API
      # key in a qrmi_config.json style file; the site key in
      # qrmi_config.json is then only used for status().
      - name: user_credentials  # required (default) | off
        value: off
      # - name: user_config       # %u = user name, %U = uid
      #   value: /shared/qrmi/%u/config.json
      # - name: user_keys         # keys taken from the user's file
      #   value: QRMI_IBM_QS_IAM_APIKEY,QRMI_IBM_QS_SERVICE_CRN
      # - name: cred_fail         # hold (default): hold the job, cause in squeue
      #   value: hold             # pend: keep jobs pending for cred_retry seconds
      # - name: cred_retry        # seconds a user's jobs wait after a bad file
      #   value: "300"
    maintenance_cycle: 10       # also performs deferred releases; keep it short
    maintenance_timeout: 10     # seconds before a slow call is logged; default 3
  layers:
    - layer_name: all           # no whitespace or , ; | : = ( ) *
      nodes:
        - "c[1-2]"
      count: 1                  # concurrent jobs on this backend; -1 = unlimited
      disable_layer: false      # true = this layer is not allocated from

```

## Run example

### Install venv

```bash
python3 -m venv /shared/venv
source /shared/venv/bin/activate
pip install -u pip && pip install qrmi[pasqal]
```

### Run example

```bash
sbatch --resources=PASQAL-LOCAL:1 /shared/pulser_qrmi.sh
```

## Administrate Warden

Disable Warden: 

```bash
# As root user
 curl -X POST warden:4207/accessible -H "X-Munge-Cred: $(munge -n)" -H "Content-Type: application/json" -d '{"is_accessible": false, "message": "Disabling Warden"}'
```
