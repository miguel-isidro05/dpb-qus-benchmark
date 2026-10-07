#!/usr/bin/bash

#SBATCH --gpus-per-node=1
#SBATCH --nodes=1
#SBATCH --partition=thinkstation
#SBATCH --nodelist=worker8
#SBATCH --output="mi_m_transmission_comparison_64el-%j.out"

srun matlab -nosplash -nodesktop -nodisplay -r "run('mi_m_transmission_comparison_64el.m'); exit"
