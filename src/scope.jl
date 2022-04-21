using GLMakie
using FFTW
using SignalBase
using Statistics

export Scope

@enum Mode TIME FREQ TIMEFREQ

mutable struct Scope
  fap::Makie.FigureAxisPlot
  mode::Mode
  fs::Float32
  n::Int
  nfft::Int
  ch::Observable{Int}
  dc::Observable{Bool}
  y::Observable{Vector{Float32}}
  z::Observable{Matrix{Float32}}
  zmax::Observable{Float32}
  zrange::Observable{Float32}
  running::Observable{Bool}
  dirty::Bool
  ybuf::Vector{Float32}
  zbuf::Matrix{Float32}
  closed::Bool
  waitfordirty::Threads.Condition
  src::Any
end

function Scope(; fs=48000f0, bufsize=4096, nfft=1024, history=256)
  n = bufsize
  m = nfft ÷ 2 + 1
  t = range(0f0; length=n, step=1000f0/Float32(fs))
  y = Observable(zeros(Float32, n))
  ybuf = similar(y[])
  z = Observable(zeros(Float32, history, m))
  zbuf = similar(z[])
  fap = lines(t, y; axis=(xlabel="Time (ms)", xautolimitmargin=(0f0, 0f0)))
  display(fap)
  scope = Scope(fap, TIME, Float32(fs), n, nfft, Observable(1), Observable(true), y, z, Observable(20f0), Observable(50f0),
    Observable(true), false, ybuf, zbuf, false, Threads.Condition(), nothing)
  annotate(scope)
  on(events(fap.figure).keyboardbutton) do event
    Consume(keypress(scope, event.action, event.key))
  end
  task = @async monitor(scope)
  scope
end

function Scope(ai; nfft=1024, history=256)
  scope = Scope(; fs=inputframerate(ai), bufsize=inputblocksize(ai), nfft, history)
  scope.src = ai
  connect(ai)
  startinputstream(ai, (t, x) -> begin
    if scope.ch[] ≤ size(x,2)
      if scope.dc[]
        push!(scope, @view x[:,scope.ch[]])
      else
        x1 = x[:,scope.ch[]]
        x1 .-= mean(x1)
        push!(scope, x1)
      end
    end
  end)
  scope
end

Base.show(io::IO, scope::Scope) = print(io, "Scope(...)")

function Base.close(scope::Scope)
  scope.closed = true
  lock(() -> notify(scope.waitfordirty), scope.waitfordirty)
  nothing
end

Base.run(scope::Scope, v=true) = (scope.running[] = v)

function mode!(scope::Scope, mode::Mode)
  scope.mode == mode && return scope
  scope.mode = mode
  if mode == TIME
    t = range(0f0; length=scope.n, step=1000f0/scope.fs)
    scope.y = Observable(zeros(Float32, scope.n))
    scope.ybuf = similar(scope.y[])
    scope.fap = lines(t, scope.y; axis=(xlabel="Time (ms)", xautolimitmargin=(0f0, 0f0)))
  elseif mode == FREQ
    f = rfftfreq(scope.nfft, scope.fs) ./ 1000f0
    scope.y = Observable(zeros(Float32, length(f)))
    scope.ybuf = similar(scope.y[])
    scope.fap = lines(f, scope.y; axis=(xlabel="Frequency (kHz)", xautolimitmargin=(0f0, 0f0)))
    ylims!(scope.zmax[] - scope.zrange[], scope.zmax[])
  elseif mode == TIMEFREQ
    scope.z[] .= -Inf32
    scope.zbuf .= -Inf32
    n = size(scope.z[], 1)
    t = range(0f0; length=n, step=scope.n/scope.fs)
    f = rfftfreq(scope.nfft, scope.fs) ./ 1000f0
    scope.fap = heatmap(t, f, scope.z;
      colorrange=@lift(($(scope.zmax) - $(scope.zrange), $(scope.zmax))),
      axis=(xlabel="Time (s)", ylabel="Frequency (kHz)"))
    Colorbar(scope.fap.figure[1,2], scope.fap.plot)
  else
    throw(ArgumentError("Bad mode"))
  end
  annotate(scope)
  on(events(scope.fap.figure).keyboardbutton) do event
    Consume(keypress(scope, event.action, event.key))
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
      if scope.running[]
        if scope.mode == TIME || scope.mode == FREQ
          scope.y[] .= scope.ybuf
          scope.y[] = scope.y[]
        elseif scope.mode == TIMEFREQ
          scope.z[] .= scope.zbuf
          scope.z[] = scope.z[]
        end
      end
    end
  catch ex
    @error ex
  end
  try
    scope.src === nothing || close(scope.src)
  catch ex
    @warn ex
  end
  display(Figure())
end

function Makie.MakieLayout.autolimits!(scope::Scope)
  autolimits!(scope.fap.axis)
  if scope.mode == FREQ
    ymax = 5 * ceil(Int, maximum(scope.y[])/5)
    ylims!(scope.fap.axis, ymax - scope.zrange[], ymax)
  elseif scope.mode == TIMEFREQ
    scope.zmax[] = 5 * ceil(Int, maximum(scope.z[])/5)
  end
end

function keypress(scope::Scope, action, key)
  action == Keyboard.press || return false
  key == Keyboard._0 && reset_limits!(scope.fap.axis)
  key == Keyboard._1 && (scope.ch[] = 1)
  key == Keyboard._2 && (scope.ch[] = 2)
  key == Keyboard._3 && (scope.ch[] = 3)
  key == Keyboard._4 && (scope.ch[] = 4)
  key == Keyboard.a && autolimits!(scope)
  key == Keyboard.minus && (scope.zmax[] -= 5)
  key == Keyboard.equal && (scope.zmax[] += 5)
  key == Keyboard.t && mode!(scope, TIME)
  key == Keyboard.f && mode!(scope, FREQ)
  key == Keyboard.s && mode!(scope, TIMEFREQ)
  key == Keyboard.q && close(scope)
  key == Keyboard.space && (scope.running[] = !scope.running[])
  key == Keyboard.d && (scope.dc[] = !scope.dc[])
  false
end

annotation(ch, dc, running) = """
  Channel $ch
  $(dc ? "DC coupling" : "AC coupling")
  $(running ? "RUNNING" : "STOPPED")
  """

function annotate(scope::Scope)
  s = lift(annotation, scope.ch, scope.dc, scope.running)
  fig = scope.fap.figure
  fig[1,1] = Label(fig, s;
    textsize = 14.0f0,
    tellheight = false,
    tellwidth = false,
    padding = (10.0f0, 10.0f0, 10.0f0, 10.0f0),
    halign = :right,
    valign = :top)
end
