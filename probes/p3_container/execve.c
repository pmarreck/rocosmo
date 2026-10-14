/* Run argv[1] with a raw execve(2): no shell and no ENOEXEC fallback, as a
 * C launcher, a service manager or another language's process API would. */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
	if (argc < 2) return 2;
	execve(argv[1], argv + 1, environ);
	printf("execve: %s\n", strerror(errno));
	return 126;
}
