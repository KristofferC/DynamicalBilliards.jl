export resolvecollision!, propagate!, evolve!, construct, specular!,
periodicity!, propagate_pos, next_collision, relocate!,
bounce!, evolve

#####################################################################################
# Mathetical/Convenience Functions
#####################################################################################
const sixsqrt = 6sqrt(2)

# Used in relocate:
@inline timeprec(::AbstractParticle{T}, ::Obstacle{T}) where {T} = eps(T)^(4/5)
# This timeprec cannot be used for PeriodWall and RaySplitting obstacles with
# MagneticParticle because when mangetic and relocating forward you get
# extremely shallow angles
# and you need huge changes in time for even tiny changes in position
@inline timeprec(p::MagneticParticle, o::PeriodicWall) = timeprec_forward(p, o)
@inline timeprec_forward(::MagneticParticle{T}, ::Obstacle{T}) where {T} = eps(T)^(3/4)
@inline timeprec_forward(::MagneticParticle{BigFloat}, ::Obstacle) = BigFloat(1e-12)

@inline timeprec(::Type{T}) where {T} = eps(T)^(4/5)
@inline timeprec_forward(::Type{T}) where {T} = eps(T)^(3/4)
@inline timeprec_forward(::Type{BigFloat}) = BigFloat(1e-12)

# Used in check of skip intersection, in `realangle` and collision with Semicircle:
@inline distancecheck(::Type{T}) where {T} = sqrt(eps(T))
@inline distancecheck(::Type{BigFloat}) = BigFloat(1e-8)

"""
    acos1mx(x)
Approximate arccos(1 - x) for x very close to 0.
"""
@inline (acos1mx(x::T)::T) where {T} = sqrt(2x) + sqrt(x)^3/sixsqrt

@inline cross2D(a, b) = a[1]*b[2]-a[2]*b[1]

@inline increment_counter(::Int, t_to_write) = 1
@inline increment_counter(::T, t_to_write) where {T<:AbstractFloat} = t_to_write

#####################################################################################
# Resolve Collisions
#####################################################################################
"""
    specular!(p::AbstractParticle, o::Obstacle)
Perform specular reflection based on the normal vector of the Obstacle.

In the case where the given obstacle is a `RandomObstacle`, the specular reflection
randomizes the velocity instead (within -π/2+ε to π/2-ε of the normal vector).
"""
@inline function specular!(p::AbstractParticle{T}, o::Obstacle{T})::Nothing where {T}
    n = normalvec(o, p.pos)
    p.vel = p.vel - 2*dot(n, p.vel)*n
    return nothing
end

@inline function specular!(p::AbstractParticle{T}, r::RandomDisk{T})::Nothing where {T}
    n = normalvec(r, p.pos)
    φ = atan(n[2], n[1]) + 0.95(π*rand() - π/2) #this cannot be exactly π/2
    p.vel = SVector{2,T}(cos(φ), sin(φ))
    return nothing
end

@inline function specular!(p::AbstractParticle{T}, r::RandomWall{T})::Nothing where {T}
    n = normalvec(r, p.pos)
    φ = atan(n[2], n[1]) + 0.95(π*rand() - π/2) #this cannot be exactly π/2
    p.vel = SVector{2,T}(cossin(φ)...)
    return nothing
end

"""
    periodicity!(p::AbstractParticle, w::PeriodicWall)
Perform periodicity conditions of `w` on `p`.
"""
@inline function periodicity!(p::AbstractParticle, w::PeriodicWall)::Nothing
    p.pos += w.normal
    p.current_cell -= w.normal
    return nothing
end
@inline function periodicity!(p::MagneticParticle, w::PeriodicWall)::Nothing
    p.pos += w.normal
    p.center += w.normal
    p.current_cell -= w.normal
    return nothing
end

"""
    resolvecollision!(p::AbstractParticle, o::Obstacle)
Resolve the collision between particle `p` and obstacle `o`, depending on the
type of `o` (do `specular!` or `periodicity!`).

    resolvecollision!(p, o, T::Function, θ::Function, new_ω::Function)
This is the ray-splitting implementation. The three functions given are drawn from
the ray-splitting dictionary that is passed directly to `evolve!()`. For a calculated
incidence angle φ, if T(φ) > rand(), ray-splitting occurs.
"""
@inline resolvecollision!(p::Particle, o::Obstacle) = specular!(p, o)
@inline resolvecollision!(p::Particle, o::PeriodicWall) = periodicity!(p, o)
@inline resolvecollision!(p::MagneticParticle, o::Obstacle) = specular!(p, o)

resolvecollision!(p::MagneticParticle, o::PeriodicWall) = periodicity!(p, o)


"""
    relocate!(p::AbstractParticle, o::Obstacle, t) -> newt
Propagate the particle's position for time `t`, and check if it is on
the correct side of the obstacle. If not, adjust the time `t` by `timeprec`
and re-evalute until correct. When correct, propagate the particle itself
to the correct position and return the final adjusted time.

Notice that the adjustment is increased geometrically; if one adjustment is not
enough, the adjusted time is multiplied by a factor of 10. This happens as many
times as necessary.
"""
function relocate!(p::AbstractParticle{T}, o::Obstacle{T}, tmin::T) where {T}
    sig = timeprec_sign(o)
    newpos = propagate_pos(p.pos, p, tmin)
    i = 1
    while distance(newpos, o)*sig > 0
        tmin = tmin + i*sig*timeprec(p, o)
        newpos = propagate_pos(p.pos, p, tmin)
        i *= 10
    end
    propagate!(p, newpos, tmin)
    return tmin
end

@inline timeprec_sign(::Obstacle) = -1
@inline timeprec_sign(::PeriodicWall) = +1



#####################################################################################
# Propagate & Bounce
#####################################################################################
"""
    propagate!(p::AbstractParticle, t)
Propagate the particle `p` for given time `t`, changing appropriately the the
`p.pos` and `p.vel` fields.

For a `Particle` the propagation is a straight line
(i.e. velocity vector is constant). For a `MagneticParticle` the propagation
is circular motion with cyclic frequency `p.omega` and radius `1/p.omega`.

    propagate!(p, position, t)
Do the same, but take advantage of the already calculated `position` that the
particle should end up at.
"""
@inline propagate!(p::Particle{T}, t::Real) where {T} = (p.pos += SV{T}(p.vel[1]*t, p.vel[2]*t))
@inline propagate!(p::Particle, newpos::SV, t::Real) = (p.pos = newpos)

@inline function propagate!(p::MagneticParticle{T}, t::Real)::Nothing where {T}
    ω = p.omega; r = 1/ω
    φ0 = atan(p.vel[2], p.vel[1])
    sinωtφ, cosωtφ = sincos(ω*t + φ0)
    p.pos += SV{T}((sinωtφ - sin(φ0))*r, (-cosωtφ + cos(φ0))*r)
    p.vel = SVector{2, T}(cosωtφ, sinωtφ)
    return
end
@inline function propagate!(p::MagneticParticle{T}, newpos::SVector{2,T}, t) where {T}
    ω = p.omega; φ0 = atan(p.vel[2], p.vel[1])
    p.pos = newpos
    p.vel = SVector{2, T}(cossin(ω*t + φ0)...)
    return
end

"""
    propagate_pos(pos, p::AbstractParticle, t::Real) -> newpos
Perform a "fake" propagation, i.e. propagate a position as if it was the particle's
position.
"""
@inline propagate_pos(pos, p::Particle{T}, t::Real) where {T} =
    SV{T}(pos[1] + p.vel[1]*t, pos[2] + p.vel[2]*t)

@inline function propagate_pos(pos, p::MagneticParticle{T}, t) where {T}
    # "Initial" conditions
    ω = p.omega; r = 1/ω
    φ0 = atan(p.vel[2], p.vel[1])
    # Propagate:
    sφ0, cφ0 = sincos(φ0)
    sωφ0, cωφ0 = sincos(ω*t + φ0)
    ppos = SV{T}((sωφ0 - sφ0)*r, (-cωφ0 + cφ0)*r)
    return pos + ppos
end

"""
    bounce!(p::AbstractParticle, bd::Billiard) -> i, t, pos, vel
"Bounce" the particle (advance for one collision) in the billiard.

Specifically, find the [`next_collision`](@ref) of `p` with `bd`,
[`relocate!`](@ref) the particle correctly,
[`resolvecollision!`](@ref) with the colliding obstacle and finally return:

* index of the obstacle that the particle just collided with
* the time from the previous collision until the current collision `t`
* position and velocity of the particle at the current collision (*after* the
  collision has been resolved!). The position is given in the unit cell of
  periodic billiards. Do `pos += p.current_cell` for the position in real space.

```julia
bounce!(p, bd, raysplit::Dict) -> i, t, pos, vel
```
Ray-splitting version of `bounce!`.
"""
function bounce!(p::AbstractParticle{T}, bd::Billiard{T}) where {T}
    tmin::T, i::Int = next_collision(p, bd)
    o = bd[i]
    tmin = relocate!(p, o, tmin)
    resolvecollision!(p, o)
    return i, tmin, p.pos, p.vel
end

function bounce!(p::MagneticParticle{T}, bd::Billiard{T}) where {T}
    tmin::T, i::Int = next_collision(p, bd)
    if tmin != Inf
        tmin = relocate!(p, bd[i], tmin)
        resolvecollision!(p, bd[i])
    end
    p.center = find_cyclotron(p)
    return i, tmin, p.pos, p.vel
end


#####################################################################################
# Evolve & Construct
#####################################################################################
"""
    evolve!(p::AbstractParticle, bd::Billiard, t)
Evolve the given particle `p` inside the billiard `bd`. If `t` is of type
`AbstractFloat`, evolve for as much time as `t`. If however `t` is of type `Int`,
evolve for as many collisions as `t`.
Return the states of the particle between collisions.

The evolution takes into account the particle's Type.
E.g. if `typeof(p) <: MagneticParticle` then magnetic evolution will take place.

This function mutates the particle, use `evolve` otherwise.

### Returns

* `ct::Vector{T}` : Collision times.
* `poss::Vector{SVector{2,T}}` : Positions at the collisions.
* `vels::Vector{SVector{2,T}})` : Velocities exactly after the collisions.
* `ω`, either `T` or `Vector{T}` : Angular velocity/ies (returned only for magnetic
  particles).

Use the function [`construct`](@ref) to create timeseries of positions and
velocities out of these outputs.

The time `ct[i+1]` is the time necessary to reach state `poss[i+1], vels[i+1]` starting
from the state `poss[i], vels[i]`. That is why `ct[1]` is always 0 since
`poss[1], vels[1]` are the initial conditions. The angular velocity `ω[i]` is the one
the particle has while propagating from state `poss[i], vels[i]` to `i+1`.

Notice that at any point, the velocity vector `vels[i]` is the one obdained *after*
the specular reflection of the `i-1`th collision.
The function [`construct`](@ref) takes that into account.

### Ray-splitting billiards
    evolve!(p, bd, t, raysplitters)

To implement ray-splitting, the `evolve!` function is supplemented with a
fourth argument, `raysplitters` which is a tuple of [`RaySplitter`](@ref) instances.
For more information and instructions on using ray-splitting
please visit the official documentation.
"""
function evolve!(p::AbstractParticle{T}, bd::Billiard{T}, t;
    warning = false) where {T<:AbstractFloat}

    if t ≤ 0
        throw(ArgumentError("`evolve!()` cannot evolve backwards in time."))
    end

    ismagnetic = typeof(p) <: MagneticParticle
    rt = T[]; push!(rt, 0)
    rpos = SVector{2,T}[]; push!(rpos, p.pos)
    rvel = SVector{2,T}[]; push!(rvel, p.vel)
    ismagnetic && (omegas = T[]; push!(omegas, p.omega); absω = abs(p.omega))

    count = zero(t)
    t_to_write = zero(T)

    while count < t

        i, tmin, pos, vel = bounce!(p, bd)
        t_to_write += tmin

        if ismagnetic && tmin == Inf
            warning && warn("Pinned particle in evolve! (Inf. col. t)")
            push!(rpos, pos)
            push!(rvel, vel)
            push!(rt, tmin)
            return (rt, rpos, rvel, p.omega)
        end

        if typeof(bd[i]) <: PeriodicWall
            # Pinned particle:
            if ismagnetic && t_to_write ≥ 2π/absω
                warning && warn("Pinned particle in evolve! (completed circle)")
                push!(rpos, rpos[end])
                push!(rvel, rvel[end])
                push!(rt, Inf)
                return (rt, rpos, rvel, p.omega)
            end
            #If not pinned, do not write for PeriodicWall
            continue
        else
            push!(rpos, pos + p.current_cell)
            push!(rvel, vel)
            push!(rt, t_to_write)
            # set counter
            count += increment_counter(t, t_to_write)
            t_to_write = zero(T)
        end
    end#time, or collision number, loop

    return ismagnetic ? (rt, rpos, rvel, p.omega) : (rt, rpos, rvel)
end

"""
    evolve(p, args...)
Same as [`evolve!`](@ref) but deep-copies the particle instead.
"""
evolve(p, args...) = evolve!(deepcopy(p), args...)

"""
    construct(ct, poss, vels [, ω [, dt=0.01]]) -> xt, yt, vxt, vyt, t
Given the output of [`evolve!`](@ref), construct the
timeseries of the position and velocity, as well as the time vector.

In case of not given `ω` (or `ω == 0`), straight construction takes place.
In case of `ω != 0` or `ω::Vector` magnetic construction takes place.

The additional optional argument of `dt` (only valid for magnetic construction)
is the timestep with which the timeseries are constructed.

Return:
* x position time-series
* y position time-series
* x velocity time-series
* y velocity time-series
* time vector
"""
function construct(t::Vector{T},
    poss::Vector{SVector{2,T}}, vels::Vector{SVector{2,T}}) where {T}

    xt = [pos[1] for pos in poss]
    yt = [pos[2] for pos in poss]
    vxt = [vel[1] for vel in vels]
    vyt = [vel[2] for vel in vels]
    ct = cumsum(t)
    return xt, yt, vxt, vyt, ct
end

function construct(t::Vector{T},  poss::Vector{SVector{2,T}},
vels::Vector{SVector{2,T}}, ω::T, dt=0.01) where {T}

    dt = T(dt)
    ω == 0 && return construct(t, poss, vels)

    xt = [poss[1][1]]
    yt = [poss[1][2]]
    vxt= [vels[1][1]]
    vyt= [vels[1][2]]
    ts = [t[1]]
    ct = cumsum(t)

    for i in 2:length(t)
        φ0 = atan(vels[i-1][2], vels[i-1][1])
        x0 = poss[i-1][1]; y0 = poss[i-1][2]
        colt=t[i]

        t0 = ct[i-1]
        # Construct proper time-vector
        if colt >= dt
            timevec = collect(0:dt:colt)[2:end]
            timevec[end] == colt || push!(timevec, colt)
        else
            timevec = colt
        end

        for td in timevec
            s, c = sincos(ω*td + φ0)
            s0, c0 = sincos(φ0)
            push!(vxt, c)
            push!(vyt, s)
            push!(xt, s/ω + x0 - s0/ω)  #vy0 is sin(φ0)
            push!(yt, -c/ω + y0 + c0/ω) #vx0 is cos(φ0)
            push!(ts, t0 + td)
        end#collision time
    end#total time
    return xt, yt, vxt, vyt, ts
end
