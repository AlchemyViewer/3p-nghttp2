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

            opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)"
            plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

            # Release Build
            mkdir -p "build"
            pushd "build"
                cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_C_FLAGS="$plainopts" \
                    -DCMAKE_CXX_FLAGS="$opts" \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)" \
                    -DCMAKE_INSTALL_LIBDIR="$(cygpath -m "$stage/lib/release")" \
                    -DBUILD_SHARED_LIBS=OFF \
                    -DBUILD_TESTING=OFF \
                    -DENABLE_LIB_ONLY=ON \
                    -DBUILD_STATIC_LIBS=ON

                cmake --build . --config Release --clean-first
                cmake --install . --config Release
            popd
        ;;

        darwin*)
            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_DEPLOY_TARGET}

            for arch in x86_64 arm64 ; do
                ARCH_ARGS="-arch $arch"
                cxx_opts="${TARGET_OPTS:-$ARCH_ARGS $LL_BUILD_RELEASE}"
                cc_opts="$(remove_cxxstd $cxx_opts)"

                mkdir -p "build_$arch"
                pushd "build_$arch"
                    cmake .. -G Ninja -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=ON \
                        -DCMAKE_BUILD_TYPE=Release \
                        -DCMAKE_C_FLAGS="$cc_opts" \
                        -DCMAKE_CXX_FLAGS="$cxx_opts" \
                        -DCMAKE_INSTALL_PREFIX="$stage" \
                        -DCMAKE_INSTALL_LIBDIR="$stage/lib/release" \
                        -DCMAKE_OSX_ARCHITECTURES:STRING=$arch \
                        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                        -DCMAKE_MACOSX_RPATH=YES \
                        -DCMAKE_INSTALL_PREFIX="$stage" \
                        -DCMAKE_INSTALL_LIBDIR="$stage/lib/release/$arch" \
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

            # create staging dirs
            mkdir -p "$stage/include/nghttp2"
            mkdir -p "$stage/lib/release"

            # create fat libraries
            lipo -create -output ${stage}/lib/release/libnghttp2.a ${stage}/lib/release/x86_64/libnghttp2.a ${stage}/lib/release/arm64/libnghttp2.a
        ;;

        linux*)
            # Default target per --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"
            plainopts="$(remove_cxxstd $opts)"

            mkdir -p "build"
            pushd "build"
                CFLAGS="$plainopts" \
                cmake .. -G Ninja -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=ON \
                    -DCMAKE_BUILD_TYPE="Release" \
                    -DCMAKE_C_FLAGS="$plainopts" \
                    -DCMAKE_CXX_FLAGS="$opts" \
                    -DCMAKE_INSTALL_PREFIX="$stage" \
                    -DCMAKE_INSTALL_LIBDIR="$stage/lib/release" \
                    -DENABLE_LIB_ONLY=ON \
                    -DBUILD_STATIC_LIBS=ON

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    cmake --build . --config Release -t check
                fi
            popd
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp "$top/nghttp2/COPYING" "$stage/LICENSES/nghttp2.txt"
popd
