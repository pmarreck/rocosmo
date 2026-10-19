/* Test payload for rocosmo-pack --data on Windows: prints lib\hello.txt from
 * the directory holding this executable, the way an app that looks for data
 * beside itself (Zig's lib\) finds it. Built with zig cc for x86_64-windows. */
#include <stdio.h>
#include <string.h>
#include <windows.h>

int main(void) {
	char path[32768];
	DWORD n = GetModuleFileNameA(NULL, path, sizeof path);
	if (n == 0 || n >= sizeof path) return 2;
	char *slash = strrchr(path, '\\');
	if (!slash || (size_t)(slash - path) + sizeof "\\lib\\hello.txt" > sizeof path) return 2;
	strcpy(slash, "\\lib\\hello.txt");
	FILE *f = fopen(path, "rb");
	if (!f) { fprintf(stderr, "showlib: cannot open %s\n", path); return 1; }
	char buf[4096];
	size_t got;
	while ((got = fread(buf, 1, sizeof buf, f)) > 0) fwrite(buf, 1, got, stdout);
	fclose(f);
	return 0;
}
