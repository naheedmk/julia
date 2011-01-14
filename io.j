sizeof_ios_t = ccall(:jl_sizeof_ios_t, Int32, ())
sizeof_fd_set = ccall(:jl_sizeof_fd_set, Int32, ())

struct IOStream
    ios::Array{Uint8,1}

    global make_stdout_stream, close

    function close(s::IOStream)
        ccall(:ios_close, Void, (Ptr{Void},), s.ios)
    end

    # TODO: delay adding finalizer, e.g. for memio with a small buffer, or
    # in the case where we takebuf it.
    IOStream() = (x = new(zeros(Uint8,sizeof_ios_t));
                  finalizer(x, close);
                  x)

    make_stdout_stream() =
        new(ccall(:jl_stdout_stream, Any, ()))
end

fdio(fd::Int) = (s = IOStream();
                 ccall(:ios_fd, Void,
                       (Ptr{Uint8}, Int32, Int32), s.ios, fd, 0);
                 s)

open(fname::String, rd::Bool, wr::Bool, cr::Bool, tr::Bool) =
    (s = IOStream();
     if ccall(:ios_file, Ptr{Void},
              (Ptr{Uint8}, Ptr{Uint8}, Int32, Int32, Int32, Int32),
              s.ios, cstring(fname),
              int32(rd), int32(wr), int32(cr), int32(tr))==C_NULL
         error("could not open file ", fname)
     end;
     s)

open(fname::String) = open(fname, true, true, true, false)

memio() = memio(0)
function memio(x::Int)
    s = IOStream()
    ccall(:ios_mem, Ptr{Void}, (Ptr{Uint8}, Uint32), s.ios, uint32(x))
    s
end

convert(T::Type{Ptr}, s::IOStream) = convert(T, s.ios)

current_output_stream() =
    ccall(:jl_current_output_stream_obj, Any, ())::IOStream

set_current_output_stream(s::IOStream) =
    ccall(:jl_set_current_output_stream_obj, Void, (Any,), s)

function with_output_stream(s::IOStream, f::Function, args...)
    try
        set_current_output_stream(s)
        f(args...)
    catch e
        throw(e)
    end
end

takebuf_array(s::IOStream) =
    ccall(:jl_takebuf_array, Any, (Ptr{Void},), s.ios)::Array{Uint8,1}

takebuf_string(s::IOStream) =
    ccall(:jl_takebuf_string, Any, (Ptr{Void},), s.ios)::String

function print_to_array(size::Int32, f::Function, args...)
    s = memio(size)
    with_output_stream(s, f, args...)
    takebuf_array(s)
end

function print_to_string(size::Int32, f::Function, args...)
    s = memio(size)
    with_output_stream(s, f, args...)
    takebuf_string(s)
end

print_to_array(f::Function, args...) = print_to_array(0, f, args...)
print_to_string(f::Function, args...) = print_to_string(0, f, args...)

nthbyte(x::Int, n::Int) = (n > sizeof(x) ? uint8(0) : uint8((x>>>((n-1)<<3))))

write(s, x::Uint8) = error(typeof(s)," does not support byte I/O")

function write(s, x::Int)
    for n = 1:sizeof(x)
        write(s, nthbyte(x, n))
    end
end

write(s, x::Bool)    = write(s, uint8(x))
write(s, x::Float32) = write(s, boxsi32(unbox32(x)))
write(s, x::Float64) = write(s, boxsi64(unbox64(x)))

function write(s, a::Array)
    for i = 1:numel(a)
        write(s, a[i])
    end
end

read(s, x::Type{Uint8}) = error(typeof(s)," does not support byte I/O")

function read{T <: Int}(s, ::Type{T})
    x = zero(T)
    for n = 1:sizeof(x)
        x |= (convert(T,read(s,Uint8))<<((n-1)<<3))
    end
    x
end

read(s, ::Type{Bool})    = (read(s,Uint8)!=0)
read(s, ::Type{Float32}) = boxf32(unbox32(read(s,Int32)))
read(s, ::Type{Float64}) = boxf64(unbox64(read(s,Int64)))

read{T}(s, t::Type{T}, d1::Size, dims::Size...) =
    read(s, t, tuple(d1,dims...))

function read{T}(s, ::Type{T}, dims::Dims)
    a = Array(T, dims)
    for i = 1:numel(a)
        a[i] = read(s, T)
    end
    a
end

## low-level calls ##

write(s::IOStream, b::Uint8) =
    ccall(:ios_putc, Int32, (Int32, Ptr{Void}), int32(b), s.ios)

write(s::IOStream, c::Char) =
    ccall(:ios_pututf8, Int32, (Ptr{Void}, Char), s.ios, c)

function write{T}(s::IOStream, a::Array{T})
    if isa(T,BitsKind)
        ccall(:ios_write, Size,
              (Ptr{Void}, Ptr{Void}, Size), s.ios, a, numel(a)*sizeof(T))
    else
        invoke(write, (Any, Array), s, a)
    end
end

ASYNCH = false

function read(s::IOStream, ::Type{Uint8})
    # for asynch I/O
    if ASYNCH && nb_available(s) < 1
        io_wait(s)
    end
    b = ccall(:ios_getc, Int32, (Ptr{Void},), s.ios)
    if b == -1
        throw(EOFError())
    end
    uint8(b)
end

function read(s::IOStream, ::Type{Char})
    if ASYNCH && nb_available(s) < 1
        io_wait(s)
    end
    ccall(:jl_getutf8, Char, (Ptr{Void},), s.ios)
end

function read{T}(s::IOStream, ::Type{T}, dims::Dims)
    if isa(T,BitsKind)
        a = Array(T, dims...)
        nb = numel(a)*sizeof(T)
        if ASYNCH && nb_available(s) < nb
            io_wait(s)
        end
        ccall(:ios_readall, Size,
              (Ptr{Void}, Ptr{Void}, Size), s.ios, a, nb)
        a
    else
        invoke(read, (Any, Type, Size...), s, T, dims...)
    end
end

function readuntil(s::IOStream, delim::Uint8)
    dest = memio()
    ccall(:ios_copyuntil, Size,
          (Ptr{Void}, Ptr{Void}, Uint8), dest.ios, s.ios, delim)
    takebuf_string(dest)
end

function readall(s::IOStream)
    dest = memio()
    ccall(:ios_copyall, Size,
          (Ptr{Void}, Ptr{Void}), dest.ios, s.ios)
    takebuf_string(dest)
end

readline(s::IOStream) = readuntil(s, uint8('\n'))

flush(s::IOStream) = ccall(:ios_flush, Void, (Ptr{Void},), s.ios)

struct IOTally
    nbytes::Size
    IOTally() = new(zero(Size))
end

write(s::IOTally, x::Uint8) = (s.nbytes += 1; ())
flush(s::IOTally) = ()

## serializing values ##

ser_tag = idtable()
let i = 1
    global ser_tag
    for t = {Any, Symbol, Bool, Int8, Uint8, Int16, Uint16, Int32, Uint32,
             Int64, Uint64, Float32, Float64,
             TagKind, UnionKind, BitsKind, StructKind, Tuple, Array}
        ser_tag[t] = i
        i += 1
    end
end

writetag(s, x) = write(s, uint8(ser_tag[x]))

serialize(s, x::Bool) = (writetag(s,Bool); write(s, uint8(x)))

function serialize(s, t::Tuple)
    writetag(s, Tuple)
    write(s, int32(length(t)))
    for i = 1:length(t)
        serialize(s, t[i])
    end
end

function serialize(s, x::Symbol)
    writetag(s, Symbol)
    name = string(x)
    write(s, int32(length(name)))
    write(s, name)
end

function serialize(s, a::Array)
    writetag(s, Array)
    elty = typeof(a).parameters[1]
    serialize(s, elty)
    serialize(s, size(a))
    if isa(elty,BitsKind)
        write(s, a)
    else
        # TODO: handle uninitialized elements
        for i = 1:numel(a)
            serialize(s, a[i])
        end
    end
end

function serialize(s, t::TagKind)
    if has(ser_tag,t)
        write(s, uint8(0))
        writetag(s, t)
    else
        writetag(s, TagKind)
        serialize(s, t.name.name)
        serialize(s, t.parameters)
    end
end

function serialize(s, x)
    if has(ser_tag,x)
        write(s, uint8(0)) # tag 0 indicates just a tag
        writetag(s, x)
        return ()
    end
    t = typeof(x)
    if isa(t,BitsKind)
        if has(ser_tag,t)
            writetag(s, t)
        else
            writetag(s, BitsKind)
            serialize(s, t.name.name)
            serialize(s, t.parameters)
        end
        write(s, x)
    elseif isa(t,StructKind)
        writetag(s, StructKind)
        serialize(s, t.name.name)
        serialize(s, t.parameters)
        for n = t.names
            serialize(s, getfield(x, n))
        end
    else
        error(x," is not serializable")
    end
end

## deserializing values ##

deser_tag = idtable()
for (k, v) = ser_tag
    deser_tag[v] = k
end

function deserialize(s)
    b = int32(read(s, Uint8))
    if b == 0
        return deser_tag[int32(read(s, Uint8))]
    end
    tag = deser_tag[b]
    if is(tag,Tuple)
        len = read(s, Int32)
        return deserialize_tuple(s, len)
    end
    return deserialize(s, tag)
end

deserialize(s, t::BitsKind) = read(s, t)

function deserialize(s, ::Type{BitsKind})
    name = deserialize(s)::Symbol
    params = deserialize(s)
    t = apply_type(eval(name), params...)
    return read(s, t)
end

deserialize_tuple(s, len) = ntuple(len, i->deserialize(s))

deserialize(s, ::Type{Symbol}) = symbol(read(s, Uint8, read(s, Int32)))

function deserialize(s, ::Type{Array})
    elty = deserialize(s)
    dims = deserialize(s)
    if isa(elty,BitsKind)
        return read(s, elty, dims...)
    end
    A = Array(elty, dims...)
    for i = 1:numel(A)
        A[i] = deserialize(s)
    end
    return A
end

function deserialize(s, ::Type{TagKind})
    name = deserialize(s)::Symbol
    params = deserialize(s)
    apply_type(eval(name), params...)
end

function deserialize(s, ::Type{StructKind})
    name = deserialize(s)::Symbol
    params = deserialize(s)
    t = apply_type(eval(name), params...)
    # allow delegation to more specialized method
    return deserialize(s, t)
end

# default structure deserializer
function deserialize(s, t::Type)
    assert(isa(t,StructKind))
    nf = length(t.names)
    if nf == 0
        return ccall(:jl_new_struct, Any, (Any,), t)
    elseif nf == 1
        return ccall(:jl_new_struct, Any, (Any,Any), t, deserialize(s))
    elseif nf == 2
        return ccall(:jl_new_struct, Any,
                     (Any,Any,Any), t, deserialize(s), deserialize(s))
    elseif nf == 3
        return ccall(:jl_new_struct, Any,
                     (Any,Any,Any,Any), t, deserialize(s), deserialize(s),
                     deserialize(s))
    elseif nf == 4
        return ccall(:jl_new_struct, Any,
                     (Any,Any,Any,Any,Any), t, deserialize(s), deserialize(s),
                     deserialize(s), deserialize(s))
    else
        return ccall(:jl_new_structt, Any,
                     (Any,Any), t, ntuple(nf, i->deserialize(s)))
    end
end

## select interface ##

struct FDSet
    data::Array{Uint8,1}
    nfds::Int32

    function FDSet()
        ar = Array(Uint8, sizeof_fd_set)
        ccall(:jl_fd_zero, Void, (Ptr{Void},), ar)
        new(ar, 0)
    end
end

isempty(s::FDSet) = (s.nfds==0)

function add(s::FDSet, i::Int)
    if !(0 <= i < sizeof_fd_set*8)
        error("invalid descriptor ", i)
    end
    ccall(:jl_fd_set, Void, (Ptr{Void}, Int32), s.data, int32(i))
    if i >= s.nfds
        s.nfds = i+1
    end
    s
end

function has(s::FDSet, i::Int)
    if i < sizeof_fd_set*8 && i>=0
        return ccall(:jl_fd_isset, Int32,
                     (Ptr{Void}, Int32), s.data, int32(i))!=0
    end
    return false
end

function del(s::FDSet, i::Int)
    if i < sizeof_fd_set*8 && i>=0
        ccall(:jl_fd_clr, Void, (Ptr{Void}, Int32), s.data, int32(i))
        if i == s.nfds-1
            s.nfds -= 1
            while s.nfds>0 && !has(s, s.nfds-1)
                s.nfds -= 1
            end
        end
    end
    s
end

function del_all(s::FDSet)
    ccall(:jl_fd_zero, Void, (Ptr{Void},), s.data)
    s.nfds = 0
    s
end

function select_read(readfds::FDSet, timeout::Real)
    if timeout == Inf
        tout = C_NULL
    else
        tv = Array(Uint8, ccall(:jl_sizeof_timeval, Int32, ()))
        ccall(:jl_set_timeval, Void, (Ptr{Void}, Float64),
              tv, float64(timeout))
        tout = convert(Ptr{Void}, tv)
    end
    return ccall(dlsym(libc, :select), Int32,
                 (Int32, Ptr{Void}, Ptr{Void}, Ptr{Void}, Ptr{Void}),
                 readfds.nfds, readfds.data, C_NULL, C_NULL, tout)
end
