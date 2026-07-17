#pragma once

// The F.E.A.R. 1.08 SDK relied on standard C declarations that older MSVC
// headers exposed transitively.  Keep those declarations available without
// modifying the user-local SDK extraction.
#include <ctype.h>

// The retail engine and its GameSpy implementation were built with the VC7.1
// standard library.  C++ standard-library objects cannot cross that boundary
// from a newer toolset: their layouts are different even though the engine SDK
// declarations still compile.  Source paths that touch such interfaces use
// this shared marker to retain the VC7.1 behavior in the original project and
// select an ABI-safe path in modern CMake builds.
#if defined(_MSC_VER) && (_MSC_VER > 1310)
#define FEAR_MODERN_STL_ABI 1
#endif
