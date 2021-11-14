using Fjage

export UnetSource

const RxBasebandSignalNtf = MessageClass(@__MODULE__, "org.arl.unet.bb.RxBasebandSignalNtf")

struct UnetSource
  gw::Gateway
  bb::AgentID
  fs::Float32
  blksize::Int
  nchannels::Int
  streaming::Ref{Bool}
end

function UnetSource(host="127.0.0.1", port=1100; blksize=4096, bb=nothing)
  Fjage.registermessages()
  gw = Gateway(host, port)
  try
    if bb === nothing
      bb = agentforservice(gw, "org.arl.unet.Services.BASEBAND")
    else
      bb = agent(gw, bb)
    end
    subscribe(gw, topic(bb))
    blksize === nothing || (bb.pbsblk = blksize)
    blksize = bb.pbsblk
    bb.pbscnt = 1
    ntf = receive(gw, RxBasebandSignalNtf, 5000)
    if ntf === nothing
      bb.pbscnt = 0
      throw(ErrorException("No data from host"))
    end
    UnetSource(gw, bb, Float32(ntf.fs), blksize, ntf.channels, Ref(false))
  catch ex
    close(gw)
    rethrow(ex)
  end
end

connect(::UnetSource) = true

function Base.close(src::UnetSource)
  stopinputstream(src)
  close(src.gw)
end

inputframerate(src::UnetSource) = src.fs
inputblocksize(src::UnetSource) = src.blksize
inputchannels(src::UnetSource) = src.nchannels

function startinputstream(src::UnetSource, callback)
  src.streaming[] && return
  src.bb.pbscnt = -1
  src.streaming[] = true
  @async begin
    t0 = time()
    while src.streaming[]
      ntf = receive(src.gw, RxBasebandSignalNtf, 1000)
      if ntf !== nothing && iszero(ntf.fc)
        t = time() - t0
        try
          data = transpose(reshape(ntf.signal, src.nchannels, src.blksize))
          callback(round(Int, 1000000t), data)
        catch ex
          @error "$ex"
        end
      end
    end
  end
end

function stopinputstream(src::UnetSource)
  try
    req = ParameterReq(recipient=src.bb)
    set!(req, "pbscnt", 0)
    send(src.gw, req)
  catch ex
    @error "$ex"
  end
  src.streaming[] = false
end
