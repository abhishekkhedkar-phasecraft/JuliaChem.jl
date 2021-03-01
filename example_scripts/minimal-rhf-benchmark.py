#=============================#
#== put needed modules here ==#
#=============================#
import sys

import julia
from julia import Base
from julia import JuliaChem
from julia import Statistics
from julia import HypothesisTests 

#================================#
#== JuliaChem execution script ==#
#================================#
def script(input_file):
  try:
    #== initialize JuliaChem runtime ==#
    JuliaChem.initialize()

    #== read in input file ==#
    input_time1_t1 = Base.time_ns()/1e9
    molecule, driver, model, keywords = JuliaChem.JCInput.run(input_file, 
      output=2)
    input_time1_t2 = Base.time_ns()/1e9
    input_time1 = input_time1_t2 - input_time1_t1 

    input_time2_t1 = Base.time_ns()/1e9
    molecule, driver, model, keywords = JuliaChem.JCInput.run(input_file, 
      output=2)
    input_time2_t2 = Base.time_ns()/1e9
    input_time2 = input_time2_t2 - input_time2_t1
  
    input_jit = input_time1 - input_time2
    molecule, driver, model, keywords = JuliaChem.JCInput.run(input_file, 
      output=2)

    #== generate basis set ==#
    basis_time1_t1 = Base.time_ns()/1e9
    basis = JuliaChem.JCBasis.run(molecule, model, output=2)
    basis_time1_t2 = Base.time_ns()/1e9
    basis_time1 = basis_time1_t2 - basis_time1_t1 

    basis_time2_t1 = Base.time_ns()/1e9
    mol, basis = JuliaChem.JCBasis.run(molecule, model, output=2)
    basis_time2_t2 = Base.time_ns()/1e9
    basis_time2 = basis_time2_t2 - basis_time2_t1
  
    basis_jit = basis_time1 - basis_time2
    mol, basis = JuliaChem.JCBasis.run(molecule, model, output=2)

    #== perform scf benchmark ==#
    timeof = [] 
    scf_time1 = 0.0
    if (driver == "energy"):
      if (model["method"] == "RHF"):
        scf_time1_t1 = Base.time_ns()/1e9
        scf = JuliaChem.JCRHF.run(mol, basis, keywords["scf"], 
          output=2) 
        scf_time1_t2 = Base.time_ns()/1e9
        scf_time1 = scf_time1_t2 - scf_time1_t1 

        JuliaChem.reset()
      
        for index in range(1,5):
          molecule, driver, model, keywords = JuliaChem.JCInput.run(input_file, 
            output=2)
          mol, basis = JuliaChem.JCBasis.run(molecule, model, output=2)

          scf_timeof_t1 = Base.time_ns()/1e9
          scf = JuliaChem.JCRHF.run(mol, basis, keywords["scf"], 
            output=2) #initial run
          scf_timeof_t2 = Base.time_ns()/1e9
          timeof.append(scf_timeof_t2 - scf_timeof_t1) 
        
          JuliaChem.reset()
  
    scf_jit = scf_time1 - Statistics.mean(timeof)
  
    #== output relevant information ==# 
    print("Input JIT: ", input_jit)
    print("Basis JIT: ", basis_jit)
    print("SCF JIT: ", scf_jit)
    print("Total JIT: ", input_jit + basis_jit + scf_jit)
    print("")
  
    #== perform t-test to compare to GAMESS ==#
    p = HypothesisTests.OneSampleTTest(timeof,0.39+0.17)
    print(p)

    #== finalize JuliaChem runtime ==#
    JuliaChem.finalize()
  
  except Exception as e:                                                        
    bt = Base.catch_backtrace()                                                 
    msg = Base.sprint(Base.showerror, e, bt)                                    
    print(msg)                                                                  
                                                                                
    JuliaChem.finalize()                                                        
    exit()       
  
script(sys.argv[1])
