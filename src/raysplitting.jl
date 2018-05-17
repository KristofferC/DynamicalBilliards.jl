export isphysical, acceptable_raysplitter, reset_billiard!

#=debug=# false && using Juno

#####################################################################################
# RaySplitter structures
#####################################################################################
"""
    RaySplitter(idxs, transmission, refraction; affect, newangular)
Return a `RaySplitter` instance, used to performs raysplitting.
`idxs` is a `Vector{Int}` with the indices of the obstacles
that this `RaySplitter` corresponds to.

`transmission`, `refraction` and `newangular` are **functions**. Let
`φ` be the angle of incidence and `ω` be the angular velocity (before transmission).
The functions have the following signatures:

1. `transmission(φ, pflag, ω) -> T` : Transmission probability `T` depending on
   whether the particle is inside or outside the obstacle (`pflag`) and optionally
   depending on ω.
2. `refraction(φ, pflag, ω) -> θ` : Refraction angle `θ`
   depending on whether the particle is inside or outside the obstacle (`pflag`)
   and optionally depending on `ω`. This angle is *relative* to the normal vector.
3. `newangular(ω, pflag) -> newω` : New angular velocity after transmission.
   Notice that `newangular` is a keyword argument and defaults to `(ω, pflag) -> ω`.

The above three functions use the **same convention**: the argument `pflag` is the
one the Obstacle has **before transmission**. For example, if a particle is
outside an [`Antidot`](@ref) (with `pflag = true` here) and is transmitted inside
the `Antidot` (`pflag` becomes `false` here), then all three functions will be
given their second argument (the Boolean one) as `true`!

Also notice that the call signature **must** be as stated, irrespectively of
whether some of the arguments are used in the functions.

`affect` is a vector of integers, and denotes which obstacles
of the billiard are affected when transmission occurs (for which obstacles
should the field `pflag` be reversed). Defaults to `idxs`.
"""
struct RaySplitter{T, Φ, Ω}
    oidx::Vector{Int}
    transmission::T
    refraction::Φ
    affect::Vector{Int}
    # Change this to make it easier to handle.?
    # Affect to be a function that returns the indices to be affected?
    # Otherwise not so easy to use same struct for different obstacles
    # and then I use Set{} on oidx given to affect
    newω::Ω
end

function RaySplitter(idxs, tr, ref; affect = idxs, newangular = nothing)
    for i ∈ idxs
        i ∈ affect || throw(ArgumentError(
        "All indices that correspond to this RaySplitter must also be affected"))
    end
    return RaySplitter(idxs, tr, ref, affect, newangular)
end

"""
    raysplit_indices(bt::Billiard, raysplitters::Tuple)
Create a vector of integers. The `i`th entry tells you which entry of the
`raysplitters` tuple is associated with the `i`th obstacle of the billiard.

If the `i`th entry is `0`, this means that the obstacle does not do raysplitting.
"""
function raysplit_indices(bt::Billiard, raysplitters::Tuple)
    O = zeros(Int, length(bt.obstacles))
    for (k, rayspl) ∈ enumerate(raysplitters)
        O[rayspl.oidx] = k
    end
    return O
end

# in isphysical add test that different raysplitters cannot share
# ANY entry in oidx

#####################################################################################
# Resolve collisions
#####################################################################################
timeprec_rayspl(::Particle{T}) where {T} = timeprec(T)
timeprec_rayspl(::MagneticParticle{T}) where {T} = timeprec_forward(T)

function incidence_angle(p::AbstractParticle{T}, a::Obstacle{T})::T where {T}
    # Raysplit Algorithm step 1: Determine incidence angle (0 < φ < π/4)
    n = normalvec(a, p.pos)
    inverse_dot = clamp(dot(p.vel, -n), -1.0, 1.0)
    φ = acos(inverse_dot)
    # Raysplit Algorithm step 2: get correct sign
    if cross2D(p.vel, n) < 0
        φ *= -1
    end
    return φ
end

function istransmitted(p::AbstractParticle{T}, a::Obstacle{T}, Tr::F) where {T, F}
    ω = typeof(p) <: MagneticParticle ? p.omega : T(0)
    φ = incidence_angle(p, a)
    # Raysplit Algorithm step 3: check transmission probability
    trans = Tr(φ, a.pflag, ω) > rand()
end

# Raysplit Algorithm step 4: relocate the particle _inside_ the obstacle
# if ray-splitting happens (see `ineq` variable)
function relocate_rayspl!(
    p::Particle{T}, o::Obstacle{T}, trans::Bool = false)::T where {T}

    ineq = 2trans - 1
    newpos = p.pos; newt = zero(T)
    i = 1
    # THE BUG IS IN THIS LOOP!!!!
    while ineq*distance(newpos, o) > 0
        newt += ineq*timeprec_rayspl(p)
        newpos = propagate_pos(p.pos, p, newt)
        i *= 10
        #=debug=# false && i > 10000 && println("care, iteration $(log10(i))")
    end
    propagate!(p, newpos, newt)
    return newt
end

function resolvecollision!(p::AbstractParticle{T}, bt::Billiard{T}, colidx::Int,
    trans::Bool, rayspl::RaySplitter) where {T<:AbstractFloat}

    a = bt[colidx]
    ismagnetic = typeof(p) <: MagneticParticle
    ω = ismagnetic ? p.omega : T(0)

    # Raysplit Algorithm step 5: recompute angle of incidence
    φ = incidence_angle(p, a)

    if trans #perform raysplitting
        # Raysplit Algorithm step 6: find transmission angle in relative angles
        theta = rayspl.refraction(φ, a.pflag, ω)
        # Raysplit Algorithm step 7: reverse the Obstacle propagation flag
        # for all obstacles dictated by the RaySplitter
        for oi ∈ rayspl.affect
            bt[oi].pflag = ! bt[oi].pflag
        end
        # Raysplit Algorithm step 8: find transmission angle in real-space angles
        n = normalvec(a, p.pos) #notice that this is reversed! It's the new normalvec!
        Θ = theta + atan2(n[2], n[1])

        # Raysplit Algorithm step 9: Perform refraction
        p.vel = SVector{2,T}(cos(Θ), sin(Θ))
        # Raysplit Algorithm step 10: Set new angular velocity
        if ismagnetic
            ω = rayspl.newω(p.omega, !a.pflag)  # notice the exclamation mark
            p.omega = ω
            p.r = abs(1/ω)
        end
    else # No ray-splitting:
        #perform specular
        specular!(p, a)
        end
    return
end

# Ray-splitting version of bounce!
# rays is a tuple of RaySplitter. raysidx is a vector that given the obstacle
# index it tells you which raysplitter to choose from the tuple OR to not
# do raysplitting at all (for returned index 0)
function bounce!(p::AbstractParticle{T}, bt::Billiard{T},
    raysidx::Vector{Int}, raysplitters::Tuple) where {T}

    tmin::T, i::Int = next_collision(p, bt)
    #=debug=# false && println("Colt. with Left antidot = $(collisiontime(p, bt[1]))")
    #=debug=# false && println("Min. col. t with $(bt[i].name) = $tmin")
    #=debug=# false && tmin == 0 || tmin == Inf && error("Ridiculous, tmin=$(tmin)!")
    if tmin == Inf
        return i, tmin, p.pos, p.vel
    elseif raysidx[i] != 0
        propagate!(p, tmin)
        trans = istransmitted(p, bt[i], rays[raysidx[i]].transmission)
        #=debug=# false && println("Angle of incidence: $(φ), transmitted? $trans")
        #=debug=# false && println("Currently, pflag is $(bt[i].pflag)")
        #=debug=# false && trans && println("(pflag will be reversed!)")
        #=debug=# false && println()
        newt = relocate_rayspl!(p, bt[i], trans)
        resolvecollision!(p, bt, i, trans,  raysplitters[raysidx[i]])
        tmin += newt
    else
        tmin = relocate!(p, bt[i], tmin)
        resolvecollision!(p, bt[i])
    end
    typeof(p) <: MagneticParticle && (p.center = find_cyclotron(p))
    return i, tmin, p.pos, p.vel
end

#####################################################################################
# Evolve raysplitting
#####################################################################################
function evolve!(p::AbstractParticle{T}, bt::Billiard{T}, t, raysplitters::Tuple;
    warning = false) where {T}

    if t <= 0
        throw(ArgumentError("`evolve!()` cannot evolve backwards in time."))
    end

    # TODO: Here check if raysplitters is acceptable

    ismagnetic = typeof(p) <: MagneticParticle

    raysidx = raysplit_indices(bt, raysplitters)

    rt = T[]; push!(rt, 0)
    rpos = SVector{2,T}[]; push!(rpos, p.pos)
    rvel = SVector{2,T}[]; push!(rvel, p.vel)
    ismagnetic && (omegas = T[]; push!(omegas, p.omega))

    count = zero(t)
    t_to_write = zero(T)

    #=debug=# false && (dc = 0)

    while count < t
        #=debug=# false && println("count=$count")
        if #=debug=# false
            if dc > 10
                Juno.clearconsole()
                dc = 0
            else
                dc += 1
            end
        end

        i, tmin, pos, vel = bounce!(p, bt, raysidx, raysplitters)
        t_to_write += tmin

        if ismagnetic && tmin == Inf
            warning && warn("Pinned particle in evolve! (Inf. col. t)")
            push!(rpos, pos); push!(rvel, vel)
            push!(rt, tmin); push!(omegas, p.omega)
            return (rt, rpos, rvel, omegas)
        end

        if typeof(bt[i]) <: PeriodicWall
            # Pinned particle:
            if ismagnetic && t_to_write ≥ 2π/absω
                warning && warn("Pinned particle in evolve! (completed circle)")
                push!(rpos, pos); push!(rvel, vel)
                push!(rt, tmin); push!(omegas, p.omega)
                return (rt, rpos, rvel, omegas)
            end
            #If not pinned, continue (do not write for PeriodicWall)
            continue
        else
            push!(rpos, p.pos + p.current_cell)
            push!(rvel, p.vel); push!(rt, t_to_write);
            ismagnetic && push!(omegas, p.omega)
            count += increment_counter(t, t_to_write)
            t_to_write = zero(T)
        end

    end#time loop
    if ismagnetic
        return (rt, rpos, rvel, omegas)
    else
        return (rt, rpos, rvel)
    end
end

#####################################################################################
# Construct
#####################################################################################
function construct(t::Vector{T}, poss::Vector{SVector{2,T}},
vels::Vector{SVector{2,T}}, omegas::Vector{T}, dt=0.01) where T

    xt = [poss[1][1]]
    yt = [poss[1][2]]
    vxt= [vels[1][1]]
    vyt= [vels[1][2]]
    ts = [t[1]]
    ct = cumsum(t)

    for i in 2:length(t)
        ω = omegas[i-1]
        φ0 = atan2(vels[i-1][2], vels[i-1][1])
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
            push!(vxt, cos(ω*td + φ0))
            push!(vyt, sin(ω*td + φ0))
            push!(xt, sin(ω*td + φ0)/ω + x0 - sin(φ0)/ω)  #vy0 is sin(φ0)
            push!(yt, -cos(ω*td + φ0)/ω + y0 + cos(φ0)/ω) #vx0 is cos(φ0)
            push!(ts, t0 + td)
        end#collision time
    end#total time
    return xt, yt, vxt, vyt, ts
end

########################
# is physical, etc.
########################

function supports_raysplitting(obst::Obstacle)
  n = fieldnames(typeof(obst))
  in(:pflag, n)
end

"""
    reset_billiard!(bt)
Sets the `pflag` field of all ray-splitting obstacles of a billiard table
to `true`.
"""
function reset_billiard!(bt::Billiard)
    for obst in bt
        supports_raysplitting(obst) && (obst.pflag = true)
    end
end

"""
    acceptable_raysplitter(raysplitter, bt)
Return `true` if the given ray-splitting dictionary `raysplitter`
can be used in conjuction with given billiard table `bt`.
"""
function acceptable_raysplitter(ray::Dict{Int, Any}, bt::Billiard)
    for i in keys(ray)
        if !supports_raysplitting(bt[i])
            print("Obstacle at index $i of given billiard table")
            println("does not have a field `pflag`")
            println("and therefore does not support ray-splitting.")
            return false
        end
    end
    true
end

"""
    isphysical(raysplitter::Dict; only_mandatory = false)
Return `true` if the given ray-splitting dictionary has physically
plausible properties.

Specifically, check if (φ is the incidence angle, θ the refraction angle):

* Critical angle means total reflection: If θ(φ) ≥ π/2 then Tr(φ) = 0
* Transmission probability is even function: Tr(φ) ≈ Tr(-φ) at ω = 0
* Refraction angle is odd function: θ(φ) ≈ -θ(-φ) at ω = 0
* Ray reversal is true: θ(θ(φ, pflag, ω), !pflag, ω) ≈ φ
* Magnetic conservation is true: (ω_new(ω_new(ω, pflag), !pflag) ≈ ω

The first property is mandatory to hold for any setting and is always checked.
The rest are checked if `only_mandatory = false`.
"""
function isphysical(ray::Dict; only_mandatory = false)
  for i in keys(ray)
    scatter = ray[i][2]
    tr = ray[i][1]
    om = ray[i][3]
    range = -1.5:0.01:1.5
    orange = -1.0:0.1:1.0
    display_er = true
    for pflag in [true, false]
      for ω in orange
        for φ in range
          θ::Float64 = 0.0
          # Calculate refraction angle:
          try
            θ = scatter(φ, pflag, ω)
          catch er
            if display_er
              ws = "Got error message: $er\n"
              ws*= "while calculating the refraction angle with settings:\n"
              ws*= "index = $i, φ = $φ, pflag = $pflag, ω = $ω\n"
              ws*= "Similar warnings will be skipped as long as the Tr. prob. is 0."
              warn(ws)
            end
            display_er = false
            T = tr(φ, pflag, ω)
            if T!= 0
              println("Got error message: $er")
              println("while calculating the refraction angle with settings:")
              println("index = $i, φ = $φ, pflag = $pflag, ω = $ω")
              println("PROBLEM: Transmission prob. was not 0 for these settings!")
              return false
            else
              continue
            end
          end
          # Calculate transmission probability:
          T = tr(φ, pflag, ω)
          # Check critical angle:
          if θ >= π/2 && T > 0
            es = "Refraction angle >= π/2 and T > 0 !\n"
            es*= "For index = $i, tested with φ = $φ, pflag = $pflag, ω = $ω"
            println(es)
            return false
          end
          if !only_mandatory
            # Check symmetry:
            if ω==0
              if !isapprox(θ, -scatter(-φ, pflag, ω))
                es = "Scattering angle function is not odd!\n"
                es *="For index = $i, tested with φ = $φ, pflag = $pflag, ω = $ω"
                println(es)
                return false
              end
              if !isapprox(T, tr(-φ, pflag, ω))
                es = "Transmission probability function is not even!\n"
                es *="For index = $i, tested with φ = $φ, pflag = $pflag, ω = $ω"
                println(es)
                return false
              end
            end
            # Check ray-reversal:
            if !isapprox(scatter(θ, !pflag, ω), φ)
              es = "Ray-reversal does not hold!\n"
              es *="For index = $i, tested with φ = $φ, pflag = $pflag, ω = $ω"
              println(es)
              return false
            end
            if !isapprox(om(om(ω, pflag), !pflag), ω)
              es = "Magnetic reversal does not hold!\n"
              es *="For index = $i, tested with φ = $φ, pflag = $pflag, ω = $ω"
              println(es)
              return false
            end
          end
        end#φ range
      end#ω range
    end#pflag range
  end#obstacle range
  return true
end
