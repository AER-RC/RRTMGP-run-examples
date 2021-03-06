
subroutine stop_on_err(error_msg)
  use iso_fortran_env, only : error_unit
  character(len=*), intent(in) :: error_msg

  if(error_msg /= "") then
    write (error_unit,*) trim(error_msg)
    write (error_unit,*) "rrtmgp_default_atmos stopping"
    stop
  end if

end subroutine stop_on_err
!-----------------------------
!
! This example program computes clear-sky fluxes for the default atmospheres
!   (doi:10.1029/2000JD000184) used to train the RRTMGP gas optics.
! Users supply a file containing the atmospheres and relevant boundary conditions
!   (separately for LW and SW); the program invokes RRTMGP gas optics and
!   computes fluxes up, down, and net (down minus up) with RTE, as well as
!   heating rates. Fluxes are reported for the broadband as well as within each
!   spectral band defined by RRTMGP.
! The program expects files in a certain, arbitrary netCDF file. Results are added
!    to the file containing the inputs.
! The code does either LW or SW calculations; the boundary conditions in the file
!   describing the atmosphere need to be consistent with the absorption coefficient data
! The code divides the work into blocks of columns (user-configurable, default of 4)
!   which makes the code longer and more complciated than it might be but
!   useful for testing e.g. threading implementations.
!
program rrtmgp_default_atmos
  !
  ! Modules for working with rte and rrtmgp
  !
  ! Working precision for real variables
  !
  use mo_rte_kind,           only: wp
  !
  ! Optical properties of the atmosphere as array of values
  !   In the longwave we include only absorption optical depth (_1scl)
  !   Shortwave calculations would use optical depth, single-scattering albedo, asymmetry parameter (_2str)
  !
  use mo_optical_props,      only: ty_optical_props, &
                                   ty_optical_props_arry, ty_optical_props_1scl, ty_optical_props_2str
  !
  ! Gas optics: maps physical state of the atmosphere to optical properties
  !
  use mo_gas_optics_rrtmgp,         only: ty_gas_optics_rrtmgp
  !
  ! Gas optics uses a derived type to represent gas concentrations compactly...
  !
  use mo_gas_concentrations, only: ty_gas_concs
  !
  ! ... and another type to encapsulate the longwave source functions.
  !
  use mo_source_functions,   only: ty_source_func_lw
  !
  ! RTE  drivers
  !
  use mo_rte_lw,             only: rte_lw
  use mo_rte_sw,             only: rte_sw
  !
  ! Output fluxes by spectral band in addition to broadband
  !   in extensions/
  !
  use mo_fluxes_byband,             only: ty_fluxes_byband
  !
  ! Simple estimation of heating rates (in extensions/)
  !
  use mo_heating_rates,      only: compute_heating_rate
  !
  ! Serial netCDF I/O, provided in examples/
  !
  use mo_load_coefficients,   only: load_and_init
  use mo_default_io,    only: read_atmos, is_lw, is_sw, &
                                   read_lw_bc, read_sw_bc, read_lw_rt,  &
                                   write_spectral_disc, &
                                   write_fluxes, write_dir_fluxes, write_heating_rates
  implicit none
  ! ----------------------------------------------------------------------------------
  ! Variables
  ! ----------------------------------------------------------------------------------
  ! Arrays: dimensions (col, lay)
  real(wp), dimension(:,:),   allocatable :: p_lay, t_lay, p_lev
  real(wp), dimension(:,:),   allocatable :: col_dry
  !
  ! Longwave only
  !
  real(wp), dimension(:,:), allocatable :: t_lev
  real(wp), dimension(:),     allocatable :: t_sfc
  real(wp), dimension(:,:),   allocatable :: emis_sfc ! First dimension is band
  !
  ! Shortwave only
  !
  real(wp), dimension(:),     allocatable :: sza, tsi, mu0
  real(wp), dimension(:,:),   allocatable :: sfc_alb_dir, sfc_alb_dif ! First dimension is band
  real(wp)                                :: tsi_scaling = -999._wp
  !
  ! Source functions
  !
  !   Longwave
  type(ty_source_func_lw)               :: lw_sources
  !   Shortwave
  real(wp), dimension(:,:), allocatable :: toa_flux

  !
  ! Output variables
  !
  real(wp), dimension(:,: ), target, &
                               allocatable ::     flux_up,      flux_dn, &
                                                  flux_net,     flux_dir
  real(wp), dimension(:,:),    allocatable :: heating_rate
  real(wp), dimension(:,:,:),  allocatable :: bnd_heating_rate
  real(wp), dimension(:,:,:), target, &
                              allocatable ::  bnd_flux_up,  bnd_flux_dn, &
                                              bnd_flux_net, bnd_flux_dir
  !
  ! Derived types from the RTE and RRTMGP libraries
  !
  type(ty_gas_optics_rrtmgp)    :: k_dist
  type(ty_gas_concs)     :: gas_concs_subset, gas_concs
  !type(ty_gas_concs),allocatable,dimension(:)  :: gas_concs
  class(ty_optical_props_arry), &
             allocatable :: optical_props
  type(ty_fluxes_byband) :: fluxes

  !
  ! Inputs to RRTMGP
  !
  logical :: top_at_1

  integer :: ncol, nlay, nbnd, ngpt, nUserArgs=0
  integer :: b, nBlocks, colS, colE, nSubcols, nangs
  integer :: blockSize = 0
  character(len=256) :: rt_description = 'radiative transfer model scheme'
  !
  ! k-distribution file and input-output files must be paired: LW or SW
  !
  character(len=256) :: k_dist_file = 'coefficients.nc'
  character(len=256) :: input_file  = "rrtmgp-flux-inputs-outputs.nc"
  character(len=2) :: lw_rt_method = "QA"
  real(wp), parameter :: pi = acos(-1._wp)
  ! ----------------------------------------------------------------------------------
  ! Code
  ! ----------------------------------------------------------------------------------
  !
  ! Parse command line for any file names, block size
  !
  nUserArgs = command_argument_count()
  if (nUserArgs < 2) then
     print *, "usage: rrtmgp_default_atmos <input_file> <k_dist_file> [blockSize]"
     print *, "arguments:                                                       "
     print *, "    input_file   file containing atmos profile information       "
     print *, "    k_dist_file  file containing spectral discretization         "
     print *, "    LW RT method choices are QA or OA (required for LW calcs with 1 ang) "
     stop
  else
     call get_command_argument(1, input_file)
     call get_command_argument(2, k_dist_file)
  end if
  if (nUserArgs >  3) print *, "Ignoring command line arguments beyond the first three..."
  !
  ! Read temperature, pressure, gas concentrations, then variables specific
  !  to LW or SW problems. Arrays are allocated as they are read
  !
  call read_atmos(input_file,  p_lay, t_lay, p_lev, t_lev, gas_concs, col_dry)
  if(is_lw(input_file)) then
    call read_lw_bc(input_file, t_sfc, emis_sfc)
    ! Number of quadrature angles
    call read_lw_rt(input_file, nangs)
    if (nangs .eq. 1) then
        call get_command_argument(3, lw_rt_method)
        if (trim(lw_rt_method) .ne. 'QA' .and. trim(lw_rt_method) .ne. 'OA') then
            call stop_on_err("rrtmgp_default_atmos: invalid declaration of RT type (need OA or QA)")
        endif
    endif
  else
    call read_sw_bc(input_file, sza, tsi, tsi_scaling, sfc_alb_dir, sfc_alb_dif)
    allocate(mu0(size(sza)))
    mu0 = cos(sza * pi/180.)
  end if

  !
  ! Load the gas optics class with data
  !
  call load_and_init(k_dist, k_dist_file, gas_concs)
  if(k_dist%source_is_internal() .neqv. is_lw(input_file)) &
    call stop_on_err("rrtmgp_default_atmos: gas optics and input-output file disagree about SW/LW")

  !
  ! Problem sizes; allocate output arrays for full problem
  !
  ncol  = size(p_lay,1)
  nlay  = size(p_lay,2)
  nbnd = k_dist%get_nband()
  ngpt = k_dist%get_ngpt()
  top_at_1 = p_lay(1, 1) < p_lay(1, nlay)

  allocate(flux_up(ncol,nlay+1), flux_dn(ncol,nlay+1), flux_net(ncol,nlay+1))
  allocate(heating_rate(ncol,nlay))
  if(is_sw(input_file)) &
    allocate(flux_dir(ncol,nlay+1))
  allocate(bnd_flux_up (ncol,nlay+1,nbnd), bnd_flux_dn(ncol,nlay+1,nbnd), &
         bnd_flux_net(ncol,nlay+1,nbnd))
  if(is_sw(input_file)) &
    allocate(bnd_flux_dir(ncol,nlay+1,nbnd))

  allocate(bnd_heating_rate(ncol,nlay,nbnd))

  !
  ! LW calculations neglect scattering; SW calculations use the 2-stream approximation
  !   Here we choose the right variant of optical_props.
  !
  if(is_sw(input_file)) then
    allocate(ty_optical_props_2str::optical_props)
  else
    allocate(ty_optical_props_1scl::optical_props)
  end if
  call stop_on_err(optical_props%init(k_dist))

  !
  ! How many columns to do at once? Default is all but user may have specified something
  !
  if (blockSize == 0) blockSize = ncol
  nBlocks = ncol/blockSize ! Integer division

  !
  ! Allocate arrays for the optical properties themselves.
  !
  select type(optical_props)
    class is (ty_optical_props_1scl)
      call stop_on_err(optical_props%alloc_1scl(blockSize, nlay))
    class is (ty_optical_props_2str)
      call stop_on_err(optical_props%alloc_2str(blockSize, nlay))
    class default
      call stop_on_err("rrtmgp_default_atmos: Don't recognize the kind of optical properties ")
  end select
  !
  ! Source function
  !
  if(is_sw(input_file)) then
    allocate(toa_flux(blockSize, ngpt))
  else
    call stop_on_err(lw_sources%alloc(blockSize, nlay, k_dist))
  end if

    !
    ! Loop over subsets of the problem
    !
    if(is_sw(input_file)) then
        do b = 1, nBlocks
            colS = (b-1) * blockSize + 1
            colE =  b    * blockSize
            nSubcols = colE-colS+1
            call compute_fluxes(colS, colE)
        end do
    else
        do b = 1, nBlocks
            colS = (b-1) * blockSize + 1
            colE =  b    * blockSize
            nSubcols = colE-colS+1
            call compute_fluxes(colS, colE, nangs=nangs, lw_rt_method=lw_rt_method)
        end do
    endif
    !
    ! Do any leftover columns
    !
    if(mod(ncol, blockSize) /= 0) then
      colS = ncol/blockSize * blockSize + 1  ! Integer arithmetic
      colE = ncol
      nSubcols = colE-colS+1
      !
      ! Reallocate optical properties and source function arrays
      !
      select type(optical_props)
        class is (ty_optical_props_1scl)
          call stop_on_err(optical_props%alloc_1scl(nSubcols, nlay))
        class is (ty_optical_props_2str)
          call stop_on_err(optical_props%alloc_2str(nSubcols, nlay))
        class default
          call stop_on_err("rrtmgp_default_atmos: Don't recognize the kind of optical properties ")
      end select
      if(is_sw(input_file)) then
        if(allocated(toa_flux)) deallocate(toa_flux)
        allocate(toa_flux(nSubcols, ngpt))
        call compute_fluxes(colS, colE)
      else
        call stop_on_err(lw_sources%alloc(nSubcols, nlay))
        call compute_fluxes(colS, colE, nangs=nangs, lw_rt_method=lw_rt_method)
      end if
    end if

    !
    ! Heating rates
    !
    call stop_on_err(compute_heating_rate(flux_up(:,:), flux_dn(:,:), &
                                          p_lev(:,:), heating_rate(:,:)))

    !JSD call stop_on_err(compute_heating_rate(flux_up(:,:), flux_dn(:,:), &
        !p_lev(:,:), heating_rate(:,:)))
        do b = 1, nbnd
          call stop_on_err(compute_heating_rate(bnd_flux_up(:,:,b), bnd_flux_dn(:,:,b), &
                                            p_lev(:,:), bnd_heating_rate(:,:,b)))
        end do
  !JSD enddo
  !
  ! ... and write everything out
  !
  call write_spectral_disc(input_file, optical_props)
  call write_fluxes(input_file, rt_description, flux_up, flux_dn, flux_net, bnd_flux_up, bnd_flux_dn, bnd_flux_net)
  call write_heating_rates(input_file, rt_description, heating_rate, bnd_heating_rate)
  if(k_dist%source_is_external()) &
    call write_dir_fluxes(input_file, rt_description, flux_dir, bnd_flux_dir)

contains

subroutine compute_fluxes(colS, colE, nangs, lw_rt_method)
  integer, intent(in) :: colS, colE
  integer, optional :: nangs
  character(len=2), optional :: lw_rt_method

  integer :: ncol, ngpt
  real(wp), dimension(:,:), allocatable :: optimal_angles ! linear fit to column transmissivity (ncol,ngpt)
  !
  ! This routine compute fluxes: LW or SW, without or without col_dry provided to gas_optics()
  !   Most variables come from the host program; this just keeps us from repeating a bunch of code
  !   in two places
  !
  fluxes%flux_up      => flux_up(colS:colE,:)
  fluxes%flux_dn      => flux_dn(colS:colE,:)
  fluxes%flux_net     => flux_net(colS:colE,:)
  fluxes%bnd_flux_up  => bnd_flux_up(colS:colE,:,:)
  fluxes%bnd_flux_dn  => bnd_flux_dn(colS:colE,:,:)
  fluxes%bnd_flux_net => bnd_flux_net(colS:colE,:,:)
  if(is_sw(input_file)) then
    fluxes%flux_dn_dir     => flux_dir(colS:colE,:)
    fluxes%bnd_flux_dn_dir  => bnd_flux_dir(colS:colE,:,:)
  end if
  call stop_on_err(gas_concs%get_subset(colS, nSubcols, gas_concs_subset))
  if(is_sw(input_file)) then
    !
    ! Gas optics, including source functions
    !   There are two entries because the test files used during developement contain
    !   the field col_dry, the number of molecules per sq cm. Users will normally let
    !   RRTMGP compute this internally but it can be provided as an optional argument.
    !   We provide the value during validation to minimize one source of difference
    !   with reference calculations.
    !
    if(allocated(col_dry)) then
      call stop_on_err(k_dist%gas_optics(p_lay(colS:colE,:), &
                                         p_lev(colS:colE,:), &
                                         t_lay(colS:colE,:), &
                                         gas_concs_subset,   &
                                         optical_props,      &
                                         toa_flux,           &
                                         col_dry = col_dry(colS:colE,:)))
    else
      call stop_on_err(k_dist%gas_optics(p_lay(colS:colE,:), &
                                         p_lev(colS:colE,:), &
                                         t_lay(colS:colE,:), &
                                         gas_concs_subset,   &
                                         optical_props,      &
                                         toa_flux))
    end if
    if(tsi_scaling > 0.0_wp) toa_flux(:,:) =  toa_flux(:,:) * tsi_scaling
    !
    ! Radiative transfer
    !
    rt_description = 'shortwave 2-stream solution'
    call stop_on_err(rte_sw(optical_props,               &
                               top_at_1,                 &
                               mu0(colS:colE),           &
                               toa_flux,                 &
                               sfc_alb_dir(1:nbnd,colS:colE), &
                               sfc_alb_dif(1:nbnd,colS:colE), &
                               fluxes))
  else
    !
    ! Gas optics, including source functions
    !
    if(allocated(col_dry)) then
      call stop_on_err(k_dist%gas_optics(p_lay(colS:colE,:), &
                                         p_lev(colS:colE,:), &
                                         t_lay(colS:colE,:), &
                                         t_sfc(colS:colE  ), &
                                         gas_concs_subset,   &
                                         optical_props,      &
                                         lw_sources,         &
                                         tlev    = t_lev  (colS:colE,:), &
                                         col_dry = col_dry(colS:colE,:)))
    else
      call stop_on_err(k_dist%gas_optics(p_lay(colS:colE,:), &
                                         p_lev(colS:colE,:), &
                                         t_lay(colS:colE,:), &
                                         t_sfc(colS:colE  ), &
                                         gas_concs_subset,   &
                                         optical_props,      &
                                         lw_sources,         &
                                         tlev    = t_lev  (colS:colE,:)))
    end if
    !
    ! Radiative transfer
    !
    if (nangs .eq. 1 .AND. lw_rt_method .eq. 'OA') then
        rt_description = 'longwave optimal angle solution'
        ! Compute optimal single
        ncol = optical_props%get_ncol()
        ngpt = optical_props%get_ngpt()
        if(allocated(optimal_angles)) deallocate(optimal_angles)
        allocate(optimal_angles(ncol,ngpt))
        call stop_on_err(k_dist%compute_optimal_angles(optical_props, optimal_angles))
        call stop_on_err(rte_lw(optical_props,            &
                               top_at_1,              &
                               lw_sources,            &
                               emis_sfc(1:nbnd,colS:colE), &
                               fluxes, &
                               use_2stream = .false., &
                               n_gauss_angles = nangs, &
                               lw_Ds = optimal_angles))
    else
        rt_description = 'longwave 3-angle gaussian solution'
        call stop_on_err(rte_lw(optical_props,            &
                               top_at_1,              &
                               lw_sources,            &
                               emis_sfc(1:nbnd,colS:colE), &
                               fluxes, &
                               use_2stream = .false., &
                               n_gauss_angles = nangs))
    endif
  end if
end subroutine compute_fluxes
end program rrtmgp_default_atmos
