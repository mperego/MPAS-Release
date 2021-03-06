!|||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
!
!  li_velocity_external
!
!> \MPAS land-ice velocity driver for external dycores
!> \author Matt Hoffman
!> \date   3 October 2013
!> \version SVN:$Id:$
!> \details
!>  This module contains the routines for interfacing with 
!>  external velocity solvers.  These currently are LifeV (L1L2, First order), 
!>  Albany (First order), and PHG (Stokes).
!>
!
!-----------------------------------------------------------------------

module li_velocity_external


   use mpas_grid_types
   use mpas_configure
   use mpas_dmpar
   use mpas_configure
   !use, intrinsic :: iso_c_binding

   implicit none
   private
   save

   !--------------------------------------------------------------------
   !
   ! Public parameters
   !
   !--------------------------------------------------------------------

   !--------------------------------------------------------------------
   !
   ! Public member functions
   !
   !--------------------------------------------------------------------

   public :: li_velocity_external_init, &
             li_velocity_external_block_init, &
             li_velocity_external_solve, &
             li_velocity_external_finalize

   !--------------------------------------------------------------------
   !
   ! Private module variables
   !
   !--------------------------------------------------------------------


!***********************************************************************



contains



!***********************************************************************
!
!  routine li_velocity_external_init
!
!> \brief   Initializes velocity solver
!> \author Matt Hoffman
!> \date   3 October 2013
!> \version SVN:$Id$
!> \details
!>  This routine initializes the ice velocity solver in
!>  external velocity solvers.
!
!-----------------------------------------------------------------------

   subroutine li_velocity_external_init(domain, err)

      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------

      type (domain_type), intent(inout) :: domain

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------

      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------
      integer :: err_tmp

      err = 0
      err_tmp = 0

      ! Check for configuration options that are incompatible with external velocity solver conventions
      if (config_num_halos < 2) then
         write(0,*) "Error: External velocity solvers require that config_num_halos >= 2"
         err_tmp = 1
      endif
      err = ior(err,err_tmp)
      if (config_number_of_blocks /= 0) then
         write(0,*) "Error: External velocity solvers require that config_number_of_blocks=0"
         err_tmp = 1
      endif
      err = ior(err,err_tmp)


      ! These calls are needed for setting up the external velocity solvers

#if defined(USE_EXTERNAL_L1L2) || defined(USE_EXTERNAL_FIRSTORDER) || defined(USE_EXTERNAL_STOKES)
      !call external first order solver to set the grid of the velocity solver
      call velocity_solver_init_mpi(domain % dminfo % comm)
#else
      err = 1
      write(0,*) "Error: To run with an external velocity solver you must compile MPAS with one."
#endif


      if (config_velocity_solver == 'Stokes') then
#ifdef USE_EXTERNAL_STOKES
          call interface_phg_init(domain, err)
#else
          write(0,*) "Error: External Stokes library needed to run stokes dycore."
          err = 1
          return
#endif
      endif
      err = ior(err,err_tmp)


      ! === error check
      if (err > 0) then
          write (0,*) "An error has occurred in li_velocity_external_init."
      endif

   !--------------------------------------------------------------------
   end subroutine li_velocity_external_init



!***********************************************************************
!
!  routine li_velocity_external_block_init
!
!> \brief   Initializes blocks for external velocity solver use
!> \author Matt Hoffman
!> \date   3 October 2013
!> \version SVN:$Id$
!> \details 
!>  This routine initializes each block of the ice velocity solver in the 
!>  external velocity solver.
!>   Note: LifeV/Albany/PHG only support one block per processor, but this has (hopefully)
!>   been written to work if that were to change.  (That's why all these external dycore init
!>   calls are in li_velocity_external_block_init instead of li_velocity_external_init.)
!
!-----------------------------------------------------------------------

   subroutine li_velocity_external_block_init(block, err)

       use mpas_timer

      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------

      type (block_type), intent(in) :: &
         block          !< Input: mesh information

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------

      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------

      integer :: nCells, nEdges, nVertices, nCellsSolve, nEdgesSolve, nVerticesSolve, nVertLevels, maxNEdgesOnCell 

      integer, dimension(:,:), pointer :: cellsOnEdge, cellsOnVertex, verticesOnCell, verticesOnEdge, edgesOnCell

      integer, dimension(:), pointer :: indexToCellID, nEdgesOnCell

      real (kind=RKIND), dimension(:), pointer :: xCell, yCell, zCell, areaTriangle

      real (kind=RKIND) :: radius

      ! halo exchange arrays
      integer, dimension(:), pointer :: sendCellsArray, &
                                        recvCellsArray, &
                                        sendVerticesArray, &
                                        recvVerticesArray, &
                                        sendEdgesArray, &
                                        recvEdgesArray

      err = 0

      !extract data from domain
      nCellsSolve = block % mesh % nCellsSolve
      nEdgesSolve = block % mesh % nEdgesSolve
      nVerticesSolve = block % mesh % nVerticesSolve

      nCells = block % mesh % nCells
      nEdges = block % mesh % nEdges
      nVertices = block % mesh % nVertices
      nVertLevels = block % mesh % nVertLevels
      
      maxNEdgesOnCell = block % mesh % maxEdges;

      cellsOnEdge => block % mesh % cellsOnEdge % array
      cellsOnVertex => block % mesh % cellsOnVertex % array
      verticesOnCell => block % mesh % verticesOnCell % array
      verticesOnEdge => block % mesh % verticesOnEdge % array
      edgesOnCell => block % mesh % edgesOnCell % array
      indexToCellID => block % mesh % indexToCellID % array
      nEdgesOnCell => block % mesh % nEdgesOnCell % array

      xCell => block % mesh % xCell % array
      yCell => block % mesh % yCell % array
      zCell => block % mesh % zCell % array
      radius = block % mesh % sphere_radius

      areaTriangle => block % mesh % areaTriangle % array


      !build send and receive arrays using exchange_list
      call array_from_exchange_list(block % mesh % indexToCellID, sendCellsArray, recvCellsArray)
      call array_from_exchange_list(block % mesh % indexToEdgeID , sendEdgesArray, recvEdgesArray)
      call array_from_exchange_list(block % mesh % indexToVertexID , sendVerticesArray, recvVerticesArray)

!      call array_from_exchange_list(block % parinfo % verticesToSend, sendVerticesArray)
!      call array_from_exchange_list(block % parinfo % verticesToRecv, recvVerticesArray)
!      call array_from_exchange_list(block % parinfo % cellsToSend, sendCellsArray)
!      call array_from_exchange_list(block % parinfo % cellsToRecv, recvCellsArray)
!      call array_from_exchange_list(block % parinfo % edgesToSend, sendEdgesArray)
!      call array_from_exchange_list(block % parinfo % edgesToRecv, recvEdgesArray)

#if defined(USE_EXTERNAL_L1L2) || defined(USE_EXTERNAL_FIRSTORDER) || defined(USE_EXTERNAL_STOKES)
      ! These calls are needed for using any of the external velocity solvers

      !zCell is supposed to be zero when working on planar geometries (radius = 0) 
      !nVertLevels should be equal to nVertLevelsSolve (no splitting of the domain in the vertical direction)
      call mpas_timer_start("velocity_solver_set_grid_data")
      call velocity_solver_set_grid_data(nCells, nEdges, nVertices, nVertLevels, &
              nCellsSolve, nEdgesSolve, nVerticesSolve, maxNEdgesOnCell, radius, &
              cellsOnEdge, cellsOnVertex, verticesOnCell, verticesOnEdge, edgesOnCell, nEdgesOnCell, indexToCellID, &
              xCell, yCell, zCell, areaTriangle, &
              sendCellsArray, recvCellsArray, &
              sendEdgesArray, recvEdgesArray, &
              sendVerticesArray, recvVerticesArray)
      call mpas_timer_stop("velocity_solver_set_grid_data")
#else
      write(0,*) "Error: To run with an external velocity solver you must compile MPAS with one."
      err = 1
#endif

      !these can be deallocated because they have been copied on the c++ side
      deallocate(sendCellsArray, &
                 recvCellsArray, &
                 sendVerticesArray, &
                 recvVerticesArray, &
                 sendEdgesArray, &
                 recvEdgesArray)

      ! === error check
      if (err > 0) then
          write (0,*) "An error has occurred in li_velocity_external_block_init."
      endif

   !--------------------------------------------------------------------
   end subroutine li_velocity_external_block_init



!***********************************************************************
!
!  routine li_velocity_external_solve
!
!> \brief   Interface to call external velocity solvers
!> \author Matt Hoffman
!> \date   3 October 2013
!> \version SVN:$Id$
!> \details 
!>  This routine calls external first-order velocity solvers and/or Stokes velocity solvers.
!
!-----------------------------------------------------------------------

   subroutine li_velocity_external_solve(mesh, state, err)

       use mpas_timer

      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------

      type (mesh_type), intent(in) :: &
         mesh          !< Input: mesh information

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------

      type (state_type), intent(inout) :: &
         state          !< Input: state information 

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------

      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------
      real (kind=RKIND), dimension(:), pointer :: &
         thickness, lowerSurface, upperSurface, LayerThicknessFractions, beta
      real (kind=RKIND), dimension(:,:), pointer :: &
         normalVelocity
      real (kind=RKIND), dimension(:,:,:), pointer :: &
         tracers
      integer, dimension(:), pointer :: vertexMask

      integer :: index_temperature
      integer :: anyVertexMaskChanged

      err = 0
      
      ! Mesh variables
      LayerThicknessFractions => mesh % LayerThicknessFractions % array
      beta => mesh % beta % array

      ! State variables
      normalVelocity => state % normalVelocity % array
      thickness => state % thickness % array
      lowerSurface => state % lowerSurface % array
      upperSurface => state % upperSurface % array
      tracers => state % tracers % array
      index_temperature = state % index_temperature
      vertexMask => state % vertexMask % array
      anyVertexMaskChanged = state % anyVertexMaskChanged % scalar


      ! ==================================================================
      ! External dycore calls to be made only when vertex mask changes
      ! ==================================================================

      if ((anyVertexMaskChanged == 1) .or. (config_always_compute_fem_grid)) then
#if defined(USE_EXTERNAL_L1L2) || defined(USE_EXTERNAL_FIRSTORDER) || defined(USE_EXTERNAL_STOKES)
          call mpas_timer_start("velocity_solver_compute_2d_grid")
          call velocity_solver_compute_2d_grid(vertexMask)
          call mpas_timer_stop("velocity_solver_compute_2d_grid")
#else
      write(0,*) "Error: To run with an external velocity solver you must compile MPAS with one."
      err = 1
      return
#endif

          select case (config_velocity_solver)
          case ('L1L2')  ! ===============================================
#ifdef USE_EXTERNAL_L1L2
              call mpas_timer_start("velocity_solver_init_L1L2")
              !call velocity_solver_extrude_3d_grid(LayerThicknessFractions, lowerSurface, thickness)
              call velocity_solver_init_L1L2(LayerThicknessFractions)
              call mpas_timer_stop("velocity_solver_init_L1L2")
#else
              write(0,*) "Error: External LifeV library needed to run L1L2 dycore."
              err = 1
              return
#endif

          case ('FO') ! ===============================================
#ifdef USE_EXTERNAL_FIRSTORDER
              call mpas_timer_start("velocity_solver_extrude_3d_grid")
              call velocity_solver_extrude_3d_grid(LayerThicknessFractions, lowerSurface, thickness)
              call mpas_timer_stop("velocity_solver_extrude_3d_grid")
              call mpas_timer_start("velocity_solver_init_FO")
              call velocity_solver_init_FO(LayerThicknessFractions)
              call mpas_timer_stop("velocity_solver_init_FO")
#else
              write(0,*) "Error: External library needed to run FO dycore."
              err = 1
              return
#endif

          case ('Stokes') ! ===============================================
#ifdef USE_EXTERNAL_STOKES
              call mpas_timer_start("velocity_solver_extrude_3d_grid")
              call velocity_solver_extrude_3d_grid(LayerThicknessFractions, lowerSurface, thickness)
              call mpas_timer_stop("velocity_solver_extrude_3d_grid")
              call mpas_timer_start("velocity_solver_init_stokes")
              call velocity_solver_init_stokes(LayerThicknessFractions)
              call mpas_timer_stop("velocity_solver_init_stokes")
#else
              write(0,*) "Error: External Stokes library needed to run stokes dycore."
              err = 1
              return
#endif
          end select
      endif


      ! ==================================================================
      ! External dycore calls to be made every time step (solve velocity!)
      ! ==================================================================

      select case (config_velocity_solver)
      case ('L1L2') ! ===============================================
#ifdef USE_EXTERNAL_L1L2
          call mpas_timer_start("velocity_solver_solve_L1L2")
          call velocity_solver_solve_L1L2(lowerSurface, thickness, beta, tracers(index_temperature,:,:), normalVelocity)
!         call velocity_solver_estimate_SS_SMB(normalVelocity, mesh % sfcMassBal % array)
          call mpas_timer_stop("velocity_solver_solve_L1L2")
          ! Optional calls to have LifeV output data files
          call mpas_timer_start("velocity_solver export")
          call velocity_solver_export_2d_data(lowerSurface, thickness, beta)
          call velocity_solver_export_L1L2_velocity();
          call mpas_timer_stop("velocity_solver export")
#else
              write(0,*) "Error: External LifeV library needed to run L1L2 dycore."
              err = 1
              return
#endif

      case ('FO') ! ===============================================
#ifdef USE_EXTERNAL_FIRSTORDER
          call mpas_timer_start("velocity_solver_solve_FO")
          call velocity_solver_solve_FO(lowerSurface, thickness, beta, tracers(index_temperature,:,:), normalVelocity)
!	  call velocity_solver_estimate_SS_SMB(normalVelocity, mesh % sfcMassBal % array)
          call mpas_timer_stop("velocity_solver_solve_FO")
          call mpas_timer_start("velocity_solver export")
!	  call velocity_solver_init_L1L2(LayerThicknessFractions)          
!	  call velocity_solver_export_2d_data(lowerSurface, thickness, beta)
          call velocity_solver_export_FO_velocity()
          call mpas_timer_stop("velocity_solver export")
#else
              write(0,*) "Error: External library needed to run FO dycore."
              err = 1
              return
#endif

      case ('Stokes') ! ===============================================
#ifdef USE_EXTERNAL_STOKES
          call mpas_timer_start("velocity_solver_solve_stokes")
          call velocity_solver_solve_stokes(lowerSurface, thickness, beta, tracers(index_temperature,:,:), normalVelocity)
          call mpas_timer_stop("velocity_solver_solve_stokes")
#else
          write(0,*) "Error: External Stokes library needed to run stokes dycore."
          err = 1
          return
#endif
      end select


   normalVelocity = normalVelocity / (365.0*24.0*3600.0)  ! convert from m/yr to m/s

   !--------------------------------------------------------------------
   end subroutine li_velocity_external_solve



!***********************************************************************
!
!  routine li_velocity_external_finalize
!
!> \brief   Finalizes external velocity solvers
!> \author Matt Hoffman
!> \date   3 October 2013
!> \version SVN:$Id$
!> \details
!>  This routine finalizes the ice velocity solver in the external libraries.
!
!-----------------------------------------------------------------------

   subroutine li_velocity_external_finalize(domain, err)

      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------

      type (domain_type), intent(inout) :: domain

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------

      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------

      err = 0

#if defined(USE_EXTERNAL_L1L2) || defined(USE_EXTERNAL_FIRSTORDER) || defined(USE_EXTERNAL_STOKES)
      ! This call is needed for using any of the external velocity solvers
      call velocity_solver_finalize()
#else
      write(0,*) "Error: To run with an external velocity solver you must compile MPAS with one."
      err = 1
      return
#endif

   !--------------------------------------------------------------------
   end subroutine li_velocity_external_finalize



!***********************************************************************
!  private subroutines
!***********************************************************************



!***********************************************************************
!
!  routine interface_stokes_init
!
!> \brief   Initializes stokes external velocity solver
!> \author Matt Hoffman
!> \date   3 October 2013
!> \details
!>  This routine initializes the ice velocity solver in the stokes
!>  external library (currently only PHG).
!
!-----------------------------------------------------------------------

   subroutine interface_stokes_init(domain, err)

      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------

      type (domain_type), intent(inout) :: domain

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------

      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------

      err = 0

#ifdef USE_EXTERNAL_STOKES
      ! This call is needed for using any of the PHG velocity solvers
      call phg_init(domain % dminfo % comm)
#else
      write(0,*) "Error: External Stokes library needed to run stokes dycore."
      err = 1
      return
#endif

   !--------------------------------------------------------------------
   end subroutine interface_stokes_init



!***********************************************************************
!
!  routine array_from_exchange_list
!
!> \brief   Converts the MPAS Exchange Lists to flat arrays for external use
!> \author Matt Hoffman
!> \date   3 October 2013
!> \version SVN:$Id$
!> \details
!>  This routine converts the MPAS Exchange Lists (type mpas_multihalo_exchange_list)
!>  to flat arrays for use by external dycores.
!-----------------------------------------------------------------------

   subroutine array_from_exchange_list(field, sendArray, recvArray)
      !-----------------------------------------------------------------
      ! input variables
      !-----------------------------------------------------------------
      type (field1DInteger), pointer, intent(in) :: field   !< Input: the field that holds the MPAS exchange lists.
      ! Any 1d integer fields will work, but it is suggested to use one of indexToCellID, indexToEdgeID, or IndexToVertexID

      !-----------------------------------------------------------------
      ! input/output variables
      !-----------------------------------------------------------------
      integer, dimension(:), pointer :: sendArray !< Input/Output: the flat array of elements to send, should be unallocated on input
      integer, dimension(:), pointer :: recvArray !< Input/Output: the flat array of elements to receive, should be unallocated on input

      !-----------------------------------------------------------------
      ! output variables
      !-----------------------------------------------------------------
!      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      ! local variables
      !-----------------------------------------------------------------
      type (mpas_communication_list), pointer :: sendCommList, recvCommList  ! Communication lists that will be setup from mpas_multihalo_exchange_list's as an intermediate step to flat arrays
      type (mpas_communication_list), pointer :: commListPtr  ! A temporary comm list pointer
      integer :: nHaloLayers, iHalo
      integer, dimension(:), pointer :: haloLayers  ! an array of halo layers, needed to setup comm lists - we want all of them
      type (field1DInteger), pointer :: fieldCursor
      integer :: nAdded, bufferOffset, i
      type (mpas_exchange_list), pointer :: exchListPtr


      ! ========================================================================
      ! Step 1: Generate communication lists from the mpas_multihalo_exchange_list's
      !   (this step is written to be compatible with multiple blocks per processor,
      !    even though that is not supported for external dycores.)
      !   This is done because communication lists have the various halos collapsed
      !   into a single list.
      ! ========================================================================

      ! == First prepare communication lists
      nHaloLayers = size(field % sendList % halos)
      allocate(haloLayers(nHaloLayers))
      do iHalo = 1, nHaloLayers
         haloLayers(iHalo) = iHalo
      end do
      ! Built new send/receive communication lists that have procID & nList filled out.
      call mpas_dmpar_build_comm_lists(field % sendList, field % recvList, haloLayers, field % dimsizes, sendCommList, recvCommList)


      ! == Next populate the commLists' ibuffer field with the element indices to communicate

      ! NOTE:  Looping over the various block's via the field linked list is NOT needed
      !  because packing the communication list with indices will be garbage
      !  if there is more than one block per processor since the indices are block specific.
      !  External dycores currently only support one block per processor and
      !  this subroutine would need substantial modification to support more.
      !  However I am keeping the code that traverses blocks
      !  because this section is taken from mpas_dmpar_exch_halo_field1d_integer
      !  and retaining it makes comparison to that subroutine easier.  The only
      !  difference is the assignements to the ibuffers.
      !  A check for 1 block per proc is in li_velocity_external_init.


      ! Allocate space in send lists, and copy data into buffer
      commListPtr => sendCommList
      do while(associated(commListPtr))  ! Traverse all the processors to be sent to.
        allocate(commListPtr % ibuffer(commListPtr % nList))
        nullify(commListPtr % rbuffer)
        bufferOffset = 0
        do iHalo = 1, nHaloLayers
          nAdded = 0

          fieldCursor => field
          do while(associated(fieldCursor))  ! This is the linked list traversal that is NOT needed.
            exchListPtr => fieldCursor % sendList % halos(haloLayers(iHalo)) % exchList
            do while(associated(exchListPtr))
              if (exchListPtr % endPointID == commListPtr % procID) then
                do  i = 1, exchListPtr % nList
                  commListPtr % ibuffer(exchListPtr % destList(i) + bufferOffset) = exchListPtr % srcList(i)  ! local indices to go into the send communication list
                  nAdded = nAdded + 1

                end do
              end if

              exchListPtr => exchListPtr % next
            end do

            fieldCursor => fieldCursor % next
          end do
          bufferOffset = bufferOffset + nAdded
        end do

        commListPtr => commListPtr % next
      end do


      ! Allocate space in recv lists, and copy data into buffer
      commListPtr => recvCommList
      do while(associated(commListPtr))  ! Traverse all the processors to receive from.
        allocate(commListPtr % ibuffer(commListPtr % nList))
        nullify(commListPtr % rbuffer)
        bufferOffset = 0
        do iHalo = 1, nHaloLayers
          nAdded = 0
          fieldCursor => field
          do while(associated(fieldCursor))  ! This is the linked list traversal that is NOT needed.
            exchListPtr => fieldCursor % recvList % halos(haloLayers(iHalo)) % exchList
            do while(associated(exchListPtr))
              if (exchListPtr % endPointID == commListPtr % procID) then
                do i = 1, exchListPtr % nList
                  commListPtr % ibuffer( exchListPtr % srcList(i) + bufferOffset ) = exchListPtr % destList(i)  ! buffer index to go into the receive communication list
                end do
                nAdded = max(nAdded, maxval(exchListPtr % srcList))
              end if
              exchListPtr => exchListPtr % next
            end do

            fieldCursor => fieldCursor % next
          end do
          bufferOffset = bufferOffset + nAdded
        end do
        commListPtr => commListPtr % next
      end do


      ! ========================================================================
      ! Step 2: Flatten the communication lists to flat arrays 
      ! ========================================================================
      call fill_exchange_array(sendCommList, sendArray)
      call fill_exchange_array(recvCommList, recvArray)


      ! Clean up
      call mpas_dmpar_destroy_communication_list(sendCommList)
      call mpas_dmpar_destroy_communication_list(recvCommList)
      deallocate(haloLayers)

   end subroutine array_from_exchange_list
!***********************************************************************


!***********************************************************************
!
!  routine fill_exchange_array
!
!> \brief   Fills the flat array for external use with information from an MPAS communication list
!> \author Matt Hoffman
!> \date   15 October 2013
!> \version SVN:$Id$
!> \details
!>  This routine converts the MPAS Communication Lists (type mpas_communication_list)
!>  to flat arrays for use by external dycores.  The arrays have this format:
!>
!>  Pos 1: total size of array
!>  For each processor to be communicated with:
!>    Pos 1: processor ID
!>    Pos 2: nList (number of elements in this processor's sub-list
!>    Pos 3 to 3+nList-1:  local indices of elements to be communicated (using 0-based indexing for C/C++)
!-----------------------------------------------------------------------
   subroutine fill_exchange_array(commList, commArray)
      !-----------------------------------------------------------------
      ! input variables
      !-----------------------------------------------------------------
      type (mpas_communication_list), pointer, intent(in) :: &
         commList  !< Input: Communication list to be flattened

      !-----------------------------------------------------------------
      ! input/output variables
      !-----------------------------------------------------------------
      integer, dimension(:), pointer :: commArray !< Input/Output: the flat array of elements to communicate, should be unallocated on input

      !-----------------------------------------------------------------
      ! output variables
      !-----------------------------------------------------------------
!      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      ! local variables
      !-----------------------------------------------------------------
      integer :: arraySize ! size of array to house the send or receive list (sendArray, recvArray)
      integer :: offset !  offset for adding metadata about each processor into the flat commArray
      integer :: i
      type (mpas_communication_list), pointer :: commListPtr  ! A temporary comm list pointer for traversing linked lists

      arraySize = 1 !in first position we will store the size of the array
      commListPtr => commList
      do while (associated(commListPtr))
         ! for each processor to be communicated with, we will store the procID, nList, and then the list of local indices to be communicated
         arraySize = arraySize + commListPtr % nlist + 2
         commListPtr => commListPtr % next
      end do

      allocate(commArray(arraySize))

      commArray(1) = arraySize
      offset = 2    ! we will store the procID, nList before the list of local indices
      commListPtr => commList
      do while (associated(commListPtr))
         commArray(offset) = commListPtr % procID  ! store procID
         offset = offset + 1
         commArray(offset) = commListPtr % nlist   ! store nList
         do i = 1 , commListPtr % nlist
            commArray(i+offset) = commListPtr % ibuffer(i) -1  ! add the list of elements to be communicated, switching to 0-based indexing for C/C++
         end do
         offset = offset + commListPtr % nlist + 1

         commListPtr => commListPtr % next
      end do

   end subroutine fill_exchange_array
!***********************************************************************


end module li_velocity_external

!|||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
