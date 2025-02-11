function solve!(model::MoominModel, optimizer; enumerate=1, stoichiometry=true, printLevel=1, timeLimit=1000,mipgap=0.01)
  printLevel == 0 || @info "Creating MILP..."
  MILP = createMILP(model, optimizer, stoichiometry=stoichiometry, timeLimit=timeLimit,mipgap=mipgap)
  printLevel < 2 && set_silent(MILP)
  cont = true
  timeLimitReached = false
  solFound = false
  counter = 1
  allowed_errors = enumerate*0.1 #max retry to avoid infinite loop
  count_errors = 0
  outputColours = []
  sol_val = 0
  while cont
    printLevel == 0 || @info "Solving MILP #$counter..."
    optimize!(MILP)
    if result_count(MILP) == 0
        @warn "NO RESULT"
        set_optimizer_attribute(MILP,"CPXPARAM_RandomSeed",abs(rand(Int8)))
        MILP = createMILP(model, optimizer, stoichiometry=stoichiometry, timeLimit=timeLimit,mipgap=mipgap)
        continue
    end
    #if termination_status(MILP) ==
    solFound = termination_status(MILP) == MOI.OPTIMAL
    timeLimitReached = termination_status(MILP) == MOI.TIME_LIMIT
    (solFound & (printLevel > 0)) && @info "Found solution!"
    (!solFound & (printLevel > 0) & (counter > 1) ) && @info "No optimum found."
    (!solFound & (printLevel > 0)) && @warn "Couldn't solve MILP."
    if timeLimitReached
        count_errors = count_errors+1
        #exclude sol in error
        #algo stuck on solution, change seed and re-generate problem
        if relative_gap(MILP) > 1 #if relative gap above 100% recreate problem
            set_optimizer_attribute(MILP,"CPXPARAM_RandomSeed",abs(rand(Int8)))
            MILP = createMILP(model, optimizer, stoichiometry=stoichiometry, timeLimit=timeLimit,mipgap=mipgap)
        end
        @warn "Solver time limit reached."
        if count_errors>allowed_errors
            counter=counter+1
            @warn "Max try reached."
        end
        @warn string(count_errors) * " failed MILP"
        if counter<enumerate
            cont=true
        else
            cont=false
        end
        continue
    end
    if solFound
      if isempty(outputColours)
        outputColours = interpretSolution(value.(MILP[:xPlus]),
                                          value.(MILP[:xMinus]),
                                          model.reactions.inputColours,
                                          model.reactions.reversible)
      else
        outputColours = [outputColours interpretSolution(value.(MILP[:xPlus]),
                                          value.(MILP[:xMinus]),
                                          model.reactions.inputColours,
                                          model.reactions.reversible)]
      end
      sol_val = objective_value(MILP)
      updateMILP!(MILP, outputColours)
    end
    cont = solFound & (counter<enumerate)
    counter = counter+1
  end

  fillOutputs!(model, outputColours)
end


function interpretSolution(xPlus, xMinus, inputColours, reversible)
  all(.!((xPlus .> 0.5) .& (xMinus .> 0.5))) || error("Something is wrong with a solution: `x+` and `x-` should be mutually exclusive.")

  outputColours = zeros(length(xPlus))
  outputColours[xPlus .> 0.5] .= 1
  outputColours[xMinus .> 0.5] .= -1
  outputColours[(xPlus .> 0.5) .& (inputColours .== -1)] .= -2
  outputColours[(xMinus .> 0.5) .& (inputColours .== 1)] .= 2
  outputColours[((xPlus .> 0.5) .| (xMinus .> 0.5)) .& (inputColours .==0) .& reversible] .= 6

  return outputColours
end

function fillOutputs!(model::MoominModel, outputColours)
  if isempty(outputColours)
    return
  end
  model.reactions.outputColours = convert.(Int64, outputColours)
  model.reactions.outputFrequency = round.(sum(outputColours .!= 0, dims=2) ./ size(outputColours, 2), digits=3)[:]
  combined = zeros(size(outputColours, 1))
  for row in 1:size(outputColours, 1)
    nonZ = findall(outputColours[row, :] .!= 0)
    if !isempty(nonZ)
      if all(outputColours[row, nonZ[1]] .== outputColours[row, nonZ])
        combined[row] = outputColours[row, nonZ[1]]
      else
        combined[row] = 6
      end
    end
  end
  model.reactions.combinedOutput = convert.(Int64, combined)
end

function createMILP(model::MoominModel, optimizer; stoichiometry=true, timeLimit=1000,mipgap=0.01)
  MILP = JuMP.Model(optimizer)
  if solver_name(MILP) == "CPLEX"
    set_optimizer_attribute(MILP, "CPXPARAM_TimeLimit", timeLimit)
    set_optimizer_attribute(MILP, "CPXPARAM_MIP_Tolerances_MIPGap", mipgap)
    set_optimizer_attribute(MILP, "CPXPARAM_MIP_Strategy_PresolveNode", 1) #force presolve at nodes

  elseif solver_name(MILP) == "Gurobi"
    set_optimizer_attribute(MILP, "TimeLimit", timeLimit)
  end

  if stoichiometry
    MILPstoich!(MILP, model)
  else
    MILPtopo!(MILP, model)
  end

  return MILP
end

function MILPstoich!(MILP, model::MoominModel)
  epsilon = 1
  (m, n) = size(model.reactions.S)

  # impose a priori colours
  lb = fill(-100., n)
  lb[.!model.reactions.reversible .& (model.reactions.inputColours.==1)] .= 0
  ub = fill(100., n)
  ub[.!model.reactions.reversible .& (model.reactions.inputColours.==-1)] .= 0

  @variable(MILP, v[i=1:n], lower_bound=lb[i], upper_bound=ub[i])
  @variable(MILP, xPlus[1:n], Bin)
  @variable(MILP, xMinus[1:n], Bin)

  # stoichiometry
  @constraint(MILP, model.reactions.S*v .== zeros(m))
  # x+=1 -> v>=epsilon
  @constraint(MILP, v .+ xPlus.*(lb .- epsilon) .>= lb)
  # x+=0 -> v<=0
  @constraint(MILP, v .- xPlus.*ub .<= zeros(n))
  # x-=1 -> v<=-epsilon
  @constraint(MILP, v .+ xMinus.*(ub .+ epsilon) .<= ub)
  # x-=0 -> v>=0
  @constraint(MILP, v .+ xMinus.*(-lb) .>= zeros(n))

  @objective(MILP, Max, model.reactions.weights' * xPlus + model.reactions.weights' * xMinus)
end

function MILPtopo!(MILP, model::MoominModel)
  (m, n) = size(model.reactions.S)

  @variable(MILP, y[1:m], Bin)
  @variable(MILP, xPlus[1:n], Bin)
  @variable(MILP, xMinus[1:n], Bin)

  # impose a priori colours
  notRed = (.!model.reactions.reversible) .& (model.reactions.inputColours.==-1)
  @constraint(MILP, xPlus[notRed] .== 0)
  notBlue = (.!model.reactions.reversible) .& (model.reactions.inputColours.==1)
  @constraint(MILP, xMinus[notBlue] .== 0)

  # x+ and x- cannot be 1 at the same time
  @constraint(MILP, xPlus .+ xMinus .<= ones(n))
  # if a connected arc is included, a node is included
  @constraint(MILP, (model.reactions.S .!= 0) * (xPlus.+xMinus) .<= sum(model.reactions.S .!= 0, dims=2).*y)
  # if a node is included, it has to have an outgoing arc
  @constraint(MILP, (model.reactions.S .< 0) * xPlus .+ (model.reactions.S .> 0) * xMinus .>= y)
  # if a node is included, it has to have an incoming arc
  @constraint(MILP, (model.reactions.S .> 0) * xPlus .+ (model.reactions.S .< 0) * xMinus .>= y)

  @objective(MILP, Max, model.reactions.weights' * xPlus + model.reactions.weights' * xMinus)
end

function updateMILP!(MILP, outputColours)
  if isempty(outputColours)
    return
  end
  if isnothing(constraint_by_name(MILP, "optimality"))
    @constraint(MILP, optimality, objective_function(MILP) == objective_value(MILP))
  end
  prevSol = outputColours[:, end] .!= 0
  @constraint(MILP, 2*(MILP[:xPlus]'*prevSol + MILP[:xMinus]'*prevSol)
                      - sum(MILP[:xPlus] .+ MILP[:xMinus])
                      <= sum(prevSol) - 1)
end
