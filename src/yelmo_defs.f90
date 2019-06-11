module yelmo_defs
    
    use nml 

    implicit none 

    ! =========================================================================
    !
    ! CONSTANTS (program precision, global constants)
    !
    ! =========================================================================

    ! Internal constants
    integer,  parameter :: dp  = kind(1.d0)
    integer,  parameter :: sp  = kind(1.0)

    ! Choose the precision of the library (sp,dp)
    integer,  parameter :: prec = sp 

    ! Missing value and aliases
    real(prec), parameter :: MISSING_VALUE_DEFAULT = real(-9999.0,prec)
    real(prec), parameter :: MISSING_VALUE = MISSING_VALUE_DEFAULT
    real(prec), parameter :: MV = MISSING_VALUE_DEFAULT
    
    ! Error distance (very large), error index, and smallest number epsilon 
    real(prec), parameter :: ERR_DIST = real(1E8,prec) 
    integer,    parameter :: ERR_IND  = -1 
    real(prec), parameter :: eps      = real(1E-8,prec) 
    
    ! Mathematical constants
    real(prec), parameter :: pi  = real(2._dp*acos(0.0_dp),prec)
    real(prec), parameter :: degrees_to_radians = real(pi / 180._dp,prec)  ! Conversion factor between radians and degrees
    real(prec), parameter :: radians_to_degrees = real(180._dp / pi,prec)  ! Conversion factor between degrees and radians
    
    ! The constants below should be loaded using the global subroutine
    ! defined below `yelmo_constants_load`.
    ! Note: The key limitation imposed by defining the parameters defined 
    ! globally is that these constants must be the same for all domains 
    ! being run in the same program. 

    ! Yelmo configuration options 
    logical :: yelmo_write_log

    ! Physical constants 
    real(prec) :: sec_year       ! [s] seconds per year 
    real(prec) :: g              ! Gravitational accel.  [m s-2]
    real(prec) :: T0             ! Reference freezing temperature [K] 
    real(prec) :: rho_ice        ! Density ice           [kg m-3] 
    real(prec) :: rho_w          ! Density water         [kg m-3] 
    real(prec) :: rho_sw         ! Density seawater      [kg m-3] 
    real(prec) :: rho_a          ! Density asthenosphere [kg m-3] 
    real(prec) :: rho_m          ! Density mantle (lith) [kg m-3]
    real(prec) :: L_ice          ! Latent heat           [J kg-1]

    ! Internal parameters 
    real(prec) :: conv_we_ie        ! Conversion water equiv. => m/a ice equiv. 
    real(prec) :: conv_mmdwe_maie   ! Conversion mm/d water equiv. => m/a ice equiv.
    real(prec) :: conv_mmawe_maie   ! Conversion mm/a water equiv. => m/a ice equiv. 
    
    ! =========================================================================
    !
    ! YELMO objects: ytopo 
    !
    ! =========================================================================
    
    ! ytopo parameters
    type ytopo_param_class
        character(len=256) :: name, method, init, solver
        logical            :: margin2nd 
        integer            :: surf_gl_method 
        character(len=256) :: calv_method  
        character(len=256) :: boundaries 
        integer            :: nx, ny
        real(prec)         :: dx, dy
        
        logical    :: use_bmb  
        logical    :: use_calv_subgrid 
        logical    :: ocean_kill  
        logical    :: grline_fixed 
        logical    :: topo_fixed
        real(prec) :: topo_relax_dt, topo_fixed_dt
        real(prec) :: calv_dt 
        real(prec) :: H_calv 
        real(prec) :: H_min 
        integer    :: gl_sep 
        integer    :: gl_sep_nx 
        logical    :: diffuse_bmb_shlf 

        ! Internal parameters 
        real(prec) :: time 
        real(prec) :: time_calv 
        
    end type

    ! ytopo state variables
    type ytopo_state_class
        ! Model variables that the define the state of the domain 

        real(prec), allocatable :: H_ice(:,:)      ! Ice thickness [m] 
        real(prec), allocatable :: z_srf(:,:)      ! Surface elevation [m]
        real(prec), allocatable :: dzsrfdt(:,:)    ! Surface elevation rate of change [m/a] 
        real(prec), allocatable :: dHicedt(:,:)    ! Ice thickness rate of change [m/a] 
        real(prec), allocatable :: bmb(:,:)        ! Combined field of bmb_grnd and bmb_shlf 
        real(prec), allocatable :: mb_applied(:,:) ! Actual mass balance applied [m/a], for mass balance accounting
        real(prec), allocatable :: calv(:,:)       ! Calving [m/a]
        real(prec), allocatable :: calv_mean(:,:)  ! Calving [m/a]
        real(prec), allocatable :: calv_times(:)   ! Calving

        real(prec), allocatable :: dzsdx(:,:)      ! Surface elevation slope [m m-1], Ac x nodes
        real(prec), allocatable :: dzsdy(:,:)      ! Surface elevation slope [m m-1], Ac y nodes
        real(prec), allocatable :: dHicedx(:,:)    ! Ice thickness gradient slope [m m-1], Ac x nodes
        real(prec), allocatable :: dHicedy(:,:)    ! Ice thickness gradient slope [m m-1], Ac y nodes
        
        real(prec), allocatable :: H_grnd(:,:)       ! Ice thickness overburden [m]
        
        ! Masks 
        real(prec), allocatable :: f_grnd(:,:)       ! Grounded fraction (grounding line fraction between 0 and 1)
        real(prec), allocatable :: f_grnd_acx(:,:)   ! Grounded fraction (acx nodes)
        real(prec), allocatable :: f_grnd_acy(:,:)   ! Grounded fraction (acy nodes)
        real(prec), allocatable :: f_ice(:,:)        ! Ice-covered fraction 

        real(prec), allocatable :: dist_margin(:,:)  ! Distance to nearest margin point 
        real(prec), allocatable :: dist_grline(:,:)  ! Distance to nearest grounding-line point 
        
        ! Additional masks 
        integer,    allocatable :: mask_bed(:,:)    ! Multi-valued bed mask
        logical,    allocatable :: is_float(:,:)    ! Fully floating grid points
        logical,    allocatable :: is_grline(:,:)   ! Grounding line points
        logical,    allocatable :: is_grz(:,:)      ! Grounding line plus grounded neighbors
        
    end type

    ! ytopo class
    type ytopo_class

        type(ytopo_param_class) :: par        ! Parameters
        type(ytopo_state_class) :: now        ! Variables

    end type

    ! =========================================================================
    !
    ! YELMO objects: ydyn 
    !
    ! =========================================================================
    
    ! ydyn parameters
    type ydyn_param_class

        character(len=256) :: solver 
        integer    :: mix_method            ! Method for mixing sia and ssa velocity solutions
        logical    :: calc_diffusivity      ! Calculate diagnostic diffusivity field
        real(prec) :: m_drag                ! Sliding law exponent (m==1: plastic)
        real(prec) :: u_0                   ! [m/a] Regularized coulomb friction velocity 
        real(prec) :: beta_max              ! Maximum value of beta for which ssa should be calculated
        integer    :: beta_method
        real(prec) :: beta_const
        integer    :: beta_gl_sep           ! Beta grounding-line subelement (subgrid) parameterization
        integer    :: beta_gl_scale         ! Beta grounding-line scaling method (beta => 0 at gl?)
        integer    :: beta_gl_stag          ! Beta grounding-line staggering method 
        real(prec) :: f_beta_gl             ! Fraction of beta at gl 
        integer    :: taud_gl_method        ! Driving stress grounding line treatment 
        real(prec) :: H_grnd_lim 
        real(prec) :: H_sed_sat
        integer    :: C_bed_method 
        real(prec) :: C_bed_z0  
        real(prec) :: C_bed_z1 
        real(prec) :: cf_stream
        real(prec) :: cf_frozen
        real(prec) :: cf_fac_sed
        real(prec) :: cf_sia
        logical    :: streaming_margin      ! Ensure margin and grline are considered streaming?
        integer    :: n_sm_beta 
        real(prec) :: ssa_vel_max
        integer    :: ssa_iter_max 
        real(prec) :: ssa_iter_rel 
        real(prec) :: ssa_iter_conv 

        integer    :: neff_method
        real(prec) :: neff_p 
        logical    :: neff_use_water 
        real(prec) :: neff_w_max
        real(prec) :: neff_N0
        real(prec) :: neff_delta 
        real(prec) :: neff_e0 
        real(prec) :: neff_Cc 

        real(prec) :: till_phi_min 
        real(prec) :: till_phi_max 
        real(prec) :: till_phi_zmin 
        real(prec) :: till_phi_zmax 
        
        ! Internal parameters 
        character(len=256) :: boundaries 
        logical    :: use_ssa                    ! Should ssa be used? 
        logical    :: use_bmb                    ! Set to match `use_bmb` in ytopo_param_class 
        real(prec) :: n_glen                     ! Flow law exponent (n_glen=3)
        integer    :: nx, ny, nz_aa, nz_ac 
        real(prec) :: dx, dy
        real(prec), allocatable :: zeta_aa(:)   ! Layer centers (aa-nodes), plus base and surface: nz_aa points 
        real(prec), allocatable :: zeta_ac(:)   ! Layer borders (ac-nodes), plus base and surface: nz_ac == nz_aa-1 points
        real(prec) :: time

    end type

    ! ydyn state variables
    type ydyn_state_class
        ! Model variables that the define the state of the domain 

        real(prec), allocatable :: ux(:,:,:) 
        real(prec), allocatable :: uy(:,:,:) 
        real(prec), allocatable :: uxy(:,:,:)
        real(prec), allocatable :: uz(:,:,:)  

        real(prec), allocatable :: ux_bar(:,:) 
        real(prec), allocatable :: uy_bar(:,:)
        real(prec), allocatable :: uxy_bar(:,:)

        real(prec), allocatable :: ux_b(:,:) 
        real(prec), allocatable :: uy_b(:,:)
        real(prec), allocatable :: uxy_b(:,:)

        ! Surface velocity: eventually these could be pointers since it is simply
        ! the top layer in ux(:,:,:), etc. and only used, not calculated.
        real(prec), allocatable :: ux_s(:,:) 
        real(prec), allocatable :: uy_s(:,:)
        real(prec), allocatable :: uxy_s(:,:)
        
        real(prec), allocatable :: ux_i(:,:,:) 
        real(prec), allocatable :: uy_i(:,:,:)
        real(prec), allocatable :: ux_i_bar(:,:) 
        real(prec), allocatable :: uy_i_bar(:,:)
        real(prec), allocatable :: uxy_i_bar(:,:) 
        
        real(prec), allocatable :: dd_ab(:,:,:)  
        real(prec), allocatable :: dd_ab_bar(:,:)  
        
        real(prec), allocatable :: sigma_horiz_sq(:,:)
        real(prec), allocatable :: lhs_x(:,:) 
        real(prec), allocatable :: lhs_y(:,:) 
        real(prec), allocatable :: lhs_xy(:,:) 

        real(prec), allocatable :: duxdz(:,:,:) 
        real(prec), allocatable :: duydz(:,:,:)
        real(prec), allocatable :: duxdz_bar(:,:) 
        real(prec), allocatable :: duydz_bar(:,:)

        real(prec), allocatable :: taud_acx(:,:) 
        real(prec), allocatable :: taud_acy(:,:) 
        real(prec), allocatable :: taud(:,:) 
        
        real(prec), allocatable :: taub_acx(:,:) 
        real(prec), allocatable :: taub_acy(:,:) 
        real(prec), allocatable :: taub(:,:)
        
        real(prec), allocatable :: qq_gl_acx(:,:) 
        real(prec), allocatable :: qq_gl_acy(:,:) 
        
        real(prec), allocatable :: qq_acx(:,:) 
        real(prec), allocatable :: qq_acy(:,:) 
        real(prec), allocatable :: qq(:,:)
        
        real(prec), allocatable :: visc_eff(:,:)

        real(prec), allocatable :: N_eff(:,:)       ! Effective pressure
        real(prec), allocatable :: C_bed(:,:)  
        real(prec), allocatable :: beta_acx(:,:) 
        real(prec), allocatable :: beta_acy(:,:) 
        real(prec), allocatable :: beta(:,:) 
        
        real(prec), allocatable :: f_vbvs(:,:) 

        integer,    allocatable :: ssa_mask_acx(:,:) 
        integer,    allocatable :: ssa_mask_acy(:,:) 

        integer,    allocatable :: gfa1(:,:) 
        logical,    allocatable :: gfa2(:,:) 
        logical,    allocatable :: gfb1(:,:) 
        logical,    allocatable :: gfb2(:,:) 
        
    end type

    ! ydyn class
    type ydyn_class

        type(ydyn_param_class)    :: par        ! physical parameters
        type(ydyn_state_class)    :: now

    end type

    ! =========================================================================
    !
    ! YELMO objects: ymat 
    !
    ! =========================================================================
    
    type strain_2D_class 
        real(prec), allocatable :: dxx(:,:) 
        real(prec), allocatable :: dyy(:,:) 
        real(prec), allocatable :: dxy(:,:) 
        real(prec), allocatable :: de(:,:) 
    end type 

    type strain_3D_class 
        real(prec), allocatable :: dxx(:,:,:) 
        real(prec), allocatable :: dyy(:,:,:) 
        real(prec), allocatable :: dzz(:,:,:)
        real(prec), allocatable :: dxy(:,:,:) 
        real(prec), allocatable :: dxz(:,:,:) 
        real(prec), allocatable :: dyz(:,:,:) 
        real(prec), allocatable :: de(:,:,:) 
        real(prec), allocatable :: f_shear(:,:,:) 
    end type 
    
    type ymat_param_class
        
        character(len=56) :: flow_law
        integer    :: rf_method 
        real(prec) :: rf_const
        logical    :: rf_use_eismint2
        real(prec) :: n_glen                     ! Flow law exponent (n_glen=3)
        real(prec) :: visc_min  
        logical    :: use_2D_enh
        real(prec) :: enh_shear
        real(prec) :: enh_stream
        real(prec) :: enh_shlf
        
        
        character(len=56) :: age_method  
        real(prec)        :: age_impl_kappa

        ! Internal parameters
        real(prec) :: time 
        logical    :: calc_age
        real(prec) :: dx, dy  
        integer    :: nx, ny, nz_aa, nz_ac  

        real(prec), allocatable :: zeta_aa(:)   ! Layer centers (aa-nodes), plus base and surface: nz_aa points 
        real(prec), allocatable :: zeta_ac(:)   ! Layer borders (ac-nodes), plus base and surface: nz_ac == nz_aa-1 points
        
    end type 

    type ymat_state_class 

        type(strain_2D_class)   :: strn2D
        type(strain_3D_class)   :: strn 

        real(prec), allocatable :: enh(:,:,:)
        real(prec), allocatable :: enh_bar(:,:)
        real(prec), allocatable :: ATT(:,:,:) 
        real(prec), allocatable :: ATT_bar(:,:)
        real(prec), allocatable :: visc(:,:,:) 
        real(prec), allocatable :: visc_int(:,:) 

        real(prec), allocatable :: f_shear_bar(:,:) 
        
        real(prec), allocatable :: dep_time(:,:,:)    ! Ice deposition time (for online age tracing)

    end type 

    type ymat_class
        type(ymat_param_class) :: par 
        type(ymat_state_class) :: now 
    end type

    ! =========================================================================
    !
    ! YELMO objects: ytherm 
    !
    ! =========================================================================
    
    !ytherm parameters 
    type ytherm_param_class
        character(len=256)  :: method 
        logical             :: cond_bed 
        integer             :: nx, ny 
        real(prec)          :: dx, dy  
        integer             :: nz_aa     ! Number of vertical points in ice (layer centers, plus base and surface)
        integer             :: nz_ac     ! Number of vertical points in ice (layer boundaries)
        integer             :: nzr       ! Number of vertical points in bedrock 
        real(prec)          :: gamma  
        real(prec)          :: dzr       ! Vertical resolution in bedrock [m]
        real(prec)          :: H_rock    ! Total bedrock thickness [m] - determined as (nzr-1)*dzr 
        
        integer             :: n_sm_qstrn    ! Standard deviation (in points) for Gaussian smoothing of strain heating
        logical             :: use_strain_sia 
        logical             :: use_const_cp 
        real(prec)          :: const_cp 
        logical             :: use_const_kt 
        real(prec)          :: const_kt 
        real(prec)          :: kt_m        ! Thermal conductivity of mantle [J a-1 m-1 K-1]    
        real(prec)          :: cp_m        ! Specific heat capacity of mantle [J Kg-1 K-1]
        real(prec)          :: rho_m       ! Density of the mantle [kg m-3]

        real(prec), allocatable :: zeta_aa(:)   ! Layer centers (aa-nodes), plus base and surface: nz_aa points 
        real(prec), allocatable :: zeta_ac(:)   ! Layer borders (ac-nodes), plus base and surface: nz_ac == nz_aa-1 points
        real(prec), allocatable :: zetar(:) 

        real(prec), allocatable :: dzeta_a(:)
        real(prec), allocatable :: dzeta_b(:)
        
        real(prec) :: time

    end type

    ! ytherm state variables
    type ytherm_state_class
        real(prec), allocatable :: T_ice(:,:,:)     ! Ice temp. 
        real(prec), allocatable :: enth_ice(:,:,:)  ! Ice enthalpy 
        real(prec), allocatable :: omega_ice(:,:,:) ! Ice water content
        real(prec), allocatable :: T_pmp(:,:,:)     ! Pressure-corrected melting point
        real(prec), allocatable :: phid(:,:)        ! Heat flow related to deformation and basal slip (from grisli)
        real(prec), allocatable :: f_pmp(:,:)       ! fraction of cell at pressure melting point
        real(prec), allocatable :: bmb_grnd(:,:)    ! Grounded basal mass balance 
        real(prec), allocatable :: Q_strn(:,:,:)    ! Internal heat production 
        real(prec), allocatable :: Q_b(:,:)         ! Basal friction heat production
        real(prec), allocatable :: cp(:,:,:)        ! Specific heat capacity  
        real(prec), allocatable :: kt(:,:,:)        ! Heat conductivity  
        
        real(prec), allocatable :: T_rock(:,:,:)    ! Bedrock temp.
        real(prec), allocatable :: dTdz_b(:,:)      ! Temp. gradient in ice at base (positive up)
        real(prec), allocatable :: dTrdz_b(:,:)     ! Temp. gradient in rock at base (positive up)
        real(prec), allocatable :: T_prime_b(:,:)   ! Homologous temperature at the base 
        real(prec), allocatable :: cts(:,:)         ! Height of the cts
        real(prec), allocatable :: T_all(:,:,:) 
        
    end type

    ! ytherm class
    type ytherm_class

        type(ytherm_param_class)   :: par        ! physical parameters
        type(ytherm_state_class)   :: now

    end type

    ! =========================================================================
    !
    ! YELMO objects: ybound
    !
    ! =========================================================================
    
    ! ybnd variables (intent IN)
    type ybound_class

        ! Region constants
        real(prec) :: index_north = 1.0   ! Northern Hemisphere region number
        real(prec) :: index_south = 2.0   ! Antarctica region number
        real(prec) :: index_grl   = 1.3   ! Greenland region number

        ! Variables that save the current boundary conditions
        real(prec), allocatable :: z_bed(:,:)
        real(prec), allocatable :: z_sl(:,:)
        real(prec), allocatable :: H_sed(:,:)
        real(prec), allocatable :: H_w(:,:)
        real(prec), allocatable :: smb(:,:)
        real(prec), allocatable :: T_srf(:,:)
        real(prec), allocatable :: bmb_shlf(:,:)
        real(prec), allocatable :: T_shlf(:,:)
        real(prec), allocatable :: Q_geo(:,:)

        ! Useful masks
        real(prec), allocatable :: basins(:,:) 
        real(prec), allocatable :: basin_mask(:,:)
        real(prec), allocatable :: regions(:,:) 
        real(prec), allocatable :: region_mask(:,:) 

        logical, allocatable    :: ice_allowed(:,:)    ! Locations where ice thickness can be greater than zero 

        ! Other external variables that can be useful, ie maybe with tracers
        ! to do 

    end type

    ! =========================================================================
    !
    ! YELMO objects: ydata
    !
    ! =========================================================================
    
    type ydata_param_class 
        logical             :: pd_topo_load 
        character(len=1028) :: pd_topo_path 
        character(len=56)   :: pd_topo_names(3)
        logical             :: pd_tsrf_load  
        character(len=1028) :: pd_tsrf_path 
        character(len=56)   :: pd_tsrf_name
        logical             :: pd_tsrf_monthly
        logical             :: pd_smb_load 
        character(len=1028) :: pd_smb_path 
        character(len=56)   :: pd_smb_name
        logical             :: pd_smb_monthly 
        logical             :: pd_vel_load  
        character(len=1028) :: pd_vel_path 
        character(len=56)   :: pd_vel_names(2) 
        
        character(len=56)   :: domain 
    end type 

    type ydata_pd_class   ! pd = present-day
        ! Variables that contain observations / reconstructions for comparison/inversion
        real(prec), allocatable :: H_ice(:,:), z_srf(:,:), z_bed(:,:) 
        real(prec), allocatable :: ux_s(:,:), uy_s(:,:), uxy_s(:,:) 
        real(prec), allocatable :: T_srf(:,:), smb(:,:) 
        ! Comparison metrics 
        real(prec), allocatable :: err_H_ice(:,:), err_z_srf(:,:), err_z_bed(:,:)
        real(prec), allocatable :: err_uxy_s(:,:)
        
    end type

    type ydata_class 
        type(ydata_param_class) :: par 
        type(ydata_pd_class)    :: pd 
    end type 

    ! =========================================================================
    !
    ! YELMO objects: yregions
    !
    ! =========================================================================
    
    ! yregions variables
    type yregions_class
        ! Individual values of interest to output from a Yelmo domain 

        ! ===== Total ice variables =====
        real(prec) :: H_ice, z_srf, dHicedt, H_ice_max, dzsrfdt
        real(prec) :: V_ice, A_ice, dVicedt, fwf
        real(prec) :: uxy_bar, uxy_s, uxy_b, z_bed, smb, T_srf, bmb

        ! ===== Grounded ice variables =====
        real(prec) :: H_ice_g, z_srf_g, V_ice_g, A_ice_g, uxy_bar_g, uxy_s_g, uxy_b_g
        real(prec) :: f_pmp, H_w, bmb_g 

        ! ===== Floating ice variables =====
        real(prec) :: H_ice_f, V_ice_f, A_ice_f, uxy_bar_f, uxy_s_f, uxy_b_f, z_sl, bmb_shlf, T_shlf
        
    end type

    ! =========================================================================
    !
    ! YELMO objects: ygrid 
    !
    ! =========================================================================
    
    type ygrid_class 

        ! Grid name 
        character(len=256) :: name 
        
        ! Parameters
        integer    :: nx, ny, npts
        real(prec) :: dx, dy

        ! Projection parameters (optional)
        character(len=256) :: mtype 
        real(prec) :: lambda
        real(prec) :: phi
        real(prec) :: alpha
        real(prec) :: scale
        real(prec) :: x_e
        real(prec) :: y_n
        logical    :: is_projection 

        ! Axes
        real(prec), allocatable :: xc(:)    
        real(prec), allocatable :: yc(:) 

        ! Grid arrays 
        real(prec), allocatable :: x(:,:)
        real(prec), allocatable :: y(:,:)
        real(prec), allocatable :: lon(:,:)
        real(prec), allocatable :: lat(:,:)
        real(prec), allocatable :: area(:,:)
        
    end type 

    ! =========================================================================
    !
    ! YELMO objects: yelmo 
    !
    ! =========================================================================
    
    ! Define all parameters needed to represent a given domain
    type yelmo_param_class

        ! Domain and experiment definition
        character (len=256) :: domain
        character (len=256) :: grid_name
        character (len=512) :: grid_path
        character (len=256) :: experiment
        character (len=512) :: restart

        ! Vertical dimension definition
        character (len=56)  :: zeta_scale 
        real(prec)          :: zeta_exp 
        integer             :: nz_ac
        integer             :: nz_aa 

        ! Yelmo timesteps 
        real(prec)          :: dtmin
        real(prec)          :: dtmax
        integer             :: ntt
        real(prec)          :: dttmax 
        real(prec)          :: cfl_max 
        real(prec)          :: cfl_diff_max 

        ! Sigma coordinates (internal parameter)
        real(prec), allocatable :: zeta_aa(:)   ! Layer centers (aa-nodes), plus base and surface: nz_aa points 
        real(prec), allocatable :: zeta_ac(:)   ! Layer borders (ac-nodes), plus base and surface: nz_ac == nz_aa-1 points
        
        ! Other internal parameters
        real(prec), allocatable :: dt_adv(:,:) 
        real(prec), allocatable :: dt_diff(:,:) 
        real(prec), allocatable :: dt_adv3D(:,:,:)

        ! Timing information 
        real(prec) :: model_speed 
        real(prec) :: model_speeds(10)    ! Use 10 timesteps for running mean  

    end type

    ! Define the overall yelmo_class, which is a container for
    ! all information needed to model a given domain (eg, Greenland, Antarctica, NH)
    type yelmo_class
        type(yelmo_param_class) :: par      ! General domain parameters
        type(ygrid_class)       :: grd      ! Grid definition
        type(ytopo_class)       :: tpo      ! Topography variables
        type(ydyn_class)        :: dyn      ! Dynamics variables
        type(ymat_class)        :: mat      ! Material variables
        type(ytherm_class)      :: thrm     ! Thermodynamics variables
        type(ybound_class)      :: bnd      ! Boundary variables to drive model
        type(ydata_class)       :: dta      ! Data variables for comparison
        type(yregions_class)    :: reg      ! Regionally aggregated variables  
    end type

    public   ! All yelmo defs are public

contains 

    function yelmo_get_precision() result(yelmo_prec)

        implicit none 

        integer :: yelmo_prec 

        yelmo_prec = kind(prec)

        return 

    end function yelmo_get_precision

        
    subroutine yelmo_parse_path(path,domain,grid_name)

        implicit none 

        character(len=*), intent(INOUT) :: path 
        character(len=*), intent(IN)    :: domain, grid_name 

        call nml_replace(path,"{domain}",   trim(domain))
        call nml_replace(path,"{grid_name}",trim(grid_name))
        
        return 

    end subroutine yelmo_parse_path

    subroutine yelmo_global_init(filename)

        character(len=*), intent(IN)  :: filename
        
        ! Local variables
        logical :: init_pars 

        init_pars = .TRUE. 
        
        ! Load parameter values 

        call nml_read(filename,"yelmo_config","write_log",yelmo_write_log,  init=init_pars)
        
        call nml_read(filename,"yelmo_constants","sec_year",    sec_year,   init=init_pars)
        call nml_read(filename,"yelmo_constants","g",           g,          init=init_pars)
        call nml_read(filename,"yelmo_constants","T0",          T0,         init=init_pars)
        
        call nml_read(filename,"yelmo_constants","rho_ice",     rho_ice,    init=init_pars)
        call nml_read(filename,"yelmo_constants","rho_w",       rho_w,      init=init_pars)
        call nml_read(filename,"yelmo_constants","rho_sw",      rho_sw,     init=init_pars)
        call nml_read(filename,"yelmo_constants","rho_a",       rho_a,      init=init_pars)
        call nml_read(filename,"yelmo_constants","rho_m",       rho_m,      init=init_pars)
        call nml_read(filename,"yelmo_constants","L_ice",       L_ice,      init=init_pars)
        
        if (yelmo_write_log) then 
            write(*,*) "yelmo:: configuration:"
            write(*,*) "    write_log = ", yelmo_write_log

            write(*,*) "yelmo:: loaded global constants:"
            write(*,*) "    sec_year  = ", sec_year 
            write(*,*) "    g         = ", g 
            write(*,*) "    T0        = ", T0 
            write(*,*) "    rho_ice   = ", rho_ice 
            write(*,*) "    rho_w     = ", rho_w 
            write(*,*) "    rho_sw    = ", rho_sw 
            write(*,*) "    rho_a     = ", rho_a 
            write(*,*) "    rho_m     = ", rho_m 
            write(*,*) "    L_ice     = ", L_ice 
            
        end if 

        ! Define conversion factors too

        conv_we_ie  = rho_w/rho_ice
        conv_mmdwe_maie = 1e-3*365*conv_we_ie
        conv_mmawe_maie = 1e-3*conv_we_ie
        
        return

    end subroutine yelmo_global_init
    
    subroutine yelmo_load_command_line_args(path_par)
        ! Load the parameter filename from the command line 
        ! call eg: ./yelmo_test.x yelmo_Greenland.nml 

        implicit none 

        character(len=*), intent(OUT) :: path_par 

        ! Local variables 
        integer :: narg 

        narg = command_argument_count()

        if (narg .ne. 1) then 
            write(*,*) "yelmo_load_command_line_args:: Error: The following &
            &argument must be provided: path_par"
            stop 
        end if 

        call get_command_argument(1,path_par)

        return 

    end subroutine yelmo_load_command_line_args 

     subroutine yelmo_calc_speed(rate,rates,model_time0,model_time1,cpu_time0)
        ! Calculate the model computational speed [model-kyr / hr]
        ! Note: uses a running mean of rates over the last X steps, in order
        ! to provide a smoother estimate of the rate 

        implicit none 

        real(prec), intent(OUT)   :: rate        ! [kyr / hr]
        real(prec), intent(INOUT) :: rates(:)    ! [kyr / hr]

        real(prec), intent(IN) :: model_time0    ! [yr]
        real(prec), intent(IN) :: model_time1    ! [yr]
        real(prec), intent(IN) :: cpu_time0      ! [sec]
        
        ! Local variables
        integer    :: ntot, n 
        real(4)    :: cpu_time1      ! [sec]
        real(prec) :: rate_now 

        ! Get current time 
        call cpu_time(cpu_time1)

        if (model_time1 .gt. model_time0) then 
            ! Model has advanced in time, calculate rate 

            ! Calculate the model speed [model-yr / sec]
            rate_now = (model_time1-model_time0) / (cpu_time1-cpu_time0)

            ! Convert to more useful rate [model-kyr / hr]
            rate_now = rate_now*1e-3*3600.0 

        else 
            rate_now = 0.0 
        end if 

        ! Shift rates vector to eliminate oldest entry, and add current entry
        n = size(rates) 
        rates    = cshift(rates,1)
        rates(n) = rate_now 

        ! Calculate running average rate 
        n    = count(rates .gt. 0.0)
        if (n .gt. 0) then 
            rate = sum(rates,mask=rates .gt. 0.0) / real(n,prec) 
        else 
            rate = 0.0 
        end if 

        return 

    end subroutine yelmo_calc_speed 
    
end module yelmo_defs

