using Random

export RandomSource

struct RandomSource
  fs::Float32
  blksize::Int
  nchannels::Int
  streaming::Ref{Bool}
end

function RandomSource(fs; blksize=4096, nchannels=1)
  RandomSource(fs, blksize, nchannels, Ref(false))
end

connect(::RandomSource) = true
Base.close(src::RandomSource) = stopinputstream(src)

inputframerate(src::RandomSource) = src.fs
inputblocksize(src::RandomSource) = src.blksize
inputchannels(src::RandomSource) = src.nchannels

function startinputstream(src::RandomSource, callback)
  src.streaming[] && return
  src.streaming[] = true
  @async begin
    t0 = time()
    n = 0
    data = Matrix{Float32}(undef, src.blksize, src.nchannels)
    while src.streaming[]
      t = n / src.fs
      randn!(data)
      Δt = t0 + t - time()
      Δt > 0 && sleep(Δt)
      callback(round(Int, 1000000t), data)
      n += src.blksize
    end
  end
end

function stopinputstream(src::RandomSource)
  src.streaming[] = false
end
