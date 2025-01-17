"""
    WhittleLikelihood(model::Type{<:TimeSeriesModel}, ts, Δ; lowerΩcutoff, upperΩcutoff, taper)
    WhittleLikelihood(model::Type{<:TimeSeriesModel}, timeseries::TimeSeries; lowerΩcutoff, upperΩcutoff, taper)

Generate a function to evaluate the Whittle likelihood it's gradient and Hessian.

Create a callable struct which prealloctes memory appropriately.

    (f::WhittleLikelihood)(θ)

Evaluates the Whittle likelihood at θ.

    (f::WhittleLikelihood)(F,G,H,θ)

Evaluates the Whittle likelihood at θ and stores the gradient and Hessian in G and H respectively.
If F, G or H equal nothing, then the function, gradient or Hessian are not evaluated repsectively.

# Aruguments
- `model`: the model for the process. Should be of type TimeSeriesModel, so `OU` and not `OU(1,1)`.
- `ts`: the timeseries in the form of an n by d matrix (where d is the dimension of the time series model).
- `Δ`: the sampling rate of the time series.
- `timeseries`: can be provided instead of `ts` and `Δ`. Must be of type `TimeSeries`.
- `lowerΩcutoff`: the lower bound of the frequency range included in the likelihood.
- `upperΩcutoff`: the upper bound of the frequency range included in the likelihood.
- `taper`: optional taper which should be a vector of length `size(ts,1)`, or `nothing` in which case no taper will be used.

Note that to use the gradient the model must have `grad_add_sdf!` specified.
Similarly, to use the Hessian, the model must have `hess_add_sdf!` specified.

# Examples
```julia-repl
julia> obj = WhittleLikelihood(OU, ones(1000), 1)
Whittle likelihood for the OU model.

julia> obj([1.0, 1.0])
-2006.7870804551364

julia> F, G, H = 0.0, zeros(2), zeros(2,2)
(0.0, [0.0, 0.0], [0.0 0.0; 0.0 0.0])

julia> obj(F, G, H, [1.0, 1.0])
-2006.7870804551364

julia> G
2-element Vector{Float64}:
   2.777354965282642
 -17.45063591068618

julia> H
2×2 Matrix{Float64}:
 -0.00967179   0.0607696
  0.0607696   -0.381827
```

"""
struct WhittleLikelihood{T,S<:TimeSeriesModelStorage,M}
    data::WhittleData{T}
    memory::S
    function WhittleLikelihood(model, timeseries::TimeSeries; lowerΩcutoff = 0, upperΩcutoff = Inf, taper = nothing)
        WhittleLikelihood(model, timeseries.ts, timeseries.Δ; lowerΩcutoff = lowerΩcutoff, upperΩcutoff = upperΩcutoff, taper = taper)
    end
    function WhittleLikelihood(
        model::Type{<:TimeSeriesModel{D}}, ts, Δ;
        lowerΩcutoff = 0, upperΩcutoff = Inf, taper = nothing) where {D}
        
        Δ > 0 || throw(ArgumentError("Δ should be a positive."))
        D == size(ts,2) || throw(ArgumentError("timeseries is $(size(ts,2)) dimensional, but model is $D dimensional."))
        if taper !== nothing
            taper .*= inv(sqrt(sum(abs2,taper))) # normalise the taper
        end
        wdata = WhittleData(model, ts, Δ, lowerΩcutoff = lowerΩcutoff, upperΩcutoff = upperΩcutoff, taper = taper)
        mem = allocate_memory_sdf_FGH(model, size(ts,1), Δ)
        new{eltype(wdata.I),typeof(mem),model}(wdata,mem)
    end
end
(f::WhittleLikelihood{T,S,M})(θ) where {T,S,M} = whittle!(f.memory,M(θ),f.data)
function checksize(G,H,θ)
    G === nothing || size(G) == size(θ) || throw(ArgumentError("G should be nothing or same size as θ"))
    H === nothing || size(H) == (length(θ),length(θ)) || throw(ArgumentError("H should be nothing or size (length(θ),length(θ))"))
    nothing
end
function (f::WhittleLikelihood{T,S,M})(F,G,H,θ) where {T,S,M}
    checksize(G,H,θ)
    whittle_FGH!(F,G,H,f.memory,M(θ),f.data)
end
Base.show(io::IO, ::WhittleLikelihood{T,S,M}) where {T,S,M} = print(io, "Whittle likelihood for the $M model.")
getmodel(::WhittleLikelihood{T,S,M}) where {T,S,M} = M
## internal functions

"""
    whittle!(store, model::TimeSeriesModel, data::GenWhittleData)

Compute the Whittle likelihood using a preallocated store.
"""
function whittle!(store, model::TimeSeriesModel, data::GenWhittleData)
    asdf!(store, model)
    return @views generalwhittle(store, data)
end

"""
    whittle_FG!(F, G, store, model::TimeSeriesModel, data::GenWhittleData)

Compute the Whittle likelihood and its gradient using a preallocated store.
"""
function whittle_FG!(F, G, store, model::TimeSeriesModel, data::GenWhittleData)
    if F !== nothing || G !== nothing
        asdf!(store, model)
    end
    if G !== nothing
        grad_asdf!(store, model)
        grad_generalwhittle!(G, store, data)
    end
    if F !== nothing
        F = generalwhittle(store, data)
        return F
    end
    return nothing
end

"""
    whittle_FGH!(F, G, H, store, model::TimeSeriesModel, data::GenWhittleData)

Compute the debiased Whittle likelihood and its gradient and hessian using a preallocated store.
"""
function whittle_FGH!(F, G, H, store, model::TimeSeriesModel, data::GenWhittleData)
    if F !== nothing || G !== nothing || H !== nothing
        asdf!(store, model)
    end
    if G !== nothing || H !== nothing
        grad_asdf!(store, model)
    end
    if H !== nothing
        hess_asdf!(store, model)
        hess_generalwhittle!(H, store, data)
    end
    if G !== nothing
        grad_generalwhittle!(G, store, data)
    end
    if F !== nothing
        F = generalwhittle(store, data)
        return F
    end
    return nothing
end