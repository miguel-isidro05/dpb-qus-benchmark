#!/usr/bin/bash

#SBATCH --gpus-per-node=1
#SBATCH --nodes=1
#SBATCH --partition=thinkstation
#SBATCH --nodelist=worker[7-10]
#SBATCH --output="mi_m_hello_world.out"

srun matlab -nosplash -nodesktop -nodisplay -r "mi_m_hello_world; exit"

