#!/bin/bash 
#
#PBS -N juliachem-runtest 
#PBS -o juliachem-runtest.log
#PBS -e juliachem-runtest.err
#
#PBS -q skylake_8180
#PBS -l walltime=24:00:00
#PBS -l ncpus=8
#PBS -l jobfs=1Gb
#PBS -l mem=128Gb
#
export JULIA_NUM_THREADS=8
#
julia --check-bounds=no --math-mode=fast --optimize=3 --inline=yes --compiled-modules=yes -E 'using Pkg; using JuliaChem; Pkg.test("JuliaChem")'
