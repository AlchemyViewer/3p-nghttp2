add_subdirectory(includes)

include_directories(
  "${CMAKE_CURRENT_SOURCE_DIR}/includes"
  "${CMAKE_CURRENT_BINARY_DIR}/includes"
)

add_definitions(-DBUILDING_NGHTTP2)

set(NGHTTP2_SOURCES
  nghttp2_pq.c nghttp2_map.c nghttp2_queue.c
  nghttp2_frame.c
  nghttp2_buf.c
  nghttp2_stream.c nghttp2_outbound_item.c
  nghttp2_session.c nghttp2_submit.c
  nghttp2_helper.c
  nghttp2_npn.c
  nghttp2_hd.c nghttp2_hd_huffman.c nghttp2_hd_huffman_data.c
  nghttp2_version.c
  nghttp2_priority_spec.c
  nghttp2_option.c
  nghttp2_callbacks.c
  nghttp2_mem.c
  nghttp2_http.c
  nghttp2_rcbuf.c
  nghttp2_debug.c
)

set(NGHTTP2_RES "")

if(WIN32)
  configure_file(
    version.rc.in
    ${CMAKE_CURRENT_BINARY_DIR}/version.rc
    @ONLY)

  set(NGHTTP2_RES ${CMAKE_CURRENT_BINARY_DIR}/version.rc)
endif()

# Public shared library
if(ENABLE_SHARED_LIB)
  add_library(nghttp2 SHARED ${NGHTTP2_SOURCES} ${NGHTTP2_RES})
  set_target_properties(nghttp2 PROPERTIES
    COMPILE_FLAGS "${WARNCFLAGS}"
    VERSION ${LT_VERSION} SOVERSION ${LT_SOVERSION}
    C_VISIBILITY_PRESET hidden
  )
  target_include_directories(nghttp2 INTERFACE
    "${CMAKE_CURRENT_BINARY_DIR}/includes"
    "${CMAKE_CURRENT_SOURCE_DIR}/includes"
  )

  # <ALCHEMY>
  if("${CMAKE_C_COMPILER_ID}" STREQUAL "MSVC")
    target_compile_options(nghttp2 PRIVATE /std:c++17 /permissive- /Zi $<$<CONFIG:Release>:/Ob3> $<$<CONFIG:Release>:/Gy> $<$<EQUAL:${CMAKE_SIZEOF_VOID_P},4>:/arch:SSE2>)
    target_link_options(nghttp2 PRIVATE /DEBUG:FULL $<$<CONFIG:Release>:/OPT:REF> $<$<CONFIG:Release>:/OPT:ICF>)
  endif()
  # </ALCHEMY>

  install(TARGETS nghttp2
    ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
endif()

if(HAVE_CUNIT OR ENABLE_STATIC_LIB)
  # Static library (for unittests because of symbol visibility)
  add_library(nghttp2_static STATIC ${NGHTTP2_SOURCES})
  set_target_properties(nghttp2_static PROPERTIES
    COMPILE_FLAGS "${WARNCFLAGS}"
    VERSION ${LT_VERSION} SOVERSION ${LT_SOVERSION}
    ARCHIVE_OUTPUT_NAME nghttp2${STATIC_LIB_SUFFIX}
  )
  target_compile_definitions(nghttp2_static PUBLIC "-DNGHTTP2_STATICLIB")

  # <ALCHEMY>
  if("${CMAKE_C_COMPILER_ID}" STREQUAL "MSVC")
    target_compile_options(nghttp2_static PRIVATE /std:c++17 /permissive- /Z7 $<$<CONFIG:Release>:/Ob3> $<$<CONFIG:Release>:/Gy> $<$<EQUAL:${CMAKE_SIZEOF_VOID_P},4>:/arch:SSE2>)
    target_link_options(nghttp2_static PRIVATE /DEBUG:FULL $<$<CONFIG:Release>:/OPT:REF> $<$<CONFIG:Release>:/OPT:ICF>)
  endif()
  # </ALCHEMY>

  if(ENABLE_STATIC_LIB)
    install(TARGETS nghttp2_static
      DESTINATION "${CMAKE_INSTALL_LIBDIR}")
  endif()
endif()


install(FILES "${CMAKE_CURRENT_BINARY_DIR}/libnghttp2.pc"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig")
