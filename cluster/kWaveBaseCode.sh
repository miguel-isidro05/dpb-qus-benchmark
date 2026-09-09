#!/usr/bin/bash
#SBATCH --gpus-per-node=1
#SBATCH --nodes=1
#SBATCH --partition=thinkstation
#SBATCH --nodelist=worker8
#SBATCH --output="mi_m_kwave_baseline-%j.out"

script_directory="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "${script_directory}"

srun matlab -nosplash -nodesktop -nodisplay -r "kWaveBaseCode; exit"
