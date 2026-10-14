/* P9 payload: names the target it was built for and echoes its arguments in
 * brackets; exits 7 when the first argument is "seven". */
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
	printf("hello %s", TARGET);
	for (int i = 1; i < argc; i++) printf(" [%s]", argv[i]);
	printf("\n");
	return argc > 1 && strcmp(argv[1], "seven") == 0 ? 7 : 0;
}
