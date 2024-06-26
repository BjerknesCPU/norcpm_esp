module m_set_random_seed2
contains
subroutine set_random_seed2
! Sets a random seed based on the system and wall clock time
#if defined (QMPI) 
   use qmpi
#else
   use qmpi_fake
#endif
   implicit none 

   integer , dimension(8)::val
   integer cnt
   integer sze
   integer, allocatable, dimension(:):: pt
#if defined (QMPI)
   integer :: q
#endif

   call DATE_AND_TIME(values=val)
   if(master)print*,'TIME', val
   call SYSTEM_CLOCK(count=cnt)
   if(master)print*,'CLOCK', cnt
   call RANDOM_SEED(size=sze)
   if(master)print*,'SEED', sze
   allocate(pt(sze))
   pt(1) = val(8)*val(3)
   pt(2) = cnt
   ! KAL --- spread random seed to tiles, this makes sure that m_sample2D 
   ! KAL --- produces the same perturbations across processes
#if defined (QMPI)
   if (master) then
      do q=2,qmpi_num_proc
         call send(pt,q-1)
      end do
   else
      call receive(pt,0)
   end if
#endif
   call RANDOM_SEED(put=pt)
   if(master)print*,'RANDOM SEED', pt
   deallocate(pt)
end subroutine set_random_seed2

! --- Sets a random seed based on the wall clock time
      subroutine set_random_seed3
#if defined (QMPI) 
   use qmpi
#else
   use qmpi_fake
#endif
      implicit none 
      integer , dimension(8)::val
      integer cnt,q
      integer sze
! --- Arrays for random seed
      integer, allocatable, dimension(:):: pt  
      real   , allocatable, dimension(:):: rpt
!
      call DATE_AND_TIME(values=val)
      call RANDOM_SEED(size=sze)
      allocate(pt(sze)) 
      allocate(rpt(sze))
! --- Init - assumes seed is set in some way based on clock, 
! --- date etc. (not specified in fortran standard). Sometimes
! --- this initial seed is just set every second 
      call RANDOM_SEED   
! --- Retrieve initialized seed. val(8) is milliseconds - 
      call RANDOM_SEED(GET=pt) 
! --- this randomizes stuff if random_seed is not updated often 
! --- enough. synchronize seed across tasks (needed if pseudo 
! --- is paralellized some day)
      rpt = pt * (val(8)-500)  
#if defined (QMPI)
   if (master) then
      do q=2,qmpi_num_proc
         call send(rpt,q-1)
      end do
   else
      call receive(rpt,0)
   end if
#endif          
      pt=int(rpt)
      call RANDOM_SEED(put=pt)
      deallocate( pt)
      deallocate(rpt)
      end subroutine set_random_seed3

end module m_set_random_seed2
