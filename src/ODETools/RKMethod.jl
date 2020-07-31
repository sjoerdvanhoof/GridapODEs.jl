struct ButcherTableType{Kind} end

"""
Butcher table
"""
struct ButcherTable
  s::Int # stages
  p::Int # embedded order
  q::Int # order
  a::Matrix # A_ij
  b::Vector # b_j
  c::Vector # c_i
  d::Vector # d_j (embedded)
  type::ButcherTableType # identifier
end

"""
ButhcerTable constructor
"""
function ButcherTable(type::Symbol)
  btType = ButcherTableType{type}()
  createButcherTable(btType)
end

"""
Runge-Kutta ODE solver
"""
struct RKMethod <: ODESolver
  nls::NonlinearSolver
  dt::Float64
  bt::ButcherTable
  function RKMethod(nls,dt,type::Symbol)
    bt = ButcherTable(type)
    new(nls,dt,bt)
  end
end

function createButcherTable(type::ButcherTableType{:BE_1_0_1})
  s = 1
  p = 0
  q = 1
  a = reshape([1.0],1,1)
  b = [1.0]
  c = [1.0]
  d = [0.0]
  ButcherTable(s,p,q,a,b,c,d,type)
end
function createButcherTable(type::ButcherTableType{:SDIRK_2_1_2})
s = 2
p = 1
q = 2
a = [1.0 0.0; -1.0 1.0]
b = [0.5, 0.5]
c = [1.0, 0.0]
d = [1.0, 0.0]
ButcherTable(s,p,q,a,b,c,d,type)
end
function createButcherTable(type::ButcherTableType{:TRBDF2_3_3_2})
  s = 3
  p = 3
  q = 2
  aux = 2.0-√2.0
  a = [0.0 0.0 0.0; aux/2 aux/2 0.0; √2/4 √2/4 aux/2]
  b = [√2/4, √2/4, aux/2]
  c = [0.0, aux, 1.0]
  d = [(1.0-(√2/4))/3, ((3*√2)/4+1.0)/3, aux/6]
  ButcherTable(s,p,q,a,b,c,d,type)
end

function solve_step!(uf::AbstractVector,
  solver::RKMethod,
  op::ODEOperator,
  u0::AbstractVector,
  t0::Real,
  cache)

  # Unpack variables
  dt = solver.dt
  s = solver.bt.s
  a = solver.bt.a
  b = solver.bt.b
  c = solver.bt.c
  d = solver.bt.d

  # Create cache if not there
  if cache === nothing
    ode_cache = allocate_cache(op)
    vi = similar(u0)
    fi = [similar(u0)]
    nl_cache = nothing
  else
    ode_cache, vi, fi, nl_cache = cache
  end

  # Create RKNL operator
  nlop = RKMethodNonlinearOperator(op,t0,dt,u0,ode_cache,vi,fi,0,a)

  # Compute intermediate stages
  for i in 1:s

    # allocate space to store the RHS at i
    if (length(fi) < i)
      push!(fi,similar(u0))
    end

    # Skip stage solve if a_ii=0 => u_i=u_0, f_i = f_0
    if(a[i,i]==0)
      @assert c[i] == 0
      ti = t0
      update!(nlop,ti,fi,i)
      fi[i] = get_fi(u0,nlop,nl_cache)
    else
      # solve at stage i
      ti = t0 + c[i]*dt
      ode_cache = update_cache!(ode_cache,op,ti)
      update!(nlop,ti,fi,i)
      nl_cache = solve!(uf,solver.nls,nlop,nl_cache)
      fi[i] = get_fi(uf,nlop,nl_cache)
    end

  end

  # update
  uf = u0
  for i in 1:s
    uf = uf + dt*b[i]*fi[i]
  end

  cache = (ode_cache, vi, fi, nl_cache)

  tf = t0 + dt
  return (uf,tf,cache)

end

"""
Nonlinear operator that represents the Runge-Kutta nonlinear operator at a
given time step, i.e., A(t,u_i,(u_i-u_n)/dt)
"""
mutable struct RKMethodNonlinearOperator <: NonlinearOperator
  odeop::ODEOperator
  ti::Float64
  dt::Float64
  u0::AbstractVector
  ode_cache
  vi::AbstractVector
  fi::AbstractVector
  i::Int
  a::Matrix
end

function residual!(b::AbstractVector,op::RKMethodNonlinearOperator,x::AbstractVector)
  # A(t,ui,∂ui/∂t) = ∂ui/∂t - a_ii * f(ui,ti) - ∑_{j<i} a_ij * f(uj,tj) = 0
  # b = [1/a_ii * ∂u/∂t - f(ui,ti)]
  # Res_ij = - a_ij/a_ii * f(uj,ti)
  # b + ∑_{j<i} Res_ij = 0
  @assert (abs(op.a[op.i,op.i]) > 0.0)
  ui = x
  vi = op.vi
  vi = (x-op.u0)/(op.a[op.i,op.i]*op.dt)
  residual!(b,op.odeop,op.ti,ui,vi,op.ode_cache)
  for j in 1:op.i-1
    b .= b - op.a[op.i,j]/op.a[op.i,op.i] * op.fi[j]
  end
  b
end

function jacobian!(A::AbstractMatrix,op::RKMethodNonlinearOperator,x::AbstractVector)
  @assert (abs(op.a[op.i,op.i]) > 0.0)
  ui = x
  vi = op.vi
  vi = (x-op.u0)/(op.a[op.i,op.i]*op.dt)
  z = zero(eltype(A))
  fill_entries!(A,z)
  jacobian_and_jacobian_t!(A,op.odeop,op.ti,ui,vi,(1/(op.a[op.i,op.i]*op.dt)),op.ode_cache)
end

function allocate_residual(op::RKMethodNonlinearOperator,x::AbstractVector)
  allocate_residual(op.odeop,x,op.ode_cache)
end

function allocate_jacobian(op::RKMethodNonlinearOperator,x::AbstractVector)
  allocate_jacobian(op.odeop,x,op.ode_cache)
end

function zero_initial_guess(op::RKMethodNonlinearOperator)
  x0 = similar(op.u0)
  fill!(x0,zero(eltype(x0)))
  x0
end

function get_fi(x::AbstractVector, op::RKMethodNonlinearOperator, cache::Nothing)
  ui = x
  vi = op.vi
  if(op.a[op.i,op.i]==0.0)
    vi=zero(x)
  else
    vi = (x-op.u0)/(op.a[op.i,op.i]*op.dt)
  end
  b=similar(x)
  residual!(b,op.odeop,op.ti,ui,vi,op.ode_cache)
  (vi-b) # store fi for future stages
end
function get_fi(x::AbstractVector, op::RKMethodNonlinearOperator, cache)
  ui = x
  vi = op.vi
  if(op.a[op.i,op.i]==0.0)
    vi=zero(x)
  else
    vi = (x-op.u0)/(op.a[op.i,op.i]*op.dt)
  end
  residual!(cache.b,op.odeop,op.ti,ui,vi,op.ode_cache)
  (vi-cache.b) # store fi for future stages
end

function update!(op::RKMethodNonlinearOperator,ti::Float64,fi::AbstractVector,i::Int)
  op.ti = ti
  op.fi = fi
  op.i = i
end
