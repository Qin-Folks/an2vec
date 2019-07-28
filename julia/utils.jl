module Utils


export mean, normaliser, adjacency_matrix_diag, randn_like, markersize, loadparams!

using Statistics, Flux, LinearAlgebra, LightGraphs, SparseArrays
import Statistics.mean
import Flux.loadparams!


#
# Miscellaneous
#

function supertypes(T)
    current = T
    println(current)
    while current != Any
        current = supertype(current)
        println(current)
    end
end

function repeat_fn(n::Int64, fn, args...)
    for i = 1:n
        fn(args...)
    end
end

rowinmatrix(r::AbstractVector, m::AbstractMatrix) = any(all(reshape(r, 1, :) .== m, dims = 2))


#
# Neural network helpers
#

function normaliser(x)
    # Do case normalisation
    function _normaliser(y)
        ymean = mean(y, dims = 1)
        yscale = std(y, dims = 1)
        zeros = findall(yscale .== 0)
        yscale[zeros] = ones(eltype(yscale), size(zeros))
        (y .- ymean) ./ yscale
    end
    _normaliser
    # Input normalisation would be this
    # xmean = mean(x, dims = 2)
    # xscale = std(x, dims = 2)
    # zeros = findall(xscale .== 0)
    # xscale[zeros] = ones(eltype(xscale), size(zeros))
    # y -> (y .- xmean) ./ xscale
end

#
# Losses
#

import Flux.Tracker: @grad, track, data, nobacksies


regularizer(params; l = 0.01f0) = l * sum(x -> sum(x.^2), params)


function threadedσ!(out::AbstractArray, a::AbstractArray)
    Threads.@threads for i in eachindex(out)
        @inbounds out[i] = σ(a[i])
    end
    return out
end
threadedσ(a) = threadedσ!(similar(a), a)


klnormal(μ, logσ) = (exp(2logσ) + μ^2 - 1 - 2logσ) / 2

function threadedklnormal!(out::AbstractArray, μ::AbstractArray, logσ::AbstractArray)
    @assert size(μ) == size(logσ)
    Threads.@threads for i in eachindex(out)
        @inbounds out[i] = klnormal(μ[i], logσ[i])
    end
    return out
end
threadedklnormal(μ, logσ) = threadedklnormal!(similar(μ), μ, logσ)
threadedklnormal(μ::TrackedArray, logσ::TrackedArray) = track(threadedklnormal, μ, logσ)

function ∇threadedklnormal_μ!(out::AbstractArray, Δ::AbstractArray, μ::AbstractArray, logσ::AbstractArray)
    Threads.@threads for i in eachindex(out)
        @inbounds out[i] = Δ[i] * μ[i]
    end
    return out
end
∇threadedklnormal_μ(Δ, μ, logσ) = ∇threadedklnormal_μ!(similar(μ), Δ, μ, logσ)

function ∇threadedklnormal_logσ!(out::AbstractArray, Δ::AbstractArray, μ::AbstractArray, logσ::AbstractArray)
    Threads.@threads for i in eachindex(out)
        @inbounds out[i] = Δ[i] * (exp(2logσ[i]) - 1)
    end
    return out
end
∇threadedklnormal_logσ(Δ, μ, logσ) = ∇threadedklnormal_logσ!(similar(logσ), Δ, μ, logσ)

@grad function threadedklnormal(μ::AbstractArray, logσ::AbstractArray)
    threadedklnormal(data(μ), data(logσ)),
        Δ -> nobacksies(:threadedklnormal,
            (∇threadedklnormal_μ(data(Δ), data(μ), data(logσ)),
             ∇threadedklnormal_logσ(data(Δ), data(μ), data(logσ))))
end


function threadedsoftmaxcategoricallogprobloss!(out::AbstractVecOrMat, xs::AbstractVecOrMat, ys::AbstractVecOrMat)
    @assert size(xs) == size(ys)
    Threads.@threads for j in eachindex(out)
        @inbounds begin
            xi_max = xs[1, j]
            for i = 1:size(xs, 1)
                xi_max = max(xi_max, xs[i, j])
            end
            s = zero(eltype(out))
            for i = 1:size(xs, 1)
                s += exp(xs[i, j] - xi_max)
            end
            out[j] = zero(eltype(out))
            for i = 1:size(xs, 1)
                out[j] -= ys[i, j] * (xs[i, j] - xi_max - log(s))
            end
        end
    end
    return out
end
threadedsoftmaxcategoricallogprobloss(xs, ys) = threadedsoftmaxcategoricallogprobloss!(similar(xs, size(xs, 2)), xs, ys)
threadedsoftmaxcategoricallogprobloss(xs::TrackedArray, ys) = track(threadedsoftmaxcategoricallogprobloss, xs, ys)

function ∇threadedsoftmaxcategoricallogprobloss_xs!(out::AbstractArray, Δ::AbstractArray, xs::AbstractArray, ys::AbstractArray)
    smxs = softmax(xs)
    Threads.@threads for j in eachindex(Δ)
        @inbounds begin
            s = zero(eltype(out))
            for i = 1:size(xs, 1)
                s += ys[i, j]
            end
            for i = 1:size(xs, 1)
                out[i, j] = Δ[j] * (s * smxs[i, j]- ys[i, j])
            end
        end
    end
    return out
end
∇threadedsoftmaxcategoricallogprobloss_xs(Δ, xs, ys) = ∇threadedsoftmaxcategoricallogprobloss_xs!(similar(xs), Δ, xs, ys)

@grad function threadedsoftmaxcategoricallogprobloss(xs::AbstractArray, ys::AbstractArray)
    threadedsoftmaxcategoricallogprobloss(data(xs), data(ys)),
        Δ -> nobacksies(:threadedsoftmaxcategoricallogprobloss,
            (∇threadedsoftmaxcategoricallogprobloss_xs(data(Δ), data(xs), data(ys)),
             # Ignore differentiation over `ys`
             nothing))
end


logitbinarycrossentropy(logŷ, y; pos_weight = 1) = (1 - y) * logŷ + (1 + (pos_weight - 1) * y) * (log(1 + exp(-abs(logŷ))) + max(-logŷ, 0))

function threadedlogitbinarycrossentropy!(out::AbstractArray, logŷ::AbstractArray, y::AbstractArray; kw...)
    @assert size(logŷ) == size(y)
    Threads.@threads for i in eachindex(out)
        @inbounds out[i] = logitbinarycrossentropy(logŷ[i], y[i]; kw...)
    end
    return out
end
threadedlogitbinarycrossentropy(logŷ, y; kw...) = threadedlogitbinarycrossentropy!(similar(logŷ), logŷ, y; kw...)
threadedlogitbinarycrossentropy(logŷ::TrackedArray, y; kw...) = track(threadedlogitbinarycrossentropy, logŷ, y; kw...)

function ∇threadedlogitbinarycrossentropy_logits!(out::AbstractArray, Δ::AbstractArray, logŷ::AbstractArray, y::AbstractArray; pos_weight)
    Threads.@threads for i in eachindex(out)
        @inbounds out[i] = Δ[i] * (σ(logŷ[i]) * (y[i] * (pos_weight - 1) + 1) - y[i] * pos_weight)
    end
    return out
end
∇threadedlogitbinarycrossentropy_logits(Δ, logŷ, y; kw...) = ∇threadedlogitbinarycrossentropy_logits!(similar(logŷ), Δ, logŷ, y; kw...)

function ∇threadedlogitbinarycrossentropy_labels!(out::AbstractArray, Δ::AbstractArray, logŷ::AbstractArray, y::AbstractArray; pos_weight)
    Threads.@threads for i in eachindex(out)
        @inbounds out[i] = Δ[i] * (max(logŷ[i], 0) * (pos_weight - 1) - pos_weight * logŷ[i] + (pos_weight - 1) * log(1 + exp(-abs(logŷ[i]))))
    end
    return out
end
∇threadedlogitbinarycrossentropy_labels(Δ, logŷ, y; kw...) = ∇threadedlogitbinarycrossentropy_labels!(similar(y), Δ, logŷ, y; kw...)

@grad function threadedlogitbinarycrossentropy(logŷ::AbstractArray, y::AbstractArray; kw...)
    threadedlogitbinarycrossentropy(data(logŷ), data(y); kw...),
        Δ -> nobacksies(:threadedlogitbinarycrossentropy,
            (∇threadedlogitbinarycrossentropy_logits(data(Δ), data(logŷ), data(y); kw...),
             # Ignore the ∇threadedlogitbinarycrossentropy_labels gradient
             nothing))
end


normallogprobloss(μ, logσ, y) = log(2oftype(μ, π)) / 2 + logσ + (y - μ)^2 * exp(-2logσ) / 2

function threadednormallogprobloss!(out::AbstractArray, μ::AbstractArray, logσ::AbstractArray, y::AbstractArray)
    @assert size(μ) == size(logσ) == size(y)
    Threads.@threads for i in eachindex(out)
        @inbounds out[i] = normallogprobloss(μ[i], logσ[i], y[i])
    end
    return out
end
threadednormallogprobloss(μ, logσ, y) = threadednormallogprobloss!(similar(μ), μ, logσ, y)
threadednormallogprobloss(μ::TrackedArray, logσ::TrackedArray, y) = track(threadednormallogprobloss, μ, logσ, y)

function ∇threadednormallogprobloss_μ_logσ!(outμ::AbstractArray, outlogσ::AbstractArray, Δ::AbstractArray, μ::AbstractArray, logσ::AbstractArray, y::AbstractArray)
    Threads.@threads for i in eachindex(outμ)
        @inbounds begin
            gradμ = (μ[i] - y[i]) * exp(-2logσ[i])
            outμ[i] = Δ[i] * gradμ
            outlogσ[i] = Δ[i] * (1 - (μ[i] - y[i]) * gradμ)
        end
    end
    return outμ, outlogσ
end
∇threadednormallogprobloss_μ_logσ(Δ, μ, logσ, y) = ∇threadednormallogprobloss_μ_logσ!(similar(μ), similar(Δ), Δ, μ, logσ, y)

@grad function threadednormallogprobloss(μ::AbstractArray, logσ::AbstractArray, y::AbstractArray)
    threadednormallogprobloss(data.([μ, logσ, y])...),
        Δ -> nobacksies(:threadednormallogprobloss,
            # The first two gradients (w.r.t. μ and logσ) are computed together
            (∇threadednormallogprobloss_μ_logσ(data.([Δ, μ, logσ, y])...)...,
             nothing))
end


adjacency_matrix_diag(g) = adjacency_matrix(g) + Matrix(I, size(g)...)
randn_like(target::A) where A<:AbstractArray{T} where T = randn(T, size(target))
mean(a::AbstractArray...) = sum(a) / length(a)

function loadparams!(ps::Tracker.Params, xs)
  for (p, x) in zip(ps, xs)
    size(p) == size(x) ||
      error("Expected param size $(size(p)), got $(size(x))")
    copyto!(Tracker.data(p), Tracker.data(x))
  end
end

onehotmaxbatch(a::AbstractArray) = Flux.onehotbatch(a, 1:maximum(a))


#
# Plotting helpers
#

function markersize(xy)
    (xmin, xmax), (ymin, ymax) = extrema(xy, dims = 2)
    0.03 * max(xmax - xmin, ymax - ymin)
end
markersize(xy::TrackedArray) = markersize(xy.data)


end
