import CUDAnative: DevicePtr

mutable struct CuArray{T,N} <: GPUArray{T,N}
  buf::Mem.Buffer
  dims::Dims{N}
  offset::Int

  function CuArray{T,N}(buf::Mem.Buffer, dims::Dims{N}, offset::Integer=0) where {T,N}
    xs = new{T,N}(buf, dims, offset)
    Mem.retain(buf)
    finalizer(unsafe_free!, xs)
    return xs
  end
end

CuVector{T} = CuArray{T,1}
CuMatrix{T} = CuArray{T,2}
CuVecOrMat{T} = Union{CuVector{T},CuMatrix{T}}

function unsafe_free!(xs::CuArray)
  Mem.release(xs.buf) && dealloc(xs.buf, prod(xs.dims)*sizeof(eltype(xs)))
  return
end

# Wrap CuArray around the data at the address given by `pointer`,
function Base.unsafe_wrap(::Union{Type{CuArray},Type{CuArray{T}},Type{CuArray{T,N}}},
                     p::Ptr{T}, dims::NTuple{N,Int}; own::Bool = false) where {T,N}
    @assert !own "not implemented yet"
    buf = CuArrays.Mem.Buffer(
            convert(Ptr{Cvoid}, p),
            prod(dims) * sizeof(T),
            CuArrays.CuCurrentContext())

    # add refcount in advance such that the refcount never drops to zero
    # TODO: fix me
    CuArrays.Mem.retain(buf)
    return CuArrays.CuArray{T, length(dims)}(buf, dims)
end

## construction

# type and dimensionality specified, accepting dims as tuples of Ints
CuArray{T,N}(::UndefInitializer, dims::Dims{N}) where {T,N} =
  CuArray{T,N}(alloc(prod(dims)*sizeof(T)), dims)

# type and dimensionality specified, accepting dims as series of Ints
CuArray{T,N}(::UndefInitializer, dims::Integer...) where {T,N} = CuArray{T,N}(undef, dims)

# type but not dimensionality specified
CuArray{T}(::UndefInitializer, dims::Dims{N}) where {T,N} = CuArray{T,N}(undef, dims)
CuArray{T}(::UndefInitializer, dims::Integer...) where {T} =
  CuArray{T}(undef, convert(Tuple{Vararg{Int}}, dims))

# empty vector constructor
CuArray{T,1}() where {T} = CuArray{T,1}(undef, 0)


Base.similar(a::CuArray{T,N}) where {T,N} = CuArray{T,N}(undef, size(a))
Base.similar(a::CuArray{T}, dims::Base.Dims{N}) where {T,N} = CuArray{T,N}(undef, dims)
Base.similar(a::CuArray, ::Type{T}, dims::Base.Dims{N}) where {T,N} = CuArray{T,N}(undef, dims)


## array interface

Base.elsize(::Type{<:CuArray{T}}) where {T} = sizeof(T)

Base.size(x::CuArray) = x.dims
Base.sizeof(x::CuArray) = Base.elsize(x) * length(x)


## interop with other arrays

CuArray{T,N}(xs::AbstractArray{T,N}) where {T,N} =
  isbits(xs) ?
    (CuArray{T,N}(undef, size(xs)) .= xs) :
    copyto!(CuArray{T,N}(undef, size(xs)), collect(xs))

CuArray{T,N}(xs::AbstractArray{S,N}) where {T,N,S} = CuArray{T,N}((x -> T(x)).(xs))

# underspecified constructors
CuArray{T}(xs::AbstractArray{S,N}) where {T,N,S} = CuArray{T,N}(xs)
(::Type{CuArray{T,N} where T})(x::AbstractArray{S,N}) where {S,N} = CuArray{S,N}(x)
CuArray(A::AbstractArray{T,N}) where {T,N} = CuArray{T,N}(A)

# idempotency
CuArray{T,N}(xs::CuArray{T,N}) where {T,N} = xs


## conversions

Base.convert(::Type{T}, x::T) where T <: CuArray = x



## interop with C libraries

"""
  buffer(array::CuArray [, index])

Get the native address of a CuArray, optionally at a given location `index`.
Equivalent of `Base.pointer` on `Array`s.
"""
function buffer(xs::CuArray, index=1)
  extra_offset = (index-1) * Base.elsize(xs)
  Mem.Buffer(xs.buf.ptr + xs.offset + extra_offset,
             sizeof(xs) - extra_offset,
             xs.buf.ctx)
end

Base.cconvert(::Type{Ptr{T}}, x::CuArray{T}) where T = buffer(x)
Base.cconvert(::Type{Ptr{Nothing}}, x::CuArray) = buffer(x)


## interop with CUDAnative

function Base.convert(::Type{CuDeviceArray{T,N,AS.Global}}, a::CuArray{T,N}) where {T,N}
    ptr = Base.unsafe_convert(Ptr{T}, a.buf)
    CuDeviceArray{T,N,AS.Global}(a.dims, DevicePtr{T,AS.Global}(ptr+a.offset))
end

Adapt.adapt_storage(::CUDAnative.Adaptor, xs::CuArray{T,N}) where {T,N} =
  convert(CuDeviceArray{T,N,AS.Global}, xs)


## other

function Base._reshape(parent::CuArray, dims::Dims)
  n = length(parent)
  prod(dims) == n || throw(DimensionMismatch("parent has $n elements, which is incompatible with size $dims"))
  return CuArray{eltype(parent),length(dims)}(parent.buf, dims, parent.offset)
end

# Interop with CPU array

function Base.unsafe_copyto!(dest::CuArray{T}, doffs, src::Array{T}, soffs, n) where T
    Mem.upload!(buffer(dest, doffs), pointer(src, soffs), n*sizeof(T))
    return dest
end

function Base.unsafe_copyto!(dest::Array{T}, doffs, src::CuArray{T}, soffs, n) where T
    Mem.download!(pointer(dest, doffs), buffer(src, soffs), n*sizeof(T))
    return dest
end

function Base.unsafe_copyto!(dest::CuArray{T}, doffs, src::CuArray{T}, soffs, n) where T
    Mem.transfer!(buffer(dest, doffs), buffer(src, soffs), n*sizeof(T))
    return dest
end

Base.collect(x::CuArray{T,N}) where {T,N} = copyto!(Array{T,N}(undef, size(x)), x)

function Base.deepcopy_internal(x::CuArray, dict::IdDict)
  haskey(dict, x) && return dict[x]::typeof(x)
  return dict[x] = copy(x)
end


# Utils

cuzeros(T::Type, dims...) = fill!(CuArray{T}(undef, dims...), 0)
cuones(T::Type, dims...) = fill!(CuArray{T}(undef, dims...), 1)
cuzeros(dims...) = cuzeros(Float32, dims...)
cuones(dims...) = cuones(Float32, dims...)

# optimized implementation of `fill!` for types that are directly supported by memset
const MemsetTypes = Dict(1=>UInt8, 2=>UInt16, 4=>UInt32)
const MemsetCompatTypes = Union{UInt8, Int8,
                                UInt16, Int16, Float16,
                                UInt32, Int32, Float32}
function Base.fill!(A::CuArray{T}, x) where T <: MemsetCompatTypes
  y = reinterpret(MemsetTypes[sizeof(T)], convert(T, x))
  Mem.set!(buffer(A), y, length(A))
  A
end

Base.print_array(io::IO, x::CuArray) = Base.print_array(io, collect(x))
Base.print_array(io::IO, x::LinearAlgebra.Adjoint{<:Any,<:CuArray}) = Base.print_array(io, LinearAlgebra.adjoint(collect(x.parent)))
Base.print_array(io::IO, x::LinearAlgebra.Transpose{<:Any,<:CuArray}) = Base.print_array(io, LinearAlgebra.transpose(collect(x.parent)))

# We don't convert isbits types in `adapt`, since they are already
# considered gpu-compatible.

Adapt.adapt_storage(::Type{<:CuArray}, xs::AbstractArray) =
  isbits(xs) ? xs : convert(CuArray, xs)

Adapt.adapt_storage(::Type{<:CuArray{T}}, xs::AbstractArray{<:Real}) where T <: AbstractFloat =
  isbits(xs) ? xs : convert(CuArray{T}, xs)

cu(xs) = adapt(CuArray{Float32}, xs)


Base.getindex(::typeof(cu), xs...) = CuArray([xs...])


# Generic linear algebra routines

function LinearAlgebra.tril!(A::CuMatrix{T}, d::Integer = 0) where T
    function kernel!(_A, _d)
        li = (blockIdx().x - 1) * blockDim().x + threadIdx().x
        m, n = size(_A)
        if 0 < li <= m*n
            i, j = Tuple(CartesianIndices(_A)[li])
            if i < j - _d
                _A[i, j] = 0
            end
        end
        return nothing
    end

    blk, thr = cudims(A)
    @cuda blocks=blk threads=thr kernel!(A, d)
    return A
end

function LinearAlgebra.triu!(A::CuMatrix{T}, d::Integer = 0) where T
    function kernel!(_A, _d)
        li = (blockIdx().x - 1) * blockDim().x + threadIdx().x
        m, n = size(_A)
        if 0 < li <= m*n
            i, j = Tuple(CartesianIndices(_A)[li])
            if j < i + _d
                _A[i, j] = 0
            end
        end
        return nothing
    end

    blk, thr = cudims(A)
    @cuda blocks=blk threads=thr kernel!(A, d)
    return A
end
