#!/usr/bin/bash

#SBATCH --gpus-per-node=1
#SBATCH --nodes=1
#SBATCH --partition=thinkstation
#SBATCH --nodelist=worker9
#SBATCH --output="mi_m_general-%j.out"

srun matlab -nosplash -nodesktop -nodisplay -r "run('mi_m_general.m'); exit"
