module velocity_diva

    use yelmo_defs ,only  : prec, rho_ice, rho_sw, rho_w, g
    use yelmo_tools, only : stagger_aa_ab, stagger_aa_ab_ice, &
                    calc_vertical_integrated_2D, & 
                    integrate_trapezoid1D_1D, integrate_trapezoid1D_pt, minmax

    use basal_dragging 
    use solver_ssa_sico5 

    implicit none 

    type diva_param_class

        character(len=256) :: ssa_solver_opt 
        character(len=256) :: boundaries 
        integer    :: beta_method
        real(prec) :: beta_const
        real(prec) :: beta_q                ! Friction law exponent
        real(prec) :: beta_u0               ! [m/a] Friction law velocity threshold 
        integer    :: beta_gl_scale         ! Beta grounding-line scaling method (beta => 0 at gl?)
        integer    :: beta_gl_stag          ! Beta grounding-line staggering method 
        real(prec) :: beta_gl_f             ! Fraction of beta at gl 
        real(prec) :: H_grnd_lim 
        real(prec) :: beta_min              ! Minimum allowed value of beta
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
                                  visc_eff,visc_eff_bar,ssa_mask_acx,ssa_mask_acy,ssa_err_acx,ssa_err_acy, &
                                  beta,beta_acx,beta_acy,c_bed,taud_acx,taud_acy,H_ice,H_grnd,f_grnd, &
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
        real(prec), intent(INOUT) :: visc_eff(:,:,:)    ! [Pa a m]
        real(prec), intent(OUT)   :: visc_eff_bar(:,:)  ! [Pa a m]
        integer,    intent(OUT)   :: ssa_mask_acx(:,:)  ! [-]
        integer,    intent(OUT)   :: ssa_mask_acy(:,:)  ! [-]
        real(prec), intent(OUT)   :: ssa_err_acx(:,:)
        real(prec), intent(OUT)   :: ssa_err_acy(:,:)
        real(prec), intent(OUT)   :: beta(:,:)          ! [Pa a/m]
        real(prec), intent(OUT)   :: beta_acx(:,:)      ! [Pa a/m]
        real(prec), intent(OUT)   :: beta_acy(:,:)      ! [Pa a/m]
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
        integer :: k, nx, ny, nz_aa, nz_ac
        integer :: iter, iter_max  
        logical :: is_converged 
        real(prec), allocatable :: ux_bar_nm1(:,:) 
        real(prec), allocatable :: uy_bar_nm1(:,:) 
        real(prec), allocatable :: beta_eff(:,:) 
        real(prec), allocatable :: beta_eff_acx(:,:)
        real(prec), allocatable :: beta_eff_acy(:,:)  
        real(prec), allocatable :: eps_sq(:,:,:)  
        real(prec), allocatable :: F2(:,:) 

        integer,    allocatable :: ssa_mask_acx_ref(:,:)
        integer,    allocatable :: ssa_mask_acy_ref(:,:)

        nx    = size(ux,1)
        ny    = size(ux,2)
        nz_aa = size(ux,3)

        iter_max = 2 

        ! Prepare local variables 
        allocate(ux_bar_nm1(nx,ny))
        allocate(uy_bar_nm1(nx,ny))
        allocate(beta_eff(nx,ny))
        allocate(beta_eff_acx(nx,ny))
        allocate(beta_eff_acy(nx,ny))
        allocate(eps_sq(nx,ny,nz_aa))
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
            ! Step 1: Calculate fields needed by ssa solver (visc_eff_bar, beta_eff)

            ! Calculate the 3D vertical shear fields using viscosity estimated from the previous iteration 
            call calc_vertical_shear_3D(duxdz,duydz,taub_acx,taub_acy,visc_eff,zeta_aa)

            ! Calculate the effective strain rate using velocity solution from previous iteration
            call calc_strain_eff_squared(eps_sq,ux_bar,uy_bar,duxdz,duydz,zeta_aa,dx,dy)

            ! Calculate 3D effective viscosity and its vertical average 
            call calc_visc_eff_3D(visc_eff,ATT,eps_sq,n_glen)

            ! Note L19 uses eta_bar*H in the ssa equation. Yelmo uses eta_int right now,
            ! so this naming should be cleaned up (ie visc_eff_bar => visc_eff_int).
            visc_eff_bar = calc_vertical_integrated_2D(visc_eff,zeta_aa) 
            where(H_ice .gt. 0.0_prec) visc_eff_bar = visc_eff_bar*H_ice 

            ! Calculate beta (at the ice base)
            call calc_beta(beta,c_bed,ux_b,uy_b,H_ice,H_grnd,f_grnd,z_bed,z_sl,par%beta_method, &
                                par%beta_const,par%beta_q,par%beta_u0,par%beta_gl_scale,par%beta_gl_f, &
                                par%H_grnd_lim,par%beta_min,par%boundaries)

            ! Calculate F-integeral (F2) on aa-nodes 
            call calc_F_integral(F2,visc_eff,H_ice,zeta_aa,n=2.0_prec)
            
            ! Calculate effective beta 
            !call calc_beta_eff(beta_eff,beta,ux_b,uy_b,F2,zeta_aa)
            beta_eff = beta 

            ! Stagger beta_eff 
            call stagger_beta(beta_eff_acx,beta_eff_acy,beta_eff,f_grnd,f_grnd_acx,f_grnd_acy,par%beta_gl_stag)

            write(*,*) "diva:: beta:         ", minval(beta),     maxval(beta)
            write(*,*) "diva:: beta_eff:     ", minval(beta_eff), maxval(beta_eff)
            write(*,*) "diva:: F2:           ", minval(F2),       maxval(F2)
            
            ! =========================================================================================
            ! Step 2: Call the SSA solver to obtain new estimate of ux_bar/uy_bar

if (.FALSE.) then 
            if (iter .gt. 1) then
                ! Update ssa mask based on convergence with previous step to reduce calls 
                call update_ssa_mask_convergence(ssa_mask_acx,ssa_mask_acy,ssa_err_acx,ssa_err_acy,err_lim=real(1e-3,prec)) 
            end if 
end if 

            call calc_vxy_ssa_matrix(ux_bar,uy_bar,beta_eff_acx,beta_eff_acy,visc_eff_bar,ssa_mask_acx,ssa_mask_acy,H_ice, &
                                taud_acx,taud_acy,H_grnd,z_sl,z_bed,dx,dy,par%ssa_vel_max,par%boundaries,par%ssa_solver_opt)


            ! Apply relaxation to keep things stable
            call relax_ssa(ux_bar,uy_bar,ux_bar_nm1,uy_bar_nm1,rel=par%ssa_iter_rel)
            
            ! Check for convergence
            is_converged = check_vel_convergence_l2rel(ux_bar,uy_bar,ux_bar_nm1,uy_bar_nm1, &
                                            ssa_mask_acx.gt.0.0_prec,ssa_mask_acy.gt.0.0_prec, &
                                            par%ssa_iter_conv,iter,par%ssa_iter_max,par%ssa_write_log)

            ! Calculate an L1 error metric over matrix for diagnostics
            call check_vel_convergence_l1rel_matrix(ssa_err_acx,ssa_err_acy,ux_bar,uy_bar,ux_bar_nm1,uy_bar_nm1)

            
            ! =========================================================================================
            ! Update additional fields based on output of solver
            
            ! Calculate basal velocity from depth-averaged solution 
            call calc_vel_basal(ux_b,uy_b,ux_bar,uy_bar,F2,beta_acx,beta_acy)
            !ux_b = ux_bar 
            !uy_b = uy_bar 

            ! Calculate basal stress 
            call calc_basal_stress(taub_acx,taub_acy,beta_acx,beta_acy,ux_b,uy_b)

            ! Exit iterations if ssa solution has converged
            if (is_converged) exit 
            
        end do 

        ! Iterations are finished, finalize calculations of 3D velocity field 

        ! Calculate the 3D horizontal velocity field
        call calc_vel_horizontal_3D(ux,uy,ux_b,uy_b,beta_acx,beta_acy,visc_eff,zeta_aa)

        ! Also calculate the shearing contribution
        do k = 1, nz_aa 
            ux_i(:,:,k) = ux(:,:,k) - ux_b 
            uy_i(:,:,k) = uy(:,:,k) - uy_b 
        end do

        return 

    end subroutine calc_velocity_diva 

    subroutine calc_vel_horizontal_3D(ux,uy,ux_b,uy_b,beta_acx,beta_acy,visc_eff,zeta_aa)
        ! Caluculate the 3D horizontal velocity field (ux,uy)
        ! following L19, Eq. 29 

        implicit none 

        real(prec), intent(OUT) :: ux(:,:,:) 
        real(prec), intent(OUT) :: uy(:,:,:) 
        real(prec), intent(IN)  :: ux_b(:,:) 
        real(prec), intent(IN)  :: uy_b(:,:) 
        real(prec), intent(IN)  :: beta_acx(:,:) 
        real(prec), intent(IN)  :: beta_acy(:,:) 
        real(prec), intent(IN)  :: visc_eff(:,:,:)       
        real(prec), intent(IN)  :: zeta_aa(:) 

        ! Local variables
        integer :: i, j, k, ip1, jp1, nx, ny, nz_aa  
        real(prec) :: tmpval_ac 
        real(prec), allocatable :: visc_eff_ac(:) 
        real(prec), allocatable :: tmpcol_ac(:) 
        
        nx    = size(ux,1)
        ny    = size(ux,2) 
        nz_aa = size(ux,3) 

        allocate(visc_eff_ac(nz_aa))
        allocate(tmpcol_ac(nz_aa))

        do j = 1, ny 
        do i = 1, nx 

            ip1 = min(i+1,nx)
            jp1 = min(j+1,ny) 

            ! === x direction ===============================================

            ! Stagger viscosity column to ac-nodes 
            visc_eff_ac = 0.5_prec*(visc_eff(i,j,:)+visc_eff(ip1,j,:))

            ! Calculate integrated term of L19, Eq. 29 
            tmpcol_ac = integrate_trapezoid1D_1D((1.0_prec/visc_eff_ac)*(1.0-zeta_aa),zeta_aa)

            ! Calculate velocity column 
            ux(i,j,:) = ux_b(i,j) + (beta_acx(i,j)*ux_b(i,j))*tmpcol_ac 

            ! === y direction ===============================================

            ! Stagger viscosity column to ac-nodes 
            visc_eff_ac = 0.5_prec*(visc_eff(i,j,:)+visc_eff(i,jp1,:))

            ! Calculate integrated term of L19, Eq. 29 
            tmpcol_ac = integrate_trapezoid1D_1D((1.0_prec/visc_eff_ac)*(1.0-zeta_aa),zeta_aa)

            ! Calculate velocity column 
            uy(i,j,:) = uy_b(i,j) + (beta_acy(i,j)*uy_b(i,j))*tmpcol_ac 

        end do 
        end do  

        return 

    end subroutine calc_vel_horizontal_3D

    subroutine calc_vertical_shear_3D(duxdz,duydz,taub_acx,taub_acy,visc_eff,zeta_aa)
        ! Calculate vertical shear terms (L19, Eq. 36)

        implicit none 

        real(prec), intent(OUT) :: duxdz(:,:,:)         ! [1/a],    ac-nodes horizontal, aa-nodes vertical 
        real(prec), intent(OUT) :: duydz(:,:,:)         ! [1/a],    ac-nodes horizontal, aa-nodes vertical 
        real(prec), intent(IN)  :: taub_acx(:,:)        ! [Pa],     ac-nodes
        real(prec), intent(IN)  :: taub_acy(:,:)        ! [Pa],     ac-nodes
        real(prec), intent(IN)  :: visc_eff(:,:,:)      ! [Pa a m], aa-nodes
        real(prec), intent(IN)  :: zeta_aa(:)           ! [-]
        
        ! Local variables 
        integer :: i, j, k, nx, ny, nz_aa 
        integer :: ip1, jp1 
        real(prec) :: visc_eff_ac

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

        end do 
        end do 
        end do 

        return 

    end subroutine calc_vertical_shear_3D 

    subroutine calc_strain_eff_squared(eps_sq,ux,uy,duxdz,duydz,zeta_aa,dx,dy)
        ! Calculate effective strain rate for DIVA solver, using 3D vertical shear 
        ! and 2D depth-averaged horizontal shear (L19, Eq. 21)

        implicit none 
        
        real(prec), intent(OUT) :: eps_sq(:,:,:)        ! [1/a]^2
        real(prec), intent(IN) :: ux(:,:)               ! [m/a] Vertically averaged horizontal velocity, x-component
        real(prec), intent(IN) :: uy(:,:)               ! [m/a] Vertically averaged horizontal velocity, y-component
        real(prec), intent(IN) :: duxdz(:,:,:)          ! [1/a] Vertical shearing, x-component
        real(prec), intent(IN) :: duydz(:,:,:)          ! [1/a] Vertical shearing, x-component
        real(prec), intent(IN) :: zeta_aa(:)            ! Vertical axis (sigma-coordinates from 0 to 1)
        real(prec), intent(IN) :: dx, dy
        
        ! Local variables 
        integer :: i, j, nx, ny, k, nz_aa 
        integer :: im1, ip1, jm1, jp1  
        real(prec) :: inv_4dx, inv_4dy
        real(prec) :: dudx, dudy
        real(prec) :: dvdx, dvdy 
        real(prec) :: duxdz_aa, duydz_aa 

        real(prec), parameter :: epsilon_sq_0 = 1e-6_prec   ! [a^-1] Bueler and Brown (2009), Eq. 26
        
        nx    = size(ux,1)
        ny    = size(ux,2)
        nz_aa = size(zeta_aa,1) 

        inv_4dx = 1.0_prec / (4.0_prec*dx) 
        inv_4dy = 1.0_prec / (4.0_prec*dy) 

        ! Initialize strain rate to zero 
        eps_sq = 0.0_prec 

        ! Loop over domain to calculate viscosity at each aa-node
         
        do j = 1, ny
        do i = 1, nx

            im1 = max(i-1,1) 
            ip1 = min(i+1,nx) 
            jm1 = max(j-1,1) 
            jp1 = min(j+1,ny) 
            
            ! Calculate effective strain components from horizontal stretching
            dudx = (ux(i,j) - ux(im1,j))/dx
            dvdy = (uy(i,j) - uy(i,jm1))/dy

            ! Calculate of cross terms on central aa-nodes (symmetrical results)
            dudy = ((ux(i,jp1)   - ux(i,jm1))    &
                  + (ux(im1,jp1) - ux(im1,jm1))) * inv_4dx 
            dvdx = ((uy(ip1,j)   - uy(im1,j))    &
                  + (uy(ip1,jm1) - uy(im1,jm1))) * inv_4dy 

            ! Loop over vertical dimension 
            do k = 1, nz_aa 

                ! Un-stagger shear terms to central aa-nodes in horizontal
                duxdz_aa = 0.5_prec*(duxdz(i,j,k) + duxdz(im1,j,k))
                duydz_aa = 0.5_prec*(duydz(i,j,k) + duydz(i,jm1,k))
                
                ! Calculate the total effective strain rate from L19, Eq. 21 
                eps_sq(i,j,k) = dudx**2 + dvdy**2 + dudx*dvdy + 0.25_prec*(dudy+dvdx)**2 &
                               + 0.25_prec*duxdz_aa**2 + 0.25_prec*duydz_aa**2 &
                               + epsilon_sq_0
            
            end do 

        end do 
        end do 

        return
        
    end subroutine calc_strain_eff_squared

    subroutine calc_visc_eff_3D(visc_eff,ATT,eps_sq,n_glen)
        ! Calculate 3D effective viscosity 
        ! following L19, Eq. 2

        implicit none 
        
        real(prec), intent(OUT) :: visc_eff(:,:,:)  ! aa-nodes
        real(prec), intent(IN)  :: ATT(:,:,:)       ! aa-nodes
        real(prec), intent(IN)  :: eps_sq(:,:,:)    ! aa-nodes
        real(prec), intent(IN)  :: n_glen   

        ! Local variables 
        integer :: i, j, k, nx, ny, nz  
        real(prec) :: mu 

        real(prec), parameter :: visc_min     = 1e3_prec 
        
        nx = size(visc_eff,1)
        ny = size(visc_eff,2)
        nz = size(visc_eff,3)
        
        do k = 1, nz 
        do j = 1, ny 
        do i = 1, nx 

            ! Calculate intermediate term
            mu = 0.5_prec*(eps_sq(i,j,k))**((1.0_prec - n_glen)/(2.0_prec*n_glen))

            ! Calculate effective viscosity 
            visc_eff(i,j,k) = ATT(i,j,k)**(-1.0_prec/n_glen) * mu

            if (visc_eff(i,j,k) .lt. visc_min) visc_eff(i,j,k) = visc_min 

        end do 
        end do  
        end do 

        return 

    end subroutine calc_visc_eff_3D 

    subroutine calc_F_integral(Fint,visc,H_ice,zeta_aa,n)
        ! Useful integrals, following Arthern et al. (2015) Eq. 7,
        ! and Lipscomb et al. (2019), Eq. 30
        ! F_n = int_zb_zs{ 1/visc * ((s-z)/H)**n dz}
        implicit none 

        real(prec), intent(OUT) :: Fint(:,:) 
        real(prec), intent(IN)  :: visc(:,:,:)
        real(prec), intent(IN)  :: H_ice(:,:)
        real(prec), intent(IN)  :: zeta_aa(:)
        real(prec), intent(IN)  :: n  

        ! Local variables 
        integer :: i, j, nx, ny
        real(prec) :: Fint_min 
        real(prec), parameter :: visc_min     = 1e3_prec

        nx = size(visc,1)
        ny = size(visc,2) 

        ! Determine the minimum value of Fint, to assign when H_ice == 0,
        ! since Fint should be nonzero everywhere for numerics
        Fint_min = integrate_trapezoid1D_pt((1.0_prec/visc_min)*(1.0_prec-zeta_aa)**n,zeta_aa)

        ! Vertically integrate at each point
        do j = 1, ny 
        do i = 1, nx 
            if (H_ice(i,j) .gt. 0.0_prec) then 
                ! Viscosity should be nonzero here, perform integration 

                Fint(i,j) = integrate_trapezoid1D_pt((1.0_prec/visc(i,j,:))*(1.0_prec-zeta_aa)**n,zeta_aa)

            else 

                Fint(i,j) = Fint_min

            end if 

        end do 
        end do 

        return

    end subroutine calc_F_integral
    
    subroutine calc_beta_eff(beta_eff,beta,ux_b,uy_b,F2,zeta_aa)
        ! Calculate the depth-averaged horizontal velocity (ux_bar,uy_bar)

        ! Note: L19 staggers the F-integral F2, then solves for beta 

        implicit none 
        
        real(prec), intent(OUT) :: beta_eff(:,:)    ! aa-nodes
        real(prec), intent(IN)  :: beta(:,:)        ! aa-nodes
        real(prec), intent(IN)  :: ux_b(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: uy_b(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: F2(:,:)          ! aa-nodes
        real(prec), intent(IN)  :: zeta_aa(:)       ! aa-nodes

        ! Local variables 
        integer    :: i, j, nx, ny
        integer    :: im1, jm1  
        real(prec) :: uxy_b 

        nx = size(beta_eff,1)
        ny = size(beta_eff,2)

        do j = 1, ny 
        do i = 1, nx 

            im1 = max(i-1,1)
            jm1 = max(j-1,1)

            ! Calculate basal velocity magnitude at grid center, aa-nodes
            uxy_b = sqrt( 0.5_prec*(ux_b(i,j)+ux_b(im1,j))**2 + 0.5_prec*(ux_b(i,j)+ux_b(i,jm1))**2 )

            if (uxy_b .gt. 0.0) then 
                ! Basal sliding exists, follow L19, Eq. 33

                beta_eff(i,j) = beta(i,j) / (1.0+beta(i,j)*F2(i,j))

            else 
                ! No basal sliding, follow L19, Eq. 35 

                beta_eff(i,j) = 1.0 / F2(i,j) 

            end if 

        end do 
        end do 


        return 

    end subroutine calc_beta_eff 

    subroutine calc_vel_basal(ux_b,uy_b,ux_bar,uy_bar,F2,beta_acx,beta_acy)
        ! Calculate basal sliding following L19, Eq. 32 

        implicit none
        
        real(prec), intent(OUT) :: ux_b(:,:) 
        real(prec), intent(OUT) :: uy_b(:,:)
        real(prec), intent(IN)  :: ux_bar(:,:) 
        real(prec), intent(IN)  :: uy_bar(:,:)
        real(prec), intent(IN)  :: F2(:,:)
        real(prec), intent(IN)  :: beta_acx(:,:) 
        real(prec), intent(IN)  :: beta_acy(:,:)
        
        ! Local variables 
        integer    :: i, j, nx, ny 
        integer    :: ip1, jp1 
        real(prec) :: F2_ac 

        do j = 1, ny 
        do i = 1, nx 

            ip1 = min(i,nx)
            jp1 = min(j,ny)

            F2_ac = 0.5_prec*(F2(i,j) + F2(ip1,j))
            ux_b(i,j) = ux_bar(i,j) / (1.0_prec + beta_acx(i,j)*F2_ac)

            F2_ac = 0.5_prec*(F2(i,j) + F2(i,jp1))
            uy_b(i,j) = uy_bar(i,j) / (1.0_prec + beta_acy(i,j)*F2_ac)

        end do 
        end do  

        return
        
    end subroutine calc_vel_basal

    function calc_vertical_integrated_3D_ice(var,H_ice,sigma) result(var_int)
        ! Vertically integrate a field 3D field (nx,ny,nz)
        ! layer by layer (in the z-direction), return a 3D array
        
        implicit none

        real(prec), intent(IN) :: var(:,:,:)
        real(prec), intent(IN) :: H_ice(:,:) 
        real(prec), intent(IN) :: sigma(:)
        real(prec) :: var_int(size(var,1),size(var,2),size(var,3))

        ! Local variables 
        integer :: i, j, nx, ny

        nx = size(var,1)
        ny = size(var,2)

        do j = 1, ny
        do i = 1, nx
            var_int(i,j,:) = integrate_trapezoid1D_1D(var(i,j,:),sigma*H_ice(i,j))
        end do
        end do

        return

    end function calc_vertical_integrated_3D_ice

    subroutine calc_basal_stress(taub_acx,taub_acy,beta_acx,beta_acy,ux_b,uy_b)
        ! Calculate the basal stress resulting from sliding (friction times velocity)
        ! Note: calculated on ac-nodes.
        ! taub [Pa] 
        ! beta [Pa a m-1]
        ! u    [m a-1]
        ! taub = -beta*u 

        implicit none 

        real(prec), intent(OUT) :: taub_acx(:,:)   ! [Pa] Basal stress (acx nodes)
        real(prec), intent(OUT) :: taub_acy(:,:)   ! [Pa] Basal stress (acy nodes)
        real(prec), intent(IN)  :: beta_acx(:,:)   ! [Pa a m-1] Basal friction (acx nodes)
        real(prec), intent(IN)  :: beta_acy(:,:)   ! [Pa a m-1] Basal friction (acy nodes)
        real(prec), intent(IN)  :: ux_b(:,:)       ! [m a-1] Basal velocity (acx nodes)
        real(prec), intent(IN)  :: uy_b(:,:)       ! [m a-1] Basal velocity (acy nodes)
        
        ! Calculate basal stress 
        taub_acx = -beta_acx * ux_b 
        taub_acy = -beta_acy * uy_b 

        return 

    end subroutine calc_basal_stress

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
