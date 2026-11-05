#include "include/cmediafinterm.h"

#include <sys/ioctl.h>
#include <unistd.h>

int mediafin_terminal_size(int *columns, int *rows) {
    struct winsize size;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0) {
        return -1;
    }
    /* A terminal multiplexer that is still attaching reports zeroes, and a
     * zero-column screen would divide by nothing further up. */
    if (size.ws_col == 0 || size.ws_row == 0) {
        return -1;
    }
    *columns = size.ws_col;
    *rows = size.ws_row;
    return 0;
}
