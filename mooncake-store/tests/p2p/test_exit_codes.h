#pragma once

namespace mooncake::testing {

// Exit code used to skip cross-process test suites under ASAN. Must match
// SKIP_RETURN_CODE in tests/p2p/CMakeLists.txt. 77 is the conventional
// skip exit code (ctest / autotools convention).
constexpr int kAsanSkipExitCode = 77;

}  // namespace mooncake::testing
