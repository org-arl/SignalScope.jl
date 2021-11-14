export TransformedSource

struct TransformedSource
  f::Any
  src::Any
  fs::Float32
  blksize::Int
  nchannels::Int
end

function TransformedSource(f, src)
  fs = inputframerate(src)
  blksize = inputblocksize(src)
  ch = inputchannels(src)
  x = f(zeros(blksize, ch))
  fs *= size(x, 1) / blksize
  if x isa AbstractMatrix
    blksize, ch = size(x)
  else
    ch = 1
    blksize = length(x)
  end
  TransformedSource(f, src, fs, blksize, ch)
end

connect(src::TransformedSource) = connect(src.src)
Base.close(src::TransformedSource) = close(src.src)
stopinputstream(src::TransformedSource) = stopinputstream(src.src)

inputframerate(src::TransformedSource) = src.fs
inputblocksize(src::TransformedSource) = src.blksize
inputchannels(src::TransformedSource) = src.nchannels

function startinputstream(src::TransformedSource, callback)
  startinputstream(src.src, (t, data) -> callback(t, src.f(data)))
end
