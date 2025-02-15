# Energy calculation

export
    total_energy,
    kinetic_energy,
    temperature,
    potential_energy

"""
    total_energy(system, neighbors=nothing; n_threads=Threads.nthreads())

Calculate the total energy of a system as the sum of the [`kinetic_energy`](@ref)
and the [`potential_energy`](@ref).

If the interactions use neighbor lists, the neighbors should be computed
first and passed to the function.
"""
function total_energy(sys, neighbors=nothing; n_threads::Integer=Threads.nthreads())
    return kinetic_energy(sys) + potential_energy(sys, neighbors; n_threads=n_threads)
end

kinetic_energy_noconvert(sys) = sum(masses(sys) .* sum.(abs2, sys.velocities)) / 2

"""
    kinetic_energy(system)

Calculate the kinetic energy of a system.
"""
function kinetic_energy(sys::System{D, G, T}) where {D, G, T}
    ke = kinetic_energy_noconvert(sys)
    return uconvert(sys.energy_units, ke)
end

"""
    temperature(system)

Calculate the temperature of a system from the kinetic energy of the atoms.
"""
function temperature(sys)
    ke = kinetic_energy_noconvert(sys)
    df = 3 * length(sys) - 3
    temp = 2 * ke / (df * sys.k)
    if sys.energy_units == NoUnits
        return temp
    else
        return uconvert(u"K", temp)
    end
end


"""
    potential_energy(system, neighbors=nothing; n_threads=Threads.nthreads())

Calculate the potential energy of a system using the pairwise, specific and
general interactions.

If the interactions use neighbor lists, the neighbors should be computed
first and passed to the function.

    potential_energy(inter::PairwiseInteraction, vec_ij, coord_i, coord_j,
                     atom_i, atom_j, boundary)
    potential_energy(inter::SpecificInteraction, coords_i, coords_j,
                     boundary)
    potential_energy(inter::SpecificInteraction, coords_i, coords_j,
                     coords_k, boundary)
    potential_energy(inter::SpecificInteraction, coords_i, coords_j,
                     coords_k, coords_l, boundary)
    potential_energy(inter, system, neighbors=nothing; n_threads=Threads.nthreads())

Calculate the potential energy due to a given interaction type.

Custom interaction types should implement this function.
"""
function potential_energy(sys::System{D, false, T}, neighbors=nothing;
                          n_threads::Integer=Threads.nthreads()) where {D, T}
    pairwise_inters_nonl = filter(!use_neighbors, values(sys.pairwise_inters))
    pairwise_inters_nl   = filter( use_neighbors, values(sys.pairwise_inters))
    sils_1_atoms = filter(il -> il isa InteractionList1Atoms, values(sys.specific_inter_lists))
    sils_2_atoms = filter(il -> il isa InteractionList2Atoms, values(sys.specific_inter_lists))
    sils_3_atoms = filter(il -> il isa InteractionList3Atoms, values(sys.specific_inter_lists))
    sils_4_atoms = filter(il -> il isa InteractionList4Atoms, values(sys.specific_inter_lists))

    pe = potential_energy_pair_spec(sys.coords, sys.atoms, pairwise_inters_nonl, pairwise_inters_nl,
                            sils_1_atoms, sils_2_atoms, sils_3_atoms, sils_4_atoms, sys.boundary,
                            sys.energy_units, neighbors, n_threads, Val(T))

    for inter in values(sys.general_inters)
        pe += potential_energy(inter, sys, neighbors; n_threads=n_threads)
    end

    return pe
end

function potential_energy_pair_spec(coords, atoms, pairwise_inters_nonl, pairwise_inters_nl,
                                    sils_1_atoms, sils_2_atoms, sils_3_atoms, sils_4_atoms,
                                    boundary, energy_units, neighbors, n_threads,
                                    val_ft::Val{T}) where T
    pe_vec = zeros(T, 1)
    potential_energy_pair_spec!(pe_vec, coords, atoms, pairwise_inters_nonl, pairwise_inters_nl,
                                sils_1_atoms, sils_2_atoms, sils_3_atoms, sils_4_atoms, boundary,
                                energy_units, neighbors, n_threads, val_ft)
    return pe_vec[1] * energy_units
end

@inbounds function potential_energy_pair_spec!(pe_vec, coords, atoms, pairwise_inters_nonl,
                        pairwise_inters_nl, sils_1_atoms, sils_2_atoms, sils_3_atoms, sils_4_atoms,
                        boundary, energy_units, neighbors, n_threads, ::Val{T}) where T
    pe_sum = zero(T)

    if n_threads > 1
        pe_sum_chunks = [zero(T) for _ in 1:n_threads]

        if length(pairwise_inters_nonl) > 0
            n_atoms = length(coords)
            Threads.@threads for chunk_i in 1:n_threads
                for i in chunk_i:n_threads:n_atoms
                    for j in (i + 1):n_atoms
                        dr = vector(coords[i], coords[j], boundary)
                        pe = potential_energy(pairwise_inters_nonl[1], dr, coords[i], coords[j], atoms[i],
                                              atoms[j], boundary)
                        for inter in pairwise_inters_nonl[2:end]
                            pe += potential_energy(inter, dr, coords[i], coords[j], atoms[i],
                                                   atoms[j], boundary)
                        end
                        check_energy_units(pe, energy_units)
                        pe_sum_chunks[chunk_i] += ustrip(pe)
                    end
                end
            end
        end

        if length(pairwise_inters_nl) > 0
            if isnothing(neighbors)
                error("an interaction uses the neighbor list but neighbors is nothing")
            end
            Threads.@threads for chunk_i in 1:n_threads
                for ni in chunk_i:n_threads:length(neighbors)
                    i, j, special = neighbors[ni]
                    dr = vector(coords[i], coords[j], boundary)
                    pe = potential_energy(pairwise_inters_nl[1], dr, coords[i], coords[j], atoms[i],
                                          atoms[j], boundary, special)
                    for inter in pairwise_inters_nl[2:end]
                        pe += potential_energy(inter, dr, coords[i], coords[j], atoms[i],
                                               atoms[j], boundary, special)
                    end
                    check_energy_units(pe, energy_units)
                    pe_sum_chunks[chunk_i] += ustrip(pe)
                end
            end
        end

        pe_sum += sum(pe_sum_chunks)
    else
        if length(pairwise_inters_nonl) > 0
            n_atoms = length(coords)
            for i in 1:n_atoms
                for j in (i + 1):n_atoms
                    dr = vector(coords[i], coords[j], boundary)
                    pe = potential_energy(pairwise_inters_nonl[1], dr, coords[i], coords[j], atoms[i],
                                          atoms[j], boundary)
                    for inter in pairwise_inters_nonl[2:end]
                        pe += potential_energy(inter, dr, coords[i], coords[j], atoms[i],
                                               atoms[j], boundary)
                    end
                    check_energy_units(pe, energy_units)
                    pe_sum += ustrip(pe)
                end
            end
        end

        if length(pairwise_inters_nl) > 0
            if isnothing(neighbors)
                error("an interaction uses the neighbor list but neighbors is nothing")
            end
            for ni in eachindex(neighbors)
                i, j, special = neighbors[ni]
                dr = vector(coords[i], coords[j], boundary)
                pe = potential_energy(pairwise_inters_nl[1], dr, coords[i], coords[j], atoms[i],
                                      atoms[j], boundary, special)
                for inter in pairwise_inters_nl[2:end]
                    pe += potential_energy(inter, dr, coords[i], coords[j], atoms[i],
                                           atoms[j], boundary, special)
                end
                check_energy_units(pe, energy_units)
                pe_sum += ustrip(pe)
            end
        end
    end

    for inter_list in sils_1_atoms
        for (i, inter) in zip(inter_list.is, inter_list.inters)
            pe = potential_energy(inter, coords[i], boundary)
            check_energy_units(pe, energy_units)
            pe_sum += ustrip(pe)
        end
    end

    for inter_list in sils_2_atoms
        for (i, j, inter) in zip(inter_list.is, inter_list.js, inter_list.inters)
            pe = potential_energy(inter, coords[i], coords[j], boundary)
            check_energy_units(pe, energy_units)
            pe_sum += ustrip(pe)
        end
    end

    for inter_list in sils_3_atoms
        for (i, j, k, inter) in zip(inter_list.is, inter_list.js, inter_list.ks, inter_list.inters)
            pe = potential_energy(inter, coords[i], coords[j], coords[k], boundary)
            check_energy_units(pe, energy_units)
            pe_sum += ustrip(pe)
        end
    end

    for inter_list in sils_4_atoms
        for (i, j, k, l, inter) in zip(inter_list.is, inter_list.js, inter_list.ks, inter_list.ls,
                                       inter_list.inters)
            pe = potential_energy(inter, coords[i], coords[j], coords[k], coords[l], boundary)
            check_energy_units(pe, energy_units)
            pe_sum += ustrip(pe)
        end
    end

    pe_vec[1] = pe_sum
    return nothing
end

function potential_energy(sys::System{D, true, T}, neighbors=nothing;
                          n_threads::Integer=Threads.nthreads()) where {D, T}
    n_atoms = length(sys)
    val_ft = Val(T)
    pe_vec = CUDA.zeros(T, 1)

    pairwise_inters_nonl = filter(!use_neighbors, values(sys.pairwise_inters))
    if length(pairwise_inters_nonl) > 0
        nbs = NoNeighborList(n_atoms)
        pe_vec += pairwise_pe_gpu(sys.coords, sys.atoms, sys.boundary, pairwise_inters_nonl,
                                  nbs, sys.energy_units, val_ft)
    end

    pairwise_inters_nl = filter(use_neighbors, values(sys.pairwise_inters))
    if length(pairwise_inters_nl) > 0
        if isnothing(neighbors)
            error("an interaction uses the neighbor list but neighbors is nothing")
        end
        if length(neighbors) > 0
            nbs = @view neighbors.list[1:neighbors.n]
            pe_vec += pairwise_pe_gpu(sys.coords, sys.atoms, sys.boundary, pairwise_inters_nl,
                                      nbs, sys.energy_units, val_ft)
        end
    end

    for inter_list in values(sys.specific_inter_lists)
        pe_vec += specific_pe_gpu(inter_list, sys.coords, sys.boundary, sys.energy_units, val_ft)
    end

    pe = Array(pe_vec)[1]

    for inter in values(sys.general_inters)
        pe += ustrip(sys.energy_units, potential_energy(inter, sys, neighbors; n_threads=n_threads))
    end

    return pe * sys.energy_units
end

function potential_energy(inter, dr, coord_i, coord_j, atom_i, atom_j, boundary, special)
    # Fallback for interactions where special interactions are not relevant
    return potential_energy(inter, dr, coord_i, coord_j, atom_i, atom_j, boundary)
end
