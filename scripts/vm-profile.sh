# Source from repository root after set -e. Validation happens before boot/build.
# No eval: the resolver emits only validated positive decimal integers.
ORANGE_VM_RAM=$(python3 tools/vm_profile.py --field ram_mib)
export ORANGE_VM_RAM
ORANGE_VM_CPUS=$(python3 tools/vm_profile.py --field cpus)
export ORANGE_VM_CPUS
ORANGE_RAM_BUDGET_MIB=$(python3 tools/vm_profile.py --field ram_budget_mib)
export ORANGE_RAM_BUDGET_MIB
