#!/usr/bin/bash

#SBATCH --gpus-per-node=1
#SBATCH --nodes=1
#SBATCH --partition=thinkstation
#SBATCH --nodelist=worker7
#SBATCH --output="mi_m_kwave_baseline-%j.out"

srun matlab -nosplash -nodesktop -nodisplay -r "mi_m_kwavebaseline; exit"
