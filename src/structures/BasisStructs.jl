mutable struct Shell
    am::Int32
    nbas::Int32
    pos::Int32
end
export Shell

Shell(am) = Shell(am,am_to_nbas_cart(am),1)
@inline function am_to_nbas_cart(am::Int32)
    return am*(am+1)/2
end

mutable struct ShPair
    sh_a::Shell
    sh_b::Shell

    am2::Int32
    nbas2::Int32
end
export ShPair

ShPair(sh_a,sh_b) = ShPair(sh_a,sh_b,sh_a.am+sh_b.am,sh_a.nbas*sh_b.nbas)

mutable struct ShQuartet
    bra::ShPair
    ket::ShPair
end
export ShQuartet

mutable struct Basis
    shells::Array{Shell,1}
end
export Basis

Basis() = Basis([])

function add_shell(basis_set::Basis, shell::Shell)
    shell.pos = (length(basis_set.shells) == 0) ?
                1 : basis_set.shells[length(basis_set.shells)].pos +
                    basis_set.shells[length(basis_set.shells)].nbas

    push!(basis_set.shells,shell)
end
export add_shell