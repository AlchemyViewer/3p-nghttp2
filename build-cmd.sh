#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

top="$(pwd)"
stage="$(pwd)/stage"

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

NGHTTP2_VERSION_HEADER_DIR="$top/nghttp2/lib/includes/nghttp2"
build=${AUTOBUILD_BUILD_ID:=0}

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/release/lib*.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}


# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/release/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

pushd "$top/nghttp2"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                archflags=""
            else
                archflags=""
            fi

            # Create staging dirs
            mkdir -p "$stage/include/nghttp2"
            mkdir -p "${stage}/lib/debug"
            mkdir -p "${stage}/lib/release"

            # Debug Build
            mkdir -p "build_debug"
            pushd "build_debug"

                cmake -E env CFLAGS="$archflags /Zi" CXXFLAGS="$archflags /Zi" LDFLAGS="/DEBUG:FULL" \
                cmake .. -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -DENABLE_LIB_ONLY=ON \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m "$stage")"

                cmake --build . --config Debug --clean-first

                cp -a lib/Debug/nghttp2.{lib,dll,exp,pdb} "$stage/lib/debug/"
            popd

            # Release Build
            mkdir -p "build_release"
            pushd "build_release"

                cmake -E env CFLAGS="$archflags /O2 /Ob3 /GL /Gy /Zi" CXXFLAGS="$archflags /O2 /Ob3 /GL /Gy /Zi /std:c++17 /permissive-" LDFLAGS="/LTCG /OPT:REF /OPT:ICF /DEBUG:FULL" \
                cmake .. -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -DENABLE_LIB_ONLY=ON \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m "$stage")"

                cmake --build . --config Release --clean-first
                
                cp -a lib/Release/nghttp2.{lib,dll,exp,pdb} "$stage/lib/release/"

                cp -a lib/includes/nghttp2/nghttp2ver.h "$stage/include/nghttp2"
            popd

            cp "$NGHTTP2_VERSION_HEADER_DIR"/nghttp2.h "$stage/include/nghttp2/"
        ;;

        darwin*)
            opts="${TARGET_OPTS:--arch $AUTOBUILD_CONFIGURE_ARCH $LL_BUILD_RELEASE}"

##          # Release configure and build
##          ./configure --enable-lib-only CFLAGS="$opts" CXXFLAGS="$opts"
##          make
##          make check

            cmake . -DCMAKE_C_FLAGS:STRING="$opts" \
                -DCMAKE_CXX_FLAGS:STRING="$opts" \
                -DCMAKE_INSTALL_PREFIX="$stage"

            cmake --build . --config Release

            mkdir -p "$stage/lib/release"
            mv "$top/nghttp2/lib"/libnghttp2*.dylib "$stage/lib/release/"

            # SL-807: fix_dylib_id doesn't really handle symlinks, even though
            # it's coded to try to do so. Chase the multiple levels of
            # indirection to find the real dylib.
            pushd "$stage/lib/release"
                dylib="libnghttp2.dylib"
                while [ -L "$dylib" ]
                do dylib="$(readlink "$dylib")"
                done
                fix_dylib_id "$dylib"
            popd

#            make distclean

            mkdir -p "$stage/include/nghttp2"
            cp "$NGHTTP2_VERSION_HEADER_DIR"/*.h "$stage/include/nghttp2/"
        ;;

        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            # unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS

            # Default target per --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"

            # Setup build flags
            DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC -DPIC"
            RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -DPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
            RELEASE_CPPFLAGS="-DPIC"

            JOBS=`cat /proc/cpuinfo | grep processor | wc -l`

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Fix up path for pkgconfig
            if [ -d "$stage/packages/lib/release/pkgconfig" ]; then
                fix_pkgconfig_prefix "$stage/packages"
            fi

            OLD_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"

            # force regenerate autoconf
            autoreconf -fvi

            # debug configure and build
            export PKG_CONFIG_PATH="$stage/packages/lib/debug/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            CFLAGS="$DEBUG_CFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" ./configure --enable-lib-only --enable-static --disable-shared \
                --prefix="\${AUTOBUILD_PACKAGES_DIR}" --includedir="\${prefix}/include" --libdir="\${prefix}/lib/debug"
            make -j$JOBS
            make check
            make install DESTDIR="$stage"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check
            fi

            make distclean

            # Release configure and build
            export PKG_CONFIG_PATH="$stage/packages/lib/release/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" ./configure --enable-lib-only --enable-static --disable-shared \
                --prefix="\${AUTOBUILD_PACKAGES_DIR}" --includedir="\${prefix}/include" --libdir="\${prefix}/lib/release"
            make -j$JOBS
            make check
            make install DESTDIR="$stage"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check
            fi

            make distclean

        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp "$top/nghttp2/COPYING" "$stage/LICENSES/nghttp2.txt"
popd

# Must be done after the build.  nghttp2ver.h is created as part of the build.
version="$(sed -n -E 's/#define NGHTTP2_VERSION "([^"]+)"/\1/p' "${stage}/include/nghttp2/nghttp2ver.h" | tr -d '\r' )"
echo "${version}.${build}" > "${stage}/VERSION.txt"
