
"""
    FourierDerivativeOperator{T<:Real, GridCompute, GridEvaluate, RFFT, BRFFT}

A derivative operator on a periodic grid with scalar type `T` computing the
first derivative using a spectral Fourier expansion via real discrete Fourier
transforms.
"""
struct FourierDerivativeOperator{T<:Real, Grid, RFFT, BRFFT} <: AbstractPeriodicDerivativeOperator{T}
    jac::T
    grid_compute::Grid   # N-1 nodes, including the left and excluding the right boundary
    grid_evaluate::Grid #  N  nodes, including both boundaries
    tmp::Vector{Complex{T}}
    rfft_plan::RFFT
    brfft_plan::BRFFT

    function FourierDerivativeOperator(jac::T, grid_compute::Grid, grid_evaluate::Grid,
                                        tmp::Vector{Complex{T}}, rfft_plan::RFFT, brfft_plan::BRFFT) where {T<:Real, Grid, RFFT, BRFFT}
        @argcheck length(brfft_plan) == length(tmp) DimensionMismatch
        @argcheck length(brfft_plan) == (length(rfft_plan)÷2)+1 DimensionMismatch
        @argcheck length(grid_compute) == length(rfft_plan) DimensionMismatch
        @argcheck length(grid_compute) == length(grid_evaluate)-1 DimensionMismatch
        @argcheck first(grid_compute) == first(grid_evaluate)
        @argcheck step(grid_compute) ≈ step(grid_evaluate)
        @argcheck last(grid_compute) < last(grid_evaluate)

        new{T, Grid, RFFT, BRFFT}(jac, grid_compute, grid_evaluate, tmp, rfft_plan, brfft_plan)
    end
end

"""
    FourierDerivativeOperator(xmin::T, xmax::T, N::Int) where {T<:Real}

Construct the `FourierDerivativeOperator` on a uniform grid between `xmin` and
`xmax` using `N` Fourier modes.
"""
function FourierDerivativeOperator(xmin::T, xmax::T, N::Int) where {T<:Real}
    @argcheck N >= 1

    jac = 2*T(π) / (xmax - xmin) / N # / N because of brfft instead of BRFFT
    grid_evaluate = linspace(xmin, xmax, N+1)
    grid_compute = linspace(xmin, grid_evaluate[end-1], N)
    u = zero.(grid_compute)
    rfft_plan = plan_rfft(u)
    uhat = rfft_plan*u
    brfft_plan = plan_brfft(uhat, N)

    FourierDerivativeOperator(jac, grid_compute, grid_evaluate, uhat, rfft_plan, brfft_plan)
end

function fourier_derivative_operator(xmin::T, xmax::T, N::Int) where {T<:Real}
    FourierDerivativeOperator(xmin, xmax, N)
end

derivative_order(D::FourierDerivativeOperator) = 1
Base.issymmetric(D::FourierDerivativeOperator) = false

function Base.show(io::IO, D::FourierDerivativeOperator{T}) where {T}
    grid = D.grid_evaluate
    print(io, "Periodic 1st derivative Fourier operator {T=", T, "} \n")
    print(io, "on a grid in [", first(grid), ", ", last(grid),
                "] using ", length(grid)-1, " modes. \n")
end


function Base.A_mul_B!(dest::AbstractVector{T}, D::FourierDerivativeOperator,
                        u::AbstractVector{T}) where {T}
    @unpack jac, tmp, rfft_plan, brfft_plan = D
    N, _ = size(D)
    @boundscheck begin
        @argcheck N == length(u)
        @argcheck N == length(dest)
    end

    A_mul_B!(tmp, rfft_plan, u)
    @inbounds @simd for j in Base.OneTo(length(tmp)-1)
        tmp[j] *= (j-1)*im * jac
    end
    @inbounds tmp[end] = 0
    A_mul_B!(dest, brfft_plan, tmp)

    nothing
end


"""
    fourier_derivative_matrix(N, xmin::Real=0.0, xmax::Real=2π)

Compute the Fourier derivative matrix with respect to the corresponding nodal
basis, see Kopriva (2009) Implementing Spectral Methods for PDEs, Algorithm 18.
"""
function fourier_derivative_matrix(N, xmin::Real=0.0, xmax::Real=2π)
    T = promote_type(typeof(xmin), typeof(xmax))
    jac_2 = T(π) / (xmax - xmin)
    D = Array{T}(N, N)
    @inbounds for j in 1:N, i in 1:N
        j == i && continue
        D[i,j] = (-1)^(i+j) * cot((i-j)*T(π)/N) * jac_2
        D[i,i] -= D[i,j]
    end
    D
end



"""
    FourierSpectralViscosity{T<:Real, GridCompute, GridEvaluate, RFFT, BRFFT}

A spectral viscosity operator on a periodic grid with scalar type `T` computing
the derivative using a spectral Fourier expansion via real discrete Fourier
transforms.
"""
struct FourierSpectralViscosity{T<:Real, Grid, RFFT, BRFFT} <: AbstractDerivativeOperator{T}
    strength::T
    cutoff::Int
    coefficients::Vector{T}
    D::FourierDerivativeOperator{T,Grid,RFFT,BRFFT}

    function FourierSpectralViscosity(strength::T, cutoff::Int,
                                        D::FourierDerivativeOperator{T,Grid,RFFT,BRFFT}) where {T<:Real, Grid, RFFT, BRFFT}
        # precompute coefficients
        N = size(D, 1)
        jac = N * D.jac^2 # ^2: 2nd derivative; # *N: brfft instead of irfft
        coefficients = Array{T}(length(D.brfft_plan))
        @inbounds @simd for j in Base.OneTo(cutoff-1)
            coefficients[j] = 0
        end
        @inbounds @simd for j in cutoff:length(coefficients)
            coefficients[j] = -strength * (j-1)^2 * jac * exp(-((N-j+1)/(j-1-cutoff))^2)
        end
        new{T, Grid, RFFT, BRFFT}(strength, cutoff, coefficients, D)
    end
end

function spectral_viscosity_operator(D::FourierDerivativeOperator{T},
                                     strength=T(1)/size(D,2),
                                     cutoff=round(Int, sqrt(size(D,2)))) where {T}
    FourierSpectralViscosity(strength, cutoff, D)
end

function Base.show(io::IO, Di::FourierSpectralViscosity{T}) where {T}
    grid = Di.D.grid_evaluate
    print(io, "Spectral viscosity operator for the periodic 1st derivative Fourier operator\n")
    print(io, "{T=", T, "} on a grid in [", first(grid), ", ", last(grid),
                "] using ", length(grid)-1, " modes\n")
    print(io, "with strength ε = ", Di.strength, " and cutoff m = ", Di.cutoff, ".\n")
end

Base.issymmetric(Di::FourierSpectralViscosity) = true
grid(Di::FourierSpectralViscosity) = grid(Di.D)

function Base.A_mul_B!(dest::AbstractVector{T}, Di::FourierSpectralViscosity{T},
                        u::AbstractVector{T}) where {T}
    @unpack strength, cutoff, coefficients, D = Di
    @unpack jac, tmp, rfft_plan, brfft_plan = D
    N = size(D, 1)
    @boundscheck begin
        @argcheck N == length(u)
        @argcheck N == length(dest)
        @argcheck length(tmp) == length(coefficients)
    end

    A_mul_B!(tmp, rfft_plan, u)
    @inbounds @simd for j in Base.OneTo(length(tmp))
        tmp[j] *= coefficients[j]
    end
    A_mul_B!(dest, brfft_plan, tmp)

    nothing
end
