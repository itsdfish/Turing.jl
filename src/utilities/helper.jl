############################################
# Julia 1.2 temporary fix - Julia PR 33303 #
############################################
if VERSION == v"1.2"
    @eval function namedtuple(::Type{NamedTuple{names, T}}, args::Tuple) where {names, T <: Tuple}
        if length(args) != length(names)
            throw(ArgumentError("Wrong number of arguments to named tuple constructor."))
        end
        # Note T(args) might not return something of type T; e.g.
        # Tuple{Type{Float64}}((Float64,)) returns a Tuple{DataType}
        $(Expr(:splatnew, :(NamedTuple{names,T}), :(T(args))))
    end
    @generated function ntmerge(nt1::NamedTuple{names1, T1}, nt2::NamedTuple{names2, T2}) where {names1, T1 <: Tuple, names2, T2 <: Tuple}
        names = (names1..., names2...)
        T = Tuple{T1.types..., T2.types...}
        f = :(NamedTuple{$names, $T})
        args = :((Tuple(nt1)..., Tuple(nt2)...))
        quote
            $(Expr(:splatnew, f, args))
        end
    end
else
    function namedtuple(::Type{NamedTuple{names, T}}, args::Tuple) where {names, T <: Tuple}
        return NamedTuple{names, T}(args)
    end
    ntmerge(nt1::NamedTuple, nt2::NamedTuple) = merge(nt1, nt2)
end

#####################################################
# Helper functions for vectorize/reconstruct values #
#####################################################

vectorize(d::UnivariateDistribution, r::Real) = [r]
vectorize(d::MultivariateDistribution, r::AbstractVector{<:Real}) = copy(r)
vectorize(d::MatrixDistribution, r::AbstractMatrix{<:Real}) = copy(vec(r))

# NOTE:
# We cannot use reconstruct{T} because val is always Vector{Real} then T will be Real.
# However here we would like the result to be specifric type, e.g. Array{Dual{4,Float64}, 2},
# otherwise we will have error for MatrixDistribution.
# Note this is not the case for MultivariateDistribution so I guess this might be lack of
# support for some types related to matrices (like PDMat).
reconstruct(d::UnivariateDistribution, val::AbstractVector) = val[1]
reconstruct(d::MultivariateDistribution, val::AbstractVector) = copy(val)
function reconstruct(d::MatrixDistribution, val::AbstractVector)
    return reshape(copy(val), size(d))
end
function reconstruct!(r, d::Distribution, val::AbstractVector)
    return reconstruct!(r, d, val)
end
function reconstruct!(r, d::MultivariateDistribution, val::AbstractVector)
    r .= val
    return r
end
function reconstruct(d::Distribution, val::AbstractVector, n::Int)
    return reconstruct(d, val, n)
end
function reconstruct(d::UnivariateDistribution, val::AbstractVector, n::Int)
    return copy(val)
end
function reconstruct(d::MultivariateDistribution, val::AbstractVector, n::Int)
    return copy(reshape(val, size(d)[1], n))
end
function reconstruct(d::MatrixDistribution, val::AbstractVector, n::Int)
    tmp = reshape(val, size(d)[1], size(d)[2], n)
    orig = [tmp[:, :, i] for i in 1:size(tmp, 3)]
    return orig
end
function reconstruct!(r, d::Distribution, val::AbstractVector, n::Int)
    return reconstruct!(r, d, val, n)
end
function reconstruct!(r, d::MultivariateDistribution, val::AbstractVector, n::Int)
    r .= val
    return r
end

struct FlattenIterator{Tname, Tvalue}
    name::Tname
    value::Tvalue
end

Base.length(iter::FlattenIterator) = _length(iter.value)
_length(a::AbstractArray) = sum(_length, a)
_length(a::AbstractArray{<:Number}) = length(a)
@inline _length(::Number) = 1

Base.eltype(iter::FlattenIterator{String}) = Tuple{String, _eltype(typeof(iter.value))}
_eltype(::Type{TA}) where {TA <: AbstractArray} = _eltype(eltype(TA))
@inline _eltype(::Type{T}) where {T <: Number} = T

@inline function Base.iterate(iter::FlattenIterator{String, <:Number}, i = 1)
    i === 1 && return (iter.name, iter.value), 2
    return nothing
end
@inline function Base.iterate(
    iter::FlattenIterator{String, <:AbstractArray{<:Number}}, 
    ind = (1,),
)
    i = ind[1]
    i > length(iter.value) && return nothing
    name = getname(iter, i)
    return (name, iter.value[i]), (i+1,)
end
@inline function Base.iterate(
    iter::FlattenIterator{String, T},
    ind = startind(T),
) where {T <: AbstractArray}
    i = ind[1]
    i > length(iter.value) && return nothing
    name = getname(iter, i)
    local out
    while i <= length(iter.value)
        v = iter.value[i]
        out = iterate(FlattenIterator(name, v), Base.tail(ind))
        out !== nothing && break
        i += 1
    end
    if out === nothing
        return nothing
    else
        return out[1], (i, out[2]...)
    end
end

@inline startind(::Type{<:AbstractArray{T}}) where {T} = (1, startind(T)...)
@inline startind(::Type{<:Number}) = ()
@inline startind(::Type{<:Any}) = throw("Type not supported.")
@inline function getname(iter::FlattenIterator, i::Int)
    name = string(ind2sub(size(iter.value), i))
    name = replace(name, "(" => "[");
    name = replace(name, ",)" => "]");
    name = replace(name, ")" => "]");
    name = iter.name * name
    return name
end
@inline ind2sub(v, i) = Tuple(CartesianIndices(v)[i])
