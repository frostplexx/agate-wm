// Build off the private-API bridges in src/extern/, e.g.:
//   #include "extern/ax_private.h"
//   #include "extern/skylight.h"

void enumerate_windows(void);

int main(void) {
    enumerate_windows();
    return 0;
}
