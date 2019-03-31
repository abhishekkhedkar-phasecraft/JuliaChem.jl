module JuliChem

Base.include(@__MODULE__,"src/input/module_includes.jl")

#----------------------------------------------------#
# julia_main function for statically-compiled binary #
#----------------------------------------------------#
Base.@ccallable function julia_main()::Cint
    julia_main_exe()
    return 0
end

#--------------------------------------------#
# julia_main function for dynamic julia runs #
#--------------------------------------------#
function julia_main()
    julia_main_exe()
end

#-----------------------------------#
# core julichem execution algorithm #
#-----------------------------------#
function julia_main_exe()
    println("                       ========================================                ")
    println("                                 Welcome to JuliChem!                          ")
    println("                        JuliChem is a software package written                 ")
    println("                          in Julia for the purpose of quantum                  ")
    println("                                 chemical calculations.                        ")
    println("                             Let's get this party started!                     ")
    println("                       ========================================                ")
    println(" ")
    println("                                 Authors: David Poole                          ")
    println(" ")

    script()

    #we have run to completion! :)
    println("--------------------------------------------------------------------------------------")
    println("                       ========================================                       ")
    println("                        The calculation has run to completion!                        ")
    println("                                       Sayonara!                                      ")
    println("                       ========================================                       ")
    return 0
end

#--------------------------------------------#
# we want to precompile all involved modules #
#--------------------------------------------#
if (isfile("snoop/precompile_Base.jl"))
    include("snoop/precompile_Base.jl")
    _precompile_()
end
if (isfile("snoop/precompile_Core.jl"))
    include("snoop/precompile_Core.jl")
    _precompile_()
end
if (isfile("snoop/precompile_Distributed.jl"))
    include("snoop/precompile_Distributed.jl")
    _precompile_()
end
if (isfile("snoop/precompile_Logging.jl"))
    include("snoop/precompile_Logging.jl")
    _precompile_()
end
if (isfile("snoop/precompile_LinearAlgebra.jl"))
    include("snoop/precompile_LinearAlgebra.jl")
    _precompile_()
end
if (isfile("snoop/precompile_JuliChem.jl"))
    include("snoop/precompile_JuliChem.jl")
    _precompile_()
end
if (isfile("snoop/precompile_unknown.jl"))
    include("snoop/precompile_unknown.jl")
    _precompile_()
end

end
