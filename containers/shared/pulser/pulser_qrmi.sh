#!/bin/bash

#SBATCH --job-name=pasqal_job
#SBATCH --output=data/job_%j.out
#SBATCH --error=data/job_%j.out
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1

# Your script goes here
# env
source /shared/pulser/venv/bin/activate
python /shared/pulser/pulser_qrmi.py

