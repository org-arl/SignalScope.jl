using GLMakie
using FFTW
using SignalBase
using Statistics

export stop

@enum Mode TIME FREQ TIMEFREQ

mutable struct Scope
  fap::Makie.FigureAxisPlot
  mode::Mode
  fs::Float32
  n::Int
  nfft::Int
  y::Observable{Vector{Float32}}
  z::Observable{Matrix{Float32}}
  zmin::Observable{Float32}
  zmax::Observable{Float32}
  running::Bool
  dirty::Bool
  ybuf::Vector{Float32}
  zbuf::Matrix{Float32}
  closed::Bool
  waitfordirty::Threads.Condition
end

function Scope(fs::Float32; bufsize=4096, nfft=1024, history=1024)
  n = bufsize
  m = nfft ÷ 2 + 1
  t = range(0f0; length=n, step=1000f0/fs)
  y = Node(zeros(Float32, n))
  ybuf = similar(y[])
  z = Node(zeros(Float32, history, m))
  zbuf = similar(z[])
  fap = lines(t, y; axis=(xlabel="Time (ms)", xautolimitmargin=(0f0, 0f0)))
  display(fap)
  scope = Scope(fap, TIME, fs, n, nfft, y, z, Node(-30f0), Node(20f0), true, false,
    ybuf, zbuf, false, Threads.Condition())
  on(events(fap.figure).keyboardbutton) do event
    Consume(keypress(scope, event.key))
  end
  task = @async monitor(scope)
  scope
end

Base.show(io::IO, scope::Scope) = print(io, "Scope(...)")

function Base.close(scope::Scope)
  scope.closed = true
  lock(() -> notify(scope.waitfordirty), scope.waitfordirty)
  nothing
end

Base.run(scope::Scope) = (scope.running = true)
stop(scope::Scope) = (scope.running = false)

function mode!(scope::Scope, mode::Mode)
  scope.mode == mode && return scope
  scope.mode = mode
  if mode == TIME
    t = range(0f0; length=scope.n, step=1000f0/scope.fs)
    scope.y = Node(zeros(Float32, scope.n))
    scope.ybuf = similar(scope.y[])
    scope.fap = lines(t, scope.y; axis=(xlabel="Time (ms)", xautolimitmargin=(0f0, 0f0)))
  elseif mode == FREQ
    f = rfftfreq(scope.nfft, scope.fs) ./ 1000f0
    scope.y = Node(zeros(Float32, length(f)))
    scope.ybuf = similar(scope.y[])
    scope.fap = lines(f, scope.y; axis=(xlabel="Frequency (kHz)", xautolimitmargin=(0f0, 0f0)))
    ylims!(scope.zmin[], scope.zmax[])
  elseif mode == TIMEFREQ
    scope.z[] .= 0f0
    scope.zbuf .= 0f0
    n = size(scope.z[], 1)
    t = range(0f0; length=n, step=n/scope.fs)
    f = rfftfreq(scope.nfft, scope.fs) ./ 1000f0
    scope.fap = heatmap(t, f, scope.z;
      colorrange=@lift(($(scope.zmin), $(scope.zmax))),
      axis=(xlabel="Time (s)", ylabel="Frequency (kHz)"))
    Colorbar(scope.fap.figure[1,2], scope.fap.plot)
  else
    throw(ArgumentError("Bad mode"))
  end
  on(events(scope.fap.figure).keyboardbutton) do event
    Consume(keypress(scope, event.key))
  end
  display(scope.fap)
  scope
end

function psd(x, nfft)
  #w = 0.54 .+ 0.46 .* cos.(2π .* range(-0.5, 0.5; length=nfft))    # hamming
  w = cos.(π .* range(-0.5, 0.5; length=nfft)) .^ 2                 # hanning
  X = mean(abs.(rfft(x1 .* w)) for x1 ∈ Iterators.partition(x, nfft))
  20 .* log10.(X)
end

function Base.push!(scope::Scope, data)
  if scope.mode == TIME
    scope.ybuf .= data
  elseif scope.mode == FREQ
    scope.ybuf .= psd(data, scope.nfft)
  elseif scope.mode == TIMEFREQ
    scope.zbuf[1:end-1,:] .= scope.zbuf[2:end,:]
    scope.zbuf[end,:] .= psd(data, scope.nfft)
  end
  lock(scope.waitfordirty) do
    scope.dirty = true
    notify(scope.waitfordirty)
  end
  scope
end

function monitor(scope::Scope)
  try
    while true
      lock(scope.waitfordirty) do
        scope.dirty || wait(scope.waitfordirty)
        scope.dirty = false
      end
      scope.closed && break
      if scope.mode == TIME || scope.mode == FREQ
        scope.y[] .= scope.ybuf
        scope.y[] = scope.y[]
      elseif scope.mode == TIMEFREQ
        scope.z[] .= scope.zbuf
        scope.z[] = scope.z[]
      end
    end
  catch ex
    @error ex
  end
end

function keypress(scope::Scope, key)
  key == Keyboard._0 && reset_limits!(scope.fap.axis)
  key == Keyboard.a && autolimits!(scope.fap.axis)
  key == Keyboard.t && mode!(scope, TIME)
  key == Keyboard.f && mode!(scope, FREQ)
  key == Keyboard.s && mode!(scope, TIMEFREQ)
  false
end
