module VAE

include("utils.jl")
include("layers.jl")
using .Utils
using .Layers

using LightGraphs
using Flux
using ProgressMeter
using Distributions


const klscale = 1f-3
const regscale = 1f-3
const supported_label_distributions = [Bernoulli, Categorical, Normal]
const label_distributions = Dict(lowercase(split(repr(d), ".")[end]) => d for d in supported_label_distributions)


function sharedl1_enc(;g, feature_size, args)
    println("Info: using shared l1 encoder")

    diml1enc, dimξadj, dimξfeat, overlap = args["diml1enc"], args["dimxiadj"], args["dimxifeat"], args["overlap"]
    initb = args["initb"]

    l1 = Layers.GC(g, feature_size, diml1enc, Flux.relu, initb = initb)
    lμ = Layers.Apply(Layers.VOverlap(overlap),
        Layers.GC(g, diml1enc, dimξadj, initb = initb),
        Layers.GC(g, diml1enc, dimξfeat, initb = initb))
    llogσ = Layers.Apply(Layers.VOverlap(overlap),
        Layers.GC(g, diml1enc, dimξadj, initb = initb),
        Layers.GC(g, diml1enc, dimξfeat, initb = initb))
    enc(x) = (h = l1(x); (lμ(h), llogσ(h)))
    encparams = Flux.params(l1, lμ, llogσ)

    enc, encparams
end

function unsharedl1_enc(;g, feature_size, args)
    println("Info: using unshared l1 encoder")

    diml1enc, dimξadj, dimξfeat, overlap = args["diml1enc"], args["dimxiadj"], args["dimxifeat"], args["overlap"]
    initb = args["initb"]

    l1adj = Layers.GC(g, feature_size, diml1enc, Flux.relu, initb = initb)
    l1feat = Layers.GC(g, feature_size, diml1enc, Flux.relu, initb = initb)

    lμadj = Layers.GC(g, diml1enc, dimξadj, initb = initb)
    lμfeat = Layers.GC(g, diml1enc, dimξfeat, initb = initb)

    llogσadj = Layers.GC(g, diml1enc, dimξadj, initb = initb)
    llogσfeat = Layers.GC(g, diml1enc, dimξfeat, initb = initb)

    loverlap = Layers.VOverlap(overlap)

    function enc(x)
        hadj = l1adj(x)
        hfeat = l1feat(x)
        (loverlap(lμadj(hadj), lμfeat(hfeat)), loverlap(llogσadj(hadj), llogσfeat(hfeat)))
    end
    encparams = Flux.params(l1adj, l1feat, lμadj, lμfeat, llogσadj, llogσfeat)

    enc, encparams
end

function make_vae(;g, feature_size, label_size, args, weights = nothing)
    diml1dec, dimξadj, dimξfeat, overlap = args["diml1dec"], args["dimxiadj"], args["dimxifeat"], args["overlap"]
    initb = args["initb"]

    # Encoder
    make_enc = if args["sharedl1"]; sharedl1_enc; else unsharedl1_enc; end
    enc, encparams = make_enc(g = g, feature_size = feature_size, args = args)

    # Sampler
    sampleξ(μ, logσ) = μ .+ exp.(logσ) .* randn_like(μ)

    # Decoder
    decadj = if args["decadjdeep"]
        println("Info: using deep adjacency decoder")
        Chain(
            Dense(dimξadj, diml1dec, Flux.relu, initb = initb),
            Layers.Bilin(diml1dec)
        )
    else
        println("Info: using shallow adjacency decoder")
        Layers.Bilin()
    end
    decfeat, decparams = if args["label-distribution"] == Normal
        println("Info: using gaussian feature decoder")
        decfeatl1 = Dense(dimξfeat, diml1dec, Flux.relu, initb = initb)
        decfeatlμ = Dense(diml1dec, label_size, initb = initb)
        decfeatllogσ = Dense(diml1dec, label_size, initb = initb)
        decfeat(ξ) = (h = decfeatl1(ξ); (decfeatlμ(h), decfeatllogσ(h)))
        decfeat, Flux.params(decadj, decfeatl1, decfeatlμ, decfeatllogσ)
    else
        println("Info: using boolean feature decoder")
        decfeat = Chain(
            Dense(dimξfeat, diml1dec, Flux.relu, initb = initb),
            Dense(diml1dec, label_size, initb = initb),
        )
        decfeat, Flux.params(decadj, decfeat)
    end
    dec(ξ) = (decadj(ξ[1:dimξadj, :]), decfeat(ξ[end-dimξfeat+1:end, :]))

    # Load parameters if given
    if weights != nothing
        println!("Info: loading given model weights")
        paramsvae = Flux.Params()
        push!(paramsvae, paramsenc..., paramsdec...)
        loadparams!(paramsvae, weights)
    end

    enc, sampleξ, dec, encparams, decparams
end


function make_losses(;g, labels, args, enc, sampleξ, dec, paramsenc, paramsdec)
    label_distribution = args["label-distribution"]
    dimξadj, dimξfeat, overlap = args["dimxiadj"], args["dimxifeat"], args["overlap"]
    Adiag = Array{Float32}(adjacency_matrix_diag(g))
    densityA = Float32(mean(adjacency_matrix(g)))
    densitylabels = Float32(mean(labels))

    # Kullback-Leibler divergence
    Lkl(μ, logσ) = sum(Utils.threadedklnormal(μ, logσ))
    κkl = Float32(size(g, 1) * (dimξadj - overlap + dimξfeat))

    # Adjacency loss
    Ladj(logitApred) = (
        sum(Utils.threadedlogitbinarycrossentropy(logitApred, Adiag, pos_weight = (1f0 / densityA) - 1))
        / (2 * (1 - densityA))
    )
    κadj = Float32(size(g, 1)^2 * log(2))

    # Features loss
    Lfeat(logitFpred, ::Type{Bernoulli}) = (
        sum(Utils.threadedlogitbinarycrossentropy(logitFpred, labels, pos_weight = (1f0 / densitylabels) - 1))
        / (2 * (1 - densitylabels))
    )
    κfeat_bernoulli = Float32(prod(size(labels)) * log(2))
    κfeat(::Type{Bernoulli}) = κfeat_bernoulli

    Lfeat(unormFpred, ::Type{Categorical}) = sum(Utils.threadedsoftmaxcategoricallogprobloss(unormFpred, labels))
    κfeat_categorical = Float32(size(g, 1) * log(size(labels, 1)))
    κfeat(::Type{Categorical}) = κfeat_categorical

    Lfeat(Fpreds, ::Type{Normal}) = ((μ, logσ) = Fpreds; sum(Utils.threadednormallogprobloss(μ, logσ, labels)))
    κfeat_normal = Float32(prod(size(labels)) * (log(2π) + mean(labels.^2)) / 2)
    κfeat(::Type{Normal}) = κfeat_normal

    # Total loss
    function losses(x)
        μ, logσ = enc(x)
        logitApred, unormFpred = dec(sampleξ(μ, logσ))
        Dict("kl" => klscale * Lkl(μ, logσ) / κkl,
            "adj" => Ladj(logitApred) / κadj,
            "feat" => Lfeat(unormFpred, label_distribution) / κfeat(label_distribution),
            "reg" => regscale * Utils.regularizer(paramsdec))
    end

    function loss(x)
        sum(values(losses(x)))
    end

    losses, loss
end


function train_vae!(;args, features, paramsvae, losses, loss, perf_edges = nothing, perf_nodes = nothing)
    nepochs = args["nepochs"]
    elt = eltype(features)

    history = Dict(name => zeros(elt, nepochs) for name in keys(losses(features)))
    history["total loss"] = zeros(elt, nepochs)
    if perf_edges != nothing
        history["auc"] = zeros(elt, nepochs)
        history["ap"] = zeros(elt, nepochs)
    end
    if perf_nodes != nothing
        history["f1macro"] = zeros(elt, nepochs)
        history["f1micro"] = zeros(elt, nepochs)
    end

    opt = ADAM(0.01)
    @showprogress for i = 1:nepochs
        Flux.train!(loss, paramsvae, [(features,)], opt)

        lossparts = losses(features)
        for (name, value) in lossparts
            history[name][i] = value.data
        end
        history["total loss"][i] = sum(values(lossparts)).data
        if perf_edges != nothing
            history["auc"][i], history["ap"][i] = perf_edges(features)
        end
    end
    # Only save the latest node classification performance, as this is costly
    if perf_nodes != nothing
        history["f1macro"][end], history["f1micro"][end] = perf_nodes(features)
    end

    history
end


end
