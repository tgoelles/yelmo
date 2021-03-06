module velocity_diva

    use yelmo_defs ,only  : prec, rho_ice, rho_sw, rho_w, g
    use yelmo_tools, only : stagger_aa_ab, stagger_aa_ab_ice, &
                    calc_vertical_integrated_2D, & 
                    integrate_trapezoid1D_1D, integrate_trapezoid1D_pt, minmax

    use basal_dragging 
    use solver_ssa_sico5 

    implicit none 

    type diva_param_class

        character(len=256) :: ssa_lis_opt 
        character(len=256) :: boundaries 
        logical    :: diva_no_slip 
        integer    :: beta_method
        real(prec) :: beta_const
        real(prec) :: beta_q                ! Friction law exponent
        real(prec) :: beta_u0               ! [m/a] Friction law velocity threshold 
        integer    :: beta_gl_scale         ! Beta grounding-line scaling method (beta => 0 at gl?)
        integer    :: beta_gl_stag          ! Beta grounding-line staggering method 
        real(prec) :: beta_gl_f             ! Fraction of beta at gl 
        real(prec) :: H_grnd_lim 
        real(prec) :: beta_min              ! Minimum allowed value of beta
        real(prec) :: eps_0 
        real(prec) :: ssa_vel_max
        integer    :: ssa_iter_max 
        real(prec) :: ssa_iter_rel 
        real(prec) :: ssa_iter_conv 
        logical    :: ssa_write_log 

    end type

    private
    public :: diva_param_class 
    public :: calc_velocity_diva

contains 

    subroutine calc_velocity_diva(ux,uy,ux_i,uy_i,ux_bar,uy_bar,ux_b,uy_b,duxdz,duydz,taub_acx,taub_acy, &
                                  visc_eff,visc_eff_int,ssa_mask_acx,ssa_mask_acy,ssa_err_acx,ssa_err_acy,ssa_iter_now, &
                                  beta,beta_acx,beta_acy,beta_eff,beta_diva,c_bed,taud_acx,taud_acy,H_ice,H_grnd,f_grnd, &
                                  f_grnd_acx,f_grnd_acy,ATT,zeta_aa,z_sl,z_bed,dx,dy,n_glen,par)
        ! This subroutine is used to solve the horizontal velocity system (ux,uy)
        ! following the Depth-Integrated Viscosity Approximation (DIVA),
        ! as outlined by Lipscomb et al. (2019). Method originally 
        ! proposed by Goldberg (2011), algorithm by Arthern et al (2015), 
        ! updated by Lipscomb et al. (2019).

        implicit none 

        real(prec), intent(INOUT) :: ux(:,:,:)          ! [m/a]
        real(prec), intent(INOUT) :: uy(:,:,:)          ! [m/a]
        real(prec), intent(INOUT) :: ux_i(:,:,:)        ! [m/a]
        real(prec), intent(INOUT) :: uy_i(:,:,:)        ! [m/a]
        real(prec), intent(INOUT) :: ux_bar(:,:)        ! [m/a]
        real(prec), intent(INOUT) :: uy_bar(:,:)        ! [m/a]
        real(prec), intent(INOUT) :: ux_b(:,:)          ! [m/a]
        real(prec), intent(INOUT) :: uy_b(:,:)          ! [m/a]
        real(prec), intent(INOUT) :: duxdz(:,:,:)       ! [1/a]
        real(prec), intent(INOUT) :: duydz(:,:,:)       ! [1/a]
        real(prec), intent(INOUT) :: taub_acx(:,:)      ! [Pa]
        real(prec), intent(INOUT) :: taub_acy(:,:)      ! [Pa]
        real(prec), intent(INOUT) :: visc_eff(:,:,:)    ! [Pa a]
        real(prec), intent(OUT)   :: visc_eff_int(:,:)  ! [Pa a m]
        integer,    intent(OUT)   :: ssa_mask_acx(:,:)  ! [-]
        integer,    intent(OUT)   :: ssa_mask_acy(:,:)  ! [-]
        real(prec), intent(OUT)   :: ssa_err_acx(:,:)
        real(prec), intent(OUT)   :: ssa_err_acy(:,:)
        integer,    intent(OUT)   :: ssa_iter_now 
        real(prec), intent(INOUT) :: beta(:,:)          ! [Pa a/m]
        real(prec), intent(INOUT) :: beta_acx(:,:)      ! [Pa a/m]
        real(prec), intent(INOUT) :: beta_acy(:,:)      ! [Pa a/m]
        real(prec), intent(OUT)   :: beta_eff(:,:)      ! [Pa a/m]
        real(prec), intent(OUT)   :: beta_diva(:,:)     ! [Pa a/m]
        real(prec), intent(IN)    :: c_bed(:,:)         ! [Pa]
        real(prec), intent(IN)    :: taud_acx(:,:)      ! [Pa]
        real(prec), intent(IN)    :: taud_acy(:,:)      ! [Pa]
        real(prec), intent(IN)    :: H_ice(:,:)         ! [m]
        real(prec), intent(IN)    :: H_grnd(:,:)        ! [m]
        real(prec), intent(IN)    :: f_grnd(:,:)        ! [-]
        real(prec), intent(IN)    :: f_grnd_acx(:,:)    ! [-]
        real(prec), intent(IN)    :: f_grnd_acy(:,:)    ! [-]
        real(prec), intent(IN)    :: ATT(:,:,:)         ! [a^-1 Pa^-n_glen]
        real(prec), intent(IN)    :: zeta_aa(:)         ! [-]
        real(prec), intent(IN)    :: z_sl(:,:)          ! [m]
        real(prec), intent(IN)    :: z_bed(:,:)         ! [m]
        real(prec), intent(IN)    :: dx                 ! [m]
        real(prec), intent(IN)    :: dy                 ! [m]
        real(prec), intent(IN)    :: n_glen 
        type(diva_param_class), intent(IN) :: par       ! List of parameters that should be defined

        ! Local variables 
        integer :: i, j, k, nx, ny, nz_aa, nz_ac, iter 
        logical :: is_converged

        real(prec), allocatable :: ux_bar_nm1(:,:) 
        real(prec), allocatable :: uy_bar_nm1(:,:)  
        real(prec), allocatable :: beta_eff_acx(:,:)
        real(prec), allocatable :: beta_eff_acy(:,:)  
        real(prec), allocatable :: F2(:,:)              ! [Pa^-1 a^-1 m == (Pa a/m)^-1]
        integer,    allocatable :: ssa_mask_acx_ref(:,:)
        integer,    allocatable :: ssa_mask_acy_ref(:,:)

        real(prec) :: L2_norm 

        nx    = size(ux,1)
        ny    = size(ux,2)
        nz_aa = size(ux,3)

        ! Prepare local variables 
        allocate(ux_bar_nm1(nx,ny))
        allocate(uy_bar_nm1(nx,ny))
        allocate(beta_eff_acx(nx,ny))
        allocate(beta_eff_acy(nx,ny))
        allocate(F2(nx,ny))

        allocate(ssa_mask_acx_ref(nx,ny))
        allocate(ssa_mask_acy_ref(nx,ny))

        ! Store original ssa mask before iterations
        ssa_mask_acx_ref = ssa_mask_acx
        ssa_mask_acy_ref = ssa_mask_acy
            
        ! Initially set error very high 
        ssa_err_acx = 1.0_prec 
        ssa_err_acy = 1.0_prec 
        
        do iter = 1, par%ssa_iter_max 

            ! Store solution from previous iteration (nm1 == n minus 1) 
            ux_bar_nm1 = ux_bar 
            uy_bar_nm1 = uy_bar 
            
            ! =========================================================================================
            ! Step 1: Calculate fields needed by ssa solver (visc_eff_int, beta_eff)

            ! Calculate the 3D vertical shear fields using viscosity estimated from the previous iteration 
            call calc_vertical_shear_3D(duxdz,duydz,taub_acx,taub_acy,visc_eff,zeta_aa,par%boundaries)

            ! Calculate 3D effective viscosity, using velocity solution from previous iteration
            call calc_visc_eff_3D(visc_eff,ux_bar,uy_bar,duxdz,duydz,ATT,zeta_aa,dx,dy,n_glen,par%eps_0)

            ! Calculate depth-integrated effective viscosity
            ! Note L19 uses eta_bar*H in the ssa equation. Yelmo uses eta_int=eta_bar*H directly.
            visc_eff_int = calc_vertical_integrated_2D(visc_eff,zeta_aa) 
            where(H_ice .gt. 0.0_prec) visc_eff_int = visc_eff_int*H_ice 

            ! Calculate beta (at the ice base)
            call calc_beta(beta,c_bed,ux_b,uy_b,H_ice,H_grnd,f_grnd,z_bed,z_sl,par%beta_method, &
                                par%beta_const,par%beta_q,par%beta_u0,par%beta_gl_scale,par%beta_gl_f, &
                                par%H_grnd_lim,par%beta_min,par%boundaries)

            ! Calculate F-integeral (F2) on aa-nodes 
            call calc_F_integral(F2,visc_eff,H_ice,zeta_aa,n=2.0_prec)
            
            ! Calculate effective beta 
            call calc_beta_eff(beta_eff,beta,ux_b,uy_b,F2,zeta_aa,no_slip=par%diva_no_slip)

            ! Stagger beta and beta_eff 
            call stagger_beta(beta_acx,beta_acy,beta,f_grnd,f_grnd_acx,f_grnd_acy,par%beta_gl_stag,par%boundaries)
            call stagger_beta(beta_eff_acx,beta_eff_acy,beta_eff,f_grnd,f_grnd_acx,f_grnd_acy,par%beta_gl_stag,par%boundaries)
            
            ! ajr: not very stable:
            !call calc_beta_eff_ac(beta_eff_acx,beta_eff_acy,beta_acx,beta_acy,ux_b,uy_b,F2,H_ice,zeta_aa,par%diva_no_slip,par%boundaries)

            ! =========================================================================================
            ! Step 2: Call the SSA solver to obtain new estimate of ux_bar/uy_bar

if (.TRUE.) then 
            if (iter .gt. 1) then
                ! Update ssa mask based on convergence with previous step to reduce area being solved 
                call update_ssa_mask_convergence(ssa_mask_acx,ssa_mask_acy,ssa_err_acx,ssa_err_acy,err_lim=real(1e-5,prec))
                !call update_ssa_mask_convergence(ssa_mask_acx,ssa_mask_acy,ssa_err_acx,ssa_err_acy,err_lim=par%ssa_iter_conv*1e-2)  
            end if 
end if 
            
            ! Call ssa solver
            call calc_vxy_ssa_matrix(ux_bar,uy_bar,L2_norm,beta_eff_acx,beta_eff_acy,visc_eff_int,  &
                                     ssa_mask_acx,ssa_mask_acy,H_ice,taud_acx,taud_acy,H_grnd,z_sl, &
                                     z_bed,dx,dy,par%ssa_vel_max,par%boundaries,par%ssa_lis_opt)


            ! Apply relaxation to keep things stable
            call relax_ssa(ux_bar,uy_bar,ux_bar_nm1,uy_bar_nm1,rel=par%ssa_iter_rel)
            
            ! Check for convergence
            is_converged = check_vel_convergence_l2rel(ux_bar,uy_bar,ux_bar_nm1,uy_bar_nm1,ssa_mask_acx.gt.0,     &
                                                       ssa_mask_acy.gt.0,par%ssa_iter_conv,iter,par%ssa_iter_max, &
                                                       par%ssa_write_log,use_L2_norm=.FALSE.,L2_norm=L2_norm)

            ! Calculate an L1 error metric over matrix for diagnostics
            call check_vel_convergence_l1rel_matrix(ssa_err_acx,ssa_err_acy,ux_bar,uy_bar,ux_bar_nm1,uy_bar_nm1)

            ! Store current total iterations for output
            ssa_iter_now = iter 

            ! =========================================================================================
            ! Update additional fields based on output of solver
             
            ! Calculate basal stress 
            call calc_basal_stress(taub_acx,taub_acy,beta_eff_acx,beta_eff_acy,ux_bar,uy_bar)

            ! Calculate basal velocity from depth-averaged solution and basal stress
            call calc_vel_basal(ux_b,uy_b,ux_bar,uy_bar,F2,taub_acx,taub_acy,H_ice,par%boundaries)

            ! Exit iterations if ssa solution has converged
            if (is_converged) exit 
            
        end do 

        ! Iterations are finished, finalize calculations of 3D velocity field 

        ! Calculate the 3D horizontal velocity field
        call calc_vel_horizontal_3D(ux,uy,ux_b,uy_b,taub_acx,taub_acy,visc_eff,H_ice,zeta_aa,par%boundaries)

        ! Also calculate the shearing contribution
        do k = 1, nz_aa 
            ux_i(:,:,k) = ux(:,:,k) - ux_b 
            uy_i(:,:,k) = uy(:,:,k) - uy_b 
        end do

        ! Diagnose beta actually being used by DIVA
        call diagnose_beta_diva(beta_diva,beta_eff,F2,beta)

        return 

    end subroutine calc_velocity_diva 

    subroutine calc_vel_horizontal_3D(ux,uy,ux_b,uy_b,taub_acx,taub_acy,visc_eff,H_ice,zeta_aa,boundaries)
        ! Caluculate the 3D horizontal velocity field (ux,uy)
        ! following L19, Eq. 29 

        implicit none 

        real(prec), intent(OUT) :: ux(:,:,:) 
        real(prec), intent(OUT) :: uy(:,:,:) 
        real(prec), intent(IN)  :: ux_b(:,:) 
        real(prec), intent(IN)  :: uy_b(:,:) 
        real(prec), intent(IN)  :: taub_acx(:,:) 
        real(prec), intent(IN)  :: taub_acy(:,:)
        real(prec), intent(IN)  :: visc_eff(:,:,:)       
        real(prec), intent(IN)  :: H_ice(:,:)
        real(prec), intent(IN)  :: zeta_aa(:) 
        character(len=*), intent(IN) :: boundaries 

        ! Local variables
        integer :: i, j, k, ip1, jp1, nx, ny, nz_aa  
        real(prec) :: H_ice_ac 
        real(prec), allocatable :: visc_eff_ac(:) 
        real(prec), allocatable :: F1(:,:,:) 
        real(prec), allocatable :: F1_ac(:) 
        
        nx    = size(ux,1)
        ny    = size(ux,2) 
        nz_aa = size(ux,3) 

        allocate(visc_eff_ac(nz_aa))
        allocate(F1(nx,ny,nz_aa))
        allocate(F1_ac(nz_aa))

        ! First calculate F1 array on aa-nodes 
        ! (performing integral before staggering seems to improve result slightly)
        ! Note: L19 define the F1 integral as purely going from the base to the surface,
        ! whereas here F1 is calculated from the base to each point in the vertical. So, 
        ! it is not technically "F1" as defined by L19, Eq. 30, except at the surface.
        do j = 1, ny 
        do i = 1, nx 
            F1(i,j,:) = integrate_trapezoid1D_1D((H_ice(i,j)/visc_eff(i,j,:))*(1.0-zeta_aa),zeta_aa)
        end do
        end do  

        ! Next calculate 3D horizontal velocity components 
        do j = 1, ny 
        do i = 1, nx 

            ip1 = min(i+1,nx)
            jp1 = min(j+1,ny) 

            ! === x direction ===============================================

            ! Stagger F1 column to ac-nodes 
            if (H_ice(i,j) .gt. 0.0 .and. H_ice(ip1,j) .eq. 0.0) then 
                F1_ac = F1(i,j,:) 
            else if (H_ice(i,j) .eq. 0.0 .and. H_ice(ip1,j) .gt. 0.0) then
                F1_ac = F1(ip1,j,:)
            else 
                F1_ac = 0.5_prec*(F1(i,j,:) + F1(ip1,j,:))
            end if 

            ! Calculate velocity column 
            ux(i,j,:) = ux_b(i,j) + taub_acx(i,j)*F1_ac 

            ! === y direction ===============================================

            ! Stagger F1 column to ac-nodes 
            if (H_ice(i,j) .gt. 0.0 .and. H_ice(i,jp1) .eq. 0.0) then 
                F1_ac = F1(i,j,:) 
            else if (H_ice(i,j) .eq. 0.0 .and. H_ice(i,jp1) .gt. 0.0) then
                F1_ac = F1(i,jp1,:)
            else 
                F1_ac = 0.5_prec*(F1(i,j,:) + F1(i,jp1,:))
            end if 

            ! Calculate velocity column
            uy(i,j,:) = uy_b(i,j) + taub_acy(i,j)*F1_ac  

        end do 
        end do  

        ! Apply boundary conditions as needed 
        if (trim(boundaries) .eq. "periodic") then

            ux(1,:,:)    = ux(nx-2,:,:) 
            ux(nx-1,:,:) = ux(2,:,:) 
            ux(nx,:,:)   = ux(3,:,:) 
            ux(:,1,:)    = ux(:,ny-1,:)
            ux(:,ny,:)   = ux(:,2,:) 

            uy(1,:,:)    = uy(nx-1,:,:) 
            uy(nx,:,:)   = uy(2,:,:) 
            uy(:,1,:)    = uy(:,ny-2,:)
            uy(:,ny-1,:) = uy(:,2,:) 
            uy(:,ny,:)   = uy(:,3,:)

        end if 

        return 

    end subroutine calc_vel_horizontal_3D

    subroutine calc_vertical_shear_3D(duxdz,duydz,taub_acx,taub_acy,visc_eff,zeta_aa,boundaries)
        ! Calculate vertical shear terms (L19, Eq. 36)

        implicit none 

        real(prec), intent(OUT) :: duxdz(:,:,:)         ! [1/a],    ac-nodes horizontal, aa-nodes vertical 
        real(prec), intent(OUT) :: duydz(:,:,:)         ! [1/a],    ac-nodes horizontal, aa-nodes vertical 
        real(prec), intent(IN)  :: taub_acx(:,:)        ! [Pa],     ac-nodes
        real(prec), intent(IN)  :: taub_acy(:,:)        ! [Pa],     ac-nodes
        real(prec), intent(IN)  :: visc_eff(:,:,:)      ! [Pa a m], aa-nodes
        real(prec), intent(IN)  :: zeta_aa(:)           ! [-]
        character(len=*), intent(IN) :: boundaries 

        ! Local variables 
        integer :: i, j, k, nx, ny, nz_aa 
        integer :: ip1, jp1 
        real(prec) :: visc_eff_ac

        real(prec) :: visc_eff_ab, taub_ab 

        nx    = size(duxdz,1)
        ny    = size(duxdz,2)
        nz_aa = size(duxdz,3) 
        
        do k = 1, nz_aa 
        do j = 1, ny
        do i = 1, nx 

            ! Get staggering indices limited to grid size
            ip1 = min(i+1,nx)
            jp1 = min(j+1,ny) 

            ! Calculate shear strain, acx-nodes
            visc_eff_ac  = 0.5_prec*(visc_eff(i,j,k) + visc_eff(ip1,j,k)) 
            duxdz(i,j,k) = (taub_acx(i,j)/visc_eff_ac) * (1.0-zeta_aa(k))
            
            ! Calculate shear strain, acy-nodes
            visc_eff_ac  = 0.5_prec*(visc_eff(i,j,k) + visc_eff(i,jp1,k)) 
            duydz(i,j,k) = (taub_acy(i,j)/visc_eff_ac) * (1.0-zeta_aa(k))

!             visc_eff_ab  = 0.25*(visc_eff(i,j,k)+visc_eff(ip1,j,k)+visc_eff(i,jp1,k)+visc_eff(ip1,jp1,k))
!             taub_ab      = 0.50*(taub_acx(i,j)+taub_acx(i,jp1))
!             duxdz(i,j,k) = (taub_ab/visc_eff_ab) * (1.0-zeta_aa(k))
            
!             taub_ab      = 0.50*(taub_acy(i,j)+taub_acy(ip1,j))
!             duydz(i,j,k) = (taub_ab/visc_eff_ab) * (1.0-zeta_aa(k))

        end do 
        end do 
        end do 

        ! Apply boundary conditions as needed 
        if (trim(boundaries) .eq. "periodic") then

            duxdz(1,:,:)    = duxdz(nx-2,:,:) 
            duxdz(nx-1,:,:) = duxdz(2,:,:) 
            duxdz(nx,:,:)   = duxdz(3,:,:) 
            duxdz(:,1,:)    = duxdz(:,ny-1,:)
            duxdz(:,ny,:)   = duxdz(:,2,:) 

            duydz(1,:,:)    = duydz(nx-1,:,:) 
            duydz(nx,:,:)   = duydz(2,:,:) 
            duydz(:,1,:)    = duydz(:,ny-2,:)
            duydz(:,ny-1,:) = duydz(:,2,:) 
            duydz(:,ny,:)   = duydz(:,3,:)

        end if 

        return 

    end subroutine calc_vertical_shear_3D 

    subroutine calc_visc_eff_3D(visc_eff,ux,uy,duxdz,duydz,ATT,zeta_aa,dx,dy,n_glen,eps_0)
        ! Calculate 3D effective viscosity following L19, Eq. 2
        ! Use of eps_0 ensures non-zero positive viscosity value everywhere 
        ! Note: viscosity is first calculated on ab-nodes, then 
        ! unstaggered back to aa-nodes. This ensures more stability for 
        ! visc_eff (less likely to blow up for low strain rates). 

        implicit none 
        
        real(prec), intent(OUT) :: visc_eff(:,:,:)      ! aa-nodes
        real(prec), intent(IN)  :: ux(:,:)              ! [m/a] Vertically averaged horizontal velocity, x-component
        real(prec), intent(IN)  :: uy(:,:)              ! [m/a] Vertically averaged horizontal velocity, y-component
        real(prec), intent(IN)  :: duxdz(:,:,:)         ! [1/a] Vertical shearing, x-component
        real(prec), intent(IN)  :: duydz(:,:,:)         ! [1/a] Vertical shearing, x-component
        real(prec), intent(IN)  :: ATT(:,:,:)           ! aa-nodes
        real(prec), intent(IN)  :: zeta_aa(:)           ! Vertical axis (sigma-coordinates from 0 to 1)
        real(prec), intent(IN)  :: dx
        real(prec), intent(IN)  :: dy
        real(prec), intent(IN)  :: n_glen   
        real(prec), intent(IN)  :: eps_0                ! [1/a] Regularization constant (minimum strain rate, ~1e-8)
        
        ! Local variables 
        integer    :: i, j, k, nx, ny, nz
        integer    :: ip1, jp1, im1, jm1  
        real(prec) :: inv_4dx, inv_4dy 
        real(prec) :: dudx, dudy
        real(prec) :: dvdx, dvdy 
        real(prec) :: duxdz_ab, duydz_ab  
        real(prec) :: p1, p2, eps_0_sq  
        real(prec) :: eps_sq                            ! [1/a^2]
        real(prec) :: ATT_ab 
        real(prec), allocatable :: visc_eff_ab(:,:,:)  
        
        nx = size(visc_eff,1)
        ny = size(visc_eff,2)
        nz = size(visc_eff,3)
        
        ! Allocate local arrays 
        allocate(visc_eff_ab(nx,ny,nz))

        ! Calculate scaling factors
        inv_4dx = 1.0_prec / (4.0_prec*dx) 
        inv_4dy = 1.0_prec / (4.0_prec*dy) 

        ! Calculate exponents 
        p1 = (1.0_prec - n_glen)/(2.0_prec*n_glen)
        p2 = -1.0_prec/n_glen

        ! Calculate squared minimum strain rate 
        eps_0_sq = eps_0*eps_0 

        do j = 1, ny 
        do i = 1, nx 

            im1 = max(i-1,1) 
            ip1 = min(i+1,nx) 
            jm1 = max(j-1,1) 
            jp1 = min(j+1,ny) 

            ! Calculate effective strain components from horizontal stretching on ab-nodes
            dudx = ( (ux(ip1,j) - ux(im1,j)) + (ux(ip1,jp1) - ux(im1,jp1)) ) *inv_4dx
            dvdy = ( (uy(i,jp1) - uy(i,jm1)) + (uy(ip1,jp1) - uy(ip1,jm1)) ) *inv_4dy 

            ! Calculate of cross terms on ab-nodes
            dudy = (ux(i,jp1) - ux(i,j)) / dx 
            dvdx = (uy(ip1,j) - uy(i,j)) / dy 

            ! Loop over column
            do k = 1, nz 

                ! Un-stagger shear terms to central aa-nodes in horizontal
                duxdz_ab = 0.5_prec*(duxdz(i,j,k) + duxdz(i,jp1,k))
                duydz_ab = 0.5_prec*(duydz(i,j,k) + duydz(ip1,j,k))
                
                ! Calculate the total effective strain rate from L19, Eq. 21 
                eps_sq = dudx**2 + dvdy**2 + dudx*dvdy + 0.25_prec*(dudy+dvdx)**2 &
                       + 0.25_prec*duxdz_ab**2 + 0.25_prec*duydz_ab**2 + eps_0_sq
                
                ATT_ab = 0.25*(ATT(i,j,k)+ATT(im1,j,k)+ATT(i,jm1,k)+ATT(im1,jm1,k)) 
                
                ! Calculate effective viscosity on ab-nodes
                visc_eff_ab(i,j,k) = 0.5_prec*(eps_sq)**(p1) * ATT_ab**(p2)

            end do 

        end do  
        end do 

        ! Unstagger from ab-nodes to aa-nodes 
        do j = 1, ny 
        do i = 1, nx 

            im1 = max(i-1,1) 
            ip1 = min(i+1,nx) 
            jm1 = max(j-1,1) 
            jp1 = min(j+1,ny) 

            ! Loop over column
            do k = 1, nz 
                visc_eff(i,j,k) = 0.25*(visc_eff_ab(i,j,k)+visc_eff_ab(im1,j,k) &
                                        +visc_eff_ab(i,jm1,k)+visc_eff_ab(im1,jm1,k))
            end do 

        end do 
        end do 
        
        ! Treat the corners to avoid extremes
        visc_eff(1,1,:) = 0.5*(visc_eff(2,1,:)+visc_eff(1,2,:))
        visc_eff(1,ny,:) = 0.5*(visc_eff(2,ny,:)+visc_eff(1,ny-1,:))
        visc_eff(nx,1,:) = 0.5*(visc_eff(nx,2,:)+visc_eff(nx-1,1,:))
        visc_eff(nx,ny,:) = 0.5*(visc_eff(nx-1,ny,:)+visc_eff(nx,ny-1,:))

        return 

    end subroutine calc_visc_eff_3D 

    subroutine calc_F_integral(F_int,visc,H_ice,zeta_aa,n)
        ! Useful integrals, following Arthern et al. (2015) Eq. 7,
        ! and Lipscomb et al. (2019), Eq. 30
        ! F_n = int_zb_zs{ 1/visc * ((s-z)/H)**n dz}

        implicit none 

        real(prec), intent(OUT) :: F_int(:,:) 
        real(prec), intent(IN)  :: visc(:,:,:)
        real(prec), intent(IN)  :: H_ice(:,:)
        real(prec), intent(IN)  :: zeta_aa(:)
        real(prec), intent(IN)  :: n  

        ! Local variables 
        integer :: i, j, nx, ny, nz_aa, np
        integer :: im1, jm1, ip1, jp1 
        real(prec) :: F_int_min 
        real(prec), parameter :: visc_min = 1e3_prec

        nx    = size(visc,1)
        ny    = size(visc,2) 
        nz_aa = size(visc,3)

        ! Determine the minimum value of F_int, to assign when H_ice == 0,
        ! since F_int should be nonzero everywhere for numerics
        F_int_min = integrate_trapezoid1D_pt((1.0_prec/visc_min)*(1.0_prec-zeta_aa)**n,zeta_aa)

        ! Initially set F_int to minimum value everywhere 
        F_int = F_int_min

        ! Vertically integrate at each point
        do j = 1, ny 
        do i = 1, nx

            im1 = max(i-1,1)
            jm1 = max(j-1,1)
            ip1 = min(i+1,nx)
            jp1 = min(j+1,ny)

            if (H_ice(i,j) .gt. 0.0_prec) then 
                ! Viscosity should be nonzero here, perform integration 

                F_int(i,j) = integrate_trapezoid1D_pt((H_ice(i,j)/visc(i,j,:) )*(1.0_prec-zeta_aa)**n,zeta_aa)

            else 

                F_int(i,j) = F_int_min

            end if 

        end do 
        end do 

        return

    end subroutine calc_F_integral
    
    subroutine calc_beta_eff(beta_eff,beta,ux_b,uy_b,F2,zeta_aa,no_slip)
        ! Calculate the depth-averaged horizontal velocity (ux_bar,uy_bar)

        ! Note: L19 staggers the F-integral F2, then solves for beta 

        implicit none 
        
        real(prec), intent(OUT) :: beta_eff(:,:)    ! aa-nodes
        real(prec), intent(IN)  :: beta(:,:)        ! aa-nodes
        real(prec), intent(IN)  :: ux_b(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: uy_b(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: F2(:,:)          ! aa-nodes
        real(prec), intent(IN)  :: zeta_aa(:)       ! aa-nodes
        logical,    intent(IN)  :: no_slip 

        ! Local variables 
        integer    :: i, j, nx, ny

        nx = size(beta_eff,1)
        ny = size(beta_eff,2)

        if (no_slip) then 
            ! No basal sliding allowed, impose beta_eff derived from viscosity 
            ! following L19, Eq. 35 (or G11, Eq. 42)

            beta_eff = 1.0_prec / F2 

        else 
            ! Basal sliding allowed, calculate beta_eff 
            ! following L19, Eq. 33 (or G11, Eq. 41)

            beta_eff = beta / (1.0_prec+beta*F2)

        end if 

        return 

    end subroutine calc_beta_eff 

    subroutine calc_beta_eff_ac(beta_eff_acx,beta_eff_acy,beta_acx,beta_acy,ux_b,uy_b,F2,H_ice,zeta_aa,no_slip,boundaries)
        ! Calculate the depth-averaged horizontal velocity (ux_bar,uy_bar)

        ! Note: L19 staggers the F-integral F2, then solves for beta 

        implicit none 
        
        real(prec), intent(OUT) :: beta_eff_acx(:,:)    ! ac-nodes
        real(prec), intent(OUT) :: beta_eff_acy(:,:)    ! ac-nodes
        real(prec), intent(IN)  :: beta_acx(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: beta_acy(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: ux_b(:,:)            ! ac-nodes
        real(prec), intent(IN)  :: uy_b(:,:)            ! ac-nodes
        real(prec), intent(IN)  :: F2(:,:)              ! aa-nodes
        real(prec), intent(IN)  :: H_ice(:,:)           ! aa-nodes
        real(prec), intent(IN)  :: zeta_aa(:)           ! aa-nodes
        logical,    intent(IN)  :: no_slip 
        character(len=*), intent(IN) :: boundaries  

        ! Local variables 
        integer    :: i, j, nx, ny
        integer    :: ip1, jp1   
        real(prec) :: F2_ac 

        nx = size(beta_eff_acx,1)
        ny = size(beta_eff_acx,2)

        do j = 1, ny 
        do i = 1, nx 

            ip1 = min(i+1,nx)
            jp1 = min(j+1,ny)

            ! === x-direction =====

            ! Stagger the F2 integral to the ac-nodes
            if (H_ice(i,j) .gt. 0.0 .and. H_ice(ip1,j) .eq. 0.0) then 
                F2_ac = F2(i,j) 
            else if (H_ice(i,j) .eq. 0.0 .and. H_ice(ip1,j) .gt. 0.0) then
                F2_ac = F2(ip1,j)
            else 
                F2_ac = 0.5_prec*(F2(i,j) + F2(ip1,j))
            end if 


            if (no_slip) then 
                ! No basal sliding allowed, impose beta_eff derived from viscosity 
                ! following L19, Eq. 35 (or G11, Eq. 42)

                beta_eff_acx(i,j) = 1.0_prec / F2_ac 

            else 
                ! Basal sliding allowed, calculate beta_eff 
                ! following L19, Eq. 33 (or G11, Eq. 41)

                beta_eff_acx(i,j) = beta_acx(i,j) / (1.0_prec+beta_acx(i,j)*F2_ac)

            end if 

            ! === y-direction =====

            ! Stagger the F2 integral to the ac-nodes
            if (H_ice(i,j) .gt. 0.0 .and. H_ice(i,jp1) .eq. 0.0) then 
                F2_ac = F2(i,j) 
            else if (H_ice(i,j) .eq. 0.0 .and. H_ice(i,jp1) .gt. 0.0) then
                F2_ac = F2(i,jp1)
            else 
                F2_ac = 0.5_prec*(F2(i,j) + F2(i,jp1))
            end if 


            if (no_slip) then 
                ! No basal sliding allowed, impose beta_eff derived from viscosity 
                ! following L19, Eq. 35 (or G11, Eq. 42)

                beta_eff_acy(i,j) = 1.0_prec / F2_ac 

            else 
                ! Basal sliding allowed, calculate beta_eff 
                ! following L19, Eq. 33 (or G11, Eq. 41)

                beta_eff_acy(i,j) = beta_acy(i,j) / (1.0_prec+beta_acy(i,j)*F2_ac)

            end if 

        end do 
        end do  

        ! Apply boundary conditions as needed 
        if (trim(boundaries) .eq. "periodic") then 

            beta_eff_acx(1,:)    = beta_eff_acx(nx-2,:) 
            beta_eff_acx(nx-1,:) = beta_eff_acx(2,:) 
            beta_eff_acx(nx,:)   = beta_eff_acx(3,:) 
            beta_eff_acx(:,1)    = beta_eff_acx(:,ny-1)
            beta_eff_acx(:,ny)   = beta_eff_acx(:,2) 
            
            beta_eff_acy(1,:)    = beta_eff_acy(nx-1,:) 
            beta_eff_acy(nx,:)   = beta_eff_acy(2,:) 
            beta_eff_acy(:,1)    = beta_eff_acy(:,ny-2)
            beta_eff_acy(:,ny-1) = beta_eff_acy(:,2) 
            beta_eff_acy(:,ny)   = beta_eff_acy(:,3)

        end if 

        return 

    end subroutine calc_beta_eff_ac 

    subroutine calc_vel_basal(ux_b,uy_b,ux_bar,uy_bar,F2,taub_acx,taub_acy,H_ice,boundaries)
        ! Calculate basal sliding following Goldberg (2011), Eq. 34
        ! (or it can also be obtained from L19, Eq. 32 given ub*beta=taub)

        implicit none
        
        real(prec), intent(OUT) :: ux_b(:,:) 
        real(prec), intent(OUT) :: uy_b(:,:)
        real(prec), intent(IN)  :: ux_bar(:,:) 
        real(prec), intent(IN)  :: uy_bar(:,:)
        real(prec), intent(IN)  :: F2(:,:)
        real(prec), intent(IN)  :: taub_acx(:,:) 
        real(prec), intent(IN)  :: taub_acy(:,:)
        real(prec), intent(IN)  :: H_ice(:,:)
        character(len=*), intent(IN) :: boundaries 

        ! Local variables 
        integer    :: i, j, nx, ny 
        integer    :: ip1, jp1 
        real(prec) :: F2_ac 

        nx = size(ux_b,1)
        ny = size(ux_b,2) 

        do j = 1, ny 
        do i = 1, nx 

            ip1 = min(i+1,nx)
            jp1 = min(j+1,ny)

            ! ==== x-direction =====

            ! Stagger the F2 integral to the ac-nodes
            if (H_ice(i,j) .gt. 0.0 .and. H_ice(ip1,j) .eq. 0.0) then 
                F2_ac = F2(i,j) 
            else if (H_ice(i,j) .eq. 0.0 .and. H_ice(ip1,j) .gt. 0.0) then
                F2_ac = F2(ip1,j)
            else 
                F2_ac = 0.5_prec*(F2(i,j) + F2(ip1,j))
            end if 

            ! Calculate basal velocity component 
            ux_b(i,j) = ux_bar(i,j) - taub_acx(i,j)*F2_ac 

            ! ==== y-direction =====
            
            ! Stagger the F2 integral to the ac-nodes
            if (H_ice(i,j) .gt. 0.0 .and. H_ice(i,jp1) .eq. 0.0) then 
                F2_ac = F2(i,j) 
            else if (H_ice(i,j) .eq. 0.0 .and. H_ice(i,jp1) .gt. 0.0) then
                F2_ac = F2(i,jp1)
            else 
                F2_ac = 0.5_prec*(F2(i,j) + F2(i,jp1))
            end if 
                
            ! Calculate basal velocity component 
            uy_b(i,j) = uy_bar(i,j) - taub_acy(i,j)*F2_ac 

        end do 
        end do  

        ! Apply boundary conditions as needed 
        if (trim(boundaries) .eq. "periodic") then 

            ux_b(1,:)    = ux_b(nx-2,:) 
            ux_b(nx-1,:) = ux_b(2,:) 
            ux_b(nx,:)   = ux_b(3,:) 
            ux_b(:,1)    = ux_b(:,ny-1)
            ux_b(:,ny)   = ux_b(:,2) 
            
            uy_b(1,:)    = uy_b(nx-1,:) 
            uy_b(nx,:)   = uy_b(2,:) 
            uy_b(:,1)    = uy_b(:,ny-2)
            uy_b(:,ny-1) = uy_b(:,2) 
            uy_b(:,ny)   = uy_b(:,3)

        end if 

        return
        
    end subroutine calc_vel_basal

    subroutine calc_vel_basal_ab(ux_b,uy_b,ux_bar,uy_bar,F2,taub_acx,taub_acy,H_ice,boundaries)
        ! Calculate basal sliding following Goldberg (2011), Eq. 34
        ! (or it can also be obtained from L19, Eq. 32 given ub*beta=taub)

        implicit none
        
        real(prec), intent(OUT) :: ux_b(:,:) 
        real(prec), intent(OUT) :: uy_b(:,:)
        real(prec), intent(IN)  :: ux_bar(:,:) 
        real(prec), intent(IN)  :: uy_bar(:,:)
        real(prec), intent(IN)  :: F2(:,:)
        real(prec), intent(IN)  :: taub_acx(:,:) 
        real(prec), intent(IN)  :: taub_acy(:,:)
        real(prec), intent(IN)  :: H_ice(:,:)
        character(len=*), intent(IN) :: boundaries 

        ! Local variables 
        integer    :: i, j, nx, ny, k  
        integer    :: ip1, jp1, im1, jm1  
        real(prec) :: F2_ac 
        real(prec), allocatable :: F2_ab(:,:) 

        nx = size(ux_b,1)
        ny = size(ux_b,2) 

        allocate(F2_ab(nx,ny))

        ! Stagger F2 to ab-nodes 
        do j = 1, ny 
        do i = 1, nx 

            ip1 = min(i,nx)
            jp1 = min(j,ny)

            k = 0 

            if (H_ice(i,j) .gt. 0.0) then 
                F2_ab(i,j) = F2_ab(i,j) + F2(i,j) 
                k = k + 1 
            end if 

            if (H_ice(ip1,j) .gt. 0.0) then 
                F2_ab(i,j) = F2_ab(i,j) + F2(ip1,j) 
                k = k + 1 
            end if 
            
            if (H_ice(i,jp1) .gt. 0.0) then 
                F2_ab(i,j) = F2_ab(i,j) + F2(i,jp1) 
                k = k + 1 
            end if 
            
            if (H_ice(ip1,jp1) .gt. 0.0) then 
                F2_ab(i,j) = F2_ab(i,j) + F2(ip1,jp1) 
                k = k + 1 
            end if 
            
            if (k .gt. 0) then 
                F2_ab(i,j) = F2_ab(i,j) / real(k,prec) 
            else 
                F2_ab = 0.25*(F2(i,j)+F2(ip1,j)+F2(i,jp1)+F2(ip1,jp1))
            end if 

        end do 
        end do 

        do j = 1, ny 
        do i = 1, nx 

            ip1 = min(i+1,nx)
            jp1 = min(j+1,ny)
            im1 = max(i-1,1)
            jm1 = max(j-1,1)

            ! ==== x-direction =====

            ! Stagger the F2_ab integral to the ac-nodes
            if (H_ice(i,j) .gt. 0.0 .and. H_ice(im1,j) .eq. 0.0) then 
                F2_ac = F2(i,j) 
            else if (H_ice(i,j) .eq. 0.0 .and. H_ice(ip1,j) .gt. 0.0) then
                F2_ac = F2(ip1,j)
            else 
                F2_ac = 0.5_prec*(F2(i,j) + F2(ip1,j))
            end if 

            ! Calculate basal velocity component 
            ux_b(i,j) = ux_bar(i,j) - taub_acx(i,j)*F2_ac 

            ! ==== y-direction =====
            
            ! Stagger the F2 integral to the ac-nodes
            if (H_ice(i,j) .gt. 0.0 .and. H_ice(i,jp1) .eq. 0.0) then 
                F2_ac = F2(i,j) 
            else if (H_ice(i,j) .eq. 0.0 .and. H_ice(i,jp1) .gt. 0.0) then
                F2_ac = F2(i,jp1)
            else 
                F2_ac = 0.5_prec*(F2(i,j) + F2(i,jp1))
            end if 
                
            ! Calculate basal velocity component 
            uy_b(i,j) = uy_bar(i,j) - taub_acy(i,j)*F2_ac 

        end do 
        end do  

        ! Apply boundary conditions as needed 
        if (trim(boundaries) .eq. "periodic") then 

            ux_b(1,:)    = ux_b(nx-2,:) 
            ux_b(nx-1,:) = ux_b(2,:) 
            ux_b(nx,:)   = ux_b(3,:) 
            ux_b(:,1)    = ux_b(:,ny-1)
            ux_b(:,ny)   = ux_b(:,2) 
            
            uy_b(1,:)    = uy_b(nx-1,:) 
            uy_b(nx,:)   = uy_b(2,:) 
            uy_b(:,1)    = uy_b(:,ny-2)
            uy_b(:,ny-1) = uy_b(:,2) 
            uy_b(:,ny)   = uy_b(:,3)

        end if 

        return
        
    end subroutine calc_vel_basal_ab
    
    subroutine calc_basal_stress(taub_acx,taub_acy,beta_eff_acx,beta_eff_acy,ux_bar,uy_bar)
        ! Calculate the basal stress resulting from sliding (friction times velocity)
        ! Note: calculated on ac-nodes.
        ! taub [Pa] 
        ! beta [Pa a m-1]
        ! u    [m a-1]
        ! taub = beta*u (here defined with taub in the same direction as u)

        implicit none 

        real(prec), intent(OUT) :: taub_acx(:,:)        ! [Pa] Basal stress (acx nodes)
        real(prec), intent(OUT) :: taub_acy(:,:)        ! [Pa] Basal stress (acy nodes)
        real(prec), intent(IN)  :: beta_eff_acx(:,:)    ! [Pa a m-1] Effective basal friction (acx nodes)
        real(prec), intent(IN)  :: beta_eff_acy(:,:)    ! [Pa a m-1] Effective basal friction (acy nodes)
        real(prec), intent(IN)  :: ux_bar(:,:)          ! [m a-1] depth-ave velocity (acx nodes)
        real(prec), intent(IN)  :: uy_bar(:,:)          ! [m a-1] depth-ave velocity (acy nodes)
        
        ! Local variables 
        integer :: i, j, nx, ny 

        nx = size(taub_acx,1)
        ny = size(taub_acy,2) 

        do j = 1, ny 
        do i = 1, nx 

            taub_acx(i,j) = beta_eff_acx(i,j) * ux_bar(i,j) 
            taub_acy(i,j) = beta_eff_acy(i,j) * uy_bar(i,j) 

        end do 
        end do  

        return 

    end subroutine calc_basal_stress

    subroutine diagnose_beta_diva(beta_diva,beta_eff,F2,beta)
        ! Given beta_eff and F2, iteratively solve for beta_diva,
        ! where: beta_eff = beta_diva / (1+beta_diva*F2)
        ! Use root-finding method: 0 = beta_eff - beta_diva / (1+beta_diva*F2)

        implicit none 

        real(prec), intent(OUT) :: beta_diva(:,:)       ! [Pa a/m] beta seen by diva solver (derived from beta_eff)
        real(prec), intent(IN)  :: beta_eff(:,:)        ! [Pa a/m] Effective beta used directly in diva solver
        real(prec), intent(IN)  :: beta(:,:)            ! [Pa a/m] Prescribed beta for points with ux/y_b > 0
        real(prec), intent(IN)  :: F2(:,:)              ! [(Pa a)^-1]

        ! To do !!!

        ! For now, simply:
        beta_diva = beta 

        return

    contains 

        function f(beta_diva,beta_eff,F2) result(fout)

            implicit none 

            real(prec), intent(IN) :: beta_diva 
            real(prec), intent(IN) :: beta_eff
            real(prec), intent(IN) :: F2
            real(prec) :: fout 

            fout = beta_eff - beta_diva*(1.0_prec + beta_diva*F2)**(-1.0)

            return 

        end function f
            
        function fp(beta_diva,beta_eff,F2) result(fpout)

            implicit none 

            real(prec), intent(IN) :: beta_diva 
            real(prec), intent(IN) :: beta_eff
            real(prec), intent(IN) :: F2
            real(prec) :: fpout 
            
            fpout = beta_diva*F2*(1.0_prec + beta_diva*F2)**(-2.0) - (1.0_prec + beta_diva*F2)**(-1.0)

            return 

        end function fp

    end subroutine diagnose_beta_diva

    subroutine solve_newton(x,x0,f,fp,debug)
        ! Estimate the zero of f(x) using Newton's method. 
        ! Input:
        !   f:  the function to find a root of
        !   fp: function returning the derivative f'
        !   x0: the initial guess
        !   debug: logical, prints iterations if debug=.true.
        ! Returns:
        !   the estimate x satisfying f(x)=0 (assumes Newton converged!) 
        !   the number of iterations iters
        
        ! Adapted from: 
        ! https://faculty.washington.edu/rjl/classes/am583s2013/notes/fortran_newton.html

        implicit none

        real(prec), intent(OUT) :: x
        real(prec), intent(IN)  :: x0
        real(prec), external    :: f, fp
        logical,    intent(in)  :: debug

        ! Declare any local variables:
        real(prec) :: deltax, fx, fxprime
        integer    :: k, iters

        integer, parameter :: maxiter = 20
        real(kind=8), parameter :: tol = 1.d-14

        ! Save initial guess
        x = x0

        if (debug) then
            write(*,*) "Initial guess: x = ", x
        end if

        ! Newton iteration to find a zero of f(x) 

        do k = 1, maxiter

            ! evaluate function and its derivative:
            fx      = f(x)
            fxprime = fp(x)

            if (abs(fx) < tol) then
                exit  ! jump out of do loop
            end if

            ! Compute Newton increment x:
            deltax = fx/fxprime

            ! update x:
            x = x - deltax

            if (debug) then
                write(*,*) "After ", k, "iterations, x = ", x 
            end if 

        end do


        if (k > maxiter) then
        ! Solver did not converge

            fx = f(x)
            if (abs(fx) > tol) then
                write(*,*) "*** Warning: has not yet converged"
            end if

        end if 

        ! Number of iterations taken:
        iters = k-1

        return 

    end subroutine solve_newton

    elemental subroutine limit_vel(u,u_lim)
        ! Apply a velocity limit (for stability)

        implicit none 

        real(prec), intent(INOUT) :: u 
        real(prec), intent(IN)    :: u_lim

        real(prec), parameter :: tol = 1e-10
        
        u = min(u, u_lim)
        u = max(u,-u_lim)

        ! Also avoid underflow errors 
        if (abs(u) .lt. tol) u = 0.0 

        return 

    end subroutine limit_vel
    
end module velocity_diva
