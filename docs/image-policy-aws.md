# AWS Ubuntu CPU and GPU image policy

V0 is x86_64 Ubuntu 24.04 LTS only.

| Profile | AMI source | Driver policy |
|---|---|---|
| CPU | Canonical public SSM parameter `/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id` | No NVIDIA stack; install the locked native ML environment only |
| GPU | AWS public SSM parameter `/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id` | Base OSS NVIDIA Driver GPU DLAMI supplies the compatible driver/CUDA base; verify it before installing locked project packages |

Planning resolves the parameter, but authorization binds the exact saved plan and AMI ID. Every run receipt must record the parameter, resolved ID, AMI name, owner, architecture, creation date, and resolution time.

CPU AMIs must be owned by Canonical account `099720109477`. GPU AMIs must have the Amazon owner alias, x86_64 architecture, `available` state, and documented compatibility with the selected G-family type.

GPU bootstrap will fail fast unless `nvidia-smi` succeeds and reports the expected accelerator. CPU bootstrap must not install NVIDIA drivers. Polars, DuckDB, PyArrow, and CPU model libraries use the same locked application contract on both images; GPU-enabled XGBoost/LightGBM/CatBoost settings are accepted separately because capability and wheel support differ.

No custom AMI, framework-bundled DLAMI, Ubuntu Pro, Amazon Linux, Debian, ARM64, or automatic in-place driver upgrade is allowed in V0.
