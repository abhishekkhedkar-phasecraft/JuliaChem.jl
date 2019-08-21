Base.include(@__MODULE__,"RHFHelpers.jl")

using MATH

using MPI
using Base.Threads
#using Distributed
using LinearAlgebra
using HDF5

function rhf_energy(basis::BasisStructs.Basis, molecule::Dict{String,Any},
  scf_flags::Dict{String,Any})

  if (scf_flags["prec"] == "Float64")
    return rhf_kernel(basis,molecule,scf_flags,oneunit(Float64))
  elseif (scf_flags["prec"] == "Float32")
    return rhf_kernel(basis,molecule,scf_flags,oneunit(Float32))
  end
end


"""
	 rhf_kernel(FLAGS::RHF_Flags, basis::Basis, read_in::Dict{String,Any},
       type::T)
Summary
======
Perform the core RHF SCF algorithm.

Arguments
======
FLAGS = Input flags

basis = Generated basis set

read_in = file required to read in from input file

type = Precision of variables in calculation
"""
function rhf_kernel(basis::BasisStructs.Basis, molecule::Dict{String,Any},
  scf_flags::Dict{String,Any}, type::T) where {T<:AbstractFloat}

  comm=MPI.COMM_WORLD
  calculation_status::Dict{String,Any} = Dict([])

  #== read variables from input if needed ==#
  E_nuc::T = molecule["enuc"]

  S::Array{T,2} = read_in_oei(molecule["ovr"], basis.norb)
  H::Array{T,2} = read_in_oei(molecule["hcore"], basis.norb)

  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
    println("Overlap matrix:")
    display(S)
    println("")

    println("Hamiltonian matrix:")
    display(H)
    println("")
  end

  #== build the orthogonalization matrix ==#
  S_evec::Array{T,2} = eigvecs(LinearAlgebra.Hermitian(S))

  S_eval_diag::Array{T,1} = eigvals(LinearAlgebra.Hermitian(S))

  S_eval::Array{T,2} = zeros(basis.norb,basis.norb)
  for i::Int64 in 1:basis.norb
    S_eval[i,i] = S_eval_diag[i]
  end

  ortho::Array{T,2} = S_evec*
    (LinearAlgebra.Diagonal(S_eval)^-0.5)*transpose(S_evec)

  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
    println("Ortho matrix:")
    display(ortho)
    println("")
  end

  #== build the initial matrices ==#
  F::Array{T,2} = H
  D::Array{T,2} = Matrix{T}(undef,basis.norb,basis.norb)
  C::Array{T,2} = Matrix{T}(undef,basis.norb,basis.norb)

  if (MPI.Comm_rank(comm) == 0)
    println("----------------------------------------          ")
	println("       Starting RHF iterations...                 ")
	println("----------------------------------------          ")
	println(" ")
	println("Iter      Energy                   ΔE                   Drms")
  end

  E_elec::T = 0.0
  F, D, C, E_elec = iteration(F, D, H, ortho, basis, scf_flags)

  E::T = E_elec + E_nuc
  E_old::T = E

  if (MPI.Comm_rank(comm) == 0)
    println(0,"     ", E)
  end

  #=============================#
  #== start scf cycles: #7-10 ==#
  #=============================#
  @time F, D, C, E, iter, converged = scf_cycles(F, D, C, E, H, ortho, S, E_nuc,
    E_elec, E_old, basis, scf_flags)

  if (!converged)
    if (MPI.Comm_rank(comm) == 0)
	    println(" ")
      println("----------------------------------------")
      println(" The SCF calculation did not converge.  ")
      println("      Restart data is being output.     ")
      println("----------------------------------------")
      println(" ")
    end

    calculation_fail::Dict{String,Any} = Dict(
    "success" => false,
    "error" => Dict(
      "error_type" => "convergence_error",
      "error_message" => " SCF calculation did not converge within $iter_limit
        iterations. "
      )
    )

    merge!(calculation_status, calculation_fail)

  else
    if (MPI.Comm_rank(comm) == 0)
      println(" ")
      println("----------------------------------------")
      println("   The SCF calculation has converged!   ")
      println("----------------------------------------")
      println("Total SCF Energy: ",E," h")
      println(" ")

      calculation_success::Dict{String,Any} = Dict(
      "return_result" => E,
      "success" => true,
      "properties" => Dict(
        "return_energy" => E,
        "nuclear_repulsion_energy" => E_nuc,
        "scf_iterations" => iter,
        "scf_total_energy" => E
        )
      )

      merge!(calculation_status, calculation_success)
    end

	#if (FLAGS.SCF.debug == true)
    #  close(json_debug)
    #end
  end

  return (F, D, C, E, calculation_status)
end

function scf_cycles(F::Array{T,2}, D::Array{T,2}, C::Array{T,2}, E::T,
  H::Array{T,2}, ortho::Array{T,2}, S::Array{T,2}, E_nuc::T, E_elec::T,
  E_old::T, basis::BasisStructs.Basis,
  scf_flags::Dict{String,Any}) where {T<:AbstractFloat}

  comm=MPI.COMM_WORLD

  scf_converged::Bool = true
  iter_converged::Bool = false

  iter_limit::Int64 = scf_flags["niter"]
  dele::T = scf_flags["dele"]
  rmsd::T = scf_flags["rmsd"]

  #== build DIIS arrays ==#
  ndiis::Int64 = scf_flags["ndiis"]
  F_array::Array{Array{T,2},1} = fill(zeros(basis.norb,basis.norb), ndiis)

  e::Array{T,2} = Matrix{T}(undef,basis.norb,basis.norb)
  e_array::Array{Array{T,2},1} = fill(zeros(basis.norb,basis.norb), ndiis)

  #== start convergence procedure ==#
  iter::Int64 = 1
  B_dim::Int64 = 1
  h5open("tei_batch.h5", "r") do tei::HDF5File
    F_temp::Array{T,2} = Matrix{T}(undef,basis.norb,basis.norb)
    D_old::Array{T,2} = Matrix{T}(undef,basis.norb,basis.norb)
    ΔD::Array{T,2} = Matrix{T}(undef,basis.norb,basis.norb)

    eri_batch::Array{T,1} = read(tei, "Integrals/1")
    eri_starts::Array{Int64,1} = read(tei, "Starts/1")
    eri_sizes::Array{Int64,1} = read(tei, "Sizes/1")

    while(!iter_converged)
      #== build fock matrix ==#
	  F_temp = twoei(F, D, tei, eri_batch, eri_starts, eri_sizes, H, basis)

	  F = MPI.Allreduce(F_temp,MPI.SUM,comm)
	  MPI.Barrier(comm)

	  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
        println("Skeleton Fock matrix:")
        display(F)
        println("")
	  end

	  F += H

      if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
        println("Total Fock matrix:")
        display(F)
        println("")
      end

	  #== do DIIS ==#
      e = F*D*S - S*D*F
	  e_array = [deepcopy(e), e_array[1:ndiis]...]
	  F_array = [deepcopy(F), F_array[1:ndiis]...]

	  if (iter > 1)
		B_dim += 1
		B_dim = min(B_dim,ndiis)
		try
		  F = DIIS(e_array, F_array, B_dim)
	    catch
		  B_dim = 2
		  F = DIIS(e_array, F_array, B_dim)
		end
      end

      #== obtain new F,D,C matrices ==#
      D_old = deepcopy(D)

	  F, D, C, E_elec = iteration(F, D, H, ortho, basis, scf_flags)

      #== dynamic damping of density matrix ==#
      damp_values::Array{T,1} = [ 0.25, 0.75 ]
      D_damp::Array{Array{T,2},1} = map(x -> x*D + (1.0-x)*D_old, damp_values)
      D_damp_rms::Array{T,1} = map(x->√(@∑ x-D_old x-D_old), D_damp)

      x::T = max(D_damp_rms...) > 1 ? min(damp_values...) :
        max(damp_values...)
      D = x*D + (1.0-x)*D_old

      #== check for convergence ==#
      ΔD = D - D_old
	  D_rms::T = √(@∑ ΔD ΔD)

	  E = E_elec+E_nuc
	  ΔE::T = E - E_old

	  if (MPI.Comm_rank(comm) == 0)
	    println(iter,"     ", E,"     ", ΔE,"     ", D_rms)
	  end

	  iter_converged = (abs(ΔE) <= dele) && (D_rms <= rmsd)
	  iter += 1
      if (iter > iter_limit)
        scf_converged = false
        break
      end

      #== if not converged, replace old D and E values for next iteration ==#
      #D_old = deepcopy(D)
      E_old = E
    end
  end

  return (F, D, C, E, iter, scf_converged)
end
#=
"""
	 iteration(F::Array{T,2}, D::Array{T,2}, H::Array{T,2}, ortho::Array{T,2})
Summary
======
Perform single SCF iteration.

Arguments
======
F = Current iteration's Fock Matrix

D = Current iteration's Density Matrix

H = One-electron Hamiltonian Matrix

ortho = Symmetric Orthogonalization Matrix
"""
=#
function iteration(F_μν::Array{T,2}, D::Array{T,2}, H::Array{T,2},
  ortho::Array{T,2}, basis::BasisStructs.Basis,
  scf_flags::Dict{String,Any}) where {T<:AbstractFloat}

  comm=MPI.COMM_WORLD

  #== obtain new orbital coefficients ==#
  F::Array{T,2} = transpose(ortho)*F_μν*ortho

  F_eval::Array{T,1} = eigvals(LinearAlgebra.Hermitian(F))

  F_evec::Array{T,2} = eigvecs(LinearAlgebra.Hermitian(F))
  F_evec = F_evec[:,sortperm(F_eval)] #sort evecs according to sorted evals

  C::Array{T,2} = ortho*F_evec

  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
    println("New orbitals:")
    display(C)
    println("")
  end

  #== build new density matrix ==#
  nocc::Int64 = basis.nels/2
  norb = basis.norb

  for i::Int64 in 1:basis.norb, j::Int64 in 1:basis.norb
    D[i,j] = @∑ C[i,1:nocc] C[j,1:nocc]
    #D[i,j] = @∑ C[1:nocc,i] C[1:nocc,j]
    D[i,j] *= 2
  end

  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
    println("New density matrix:")
    display(D)
    println("")
  end

  #== compute new SCF energy ==#
  EHF1::T = @∑ D F_μν
  EHF2::T = @∑ D H
  E_elec::T = (EHF1 + EHF2)/2

  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
    println("New energy:")
    println("$EHF1, $EHF2")
    println("")
  end

  return (F, D, C, E_elec)
end
#=
"""
	 index(a::Int64,b::Int64)
Summary
======
Triangular indexing determination.

Arguments
======
a = row index

b = column index
"""
=#
@inline function index(a::Int64,b::Int64)
  index::Int64 = (a*(a-1)) >> 1 #bitwise divide by 2
  index += b
  return index
end

#=
"""
	 twoei(F::Array{T}, D::Array{T}, tei::Array{T}, H::Array{T})
Summary
======
Perform Fock build step.

Arguments
======
F = Current iteration's Fock Matrix

D = Current iteration's Density Matrix

tei = Two-electron integral array

H = One-electron Hamiltonian Matrix
"""
=#

function twoei(F::Array{T,2}, D::Array{T,2}, tei::HDF5File,
  eri_batch::Array{T,1}, eri_starts::Array{Int64,1}, eri_sizes::Array{Int64,1},
  H::Array{T,2}, basis::BasisStructs.Basis) where {T<:AbstractFloat}

  comm=MPI.COMM_WORLD
  nsh::Int64 = length(basis.shells)
  nindices::Int64 = nsh*(nsh+1)*(nsh^2 + nsh + 2)/8

  quartets_per_batch::Int64 = 2500
  quartet_batch_num_old::Int64 = 1

  F = zeros(basis.norb,basis.norb)
  mutex::Base.Threads.Mutex = Base.Threads.Mutex()

  #eri_batch = read(tei, "Integrals/$quartet_batch_num_old")
  #eri_starts = read(tei, "Starts/$quartet_batch_num_old")
  #eri_sizes = read(tei, "Sizes/$quartet_batch_num_old")

  thread_index_counter::Threads.Atomic{Int64} = Threads.Atomic{Int64}(nindices)
  Threads.@threads for thread::Int64 in 1:Threads.nthreads()
    F_priv::Array{T,2} = zeros(basis.norb,basis.norb)

    bra::ShPair = ShPair(basis.shells[1], basis.shells[1])
	  ket::ShPair = ShPair(basis.shells[1], basis.shells[1])
	  quartet::ShQuartet = ShQuartet(bra,ket)

    while true
      ijkl_index::Int64 = Threads.atomic_sub!(thread_index_counter, 1)
      if (ijkl_index < 1) break end

      if(MPI.Comm_rank(comm) != ijkl_index%MPI.Comm_size(comm)) continue end
      bra_pair::Int64 = ceil(((-1+sqrt(1+8*ijkl_index))/2))
      ket_pair::Int64 = (ijkl_index%bra_pair)+1

      ish::Int64 = ceil(((-1+sqrt(1+8*bra_pair))/2))
      jsh::Int64 = (bra_pair%ish) + 1
      ksh::Int64 = ceil(((-1+sqrt(1+8*ket_pair))/2))
	    lsh::Int64 = (ket_pair%ksh) + 1

      ijsh::Int64 = index(ish,jsh)
		  klsh::Int64 = index(ksh,lsh)

		  if (klsh > ijsh) ish,jsh,ksh,lsh = ksh,lsh,ish,jsh end

	    bra = ShPair(basis.shells[ish], basis.shells[jsh])
	    ket = ShPair(basis.shells[ksh], basis.shells[lsh])
	    quartet = ShQuartet(bra,ket)

		  qnum_ij::Int64 = ish*(ish-1)/2 + jsh
	    qnum_kl::Int64 = ksh*(ksh-1)/2 + lsh
	    quartet_num::Int64 = qnum_ij*(qnum_ij-1)/2 + qnum_kl
		  #println("QUARTET: $ish, $jsh, $ksh, $lsh ($quartet_num):")

		  quartet_batch_num::Int64 = Int64(floor(quartet_num/
		    quartets_per_batch)) + 1

		  if quartet_batch_num != quartet_batch_num_old
		    eri_batch = read(tei, "Integrals/$quartet_batch_num")
		    eri_starts = read(tei, "Starts/$quartet_batch_num")
		    eri_sizes = read(tei, "Sizes/$quartet_batch_num")

		    quartet_batch_num_old = quartet_batch_num
		  end

		  quartet_num_in_batch::Int64 = quartet_num - quartets_per_batch*
		    (quartet_batch_num-1)
	    eri_quartet_batch::Array{T,1} = shellquart(eri_batch,
		   eri_starts, eri_sizes, quartet_num_in_batch)

		  dirfck(F_priv, D, eri_quartet_batch, quartet,
		    ish, jsh, ksh, lsh)
    end

    lock(mutex)
    F += F_priv
    unlock(mutex)
  end

  for iorb::Int64 in 1:basis.norb, jorb::Int64 in 1:basis.norb
    if (iorb != jorb)
      F[iorb,jorb] /= 2
    end
  end

  return F
end

function shellquart(eri_batch::Array{T,1}, eri_starts::Array{Int64,1},
  eri_sizes::Array{Int64,1}, quartet_num::Int64) where {T<:AbstractFloat}

  starting::Int64 = eri_starts[quartet_num]
  ending::Int64 = starting + (eri_sizes[quartet_num] - 1)

  return eri_batch[starting:ending]
end

function dirfck(F_priv::Array{T,2}, D::Array{T,2}, eri_batch::Array{T,1},
  quartet::ShQuartet, ish::Int64, jsh::Int64,
  ksh::Int64, lsh::Int64) where {T<:AbstractFloat}

  norb::Int64 = size(D)[1]

  nμ::Int64 = quartet.bra.sh_a.nbas
  nν::Int64 = quartet.bra.sh_b.nbas
  nλ::Int64 = quartet.ket.sh_a.nbas
  nσ::Int64 = quartet.ket.sh_b.nbas

  pμ::Int64 = quartet.bra.sh_a.pos
  pν::Int64 = quartet.bra.sh_b.pos
  pλ::Int64 = quartet.ket.sh_a.pos
  pσ::Int64 = quartet.ket.sh_b.pos

  μνλσ::Int64 = 0

  for μμ::Int64 in pμ:pμ+(nμ-1), νν::Int64 in pν:pν+(nν-1)
    μ::Int64, ν::Int64 = μμ,νν
    if (μμ < νν) continue end

    μν::Int64 = index(μμ,νν)

    for λλ::Int64 in pλ:pλ+(nλ-1), σσ::Int64 in pσ:pσ+(nσ-1)
      λ::Int64, σ::Int64 = λλ,σσ
      if (λλ < σσ) continue end

      λσ::Int64 = index(λλ,σσ)

      #if (μν < λσ) continue end

      #println("$μ, $ν, $λ, $σ")

      if (μν < λσ)
        two_shell::Bool = nμ == nν
        two_shell = two_shell || (nμ == nλ)
        two_shell = two_shell || (nμ == nσ)
        two_shell = two_shell || (nν == nλ)
        two_shell = two_shell || (nν == nσ)
        two_shell = two_shell || (nλ == nσ)

        three_shell::Bool = nμ == nν && nν == nλ
        three_shell = three_shell || (nμ == nν && nν == nσ)
        three_shell = three_shell || (nμ == nλ && nλ == nσ)
        three_shell = three_shell || (nν == nλ && nλ == nσ)

        four_shell::Bool = nμ == nν
        four_shell = four_shell && (nν == nλ)
        four_shell = four_shell && (nλ == nσ)

        if four_shell
          three_same::Bool = ish == jsh && jsh == ksh
          three_same = three_same || (ish == jsh && jsh == lsh)
          three_same = three_same || (ish == ksh && ksh == lsh)
          three_same = three_same || (jsh == ksh && ksh == lsh)

          four_same::Bool = ish == jsh
          four_same = four_same && jsh == ksh
          four_same = four_same && ksh == lsh

          if four_same
            continue
          elseif three_same
            if (μμ != λλ && νν != σσ)
              μ,ν,λ,σ = λλ,σσ,μμ,νν
            else
              continue
            end
          else
            continue
          end
        elseif three_shell
          if (μμ != λλ && νν != σσ)
              μ,ν,λ,σ = λλ,σσ,μμ,νν
          else
            continue
          end
        elseif two_shell
          if (ish == ksh && jsh == lsh &&
                        μμ != νν && μμ != λλ && μμ != σσ &&
                        νν != λλ && νν != σσ &&
                        λλ != σσ )
                      continue
          elseif (μμ != λλ && νν != σσ)
            μ,ν,λ,σ = λλ,σσ,μμ,νν
          else
            continue
          end
        end
      end

      μνλσ += 1

	  eri::T = eri_batch[μνλσ]
      #eri::T = 0
      if (abs(eri) <= 1E-10) continue end

      #println("$μ, $ν, $λ, $σ, $eri")
	  eri *= (μ == ν) ? 0.5 : 1.0
	  eri *= (λ == σ) ? 0.5 : 1.0
	  eri *= ((μ == λ) && (ν == σ)) ? 0.5 : 1.0

	  F_priv[λ,σ] += 4.0 * D[μ,ν] * eri
	  F_priv[μ,ν] += 4.0 * D[λ,σ] * eri
      F_priv[μ,λ] -= D[ν,σ] * eri
	  F_priv[μ,σ] -= D[ν,λ] * eri
	  F_priv[max(ν,λ),min(ν,λ)] -= D[max(μ,σ),min(μ,σ)] * eri
	  F_priv[max(ν,σ),min(ν,σ)] -= D[max(μ,λ),min(μ,λ)] * eri

	  F_priv[σ,λ] = F_priv[λ,σ]
	  F_priv[ν,μ] = F_priv[μ,ν]
	  F_priv[λ,μ] = F_priv[μ,λ]
	  F_priv[σ,μ] = F_priv[μ,σ]
	  F_priv[min(λ,ν),max(λ,ν)] = F_priv[max(ν,λ),min(ν,λ)]
	  F_priv[min(σ,ν),max(σ,ν)] = F_priv[max(ν,σ),min(ν,σ)]
    end
  end
end
