using MPI
using JuliaChem.SIMINT
using JuliaChem.JERI

#== initialize JuliaChem runtime ==#
function initialize()
  if(!MPI.Initialized())
    MPI.Init()
    SIMINT.initialize()
    JERI.initialize()
  else
    println("JuliaChem has already been initialized!")
  end

  #==set up scratch directory==#
  
end
export initialize

#== finalize JuliaChem runtime ==#
function finalize() 
  
  #== finalize MPI ==#
  if(!MPI.Finalized())
    MPI.Finalize()
    SIMINT.finalize()
    JERI.finalize()
  else
    println("JuliaChem has already been finalized!")
  end
  
  #==clean scratch directory==#
end
export finalize

function reset()
  SIMINT.reset()
end
export reset
