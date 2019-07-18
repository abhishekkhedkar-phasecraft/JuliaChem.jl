"""
  module JCInput
The module required for reading in and processing the selected input file.
Import this module into the script when you need to process an input file
(which will be every single calculation).
"""
module JCBasis

using BasisStructs
using ShellProcess

using MPI
using Base.Threads
#using Distributed
using HDF5

"""
  run(args::String)
Perform the operations necessary to read in, process, and extract data from the
selected input file.

One input variable is required:
1. args = The name of the input file.

Two variables are output:
1. input_info = Information gathered from the input file.
2. basis = The basis set shells, determined from the input file.

Thus, proper use of the Input.run() function would look like this:

```
input_info, basis = Input.run(args)
```
"""
function run(molecule::Dict{String,Any}, model::Dict{String,Any})
  comm=MPI.COMM_WORLD

  if (MPI.Comm_rank(comm) == 0)
    println("--------------------------------------------------------------------------------")
    println("                       ========================================                 ")
    println("                                GENERATING BASIS SET                            ")
    println("                       ========================================                 ")
    println(" ")
  end

  #== initialize variables ==#
  geometry_array::Array{Float64,1} = molecule["geometry"]
  symbols::Array{String} = molecule["symbols"]
  basis::String = model["basis"]
  charge::Int64 = molecule["charge"]

  num_atoms::Int64 = length(geometry_array)/3
  geometry_array_t::Array{Float64,2} = reshape(geometry_array,(3,num_atoms))
  geometry::Array{Float64,2} = transpose(geometry_array_t)

  basis_set::Basis = Basis(basis, charge)

  #== create basis set ==#
  for atom_idx::Int64 in 1:length(symbols)
    #== initialize variables needed for shell ==#
    atom_center::Array{Float64,1} = geometry[atom_idx,:]

    #== add shells on atom to basis set ==#
    process_shells(basis_set, symbols[atom_idx], atom_idx, atom_center)
  end

  if (MPI.Comm_rank(comm) == 0)
    println(" ")
    println("                       ========================================                 ")
    println("                                       END BASIS                                ")
    println("                       ========================================                 ")
  end

  return basis_set
end
export run

end
