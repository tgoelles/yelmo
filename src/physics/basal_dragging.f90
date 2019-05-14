module basal_dragging
    ! This module calculate beta, the basal friction coefficient,
    ! needed as input to the SSA solver. It corresponds to
    ! the equation for basal stress:
    !
    ! tau_b_acx = beta_acx * ux
    ! tau_b_acy = beta_acy * uy 
    !
    ! Note that for the stability and correctness of the SSA solver, 
    ! particularly at the grounding line, beta should be defined
    ! directly on the ac nodes (acx,acy). 

    use yelmo_defs, only : sp, dp, prec, pi, g, rho_sw, rho_ice, rho_w  

    use yelmo_tools, only : stagger_aa_acx, stagger_aa_acy, smooth_gauss_2D

    implicit none 


    private

    public :: calc_effective_pressure

    ! Beta functions (aa-nodes)
    public :: calc_beta_aa_linear
    public :: calc_beta_aa_power
    public :: calc_beta_aa_coulomb

    ! Beta scaling functions (aa-nodes)
    public :: scale_beta_aa_Neff
    public :: scale_beta_aa_grline
    public :: scale_beta_aa_Hgrnd 
    public :: scale_beta_aa_zstar
    
    ! Beta smoothing functions (aa-nodes)
    public :: smooth_beta_aa

    ! Beta staggering functions (aa- to ac-nodes)
    public :: stagger_beta_aa_simple
    public :: stagger_beta_aa_upstream
    public :: stagger_beta_aa_subgrid
    public :: stagger_beta_aa_subgrid_1 

    ! Extra...
    public :: calc_beta_ac_linear
    public :: calc_beta_ac_power
    public :: scale_beta_ac_binary
    public :: scale_beta_ac_fraction
    public :: scale_beta_ac_Neff

    public :: scale_beta_ac_Hgrnd
    public :: scale_beta_ac_zstar
    public :: scale_beta_ac_l14
    
    
contains 

    elemental function calc_effective_pressure(H_ice,z_bed,z_sl,H_w,p) result(N_eff)
        ! Effective pressure as a function of connectivity to the ocean
        ! as defined by Leguy et al. (2014), Eq. 14, and modified
        ! by Robinson and Alvarez-Solas to account for basal water pressure (to do!)

        ! Note: input is for a given point, should be on central aa-nodes
        ! or shifted to ac-nodes before entering this routine 

        implicit none 

        real(prec), intent(IN) :: H_ice 
        real(prec), intent(IN) :: z_bed 
        real(prec), intent(IN) :: z_sl 
        real(prec), intent(IN) :: H_w 
        real(prec), intent(IN) :: p       ! [0:1], 0: no ocean connectivity, 1: full ocean connectivity
        real(prec) :: N_eff                 ! Output in [bar] == [1e-5 Pa] 

        ! Local variables  
        real(prec) :: H_float     ! Maximum ice thickness to allow floating ice
        real(prec) :: p_w         ! Pressure of water at the base of the ice sheet
        real(prec) :: x 
        real(prec) :: rho_sw_ice 

        rho_sw_ice = rho_sw/rho_ice 

        ! Determine the maximum ice thickness to allow floating ice
        H_float = max(0.0_prec, rho_sw_ice*(z_sl-z_bed))

        ! Calculate basal water pressure 
        if (H_ice .eq. 0.0) then
            ! No water pressure for ice-free points

            p_w = 0.0 

        else if (H_ice .lt. H_float) then 
            ! Floating ice: water pressure equals ice pressure 

            p_w   = (rho_ice*g*H_ice)

        else
            ! Determine water pressure based on marine connectivity (Leguy et al., 2014, Eq. 14)

            x     = min(1.0_prec, H_float/H_ice)
            p_w   = (rho_ice*g*H_ice)*(1.0_prec - (1.0_prec-x)**p)

        end if 

        ! Calculate effective pressure (overburden pressure minus basal water pressure)
        ! Convert from [Pa] => [bar]
        N_eff = 1e-5 * ((rho_ice*g*H_ice) - p_w) 

        return 

    end function calc_effective_pressure

    ! ================================================================================
    !
    ! Beta functions (aa-nodes) 
    !
    ! ================================================================================

    subroutine calc_beta_aa_linear(beta,C_bed)
        ! Calculate basal friction coefficient (beta) that
        ! enters the SSA solver as a function of basal velocity
        ! Pollard and de Conto (2012), inverse of Eq. 10, given following Eq. 7
        ! Note: Calculated on ac-nodes
        ! Note: beta should be calculated for bed everywhere, 
        ! independent of floatation, which is accounted for later
        
        implicit none
        
        real(prec), intent(OUT) :: beta(:,:)    ! aa-nodes
        real(prec), intent(IN)  :: C_bed(:,:)   ! aa-nodes
        
        beta = C_bed

        return
        
    end subroutine calc_beta_aa_linear
    
    subroutine calc_beta_aa_power(beta,ux_b,uy_b,C_bed,m_drag)
        ! Calculate basal friction coefficient (beta) that
        ! enters the SSA solver as a function of basal velocity
        ! Pollard and de Conto (2012), inverse of Eq. 10, given in text
        ! following Eq. 7: beta = c_b**(-1/m)*|u_b|**((1-m)/m)
        ! Note: Calculated on ac-nodes
        ! Note: beta should be calculated for bed everywhere, 
        ! independent of floatation, which is accounted for later
        
        implicit none
        
        real(prec), intent(OUT) :: beta(:,:)        ! aa-nodes
        real(prec), intent(IN)  :: ux_b(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: uy_b(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: C_bed(:,:)       ! Aa nodes
        real(prec), intent(IN)  :: m_drag
        
        ! Local variables
        integer    :: i, j, nx, ny
        integer    :: i1, i2, j1, j2 
        real(prec) :: ux_b_mid, uy_b_mid, uxy_b
        real(prec) :: exp1, exp2
        real(prec) :: C_bed_ac 

        real(prec), parameter :: u_b_min    = 1e-3_prec  ! [m/a] Minimum velocity is positive small value

        nx = size(beta,1)
        ny = size(beta,2)
        
        ! Pre-define exponents
        exp1 = 1.0_prec/m_drag
        exp2 = (1.0_prec-m_drag)/m_drag
        
        ! Initially set friction to zero everywhere
        beta = 0.0_prec 

        ! x-direction 
        do j = 1, ny
        do i = 1, nx

            i1 = max(i-1,1)
            j1 = max(j-1,1) 
            
            ! Calculate magnitude of basal velocity on aa-node 
            ux_b_mid  = 0.5_prec*(ux_b(i1,j)+ux_b(i,j))
            uy_b_mid  = 0.5_prec*(uy_b(i,j1)+uy_b(i,j))
            uxy_b     = (ux_b_mid**2 + uy_b_mid**2 + u_b_min**2)**0.5

            ! Nonlinear beta as a function of basal velocity (unless m==1)
            if (uxy_b .eq. 0.0) then 
                beta(i,j) = C_bed(i,j)**exp1
            else 
                beta(i,j) = C_bed(i,j)**exp1 * uxy_b**exp2 
            end if  

        end do
        end do
        
        return
        
    end subroutine calc_beta_aa_power
    
    subroutine calc_beta_aa_coulomb(beta,ux_b,uy_b,C_bed,m_drag,u_0)
        ! Calculate basal friction coefficient (beta) that
        ! enters the SSA solver as a function of basal velocity
        ! Pollard and de Conto (2012), inverse of Eq. 10, given in text
        ! following Eq. 7: beta = c_b**(-1/m)*|u_b|**((1-m)/m)
        ! Note: Calculated on ac-nodes
        ! Note: beta should be calculated for bed everywhere, 
        ! independent of floatation, which is accounted for later
        
        implicit none
        
        real(prec), intent(OUT) :: beta(:,:)        ! aa-nodes
        real(prec), intent(IN)  :: ux_b(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: uy_b(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: C_bed(:,:)       ! Aa nodes
        real(prec), intent(IN)  :: m_drag
        real(prec), intent(IN)  :: u_0

        ! Local variables
        integer    :: i, j, nx, ny
        integer    :: i1, i2, j1, j2 
        real(prec) :: ux_b_mid, uy_b_mid, uxy_b
        real(prec) :: exp1, exp2
        real(prec) :: C_bed_ac 

        real(prec), parameter :: u_b_min    = 1e-3_prec  ! [m/a] Minimum velocity is positive small value

        nx = size(beta,1)
        ny = size(beta,2)
        
        ! Pre-define exponents
        exp2 = 1.0/m_drag
        
        ! Initially set friction to zero everywhere
        beta = 0.0_prec 

        ! x-direction 
        do j = 1, ny
        do i = 1, nx

            i1 = max(i-1,1)
            j1 = max(j-1,1) 
            
            ! Calculate magnitude of basal velocity on aa-node 
            ux_b_mid  = 0.5_prec*(ux_b(i1,j)+ux_b(i,j))
            uy_b_mid  = 0.5_prec*(uy_b(i,j1)+uy_b(i,j))
            uxy_b     = (ux_b_mid**2 + uy_b_mid**2 + u_b_min**2)**0.5

            ! Nonlinear beta as a function of basal velocity (unless m==1)
            if (uxy_b .eq. 0.0) then 
                beta(i,j) = C_bed(i,j)
            else 
                beta(i,j) = C_bed(i,j) * (uxy_b / (uxy_b+u_0))**exp2 * uxy_b**(-1) 
            end if  

        end do
        end do
        
        return
        
    end subroutine calc_beta_aa_coulomb

    ! ================================================================================
    !
    ! Scaling functions 
    !
    ! ================================================================================

    subroutine scale_beta_aa_Neff(beta,N_eff)
        ! Calculate scalar between 0 and 1 to modify basal friction coefficient
        ! as ice approaches and achieves floatation, and apply.
        
        implicit none
            
        real(prec), intent(INOUT) :: beta(:,:)        ! aa-nodes
        real(prec), intent(IN)    :: N_eff(:,:)       ! aa-nodes, [bar]     

        beta = N_eff * beta 

        return
        
    end subroutine scale_beta_aa_Neff
    
    subroutine scale_beta_aa_grline(beta,f_grnd,f_beta_gl)
        ! Applyt scalar between 0 and 1 to modify basal friction coefficient
        ! at the grounding line.
        
        implicit none
        
        real(prec), intent(INOUT) :: beta(:,:)    ! aa-nodes
        real(prec), intent(IN)    :: f_grnd(:,:)  ! aa-nodes
        real(prec), intent(IN)    :: f_beta_gl    ! Fraction parameter      

        ! Local variables
        integer    :: i, j, nx, ny
        integer    :: im1, ip1, jm1, jp1 

        nx = size(f_grnd,1)
        ny = size(f_grnd,2) 

        ! Consistency check 
        if (f_beta_gl .lt. 0.0 .or. f_beta_gl .gt. 1.0) then 
            write(*,*) "scale_beta_aa_grline:: Error: f_beta_gl must be between 0 and 1."
            write(*,*) "f_beta_gl = ", f_beta_gl
            stop 
        end if 
         
        do j = 1, ny 
        do i = 1, nx-1

            im1 = max(1, i-1)
            ip1 = min(nx,i+1)
            
            jm1 = max(1, j-1)
            jp1 = min(ny,j+1)

            ! Check if point is at the grounding line 
            if (f_grnd(i,j) .gt. 0.0 .and. &
                (f_grnd(im1,j) .eq. 0.0 .or. f_grnd(ip1,j) .eq. 0.0 .or. &
                 f_grnd(i,jm1) .eq. 0.0 .or. f_grnd(i,jp1) .eq. 0.0) ) then 

                ! Apply grounding-line beta scaling 
                beta(i,j) = f_beta_gl * beta(i,j) 

            end if 

        end do 
        end do  

        return
        
    end subroutine scale_beta_aa_grline
    
    subroutine scale_beta_aa_Hgrnd(beta,H_grnd,H_grnd_lim)
        ! Calculate scalar between 0 and 1 to modify basal friction coefficient
        ! as ice approaches and achieves floatation, and apply.
        
        implicit none
        
        real(prec), intent(INOUT) :: beta(:,:)    ! aa-nodes
        real(prec), intent(IN)    :: H_grnd(:,:)  ! aa-nodes
        real(prec), intent(IN)    :: H_grnd_lim       

        ! Local variables
        integer    :: i, j, nx, ny
        real(prec) :: f_scale 

        nx = size(H_grnd,1)
        ny = size(H_grnd,2) 

        ! Consistency check 
        if (H_grnd_lim .le. 0.0) then 
            write(*,*) "scale_beta_aa_Hgrnd:: Error: H_grnd_lim must be positive."
            write(*,*) "H_grnd_lim = ", H_grnd_lim
            stop 
        end if 
         
        do j = 1, ny 
        do i = 1, nx

            f_scale   = max( min(H_grnd(i,j),H_grnd_lim)/H_grnd_lim, 0.0) 
            beta(i,j) = f_scale * beta(i,j) 

        end do 
        end do  

        return
        
    end subroutine scale_beta_aa_Hgrnd
    
    subroutine scale_beta_aa_zstar(beta,H_ice,z_bed,z_sl,norm)
        ! Calculate scalar between 0 and 1 to modify basal friction coefficient
        ! as ice approaches and achieves floatation, and apply.
        ! Following "Zstar" approach of Gladstone et al. (2017) 
        
        implicit none
        
        real(prec), intent(INOUT) :: beta(:,:)      ! aa-nodes
        real(prec), intent(IN)    :: H_ice(:,:)     ! aa-nodes
        real(prec), intent(IN)    :: z_bed(:,:)     ! aa-nodes        
        real(prec), intent(IN)    :: z_sl(:,:)      ! aa-nodes        
        logical,    intent(IN)    :: norm           ! Normalize by H_ice? 

        ! Local variables
        integer    :: i, j, nx, ny
        real(prec) :: f_scale 
        real(prec) :: rho_sw_ice 

        rho_sw_ice = rho_sw / rho_ice 

        nx = size(H_ice,1)
        ny = size(H_ice,2) 

        ! acx-nodes 
        do j = 1, ny 
        do i = 1, nx

            if (z_bed(i,j) > z_sl(i,j)) then 
                ! Land based above sea level 
                f_scale = H_ice(i,j) 
            else
                ! Marine based 
                f_scale = max(0.0_prec, H_ice(i,j) - (z_sl(i,j)-z_bed(i,j))*rho_sw_ice)
            end if 

            if (norm .and. H_ice(i,j) .gt. 0.0) f_scale = f_scale / H_ice(i,j) 

            beta(i,j) = f_scale * beta(i,j) 

        end do 
        end do  

        return
        
    end subroutine scale_beta_aa_zstar

    ! ================================================================================
    !
    ! Smoothing functions 
    !
    ! ================================================================================

    subroutine smooth_beta_aa(beta,dx,n_smooth)
        ! Smooth the grounded beta field to avoid discontinuities that
        ! may crash the model. Ensure that points with 
        ! low values of beta are not too far away from neighborhood values 

        implicit none 

        real(prec), intent(INOUT) :: beta(:,:) 
        real(prec), intent(IN)    :: dx           ! [m]
        integer,    intent(IN)    :: n_smooth     ! [--] Number of points corresponding to 1-sigma

        ! Local variables 
        real(prec) :: dx_km, sigma 

        dx_km = dx*1e-3 
        sigma = dx_km*n_smooth 

        call smooth_gauss_2D(beta,mask_apply=beta .gt. 0.0,dx=dx_km,sigma=sigma,mask_use=beta .gt. 0.0)

        return 

    end subroutine smooth_beta_aa
    
    ! ================================================================================
    !
    ! Staggering functions 
    !
    ! ================================================================================

    subroutine stagger_beta_aa_simple(beta_acx,beta_acy,beta)
        ! Stagger beta from aa-nodes to ac-nodes
        ! using simple staggering method, independent
        ! of any information about flotation, etc. 

        implicit none
        
        real(prec), intent(INOUT) :: beta_acx(:,:)   ! ac-nodes
        real(prec), intent(INOUT) :: beta_acy(:,:)   ! ac-nodes
        real(prec), intent(IN)    :: beta(:,:)       ! aa-nodes

        ! Local variables
        integer    :: i, j, nx, ny

        nx = size(beta_acx,1)
        ny = size(beta_acx,2) 

        ! === Stagger to ac-nodes === 

        ! acx-nodes
        do j = 1, ny 
        do i = 1, nx-1
            beta_acx(i,j) = 0.5_prec*(beta(i,j)+beta(i+1,j))
        end do 
        end do 
        beta_acx(nx,:) = beta_acx(nx-1,:) 
        
        ! acy-nodes 
        do j = 1, ny-1 
        do i = 1, nx
            beta_acy(i,j) = 0.5_prec*(beta(i,j)+beta(i,j+1))
        end do 
        end do 
        beta_acy(:,ny) = beta_acy(:,ny-1) 
        
        return
        
    end subroutine stagger_beta_aa_simple
    
    subroutine stagger_beta_aa_upstream(beta_acx,beta_acy,beta,f_grnd)
        ! Modify basal friction coefficient by grounded/floating binary mask
        ! (via the grounded fraction)
        ! Analagous to method "NSEP" in Seroussi et al (2014): 
        ! Friction is zero if a staggered node contains a floating fraction,
        ! ie, f_grnd_acx/acy > 1.0 

        implicit none
        
        real(prec), intent(INOUT) :: beta_acx(:,:)   ! ac-nodes
        real(prec), intent(INOUT) :: beta_acy(:,:)   ! ac-nodes
        real(prec), intent(IN)    :: beta(:,:)       ! aa-nodes
        real(prec), intent(IN)    :: f_grnd(:,:)     ! aa-nodes    
        
        ! Local variables
        integer    :: i, j, nx, ny 
        logical    :: is_float 

        nx = size(beta_acx,1)
        ny = size(beta_acx,2) 

        ! === Stagger to ac-nodes === 

        ! acx-nodes
        do j = 1, ny 
        do i = 1, nx-1

            if (f_grnd(i,j) .eq. 0.0 .and. f_grnd(i+1,j) .eq. 0.0) then 
                ! Purely floating points only considered floating (ie, domain more grounded)

                is_float = .TRUE. 

            else 
                ! Grounded 

                is_float = .FALSE. 

            end if 

            if (is_float) then
                ! Consider ac-node floating

                beta_acx(i,j) = 0.0 

            else 
                ! Consider ac-node grounded 

                if (f_grnd(i,j) .gt. 0.0 .and. f_grnd(i+1,j) .eq. 0.0) then 
                    beta_acx(i,j) = beta(i,j)
                else if (f_grnd(i,j) .eq. 0.0 .and. f_grnd(i+1,j) .gt. 0.0) then
                    beta_acx(i,j) = beta(i+1,j)
                else 
                    beta_acx(i,j) = 0.5_prec*(beta(i,j)+beta(i+1,j))
                end if 
                
            end if 
            
        end do 
        end do 
        beta_acx(nx,:) = beta_acx(nx-1,:) 
        
        ! acy-nodes 
        do j = 1, ny-1 
        do i = 1, nx

            if (f_grnd(i,j) .eq. 0.0 .and. f_grnd(i,j+1) .eq. 0.0) then 
                ! Purely floating points only considered floating (ie, domain more grounded)

                is_float = .TRUE. 

            else 
                ! Grounded 

                is_float = .FALSE. 

            end if 

            if (is_float) then
                ! Consider ac-node floating

                beta_acy(i,j) = 0.0 

            else 
                ! Consider ac-node grounded 

                if (f_grnd(i,j) .gt. 0.0 .and. f_grnd(i,j+1) .eq. 0.0) then 
                    beta_acy(i,j) = beta(i,j)
                else if (f_grnd(i,j) .eq. 0.0 .and. f_grnd(i,j+1) .gt. 0.0) then
                    beta_acy(i,j) = beta(i,j+1)
                else 
                    beta_acy(i,j) = 0.5_prec*(beta(i,j)+beta(i,j+1))
                end if 
                
            end if 
            
        end do 
        end do 
        beta_acy(:,ny) = beta_acy(:,ny-1) 
        
        return
        
    end subroutine stagger_beta_aa_upstream
    
    subroutine stagger_beta_aa_subgrid(beta_acx,beta_acy,beta,f_grnd,f_grnd_acx,f_grnd_acy)
        ! Modify basal friction coefficient by grounded/floating binary mask
        ! (via the grounded fraction)
        ! Analagous to method "NSEP" in Seroussi et al (2014): 
        ! Friction is zero if a staggered node contains a floating fraction,
        ! ie, f_grnd_acx/acy > 1.0 

        implicit none
        
        real(prec), intent(INOUT) :: beta_acx(:,:)      ! ac-nodes
        real(prec), intent(INOUT) :: beta_acy(:,:)      ! ac-nodes
        real(prec), intent(IN)    :: beta(:,:)          ! aa-nodes
        real(prec), intent(IN)    :: f_grnd(:,:)        ! aa-nodes     
        real(prec), intent(IN)    :: f_grnd_acx(:,:)    ! ac-nodes     
        real(prec), intent(IN)    :: f_grnd_acy(:,:)    ! ac-nodes     
        
        ! Local variables
        integer    :: i, j, nx, ny 

        nx = size(beta_acx,1)
        ny = size(beta_acx,2) 

        ! Apply simple staggering to ac-nodes

        ! acx-nodes
        do j = 1, ny 
        do i = 1, nx-1

            if (f_grnd(i,j) .gt. 0.0 .and. f_grnd(i+1,j) .eq. 0.0) then 
                ! Floating to the right 
                beta_acx(i,j) = f_grnd_acx(i,j)*beta(i,j) + (1.0-f_grnd_acx(i,j))*beta(i+1,j)
            else if (f_grnd(i,j) .eq. 0.0 .and. f_grnd(i+1,j) .gt. 0.0) then 
                ! Floating to the left 
                beta_acx(i,j) = (1.0-f_grnd_acx(i,j))*beta(i,j) + f_grnd_acx(i,j)*beta(i+1,j)
            else if (f_grnd(i,j) .gt. 0.0 .and. f_grnd(i+1,j) .gt. 0.0) then 
                ! Fully grounded, simple staggering 
                beta_acx(i,j) = 0.5*(beta(i,j) + beta(i+1,j))
            else 
                ! Fully floating 
                beta_acx(i,j) = 0.0 
            end if 

        end do 
        end do 
        beta_acx(nx,:) = beta_acx(nx-1,:) 
        
        ! acy-nodes 
        do j = 1, ny-1 
        do i = 1, nx

            if (f_grnd(i,j) .gt. 0.0 .and. f_grnd(i,j+1) .eq. 0.0) then 
                ! Floating to the top 
                beta_acy(i,j) = f_grnd_acy(i,j)*beta(i,j) + (1.0-f_grnd_acy(i,j))*beta(i,j+1)
            else if (f_grnd(i,j) .eq. 0.0 .and. f_grnd(i,j+1) .gt. 0.0) then 
                ! Floating to the bottom 
                beta_acy(i,j) = (1.0-f_grnd_acy(i,j))*beta(i,j) + f_grnd_acy(i,j)*beta(i,j+1)
            else if (f_grnd(i,j) .gt. 0.0 .and. f_grnd(i,j+1) .gt. 0.0) then 
                ! Fully grounded, simple staggering 
                beta_acy(i,j) = 0.5*(beta(i,j) + beta(i,j+1))
            else 
                ! Fully floating 
                beta_acy(i,j) = 0.0 
            end if 

        end do 
        end do 
        beta_acy(:,ny) = beta_acy(:,ny-1) 
        
        return
        
    end subroutine stagger_beta_aa_subgrid
    
    subroutine stagger_beta_aa_subgrid_1(beta_acx,beta_acy,beta,H_grnd,f_grnd_acx,f_grnd_acy,dHdt)
        ! Modify basal friction coefficient by grounded/floating binary mask
        ! (via the grounded fraction)
        ! Analagous to method "NSEP" in Seroussi et al (2014): 
        ! Friction is zero if a staggered node contains a floating fraction,
        ! ie, f_grnd_acx/acy > 1.0 

        implicit none
        
        real(prec), intent(INOUT) :: beta_acx(:,:)   ! ac-nodes
        real(prec), intent(INOUT) :: beta_acy(:,:)   ! ac-nodes
        real(prec), intent(INOUT) :: beta(:,:)       ! aa-nodes
        real(prec), intent(IN)    :: H_grnd(:,:)     ! aa-nodes    
        real(prec), intent(IN)    :: f_grnd_acx(:,:) ! ac-nodes 
        real(prec), intent(IN)    :: f_grnd_acy(:,:) ! ac-nodes
        real(prec), intent(IN)    :: dHdt(:,:)       ! aa-nodes  
        
        ! Local variables
        integer    :: i, j, nx, ny
        real(prec) :: H_grnd_now, dHdt_now  
        logical    :: is_float 

        nx = size(beta_acx,1)
        ny = size(beta_acx,2) 

        ! === Treat beta at the grounding line on aa-nodes ===

        ! Cut-off beta according to floating criterion on aa-nodes
        !where (H_grnd .le. 0.0) beta = 0.0 
        !beta = beta*f_grnd

        ! === Stagger to ac-nodes === 

        ! acx-nodes
        do j = 1, ny 
        do i = 1, nx-1

            H_grnd_now = 0.5_prec*(H_grnd(i,j)+H_grnd(i+1,j))
            !dHdt_now   = 0.5_prec*(dHdt(i,j)+dHdt(i+1,j))
            dHdt_now   = max(dHdt(i,j),dHdt(i+1,j))

            if (dHdt_now .gt. 0.0 .and. f_grnd_acx(i,j) .eq. 0.0) then 
                ! Purely floating points only considered floating (ie, domain more grounded)

                is_float = .TRUE. 

            else if (dHdt_now .le. 0.0 .and. f_grnd_acx(i,j) .lt. 1.0) then 
                ! Purely floating and partially grounded points considered floating (ie, domain more floating)
                
                is_float = .TRUE. 

            else 
                ! Grounded 

                is_float = .FALSE. 

            end if 

            if (is_float) then
                ! Consider ac-node floating

                beta_acx(i,j) = 0.0 

            else 
                ! Consider ac-node grounded 

                if (H_grnd(i,j) .gt. 0.0 .and. H_grnd(i+1,j) .le. 0.0) then 
                    beta_acx(i,j) = beta(i,j) !*f_grnd_acx(i,j)
                else if (H_grnd(i,j) .le. 0.0 .and. H_grnd(i+1,j) .gt. 0.0) then
                    beta_acx(i,j) = beta(i+1,j) !*f_grnd_acx(i,j)
                else 
                    beta_acx(i,j) = 0.5_prec*(beta(i,j)+beta(i+1,j))
                end if 
                
            end if 
            
        end do 
        end do 
        beta_acx(nx,:) = beta_acx(nx-1,:) 
        
        ! acy-nodes 
        do j = 1, ny-1 
        do i = 1, nx

!             dHdt_now   = 0.5_prec*(dHdt(i,j)+dHdt(i,j+1))
            dHdt_now   = max(dHdt(i,j),dHdt(i,j+1))
            
            if (dHdt_now .gt. 0.0 .and. f_grnd_acy(i,j) .eq. 0.0) then 
                ! Purely floating points only considered floating (ie, domain more grounded)

                is_float = .TRUE. 

            else if (dHdt_now .le. 0.0 .and. f_grnd_acy(i,j) .lt. 1.0) then 
                ! Purely floating and partially grounded points considered floating (ie, domain more floating)
                
                is_float = .TRUE. 

            else 
                ! Grounded 

                is_float = .FALSE. 

            end if 

            if (is_float) then
                ! Consider ac-node floating

                beta_acy(i,j) = 0.0 

            else 
                ! Consider ac-node grounded 

                if (H_grnd(i,j) .gt. 0.0 .and. H_grnd(i,j+1) .le. 0.0) then 
                    beta_acy(i,j) = beta(i,j) !*f_grnd_acy(i,j)
                else if (H_grnd(i,j) .le. 0.0 .and. H_grnd(i,j+1) .gt. 0.0) then
                    beta_acy(i,j) = beta(i,j+1) !*f_grnd_acy(i,j)
                else 
                    beta_acy(i,j) = 0.5_prec*(beta(i,j)+beta(i,j+1))
                end if 
                
            end if 
            
        end do 
        end do 
        beta_acy(:,ny) = beta_acy(:,ny-1) 
        
        return
        
    end subroutine stagger_beta_aa_subgrid_1
    
    ! ================================================================================
    ! ================================================================================



! ===== beta (ac-nodes) formulation, calculate beta on ac-nodes directly =====

    subroutine calc_beta_ac_linear(beta_acx,beta_acy,C_bed)
        ! Calculate basal friction coefficient (beta) that
        ! enters the SSA solver as a function of basal velocity
        ! Pollard and de Conto (2012), inverse of Eq. 10, given following Eq. 7
        ! Note: Calculated on ac-nodes
        ! Note: beta should be calculated for bed everywhere, 
        ! independent of floatation, which is accounted for later
        
        implicit none
        
        real(prec), intent(OUT) :: beta_acx(:,:)    ! ac-nodes
        real(prec), intent(OUT) :: beta_acy(:,:)    ! ac-nodes
        real(prec), intent(IN)  :: C_bed(:,:)       ! Aa nodes
        
        ! Local variables
        integer    :: i, j, nx, ny
        integer    :: i1, i2, j1, j2 
        real(prec) :: C_bed_ac 

        nx = size(beta_acx,1)
        ny = size(beta_acx,2)
        
        ! Initially set friction to zero everywhere
        beta_acx = 0.0_prec 
        beta_acy = 0.0_prec 
        
        ! x-direction 
        do j = 1, ny
        do i = 1, nx-1

            ! Get topo and bed quantities on Ac node 
            beta_acx(i,j) = 0.5_prec*(C_bed(i,j)+C_bed(i+1,j))

        end do
        end do
        
        ! y-direction 
        do j = 1, ny-1
        do i = 1, nx

            ! Get bed roughness on ac-node 
            beta_acy(i,j) = 0.5_prec*(C_bed(i,j)+C_bed(i,j+1))  

        end do
        end do
        
        return
        
    end subroutine calc_beta_ac_linear
    
    subroutine calc_beta_ac_power(beta_acx,beta_acy,ux_b,uy_b,C_bed,m_drag)
        ! Calculate basal friction coefficient (beta) that
        ! enters the SSA solver as a function of basal velocity
        ! Pollard and de Conto (2012), inverse of Eq. 10, given in text
        ! following Eq. 7: beta = c_b**(-1/m)*|u_b|**((1-m)/m)
        ! Note: Calculated on ac-nodes
        ! Note: beta should be calculated for bed everywhere, 
        ! independent of floatation, which is accounted for later
        
        implicit none
        
        real(prec), intent(OUT) :: beta_acx(:,:)    ! ac-nodes
        real(prec), intent(OUT) :: beta_acy(:,:)    ! ac-nodes
        real(prec), intent(IN)  :: ux_b(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: uy_b(:,:)        ! ac-nodes
        real(prec), intent(IN)  :: C_bed(:,:)       ! Aa nodes
        real(prec), intent(IN)  :: m_drag
        
        ! Local variables
        integer    :: i, j, nx, ny
        integer    :: i1, i2, j1, j2 
        real(prec) :: ux_b_ac, uy_b_ac, uxy_b_ac
        real(prec) :: exp1, exp2
        real(prec) :: C_bed_ac 

        real(prec), parameter :: u_b_min    = 1e-3_prec  ! [m/a] Minimum velocity is positive small value

        nx = size(beta_acx,1)
        ny = size(beta_acx,2)
        
        ! Pre-define exponents
        exp1 = 1.0_prec/m_drag
        exp2 = (1.0_prec-m_drag)/m_drag
        
        ! Initially set friction to zero everywhere
        beta_acx = 0.0_prec 
        beta_acy = 0.0_prec 
        
        ! x-direction 
        do j = 1, ny
        do i = 1, nx-1

            j1 = max(j-1,1) 

            ! Get topo and bed quantities on Ac node 
            C_bed_ac = 0.5_prec*(C_bed(i,j)+C_bed(i+1,j))

            ! Calculate magnitude of basal velocity on Ac node 
            ! ux is defined on Ac node, get uy on the ux Ac node 
            ux_b_ac  = ux_b(i,j)
            uy_b_ac  = 0.25_prec*(uy_b(i,j)+uy_b(i,j1)+uy_b(i+1,j)+uy_b(i+1,j1))
            uxy_b_ac = (ux_b_ac**2 + uy_b_ac**2 + u_b_min**2)**0.5

            ! Nonlinear beta as a function of basal velocity (unless m==1)
            if (uxy_b_ac .eq. 0.0) then 
                beta_acx(i,j) = C_bed_ac**exp1
            else 
                beta_acx(i,j) = C_bed_ac**exp1 * uxy_b_ac**exp2 
            end if  

        end do
        end do
        
        ! y-direction 
        do j = 1, ny-1
        do i = 1, nx

            i1 = max(i-1,1) 
            
            ! Get bed roughness on ac-node 
            C_bed_ac = 0.5_prec*(C_bed(i,j)+C_bed(i,j+1))  

            ! Calculate magnitude of basal velocity on Ac node 
            ! uy is defined on ac-node, get ux on the uy Ac node 
            uy_b_ac  = uy_b(i,j)
            ux_b_ac  = 0.25_prec*(ux_b(i,j)+ux_b(i1,j)+ux_b(i,j+1)+ux_b(i1,j+1))
            uxy_b_ac = (ux_b_ac**2 + uy_b_ac**2 + u_b_min**2)**0.5

            ! Nonlinear beta as a function of basal velocity (unless m==1)
            if (uxy_b_ac .eq. 0.0) then 
                beta_acy(i,j) =  C_bed_ac**exp1 
            else 
                beta_acy(i,j) =  C_bed_ac**exp1 * uxy_b_ac**exp2 
            end if  

        end do
        end do
        
        return
        
    end subroutine calc_beta_ac_power
    
    subroutine scale_beta_ac_binary(beta_acx,beta_acy,f_grnd_acx,f_grnd_acy)
        ! Modify basal friction coefficient by grounded/floating binary mask
        ! (via the grounded fraction)

        implicit none
        
        real(prec), intent(INOUT) :: beta_acx(:,:)   ! ac-nodes
        real(prec), intent(INOUT) :: beta_acy(:,:)   ! ac-nodes
        real(prec), intent(IN)    :: f_grnd_acx(:,:) ! ac-nodes
        real(prec), intent(IN)    :: f_grnd_acy(:,:) ! ac-nodes
        
        ! Local variables
        integer    :: i, j, nx, ny

        nx = size(f_grnd_acx,1)
        ny = size(f_grnd_acx,2) 

        ! acx-nodes 
        do j = 1, ny 
        do i = 1, nx-1

            if (f_grnd_acx(i,j) .lt. 1.0) beta_acx(i,j) = 0.0 

        end do 
        end do 

        beta_acx(nx,:) = beta_acx(nx-1,:) 

        ! acy-nodes 
        do j = 1, ny-1 
        do i = 1, nx

            if (f_grnd_acy(i,j) .lt. 1.0) beta_acy(i,j) = 0.0 

        end do 
        end do 
        
        beta_acy(:,ny) = beta_acy(:,ny-1) 

        return
        
    end subroutine scale_beta_ac_binary
    
    subroutine scale_beta_ac_fraction(beta_acx,beta_acy,f_grnd_acx,f_grnd_acy)
        ! Modify basal friction coefficient by grounded ice fraction at grounding line

        implicit none
        
        real(prec), intent(INOUT) :: beta_acx(:,:)   ! ac-nodes
        real(prec), intent(INOUT) :: beta_acy(:,:)   ! ac-nodes
        real(prec), intent(IN)    :: f_grnd_acx(:,:) ! ac-nodes
        real(prec), intent(IN)    :: f_grnd_acy(:,:) ! ac-nodes
        
        ! Local variables
        integer    :: i, j, nx, ny

        nx = size(f_grnd_acx,1)
        ny = size(f_grnd_acx,2) 

        ! acx-nodes 
        do j = 1, ny 
        do i = 1, nx-1

            beta_acx(i,j) = f_grnd_acx(i,j) * beta_acx(i,j)

        end do 
        end do 

        beta_acx(nx,:) = beta_acx(nx-1,:) 

        ! acy-nodes 
        do j = 1, ny-1 
        do i = 1, nx

            beta_acy(i,j) = f_grnd_acy(i,j) * beta_acy(i,j)

        end do 
        end do 
        
        beta_acy(:,ny) = beta_acy(:,ny-1) 

        return
        
    end subroutine scale_beta_ac_fraction
    
    subroutine scale_beta_ac_Neff(beta_acx,beta_acy,N_eff)
        ! Calculate scalar between 0 and 1 to modify basal friction coefficient
        ! as ice approaches and achieves floatation, and apply.
        
        implicit none
        
        real(prec), intent(INOUT) :: beta_acx(:,:)    ! ac-nodes
        real(prec), intent(INOUT) :: beta_acy(:,:)    ! ac-nodes
        real(prec), intent(IN)    :: N_eff(:,:)       ! aa-nodes, [bar]     

        ! Local variables
        integer    :: i, j, nx, ny 
        real(prec) :: N_eff_mid 

        nx = size(beta_acx,1)
        ny = size(beta_acx,2) 

        ! acx-nodes 
        do j = 1, ny 
        do i = 1, nx-1 

            N_eff_mid     = 0.5_prec*(N_eff(i,j)+N_eff(i+1,j))
            beta_acx(i,j) = N_eff_mid * beta_acx(i,j) 

        end do 
        end do  

        ! acy-nodes 
        do j = 1, ny-1 
        do i = 1, nx 

            N_eff_mid     = 0.5_prec*(N_eff(i,j)+N_eff(i,j+1))
            beta_acy(i,j) = N_eff_mid * beta_acy(i,j) 

        end do 
        end do  

        return
        
    end subroutine scale_beta_ac_Neff

    subroutine scale_beta_ac_Hgrnd(beta_acx,beta_acy,H_grnd,H_grnd_lim)
        ! Calculate scalar between 0 and 1 to modify basal friction coefficient
        ! as ice approaches and achieves floatation, and apply.
        
        implicit none
        
        real(prec), intent(INOUT) :: beta_acx(:,:)    ! ac-nodes
        real(prec), intent(INOUT) :: beta_acy(:,:)    ! ac-nodes
        real(prec), intent(IN)    :: H_grnd(:,:)      ! aa-nodes
        real(prec), intent(IN)    :: H_grnd_lim       

        ! Local variables
        integer    :: i, j, nx, ny
        real(prec) :: H_grnd_mid 
        real(prec) :: f_scale 

        nx = size(H_grnd,1)
        ny = size(H_grnd,2) 

        ! Consistency check 
        if (H_grnd_lim .le. 0.0) then 
            write(*,*) "scale_beta_ac_Hgrnd:: Error: H_grnd_lim must be positive."
            write(*,*) "H_grnd_lim = ", H_grnd_lim
            stop 
        end if 

        ! acx-nodes 
        do j = 1, ny 
        do i = 1, nx-1 

            H_grnd_mid    = 0.5_prec*(H_grnd(i,j)+H_grnd(i+1,j))

            f_scale       = max( min(H_grnd_mid,H_grnd_lim)/H_grnd_lim, 0.0) 

            beta_acx(i,j) = f_scale * beta_acx(i,j) 

        end do 
        end do  

        ! acy-nodes 
        do j = 1, ny-1 
        do i = 1, nx 

            H_grnd_mid    = 0.5_prec*(H_grnd(i,j)+H_grnd(i,j+1))

            f_scale       = max( min(H_grnd_mid,H_grnd_lim)/H_grnd_lim, 0.0) 

            beta_acy(i,j) = f_scale * beta_acy(i,j) 

        end do 
        end do  

        return
        
    end subroutine scale_beta_ac_Hgrnd
    
    subroutine scale_beta_ac_zstar(beta_acx,beta_acy,H_ice,z_bed,z_sl,norm)
        ! Calculate scalar between 0 and 1 to modify basal friction coefficient
        ! as ice approaches and achieves floatation, and apply.
        ! Following "Zstar" approach of Gladstone et al. (2017) 
        
        implicit none
        
        real(prec), intent(INOUT) :: beta_acx(:,:)    ! ac-nodes
        real(prec), intent(INOUT) :: beta_acy(:,:)    ! ac-nodes
        real(prec), intent(IN)    :: H_ice(:,:)       ! aa-nodes
        real(prec), intent(IN)    :: z_bed(:,:)       ! aa-nodes        
        real(prec), intent(IN)    :: z_sl(:,:)        ! aa-nodes        
        logical,    intent(IN)    :: norm             ! Normalize by H_ice? 

        ! Local variables
        integer    :: i, j, nx, ny
        real(prec) :: H_ice_mid, z_bed_mid, z_sl_mid 
        real(prec) :: f_scale 
        real(prec) :: rho_sw_ice 

        rho_sw_ice = rho_sw / rho_ice 

        nx = size(H_ice,1)
        ny = size(H_ice,2) 

        ! acx-nodes 
        do j = 1, ny 
        do i = 1, nx-1 

            H_ice_mid    = 0.5_prec*(H_ice(i,j)+H_ice(i+1,j))
            z_bed_mid    = 0.5_prec*(z_bed(i,j)+z_bed(i+1,j))
            z_sl_mid     = 0.5_prec*(z_sl(i,j)+z_sl(i+1,j))
            
            if (z_bed_mid > z_sl_mid) then 
                ! Land based above sea level 
                f_scale = H_ice_mid 
            else
                ! Marine based 
                f_scale = max(0.0_prec, H_ice_mid - (z_sl_mid-z_bed_mid)*rho_sw_ice)
            end if 

            if (norm .and. H_ice_mid .gt. 0.0) f_scale = f_scale / H_ice_mid 

            beta_acx(i,j) = f_scale * beta_acx(i,j) 

        end do 
        end do  

        ! acy-nodes 
        do j = 1, ny-1 
        do i = 1, nx 

            H_ice_mid    = 0.5_prec*(H_ice(i,j)+H_ice(i,j+1))
            z_bed_mid    = 0.5_prec*(z_bed(i,j)+z_bed(i,j+1))
            z_sl_mid     = 0.5_prec*(z_sl(i,j)+z_sl(i,j+1))
            
            if (z_bed_mid > z_sl_mid) then 
                ! Land based above sea level 
                f_scale = H_ice_mid 
            else
                ! Marine based 
                f_scale = max(0.0_prec, H_ice_mid - (z_sl_mid-z_bed_mid)*rho_sw_ice)
            end if 

            if (norm .and. H_ice_mid .gt. 0.0) f_scale = f_scale / H_ice_mid 
            
            beta_acy(i,j) = f_scale * beta_acy(i,j) 

        end do 
        end do  

        return
        
    end subroutine scale_beta_ac_zstar
    
    subroutine scale_beta_ac_l14(beta_acx,beta_acy,ux_b,uy_b,ATT_base,H_ice,z_bed,z_sl,H_w,m_drag,p,m_max,lambda_max)
        ! Calculate scalar between 0 and 1 to modify basal friction coefficient
        ! as ice approaches and achieves floatation, and apply.
        ! Following Leguy et al. (2014), Eq. 15

        ! ajr: This scaling causes crashing for MISMIP3D, something is wrong!! 
        
        implicit none
        
        real(prec), intent(INOUT) :: beta_acx(:,:)    ! ac-nodes
        real(prec), intent(INOUT) :: beta_acy(:,:)    ! ac-nodes
        real(prec), intent(INOUT) :: ux_b(:,:)        ! ac-nodes
        real(prec), intent(INOUT) :: uy_b(:,:)        ! ac-nodes
        real(prec), intent(IN)    :: ATT_base(:,:)    ! aa-nodes
        real(prec), intent(IN)    :: H_ice(:,:)       ! aa-nodes
        real(prec), intent(IN)    :: z_bed(:,:)       ! aa-nodes        
        real(prec), intent(IN)    :: z_sl(:,:)        ! aa-nodes        
        real(prec), intent(IN)    :: H_w(:,:)         ! aa-nodes
        real(prec), intent(IN)    :: m_drag           ! Dragging law exponent 
        real(prec), intent(IN)    :: p                ! [0:1], 0: no ocean connectivity, 1: full ocean connectivity
        real(prec), intent(IN)    :: m_max            ! Maximum bed obstacle slope (0-1?) 
        real(prec), intent(IN)    :: lambda_max       ! [m] Wavelength of bedrock bumps

        ! Local variables
        integer    :: i, j, nx, ny
        real(prec) :: H_ice_mid, z_bed_mid, z_sl_mid, H_w_mid 
        real(prec) :: Neff_mid, ATT_base_mid, uxy_b  
        real(prec) :: f_scale 
        real(prec) :: rho_sw_ice 

        rho_sw_ice = rho_sw / rho_ice 

        nx = size(H_ice,1)
        ny = size(H_ice,2) 

        ! acx-nodes 
        do j = 2, ny 
        do i = 1, nx-1 

            H_ice_mid     = 0.5_prec*(H_ice(i,j)+H_ice(i+1,j))
            z_bed_mid     = 0.5_prec*(z_bed(i,j)+z_bed(i+1,j))
            z_sl_mid      = 0.5_prec*(z_sl(i,j)+z_sl(i+1,j))
            H_w_mid       = 0.5_prec*(H_w(i,j)+H_w(i+1,j))
            ATT_base_mid  = 0.5_prec*(ATT_base(i,j)+ATT_base(i+1,j))
            
            Neff_mid      = calc_effective_pressure(H_ice_mid,z_bed_mid,z_sl_mid,H_w_mid,p)
            uxy_b         = sqrt(ux_b(i,j)**2 + (0.25_prec*(uy_b(i,j)+uy_b(i+1,j)+uy_b(i,j-1)+uy_b(i+1,j-1)))**2)

            f_scale       = calc_l14_scalar(Neff_mid,uxy_b,ATT_base_mid,m_drag,m_max,lambda_max)

            beta_acx(i,j) = f_scale * beta_acx(i,j) 

        end do 
        end do  

        beta_acx(:,1) = beta_acx(:,2) 

        ! acy-nodes 
        do j = 1, ny-1 
        do i = 1, nx 

            H_ice_mid     = 0.5_prec*(H_ice(i,j)+H_ice(i,j+1))
            z_bed_mid     = 0.5_prec*(z_bed(i,j)+z_bed(i,j+1))
            z_sl_mid      = 0.5_prec*(z_sl(i,j)+z_sl(i,j+1))
            H_w_mid       = 0.5_prec*(H_w(i,j)+H_w(i,j+1))
            ATT_base_mid  = 0.5_prec*(ATT_base(i,j)+ATT_base(i,j+1))
            
            Neff_mid      = calc_effective_pressure(H_ice_mid,z_bed_mid,z_sl_mid,H_w_mid,p)
            uxy_b         = sqrt(uy_b(i,j)**2 + (0.25_prec*(ux_b(i,j)+ux_b(i,j+1)+ux_b(i-1,j)+ux_b(i-1,j+1)))**2)

            f_scale       = calc_l14_scalar(Neff_mid,uxy_b,ATT_base_mid,m_drag,m_max,lambda_max)

            beta_acy(i,j) = f_scale * beta_acy(i,j) 

        end do 
        end do  

        return
        
    end subroutine scale_beta_ac_l14
    
    function calc_l14_scalar(N_eff,uxy_b,ATT_base,m_drag,m_max,lambda_max) result(f_np)
        ! Calculate a friction scaling coefficient as a function
        ! of velocity and effective pressure, following
        ! Leguy et al. (2014), Eq. 15

        ! Note: input is for a given point, should be on central aa-nodes
        ! or shifted to ac-nodes before entering this routine 

        ! Note: this routine is untested and so far, not used (ajr, 2019-02-01)
        
        implicit none 

        real(prec), intent(IN) :: N_eff 
        real(prec), intent(IN) :: uxy_b 
        real(prec), intent(IN) :: ATT_base 
        real(prec), intent(IN) :: m_drag     
        real(prec), intent(IN) :: m_max 
        real(prec), intent(IN) :: lambda_max 
        real(prec) :: f_np 

        ! Local variables 
        real(prec) :: kappa 

        ! Calculate the velocity scaling 
        kappa = m_max / (lambda_max*ATT_base)

        ! Calculate the scaling coeffcient 
        f_np = (N_eff**m_drag / (kappa*uxy_b + N_eff**m_drag))**1/m_drag 

        if (f_np .lt. 0.0 .or. f_np .gt. 1.0) then 
            write(*,*) "calc_l14_scalar:: f_np out of bounds: f_np = ", f_np 
            stop 
        end if 

        return 

    end function calc_l14_scalar

end module basal_dragging 
