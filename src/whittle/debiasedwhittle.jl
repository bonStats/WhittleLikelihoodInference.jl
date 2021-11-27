"""
    DebiasedWhittleLikelihood(model::Type{<:TimeSeriesModel}, ts, Δ; lowerΩcutoff, upperΩcutoff)

Generate a function to evaluate the Debiased Whittle likelihood it's gradient and expected Hessian.

Create a callable struct which prealloctes memory appropriately.

    (f::DebiasedWhittleLikelihood)(θ)

Evaluates the Whittle likelihood at θ.

    (f::DebiasedWhittleLikelihood)(F,G,EH,θ)

Evaluates the Whittle likelihood at θ and stores the gradient and expected Hessian in G and EH respectively.
If F, G or EH equal nothing, then the function, gradient or expected Hessian are not evaluated repsectively.

# Aruguments
- `model`: the model for the process. Should be of type TimeSeriesModel, so `OU` and not `OU(1,1)`.
- `ts`: the timeseries in the form of an n by d matrix (where d is the dimension of the time series model).
- `Δ`: the sampling rate of the time series.
- `lowerΩcutoff`: the lower bound of the frequency range included in the likelihood.
- `upperΩcutoff`: the upper bound of the frequency range included in the likelihood.

Note that to use the gradient the model must have `grad_add_sdf!` or `grad_acv!` specified.
Similarly, to use the Hessian, the model must have `hess_add_sdf!` or `hess_acv!` specified.

# Examples
```julia-repl
julia> obj = DebiasedWhittleLikelihood(OU, ones(1000), 1)
Debiased Whittle likelihood for the OU model.

julia> obj([1.0, 1.0])
-1982.0676530999626

julia> F, G, EH = 0.0, zeros(2), zeros(2,2)
(0.0, [0.0, 0.0], [0.0 0.0; 0.0 0.0])

julia> obj(F, G, EH, [1.0, 1.0])
-1982.0676530999626

julia> G
2-element Vector{Float64}:
 1998.3136810970122
 -685.7904154568779

julia> H
2×2 Matrix{Float64}:
 -0.00967179   0.0607696
  0.0607696   -0.381827
```
"""
struct DebiasedWhittleLikelihood{T,S<:TimeSeriesModelStorage,M}
    data::DebiasedWhittleData{T}
    memory::S
    model::M
    function DebiasedWhittleLikelihood(
        model::Type{<:TimeSeriesModel{D}}, ts, Δ;
        lowerΩcutoff = 0, upperΩcutoff = Inf) where {D}
        
        Δ > 0 || error("Δ should be a positive.")
        D == size(ts,2) || error("timeseries is $(size(ts,2)) dimensional, but model is $D dimensional.")
        wdata = DebiasedWhittleData(model, ts, Δ, lowerΩcutoff = lowerΩcutoff, upperΩcutoff = upperΩcutoff)
        mem = allocate_memory_EI_FG(model, size(ts,1), Δ)
        new{eltype(wdata.I),typeof(mem),typeof(model)}(wdata,mem,model)
    end
end
(f::DebiasedWhittleLikelihood)(θ) = debiasedwhittle!(f.memory,f.model(θ),f.data)
(f::DebiasedWhittleLikelihood)(F,G,EH,θ) = debiasedwhittle_Fisher!(F,G,EH,f.memory,f.model(θ),f.data)
Base.show(io::IO, W::DebiasedWhittleLikelihood) = print(io, "Debiased Whittle likelihood for the $(W.model) model.")

## Interior functions

##
"""
    debiasedwhittle!(store::TimeSeriesModelStorage, model::TimeSeriesModel, data::GenWhittleData)

Function to compute the debiased Whittle likelihood using a preallocated store.
"""
function debiasedwhittle!(store::TimeSeriesModelStorage, model::TimeSeriesModel, data::GenWhittleData)
    EI!(store, model)
    return generalwhittle(store, data)
end

"""
    debiasedwhittle_FG!(F, G, store, model::TimeSeriesModel ,data::GenWhittleData)

Compute the debiased Whittle likelihood and its gradient using a preallocated store.
"""
function debiasedwhittle_FG!(F, G, store, model::TimeSeriesModel ,data::GenWhittleData)
    if F !== nothing || G !== nothing
        EI!(store, model)
    end
    if G !== nothing
        grad_EI!(store, model)
        grad_generalwhittle!(G, store, data)
    end
    if F !== nothing
        return generalwhittle(store, data)
    end
    return nothing
end

"""
    debiasedwhittle_FGH!(F, G, H, store, model::TimeSeriesModel, data::GenWhittleData)

Compute the debiased Whittle likelihood and its gradient and hessian using a preallocated store.
"""
function debiasedwhittle_FGH!(F, G, H, store, model::TimeSeriesModel, data::GenWhittleData)
    if F !== nothing || G !== nothing || H !== nothing
        EI!(store, model)
    end
    if G !== nothing || H !== nothing
        grad_EI!(store, model)
    end
    if H !== nothing
        hess_EI!(store, model)
        hess_generalwhittle!(H, store, data)
    end
    if G !== nothing
        grad_generalwhittle!(G, store, data)
    end
    if F !== nothing
        return generalwhittle(store, data)
    end
    return nothing
end

"""
    getallderiv(store::AdditiveStorage)
    getallderiv(store::TimeSeriesModelStorageGradient)

Extract all of the derivatives from a generic store.
"""
function getallderiv(store::AdditiveStorage)
    Vcat(getallderiv(store.store1), getallderiv(store.store2))
end
getallderiv(store::TimeSeriesModelStorageGradient) = extract_array(store.gradmemory)

"""
    extract_array(store::Sdf2EIStorage)
    extract_array(store::Acv2EIStorage)

Extract array from storage.
"""
extract_array(store::Sdf2EIStorage) = extract_array(store.acv2EI)
extract_array(store::Acv2EIStorage) = store.hermitianarray

"""
    debiasedwhittle_Ehess!(EH, store, data::GenWhittleData)

Compute the expected hessian of the de-biased Whittle likelihood.
"""
function debiasedwhittle_Ehess!(EH, store, data::GenWhittleData)
    EH .= zero(eltype(EH))
    ∇S = getallderiv(store)
    S = extract_array(extract_S(store))
    for iω = data.Ω_used_index
        @views invS = inv(S[iω]) # account for double frequency resolution
        for jpar = 1:size(EH, 1), kpar = 1:jpar
            @views EH[jpar,kpar] += real(tr(∇S[jpar, iω] * invS*∇S[kpar, iω] * invS))
        end
    end
    for jpar = 1:size(EH, 1)-1, kpar = jpar+1:size(EH, 1) # fill upper triangle from symmetry
        @views EH[jpar, kpar] = EH[kpar, jpar]
    end
    return nothing
end

"""
    debiasedwhittle_Fisher!(F, G, H, store, model::TimeSeriesModel, data::GenWhittleData)

Compute the debiased Whittle likelihood, its gradient and fisher information.
"""
function debiasedwhittle_Fisher!(F, G, H, store, model::TimeSeriesModel, data::GenWhittleData)
    if F !== nothing || G !== nothing || H !== nothing
        EI!(store, model)
    end
    if G !== nothing || H !== nothing
        grad_EI!(store, model)
    end
    if H !== nothing
        debiasedwhittle_Ehess!(H, store, data)
    end
    if G !== nothing
        grad_generalwhittle!(G, store, data)
    end
    if F !== nothing
        return generalwhittle(store, data)
    end
    return nothing
end