#!/usr/bin/bash

#SBATCH --gpus-per-node=1
#SBATCH --nodes=1
#SBATCH --partition=thinkstation
#SBATCH --nodelist=worker7
#SBATCH --output="mi_m_paper_s1_s8_swift_rx67_pipeline-%j.out"

srun matlab -nosplash -nodesktop -nodisplay -r "run('mi_m_paper_s1_s8_swift_rx67_pipeline.m'); exit"
