#ifndef CORVUS_SIGNAL_H
#define CORVUS_SIGNAL_H

/*
 * The Signal backend (corvus-signal) linked into an app instead of started as a process.
 * A run is one command line on a thread of its own, e.g.
 *   --config DIR --store-key-stdin -a ACCOUNT jsonRpc
 * with the same lines on its standard streams as the process has (see DESIGN.md).
 */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CsRun CsRun;

/* stream: 1 = standard output, 2 = standard error. Called on the run's thread; line is valid during the call. */
typedef void (*cs_line_fn)(void *ctx, int stream, const char *line);
/* The run ended with this exit code (101: it panicked). Called on the run's thread, last. */
typedef void (*cs_exit_fn)(void *ctx, int code);

/* Starts a run of argv[0..argc] (the arguments after the program name). NULL if it could not start. */
CsRun *cs_run_start(int argc, const char *const *argv, cs_line_fn on_line, cs_exit_fn on_exit, void *ctx);
/* One line of standard input (the store key first, then JSON-RPC requests). 0, or -1 if the run is over. */
int cs_run_send(CsRun *run, const char *line);
/* End of standard input: a jsonRpc run shuts down, a link run is cancelled. */
void cs_run_close_input(CsRun *run);
/* Frees the handle (after cs_exit_fn was called, or after cs_run_close_input if the exit is not awaited). */
void cs_run_free(CsRun *run);

#ifdef __cplusplus
}
#endif

#endif
