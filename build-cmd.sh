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

if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
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

# remove_cxxstd
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

apply_patch "$top/patches/update-cmake-version-compat.patch" "nghttp2"

pushd "$top/nghttp2"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            for arch in sse avx2 arm64 ; do
                platform_target="x64"
                if [[ "$arch" == "arm64" ]]; then
                    platform_target="ARM64"
                fi

                mkdir -p "build_debug_$arch"
                pushd "build_debug_$arch"
                    opts="$(replace_switch /Zi /Z7 $LL_BUILD_DEBUG)"
                    if [[ "$arch" == "avx2" ]]; then
                        opts="$(replace_switch /arch:SSE4.2 /arch:AVX2 $opts)"
                    elif [[ "$arch" == "arm64" ]]; then
                        opts="$(remove_switch /arch:SSE4.2 $opts)"
                    fi
                    plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

                    cmake .. -G"$AUTOBUILD_WIN_CMAKE_GEN" -A"$platform_target" \
                        -DCMAKE_CONFIGURATION_TYPES=Debug \
                        -DCMAKE_C_FLAGS="$plainopts" \
                        -DCMAKE_CXX_FLAGS="$opts" \
                        -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT="Embedded" \
                        -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)" \
                        -DCMAKE_INSTALL_LIBDIR="$(cygpath -m "$stage/lib/$arch/debug")" \
                        -DBUILD_SHARED_LIBS=OFF \
                        -DBUILD_TESTING=OFF \
                        -DENABLE_LIB_ONLY=ON \
                        -DBUILD_STATIC_LIBS=ON

                    cmake --build . --config Debug --clean-first
                    cmake --install . --config Debug
                popd

                # Release Build
                mkdir -p "build_release_$arch"
                pushd "build_release_$arch"
                    opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)"
                    if [[ "$arch" == "avx2" ]]; then
                        opts="$(replace_switch /arch:SSE4.2 /arch:AVX2 $opts)"
                    elif [[ "$arch" == "arm64" ]]; then
                        opts="$(remove_switch /arch:SSE4.2 $opts)"
                    fi
                    plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

                    cmake .. -G"$AUTOBUILD_WIN_CMAKE_GEN" -A"$platform_target" \
                        -DCMAKE_CONFIGURATION_TYPES=Release \
                        -DCMAKE_C_FLAGS="$plainopts" \
                        -DCMAKE_CXX_FLAGS="$opts" \
                        -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT="Embedded" \
                        -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)" \
                        -DCMAKE_INSTALL_LIBDIR="$(cygpath -m "$stage/lib/$arch/release")" \
                        -DBUILD_SHARED_LIBS=OFF \
                        -DBUILD_TESTING=OFF \
                        -DENABLE_LIB_ONLY=ON \
                        -DBUILD_STATIC_LIBS=ON

                    cmake --build . --config Release --clean-first
                    cmake --install . --config Release
                popd
            done
        ;;

        darwin*)
            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_DEPLOY_TARGET}

            for arch in x86_64 arm64 ; do
                ARCH_ARGS="-arch $arch"
                cxx_opts="${TARGET_OPTS:-$ARCH_ARGS $LL_BUILD_RELEASE}"
                cc_opts="$(remove_cxxstd $cxx_opts)"
                ld_opts="$ARCH_ARGS"

                mkdir -p "build_$arch"
                pushd "build_$arch"
                    CFLAGS="$cc_opts" \
                    CXXFLAGS="$cxx_opts" \
                    LDFLAGS="$ld_opts" \
                    cmake .. -G Ninja -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=ON \
                        -DCMAKE_BUILD_TYPE=Release \
                        -DCMAKE_C_FLAGS="$cc_opts" \
                        -DCMAKE_CXX_FLAGS="$cxx_opts" \
                        -DCMAKE_INSTALL_PREFIX="$stage" \
                        -DCMAKE_INSTALL_LIBDIR="$stage/lib/release/$arch" \
                        -DCMAKE_OSX_ARCHITECTURES:STRING=$arch \
                        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                        -DCMAKE_MACOSX_RPATH=YES \
                        -DENABLE_LIB_ONLY=ON \
                        -DBUILD_STATIC_LIBS=ON

                    cmake --build . --config Release
                    cmake --install . --config Release

                    # conditionally run unit tests
                    if [ "${DISABLE_UNIT_TESTS:-0}" = "0" -a "$arch" = "$(uname -m)" ]; then
                        cmake --build . --config Release -t check
                    fi
                popd
            done

            # create fat libraries
            lipo -create -output ${stage}/lib/release/libnghttp2.a ${stage}/lib/release/x86_64/libnghttp2.a ${stage}/lib/release/arm64/libnghttp2.a
        ;;

        linux*)
            for arch in sse avx2 ; do
                # Default target per autobuild build --address-size
                opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"
                if [[ "$arch" == "avx2" ]]; then
                    opts="$(replace_switch -march=x86-64-v2 -march=x86-64-v3 $opts)"
                fi

                # Release
                mkdir -p "build_$arch"
                pushd "build_$arch"
                    CFLAGS="$plainopts" \
                    cmake .. -G Ninja -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=ON \
                        -DCMAKE_BUILD_TYPE="Release" \
                        -DCMAKE_C_FLAGS="$plainopts" \
                        -DCMAKE_CXX_FLAGS="$opts" \
                        -DCMAKE_INSTALL_PREFIX="$stage" \
                        -DCMAKE_INSTALL_LIBDIR="$stage/lib/$arch/release" \
                        -DENABLE_LIB_ONLY=ON \
                        -DBUILD_STATIC_LIBS=ON

                    cmake --build . --config Release
                    cmake --install . --config Release

                    # conditionally run unit tests
                    if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                        cmake --build . --config Release -t check
                    fi
                popd
            done
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp "$top/nghttp2/COPYING" "$stage/LICENSES/nghttp2.txt"
popd
