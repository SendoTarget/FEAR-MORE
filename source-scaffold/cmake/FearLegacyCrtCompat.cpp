#include <stdio.h>

// The Debug Shared_Assert archive shipped with F.E.A.R. Public Tools 1.08 was
// built against the VS2003 CRT and imports _snprintf through this x86 import
// pointer.  Modern CRT compatibility libraries retain the function but not
// the old pointer symbol.  Define only that ABI bridge; game code continues to
// call its original APIs unchanged.
#if defined(_DEBUG) && defined(_MSC_VER) && (_MSC_VER >= 1900)
extern "C" int (__cdecl* _imp___snprintf)(char*, size_t, const char*, ...) =
	&_snprintf;
#endif
