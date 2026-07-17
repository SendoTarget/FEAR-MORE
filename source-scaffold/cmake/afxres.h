#pragma once

// Modern Visual Studio Build Tools can provide the Windows resource compiler
// without the optional MFC headers.  The game module resources only require
// the standard Win32 resource definitions.
#include <winres.h>
