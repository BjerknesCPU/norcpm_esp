!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This is a dummy module, for running ESP component in NorESM2.
!       [2023-10] fork by Ping-Gin Chiu
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

! File:          p_fixenkf_cice.F90
!
! Created:       Francois counillon
!
! Last modified: 05/09/2017 by Madlen Kimmritz
!                
!
! Purpose:       Fixes EnKF output.
!
! Description:  
!
! Modifications: updates due to Kimmritz et al. 2017 (subm) optimized assim. of sea ice
!
module m_fixenkf_ice

contains

subroutine fixenkf_ice(imem)
use netcdf
!use mod_eosfun
use nfw_mod
   implicit none

   integer*4, external :: iargc
   real, parameter :: rhoi=917.       ! density of ice (kg/m^3)
   real, parameter :: rhos=330.       ! density of snow (kg/m^3)
   real, parameter :: pi = 3.14159265358979323846
   real, parameter :: Lfresh=0.334e6  ! latent heat of melting of fresh ice (J/kg)
   real, parameter :: cp_ice=2106. ! specific heat of fresh ice (J/kg/K)
   real, parameter :: cp_ocn=4190. ! specific heat of ocn    (J/kg/K)
   real, parameter :: mu=0.054     ! specific heat of ocn    (J/kg/K)
   real, parameter :: eps=0.0001   ! specific heat of ocn    (J/kg/K)
   real, parameter :: saltmax=3.2  ! max salt in ice
   real, parameter :: msal=0.573 
   real, parameter :: nsal=0.407 
   real, parameter :: thresh = 1.0e-6 ! threshold for energy update

   logical         :: TRIPOL_GRID=.false. 
   logical         :: V_IN_STATEVEC=.false.

   integer imem                  ! ensemble member
   character(len=80) :: oldfile,maskfile, char80, oldfile_oce

   character(len=80) :: aiceoldfile
   character(len=80) :: viceoldfile
   integer           :: aiceo_ID, ncida
   integer           :: viceo_ID, ncidv
   real, allocatable, dimension(:,:,:)   :: aice_old
   real, allocatable, dimension(:,:,:)   :: vice_old
   !=== proceed with normal
   logical          :: ex
   character(len=8) :: cfld, ctmp
   character(len=3) :: cproc,cmem
   integer          :: tlevel, vlevel, nproc
   integer          :: idm,jdm,kdm,ncat,nzi,nzs,l,l2
   real, allocatable:: mask_land(:,:),kcat(:),Tmlt(:)
   real, allocatable, dimension(:,:,:)     :: vicen, aicen,Tsfcn,eicen,esnon,vsnon,volpn,apondn,hpondn,iage,FY
   real, allocatable, dimension(:,:,:,:)   :: temp,saln,sigma,dp
   real, allocatable, dimension(:,:,:) :: ficem
   real, allocatable, dimension(:,:)   :: uvel,vvel,strocnxT,strocnyT,stressp_1,stressp_2,stressp_3,stressp_4
   real, allocatable, dimension(:,:)   :: stress12_1,stress12_2,stress12_3,stress12_4,stressm_1,stressm_2,stressm_3,stressm_4
   real, parameter  :: epsil=1.e-11
   integer :: i,j,k,Ni,Nsn
   real :: sumaicen,salin,b,Ti,zn
   integer, allocatable :: ns(:), nc(:)
   integer, allocatable :: ns3(:), nc3(:)
   integer, allocatable :: ns2(:), nc2(:)
   integer :: ncid, x_ID, y_ID, z_ID, zi_ID, zs_ID
   integer :: ncid2, vTMP_ID
   integer :: aicen_ID,vicen_ID,Tsfcn_ID,eicen_ID
   integer :: esnon_ID,vsnon_ID,temp_ID,saln_ID, sig_ID, dp_ID
   real, parameter :: radian=57.295779513

  !  air temp and diff. to melting temp. :  
  !          Tair(init) = 253 K = -20 gradC (winter) or 
  !                       273 K =   0 gradC (summer)
   real, parameter ::  Tair_ij = 253.15 -0.0         
   integer, allocatable, dimension(:) :: ilyr1       !
   integer :: n,kk

   real :: trcrn_s 
   trcrn_s = min(0., Tair_ij - 273.15)               !Tsmelt=0C, Tffresh=273.15K !=== tuning parameter
   !=====================================================================================================================================
#if defined(TRIPOLAR)
   TRIPOL_GRID=.true.
#endif
  !!not use here!!if (iargc()==1 ) then
  !!not use here!!   call getarg(1,ctmp)
  !!not use here!!   read(ctmp,*) imem
  write(cmem,'(i3.3)') imem
  !!not use here!!else
  !!not use here!!   print *,'"fixmycom" -- A crude routine to correct restart files obvious errors and complete diagnostic variable'
  !!not use here!!   print *
  !!not use here!!   print *,'usage: '
  !!not use here!!   print *,'   fixmicom ensemble_member'
  !!not use here!!   print *,'   "ensemble_member" is the ensemble member'
  !!not use here!!   call exit(1)
  !!not use here!!endif

   oldfile    ='forecast_ice'//cmem//'.nc'    
   oldfile_oce='forecast'//cmem//'.nc'

   print *, 'fixenkf files:',oldfile, oldfile_oce
   ! Get dimensions from blkdat
   inquire(exist=ex,file=trim(oldfile))
   if (.not.ex) then
      write(*,*) 'Can not find '//'forecast_ice'//cmem//'.nc'
      stop '(EnKF_postprocess)'
   end if

   inquire(exist=ex,file=trim(oldfile_oce))
   if (.not.ex) then
      write(*,*) 'Can not find '//'forecast'//cmem//'.nc'
      stop '(EnKF_postprocess)'
   end if

   aiceoldfile='aiceold'//cmem//'.nc'
   inquire(exist=ex,file=trim(aiceoldfile))
   if (.not.ex) then
      write(*,*) 'Can not find '//'aiceold'//cmem//'.nc'
      stop '(EnKF_postprocess)'
   end if

   if (V_IN_STATEVEC) then
     viceoldfile='viceold'//cmem//'.nc'
     inquire(exist=ex,file=trim(viceoldfile))
     if (.not.ex) then
       write(*,*) 'Can not find '//'viceold'//cmem//'.nc'
       stop '(EnKF_postprocess)'
     end if
   end if 
   !=====================================================================================================================================
   ! Reading the restart file
   call nfw_open(trim(oldfile), nf_write, ncid)
   ! Get dimension id in netcdf file ...
   ! from ice file
   !nb total of data
   call nfw_inq_dimid(trim(oldfile), ncid, 'ni', x_ID)
   call nfw_inq_dimid(trim(oldfile), ncid, 'nj', y_ID)
   call nfw_inq_dimid(trim(oldfile), ncid, 'ncat', z_ID)
   call nfw_inq_dimid(trim(oldfile), ncid, 'ntilyr', zi_ID)
   call nfw_inq_dimid(trim(oldfile), ncid, 'ntslyr', zs_ID)
   !nb total of track
   call nfw_inq_dimlen(trim(oldfile), ncid, x_ID, idm)
   call nfw_inq_dimlen(trim(oldfile), ncid, y_ID, jdm)

   call nfw_inq_dimlen(trim(oldfile), ncid, z_ID, ncat)
   call nfw_inq_dimlen(trim(oldfile), ncid, zi_ID, nzi)
   call nfw_inq_dimlen(trim(oldfile), ncid, zs_ID, nzs)
  ! print *, 'The model dimension is :',idm,jdm,kdm
   allocate(aicen (idm,jdm,ncat))
   allocate(vicen (idm,jdm,ncat))
   allocate(Tsfcn (idm,jdm,ncat))
   allocate(vsnon (idm,jdm,ncat))
   allocate(eicen (idm,jdm,nzi))
   allocate(esnon (idm,jdm,nzs))
   allocate(volpn (idm,jdm,ncat))
   allocate(apondn(idm,jdm,ncat))
   allocate(hpondn(idm,jdm,ncat))
   allocate(iage (idm,jdm,ncat))
   allocate(FY (idm,jdm,ncat))
   allocate(uvel (idm,jdm))
   allocate(vvel (idm,jdm))
   allocate(strocnxT (idm,jdm))
   allocate(strocnyT (idm,jdm))
   allocate(stressp_1 (idm,jdm))
   allocate(stressp_2 (idm,jdm))
   allocate(stressp_3 (idm,jdm))
   allocate(stressp_4 (idm,jdm))
   allocate(stressm_1 (idm,jdm))
   allocate(stressm_2 (idm,jdm))
   allocate(stressm_3 (idm,jdm))
   allocate(stressm_4 (idm,jdm))
   allocate(stress12_1 (idm,jdm))
   allocate(stress12_2 (idm,jdm))
   allocate(stress12_3 (idm,jdm))
   allocate(stress12_4 (idm,jdm))
   allocate(kcat(ncat+1))          !bound for thickness

   kcat(1)=0.01 !0.0
   kcat(2)=0.644507216819426
   kcat(3)=1.39143349757630
   kcat(4)=2.47017938195989
   Kcat(5)=4.56728791885049
   !maximun thickness arguably selected to 70m
   Kcat(6)=9.33384181586817

   Ni=int(nzi/ncat)
   Nsn=int(nzs/ncat)

   !needed for eicen (see also CICE code) 
   allocate(ilyr1(ncat))
   ilyr1(1) = 1                                      ! if nilyr (=Ni) = 4 nr. of els in ice layers
   do k = 2, ncat                                    !   ilyrn = { 4,8,12} etc
     ilyr1(k) = ilyr1(k-1) + Ni
   enddo

   allocate(Tmlt(Ni))          ! melting (for each element in a category)
   do k=1, Ni
     zn=(k-.5)/Ni
     salin=saltmax/2.*(1.-cos(pi*zn**(nsal/(msal+zn))))
     Tmlt(k)=-mu*salin
   enddo
  
!=====================================


   allocate(ns(4))
   allocate(nc(4))
   ns(1)=1
   ns(2)=1
   ns(3)=1
   ns(4)=1
   nc(1)=idm
   nc(2)=jdm
   nc(3)=ncat
   nc(4)=1
   allocate(ns3(3))
   allocate(nc3(3))
   ns3(1)=1
   ns3(2)=1
   ns3(3)=1
   nc3(1)=idm
   nc3(2)=jdm
   nc3(3)=1
   allocate(ns2(2))
   allocate(nc2(2))
   ns2(1)=1
   ns2(2)=1
   nc2(1)=idm
   nc2(2)=jdm

   call nfw_inq_varid(trim(oldfile), ncid,'aicen',aicen_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, aicen_ID, ns, nc, aicen)
   call nfw_inq_varid(trim(oldfile), ncid,'vicen',vicen_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vicen_ID, ns, nc, vicen)
   call nfw_inq_varid(trim(oldfile), ncid,'Tsfcn',Tsfcn_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, Tsfcn_ID, ns, nc, Tsfcn)
   call nfw_inq_varid(trim(oldfile), ncid,'vsnon',vsnon_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vsnon_ID, ns, nc, vsnon)
   call nfw_inq_varid(trim(oldfile), ncid,'volpn',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, volpn)
   call nfw_inq_varid(trim(oldfile), ncid,'apondn',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, apondn)
   call nfw_inq_varid(trim(oldfile), ncid,'hpondn',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, hpondn)
   call nfw_inq_varid(trim(oldfile), ncid,'iage',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, iage)
   call nfw_inq_varid(trim(oldfile), ncid,'FY',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, FY)
   nc(3)=nzi
   call nfw_inq_varid(trim(oldfile), ncid,'eicen',eicen_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, eicen_ID, ns, nc, eicen)
   nc(3)=nzs
   call nfw_inq_varid(trim(oldfile), ncid,'esnon',esnon_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, esnon_ID, ns, nc, esnon)
   call nfw_inq_varid(trim(oldfile), ncid,'uvel',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, uvel)
   call nfw_inq_varid(trim(oldfile), ncid,'vvel',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, vvel)
   call nfw_inq_varid(trim(oldfile), ncid,'strocnxT',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, strocnxT)
   call nfw_inq_varid(trim(oldfile), ncid,'strocnyT',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, strocnyT)
   call nfw_inq_varid(trim(oldfile), ncid,'stressp_1',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressp_1)
   call nfw_inq_varid(trim(oldfile), ncid,'stressp_2',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressp_2)
   call nfw_inq_varid(trim(oldfile), ncid,'stressp_3',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressp_3)
   call nfw_inq_varid(trim(oldfile), ncid,'stressp_4',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressp_4)

   call nfw_inq_varid(trim(oldfile), ncid,'stressm_1',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressm_1)
   call nfw_inq_varid(trim(oldfile), ncid,'stressm_2',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressm_2)
   call nfw_inq_varid(trim(oldfile), ncid,'stressm_3',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressm_3)
   call nfw_inq_varid(trim(oldfile), ncid,'stressm_4',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressm_4)

   call nfw_inq_varid(trim(oldfile), ncid,'stress12_1',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stress12_1)
   call nfw_inq_varid(trim(oldfile), ncid,'stress12_2',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stress12_2)
   call nfw_inq_varid(trim(oldfile), ncid,'stress12_3',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stress12_3)
   call nfw_inq_varid(trim(oldfile), ncid,'stress12_4',vTMP_ID)
   call nfw_get_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stress12_4)

   !==== read old ice concentrations for scaling vsnon, eicen and esnon
   allocate(aice_old (idm,jdm,ncat))
   nc(3)=ncat
   call nfw_open(trim(aiceoldfile), nf_write, ncida)
   call nfw_inq_varid(trim(aiceoldfile), ncida,'aicen',aiceo_ID)
   call nfw_get_vara_double(trim(aiceoldfile), ncida, aiceo_ID, ns, nc, aice_old)
   call nfw_close(trim(aiceoldfile), ncida)

   allocate(vice_old (idm,jdm,ncat))
   if (V_IN_STATEVEC) then
    call nfw_open(trim(viceoldfile), nf_write, ncidv)
    call nfw_inq_varid(trim(viceoldfile), ncidv,'vicen',viceo_ID)
    call nfw_get_vara_double(trim(viceoldfile), ncidv, viceo_ID, ns, nc, vice_old)
    call nfw_close(trim(viceoldfile), ncidv)
   end if 
   nc(3)=nzs

   !==== read ice mask 
   if (TRIPOL_GRID) nc3(2) = jdm+1
   allocate(mask_land (idm,nc3(2)))
   maskfile='mask_ice.nc'

   ! ingo.bethke: deactivate reading of ice mask, which causes problems on Betzy
   if (.false.) then 
   call nfw_open(trim(maskfile), or(nf_write,nf_share), ncid2)
   if (TRIPOL_GRID) then
    call nfw_inq_varid(trim(maskfile), ncid2,'aice',aicen_ID)
   else
     call nfw_inq_varid(trim(maskfile), ncid2,'fice',aicen_ID)
   end if
   call nfw_get_vara_double(trim(maskfile), ncid2, aicen_ID, ns3, nc3, mask_land)
   call nfw_close(trim(maskfile), ncid2)
   else
   mask_land=0.5
   end if 
   ! 

   !==== read ocean data
   maskfile='forecast'//cmem//'.nc'

  
   if (TRIPOL_GRID) nc(2) = jdm+1
   call nfw_open(trim(maskfile), nf_write, ncid2)   
   call nfw_inq_dimid(trim(maskfile), ncid2, 'kk', z_ID)
   call nfw_inq_dimlen(trim(maskfile), ncid2, z_ID, kdm)

   !allocate micom fields
   if (TRIPOL_GRID) then 
     allocate(temp (idm,jdm+1,kdm,1))
     allocate(saln (idm,jdm+1,kdm,1))
     allocate(dp (idm,jdm+1,kdm,1))
     allocate(sigma (idm,jdm+1,kdm,1))
     allocate(ficem (idm,jdm+1,1))
   else
     allocate(temp (idm,jdm,kdm,1))
     allocate(saln (idm,jdm,kdm,1))
     allocate(dp (idm,jdm,kdm,1))
     allocate(sigma (idm,jdm,kdm,1))
     allocate(ficem (idm,jdm,1))
   end if 
   ficem=0.
   !reading the first 53 layers representing the entire depth'
   nc(3)=kdm

   call nfw_inq_varid(trim(maskfile), ncid2,'temp',temp_ID)
   call nfw_get_vara_double(trim(maskfile), ncid2, temp_ID, ns, nc, temp)
   call nfw_inq_varid(trim(maskfile), ncid2,'saln',saln_ID)
   call nfw_get_vara_double(trim(maskfile), ncid2, saln_ID, ns, nc, saln)
   call nfw_inq_varid(trim(maskfile), ncid2,'dp',dp_ID)
   call nfw_get_vara_double(trim(maskfile), ncid2, dp_ID, ns, nc, dp)
   call nfw_inq_varid(trim(maskfile), ncid2,'sigma',sig_ID)
   call nfw_get_vara_double(trim(maskfile), ncid2, sig_ID, ns, nc, sigma)

   nc(2) = jdm 
   ! First ensure that value of aicen  within [0 1]
   ! set other var=0 if aicen=0
   ! make sure volume > 0
   ! make sure the sum of the concentration does not exceed 1.
   !Ice mask land not same than ocn mask land. 

   do j=1,jdm
   do i=1,idm
      if ((mask_land(i,j) .ge. 0. .and. mask_land(i,j) .le. 100 )) then
         do k = 1, ncat
            vicen(i,j,k)=max(0.,vicen(i,j,k))
            Tsfcn(i,j,k)=min(0.,Tsfcn(i,j,k))
            aicen(i,j,k)=min(1.,aicen(i,j,k))
            aicen(i,j,k)=max(0.,aicen(i,j,k))
            ficem(i,j,1)=ficem(i,j,1)+aicen(i,j,k)

            aice_old(i,j,k)=min(1.,aice_old(i,j,k))
            aice_old(i,j,k)=max(0.,aice_old(i,j,k))

            if  (aicen(i,j,k)<=0.00 ) then
              aicen(i,j,k)=0.
              Tsfcn(i,j,k)=-1.836
              vicen(i,j,k)=0.
              vsnon(i,j,k)=0.
              volpn(i,j,k)=0.
              apondn(i,j,k)=0.
              hpondn(i,j,k)=0.
              iage(i,j,k)=0.
              FY(i,j,k)=0.
              eicen(i,j,(k-1)*Ni+1:k*Ni)=0.
              esnon(i,j,(k-1)*Nsn+1:k*Nsn)=0.
            end if
         end do
         !====    rescale total ice concentration to range [0,1]
         if ( ficem(i,j,1) .ne. 0. .and. ficem(i,j,1) .gt. 1.) then
            do k = 1, ncat
              aicen(i,j,k)=aicen(i,j,k)/ficem(i,j,1)
            end do
         end if
         ficem(i,j,1)=min(1.,ficem(i,j,1))
         !=======================
         do k = 1, ncat
            if (aicen(i,j,k)>0. ) then
              !=== if vicen not in state vector scale it due to changes in aicen
              if (.not.V_IN_STATEVEC) then
                  vice_old(i,j,k)=vicen(i,j,k)
                  if (aice_old(i,j,k)>0. ) then
                     vicen(i,j,k)=vicen(i,j,k)*aicen(i,j,k)/aice_old(i,j,k)
                  else
                     vicen(i,j,k)=0.0
                  end if 
              end if
              !=== ensure that there is ice volume
              !    and ice volume within correct range
              !    particularly relevant, when vicen not in state vector
              !          to create ice volume for aicenold=0 and aicen>0
              vicen(i,j,k)=max(vicen(i,j,k),kcat(k)  *aicen(i,j,k))
              vicen(i,j,k)=min(vicen(i,j,k),kcat(k+1)*aicen(i,j,k))


              !=== set ice energy
                do kk=1,Ni!eicen(i,j,(k-1)*Ni+1:k*Ni)=0.
                  eicen(i,j,(k-1)*Ni+kk)=eicen(i,j,(k-1)*Ni+kk)*vicen(i,j,k)/vice_old(i,j,k)
                end do              
             !=== if aice_old too low, replace by predefined value (see ice_init.F90)
              if (vice_old(i,j,k)<thresh*kcat(k)) then
                do kk = 1, Ni 
                  b = Tmlt(kk) - trcrn_s !
                  Ti = trcrn_s + b*(real(kk)-0.5) /real(Ni)  
                  eicen(i,j,ilyr1(k)+kk-1) = &
                     -(rhoi * (cp_ice*(Tmlt(kk)-Ti) + Lfresh*(1.0-Tmlt(kk)/(Ti+1.0e-12)) - cp_ocn*Tmlt(kk))) &
                      * vicen(i,j,k)/real(Ni)
                 end do
              end if

              !=== set snow volume
              !    We presume at this stage that neither vsnon nor esnon 
              !    are in the state vector of the EnKF.
              !    snow thickness is preserved throughout assimilation
              !    31/01/2017: only update of vsnon does not work, thermo error, 
              !                need to modify esnon as well
              !
              vsnon(i,j,k)=vsnon(i,j,k)*aicen(i,j,k)/max(thresh,aice_old(i,j,k)) 
              !    ensure there is vsnon for aice_old = 0 

              if (aice_old(i,j,k)<thresh) then
                 vsnon(i,j,k)=0.2*vicen(i,j,k)
              end if

              !scale esnon 
              !            (if aice_old too low, use predefined value, see ice_init.F90)
              ! 01/02/2017: setting treshold to 1e-12 causes thermo error
              !             with 1e-6 next month is being integrated
              do kk=1,Nsn!
                esnon(i,j,(k-1)*Nsn+kk)=esnon(i,j,(k-1)*Nsn+kk)*aicen(i,j,k)/max(thresh,aice_old(i,j,k))
                if (aice_old(i,j,k)<thresh) then 
                  Ti = min(0.0, trcrn_s)
                  esnon(i,j,(k-1)*Nsn+kk)=-rhos*(Lfresh - cp_ice*Ti)*vsnon(i,j,k)/real(Nsn)
                end if
              end do              

            end if
         end do
         
         !=======================
         if (ficem(i,j,1).le.0) then
            uvel(i,j)=0
            vvel(i,j)=0
            strocnxT(i,j)=0
            strocnyT(i,j)=0
            stressp_1(i,j)=0
            stressp_2(i,j)=0
            stressp_3(i,j)=0
            stressp_4(i,j)=0

            stressm_1(i,j)=0
            stressm_2(i,j)=0
            stressm_3(i,j)=0
            stressm_4(i,j)=0

            stress12_1(i,j)=0
            stress12_2(i,j)=0
            stress12_3(i,j)=0
            stress12_4(i,j)=0
         end if


        end if!land mask
   end do
   end do
   !===================================================================================================
   if (TRIPOL_GRID) then
    ficem(:,jdm+1,1) = ficem(:,jdm,1)
   end if 
   !===================================================================================================

   nc(3)=ncat
   call nfw_inq_varid(trim(oldfile), ncid,'aicen',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, aicen)
   call nfw_inq_varid(trim(oldfile), ncid,'vicen',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, vicen)
   call nfw_inq_varid(trim(oldfile), ncid,'Tsfcn',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, Tsfcn)
   nc(3)=nzi
   call nfw_inq_varid(trim(oldfile), ncid,'eicen',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, eicen)
   nc(3)=nzs
   call nfw_inq_varid(trim(oldfile), ncid,'esnon',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, esnon)
   call nfw_inq_varid(trim(oldfile), ncid,'vsnon',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, vsnon)
   call nfw_inq_varid(trim(oldfile), ncid,'volpn',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, volpn)
   call nfw_inq_varid(trim(oldfile), ncid,'apondn',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, apondn)
   call nfw_inq_varid(trim(oldfile), ncid,'hpondn',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, hpondn)
   call nfw_inq_varid(trim(oldfile), ncid,'iage',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, iage)
   call nfw_inq_varid(trim(oldfile), ncid,'FY',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns, nc, FY)
   call nfw_inq_varid(trim(oldfile), ncid,'uvel',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, uvel)
   call nfw_inq_varid(trim(oldfile), ncid,'vvel',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, vvel)
   call nfw_inq_varid(trim(oldfile), ncid,'strocnxT',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, strocnxT)
   call nfw_inq_varid(trim(oldfile), ncid,'strocnyT',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, strocnyT)

   call nfw_inq_varid(trim(oldfile), ncid,'stressp_1',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressp_1)
   call nfw_inq_varid(trim(oldfile), ncid,'stressp_2',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressp_2)
   call nfw_inq_varid(trim(oldfile), ncid,'stressp_3',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressp_3)
   call nfw_inq_varid(trim(oldfile), ncid,'stressp_4',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressp_4)

   call nfw_inq_varid(trim(oldfile), ncid,'stressm_1',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressm_1)
   call nfw_inq_varid(trim(oldfile), ncid,'stressm_2',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressm_2)
   call nfw_inq_varid(trim(oldfile), ncid,'stressm_3',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressm_3)
   call nfw_inq_varid(trim(oldfile), ncid,'stressm_4',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stressm_4)

   call nfw_inq_varid(trim(oldfile), ncid,'stress12_1',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stress12_1)
   call nfw_inq_varid(trim(oldfile), ncid,'stress12_2',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stress12_2)
   call nfw_inq_varid(trim(oldfile), ncid,'stress12_3',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stress12_3)
   call nfw_inq_varid(trim(oldfile), ncid,'stress12_4',vTMP_ID)
   call nfw_put_vara_double(trim(oldfile), ncid, vTMP_ID, ns2, nc2, stress12_4)

   call nfw_close(trim(oldfile), ncid)

   nc(3)=kdm ! write entire column
   if (TRIPOL_GRID) nc(2) = jdm+1
   call nfw_inq_varid(trim(maskfile), ncid2,'temp',temp_ID)
   call nfw_inq_varid(trim(maskfile), ncid2,'saln',saln_ID)
   call nfw_inq_varid(trim(maskfile), ncid2,'sigma',sig_ID)
   call nfw_inq_varid(trim(maskfile), ncid2,'dp',dp_ID)
   call nfw_put_vara_double(trim(maskfile), ncid2, temp_ID, ns, nc, temp)

   !now dump temperature on the second time level of ocean variables
   ns(3)=kdm+1
   call nfw_put_vara_double(trim(maskfile), ncid2, temp_ID, ns, nc, temp)
   call nfw_put_vara_double(trim(maskfile), ncid2, saln_ID, ns, nc, saln)
   call nfw_put_vara_double(trim(maskfile), ncid2, sig_ID, ns, nc, sigma)
   call nfw_put_vara_double(trim(maskfile), ncid2, dp_ID, ns, nc, dp)
   !==== ficem
   if (TRIPOL_GRID) nc3(2)=jdm+1
   call nfw_inq_varid(trim(maskfile), ncid2,'ficem',vTMP_ID)
   call nfw_put_vara_double(trim(maskfile), ncid2, vTMP_ID, ns3, nc3, ficem)
   call nfw_close(trim(maskfile), ncid2)



end subroutine fixenkf_ice
end module m_fixenkf_ice
