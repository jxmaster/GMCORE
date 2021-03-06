module pv_mod

  use const_mod
  use mesh_mod
  use allocator_mod
  use namelist_mod
  use parallel_mod
  use state_mod
  use tend_mod

  implicit none

  private

  public calc_pv_on_vertex
  public calc_pv_on_edge_midpoint
  public calc_pv_on_edge_upwind
  public calc_pv_on_edge_apvm
  public calc_pv_on_edge_scale_aware_apvm

contains

  subroutine calc_pv_on_vertex(state)

    type(state_type), intent(inout) :: state

    type(mesh_type), pointer :: mesh
    integer i, j

    mesh => state%mesh

    do j = mesh%half_lat_start_idx_no_pole, mesh%half_lat_end_idx_no_pole
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
#ifdef V_POLE
        state%pv(i,j) = (                                                               &
          (                                                                             &
            state%u(i  ,j-1) * mesh%de_lon(j-1) - state%u(i  ,j  ) * mesh%de_lon(j  ) + &
            state%v(i+1,j  ) * mesh%de_lat(j  ) - state%v(i  ,j  ) * mesh%de_lat(j  )   &
          ) / mesh%vertex_area(j) + mesh%half_f(j)                                      &
        ) / state%m_vtx(i,j)
#else
        state%pv(i,j) = (                                                               &
          (                                                                             &
            state%u(i  ,j  ) * mesh%de_lon(j  ) - state%u(i  ,j+1) * mesh%de_lon(j+1) + &
            state%v(i+1,j  ) * mesh%de_lat(j  ) - state%v(i  ,j  ) * mesh%de_lat(j  )   &
          ) / mesh%vertex_area(j) + mesh%half_f(j)                                      &
        ) / state%m_vtx(i,j)
#endif
      end do
    end do
#ifdef V_POLE
    if (mesh%has_south_pole()) then
      j = mesh%half_lat_start_idx
      state%vor_sp = 0.0_r8
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
        state%vor_sp = state%vor_sp - state%u(i,j) * mesh%de_lon(j)
      end do
      call parallel_zonal_sum(state%vor_sp)
      state%vor_sp = state%vor_sp / mesh%num_half_lon / mesh%vertex_area(j)
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
        state%pv(i,j) = (state%vor_sp + mesh%half_f(j)) / state%m_vtx(i,j)
      end do
    end if
    if (mesh%has_north_pole()) then
      j = mesh%half_lat_end_idx
      state%vor_np = 0.0_r8
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
        state%vor_np = state%vor_np + state%u(i,j-1) * mesh%de_lon(j-1)
      end do
      call parallel_zonal_sum(state%vor_np)
      state%vor_np = state%vor_np / mesh%num_half_lon / mesh%vertex_area(j)
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
        state%pv(i,j) = (state%vor_np + mesh%half_f(j)) / state%m_vtx(i,j)
      end do
    end if
#else
    if (pv_pole_stokes) then
      ! Special treatment of vorticity around Poles
      if (mesh%has_south_pole()) then
        j = mesh%half_lat_start_idx
        state%vor_sp = 0.0_r8
        do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
          state%vor_sp = state%vor_sp - state%u(i,j+1) * mesh%de_lon(j+1)
        end do
        call parallel_zonal_sum(state%vor_sp)
        state%vor_sp = state%vor_sp / mesh%num_half_lon / mesh%vertex_area(j)
        do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
          state%pv(i,j) = (state%vor_sp + mesh%half_f(j)) / state%m_vtx(i,j)
        end do
      end if
      if (mesh%has_north_pole()) then
        j = mesh%half_lat_end_idx
        state%vor_np = 0.0_r8
        do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
          state%vor_np = state%vor_np + state%u(i,j) * mesh%de_lon(j)
        end do
        call parallel_zonal_sum(state%vor_np)
        state%vor_np = state%vor_np / mesh%num_half_lon / mesh%vertex_area(j)
        do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
          state%pv(i,j) = (state%vor_np + mesh%half_f(j)) / state%m_vtx(i,j)
        end do
      end if
    end if
#endif
    call parallel_fill_halo(mesh, state%pv)

  end subroutine calc_pv_on_vertex

  subroutine calc_dpv_on_edge(state)

    type(state_type), intent(inout) :: state

    type(mesh_type), pointer :: mesh
    integer i, j

    mesh => state%mesh

    ! Tangent pv difference
    do j = mesh%half_lat_start_idx_no_pole, mesh%half_lat_end_idx_no_pole
      do i = mesh%full_lon_start_idx, mesh%full_lon_end_idx
        state%dpv_lat_t(i,j) = state%pv(i,j) - state%pv(i-1,j)
      end do
    end do
    call parallel_fill_halo(mesh, state%dpv_lat_t)

    do j = mesh%full_lat_start_idx_no_pole, mesh%full_lat_end_idx_no_pole
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
#ifdef V_POLE
        state%dpv_lon_t(i,j) = state%pv(i,j+1) - state%pv(i,j)
#else
        state%dpv_lon_t(i,j) = state%pv(i,j) - state%pv(i,j-1)
#endif
      end do
    end do
    call parallel_fill_halo(mesh, state%dpv_lon_t)

    ! Normal pv difference
    do j = mesh%half_lat_start_idx_no_pole, mesh%half_lat_end_idx_no_pole
      do i = mesh%full_lon_start_idx, mesh%full_lon_end_idx
#ifdef V_POLE
        state%dpv_lat_n(i,j) = 0.25_r8 * (state%dpv_lon_t(i-1,j-1) + state%dpv_lon_t(i,j-1) + &
                                          state%dpv_lon_t(i-1,j  ) + state%dpv_lon_t(i,j  ))
#else
        state%dpv_lat_n(i,j) = 0.25_r8 * (state%dpv_lon_t(i-1,j  ) + state%dpv_lon_t(i,j  ) + &
                                          state%dpv_lon_t(i-1,j+1) + state%dpv_lon_t(i,j+1))
#endif
      end do
    end do

    do j = mesh%full_lat_start_idx_no_pole, mesh%full_lat_end_idx_no_pole
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
#ifdef V_POLE
        state%dpv_lon_n(i,j) = 0.25_r8 * (state%dpv_lat_t(i,j  ) + state%dpv_lat_t(i+1,j  ) + &
                                          state%dpv_lat_t(i,j+1) + state%dpv_lat_t(i+1,j+1))
#else
        state%dpv_lon_n(i,j) = 0.25_r8 * (state%dpv_lat_t(i,j-1) + state%dpv_lat_t(i+1,j-1) + &
                                          state%dpv_lat_t(i,j  ) + state%dpv_lat_t(i+1,j  ))
#endif
      end do
    end do

  end subroutine calc_dpv_on_edge

  subroutine calc_pv_on_edge_midpoint(state)

    type(state_type), intent(inout) :: state

    type(mesh_type), pointer :: mesh
    integer i, j

    mesh => state%mesh

    do j = mesh%half_lat_start_idx, mesh%half_lat_end_idx
      do i = mesh%full_lon_start_idx, mesh%full_lon_end_idx
        state%pv_lat(i,j) = 0.5_r8 * (state%pv(i-1,j) + state%pv(i,j))
      end do 
    end do 
    call parallel_fill_halo(mesh, state%pv_lon)

    do j = mesh%full_lat_start_idx_no_pole, mesh%full_lat_end_idx_no_pole
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
#ifdef V_POLE
        state%pv_lon(i,j) = 0.5_r8 * (state%pv(i,j) + state%pv(i,j+1))
#else
        state%pv_lon(i,j) = 0.5_r8 * (state%pv(i,j) + state%pv(i,j-1))
#endif
      end do 
    end do 
    call parallel_fill_halo(mesh, state%pv_lat)

  end subroutine calc_pv_on_edge_midpoint

  subroutine calc_pv_on_edge_upwind(state)

    type(state_type), intent(inout) :: state

    type(mesh_type), pointer :: mesh
    real(r8), parameter :: beta0 = 1.0_r8
    real(r8), parameter :: dpv0 = 1.0e-9_r8
    real(r8) dpv, beta
    integer i, j

    call calc_dpv_on_edge(state)

    mesh => state%mesh

    do j = mesh%full_lat_start_idx_no_pole, mesh%full_lat_end_idx_no_pole 
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
        ! beta = mesh%full_upwind_beta(j)
        dpv = min(abs(state%dpv_lon_t(i,j)), abs(state%dpv_lon_n(i,j)))
        beta = beta0 * exp(-(dpv0 / dpv)**2)
#ifdef V_POLE
        state%pv_lon(i,j) = 0.5_r8 * (state%pv(i,j+1) + state%pv(i,j)) - &
          beta * 0.5_r8 * (                                              &
            state%dpv_lon_t(i,j) * sign(1.0_r8, state%mf_lon_t(i,j) +    &
            state%dpv_lon_n(i,j) * sign(1.0_r8, state%u(i,j)))           &
          )
#else
        state%pv_lon(i,j) = 0.5_r8 * (state%pv(i,j-1) + state%pv(i,j)) - &
          beta * 0.5_r8 * (                                              &
            state%dpv_lon_t(i,j) * sign(1.0_r8, state%mf_lon_t(i,j) +    &
            state%dpv_lon_n(i,j) * sign(1.0_r8, state%u(i,j)))           &
          )
#endif
      end do
    end do
    call parallel_fill_halo(mesh, state%pv_lon)

    do j = mesh%half_lat_start_idx, mesh%half_lat_end_idx
      do i = mesh%full_lon_start_idx, mesh%full_lon_end_idx
        ! beta = mesh%half_upwind_beta(j)
        dpv = min(abs(state%dpv_lat_t(i,j)), abs(state%dpv_lat_n(i,j)))
        beta = beta0 * exp(-(dpv0 / dpv)**2)
        state%pv_lat(i,j) = 0.5_r8 * (state%pv(i,j) + state%pv(i-1,j)) - &
          beta * 0.5_r8 * (                                              &
            state%dpv_lat_t(i,j) * sign(1.0_r8, state%mf_lat_t(i,j) +    &
            state%dpv_lat_n(i,j) * sign(1.0_r8, state%v(i,j)))           &
          )
      end do
    end do
    call parallel_fill_halo(mesh, state%pv_lat)

  end subroutine calc_pv_on_edge_upwind

  subroutine calc_pv_on_edge_apvm(state, dt)

    type(state_type), intent(inout) :: state
    real(r8)        , intent(in   ) :: dt

    type(mesh_type), pointer :: mesh
    real(r8) u, v, le, de
    integer i, j

    call calc_dpv_on_edge(state)

    mesh => state%mesh

    do j = mesh%half_lat_start_idx_no_pole, mesh%half_lat_end_idx_no_pole
      le = mesh%le_lat(j)
      de = mesh%de_lat(j)
      do i = mesh%full_lon_start_idx, mesh%full_lon_end_idx
        u = state%mf_lat_t(i,j) / state%m_lat(i,j)
        v = state%v(i,j)
        state%pv_lat(i,j) = 0.5_r8 * (state%pv(i,j) + state%pv(i-1,j)) - &
          0.5_r8 * (u * state%dpv_lat_t(i,j) / le + v * state%dpv_lat_n(i,j) / de) * dt
      end do
    end do
#ifdef V_POLE
    state%pv_lat(:,mesh%half_lat_start_idx) = state%pv(:,mesh%half_lat_start_idx)
    state%pv_lat(:,mesh%half_lat_end_idx  ) = state%pv(:,mesh%half_lat_end_idx  )
#endif
    call parallel_fill_halo(mesh, state%pv_lat)

    do j = mesh%full_lat_start_idx_no_pole, mesh%full_lat_end_idx_no_pole
      le = mesh%le_lon(j)
      de = mesh%de_lon(j)
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
        u = state%u(i,j)
        v = state%mf_lon_t(i,j) / state%m_lon(i,j)
#ifdef V_POLE
        state%pv_lon(i,j) = 0.5_r8 * (state%pv(i,j+1) + state%pv(i,j)) - &
          0.5_r8 * (u * state%dpv_lon_n(i,j) / de + v * state%dpv_lon_t(i,j) / le) * dt
#else
        state%pv_lon(i,j) = 0.5_r8 * (state%pv(i,j-1) + state%pv(i,j)) - &
          0.5_r8 * (u * state%dpv_lon_n(i,j) / de + v * state%dpv_lon_t(i,j) / le) * dt
#endif
      end do
    end do
    call parallel_fill_halo(mesh, state%pv_lon)

  end subroutine calc_pv_on_edge_apvm

  subroutine calc_pv_on_edge_scale_aware_apvm(state)

    type(state_type), intent(inout) :: state

    type(mesh_type), pointer :: mesh
    real(r8), parameter :: alpha = 0.0013_r8
    real(r8) u, v, le, de, ke, h, pv_adv
    integer i, j

    call calc_dpv_on_edge(state)

    mesh => state%mesh

    ke = state%total_ke**(-3.0_r8 / 4.0_r8)
    h  = state%total_m / mesh%total_area / g

    do j = mesh%half_lat_start_idx_no_pole, mesh%half_lat_end_idx_no_pole
      le = mesh%le_lat(j)
      de = mesh%de_lat(j)
      do i = mesh%full_lon_start_idx, mesh%full_lon_end_idx
        u = state%mf_lat_t(i,j) / state%m_lat(i,j)
        v = state%v(i,j)
        pv_adv = u * state%dpv_lat_t(i,j) / le + v * state%dpv_lat_n(i,j) / de
        state%pv_lat (i,j) = 0.5_r8 * (state%pv(i,j) + state%pv(i-1,j)) - alpha * ke * h * de**3 * abs(pv_adv) * pv_adv
      end do
    end do
#ifdef V_POLE
    state%pv_lat(:,mesh%half_lon_start_idx) = state%pv(:,mesh%half_lon_start_idx)
    state%pv_lat(:,mesh%half_lon_end_idx  ) = state%pv(:,mesh%half_lon_end_idx  )
#endif

    do j = mesh%full_lat_start_idx_no_pole, mesh%full_lat_end_idx_no_pole
      le = mesh%le_lon(j)
      de = mesh%de_lon(j)
      do i = mesh%half_lon_start_idx, mesh%half_lon_end_idx
        u = state%u(i,j)
        v = state%mf_lon_t(i,j) / state%m_lon(i,j)
        pv_adv = u * state%dpv_lon_n(i,j) / de + v * state%dpv_lon_t(i,j) / le
#ifdef V_POLE
        state%pv_lon (i,j) = 0.5_r8 * (state%pv(i,j+1) + state%pv(i,j)) - alpha * ke * h * de**3 * abs(pv_adv) * pv_adv
#else
        state%pv_lon (i,j) = 0.5_r8 * (state%pv(i,j-1) + state%pv(i,j)) - alpha * ke * h * de**3 * abs(pv_adv) * pv_adv
#endif
      end do
    end do

    call parallel_fill_halo(mesh, state%pv_lon)
    call parallel_fill_halo(mesh, state%pv_lat)

  end subroutine calc_pv_on_edge_scale_aware_apvm

end module pv_mod