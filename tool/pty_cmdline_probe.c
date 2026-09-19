/* packages/flutter_pty/src/flutter_pty_win.c の build_command を検算する。
 *
 * 使い捨て。 パッチした関数をそのまま写して、 実際に組まれるコマンドラインを
 * 目で見る。 期待する形:
 *   "C:\...\npm.cmd" install -g pkg      (自分のパスが 2 回出ない)
 *   "C:\Program Files\nodejs\npm.cmd" …  (空白入りは引用符で囲む)
 *   先頭が空白でない                      (CreateProcessW が err=87 で落ちる)
 *
 * gcc tool/pty_cmdline_probe.c -o probe.exe && ./probe.exe
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef wchar_t WCHAR;
typedef WCHAR *LPWSTR;
#define L_(x) L##x

static LPWSTR build_command(char *executable, char **arguments)
{
    (void)executable;

    if (arguments == NULL || arguments[0] == NULL)
    {
        return NULL;
    }

    int cap = 0;
    for (int i = 0; arguments[i] != NULL; i++)
    {
        cap += (int)strlen(arguments[i]) * 2 + 4;
    }

    LPWSTR command = malloc((cap + 1) * sizeof(WCHAR));
    if (command == NULL)
    {
        return NULL;
    }

    int pos = 0;
    for (int i = 0; arguments[i] != NULL; i++)
    {
        if (i > 0)
        {
            command[pos++] = L' ';
        }

        int quote = (arguments[i][0] == 0) ||
                    (strpbrk(arguments[i], " \t\"") != NULL);

        if (quote)
        {
            command[pos++] = L'"';
        }

        for (int k = 0; arguments[i][k] != 0; k++)
        {
            if (quote && arguments[i][k] == '"')
            {
                command[pos++] = L'\\';
            }
            command[pos++] = (WCHAR)(unsigned char)arguments[i][k];
        }

        if (quote)
        {
            command[pos++] = L'"';
        }
    }

    command[pos] = 0;
    return command;
}

/* Dart 側 (lib/flutter_pty.dart:87-92) と同じ argv を作る。 */
static void run(const char *name, char *exe, char **args, int n)
{
    char **argv = malloc(sizeof(char *) * (n + 2));
    argv[0] = exe;
    for (int i = 0; i < n; i++) argv[i + 1] = args[i];
    argv[n + 1] = NULL;

    LPWSTR cmd = build_command(exe, argv);
    printf("%-22s [%ls]\n", name, cmd ? cmd : L"(null)");
    if (cmd && cmd[0] == L' ') printf("  !! 先頭が空白 (CreateProcessW が err=87)\n");
    free(cmd);
    free(argv);
}

int main(void)
{
    char *a1[] = {"install", "-g", "@anthropic-ai/claude-code"};
    run("npm (引数あり)", "C:\\Users\\Study\\AppData\\Roaming\\npm\\npm.cmd", a1, 3);

    run("claude (引数なし)", "C:\\Users\\Study\\AppData\\Roaming\\npm\\claude.cmd", NULL, 0);

    run("空白入りのパス", "C:\\Program Files\\nodejs\\npm.cmd", a1, 3);

    char *a2[] = {"-p", "hello \"world\""};
    run("引用符入りの引数", "C:\\bin\\claude.cmd", a2, 2);
    return 0;
}
