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

# Create staging dirs
mkdir -p "$stage/include/nghttp2"
mkdir -p "${stage}/lib/debug"
mkdir -p "${stage}/lib/release"

pushd "$top/nghttp2"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            # Debug Build
            mkdir -p "build_debug"
            pushd "build_debug"
                cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Debug \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)/debug" \
                    -DBUILD_SHARED_LIBS=OFF \
                    -DENABLE_LIB_ONLY=ON \
                    -DBUILD_STATIC_LIBS=ON

                cmake --build . --config Debug --clean-first
                cmake --install . --config Debug
            popd

            # Release Build
            mkdir -p "build_release"
            pushd "build_release"
                cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)/release" \
                    -DBUILD_SHARED_LIBS=OFF \
                    -DENABLE_LIB_ONLY=ON \
                    -DBUILD_STATIC_LIBS=ON

                cmake --build . --config Release --clean-first
                cmake --install . --config Release
            popd

            # Copy libraries
            cp -a ${stage}/debug/lib/*.lib ${stage}/lib/debug/
            cp -a ${stage}/release/lib/*.lib ${stage}/lib/release/

            # copy headers
            cp -a $stage/release/include/nghttp2/* $stage/include/nghttp2/
        ;;

        darwin*)
            # Setup build flags
            C_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CFLAGS"
            C_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CFLAGS"
            CXX_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CXXFLAGS"
            CXX_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CXXFLAGS"
            LINK_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_LINKER"
            LINK_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_LINKER"

            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_BASE_DEPLOY_TARGET}

            mkdir -p "build_release_x86"
            pushd "build_release_x86"
                CFLAGS="$C_OPTS_X86" \
                CXXFLAGS="$CXX_OPTS_X86" \
                LDFLAGS="$LINK_OPTS_X86" \
                cmake .. -G Ninja -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_C_FLAGS="$C_OPTS_X86" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_X86" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/release_x86" \
                    -DENABLE_LIB_ONLY=ON \
                    -DBUILD_STATIC_LIBS=ON

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                #     ctest -C Release
                # fi
            popd

            mkdir -p "build_release_arm64"
            pushd "build_release_arm64"
                CFLAGS="$C_OPTS_ARM64" \
                CXXFLAGS="$CXX_OPTS_ARM64" \
                LDFLAGS="$LINK_OPTS_ARM64" \
                cmake .. -G Ninja -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_C_FLAGS="$C_OPTS_ARM64" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_ARM64" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/release_arm64" \
                    -DENABLE_LIB_ONLY=ON \
                    -DBUILD_STATIC_LIBS=ON

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                #     ctest -C Release
                # fi
            popd

            # create staging dirs
            mkdir -p "$stage/include/nghttp2"
            mkdir -p "$stage/lib/release"

            # create fat libraries
            lipo -create ${stage}/release_x86/lib/libnghttp2.a ${stage}/release_arm64/lib/libnghttp2.a -output ${stage}/lib/release/libnghttp2.a

            # copy headers
            mv $stage/release_x86/include/nghttp2/* $stage/include/nghttp2
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
            unset DISTCC_HOSTS CFLAGS CPPFLAGS CXXFLAGS

            # Default target per --address-size
            opts_c="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CFLAGS}"
            opts_cxx="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CXXFLAGS}"

            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$opts_c" \
                cmake .. -G Ninja -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_BUILD_TYPE="Release" \
                    -DCMAKE_C_FLAGS="$opts_c" \
                    -DCMAKE_INSTALL_PREFIX="$stage" \
                    -DENABLE_LIB_ONLY=ON \
                    -DBUILD_STATIC_LIBS=ON

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                #if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                #    ctest -C Release
                #fi
            popd
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp "$top/nghttp2/COPYING" "$stage/LICENSES/nghttp2.txt"
popd

# Must be done after the build.  nghttp2ver.h is created as part of the build.
version="$(sed -n -E 's/#define NGHTTP2_VERSION "([^"]+)"/\1/p' "${stage}/include/nghttp2/nghttp2ver.h" | tr -d '\r' )"
echo "${version}" > "${stage}/VERSION.txt"
