#!/usr/bin/bash

#SBATCH --job-name=mi_m_tx64
#SBATCH --gpus-per-node=1
#SBATCH --nodes=1
#SBATCH --partition=thinkstation
#SBATCH --nodelist=worker7
#SBATCH --output="mi_m_transmission_comparison_64el-%j.out"

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

srun matlab -nosplash -nodesktop -nodisplay \
    -r "run('mi_m_transmission_comparison_64el.m'); exit"
