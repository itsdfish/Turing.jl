module RandomVariables

using ...Turing: Turing, CACHERESET, CACHEIDCS, CACHERANGES, Model,
    AbstractSampler, Sampler, SampleFromPrior, SampleFromUniform,
    Selector, getspace, AbstractContext, DefaultContext
using ...Utilities: vectorize, reconstruct, reconstruct!
using Bijectors: SimplexDistribution, link, invlink
using Distributions

import ...Turing: runmodel!
import Base:    string,
                Symbol,
                ==,
                hash,
                in,
                getindex,
                setindex!,
                push!,
                show,
                isempty,
                empty!,
                getproperty,
                setproperty!,
                keys,
                haskey

export  VarName,
        AbstractVarInfo,
        VarInfo,
        UntypedVarInfo,
        getlogp,
        setlogp!,
        acclogp!,
        resetlogp!,
        set_retained_vns_del_by_spl!,
        is_flagged,
        set_flag!,
        unset_flag!,
        setgid!,
        updategid!,
        setorder!,
        istrans,
        link!,
        invlink!,
        tonamedtuple

####
#### Types for typed and untyped VarInfo
####


###########
# VarName #
###########
"""
```
struct VarName{sym}
    indexing  ::    String
end
```

A variable identifier. Every variable has a symbol `sym` and `indices `indexing`. 
The Julia variable in the model corresponding to `sym` can refer to a single value or 
to a hierarchical array structure of univariate, multivariate or matrix variables. `indexing` stores the indices that can access the random variable from the Julia 
variable.

Examples:

- `x[1] ~ Normal()` will generate a `VarName` with `sym == :x` and `indexing == "[1]"`.
- `x[:,1] ~ MvNormal(zeros(2))` will generate a `VarName` with `sym == :x` and
 `indexing == "[Colon(),1]"`.
- `x[:,1][2] ~ Normal()` will generate a `VarName` with `sym == :x` and
 `indexing == "[Colon(),1][2]"`.
"""
struct VarName{sym}
    indexing::String
end

abstract type AbstractVarInfo end

####################
# VarInfo metadata #
####################

"""
The `Metadata` struct stores some metadata about the parameters of the model. This helps
query certain information about a variable, such as its distribution, which samplers
sample this variable, its value and whether this value is transformed to real space or
not.

Let `md` be an instance of `Metadata`:
- `md.vns` is the vector of all `VarName` instances.
- `md.idcs` is the dictionary that maps each `VarName` instance to its index in
 `md.vns`, `md.ranges` `md.dists`, `md.orders` and `md.flags`.
- `md.vns[md.idcs[vn]] == vn`.
- `md.dists[md.idcs[vn]]` is the distribution of `vn`.
- `md.gids[md.idcs[vn]]` is the set of algorithms used to sample `vn`. This is used in
 the Gibbs sampling process.
- `md.orders[md.idcs[vn]]` is the number of `observe` statements before `vn` is sampled.
- `md.ranges[md.idcs[vn]]` is the index range of `vn` in `md.vals`.
- `md.vals[md.ranges[md.idcs[vn]]]` is the vector of values of corresponding to `vn`.
- `md.flags` is a dictionary of true/false flags. `md.flags[flag][md.idcs[vn]]` is the
 value of `flag` corresponding to `vn`.

To make `md::Metadata` type stable, all the `md.vns` must have the same symbol
and distribution type. However, one can have a Julia variable, say `x`, that is a
matrix or a hierarchical array sampled in partitions, e.g.
`x[1][:] ~ MvNormal(zeros(2), 1.0); x[2][:] ~ MvNormal(ones(2), 1.0)`, and is managed by
a single `md::Metadata` so long as all the distributions on the RHS of `~` are of the
same type. Type unstable `Metadata` will still work but will have inferior performance.
When sampling, the first iteration uses a type unstable `Metadata` for all the
variables then a specialized `Metadata` is used for each symbol along with a function
barrier to make the rest of the sampling type stable.
"""
struct Metadata{TIdcs <: Dict{<:VarName,Int}, TDists <: AbstractVector{<:Distribution}, TVN <: AbstractVector{<:VarName}, TVal <: AbstractVector{<:Real}, TGIds <: AbstractVector{Set{Selector}}}
    # Mapping from the `VarName` to its integer index in `vns`, `ranges` and `dists`
    idcs        ::    TIdcs # Dict{<:VarName,Int}

    # Vector of identifiers for the random variables, where `vns[idcs[vn]] == vn`
    vns         ::    TVN # AbstractVector{<:VarName}

    # Vector of index ranges in `vals` corresponding to `vns`
    # Each `VarName` `vn` has a single index or a set of contiguous indices in `vals`
    ranges      ::    Vector{UnitRange{Int}}

    # Vector of values of all the univariate, multivariate and matrix variables
    # The value(s) of `vn` is/are `vals[ranges[idcs[vn]]]`
    vals        ::    TVal # AbstractVector{<:Real}

    # Vector of distributions correpsonding to `vns`
    dists       ::    TDists # AbstractVector{<:Distribution}

    # Vector of sampler ids corresponding to `vns`
    # Each random variable can be sampled using multiple samplers, e.g. in Gibbs, hence the `Set`
    gids        ::    TGIds # AbstractVector{Set{Selector}}

    # Number of `observe` statements before each random variable is sampled
    orders      ::    Vector{Int}

    # Each `flag` has a `BitVector` `flags[flag]`, where `flags[flag][i]` is the true/false flag value corresonding to `vns[i]`
    flags       ::    Dict{String, BitVector}
end

###########
# VarInfo #
###########

"""
```
struct VarInfo{Tmeta, Tlogp} <: AbstractVarInfo
    metadata::Tmeta
    logp::Base.RefValue{Tlogp}
    num_produce::Base.RefValue{Int}
end
```

A light wrapper over one or more instances of `Metadata`. Let `vi` be an instance of
`VarInfo`. If `vi isa VarInfo{<:Metadata}`, then only one `Metadata` instance is used
for all the sybmols. `VarInfo{<:Metadata}` is aliased `UntypedVarInfo`. If
`vi isa VarInfo{<:NamedTuple}`, then `vi.metadata` is a `NamedTuple` that maps each
symbol used on the LHS of `~` in the model to its `Metadata` instance. The latter allows
for the type specialization of `vi` after the first sampling iteration when all the
symbols have been observed. `VarInfo{<:NamedTuple}` is aliased `TypedVarInfo`.

Note: It is the user's responsibility to ensure that each "symbol" is visited at least
once whenever the model is called, regardless of any stochastic branching. Each symbol
refers to a Julia variable and can be a hierarchical array of many random variables, e.g. `x[1] ~ ...` and `x[2] ~ ...` both have the same symbol `x`.
"""
struct VarInfo{Tmeta, Tlogp} <: AbstractVarInfo
    metadata::Tmeta
    logp::Base.RefValue{Tlogp}
    num_produce::Base.RefValue{Int}
end
const UntypedVarInfo = VarInfo{<:Metadata}
const TypedVarInfo = VarInfo{<:NamedTuple}

function VarInfo(model::Model, ctx = DefaultContext())
    vi = VarInfo()
    model(vi, SampleFromPrior(), ctx)
    return TypedVarInfo(vi)
end
(model::Model)() = model(Turing.VarInfo(), SampleFromPrior())

function VarInfo(old_vi::UntypedVarInfo, spl, x::AbstractVector)
    new_vi = deepcopy(old_vi)
    new_vi[spl] = x
    return new_vi
end
function VarInfo(old_vi::TypedVarInfo, spl, x::AbstractVector)
    md = newmetadata(old_vi.metadata, Val(getspace(spl)), x)
    VarInfo(md, Base.RefValue{eltype(x)}(old_vi.logp), Ref(old_vi.num_produce))
end
@generated function newmetadata(metadata::NamedTuple{names}, ::Val{space}, x) where {names, space}
    exprs = []
    offset = :(0)
    for f in names
        mdf = :(metadata.$f)
        if f in space || length(space) == 0
            len = :(length($mdf.vals))
            push!(exprs, :($f = Metadata($mdf.idcs,
                                        $mdf.vns,
                                        $mdf.ranges,
                                        x[($offset + 1):($offset + $len)],
                                        $mdf.dists,
                                        $mdf.gids,
                                        $mdf.orders,
                                        $mdf.flags
                                    )
                            )
            )
            offset = :($offset + $len)
        else
            push!(exprs, :($f = $mdf))
        end
    end
    length(exprs) == 0 && return :(NamedTuple())
    return :($(exprs...),)
end

####
#### Internal functions
####

"""
    Metadata()

Construct an empty type unstable instance of `Metadata`.
"""
function Metadata()
    vals  = Vector{Real}()
    flags = Dict{String, BitVector}()
    flags["del"] = BitVector()
    flags["trans"] = BitVector()

    return Metadata(
        Dict{VarName, Int}(),
        Vector{VarName}(),
        Vector{UnitRange{Int}}(),
        vals,
        Vector{Distributions.Distribution}(),
        Vector{Set{Selector}}(),
        Vector{Int}(),
        flags
    )
end

"""
    empty!(meta::Metadata)

Empty the fields of `meta`.

This is useful when using a sampling algorithm that assumes an empty `meta`, e.g. `SMC`.
"""
function empty!(meta::Metadata)
    empty!(meta.idcs)
    empty!(meta.vns)
    empty!(meta.ranges)
    empty!(meta.vals)
    empty!(meta.dists)
    empty!(meta.gids)
    empty!(meta.orders)
    for k in keys(meta.flags)
        empty!(meta.flags[k])
    end

    return meta
end

# Removes the first element of a NamedTuple. The pairs in a NamedTuple are ordered, so this is well-defined.
if VERSION < v"1.1"
    _tail(nt::NamedTuple{names}) where names = NamedTuple{Base.tail(names)}(nt)
else
    _tail(nt::NamedTuple) = Base.tail(nt)
end

const VarView = Union{Int, UnitRange, Vector{Int}}

"""
    getval(vi::UntypedVarInfo, vview::Union{Int, UnitRange, Vector{Int}})

Return a view `vi.vals[vview]`.
"""
getval(vi::UntypedVarInfo, vview::VarView) = view(vi.metadata.vals, vview)

"""
    setval!(vi::UntypedVarInfo, val, vview::Union{Int, UnitRange, Vector{Int}})

Set the value of `vi.vals[vview]` to `val`.
"""
setval!(vi::UntypedVarInfo, val, vview::VarView) = vi.metadata.vals[vview] = val
function setval!(vi::UntypedVarInfo, val, vview::Vector{UnitRange})
    if length(vview) > 0
        vi.metadata.vals[[i for arr in vview for i in arr]] = val
    end
    return val
end

"""
    getmetadata(vi::VarInfo, vn::VarName)

Return the metadata in `vi` that belongs to `vn`.
"""
getmetadata(vi::VarInfo, vn::VarName) = vi.metadata
getmetadata(vi::TypedVarInfo, vn::VarName) = getfield(vi.metadata, getsym(vn))

"""
    getidx(vi::VarInfo, vn::VarName)

Return the index of `vn` in the metadata of `vi` corresponding to `vn`.
"""
getidx(vi::VarInfo, vn::VarName) = getmetadata(vi, vn).idcs[vn]

"""
    getrange(vi::VarInfo, vn::VarName)

Return the index range of `vn` in the metadata of `vi`.
"""
getrange(vi::VarInfo, vn::VarName) = getmetadata(vi, vn).ranges[getidx(vi, vn)]

"""
    getranges(vi::AbstractVarInfo, vns::Vector{<:VarName})

Return the indices of `vns` in the metadata of `vi` corresponding to `vn`.
"""
function getranges(vi::AbstractVarInfo, vns::Vector{<:VarName})
    return mapreduce(vn -> getrange(vi, vn), vcat, vns, init=Int[])
end

"""
    getdist(vi::VarInfo, vn::VarName)

Return the distribution from which `vn` was sampled in `vi`.
"""
getdist(vi::VarInfo, vn::VarName) = getmetadata(vi, vn).dists[getidx(vi, vn)]

"""
    getval(vi::VarInfo, vn::VarName)

Return the value(s) of `vn`.

The values may or may not be transformed to Euclidean space.
"""
getval(vi::VarInfo, vn::VarName) = view(getmetadata(vi, vn).vals, getrange(vi, vn))

"""
    setval!(vi::VarInfo, val, vn::VarName)

Set the value(s) of `vn` in the metadata of `vi` to `val`.

The values may or may not be transformed to Euclidean space.
"""
setval!(vi::VarInfo, val, vn::VarName) = getmetadata(vi, vn).vals[getrange(vi, vn)] = val

"""
    getval(vi::VarInfo, vns::Vector{<:VarName})

Return the value(s) of `vns`.

The values may or may not be transformed to Euclidean space.
"""
function getval(vi::AbstractVarInfo, vns::Vector{<:VarName})
    return mapreduce(vn -> getval(vi, vn), vcat, vns)
end

"""
    getall(vi::VarInfo)

Return the values of all the variables in `vi`.

The values may or may not be transformed to Euclidean space.
"""
getall(vi::UntypedVarInfo) = vi.metadata.vals
getall(vi::TypedVarInfo) = vcat(_getall(vi.metadata)...)
@generated function _getall(metadata::NamedTuple{names}) where {names}
    exprs = []
    for f in names
        push!(exprs, :(metadata.$f.vals))
    end
    return :($(exprs...),)
end

"""
    setall!(vi::VarInfo, val)

Set the values of all the variables in `vi` to `val`.

The values may or may not be transformed to Euclidean space.
"""
setall!(vi::UntypedVarInfo, val) = vi.metadata.vals .= val
setall!(vi::TypedVarInfo, val) = _setall!(vi.metadata, val)
@generated function _setall!(metadata::NamedTuple{names}, val, start = 0) where {names}
    expr = Expr(:block)
    start = :(1)
    for f in names
        length = :(length(metadata.$f.vals))
        finish = :($start + $length - 1)
        push!(expr.args, :(metadata.$f.vals .= val[$start:$finish]))
        start = :($start + $length)
    end
    return expr
end

"""
    getsym(vn::VarName)

Return the symbol of the Julia variable used to generate `vn`.
"""
getsym(vn::VarName{sym}) where sym = sym

"""
    getgid(vi::VarInfo, vn::VarName)

Return the set of sampler selectors associated with `vn` in `vi`.
"""
getgid(vi::VarInfo, vn::VarName) = getmetadata(vi, vn).gids[getidx(vi, vn)]

"""
    settrans!(vi::VarInfo, trans::Bool, vn::VarName)

Set the `trans` flag value of `vn` in `vi`.
"""
function settrans!(vi::AbstractVarInfo, trans::Bool, vn::VarName)
    trans ? set_flag!(vi, vn, "trans") : unset_flag!(vi, vn, "trans")
end

"""
    syms(vi::VarInfo)

Returns a tuple of the unique symbols of random variables sampled in `vi`.
"""
syms(vi::UntypedVarInfo) = Tuple(unique!(map(getsym, vi.metadata.vns)))  # get all symbols
syms(vi::TypedVarInfo) = keys(vi.metadata)

# Get all indices of variables belonging to SampleFromPrior:
#   if the gid/selector of a var is an empty Set, then that var is assumed to be assigned to
#   the SampleFromPrior sampler
@inline function _getidcs(vi::UntypedVarInfo, ::SampleFromPrior)
    return filter(i -> isempty(vi.metadata.gids[i]) , 1:length(vi.metadata.gids))
end
# Get a NamedTuple of all the indices belonging to SampleFromPrior, one for each symbol
@inline function _getidcs(vi::TypedVarInfo, ::SampleFromPrior)
    return _getidcs(vi.metadata)
end
@generated function _getidcs(metadata::NamedTuple{names}) where {names}
    exprs = []
    for f in names
        push!(exprs, :($f = findinds(metadata.$f)))
    end
    length(exprs) == 0 && return :(NamedTuple())
    return :($(exprs...),)
end

# Get all indices of variables belonging to a given sampler
@inline function _getidcs(vi::AbstractVarInfo, spl::Sampler)
    # NOTE: 0b00 is the sanity flag for
    #         |\____ getidcs   (mask = 0b10)
    #         \_____ getranges (mask = 0b01)
    #if ~haskey(spl.info, :cache_updated) spl.info[:cache_updated] = CACHERESET end
    # Checks if cache is valid, i.e. no new pushes were made, to return the cached idcs
    # Otherwise, it recomputes the idcs and caches it
    #if haskey(spl.info, :idcs) && (spl.info[:cache_updated] & CACHEIDCS) > 0
    #    spl.info[:idcs]
    #else
        #spl.info[:cache_updated] = spl.info[:cache_updated] | CACHEIDCS
        idcs = _getidcs(vi, spl.selector, Val(getspace(spl)))
        #spl.info[:idcs] = idcs
    #end
    return idcs
end
@inline _getidcs(vi::UntypedVarInfo, s::Selector, space) = findinds(vi.metadata, s, space)
@inline _getidcs(vi::TypedVarInfo, s::Selector, space) = _getidcs(vi.metadata, s, space)
# Get a NamedTuple for all the indices belonging to a given selector for each symbol
@generated function _getidcs(metadata::NamedTuple{names}, s::Selector, ::Val{space}) where {names, space}
    exprs = []
    # Iterate through each varname in metadata.
    for f in names
        # If the varname is in the sampler space
        # or the sample space is empty (all variables)
        # then return the indices for that variable.
        if f in space || length(space) == 0
            push!(exprs, :($f = findinds(metadata.$f, s, Val($space))))
        end
    end
    length(exprs) == 0 && return :(NamedTuple())
    return :($(exprs...),)
end
@inline function findinds(f_meta, s, ::Val{space}) where {space}
    # Get all the idcs of the vns in `space` and that belong to the selector `s`
    return filter((i) ->
        (s in f_meta.gids[i] || isempty(f_meta.gids[i])) &&
        (isempty(space) || in(f_meta.vns[i], space)), 1:length(f_meta.gids))
end
@inline function findinds(f_meta)
    # Get all the idcs of the vns
    return filter((i) -> isempty(f_meta.gids[i]), 1:length(f_meta.gids))
end

# Get all vns of variables belonging to spl
_getvns(vi::AbstractVarInfo, spl::Sampler) = _getvns(vi, spl.selector, Val(getspace(spl)))
_getvns(vi::UntypedVarInfo, s::Selector, space) = view(vi.metadata.vns, _getidcs(vi, s, space))
function _getvns(vi::TypedVarInfo, s::Selector, space)
    return _getvns(vi.metadata, _getidcs(vi, s, space))
end
# Get a NamedTuple for all the `vns` of indices `idcs`, one entry for each symbol
@generated function _getvns(metadata, idcs::NamedTuple{names}) where {names}
    exprs = []
    for f in names
        push!(exprs, :($f = metadata.$f.vns[idcs.$f]))
    end
    length(exprs) == 0 && return :(NamedTuple())
    return :($(exprs...),)
end

# Get the index (in vals) ranges of all the vns of variables belonging to spl
@inline function _getranges(vi::AbstractVarInfo, spl::Sampler)
    ## Uncomment the spl.info stuff when it is concretely typed, not Dict{Symbol, Any}
    #if ~haskey(spl.info, :cache_updated) spl.info[:cache_updated] = CACHERESET end
    #if haskey(spl.info, :ranges) && (spl.info[:cache_updated] & CACHERANGES) > 0
    #    spl.info[:ranges]
    #else
        #spl.info[:cache_updated] = spl.info[:cache_updated] | CACHERANGES
        ranges = _getranges(vi, spl.selector, Val(getspace(spl)))
        #spl.info[:ranges] = ranges
        return ranges
    #end
end
# Get the index (in vals) ranges of all the vns of variables belonging to selector `s` in `space`
@inline function _getranges(vi::AbstractVarInfo, s::Selector, space)
    return _getranges(vi, _getidcs(vi, s, space))
end
@inline function _getranges(vi::UntypedVarInfo, idcs::Vector{Int})
    mapreduce(i -> vi.metadata.ranges[i], vcat, idcs, init=Int[])
end
@inline _getranges(vi::TypedVarInfo, idcs::NamedTuple) = _getranges(vi.metadata, idcs)

@generated function _getranges(metadata::NamedTuple, idcs::NamedTuple{names}) where {names}
    exprs = []
    for f in names
        push!(exprs, :($f = findranges(metadata.$f.ranges, idcs.$f)))
    end
    length(exprs) == 0 && return :(NamedTuple())
    return :($(exprs...),)
end
@inline function findranges(f_ranges, f_idcs)
    return mapreduce(i -> f_ranges[i], vcat, f_idcs, init=Int[])
end

"""
    set_flag!(vi::VarInfo, vn::VarName, flag::String)

Set `vn`'s value for `flag` to `true` in `vi`.
"""
function set_flag!(vi::VarInfo, vn::VarName, flag::String)
    return getmetadata(vi, vn).flags[flag][getidx(vi, vn)] = true
end

####
#### APIs for typed and untyped VarInfo
####

# VarName

"""
    VarName(sym, indexing)
    VarName{sym}(indexing::String)

Construct a new instance of `VarName{sym}`
"""
VarName(sym, indexing) = VarName{sym}(indexing)

"""
    VarName(vn::VarName, indexing::String)

Return a copy of `vn` with a new index `indexing`.
"""
function VarName(vn::VarName, indexing::String)
    return VarName{getsym(vn)}(indexing)
end

"""
    uid(vn::VarName)

Return a unique tuple identifier for `vn`.
"""
uid(vn::VarName) = (getsym(vn), vn.indexing)

hash(vn::VarName) = hash(uid(vn))

==(x::VarName, y::VarName) = hash(uid(x)) == hash(uid(y))

function string(vn::VarName)
    return "$(getsym(vn))$(vn.indexing)"
end
function string(vns::Vector{<:VarName})
    return replace(string(map(string, vns)), "String" => "")
end

"""
    Symbol(vn::VarName)

Return a `Symbol` represenation of the variable identifier `VarName`.
"""
Symbol(vn::VarName) = Symbol(string(vn))  # simplified symbol

"""
    in(vn::VarName, space::Set)

Check whether `vn`'s symbol is in `space`.
"""
in(::VarName, ::Tuple{}) = true
in(vn::VarName, space::Tuple)::Bool = getsym(vn) in space || _in(string(vn), space)

_in(::String, ::Tuple{}) = false
_in(vn_str::String, space::Tuple)::Bool = _in(vn_str, Base.tail(space))
function _in(vn_str::String, space::Tuple{Expr,Vararg})::Bool
    # Collect expressions from space
    expr = first(space)
    # Filter `(` and `)` out and get a string representation of `exprs`
    expr_str = replace(string(expr), r"\(|\)" => "")
    # Check if `vn_str` is in `expr_strs`
    valid = occursin(expr_str, vn_str)
    return valid || _in(vn_str, Base.tail(space))
end

# VarInfo

"""
    has_eval_num(spl::AbstractSampler)

Check whether `spl` is a `Sampler` and has a field called `eval_num` in its state variable.
"""
function has_eval_num(spl::AbstractSampler)
    return !(spl isa Union{SampleFromPrior, SampleFromUniform}) && 
           :eval_num in fieldnames(typeof(spl.state))
end

"""
    runmodel!(model::Model, vi::AbstractVarInfo, spl::AbstractSampler, ctx::AbstractContext)

Sample from `model` using the sampler `spl` storing the sample and log joint
probability in `vi`.
"""
function runmodel!(
    model::Model,
    vi::AbstractVarInfo,
    spl::AbstractSampler = SampleFromPrior(),
    ctx::AbstractContext = DefaultContext()
)
    setlogp!(vi, 0)
    if has_eval_num(spl)
        spl.state.eval_num += 1
    end
    model(vi, spl, ctx)
    return vi
end

VarInfo(meta=Metadata()) = VarInfo(meta, Ref{Real}(0.0), Ref(0))

"""
    TypedVarInfo(vi::UntypedVarInfo)

This function finds all the unique `sym`s from the instances of `VarName{sym}` found in
`vi.metadata.vns`. It then extracts the metadata associated with each symbol from the
global `vi.metadata` field. Finally, a new `VarInfo` is created with a new `metadata` as
a `NamedTuple` mapping from symbols to type-stable `Metadata` instances, one for each
symbol.
"""
function TypedVarInfo(vi::UntypedVarInfo)
    meta = vi.metadata
    new_metas = Metadata[]
    # Symbols of all instances of `VarName{sym}` in `vi.vns`
    syms_tuple = Tuple(syms(vi))
    for s in syms_tuple
        # Find all indices in `vns` with symbol `s`
        inds = findall(vn -> getsym(vn) === s, meta.vns)
        n = length(inds)
        # New `vns`
        sym_vns = getindex.((meta.vns,), inds)
        # New idcs
        sym_idcs = Dict(a => i for (i, a) in enumerate(sym_vns))
        # New dists
        sym_dists = getindex.((meta.dists,), inds)
        # New gids, can make a resizeable FillArray
        sym_gids = getindex.((meta.gids,), inds)
        @assert length(sym_gids) <= 1 ||
            all(x -> x == sym_gids[1], @view sym_gids[2:end])
        # New orders
        sym_orders = getindex.((meta.orders,), inds)
        # New flags
        sym_flags = Dict(a => meta.flags[a][inds] for a in keys(meta.flags))

        # Extract new ranges and vals
        _ranges = getindex.((meta.ranges,), inds)
        # `copy.()` is a workaround to reduce the eltype from Real to Int or Float64
        _vals = [copy.(meta.vals[_ranges[i]]) for i in 1:n]
        sym_ranges = Vector{eltype(_ranges)}(undef, n)
        start = 0
        for i in 1:n
            sym_ranges[i] = start + 1 : start + length(_vals[i])
            start += length(_vals[i])
        end
        sym_vals = foldl(vcat, _vals)

        push!(new_metas, Metadata(sym_idcs, sym_vns, sym_ranges, sym_vals,
                                    sym_dists, sym_gids, sym_orders, sym_flags)
            )
    end
    logp = vi.logp
    num_produce = vi.num_produce
    nt = NamedTuple{syms_tuple}(Tuple(new_metas))
    return VarInfo(nt, Ref(logp), Ref(num_produce))
end
TypedVarInfo(vi::TypedVarInfo) = vi

function getproperty(vi::VarInfo, f::Symbol)
    f === :logp && return getfield(vi, :logp)[]
    f === :num_produce && return getfield(vi, :num_produce)[]
    return getfield(vi, f)
end
function setproperty!(vi::VarInfo, f::Symbol, x)
    f === :logp && return getfield(vi, :logp)[] = x
    f === :num_produce && return getfield(vi, :num_produce)[] = x
    return setfield!(vi, f, x)
end

"""
    empty!(vi::VarInfo)

Empty the fields of `vi.metadata` and reset `vi.logp` and `vi.num_produce` to
zeros.

This is useful when using a sampling algorithm that assumes an empty `vi`, e.g. `SMC`.
"""
function empty!(vi::VarInfo)
    _empty!(vi.metadata)
    vi.logp = 0
    vi.num_produce = 0
    return vi
end
@inline _empty!(metadata::Metadata) = empty!(metadata)
@generated function _empty!(metadata::NamedTuple{names}) where {names}
    expr = Expr(:block)
    for f in names
        push!(expr.args, :(empty!(metadata.$f)))
    end
    return expr
end

# Functions defined only for UntypedVarInfo
"""
    keys(vi::UntypedVarInfo)

Return an iterator over all `vns` in `vi`.
"""
keys(vi::UntypedVarInfo) = keys(vi.metadata.idcs)

"""
    setgid!(vi::VarInfo, gid::Selector, vn::VarName)

Add `gid` to the set of sampler selectors associated with `vn` in `vi`.
"""
setgid!(vi::VarInfo, gid::Selector, vn::VarName) = push!(getmetadata(vi, vn).gids[getidx(vi, vn)], gid)

"""
    istrans(vi::VarInfo, vn::VarName)

Return true if `vn`'s values in `vi` are transformed to Euclidean space, and false if
they are in the support of `vn`'s distribution.
"""
istrans(vi::AbstractVarInfo, vn::VarName) = is_flagged(vi, vn, "trans")

"""
    getlogp(vi::VarInfo)

Return the log of the joint probability of the observed data and parameters sampled in
`vi`.
"""
getlogp(vi::AbstractVarInfo) = vi.logp

"""
    setlogp!(vi::VarInfo, logp::Real)

Set the log of the joint probability of the observed data and parameters sampled in
`vi` to `logp`.
"""
setlogp!(vi::AbstractVarInfo, logp::Real) = vi.logp = logp

"""
    acclogp!(vi::VarInfo, logp::Real)

Add `logp` to the value of the log of the joint probability of the observed data and
parameters sampled in `vi`.
"""
acclogp!(vi::AbstractVarInfo, logp::Real) = vi.logp += logp

"""
    resetlogp!(vi::VarInfo)

Reset the value of the log of the joint probability of the observed data and parameters
sampled in `vi` to 0.
"""
resetlogp!(vi::AbstractVarInfo) = setlogp!(vi, 0.0)

"""
    isempty(vi::VarInfo)

Return true if `vi` is empty and false otherwise.
"""
isempty(vi::UntypedVarInfo) = isempty(vi.metadata.idcs)
isempty(vi::TypedVarInfo) = _isempty(vi.metadata)
@generated function _isempty(metadata::NamedTuple{names}) where {names}
    expr = Expr(:&&, :true)
    for f in names
        push!(expr.args, :(isempty(metadata.$f.idcs)))
    end
    return expr
end

# X -> R for all variables associated with given sampler
"""
    link!(vi::VarInfo, spl::Sampler)

Transform the values of the random variables sampled by `spl` in `vi` from the support
of their distributions to the Euclidean space and set their corresponding `"trans"`
flag values to `true`.
"""
function link!(vi::UntypedVarInfo, spl::Sampler)
    # TODO: Change to a lazy iterator over `vns`
    vns = _getvns(vi, spl)
    if ~istrans(vi, vns[1])
        for vn in vns
            dist = getdist(vi, vn)
            # TODO: Use inplace versions to avoid allocations
            setval!(vi, vectorize(dist, link(dist, reconstruct(dist, getval(vi, vn)))), vn)
            settrans!(vi, true, vn)
        end
    else
        @warn("[Turing] attempt to link a linked vi")
    end
end
function link!(vi::TypedVarInfo, spl::AbstractSampler)
    vns = _getvns(vi, spl)
    return _link!(vi.metadata, vi, vns, Val(getspace(spl)))
end
@generated function _link!(metadata::NamedTuple{names}, vi, vns, ::Val{space}) where {names, space}
    expr = Expr(:block)
    for f in names
        if f in space || length(space) == 0
            push!(expr.args, quote
                f_vns = vi.metadata.$f.vns
                if ~istrans(vi, f_vns[1])
                    # Iterate over all `f_vns` and transform
                    for vn in f_vns
                        dist = getdist(vi, vn)
                        setval!(vi, vectorize(dist, link(dist, reconstruct(dist, getval(vi, vn)))), vn)
                        settrans!(vi, true, vn)
                    end
                else
                    @warn("[Turing] attempt to link a linked vi")
                end
            end)
        end
    end
    return expr
end

# R -> X for all variables associated with given sampler
"""
    invlink!(vi::VarInfo, spl::AbstractSampler)

Transform the values of the random variables sampled by `spl` in `vi` from the
Euclidean space back to the support of their distributions and sets their corresponding
`"trans"` flag values to `false`.
"""
function invlink!(vi::UntypedVarInfo, spl::AbstractSampler)
    vns = _getvns(vi, spl)
    if istrans(vi, vns[1])
        for vn in vns
            dist = getdist(vi, vn)
            setval!(vi, vectorize(dist, invlink(dist, reconstruct(dist, getval(vi, vn)))), vn)
            settrans!(vi, false, vn)
        end
    else
        @warn("[Turing] attempt to invlink an invlinked vi")
    end
end
function invlink!(vi::TypedVarInfo, spl::AbstractSampler)
    vns = _getvns(vi, spl)
    return _invlink!(vi.metadata, vi, vns, Val(getspace(spl)))
end
@generated function _invlink!(metadata::NamedTuple{names}, vi, vns, ::Val{space}) where {names, space}
    expr = Expr(:block)
    for f in names
        if f in space || length(space) == 0
            push!(expr.args, quote
                f_vns = vi.metadata.$f.vns
                if istrans(vi, f_vns[1])
                    # Iterate over all `f_vns` and transform
                    for vn in f_vns
                        dist = getdist(vi, vn)
                        setval!(vi, vectorize(dist, invlink(dist, reconstruct(dist, getval(vi, vn)))), vn)
                        settrans!(vi, false, vn)
                    end
                else
                    @warn("[Turing] attempt to invlink an invlinked vi")
                end
            end)
        end
    end
    return expr
end


"""
    islinked(vi::VarInfo, spl::Sampler)

Check whether `vi` is in the transformed space for a particular sampler `spl`.

Turing's Hamiltonian samplers use the `link` and `invlink` functions from 
[Bijectors.jl](https://github.com/TuringLang/Bijectors.jl) to map a constrained variable
(for example, one bounded to the space `[0, 1]`) from its constrained space to the set of 
real numbers. `islinked` checks if the number is in the constrained space or the real space.
"""
function islinked(vi::UntypedVarInfo, spl::Sampler)
    vns = _getvns(vi, spl)
    return istrans(vi, vns[1])
end
function islinked(vi::TypedVarInfo, spl::Sampler)
    vns = _getvns(vi, spl)
    return _islinked(vi, vns)
end
@generated function _islinked(vi, vns::NamedTuple{names}) where {names}
    out = []
    for f in names
        push!(out, :(length(vns.$f) == 0 ? false : istrans(vi, vns.$f[1])))
    end
    return Expr(:||, false, out...)
end

# The default getindex & setindex!() for get & set values
# NOTE: vi[vn] will always transform the variable to its original space and Julia type
"""
    getindex(vi::VarInfo, vn::VarName)
    getindex(vi::VarInfo, vns::Vector{<:VarName})

Return the current value(s) of `vn` (`vns`) in `vi` in the support of its (their)
distribution(s).

If the value(s) is (are) transformed to the Euclidean space, it is
(they are) transformed back.
"""
function getindex(vi::AbstractVarInfo, vn::VarName)
    @assert haskey(vi, vn) "[Turing] attempted to replay unexisting variables in VarInfo"
    dist = getdist(vi, vn)
    return istrans(vi, vn) ?
        invlink(dist, reconstruct(dist, getval(vi, vn))) :
        reconstruct(dist, getval(vi, vn))
end
function getindex(vi::AbstractVarInfo, vns::Vector{<:VarName})
    @assert haskey(vi, vns[1]) "[Turing] attempted to replay unexisting variables in VarInfo"
    dist = getdist(vi, vns[1])
    return istrans(vi, vns[1]) ?
        invlink(dist, reconstruct(dist, getval(vi, vns), length(vns))) :
        reconstruct(dist, getval(vi, vns), length(vns))
end

"""
    getindex(vi::VarInfo, spl::Union{SampleFromPrior, Sampler})

Return the current value(s) of the random variables sampled by `spl` in `vi`.

The value(s) may or may not be transformed to Euclidean space.
"""
getindex(vi::AbstractVarInfo, spl::SampleFromPrior) = copy(getall(vi))
getindex(vi::UntypedVarInfo, spl::Sampler) = copy(getval(vi, _getranges(vi, spl)))
function getindex(vi::TypedVarInfo, spl::Sampler)
    # Gets the ranges as a NamedTuple
    ranges = _getranges(vi, spl)
    # Calling getfield(ranges, f) gives all the indices in `vals` of the `vn`s with symbol `f` sampled by `spl` in `vi`
    return vcat(_getindex(vi.metadata, ranges)...)
end
# Recursively builds a tuple of the `vals` of all the symbols
@generated function _getindex(metadata, ranges::NamedTuple{names}) where {names}
    expr = Expr(:tuple)
    for f in names
        push!(expr.args, :(metadata.$f.vals[ranges.$f]))
    end
    return expr
end

"""
    setindex!(vi::VarInfo, val, vn::VarName)

Set the current value(s) of the random variable `vn` in `vi` to `val`.

The value(s) may or may not be transformed to Euclidean space.
"""
setindex!(vi::AbstractVarInfo, val, vn::VarName) = setval!(vi, val, vn)

"""
    setindex!(vi::VarInfo, val, spl::Union{SampleFromPrior, Sampler})

Set the current value(s) of the random variables sampled by `spl` in `vi` to `val`.

The value(s) may or may not be transformed to Euclidean space.
"""
setindex!(vi::AbstractVarInfo, val, spl::SampleFromPrior) = setall!(vi, val)
setindex!(vi::UntypedVarInfo, val, spl::Sampler) = setval!(vi, val, _getranges(vi, spl))
function setindex!(vi::TypedVarInfo, val, spl::Sampler)
    # Gets a `NamedTuple` mapping each symbol to the indices in the symbol's `vals` field sampled from the sampler `spl`
    ranges = _getranges(vi, spl)
    _setindex!(vi.metadata, val, ranges)
    return val
end
# Recursively writes the entries of `val` to the `vals` fields of all the symbols as if they were a contiguous vector.
@generated function _setindex!(metadata, val, ranges::NamedTuple{names}) where {names}
    expr = Expr(:block)
    offset = :(0)
    for f in names
        f_vals = :(metadata.$f.vals)
        f_range = :(ranges.$f)
        start = :($offset + 1)
        len = :(length($f_range))
        finish = :($offset + $len)
        push!(expr.args, :(@views $f_vals[$f_range] .= val[$start:$finish]))
        offset = :($offset + $len)
    end
    return expr
end

"""
    tonamedtuple(vi::Turing.VarInfo)

Convert a `vi` into a `NamedTuple` where each variable symbol maps to the values and 
indexing string of the variable.

For example, a model that had a vector of vector-valued
variables `x` would return

```julia
(x = ([1.5, 2.0], [3.0, 1.0], ["x[1]", "x[2]"]), )
```
"""
function tonamedtuple(vi::VarInfo)
    return tonamedtuple(vi.metadata, vi)
end
@generated function tonamedtuple(metadata::NamedTuple{names}, vi::VarInfo) where {names}
    length(names) === 0 && return :(NamedTuple())
    expr = Expr(:tuple)
    map(names) do f
        push!(expr.args, Expr(:(=), f, :(getindex.(Ref(vi), metadata.$f.vns), string.(metadata.$f.vns))))
    end
    return expr
end

@inline function findvns(vi, f_vns)
    if length(f_vns) == 0
        throw("Unidentified error, please report this error in an issue.")
    end
    return map(vn -> vi[vn], f_vns)
end

function Base.eltype(vi::AbstractVarInfo, spl::Union{AbstractSampler, SampleFromPrior})
    return eltype(Core.Compiler.return_type(getindex, Tuple{typeof(vi), typeof(spl)}))
end

"""
    haskey(vi::VarInfo, vn::VarName)

Check whether `vn` has been sampled in `vi`.
"""
haskey(vi::VarInfo, vn::VarName) = haskey(getmetadata(vi, vn).idcs, vn)
function haskey(vi::TypedVarInfo, vn::VarName)
    metadata = vi.metadata
    Tmeta = typeof(metadata)
    return getsym(vn) in fieldnames(Tmeta) && haskey(getmetadata(vi, vn).idcs, vn)
end

function show(io::IO, vi::UntypedVarInfo)
    vi_str = """
    /=======================================================================
    | VarInfo
    |-----------------------------------------------------------------------
    | Varnames  :   $(string(vi.metadata.vns))
    | Range     :   $(vi.metadata.ranges)
    | Vals      :   $(vi.metadata.vals)
    | GIDs      :   $(vi.metadata.gids)
    | Orders    :   $(vi.metadata.orders)
    | Logp      :   $(vi.logp)
    | #produce  :   $(vi.num_produce)
    | flags     :   $(vi.metadata.flags)
    \\=======================================================================
    """
    print(io, vi_str)
end

# Add a new entry to VarInfo
"""
    push!(vi::VarInfo, vn::VarName, r, dist::Distribution)

Push a new random variable `vn` with a sampled value `r` from a distribution `dist` to
the `VarInfo` `vi`.
"""
function push!(vi::AbstractVarInfo, vn::VarName, r, dist::Distribution)
    return push!(vi, vn, r, dist, Set{Selector}([]))
end

"""
    push!(vi::VarInfo, vn::VarName, r, dist::Distribution, spl::AbstractSampler)

Push a new random variable `vn` with a sampled value `r` sampled with a sampler `spl`
from a distribution `dist` to `VarInfo` `vi`.

The sampler is passed here to invalidate its cache where defined.
"""
function push!(vi::AbstractVarInfo, vn::VarName, r, dist::Distribution, spl::Sampler)
    spl.info[:cache_updated] = CACHERESET
    return push!(vi, vn, r, dist, spl.selector)
end
function push!(vi::AbstractVarInfo, vn::VarName, r, dist::Distribution, spl::AbstractSampler)
    return push!(vi, vn, r, dist)
end

"""
    push!(vi::VarInfo, vn::VarName, r, dist::Distribution, gid::Selector)

Push a new random variable `vn` with a sampled value `r` sampled with a sampler of
selector `gid` from a distribution `dist` to `VarInfo` `vi`.
"""
function push!(vi::AbstractVarInfo, vn::VarName, r, dist::Distribution, gid::Selector)
    return push!(vi, vn, r, dist, Set([gid]))
end
function push!(
            vi::VarInfo,
            vn::VarName,
            r,
            dist::Distribution,
            gidset::Set{Selector}
            )

    if vi isa UntypedVarInfo
        @assert ~(vn in keys(vi)) "[push!] attempt to add an exisitng variable $(sym(vn)) ($(vn)) to VarInfo (keys=$(keys(vi))) with dist=$dist, gid=$gid"
    elseif vi isa TypedVarInfo
        @assert ~(haskey(vi, vn)) "[push!] attempt to add an exisitng variable $(getsym(vn)) ($(vn)) to TypedVarInfo of syms $(syms(vi)) with dist=$dist, gid=$gidset"
    end

    val = vectorize(dist, r)

    meta = getmetadata(vi, vn)
    meta.idcs[vn] = length(meta.idcs) + 1
    push!(meta.vns, vn)
    l = length(meta.vals); n = length(val)
    push!(meta.ranges, l+1:l+n)
    append!(meta.vals, val)
    push!(meta.dists, dist)
    push!(meta.gids, gidset)
    push!(meta.orders, vi.num_produce)
    push!(meta.flags["del"], false)
    push!(meta.flags["trans"], false)

    return vi
end

"""
    setorder!(vi::VarInfo, vn::VarName, index::Int)

Set the `order` of `vn` in `vi` to `index`, where `order` is the number of `observe
statements run before sampling `vn`.
"""
function setorder!(vi::VarInfo, vn::VarName, index::Int)
    metadata = getmetadata(vi, vn)
    if metadata.orders[metadata.idcs[vn]] != index
        metadata.orders[metadata.idcs[vn]] = index
    end
    return vi
end

#######################################
# Rand & replaying method for VarInfo #
#######################################

"""
    is_flagged(vi::VarInfo, vn::VarName, flag::String)

Check whether `vn` has a true value for `flag` in `vi`.
"""
function is_flagged(vi::VarInfo, vn::VarName, flag::String)
    return getmetadata(vi, vn).flags[flag][getidx(vi, vn)]
end

"""
    unset_flag!(vi::VarInfo, vn::VarName, flag::String)

Set `vn`'s value for `flag` to `false` in `vi`.
"""
function unset_flag!(vi::VarInfo, vn::VarName, flag::String)
    return getmetadata(vi, vn).flags[flag][getidx(vi, vn)] = false
end

"""
    set_retained_vns_del_by_spl!(vi::VarInfo, spl::Sampler)

Set the `"del"` flag of variables in `vi` with `order > vi.num_produce` to `true`.
"""
function set_retained_vns_del_by_spl!(vi::UntypedVarInfo, spl::Sampler)
    # Get the indices of `vns` that belong to `spl` as a vector
    gidcs = _getidcs(vi, spl)
    if vi.num_produce == 0
        for i = length(gidcs):-1:1
          vi.metadata.flags["del"][gidcs[i]] = true
        end
    else
        for i in 1:length(vi.orders)
            if i in gidcs && vi.orders[i] > vi.num_produce
                vi.metadata.flags["del"][i] = true
            end
        end
    end
    return nothing
end
function set_retained_vns_del_by_spl!(vi::TypedVarInfo, spl::Sampler)
    # Get the indices of `vns` that belong to `spl` as a NamedTuple, one entry for each symbol
    gidcs = _getidcs(vi, spl)
    return _set_retained_vns_del_by_spl!(vi.metadata, gidcs, vi.num_produce)
end
@generated function _set_retained_vns_del_by_spl!(metadata, gidcs::NamedTuple{names}, num_produce) where {names}
    expr = Expr(:block)
    for f in names
        f_gidcs = :(gidcs.$f)
        f_orders = :(metadata.$f.orders)
        f_flags = :(metadata.$f.flags)
        push!(expr.args, quote
            # Set the flag for variables with symbol `f`
            if num_produce == 0
                for i = length($f_gidcs):-1:1
                    $f_flags["del"][$f_gidcs[i]] = true
                end
            else
                for i in 1:length($f_orders)
                    if i in $f_gidcs && $f_orders[i] > num_produce
                        $f_flags["del"][i] = true
                    end
                end
            end
        end)
    end
    return expr
end

"""
    updategid!(vi::VarInfo, vn::VarName, spl::Sampler)

Set `vn`'s `gid` to `Set([spl.selector])`, if `vn` does not have a sampler selector linked
and `vn`'s symbol is in the space of `spl`.
"""
function updategid!(vi::AbstractVarInfo, vn::VarName, spl::Sampler)
    if vn in getspace(spl)
        setgid!(vi, spl.selector, vn)
    end
end

end # end of module
