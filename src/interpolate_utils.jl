# interpolate utils

earth_dist_haversine(x1, y1, x2, y2) = haversine([y1, x1], [y2, x2], EARTH_RADIUS)
earth_dist_geodesics(x1, y1, x2, y2) = inverse_deg(x1, y1, x2, y2)[1]

earth_dist_haversine(p1::SpatPos, p2::SpatPos) = earth_dist_haversine(p1.longitude, p1.latitude, p2.longitude, p2.latitude)
earth_dist_geodesics(p1::SpatPos, p2::SpatPos) = earth_dist_geodesics(p1.longitude, p1.latitude, p2.longitude, p2.latitude)

# const earth_dist = earth_dist_haversine
# earth_dist(x1, y1, x2, y2) = earth_dist_geodesics(x1, y1, x2, y2)

function scale_ms(t::Millisecond, k::Float64)
    Millisecond(round(t.value * k))
end

function interpolate_stp_vec(earth_dist::Function, stp_vec::AbstractVector{SpatTempPos})
    stack = SpatTempPos[]
    
    stpi_vec = SpatTempPosInt[
        SpatTempPosInt(stp_vec[1].longitude, stp_vec[1].latitude, stp_vec[1].time, 0)]
    
    for stp in stp_vec[2:end]
        if !stp.has_time
            push!(stack, stp)
        else
            last_key_stpi = stpi_vec[end]
            key_stp_t = stp.time

            if length(stack) > 0
                dist_l = Vector{Float64}(undef, length(stack))
                last_stp = stack[1]
                dist_l[1] = earth_dist(last_key_stpi.longitude, last_key_stpi.latitude,
                        last_stp.longitude, last_stp.latitude)
                for (i, stp_minor) in enumerate(stack[2:end])
                    d = earth_dist(stp_minor.longitude, stp_minor.latitude, 
                            last_stp.longitude, last_stp.latitude)
                    dist_l[i+1] = d
                    last_stp = stp_minor
                end
                last_dist = earth_dist(
                    last_stp.longitude, last_stp.latitude, stp.longitude, stp.latitude)
                cum_sum_plus = sum(dist_l) + last_dist
                delta_range = key_stp_t - last_key_stpi.time

                # @show cumsum(dist_l)  cum_sum_plus delta_range

                p_l = scale_ms.(delta_range, cumsum(dist_l) / cum_sum_plus) .+ last_key_stpi.time
                for (stp_minor, t_it, d) in zip(stack, p_l, dist_l)
                    push!(stpi_vec, SpatTempPosInt(stp_minor.longitude, stp_minor.latitude, t_it, d))
                end
                empty!(stack)
                key_stpi = SpatTempPosInt(stp.longitude, stp.latitude, key_stp_t, last_dist)
                push!(stpi_vec, key_stpi)
            else
                key_stpi = SpatTempPosInt(stp.longitude, stp.latitude, key_stp_t,
                        earth_dist(last_key_stpi.longitude, last_key_stpi.latitude, stp.longitude, stp.latitude))
                push!(stpi_vec, key_stpi)
            end
        end
    end
    @assert length(stack) == 0
    return stpi_vec
end

interpolate_stp_vec_haversine(stp_vec) = interpolate_stp_vec(earth_dist_haversine, stp_vec)
interpolate_stp_vec_geodesics(stp_vec) = interpolate_stp_vec(earth_dist_geodesics, stp_vec)

interpolate_stp_vec(stp_vec) = interpolate_stp_vec_geodesics(stp_vec) # "recommended" method? Is it better to remove it for clarification?

Vector{SpatTempPosInt}(stp_vec::AbstractVector{SpatTempPos}) = interpolate_stp_vec(stp_vec)

function Vector{SpatTempPosInt}(action_vec::AbstractVector{<:Action}, 
                                fleet_stpi_vec_map::Dict{String, Vector{SpatTempPosInt}})
    stp_vec = Vector{SpatTempPos}(action_vec, fleet_stpi_vec_map)
    return Vector{SpatTempPosInt}(stp_vec)
end

function Vector{SpatTempPosInt}(action_vec::AbstractVector{<:Action})
    # If `fleet_stpi_vec_map` is not needed (don't need to access dynamic fleet location),
    # just create a fake empty dict. But it may cause confusing error info when fleet_stpi_vec_map is
    # needed and forget to add it as argument.
    return Vector{SpatTempPosInt}(action_vec, Dict{String, Vector{SpatTempPosInt}}())
end

function Vector{Vector{SpatTempPosInt}}(action_vec_vec::AbstractVector{<:AbstractVector{<:Action}},
        fleet_stpi_vec_map::Dict{String, Vector{SpatTempPosInt}})
    return map(action_vec_vec) do action_vec
        return Vector{SpatTempPosInt}(action_vec, fleet_stpi_vec_map)
    end
end


function Vector{Vector{SpatTempPosInt}}(ssp::SectorSearchPlan, time_begin::DateTime, time_end::DateTime)
    return Vector{SpatTempPosInt}.(Vector{Vector{Action}}(ssp, time_begin, time_end))
end

function contains(stpi_vec::AbstractVector{SpatTempPosInt}, time::DateTime)
    return (time >= stpi_vec[1].time) & (time <= stpi_vec[end].time)
end

contains(stpi_vec::AbstractVector{SpatTempPosInt}, t1::DateTime, t2::DateTime) = contains(stpi_vec, t1) & contains(stpi_vec, t2)

function interpolate_stpi_haversine(t, left_stpi, right_stpi)
    left_w = 1 - (t - left_stpi.time) / (right_stpi.time - left_stpi.time)
    longitude = left_stpi.longitude * left_w + right_stpi.longitude * (1-left_w)
    latitude = left_stpi.latitude * left_w + right_stpi.latitude * (1-left_w)
    return SpatPos(longitude, latitude)
end

function interpolate_stpi_geodesics(t, left_stpi, right_stpi)
    p = (t - left_stpi.time) / (right_stpi.time - left_stpi.time)
    if (p == 0) | (right_stpi.d == 0)
        return SpatPos(left_stpi.longitude, left_stpi.latitude)
    end
    _dist, azu, _azu_back = inverse_deg(left_stpi.longitude, left_stpi.latitude, right_stpi.longitude, right_stpi.latitude)
    lon1, lat1, backazimuth = forward_deg(left_stpi.longitude, left_stpi.latitude, azu, _dist * p)
    return SpatPos(lon1, lat1)
end


function get_pos(interpolate_stpi::Function, stpi_vec::AbstractVector{SpatTempPosInt}, t::DateTime)
    if t < stpi_vec[1].time
        error("t = $t < $(stpi_vec[1].time) = stpi_vec[1].time")
    end
    if t > stpi_vec[end].time
        error("t = $t > $(stpi_vec[end].time) = stpi_vec[end].time")
    end
    left = 1
    right = length(stpi_vec)
    
    while (right-left) > 1
        test = (left + right) ÷ 2
        test_stpi = stpi_vec[test]
        if test_stpi.time > t
            right = test
        elseif test_stpi.time < t
            left = test
        else
            return SpatPos(test_stpi.longitude, test_stpi.latitude)
        end
    end
    
    left_stpi = stpi_vec[left]
    right_stpi = stpi_vec[right]

    return interpolate_stpi(t, left_stpi, right_stpi)
end

function get_pos(interpolate_stpi::Function, stpi_vec::AbstractVector{SpatTempPosInt}, t_vec::AbstractVector{DateTime})
    # Though it's possible to implement it in a more efficient way, we will leave it to further development.
    return map(t->get_pos(interpolate_stpi, stpi_vec, t), t_vec)
end

get_pos_haversine(stpi_vec, t) = get_pos(interpolate_stpi_haversine, stpi_vec, t)
get_pos_geodesics(stpi_vec, t) = get_pos(interpolate_stpi_geodesics, stpi_vec, t)

get_pos(stpi_vec, t) = get_pos_geodesics(stpi_vec, t)

"""
    get_speed(earth_dist::Function, stpi_vec::AbstractVector{SpatTempPosInt}, t::DateTime; dt=Minute(1))

Get speed at time t (km/hour).
"""
function get_speed(earth_dist::Function, stpi_vec::AbstractVector{SpatTempPosInt}, t::DateTime; dt=Minute(1), knot=false)
    p1 = get_pos(stpi_vec, t + dt)
    p2 = get_pos(stpi_vec, t)
    v = earth_dist(p1, p2) * (Minute(60) / dt)
    if knot
        v = v / mi
    end
    return v
end


function get_speed(stpi_vec::AbstractVector{SpatTempPosInt}, t::DateTime; 
                   dt=Minute(1), knot=false)
    return get_speed(earth_dist_geodesics, stpi_vec, t; dt, knot)
end

# helper for uniform linear motion
get_speed(stpi_vec::AbstractVector{SpatTempPosInt}; dt=Minute(1), knot=false) = get_speed(stpi_vec, stpi_vec[1].time; dt, knot)

