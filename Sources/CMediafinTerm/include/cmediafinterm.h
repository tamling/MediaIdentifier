#ifndef CMEDIAFINTERM_H
#define CMEDIAFINTERM_H

/* The size of the terminal attached to stdout.
 *
 * This exists for one reason: the call that answers it is ioctl(2), and
 * ioctl is variadic in C, which Swift cannot import at all. A three-line C
 * file is the whole workaround — no system library, no dependency, and it
 * compiles the same way on Linux and macOS.
 *
 * Returns 0 and fills both out-parameters, or -1 when stdout is not a
 * terminal (a pipe, a file, a cron job) and the caller must fall back.
 */
int mediafin_terminal_size(int *columns, int *rows);

#endif
