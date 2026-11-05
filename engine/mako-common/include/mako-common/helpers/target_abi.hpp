/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <string_view>

namespace mako::abi {

    /// Compile-time description of the process ABI a MAKO binary is built for.
    ///
    /// A Vulkan layer is loaded into the application's own process, so every
    /// path that names ABI-specific libraries (Steam Runtime multiarch
    /// directories, layer manifests) must follow the architecture of *this*
    /// build rather than assuming x86. Unsupported targets fail at compile time
    /// instead of silently probing the wrong library directories.
    struct TargetAbi {
        /// Debian/Steam Runtime multiarch tuple, e.g. "x86_64-linux-gnu".
        std::string_view multiarchTuple;
        /// Canonical machine name used by MAKO package metadata.
        std::string_view machine;
    };

#if defined(__x86_64__)
    inline constexpr TargetAbi target{ "x86_64-linux-gnu", "x86_64" };
#elif defined(__i386__)
    inline constexpr TargetAbi target{ "i386-linux-gnu", "i386" };
#elif defined(__aarch64__)
    inline constexpr TargetAbi target{ "aarch64-linux-gnu", "aarch64" };
#else
#error "MAKO Renderer supports x86_64, i386 and aarch64 Linux targets only"
#endif

}
