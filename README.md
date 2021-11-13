# SignalScope.jl
Oscilloscope view from various real-time signal sources

This package is not yet registered.

To install:
```julia
julia> # press ] for package mode
pkg> add https://github.com/org-arl/SignalScope.jl
```

To run with a demo random source:
```julia
julia> using SignalScope
julia> Scope(RandomSource())
```

To connect to [Unet audio](https://unetstack.net/) running on `localhost`:
```julia
julia> using SignalScope
julia> Scope(UnetSource("localhost"))
```
